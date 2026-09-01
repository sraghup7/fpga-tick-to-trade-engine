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

from collections import deque
from dataclasses import dataclass, field

import numpy as np

import config

NUM_FEATURES = config.NUM_FEATURES


# ---------------------------------------------------------------------------
# SS4: feature extraction
# ---------------------------------------------------------------------------


@dataclass
class _SymbolState:
    """Per-symbol running state needed to compute F0-F7 incrementally.

    Reset to these defaults on construction and on a 'clear' event -- this is
    the brief's required initial-state convention (SS4): before the first
    update, F1=F3=F4=F7=0 and last-trade-direction is 0 (none).
    """

    prev_mid: int | None = None
    prev_bid_qty: int | None = None
    prev_ask_qty: int | None = None
    last_trade_dir: int = 0
    # Sliding window of the last WINDOW_W events: (is_book_update, abs_mid_delta)
    window: deque = field(default_factory=lambda: deque(maxlen=config.WINDOW_W))


class FeatureEngine:
    """Stateful, per-symbol feature extractor. One instance covers the whole
    stream; call `process(event)` for every event in sequence-number order.

    Only 'quote' events produce a feature row (they are the "quote decision"
    points the brief's features and labels are defined at). 'trade' events
    update F6 state only; 'clear' events reset a symbol's state entirely.
    """

    def __init__(self, window_w: int = config.WINDOW_W):
        self._window_w = window_w
        self._states: dict[int, _SymbolState] = {}

    def _state(self, symbol_id: int) -> _SymbolState:
        if symbol_id not in self._states:
            self._states[symbol_id] = _SymbolState(
                window=deque(maxlen=self._window_w)
            )
        return self._states[symbol_id]

    def process(self, event: dict) -> tuple[int, ...] | None:
        """Feed one event. Returns an (F0..F7) tuple for 'quote' events,
        None for 'trade'/'clear' events (no decision point)."""
        symbol_id = event["symbol_id"]
        st = self._state(symbol_id)

        if event["type"] == "clear":
            self._states[symbol_id] = _SymbolState(
                window=deque(maxlen=self._window_w)
            )
            return None

        if event["type"] == "trade":
            st.last_trade_dir = event["trade_side"]
            return None

        assert event["type"] == "quote"
        bid, ask = event["bid"], event["ask"]
        bid_qty, ask_qty = event["bid_qty"], event["ask_qty"]
        mid = (bid + ask) >> 1  # integer mid everywhere, floor (brief SS4)

        f0 = ask - bid

        if st.prev_mid is None:
            f1 = 0
        else:
            f1 = mid - st.prev_mid

        f2 = bid_qty - ask_qty

        f3 = 0 if st.prev_bid_qty is None else bid_qty - st.prev_bid_qty
        f4 = 0 if st.prev_ask_qty is None else ask_qty - st.prev_ask_qty

        f6 = st.last_trade_dir

        abs_delta = abs(f1)
        # WINDOW_INCLUDES_CURRENT: the event being processed right now is
        # pushed into the window before F5/F7 are read off it (brief SS4).
        if config.WINDOW_INCLUDES_CURRENT:
            st.window.append((1, abs_delta))
            window_items = st.window
        else:
            window_items = list(st.window)
            st.window.append((1, abs_delta))

        f5 = sum(is_update for is_update, _ in window_items)
        f7 = sum(d for _, d in window_items)

        f5 = min(f5, config.RAW_FEATURE_CLIP)
        f7 = min(f7, config.RAW_FEATURE_CLIP)

        st.prev_mid = mid
        st.prev_bid_qty = bid_qty
        st.prev_ask_qty = ask_qty

        return (f0, f1, f2, f3, f4, f5, f6, f7)


def extract_features(events: list[dict]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Run the FeatureEngine over a full event stream.

    Returns:
      seqs     : int array, shape (N,) -- sequence number of each quote event
      mids     : int array, shape (N,) -- integer mid price at each quote event
      features : int array, shape (N, 8) -- raw (pre-normalization) F0..F7
    """
    engine = FeatureEngine()
    seqs, mids, feats = [], [], []
    for event in events:
        result = engine.process(event)
        if result is None:
            continue
        seqs.append(event["seq"])
        bid, ask = event["bid"], event["ask"]
        mids.append((bid + ask) >> 1)
        feats.append(result)
    return np.array(seqs, dtype=np.int64), np.array(mids, dtype=np.int64), np.array(
        feats, dtype=np.int64
    )


# ---------------------------------------------------------------------------
# SS5: label definition
# ---------------------------------------------------------------------------


def compute_labels(
    mids: np.ndarray, horizon_h: int = config.LABEL_HORIZON_H
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """y_buy[t] = 1 if mid[t+H] - mid[t] <= -1 else 0
       y_sell[t] = 1 if mid[t+H] - mid[t] >= +1 else 0

    Events within H of the end of the stream have no valid future mid; their
    `valid` flag is False and y_buy/y_sell are 0 (excluded from training/eval,
    never treated as a real negative label).
    """
    n = len(mids)
    y_buy = np.zeros(n, dtype=np.int8)
    y_sell = np.zeros(n, dtype=np.int8)
    valid = np.zeros(n, dtype=bool)
    for t in range(n - horizon_h):
        delta = int(mids[t + horizon_h]) - int(mids[t])
        y_buy[t] = 1 if delta <= -1 else 0
        y_sell[t] = 1 if delta >= 1 else 0
        valid[t] = True
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
    seqs, mids, raw_feats = extract_features(events)
    y_buy, y_sell, valid = compute_labels(mids, config.LABEL_HORIZON_H)
    print(f"quote events with features: {len(seqs)}")
    print(f"labeled (valid) events: {valid.sum()} / {len(valid)}")
    print("first 5 raw feature rows (F0..F7):")
    for row in raw_feats[:5]:
        print(" ", row.tolist())
