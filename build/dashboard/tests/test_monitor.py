import types

import monitor


class Capture:
    def __init__(self):
        self.telegrams = []
        self.pings = []

    def install(self, monkeypatch, free_gb=1000):
        monkeypatch.setattr(monitor, "send_telegram", self.telegrams.append)
        monkeypatch.setattr(monitor, "ping_healthchecks", self.pings.append)
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


def test_update_check_survives_api_failure(monkeypatch):
    cap = Capture()
    cap.install(monkeypatch)
    monkeypatch.setattr(monitor, "_latest_release_tag", lambda url: "")
    monitor.check_updates("/Satoshi:31.1.0/", {})  # no exception, no alert
    assert cap.telegrams == []