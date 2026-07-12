import fee_history


def setup_function(_):
    fee_history.reset()


def test_records_accumulate():
    fee_history.record(5)
    fee_history.record(4)
    assert fee_history.series() == [5, 4]


def test_ignores_non_numbers():
    fee_history.record(None)
    fee_history.record("nope")
    assert fee_history.series() == []


def test_ring_is_capped():
    for i in range(fee_history.MAXLEN + 25):
        fee_history.record(i)
    assert len(fee_history.series()) == fee_history.MAXLEN


def test_series_is_thread_safe_under_concurrent_writes():
    import threading

    stop = threading.Event()

    def writer():
        i = 0
        while not stop.is_set():
            fee_history.record(i % 20)
            i += 1

    t = threading.Thread(target=writer)
    t.start()
    try:
        for _ in range(3000):
            s = fee_history.series()
            assert all(isinstance(v, int) for v in s)  # no torn reads / exceptions
    finally:
        stop.set()
        t.join()
