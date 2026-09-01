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
    out = ml_golden.hysteresis_policy(z, t_high=10, t_low=3)
    # rises to 1 once z hits 15 (idx2), stays 1 through idx3 (15) and idx4 (4,
    # above t_low), drops at idx5 (2 <= t_low), rises again at idx6 (15).
    assert list(out) == [0, 0, 1, 1, 1, 0, 1, 0]


def test_feature_extraction_hand_computed_case():
    """A small, hand-computed sequence (roadmap Step 4). Verifies F0-F7
    against manually worked-out values for the first few quote events."""
    events = [
        {"seq": 0, "symbol_id": 0, "type": "clear", "gap": False},
        # mid = (100+104)>>1 = 102; first event -> F1=F3=F4=F7=0, F6=0 (no trade yet)
        {"seq": 1, "symbol_id": 0, "type": "quote", "bid": 100, "ask": 104,
         "bid_qty": 50, "ask_qty": 60, "gap": False},
        # mid = (101+104)>>1 = 102 (unsigned floor); delta = 102-102 = 0
        {"seq": 2, "symbol_id": 0, "type": "quote", "bid": 101, "ask": 104,
         "bid_qty": 55, "ask_qty": 58, "gap": False},
        {"seq": 3, "symbol_id": 0, "type": "trade", "trade_side": 1, "gap": False},
        # mid = (99+103)>>1 = 101; delta = 101-102 = -1
        {"seq": 4, "symbol_id": 0, "type": "quote", "bid": 99, "ask": 103,
         "bid_qty": 40, "ask_qty": 70, "gap": False},
    ]
    seqs, mids, feats = ml_golden.extract_features(events)

    assert list(seqs) == [1, 2, 4]
    assert list(mids) == [102, 102, 101]

    # Event seq=1 (first quote ever for this symbol): F0=4, F1=0, F2=50-60=-10,
    # F3=0, F4=0, F6=0 (no trade seen yet), window has 1 entry -> F5=1, F7=0.
    f0, f1, f2, f3, f4, f5, f6, f7 = feats[0]
    assert (f0, f1, f2, f3, f4, f6) == (4, 0, -10, 0, 0, 0)
    assert f5 == 1 and f7 == 0

    # Event seq=2: F0=3, F1=102-102=0, F2=55-58=-3, F3=55-50=5, F4=58-60=-2,
    # F6 still 0 (trade at seq=3 comes after this quote).
    f0, f1, f2, f3, f4, f5, f6, f7 = feats[1]
    assert (f0, f1, f2, f3, f4, f6) == (3, 0, -3, 5, -2, 0)

    # Event seq=4: comes after the trade_side=+1 at seq=3, so F6=1.
    # F0=4, F1=101-102=-1, F2=40-70=-30, F3=40-55=-15, F4=70-58=12.
    f0, f1, f2, f3, f4, f5, f6, f7 = feats[2]
    assert (f0, f1, f2, f3, f4, f6) == (4, -1, -30, -15, 12, 1)


def test_labels_horizon_and_validity():
    mids = np.array([100, 101, 102, 99, 95, 95, 95])
    y_buy, y_sell, valid = ml_golden.compute_labels(mids, horizon_h=2)
    # t=0: mid[2]-mid[0] = 2  -> not <=-1, not >=1? it's >=1 -> y_sell=1
    assert valid[0] and y_sell[0] == 1 and y_buy[0] == 0
    # t=1: mid[3]-mid[1] = 99-101 = -2 -> y_buy=1
    assert valid[1] and y_buy[1] == 1 and y_sell[1] == 0
    # last `horizon_h` events have no valid future mid
    assert not valid[-1] and not valid[-2]


def test_clear_resets_state():
    events = [
        {"seq": 0, "symbol_id": 0, "type": "quote", "bid": 100, "ask": 104,
         "bid_qty": 50, "ask_qty": 60, "gap": False},
        {"seq": 1, "symbol_id": 0, "type": "clear", "gap": False},
        {"seq": 2, "symbol_id": 0, "type": "quote", "bid": 200, "ask": 210,
         "bid_qty": 10, "ask_qty": 10, "gap": False},
    ]
    _, _, feats = ml_golden.extract_features(events)
    # After the clear, the next quote must look like a "first ever" event:
    # F1=F3=F4=0.
    f0, f1, f2, f3, f4, f5, f6, f7 = feats[1]
    assert (f1, f3, f4) == (0, 0, 0)


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__, "-v"]))
