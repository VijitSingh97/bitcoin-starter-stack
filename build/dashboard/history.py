"""In-memory time series of block height and fee, sampled once a minute.

Feeds the dashboard sparklines and gives the tower its "blocks so far today"
count (the current day's layer). It's deliberately in-memory — a lightweight
node dashboard doesn't need a database — so the series resets when the
container restarts, and the day count is exact from the first full UTC day
after start.
"""
import time
from collections import deque
from datetime import datetime, timezone

MAXLEN = 1440  # ~24h at one sample per minute

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
    if _day["date"] != day:
        # first sample of a new UTC day — its height is ~midnight's height
        _day["date"] = day
        _day["height"] = height
    _samples.append((ts, height, fee))


def snapshot():
    """Parallel arrays for the sparklines, plus scalars for the tower."""
    ts = [s[0] for s in _samples]
    height = [s[1] for s in _samples]
    fee = [s[2] for s in _samples]
    latest = height[-1] if height else None
    start = _day["height"]
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
    _samples.clear()
    _day.update(date=None, height=None)
