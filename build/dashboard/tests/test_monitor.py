import types

import monitor


class Capture:
    def __init__(self):
        self.telegrams = []
        self.pings = []

    def install(self, monkeypatch, free_gb=1000):
        monkeypatch.setattr(monitor, "send_telegram", self.telegrams.append)

        def ping(healthy):  # record it, report success (see retry test for failures)
            self.pings.append(healthy)
            return True

        monkeypatch.setattr(monitor, "ping_healthchecks", ping)
        monkeypatch.setattr(
            monitor.shutil, "disk_usage",
            lambda path: types.SimpleNamespace(free=int(free_gb * 1024**3)),
        )


HEALTHY = {"initialblockdownload": False, "blocks": 900000}
SYNCING = {"initialblockdownload": True, "blocks": 100}


def run_ticks(cap, monkeypatch, infos, free_gb=1000):
    cap.install(monkeypatch, free_gb=free_gb)
    state = {}
    for info in infos:
        state = monitor.tick(lambda i=info: i, state)
    return state


def test_down_alert_is_debounced_and_fires_once(monkeypatch):
    cap = Capture()
    run_ticks(cap, monkeypatch, [None] * 6)
    assert len([t for t in cap.telegrams if "down" in t]) == 1


# --- opt-in new-block alert ---

def test_new_block_alert_when_enabled_and_synced(monkeypatch):
    cap = Capture()
    monkeypatch.setattr(monitor, "ALERT_NEW_BLOCK", True)
    run_ticks(cap, monkeypatch, [
        {"initialblockdownload": False, "blocks": 900000},
        {"initialblockdownload": False, "blocks": 900001},
    ])
    assert any("new block 900001" in t for t in cap.telegrams)


def test_no_new_block_alert_when_disabled(monkeypatch):
    cap = Capture()
    monkeypatch.setattr(monitor, "ALERT_NEW_BLOCK", False)
    run_ticks(cap, monkeypatch, [
        {"initialblockdownload": False, "blocks": 900000},
        {"initialblockdownload": False, "blocks": 900001},
    ])
    assert not any("new block" in t for t in cap.telegrams)


def test_no_new_block_alert_during_sync(monkeypatch):
    cap = Capture()
    monkeypatch.setattr(monitor, "ALERT_NEW_BLOCK", True)
    run_ticks(cap, monkeypatch, [
        {"initialblockdownload": True, "blocks": 100},
        {"initialblockdownload": True, "blocks": 500},
    ])
    assert not any("new block" in t for t in cap.telegrams)


def test_no_new_block_alert_on_catch_up_burst(monkeypatch):
    cap = Capture()
    monkeypatch.setattr(monitor, "ALERT_NEW_BLOCK", True)
    run_ticks(cap, monkeypatch, [
        {"initialblockdownload": False, "blocks": 900000},
        {"initialblockdownload": False, "blocks": 900050},  # +50 > 6, a burst
    ])
    assert not any("new block" in t for t in cap.telegrams)


def test_no_alert_on_momentary_blip(monkeypatch):
    cap = Capture()
    run_ticks(cap, monkeypatch, [None, None, HEALTHY])
    assert cap.telegrams == []


def test_recovery_alert_after_down(monkeypatch):
    cap = Capture()
    run_ticks(cap, monkeypatch, [None, None, None, HEALTHY])
    assert any("down" in t for t in cap.telegrams)
    assert any("recovered" in t for t in cap.telegrams)


def test_sync_complete_fires_on_transition_only(monkeypatch):
    cap = Capture()
    run_ticks(cap, monkeypatch, [SYNCING, SYNCING, HEALTHY, HEALTHY])
    assert len([t for t in cap.telegrams if "sync complete" in t]) == 1


def test_no_sync_alert_when_starting_already_synced(monkeypatch):
    cap = Capture()
    run_ticks(cap, monkeypatch, [HEALTHY, HEALTHY])
    assert cap.telegrams == []


def test_disk_low_fires_once_and_rearms(monkeypatch):
    cap = Capture()
    cap.install(monkeypatch, free_gb=20)
    state = {}
    state = monitor.tick(lambda: HEALTHY, state)
    state = monitor.tick(lambda: HEALTHY, state)
    assert len([t for t in cap.telegrams if "disk low" in t]) == 1
    # space freed: warning re-arms
    cap.install(monkeypatch, free_gb=100)
    state = monitor.tick(lambda: HEALTHY, state)
    cap.install(monkeypatch, free_gb=20)
    state = monitor.tick(lambda: HEALTHY, state)
    assert len([t for t in cap.telegrams if "disk low" in t]) == 2


def test_healthchecks_pinged_on_first_tick_then_throttled(monkeypatch):
    cap = Capture()
    run_ticks(cap, monkeypatch, [HEALTHY] * (monitor.PING_EVERY_TICKS + 1))
    assert cap.pings == [True, True]  # tick 0 and tick PING_EVERY_TICKS


def test_healthchecks_fail_ping_when_node_down(monkeypatch):
    cap = Capture()
    run_ticks(cap, monkeypatch, [None])
    assert cap.pings == [False]


def test_ping_cadence_is_five_minutes():
    # matches the recommended Healthchecks.io period; a change here should be
    # a deliberate one that updates docs/notifications.md too
    assert monitor.PING_EVERY_TICKS * monitor.TICK_SECONDS == 300


def test_healthchecks_retries_every_tick_until_a_ping_succeeds(monkeypatch):
    # a failed ping must not wait a full 5-minute cycle — it retries next tick,
    # so a single Tor hiccup can't trip a tight grace window
    cap = Capture()
    cap.install(monkeypatch)
    attempts = []
    outcomes = iter([False, False, True])  # first two fail, third gets through

    def flaky(healthy):
        attempts.append(healthy)
        return next(outcomes)

    monkeypatch.setattr(monitor, "ping_healthchecks", flaky)
    state = {}
    for _ in range(3):  # three consecutive ticks
        state = monitor.tick(lambda: HEALTHY, state)
    assert len(attempts) == 3  # retried on each tick, not throttled to 5


def test_healthchecks_throttles_after_a_success(monkeypatch):
    cap = Capture()
    cap.install(monkeypatch)  # always succeeds
    state = {}
    for _ in range(monitor.PING_EVERY_TICKS):  # 5 ticks after the first success
        state = monitor.tick(lambda: HEALTHY, state)
    assert len(cap.pings) == 1  # only the first tick pinged; the rest are throttled


def test_send_telegram_routes_over_tor(monkeypatch):
    seen = {}

    def capture_post(url, json, proxies, timeout):
        seen.update(url=url, json=json, proxies=proxies)

    monkeypatch.setattr(monitor, "TELEGRAM_BOT_TOKEN", "123:abc")
    monkeypatch.setattr(monitor, "TELEGRAM_CHAT_ID", "42")
    monkeypatch.setattr(monitor.requests, "post", capture_post)
    monitor.send_telegram("hello")
    assert seen["url"] == "https://api.telegram.org/bot123:abc/sendMessage"
    assert seen["json"]["chat_id"] == "42"
    assert "socks5h://" in seen["proxies"]["https"]


def test_telegram_noop_without_config(monkeypatch):
    monkeypatch.setattr(monitor, "TELEGRAM_BOT_TOKEN", "")

    def boom(*a, **kw):
        raise AssertionError("should not send")

    monkeypatch.setattr(monitor.requests, "post", boom)
    monitor.send_telegram("hello")  # no exception = pass


def test_ping_noop_without_config(monkeypatch):
    monkeypatch.setattr(monitor, "HEALTHCHECKS_URL", "")

    def boom(*a, **kw):
        raise AssertionError("should not ping")

    monkeypatch.setattr(monitor.requests, "get", boom)
    monitor.ping_healthchecks(True)


def test_ping_uses_fail_endpoint_when_unhealthy(monkeypatch):
    seen = {}
    monkeypatch.setattr(monitor, "HEALTHCHECKS_URL", "https://hc-ping.com/uuid")
    monkeypatch.setattr(
        monitor.requests, "get",
        lambda url, proxies, timeout: seen.update(url=url, proxies=proxies),
    )
    monitor.ping_healthchecks(False)
    assert seen["url"] == "https://hc-ping.com/uuid/fail"
    assert "socks5h://" in seen["proxies"]["https"]


# --- update checker ---

def _patch_releases(monkeypatch, stack_tag, core_tag):
    def fake(url):
        return stack_tag if "bitcoin-starter-stack" in url else core_tag

    monkeypatch.setattr(monitor, "_latest_release_tag", fake)


def test_update_alert_for_newer_core(monkeypatch):
    cap = Capture()
    cap.install(monkeypatch)
    monkeypatch.setattr(monitor, "STACK_VERSION", "1.2.0")
    _patch_releases(monkeypatch, "1.2.0", "32.0")
    state = {}
    monitor.check_updates("/Satoshi:31.1.0/", state)
    assert any("Bitcoin Core 32.0" in t for t in cap.telegrams)
    assert "32.0" in monitor.update_available
    # same version again: badge stays, telegram not repeated
    monitor.check_updates("/Satoshi:31.1.0/", state)
    assert len([t for t in cap.telegrams if "32.0" in t]) == 1


def test_no_update_alert_when_current(monkeypatch):
    cap = Capture()
    cap.install(monkeypatch)
    monkeypatch.setattr(monitor, "STACK_VERSION", "1.2.0")
    _patch_releases(monkeypatch, "1.2.0", "31.1")
    monitor.check_updates("/Satoshi:31.1.0/", {})  # 31.1.0 matches release v31.1
    assert cap.telegrams == []
    assert monitor.update_available == ""


def test_update_alert_for_newer_stack(monkeypatch):
    cap = Capture()
    cap.install(monkeypatch)
    monkeypatch.setattr(monitor, "STACK_VERSION", "1.2.0")
    _patch_releases(monkeypatch, "1.3.0", "31.1")
    monitor.check_updates("/Satoshi:31.1.0/", {})
    assert any("stack v1.3.0" in t for t in cap.telegrams)


def test_no_alert_when_box_is_ahead_of_latest_release(monkeypatch):
    # the bug: running v1.12.1 while the API returns an older v1.12.0 must NOT
    # say "v1.12.0 available" — only a strictly newer release alerts
    cap = Capture()
    cap.install(monkeypatch)
    monkeypatch.setattr(monitor, "STACK_VERSION", "1.12.1")
    _patch_releases(monkeypatch, "1.12.0", "31.1")
    monitor.check_updates("/Satoshi:31.1.0/", {})
    assert cap.telegrams == []
    assert monitor.update_available == ""


def test_newer_compares_numeric_parts():
    assert monitor._newer("1.12.1", "1.12.0") is True
    assert monitor._newer("1.12.0", "1.12.1") is False
    assert monitor._newer("1.2.0", "1.2.0") is False
    assert monitor._newer("31.1", "31.1.0") is False  # same release, running has a patch digit
    assert monitor._newer("32.0", "31.1.0") is True
    assert monitor._newer("", "1.0.0") is False


def test_update_check_survives_api_failure(monkeypatch):
    cap = Capture()
    cap.install(monkeypatch)
    monkeypatch.setattr(monitor, "_latest_release_tag", lambda url: "")
    monitor.check_updates("/Satoshi:31.1.0/", {})  # no exception, no alert
    assert cap.telegrams == []