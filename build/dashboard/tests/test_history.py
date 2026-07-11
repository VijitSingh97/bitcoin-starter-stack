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


def test_blocks_today_counts_from_the_first_sample_of_the_utc_day():
    # first sample of a day pins the day-start height
    history.record(900000, 1, now=DAY * 20000)          # 00:00 of some UTC day
    history.record(900010, 1, now=DAY * 20000 + 3600)   # +1h, 10 blocks later
    assert history.snapshot()["blocks_today"] == 10


def test_day_rollover_resets_the_day_start():
    history.record(900100, 1, now=DAY * 20000 + 80000)  # late in a day
    history.record(900100, 1, now=DAY * 20001 + 60)     # first sample after midnight = baseline
    history.record(900105, 1, now=DAY * 20001 + 3600)   # 5 blocks into the new day
    assert history.snapshot()["blocks_today"] == 5


def test_blocks_today_never_negative():
    history.record(900000, 1, now=1000)
    assert history.snapshot()["blocks_today"] >= 0
