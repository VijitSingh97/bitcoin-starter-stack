"""Persisted balance history per watch-only wallet.

Unlike the fee sparkline (an in-memory ring that resets on restart), this is
written to the dashboard_state volume so the trend survives restarts. Coarse
hourly samples — balances move slowly — capped to keep the file tiny. Safe: it
holds only balance numbers + timestamps, never keys, and never leaves the box.

Thread-safe: a background sampler writes, request handlers read.
"""
import json
import os
import threading
import time

MIN_INTERVAL = 3600   # at most one sample per wallet per hour
MAX_POINTS = 2160     # ~90 days of hourly points
_lock = threading.Lock()
_data = None          # {wallet_name: [[ts, btc], ...]}, loaded once


def _path():
    return os.environ.get("BALANCE_HISTORY", "/state/balance_history.json")


def _loaded():
    global _data
    if _data is None:
        try:
            with open(_path()) as f:
                _data = json.load(f)
        except Exception:
            _data = {}
    return _data


def _save():
    try:
        path = _path()
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(_data, f)
        os.replace(tmp, path)
    except Exception as e:  # a missing/unwritable volume must not crash the dashboard
        print(f"balance history not saved: {e}")


def record(name, btc, now=None):
    """Append a sample for `name`, skipped if the last one is under an hour old.
    `now` is injectable for tests."""
    if not isinstance(btc, (int, float)):
        return
    now = time.time() if now is None else now
    with _lock:
        data = _loaded()
        s = data.get(name, [])
        if s and now - s[-1][0] < MIN_INTERVAL:
            return
        data[name] = (s + [[round(now, 3), round(float(btc), 8)]])[-MAX_POINTS:]
        _save()


def series(name):
    """The balance values for a wallet (for the sparkline)."""
    with _lock:
        return [pt[1] for pt in _loaded().get(name, [])]


def forget(name):
    """Drop a removed wallet's history."""
    with _lock:
        if _loaded().pop(name, None) is not None:
            _save()
