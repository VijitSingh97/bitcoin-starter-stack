import history


def setup_function(_):
    history.reset()


DAY = 86400


def test_records_accumulate_into_parallel_arrays():
    history.record(900000, 5, now=1000)
    history.record(900001, 4, now=1060)
    snap = history.snapshot()
    assert snap["height"] == [900000, 900001]
    assert snap["fee"] == [5, 4]
    assert snap["t"] == [1000, 1060]
    assert snap["latest_height"] == 900001


def test_ignores_non_int_height():
    history.record("N/A", 5, now=1000)
    assert history.snapshot()["height"] == []


def test_ring_buffer_is_capped():
    for i in range(history.MAXLEN + 50):
        history.record(900000 + i, 1, now=i * 60)
    assert len(history.snapshot()["height"]) == history.MAXLEN


def test_snapshot_is_thread_safe_under_concurrent_writes():
    # a writer thread hammers record() while we snapshot repeatedly; the
    # parallel arrays must stay aligned and nothing may raise "deque mutated
    # during iteration" (this fails on an unlocked snapshot)
    import threading

    stop = threading.Event()

    def writer():
        i = 0
        while not stop.is_set():
            history.record(900000 + (i % 1000), i % 7, now=1000 + i)
            i += 1

    t = threading.Thread(target=writer)
    t.start()
    try:
        for _ in range(3000):
            snap = history.snapshot()
            assert len(snap["t"]) == len(snap["height"]) == len(snap["fee"])
    finally:
        stop.set()
        t.join()
