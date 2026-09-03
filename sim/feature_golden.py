"""sim/feature_golden.py

Bit-exact Python reference for feature extraction (master spec S5.3, S6.4:
FR-20, FR-21, FR-24, FR-25) -- `rtl/feature_extractor.v`'s contract
(docs/contracts/feature_extractor.md) must match this bit-for-bit for every
accepted event, not just for a handful of hand-picked vectors. Written from
the spec directly, per S11.1's "golden models are written from the spec, not
the RTL." Deliberately narrow: it only takes (msg_type, side, bid/ask
price+qty+valid after this event's book update) per accepted (watched,
type/flags-valid, non-duplicate) event for one symbol -- it knows nothing
about md_parser/symbol_filter/seq_monitor plumbing, and is not wired into
GoldenModel (sim/golden_model.py) -- that integration is a later milestone,
same as golden_model.py's own module docstring says for gate 0x09.

--------------------------------------------------------------------------
Window semantics for F5/F7 -- pinned here, not left ambiguous (D13,
docs/design_decisions.md). The spec text alone under-specifies this;
ml_engineer_brief.md S4 says outright: "Decide whether the current event is
included in the window or not, and write it down." This is that write-down,
for the FPGA (RTL) side specifically -- the ML collaborator's model_config.json
makes the equivalent commitment for their own training pipeline, and the two
must agree (S5.5's hardware contract).

- One shared W-deep sliding window per symbol backs BOTH F5 and F7 -- not
  two independently-sized windows. The window advances on EVERY accepted
  event for that symbol, of ANY msg_type (QUOTE/CLEAR/TRADE/HEARTBEAT), not
  only book-modifying ones. Each slot holds that event's (is_update,
  abs_mid_delta): `is_update` = True only for book-modifying events
  (QUOTE/CLEAR, FR-19); `abs_mid_delta` = |F1| computed for that event (0
  for TRADE/HEARTBEAT, since mid does not change then, and 0 for the first
  event after a reset/clear -- see below).
- Why the window must include non-book-modifying events, not just
  book-modifying ones: F5 ("update rate... in the last W events") is only a
  meaningful, variable signal if "events" means *all* traffic and F5 counts
  the book-modifying fraction of it. If the window only ever held
  book-modifying events, F5 would trivially equal min(events-seen, W) --
  saturated at W almost immediately and useless as a feature, which
  contradicts the spec bothering to call it out as "clipped" (a clip that
  never varies isn't worth naming). Under the chosen reading, more
  trade/heartbeat traffic relative to quotes correctly lowers F5.
- F5 = count of is_update=True slots in the window. F7 = sum of
  abs_mid_delta over the window. Both computed over exactly the most recent
  `window` events (`window` in {4, 8, 16, 32}, S9 CSR `ML_WINDOW`, default
  16) -- the RTL's fixed-max-32-deep store services any of the four
  configured depths; this Python model just slices a deque.
- The *current* event's own (is_update, abs_mid_delta) is pushed into the
  window and reflected in that SAME event's F5/F7 output -- "the last W
  events" is read as "as of and including now." This applies even to
  trade/heartbeat events, which advance the window (for future F5/F7 reads)
  even though they don't themselves produce a feature-vector *output*
  (FR-20 computes/emits F0-F7 only after a book-modifying event).
- F1/F3/F4 = 0 on the first event for a symbol after reset, matching
  ml_engineer_brief.md S4's explicit rule ("hardware resets to zero; match
  it"). F7's contribution for that first event is therefore also 0
  (abs_mid_delta = |F1| = 0).
- A book-clear (FR-16, MSG_CLEAR) resets prev_bid/prev_ask/window to the
  same all-zero state as power-on, THEN is itself treated as exactly a
  "first event after reset" (S4's rule applies to it too) -- its own
  (is_update=True, abs_mid_delta=0) becomes the window's first post-reset
  entry, not a special clear-flavored entry.
- FR-26 (forcing the classifier input to a safe state when a side is
  invalid/crossed/gapped) is explicitly NOT this module's job -- see
  docs/contracts/feature_extractor.md Sec 5 (out of scope). Raw features are
  computed mechanically from whatever price/qty/valid state tob_engine
  presents, with no masking here.

Raw feature widths: 32-bit throughout (unsigned for F0/F5/F7, signed
two's-complement for F1/F2/F3/F4/F6), matching S9's ML_OFFSET_0..7/
ML_SHIFT_0..7 registers, which are already declared 32-bit -- there is no
other width commitment anywhere in the spec, so the offset-register width is
the one piece of concrete evidence to build on rather than inventing a
narrower width. F7 saturates (never wraps) at its 32-bit unsigned output.
`window` here is a fixed constructor argument (elaboration-time in the RTL
too, D13) -- not runtime-mutable -- specifically so F5/F7 can be recomputed
from scratch over the whole window on every event (a plain sum/popcount,
no incremental add-newest/subtract-oldest step, so there is nothing to get
wrong under saturation); see docs/contracts/feature_extractor.md Sec 2.6.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

MSG_QUOTE = 0x01
MSG_TRADE = 0x02
MSG_CLEAR = 0x03
MSG_HEARTBEAT = 0xFF

SIDE_BID = 0x00
SIDE_ASK = 0x01

RAW_UNSIGNED_MAX = (1 << 32) - 1
RAW_SIGNED_MIN = -(1 << 31)
RAW_SIGNED_MAX = (1 << 31) - 1

MAX_WINDOW = 32
VALID_WINDOWS = (4, 8, 16, 32)


def _sat_unsigned32(v: int) -> int:
    return max(0, min(v, RAW_UNSIGNED_MAX))


def _sat_signed32(v: int) -> int:
    return max(RAW_SIGNED_MIN, min(v, RAW_SIGNED_MAX))


@dataclass
class FeatureVector:
    f0_spread: int
    f1_mid_delta: int
    f2_imbalance: int
    f3_bid_chg: int
    f4_ask_chg: int
    f5_update_rate: int
    f6_last_trade_dir: int
    f7_volatility: int

    def as_tuple(self):
        return (
            self.f0_spread,
            self.f1_mid_delta,
            self.f2_imbalance,
            self.f3_bid_chg,
            self.f4_ask_chg,
            self.f5_update_rate,
            self.f6_last_trade_dir,
            self.f7_volatility,
        )


@dataclass
class SymbolFeatureState:
    """Per-symbol feature history (FR-21). Reset state == power-on state ==
    post-clear state, deliberately (D13)."""

    prev_bid: int = 0
    prev_ask: int = 0
    prev_bid_qty: int = 0
    prev_ask_qty: int = 0
    last_trade_dir: int = 0  # F6: 0 = none, +1 = buy, -1 = sell
    window: deque = field(default_factory=lambda: deque(maxlen=MAX_WINDOW))
    seen_first_event: bool = False

    def reset(self) -> None:
        self.prev_bid = 0
        self.prev_ask = 0
        self.prev_bid_qty = 0
        self.prev_ask_qty = 0
        self.last_trade_dir = 0
        self.window.clear()
        self.seen_first_event = False


class FeatureTracker:
    """Owns one SymbolFeatureState per symbol_id; mirrors feature_extractor.v
    driving NUM_SYMBOLS independent per-slot state sets (D13/FR-21)."""

    def __init__(self, window: int = 16):
        if window not in VALID_WINDOWS:
            raise ValueError(f"window must be one of {VALID_WINDOWS}, got {window}")
        self.window = window
        self._states: dict[int, SymbolFeatureState] = {}

    def _state(self, symbol_id: int) -> SymbolFeatureState:
        if symbol_id not in self._states:
            self._states[symbol_id] = SymbolFeatureState()
        return self._states[symbol_id]

    def _active_window(self, st: SymbolFeatureState):
        return list(st.window)[-self.window :]

    def on_trade(self, symbol_id: int, side: int) -> None:
        """FR-25: trade print updates F6 (aggressor side), does not touch
        book price/qty, and pushes a (is_update=False, abs_delta=0) slot
        into the shared window (advances it for future F5/F7 reads) without
        itself producing a feature-vector output -- see module docstring
        and docs/contracts/feature_extractor.md Sec 2.4."""
        st = self._state(symbol_id)
        st.last_trade_dir = 1 if side == SIDE_BID else -1
        st.window.append((False, 0))

    def on_heartbeat(self, symbol_id: int) -> None:
        """FR-19: heartbeat refreshes staleness only (tob_engine's concern,
        not this module's); pushes a (False, 0) slot into the shared
        window, same as on_trade, for the same reason -- it is still an
        "event" for F5's denominator even though it changes nothing about
        the book or F6."""
        st = self._state(symbol_id)
        st.window.append((False, 0))

    def on_book_event(
        self,
        symbol_id: int,
        msg_type: int,
        bid_price: int,
        bid_qty: int,
        bid_valid: bool,
        ask_price: int,
        ask_qty: int,
        ask_valid: bool,
    ) -> FeatureVector:
        """FR-20: compute F0-F7 after a book-modifying event (QUOTE or
        CLEAR) for `symbol_id`, using the book state AFTER this event was
        applied (tob_engine's committed values -- caller's responsibility to
        pass post-update state, not pre-update)."""
        assert msg_type in (MSG_QUOTE, MSG_CLEAR)
        st = self._state(symbol_id)

        if msg_type == MSG_CLEAR:
            st.reset()  # D13: clear == "first event after reset"

        first_event = not st.seen_first_event
        st.seen_first_event = True

        f0 = _sat_unsigned32(ask_price - bid_price)  # no "prev" dependency
        f2 = _sat_signed32(bid_qty - ask_qty)  # no "prev" dependency

        if first_event:
            f1 = 0
            f3 = 0
            f4 = 0
        else:
            mid = (bid_price + ask_price) >> 1
            prev_mid = (st.prev_bid + st.prev_ask) >> 1
            f1 = _sat_signed32(mid - prev_mid)
            f3 = _sat_signed32(bid_qty - st.prev_bid_qty)
            f4 = _sat_signed32(ask_qty - st.prev_ask_qty)

        st.window.append((True, abs(f1)))

        active = self._active_window(st)
        f5 = sum(1 for is_upd, _ in active if is_upd)
        f7 = _sat_unsigned32(sum(d for _, d in active))
        f6 = st.last_trade_dir

        st.prev_bid = bid_price
        st.prev_ask = ask_price
        st.prev_bid_qty = bid_qty
        st.prev_ask_qty = ask_qty

        return FeatureVector(f0, f1, f2, f3, f4, f5, f6, f7)
