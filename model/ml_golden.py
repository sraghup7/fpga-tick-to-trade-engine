"""Fixed-point golden reference for feature extraction, labeling, normalization,
and classification (ml_engineer_brief.md SS4, SS5, SS7).

This file *is* the specification of the arithmetic: whatever it computes, the
RTL (feature_extractor.v, feature_normalizer.v, ml_classifier_wrap.v,
ml_policy.v) must reproduce bit-for-bit. Two rules make that possible:

  1. Every shift is an arithmetic right shift that floors toward -infinity
     (np.right_shift on a signed numpy int array), never Python's `//` or
     `int(v / 2**s)` -- those truncate toward zero and disagree with hardware
     on negative values (brief SS7.2, pitfall #1).
  2. Every saturation clamps into range; it never wraps (brief SS7.2).

No floating point appears anywhere in this file except inside
train_baseline-style code that calls into this module -- feature extraction,
normalization, and the score itself are pure integer arithmetic.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import numpy as np

import config

NUM_FEATURES = config.NUM_FEATURES

# ---------------------------------------------------------------------------
# SS4: feature extraction -- delegates to sim/feature_golden.py, the RTL's
# own bit-exact reference (docs/design_decisions.md D52). Loaded via
# importlib rather than `sys.path` + `import` so this file never collides
# with sim/ml_golden.py's own module name, and so model/ never needs to
# become a package or add sim/ to sys.path globally.
# ---------------------------------------------------------------------------
import sys

_REPO_ROOT = Path(__file__).resolve().parent.parent
_fg_spec = importlib.util.spec_from_file_location(
    "_rtl_feature_golden", _REPO_ROOT / "sim" / "feature_golden.py"
)
_rtl_feature_golden = importlib.util.module_from_spec(_fg_spec)
sys.modules["_rtl_feature_golden"] = _rtl_feature_golden
_fg_spec.loader.exec_module(_rtl_feature_golden)

_FeatureTracker = _rtl_feature_golden.FeatureTracker
_MSG_QUOTE = _rtl_feature_golden.MSG_QUOTE
_MSG_CLEAR = _rtl_feature_golden.MSG_CLEAR
_SIDE_BID = _rtl_feature_golden.SIDE_BID
_SIDE_ASK = _rtl_feature_golden.SIDE_ASK

assert config.WINDOW_INCLUDES_CURRENT, (
    "sim/feature_golden.py always includes the current event in the window "
    "(D13, pinned) -- config.WINDOW_INCLUDES_CURRENT=False is no longer a "
    "supported mode now that FeatureEngine delegates to it."
)


class FeatureEngine:
    """Stateful, per-symbol feature extractor. Thin adapter around
    sim.feature_golden.FeatureTracker -- the RTL's own bit-exact feature
    extraction reference -- so model/ and rtl/feature_extractor.v compute
    F0..F7 from the IDENTICAL implementation instead of two independently
    maintained (and, before D52, independently buggy) copies.

    Only 'quote' events produce a feature row; 'trade' events update F6 and
    advance the shared window; 'clear' events reset a symbol's state.
    """

    def __init__(self, window_w: int = config.WINDOW_W):
        self._tracker = _FeatureTracker(window=window_w)

    def process(self, event: dict) -> tuple[int, ...] | None:
        symbol_id = event["symbol_id"]

        if event["type"] == "clear":
            # Call on_book_event to reset state and advance the window, but
            # don't return the feature vector (CLEAR events don't produce
            # output rows in the training data).
            self._tracker.on_book_event(
                symbol_id, _MSG_CLEAR,
                bid_price=0, bid_qty=0, bid_valid=True,
                ask_price=0, ask_qty=0, ask_valid=True,
            )
            return None

        if event["type"] == "trade":
            side = _SIDE_BID if event["trade_side"] == 1 else _SIDE_ASK
            self._tracker.on_trade(symbol_id, side)
            return None

        assert event["type"] == "quote"
        fv = self._tracker.on_book_event(
            symbol_id, _MSG_QUOTE,
            bid_price=event["bid"], bid_qty=event["bid_qty"], bid_valid=True,
            ask_price=event["ask"], ask_qty=event["ask_qty"], ask_valid=True,
        )
        f0, f1, f2, f3, f4, f5, f6, f7 = fv.as_tuple()
        # Raw-domain clip (brief SS4), independent of sim/feature_golden.py's
        # own 32-bit saturation -- kept from the original model/ code.
        f5 = min(f5, config.RAW_FEATURE_CLIP)
        f7 = min(f7, config.RAW_FEATURE_CLIP)
        return (f0, f1, f2, f3, f4, f5, f6, f7)


def intended_side(
    spread: int,
    bid_qty: int,
    ask_qty: int,
    min_spread: int = config.CFG_MIN_SPREAD,
    imb_shift: int = config.CFG_IMB_SHIFT,
) -> int:
    """The master spec's actual signal rule (FR-35/FR-36/FR-37, SS6.6):
    +1 = buy, -1 = sell, 0 = no signal at this event.

    buy:  spread >= min_spread  and  bid_qty > (ask_qty << imb_shift)
    sell: spread >= min_spread  and  ask_qty > (bid_qty << imb_shift)

    Since min_spread >= 1 in any sane config, `spread < min_spread` already
    rejects a crossed/locked book (spread <= 0) and an uninitialized 0/0 book
    along with any spread that's merely too tight -- all are "not a valid,
    non-crossed book with adequate spread" per FR-35's precondition, so one
    comparison covers all three. FR-37 says both conditions firing at once is
    impossible by construction; we still guard it defensively as no-signal
    rather than trust that invariant blindly.
    """
    if spread < min_spread:
        return 0
    buy = bid_qty > (ask_qty << imb_shift)
    sell = ask_qty > (bid_qty << imb_shift)
    if buy and sell:
        return 0
    if buy:
        return 1
    if sell:
        return -1
    return 0


def extract_features(
    events: list[dict],
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Run the FeatureEngine over a full event stream.

    Returns:
      seqs      : int array, shape (N,) -- sequence number of each quote event
      mids      : int array, shape (N,) -- integer mid price at each quote event
      symbol_ids: int array, shape (N,) -- symbol_id of each quote event
      sides     : int8 array, shape (N,) -- intended_side() at each quote event
      features  : int array, shape (N, 8) -- raw (pre-normalization) F0..F7
    """
    engine = FeatureEngine()
    seqs, mids, symbol_ids, sides, feats = [], [], [], [], []
    for event in events:
        result = engine.process(event)
        if result is None:
            continue
        seqs.append(event["seq"])
        bid, ask = event["bid"], event["ask"]
        mids.append((bid + ask) >> 1)
        symbol_ids.append(event["symbol_id"])
        sides.append(intended_side(result[0], event["bid_qty"], event["ask_qty"]))
        feats.append(result)
    return (
        np.array(seqs, dtype=np.int64),
        np.array(mids, dtype=np.int64),
        np.array(symbol_ids, dtype=np.int64),
        np.array(sides, dtype=np.int8),
        np.array(feats, dtype=np.int64),
    )


# ---------------------------------------------------------------------------
# SS5: label definition
# ---------------------------------------------------------------------------


def compute_labels(
    mids: np.ndarray, symbol_ids: np.ndarray, horizon_h: int = config.LABEL_HORIZON_H
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """y_buy[t] = 1 if mid[t+H] - mid[t] <= -1 else 0
       y_sell[t] = 1 if mid[t+H] - mid[t] >= +1 else 0

    A row is `valid` only if both an in-horizon future row exists AND that
    future row belongs to the SAME symbol_id -- the dataset is many symbols'
    scenarios concatenated back-to-back (simulator.generate_dataset), so
    without the symbol check the lookahead for the last `horizon_h` rows of
    every symbol would silently read a different, unrelated instrument's
    freshly-reset price series (docs/design_decisions.md D52).
    """
    n = len(mids)
    mids = np.asarray(mids, dtype=np.int64)
    symbol_ids = np.asarray(symbol_ids)
    y_buy = np.zeros(n, dtype=np.int8)
    y_sell = np.zeros(n, dtype=np.int8)
    valid = np.zeros(n, dtype=bool)
    if n > horizon_h:
        delta = mids[horizon_h:] - mids[:-horizon_h]
        same_symbol = symbol_ids[horizon_h:] == symbol_ids[:-horizon_h]
        y_buy[:-horizon_h] = np.where(same_symbol & (delta <= -1), 1, 0)
        y_sell[:-horizon_h] = np.where(same_symbol & (delta >= 1), 1, 0)
        valid[:-horizon_h] = same_symbol
    return y_buy, y_sell, valid


# ---------------------------------------------------------------------------
# SS7.2: normalization (raw int -> int8), and SS7.1: classification (int8 -> int32)
# ---------------------------------------------------------------------------


def normalize(
    raw: np.ndarray, offsets: np.ndarray, shifts: np.ndarray
) -> np.ndarray:
    """x_i = saturate_[-128,127]( (raw_i - offset_i) >> shift_i )

    `>>` is an arithmetic right shift that floors toward -infinity, matching
    Verilog's `>>>` on signed operands. np.right_shift on a signed numpy int
    dtype has exactly this behavior -- do not replace with `//` or `/`.
    """
    raw = np.asarray(raw, dtype=np.int64)
    offsets = np.asarray(offsets, dtype=np.int64)
    shifts = np.asarray(shifts, dtype=np.int64)
    diff = raw - offsets
    shifted = np.right_shift(diff, shifts)
    return np.clip(shifted, config.FEATURE_MIN, config.FEATURE_MAX).astype(np.int8)


def classify(x_int8: np.ndarray, weights: np.ndarray, bias: int) -> np.ndarray:
    """z = b + sum_i w_i * x_i, computed with an int32 accumulator.

    Products (int8 * int8) fit comfortably in int16; the 8-term sum plus bias
    fits comfortably in int32 (brief SS7.1: max |sum of products| = 131072).
    We accumulate in int64 to make the "no silent truncation" requirement
    explicit, then assert the result actually fits in int32 before casting.
    """
    x = np.asarray(x_int8, dtype=np.int64)
    w = np.asarray(weights, dtype=np.int64)
    products = x * w  # would be int16 in hardware; int64 here just to inspect
    assert np.all(np.abs(products) <= 32767), "product overflowed int16 budget"
    z = products.sum(axis=-1) + np.int64(bias)
    int32_min, int32_max = -(2**31), 2**31 - 1
    assert np.all((z >= int32_min) & (z <= int32_max)), "z overflowed int32 accumulator"
    return z.astype(np.int32)


def hysteresis_policy(z: np.ndarray, t_high: int, t_low: int) -> np.ndarray:
    """Recommended ml_policy.v behavior (Schmitt trigger): adverse_risk goes
    high once z >= t_high and stays high until z <= t_low. RTL implements the
    actual gate; this is only the reference used to pick/evaluate thresholds.
    """
    out = np.zeros(len(z), dtype=np.int8)
    state = 0
    for i, zi in enumerate(z):
        if state == 0 and zi >= t_high:
            state = 1
        elif state == 1 and zi <= t_low:
            state = 0
        out[i] = state
    return out


if __name__ == "__main__":
    import simulator

    events = simulator.generate_dataset()
    seqs, mids, symbol_ids, sides, raw_feats = extract_features(events)
    y_buy, y_sell, valid = compute_labels(mids, symbol_ids, config.LABEL_HORIZON_H)
    print(f"quote events with features: {len(seqs)}")
    print(f"labeled (valid) events: {valid.sum()} / {len(valid)}")
    print(f"events with a trading signal (side != 0): {(sides != 0).sum()} / {len(sides)}")
    print("first 5 raw feature rows (F0..F7):")
    for row in raw_feats[:5]:
        print(" ", row.tolist())
