"""Unit tests for the fixed-point contract in ml_golden.py.

These specifically target the pitfalls called out in ml_engineer_brief.md
SS13 -- floor-vs-truncate shifting on negative numbers (pitfall #1) and
saturation-not-wrapping (part of SS7.2) -- because a silent bug here is the
most likely way this project's RTL/Python hand-off breaks.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import ml_golden  # noqa: E402


def test_normalize_floor_shift_negative():
    # raw - offset = -5, shift = 1 -> arithmetic floor(-5 / 2) = -3.
    # Python's `int(-5 / 2)` truncates toward zero and gives -2: that would be
    # the exact hardware-mismatch bug the brief warns about (pitfall #1).
    raw = np.array([-5])
    offsets = np.array([0])
    shifts = np.array([1])
    result = ml_golden.normalize(raw, offsets, shifts)
    assert result[0] == -3, f"expected floor shift -3, got {result[0]}"


def test_normalize_floor_shift_matches_verilog_arithmetic_shift():
    # Cross-check against a hand-rolled two's-complement arithmetic shift,
    # independent of numpy, for a spread of positive/negative values and shifts.
    def manual_arith_shift(v: int, s: int, bits: int = 64) -> int:
        mask = (1 << bits) - 1
        uv = v & mask
        shifted = uv >> s
        if uv & (1 << (bits - 1)):
            shifted |= (~0 << (bits - s)) & mask
        # sign-extend back to a Python int
        if shifted & (1 << (bits - 1)):
            shifted -= 1 << bits
        return shifted

    values = [-1000, -33, -1, 0, 1, 33, 1000, -128, 127]
    for v in values:
        for s in range(0, 5):
            expected_raw = manual_arith_shift(v, s)
            got = int(np.right_shift(np.int64(v), np.int64(s)))
            assert got == expected_raw, f"v={v} s={s}: expected {expected_raw}, got {got}"


def test_normalize_saturates_does_not_wrap():
    raw = np.array([100_000, -100_000])
    offsets = np.array([0, 0])
    shifts = np.array([0, 0])
    result = ml_golden.normalize(raw, offsets, shifts)
    assert result[0] == 127
    assert result[1] == -128
    # int8 wraparound would give something far from the clamp -- guard against it.
    assert result.dtype == np.int8


def test_classify_known_vector():
    x = np.array([1, -1, 2, 0, 0, 0, 0, 0], dtype=np.int8)
    w = np.array([10, 10, 5, 1, 1, 1, 1, 1], dtype=np.int8)
    bias = 3
    z = ml_golden.classify(x, w, bias)
    # 1*10 + (-1)*10 + 2*5 + 0*... + bias(3) = 0 + 10 + 3 = 13
    assert int(z) == 13


def test_classify_batch_shape():
    x = np.zeros((5, 8), dtype=np.int8)
    w = np.ones(8, dtype=np.int8)
    z = ml_golden.classify(x, w, bias=7)
    assert z.shape == (5,)
    assert np.all(z == 7)


def test_hysteresis_policy_schmitt_trigger():
    z = np.array([0, 5, 15, 15, 4, 2, 15, 2])
    symbol_ids = np.array([0, 0, 0, 0, 0, 0, 0, 0])
    out = ml_golden.hysteresis_policy(z, symbol_ids, t_high=10, t_low=3)
    # rises to 1 once z hits 15 (idx2), stays 1 through idx3 (15) and idx4 (4,
    # above t_low), drops at idx5 (2 <= t_low), rises again at idx6 (15).
    assert list(out) == [0, 0, 1, 1, 1, 0, 1, 0]


def test_feature_extraction_hand_computed_case():
    """A small, hand-computed sequence (roadmap Step 4). Verifies F0-F7
    against manually worked-out values for the first few quote events.

    Note: with FeatureEngine delegating to sim/feature_golden.FeatureTracker
    (D52 fix), a CLEAR event is treated as the "first event after reset" (f1=0),
    so the next QUOTE is NOT a first event and computes f1/f3/f4 as deltas.
    """
    events = [
        {"seq": 0, "symbol_id": 0, "type": "clear", "gap": False},
        # CLEAR resets prev_bid/prev_ask to 0 and is itself the "first event"
        # seq=1: mid = (100+104)>>1 = 102; NOT a first event (CLEAR already was)
        # F1 = 102 - (0+0)>>1 = 102, F3 = 50 - 0 = 50, F4 = 60 - 0 = 60
        # window has 2 entries (CLEAR's + this QUOTE's) -> F5=2, F7=102
        {"seq": 1, "symbol_id": 0, "type": "quote", "bid": 100, "ask": 104,
         "bid_qty": 50, "ask_qty": 60, "gap": False},
        # seq=2: mid = (101+104)>>1 = 102; F1 = 102 - 102 = 0, F3 = 55 - 50 = 5, F4 = 58 - 60 = -2
        # window has 3 entries -> F5=3, F7=102 (previous event's abs_mid_delta)
        {"seq": 2, "symbol_id": 0, "type": "quote", "bid": 101, "ask": 104,
         "bid_qty": 55, "ask_qty": 58, "gap": False},
        {"seq": 3, "symbol_id": 0, "type": "trade", "trade_side": 1, "gap": False},
        # mid = (99+103)>>1 = 101; delta = 101-102 = -1
        {"seq": 4, "symbol_id": 0, "type": "quote", "bid": 99, "ask": 103,
         "bid_qty": 40, "ask_qty": 70, "gap": False},
    ]
    seqs, mids, symbol_ids, sides, feats = ml_golden.extract_features(events)

    assert list(seqs) == [1, 2, 4]
    assert list(mids) == [102, 102, 101]
    assert list(symbol_ids) == [0, 0, 0]

    # Event seq=1: NOT first (CLEAR already was), F0=4, F1=102-0=102, F2=50-60=-10,
    # F3=50-0=50, F4=60-0=60, F6=0 (no trade yet), window has 2 entries -> F5=2, F7=102
    f0, f1, f2, f3, f4, f5, f6, f7 = feats[0]
    assert (f0, f1, f2, f3, f4, f6) == (4, 102, -10, 50, 60, 0)
    assert f5 == 2 and f7 == 102

    # Event seq=2: F0=3, F1=102-102=0, F2=55-58=-3, F3=55-50=5, F4=58-60=-2,
    # F6 still 0 (trade at seq=3 comes after this quote), window has 3 entries -> F5=3, F7=102
    f0, f1, f2, f3, f4, f5, f6, f7 = feats[1]
    assert (f0, f1, f2, f3, f4, f6) == (3, 0, -3, 5, -2, 0)
    assert f5 == 3 and f7 == 102

    # Event seq=4: comes after the trade_side=+1 at seq=3, so F6=1.
    # F0=4, F1=101-102=-1, F2=40-70=-30, F3=40-55=-15, F4=70-58=12
    # Window has 5 entries: CLEAR(0), seq=1(102), seq=2(0), seq=3_trade(0), seq=4(1) -> F5=4, F7=0+102+0+0+1=103
    f0, f1, f2, f3, f4, f5, f6, f7 = feats[2]
    assert (f0, f1, f2, f3, f4, f6) == (4, -1, -30, -15, 12, 1)
    assert f5 == 4 and f7 == 103


def test_labels_horizon_and_validity():
    mids = np.array([100, 101, 102, 99, 95, 95, 95])
    symbol_ids = np.array([0, 0, 0, 0, 0, 0, 0])
    y_buy, y_sell, valid = ml_golden.compute_labels(mids, symbol_ids, horizon_h=2)
    # t=0: mid[2]-mid[0] = 2  -> not <=-1, not >=1? it's >=1 -> y_sell=1
    assert valid[0] and y_sell[0] == 1 and y_buy[0] == 0
    # t=1: mid[3]-mid[1] = 99-101 = -2 -> y_buy=1
    assert valid[1] and y_buy[1] == 1 and y_sell[1] == 0
    # last `horizon_h` events have no valid future mid
    assert not valid[-1] and not valid[-2]


def test_clear_resets_state():
    """With FeatureEngine delegating to FeatureTracker (D52), a CLEAR event
    resets prev_bid/prev_ask/window to zero state and is itself treated as a
    'first event', so the next QUOTE computes deltas from zero. Window is
    preserved across CLEAR (not emptied)."""
    events = [
        {"seq": 0, "symbol_id": 0, "type": "quote", "bid": 100, "ask": 104,
         "bid_qty": 50, "ask_qty": 60, "gap": False},
        {"seq": 1, "symbol_id": 0, "type": "clear", "gap": False},
        {"seq": 2, "symbol_id": 0, "type": "quote", "bid": 200, "ask": 210,
         "bid_qty": 10, "ask_qty": 10, "gap": False},
    ]
    _, _, _, _, feats = ml_golden.extract_features(events)
    # After CLEAR, prev_bid/prev_ask are reset to 0, so the next QUOTE
    # computes f1/f3/f4 as deltas from zero (not f1/f3/f4=0).
    # f0 = 210 - 200 = 10, f1 = 205 - 0 = 205, f3 = 10 - 0 = 10, f4 = 10 - 0 = 10
    f0, f1, f2, f3, f4, f5, f6, f7 = feats[1]
    assert (f0, f1, f3, f4) == (10, 205, 10, 10)
    # Window should have 2 entries (CLEAR + this QUOTE)
    assert f5 == 2


def test_intended_side_buy_sell_and_no_signal():
    # default thresholds: min_spread=2, imb_shift=1 (master spec SS9 defaults)
    # buy: spread>=2 and bid_qty > ask_qty<<1
    assert ml_golden.intended_side(spread=2, bid_qty=201, ask_qty=100) == 1
    assert ml_golden.intended_side(spread=2, bid_qty=200, ask_qty=100) == 0  # not strictly >
    # sell: spread>=2 and ask_qty > bid_qty<<1
    assert ml_golden.intended_side(spread=2, bid_qty=100, ask_qty=201) == -1
    # spread too tight -> no signal even with a lopsided book
    assert ml_golden.intended_side(spread=1, bid_qty=1000, ask_qty=1) == 0
    # crossed/locked book (spread<=0) -> no signal
    assert ml_golden.intended_side(spread=0, bid_qty=1000, ask_qty=1) == 0
    assert ml_golden.intended_side(spread=-3, bid_qty=1000, ask_qty=1) == 0
    # balanced book, adequate spread -> no signal
    assert ml_golden.intended_side(spread=5, bid_qty=500, ask_qty=500) == 0


def test_extract_features_reports_sides():
    events = [
        {"seq": 0, "symbol_id": 0, "type": "clear", "gap": False},
        # spread=4, bid_qty=300 > ask_qty(100)<<1=200 -> buy signal
        {"seq": 1, "symbol_id": 0, "type": "quote", "bid": 100, "ask": 104,
         "bid_qty": 300, "ask_qty": 100, "gap": False},
        # spread=4, ask_qty=300 > bid_qty(100)<<1=200 -> sell signal
        {"seq": 2, "symbol_id": 0, "type": "quote", "bid": 100, "ask": 104,
         "bid_qty": 100, "ask_qty": 300, "gap": False},
        # balanced -> no signal
        {"seq": 3, "symbol_id": 0, "type": "quote", "bid": 100, "ask": 104,
         "bid_qty": 200, "ask_qty": 200, "gap": False},
    ]
    _, _, _, sides, _ = ml_golden.extract_features(events)
    assert list(sides) == [1, -1, 0]


def test_labels_do_not_cross_symbol_boundary():
    """mids[t+H] must never be read from a different symbol's series than
    mids[t] -- the pre-fix bug computed a 'label' from an unrelated
    instrument's freshly-reset price for the last H rows of every symbol."""
    import numpy as np
    import ml_golden

    # symbol 0: constant mid=100 for 10 events (no real move -> label 0)
    # symbol 1 starts immediately after with mid=100000 (huge jump) for 10 events
    mids = np.array([100] * 10 + [100000] * 10, dtype=np.int64)
    symbol_ids = np.array([0] * 10 + [1] * 10, dtype=np.int64)

    y_buy, y_sell, valid = ml_golden.compute_labels(mids, symbol_ids, horizon_h=5)

    # Rows 5..9 of symbol 0 would read mids[10..14] (symbol 1's huge jump) if
    # the boundary weren't respected -- they must be marked invalid instead.
    assert not valid[5:10].any(), "symbol-0 tail rows leaked into symbol 1's series"
    # Rows 0..4 of symbol 0 stay in-bounds within symbol 0 and are valid,
    # with a flat mid (no move) -> no buy/sell.
    assert valid[0:5].all()
    assert not y_buy[0:5].any() and not y_sell[0:5].any()


def test_hysteresis_resets_at_symbol_boundary():
    import numpy as np
    import ml_golden

    # symbol 0 ends in the adverse (high) state; symbol 1 starts with a
    # hold-zone score that should NOT inherit symbol 0's "already flagged"
    # state.
    z = np.array([0, 30, 30, 5, 5], dtype=np.int32)          # last two rows = symbol 1
    symbol_ids = np.array([0, 0, 0, 1, 1], dtype=np.int64)
    out = ml_golden.hysteresis_policy(z, symbol_ids, t_high=20, t_low=-20)

    assert out[2] == 1, "symbol 0 should be latched adverse after z=30"
    assert out[3] == 0, "symbol 1's first row (hold-zone z=5) must start at 0, not inherit symbol 0's state"


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__, "-v"]))
