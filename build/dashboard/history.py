"""In-memory time series of block height and fee, sampled once a minute.

Feeds the dashboard sparklines and gives the tower its "blocks so far today"
count (the current day's layer). It's deliberately in-memory — a lightweight
node dashboard doesn't need a database — so the series resets when the
container restarts, and the day count is exact from the first full UTC day
after start.
"""
import threading
import time
from collections import deque
from datetime import datetime, timezone

MAXLEN = 1440  # ~24h at one sample per minute

# The sampler thread writes and Flask request handlers read, so guard both
# with a lock — otherwise a concurrent append can raise "deque mutated during
# iteration" mid-snapshot (which would 500 the page render).
_lock = threading.Lock()
_samples = deque(maxlen=MAXLEN)
_day = {"date": None, "height": None}  # height at the first sample of the current UTC day


def _utc_day(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")


def record(height, fee, now=None):
    """Record one sample. `now` is injectable for tests."""
    if not isinstance(height, int):
        return
    ts = int(now if now is not None else time.time())
    day = _utc_day(ts)
    with _lock:
        if _day["date"] != day:
            # first sample of a new UTC day — its height is ~midnight's height
            _day["date"] = day
            _day["height"] = height
        _samples.append((ts, height, fee))


def snapshot():
    """Parallel arrays for the sparklines, plus scalars for the tower."""
    with _lock:  # copy once so the three arrays below stay aligned
        samples = list(_samples)
        start = _day["height"]
    ts = [s[0] for s in samples]
    height = [s[1] for s in samples]
    fee = [s[2] for s in samples]
    latest = height[-1] if height else None
    blocks_today = latest - start if (latest is not None and start is not None) else 0
    return {
        "t": ts,
        "height": height,
        "fee": fee,
        "blocks_today": max(0, blocks_today),
        "latest_height": latest,
    }


def reset():
    """Clear all state (tests)."""
    with _lock:
        _samples.clear()
        _day.update(date=None, height=None)
