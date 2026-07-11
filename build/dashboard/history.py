"""In-memory time series of block height and fee, sampled once a minute.

Feeds the dashboard sparklines. It's deliberately in-memory — a lightweight
node dashboard doesn't need a database — so the series resets when the
container restarts. (The tower's "blocks today" count is computed straight
from the node's block timestamps, so it's correct immediately, not from this
series — see node_status.blocks_today.)
"""
import threading
import time
from collections import deque

MAXLEN = 1440  # ~24h at one sample per minute

# The sampler thread writes and Flask request handlers read, so guard both
# with a lock — otherwise a concurrent append can raise "deque mutated during
# iteration" mid-snapshot (which would 500 the page render).
_lock = threading.Lock()
_samples = deque(maxlen=MAXLEN)


def record(height, fee, now=None):
    """Record one sample. `now` is injectable for tests."""
    if not isinstance(height, int):
        return
    ts = int(now if now is not None else time.time())
    with _lock:
        _samples.append((ts, height, fee))


def snapshot():
    """Parallel arrays for the sparklines."""
    with _lock:  # copy once so the three arrays below stay aligned
        samples = list(_samples)
    ts = [s[0] for s in samples]
    height = [s[1] for s in samples]
    fee = [s[2] for s in samples]
    return {
        "t": ts,
        "height": height,
        "fee": fee,
        "latest_height": height[-1] if height else None,
    }


def reset():
    """Clear all state (tests)."""
    with _lock:
        _samples.clear()
