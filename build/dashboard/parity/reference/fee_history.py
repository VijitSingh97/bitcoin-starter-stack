"""A tiny in-memory ring of recent fee estimates for the dashboard sparkline.

Just the values (one a minute), no timestamps — a sparkline only needs the
shape. In-memory, so it resets on restart; that's fine for a lightweight
24-hour trend line. Thread-safe: the sampler thread writes, request handlers
read.
"""
import threading
from collections import deque

MAXLEN = 1440  # ~24h at one sample per minute

_lock = threading.Lock()
_fees = deque(maxlen=MAXLEN)


def record(fee):
    if not isinstance(fee, (int, float)):
        return
    with _lock:
        _fees.append(fee)


def series():
    with _lock:
        return list(_fees)


def reset():
    with _lock:
        _fees.clear()
