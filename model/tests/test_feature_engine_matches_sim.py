"""Regression guard: model/ml_golden.py's FeatureEngine must produce the
IDENTICAL F0..F7 sequence as sim/feature_golden.py's FeatureTracker (the
RTL's bit-exact reference) on the same event stream -- this is the fix for
docs/design_decisions.md D52 (the window/clear bugs found in the 2026-09-09
review existed only because model/ reimplemented this logic independently).
"""
import os
import sys

MODEL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(MODEL_DIR)
sys.path.insert(0, MODEL_DIR)
sys.path.insert(0, REPO_ROOT)

import ml_golden  # noqa: E402
from sim import feature_golden as rtl_fg  # noqa: E402


def test_trade_and_clear_advance_window_like_rtl():
    """A trade event must occupy a window slot (F5 must drop after enough
    trades), and a clear must seed the window with one post-reset entry
    (not leave it empty) -- both were bugs in the pre-fix FeatureEngine."""
    events = [
        {"type": "clear", "symbol_id": 1},
        {"type": "quote", "symbol_id": 1, "bid": 100, "ask": 102, "bid_qty": 10, "ask_qty": 10},
        {"type": "trade", "symbol_id": 1, "trade_side": 1},
        {"type": "trade", "symbol_id": 1, "trade_side": -1},
        {"type": "quote", "symbol_id": 1, "bid": 101, "ask": 103, "bid_qty": 11, "ask_qty": 9},
    ]

    engine = ml_golden.FeatureEngine(window_w=4)
    got = [engine.process(e) for e in events]

    tracker = rtl_fg.FeatureTracker(window=4)
    want = []
    want.append(tracker.on_book_event(1, rtl_fg.MSG_CLEAR, 0, 0, True, 0, 0, True) and None)
    fv1 = tracker.on_book_event(1, rtl_fg.MSG_QUOTE, 100, 10, True, 102, 10, True)
    want.append(fv1.as_tuple())
    tracker.on_trade(1, rtl_fg.SIDE_BID)
    want.append(None)
    tracker.on_trade(1, rtl_fg.SIDE_ASK)
    want.append(None)
    fv2 = tracker.on_book_event(1, rtl_fg.MSG_QUOTE, 101, 11, True, 103, 9, True)
    want.append(fv2.as_tuple())

    assert got == want
    # With window_w=4 and 5 events pushed (clear, quote, trade, trade, quote),
    # the last quote's F5 counts is_update slots among the last 4 pushed:
    # [quote(True), trade(False), trade(False), quote(True)] -> F5 == 2, not 4.
    assert got[-1][5] == 2


def test_clear_reseeds_window_not_empties_it():
    """First quote after a clear must see F5=2 (clear's own post-reset
    (True,0) entry + this quote's own entry), matching sim/feature_golden.py
    D13, not F5=1 (the pre-fix bug)."""
    events = [
        {"type": "clear", "symbol_id": 5},
        {"type": "quote", "symbol_id": 5, "bid": 50, "ask": 52, "bid_qty": 1, "ask_qty": 1},
    ]
    engine = ml_golden.FeatureEngine(window_w=16)
    got = [engine.process(e) for e in events]
    assert got[1][5] == 2


if __name__ == "__main__":
    test_trade_and_clear_advance_window_like_rtl()
    test_clear_reseeds_window_not_empties_it()
    print("PASS")
