import balance_history as bh


def fresh(monkeypatch, tmp_path):
    monkeypatch.setenv("BALANCE_HISTORY", str(tmp_path / "bh.json"))
    monkeypatch.setattr(bh, "_data", None)  # drop the in-memory cache


def test_record_and_series(monkeypatch, tmp_path):
    fresh(monkeypatch, tmp_path)
    bh.record("A", 1.0, now=0)
    bh.record("A", 2.0, now=4000)  # over an hour later
    assert bh.series("A") == [1.0, 2.0]
    assert bh.series("missing") == []


def test_throttles_to_hourly(monkeypatch, tmp_path):
    fresh(monkeypatch, tmp_path)
    bh.record("A", 1.0, now=0)
    bh.record("A", 1.5, now=1000)   # < 1h -> skipped
    bh.record("A", 2.0, now=3600)   # exactly 1h -> recorded
    assert bh.series("A") == [1.0, 2.0]


def test_persists_across_restart(monkeypatch, tmp_path):
    fresh(monkeypatch, tmp_path)
    bh.record("A", 1.5, now=0)
    monkeypatch.setattr(bh, "_data", None)  # simulate a restart (reload from disk)
    assert bh.series("A") == [1.5]


def test_caps_the_series(monkeypatch, tmp_path):
    fresh(monkeypatch, tmp_path)
    monkeypatch.setattr(bh, "MAX_POINTS", 3)
    for i in range(6):
        bh.record("A", float(i), now=i * 3600)
    assert bh.series("A") == [3.0, 4.0, 5.0]  # only the last 3 kept


def test_ignores_non_numeric(monkeypatch, tmp_path):
    fresh(monkeypatch, tmp_path)
    bh.record("A", None, now=0)
    bh.record("A", "oops", now=3600)
    assert bh.series("A") == []


def test_forget_drops_history(monkeypatch, tmp_path):
    fresh(monkeypatch, tmp_path)
    bh.record("A", 1.0, now=0)
    bh.forget("A")
    assert bh.series("A") == []


def test_save_survives_unwritable_path(monkeypatch):
    monkeypatch.setenv("BALANCE_HISTORY", "/nonexistent-xyz/no/perms/bh.json")
    monkeypatch.setattr(bh, "_data", None)
    bh.record("A", 1.0, now=0)  # must not raise


def test_history_is_keyed_by_key_not_name(monkeypatch, tmp_path):
    # two wallets with the same label but different keys keep separate histories,
    # and the same key restores its history (a remove/re-add)
    fresh(monkeypatch, tmp_path)
    bh.record("xpub-AAA", 1.0, now=0)
    bh.record("xpub-BBB", 9.0, now=0)
    assert bh.series("xpub-AAA") == [1.0]
    assert bh.series("xpub-BBB") == [9.0]
    assert bh.series("never-seen") == []


def test_migrate_carries_old_name_history_to_the_key(monkeypatch, tmp_path):
    fresh(monkeypatch, tmp_path)
    # simulate pre-migration data keyed by the display name
    bh._data = {"Satoshi": [[0, 1.0], [3600, 2.0]]}
    bh.migrate("Satoshi", "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
    assert bh.series("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa") == [1.0, 2.0]
    assert "Satoshi" not in bh._data           # old id removed
    bh.migrate("Satoshi", "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")  # idempotent no-op
