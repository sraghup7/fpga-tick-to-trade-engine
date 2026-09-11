"""sim/golden_model.py

Bit-exact Python reference for the full tick-to-trade datapath, written
from fpga_tick_to_trade_master_spec.md directly -- not derived from any
RTL (master spec S11.1, fpga_project_flow.md Stage 3: a model derived from
the RTL can only confirm the RTL matches itself).

Scope: the full deterministic path -- ingress framing (S4), filtering (S6.2),
book state (S6.3), the spread/imbalance signal (S6.6), and risk gates
0x01-0x08 (S8.2). Gate 0x09 (ML) is an injectable input (`adverse_risk` per
message), not computed here: feature extraction, normalization, and the
classifier are the ML collaborator's `ml_golden.py` (division of
responsibility table, ml_engineer_brief.md S11). Wiring gate 0x09 to a real
feature/classifier pipeline is S6 work, not S1.

Integer arithmetic throughout. No floats anywhere -- prices and quantities
are integer ticks (CLAUDE.md hard convention). Every FR-n/NFR-n this module
implements is cited in the relevant docstring/comment for traceability
(AGENTS.md / CLAUDE.md spec convention: every requirement maps to a test).
"""

from __future__ import annotations

import struct
from collections import defaultdict, deque
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------
# Wire format constants (S4.3, S4.5)
# ---------------------------------------------------------------------

MSG_QUOTE = 0x01
MSG_TRADE = 0x02
MSG_CLEAR = 0x03
MSG_HEARTBEAT = 0xFF
VALID_MSG_TYPES = (MSG_QUOTE, MSG_TRADE, MSG_CLEAR, MSG_HEARTBEAT)

# S9 CSR frame types (D19, csr_ingress_separation.md): they share md_parser's
# byte stream by design but are NOT market data. process_message returns
# before any counter/seq side effect for them, mirroring rtl/md_parser.v,
# which now recognizes these types so err_msg_type never fires for them.
CSR_FRAME_TYPES = (0x20, 0x21)

SIDE_BID = 0x00
SIDE_ASK = 0x01

FLAG_END_OF_BURST = 0x01
FLAG_SNAPSHOT = 0x02
FLAG_RESERVED_MASK = 0xFC  # bits 7:2 must be 0 (FR-9)

ORDER_MSG_NEW = 0x10
ORDER_MSG_REJECT = 0x11
ORDER_MSG_STATS = 0x12

# Risk gate IDs (S8.2) -- also used as reject_reason values (S4.5)
GATE_KILL = 0x01
GATE_SIZE = 0x02
GATE_POSITION = 0x03
GATE_BAND = 0x04
GATE_STALE = 0x05
GATE_SEQGAP = 0x06
GATE_CROSSED = 0x07
GATE_THROTTLE = 0x08
GATE_ML = 0x09
GATE_NAME = {
    GATE_KILL: "cnt_rej_kill",
    GATE_SIZE: "cnt_rej_size",
    GATE_POSITION: "cnt_rej_position",
    GATE_BAND: "cnt_rej_band",
    GATE_STALE: "cnt_rej_stale",
    GATE_SEQGAP: "cnt_rej_seqgap",
    GATE_CROSSED: "cnt_rej_crossed",
    GATE_THROTTLE: "cnt_rej_throttle",
    GATE_ML: "cnt_rej_ml",
}

# ---------------------------------------------------------------------
# Provisional timing constants -- replace with the measured values once
# real RTL exists and S12.1's tables are filled in. Single named constants
# so that update is one line, not a search-and-replace.
# ---------------------------------------------------------------------

# NFR-1: fixed constant for every accepting message, target <=22, engine
# total target ~10-11 (S7.1 table). Not measured yet -- using the target.
TICK_TO_TRADE_CYCLES = 11

# D51: measured directly against tb_top.v's actual simulated TX path
# (rtl/eth_mac_if.v driving tb/sim_models/tob_top_sim_leaves.v's mock
# mac_top -- the environment every current consumer of this constant is
# checked against), not derived from a full real-Ethernet-frame estimate.
# Instrumented tx_start -> mac_send_end directly: exactly 26 cycles, 10/10
# samples, zero variance (TX_REQ 1 + TX_WAIT 7 + TX_PUSH 16 bytes +
# TX_DRAIN's 1-2 cycles of mock-capture latency, rtl/eth_mac_if.v:176-247).
# The previous value (84, "16-byte order frame, 8 bits/cycle serialization
# plus framing overhead") was a real-board full-Ethernet-frame estimate
# (preamble+MAC+IP+UDP headers+FCS+IFG) that this repo has never actually
# simulated end-to-end -- S11 is bitstream-only, no hardware bring-up yet.
# Using it here overstated how long this testbench's TX queue stays busy by
# >3x, which never mattered while accepted orders were rare (a few per
# soak) but badly over-predicted cnt_order_overflow once reject-report
# frames were also correctly modeled as sharing the same queue (found
# extending tb_top's soak from 209 to 5,000 messages, docs/design_decisions.md
# D51). If a real-MAC (non-mock) integration test is ever added, IT needs
# its own measured constant -- don't assume this one still applies.
#
# A follow-up measurement found the real BACK-TO-BACK tx_start-to-tx_start
# interval (when a second item is already queued) is 28 cycles, not 26 --
# tx_busy drops one cycle after mac_send_end, and order_builder's own
# tx_start output is registered one more cycle after that. Using 28 here
# was tried and made overflow prediction WORSE (46 vs 11 real, further from
# ground truth than 26's 15 vs 11) -- the system is close enough to a
# stability boundary (service time vs. MSG_ARRIVAL_CYCLES=23) that this
# model's simplified single-server queue is NOT simply "closer to
# real cycle counts is closer to correct" here. Left at 26 (empirically
# the better match of the two measured candidates) with this discrepancy
# recorded as a known, not-fully-understood residual -- see D51.
ORDER_TX_CYCLES = 26

# A caller that doesn't pass arrival_cycle is saying "advance time a little,
# exact pacing doesn't matter to this test" -- every existing such caller
# (test_golden_model_handcase.py's `m`-sequence cases) is testing something
# unrelated to TX-egress timing (symbol filtering, sequence tracking,
# crossed-book handling, snapshot recovery, ...), not real max-rate ingress.
# D51: this MUST stay strictly greater than ORDER_TX_CYCLES (26) -- at the
# NFR-4 literal max-rate value this used to be (16, "max sustained rate for
# a 16-byte message on an 8-bit/cycle link"), a run of implicit-timing calls
# that happen to produce several accepted-or-rejected intents in a row can
# still have an earlier one occupying the shared 2-deep TX queue
# (rtl/order_builder.v:139-159) when a later one arrives, causing an
# UNINTENDED cnt_order_overflow that has nothing to do with what the test
# is actually exercising (found the hard way: fixing reject-report frames
# to correctly share that queue, below, broke several `m`-sequence cases
# this way before this constant was widened). A test that deliberately
# wants to exercise real TX-egress/queue-depth timing -- max-rate ingress,
# staleness, token-bucket refill -- must pass an explicit arrival_cycle
# (as the m3 staleness cases and sim/gen_top_soak_vectors.py's soak
# generator already do), not rely on this default.
DEFAULT_INTER_ARRIVAL_CYCLES = 100


# ---------------------------------------------------------------------
# Wire format encode/decode
# ---------------------------------------------------------------------

@dataclass
class Message:
    """One 16-byte market-data message (S4.3)."""

    msg_type: int
    symbol_id: int
    side: int
    flags: int
    price: int
    quantity: int
    seq_num: int

    @classmethod
    def decode(cls, raw: bytes) -> "Message":
        if len(raw) != 16:
            raise ValueError(f"message must be exactly 16 bytes, got {len(raw)}")
        msg_type, symbol_id, side, flags, price, quantity, seq_num = struct.unpack(
            ">BBBBIII", raw
        )
        return cls(msg_type, symbol_id, side, flags, price, quantity, seq_num)

    def encode(self) -> bytes:
        return struct.pack(
            ">BBBBIII",
            self.msg_type,
            self.symbol_id,
            self.side,
            self.flags,
            self.price,
            self.quantity,
            self.seq_num,
        )


@dataclass
class OrderRecord:
    """One 16-byte order-output frame (S4.5)."""

    msg_type: int
    symbol_id: int
    side: int
    reject_reason: int
    price: int
    quantity: int
    trigger_seq: int  # low 16 bits of the triggering seq_num
    latency_cyc: int

    def encode(self) -> bytes:
        return struct.pack(
            ">BBBBIIHH",
            self.msg_type,
            self.symbol_id,
            self.side,
            self.reject_reason,
            self.price,
            self.quantity,
            self.trigger_seq & 0xFFFF,
            self.latency_cyc & 0xFFFF,
        )

    @classmethod
    def decode(cls, raw: bytes) -> "OrderRecord":
        if len(raw) != 16:
            raise ValueError(f"order record must be exactly 16 bytes, got {len(raw)}")
        msg_type, symbol_id, side, reject_reason, price, quantity, trigger_seq, latency_cyc = (
            struct.unpack(">BBBBIIHH", raw)
        )
        return cls(
            msg_type, symbol_id, side, reject_reason, price, quantity, trigger_seq, latency_cyc
        )


def parse_frame_payload(payload: bytes) -> tuple[list[bytes], bool]:
    """Split a frame's payload into complete 16-byte messages (S4.4,
    FR-4/FR-5). Returns (complete_messages, bad_length); on a bad length,
    complete_messages is always [] -- discard the frame whole, per FR-5's
    literal wording.

    A version of this briefly discarded only an incomplete *trailing*
    remainder, on the reasoning that a streaming parser can't know a
    frame's total length until it ends, so messages already forwarded
    can't be retroactively un-forwarded. That reasoning is correct in
    general but doesn't apply to this project's actual architecture: D1's
    decision to reuse the vendor MAC means the whole frame is already
    buffered, with its length known and exposed (eth_mac_if.v's
    frame_start/rx_len) *before* a single payload byte streams
    out. frame_classifier.v can and does check the length first and
    decide whether to forward anything at all -- so "discard whole" is
    both what FR-5 says and what the real RTL actually does here. Reverted
    once this was noticed, before md_parser.v was designed against the
    wrong assumption.

    A 0-byte payload (below FR-4's 1-message minimum) counts as bad_length
    too. A payload over the 88-message maximum is treated the same way
    (nothing forwarded) rather than truncated at 88 -- that boundary isn't
    covered by T05 and is a simplification, not a resolved decision.
    """
    if len(payload) == 0 or len(payload) % 16 != 0 or len(payload) > 88 * 16:
        return [], True
    return [payload[i : i + 16] for i in range(0, len(payload), 16)], False


# ---------------------------------------------------------------------
# Configuration (S9 register map defaults)
# ---------------------------------------------------------------------

@dataclass
class Config:
    num_symbols: int = 4
    symbols: tuple = (1, 2, 3, 4)
    symbol_en: int = 0xF
    min_spread: int = 2
    imb_shift: int = 1
    order_qty: int = 100
    max_order_qty: int = 500
    max_position: int = 1000
    price_band: int = 50
    max_age: int = 1_250_000
    token_max: int = 8
    token_refill_cycles: int = 12_500
    udp_port: int = 60000
    ml_action: int = 0  # 0 = block, 1 = reduce
    ml_reduce_shift: int = 0
    cfg_reject_report: bool = False

    def watched_symbols(self) -> set[int]:
        return {
            sym
            for i, sym in enumerate(self.symbols[: self.num_symbols])
            if (self.symbol_en >> i) & 1
        }


# ---------------------------------------------------------------------
# Counters (S10) -- saturating 32-bit, never wrap.
# ---------------------------------------------------------------------

_COUNTER_MAX = (1 << 32) - 1

_ALL_COUNTERS = (
    "cnt_frames_rx cnt_msgs_rx cnt_msgs_filtered cnt_msgs_accepted "
    "err_fcs err_ethertype err_ip err_udp_port err_frame_len err_msg_type "
    "err_flags err_signal_conflict "
    "cnt_seq_gap cnt_seq_dup cnt_crossed cnt_book_clear cnt_trades cnt_heartbeats "
    "cnt_signal_buy cnt_signal_sell "
    "cnt_ml_events cnt_ml_adverse cnt_ml_benign cnt_ml_safe_forced cnt_rej_ml "
    "cnt_rej_kill cnt_rej_size cnt_rej_position cnt_rej_band cnt_rej_stale "
    "cnt_rej_seqgap cnt_rej_crossed cnt_rej_throttle "
    "cnt_orders_tx cnt_order_overflow"
).split()


class Counters:
    """All S10 counters. Saturating add; never wraps."""

    def __init__(self):
        self._c: dict[str, int] = {name: 0 for name in _ALL_COUNTERS}
        self.lat_min: Optional[int] = None
        self.lat_max: Optional[int] = None
        self.lat_last: Optional[int] = None
        self.histogram: dict[int, int] = defaultdict(int)

    def inc(self, name: str, amount: int = 1) -> None:
        if name not in self._c:
            raise KeyError(f"unknown counter {name!r}")
        self._c[name] = min(self._c[name] + amount, _COUNTER_MAX)

    def __getitem__(self, name: str) -> int:
        return self._c[name]

    def record_latency(self, latency_cyc: int) -> None:
        self.lat_last = latency_cyc
        self.lat_min = latency_cyc if self.lat_min is None else min(self.lat_min, latency_cyc)
        self.lat_max = latency_cyc if self.lat_max is None else max(self.lat_max, latency_cyc)
        bucket = latency_cyc % 64
        self.histogram[bucket] += 1

    def as_dict(self) -> dict:
        d = dict(self._c)
        d["lat_min"] = self.lat_min
        d["lat_max"] = self.lat_max
        d["lat_last"] = self.lat_last
        return d


# ---------------------------------------------------------------------
# Per-symbol book state (S6.3)
# ---------------------------------------------------------------------

@dataclass
class SymbolBook:
    bid_price: int = 0
    bid_qty: int = 0
    bid_valid: bool = False
    ask_price: int = 0
    ask_qty: int = 0
    ask_valid: bool = False
    last_update_cycle: int = 0
    last_trade_side: int = SIDE_BID

    @property
    def crossed(self) -> bool:
        # FR-17: crossed iff both sides valid and bid >= ask.
        return self.bid_valid and self.ask_valid and self.bid_price >= self.ask_price

    @property
    def mid(self) -> int:
        # Integer mid (bid+ask)>>1 everywhere (CLAUDE.md hard convention).
        return (self.bid_price + self.ask_price) >> 1


# ---------------------------------------------------------------------
# The engine
# ---------------------------------------------------------------------

@dataclass
class ProcessResult:
    """What processing one message produced, for test assertions."""

    order: Optional[OrderRecord] = None
    order_dropped_overflow: bool = False
    signal_fired: Optional[str] = None  # "buy" / "sell" / None


class GoldenModel:
    """The full deterministic datapath: parse -> filter -> seq -> book ->
    signal -> risk -> order. Gate 0x09 (ML) is driven by an explicit
    `adverse_risk` argument to `process_message`, not computed internally
    -- see module docstring.
    """

    def __init__(self, cfg: Optional[Config] = None):
        self.cfg = cfg or Config()
        self.counters = Counters()
        self.books: dict[int, SymbolBook] = {}
        self.position: dict[int, int] = defaultdict(int)

        self.expected_seq: Optional[int] = None
        self.seq_gap = False

        self.kill_latched = False

        self.token_bucket = self.cfg.token_max
        self._last_refill_cycle = 0

        self._tx_busy_until: deque = deque()  # up to 2 pending "TX end" cycles
        self.current_cycle = 0

    # -- control plane -------------------------------------------------

    def assert_kill_switch(self) -> None:
        """FR-46: latches; deassertion alone does not resume."""
        self.kill_latched = True

    def clear_kill_switch(self) -> None:
        """Explicit CSR clear required (FR-46)."""
        self.kill_latched = False

    def clear_seq_gap(self) -> None:
        """FR-12: seq_gap clears on flags.snapshot=1 or explicit CSR clear."""
        self.seq_gap = False

    # -- internal helpers ------------------------------------------------

    def _book(self, symbol_id: int) -> SymbolBook:
        if symbol_id not in self.books:
            self.books[symbol_id] = SymbolBook()
        return self.books[symbol_id]

    def _refill_tokens(self, now_cycle: int) -> None:
        if now_cycle <= self._last_refill_cycle:
            return
        elapsed = now_cycle - self._last_refill_cycle
        # D51: risk_engine.v's refill_ctr ticks on `(refill_ctr+1) >=
        # cfg_token_refill_cycles` (rtl/risk_engine.v:308-311) -- true when
        # refill_ctr == cfg-1, i.e. the Nth refill lands at absolute cycle
        # N*cfg - 1, ONE CYCLE EARLIER than a plain `elapsed //
        # token_refill_cycles` floor-division predicts. refill_ctr and
        # cur_cycle share the same reset lineage (since D54, gated by local
        # buffers of tob_top.v's engine_rst_n -- rst_n_risk and
        # rst_n_cur_cycle respectively; these buffers release one uniform
        # clock cycle after engine_rst_n itself, but the shift is the SAME
        # for both, so refill_ctr and cur_cycle stay in lockstep exactly as
        # before D54 -- see docs/design_decisions.md D54) and both
        # increment by exactly 1 every cycle unconditionally, so they stay
        # in lockstep as absolute counters -- this +1 is not a guess, it's
        # RTL's own combinational lookahead condition. Found the hard way
        # (D51): a soak-order
        # mismatch traced to gate precedence flipping (8 vs 9) at exactly
        # the FIRST token-bucket refill boundary of a 5,000-message run --
        # this model refilled one order-position later than real RTL,
        # shifting every subsequent comparison by one.
        refills = (elapsed + 1) // self.cfg.token_refill_cycles
        if refills > 0:
            self.token_bucket = min(self.cfg.token_max, self.token_bucket + refills)
            self._last_refill_cycle += refills * self.cfg.token_refill_cycles

    def _retire_tx_slots(self, now_cycle: int) -> None:
        while self._tx_busy_until and self._tx_busy_until[0] <= now_cycle:
            self._tx_busy_until.popleft()

    def _tx_push(self, now_cycle: int) -> None:
        """D51: push one item into the TX queue with SEQUENTIAL,
        single-server semantics, matching rtl/order_builder.v exactly --
        `tx_busy` is one shared resource (one item transmitting at a time,
        rtl/eth_mac_if.v's tx_state), and the 2-deep queue (q0/q1) is a
        waiting room in front of it, not two parallel servers. A second
        item queued while the first is still in flight does not start its
        own ORDER_TX_CYCLES countdown until the first one's ends -- found
        the hard way (D51): appending `now_cycle + ORDER_TX_CYCLES`
        independently for every push (this method's predecessor) modeled
        two items draining in PARALLEL, which drains far faster than real
        hardware and silently erased genuine cnt_order_overflow events
        once reject-report frames also began sharing this queue at
        realistic (5,000-message) burst density. Call only after
        `_retire_tx_slots` + confirming `len(self._tx_busy_until) < 2`."""
        start = max(now_cycle, self._tx_busy_until[-1] if self._tx_busy_until else now_cycle)
        self._tx_busy_until.append(start + ORDER_TX_CYCLES)

    # -- main entry point ------------------------------------------------

    def process_message(
        self,
        raw: bytes,
        arrival_cycle: Optional[int] = None,
        adverse_risk: bool = False,
    ) -> ProcessResult:
        """Process one already-framed 16-byte message (post frame_classifier
        / md_parser). Frame-level errors (FR-1/2/3/5) are handled by
        `process_frame` below, not here.
        """
        if arrival_cycle is None:
            arrival_cycle = self.current_cycle + DEFAULT_INTER_ARRIVAL_CYCLES
        self.current_cycle = max(self.current_cycle, arrival_cycle)
        self._refill_tokens(self.current_cycle)
        self._retire_tx_slots(self.current_cycle)

        msg = Message.decode(raw)

        # csr_ingress_separation.md: CSR write/read-request frames (0x20/0x21)
        # share md_parser's byte stream by design (D19) but are not market
        # data -- and, matching rtl/md_parser.v (which now recognizes these
        # types so err_msg_type never fires for them), they must have ZERO
        # effect on every message-level counter and on seq-gap/dup tracking.
        # This early return is the very first thing process_message does with
        # a decoded message, BEFORE cnt_msgs_rx and BEFORE the seq block:
        # csr_block.v's cnt_msgs_rx condition (md_msg_valid | err_msg_type |
        # err_flags) and seq_monitor.v's msg_complete both key off signals
        # md_parser keeps low for CSR frames, so this model must not count
        # them either. (process_frame's own cnt_frames_rx still moves for a
        # CSR frame -- it counts Ethernet frames, not messages; unchanged.)
        if msg.msg_type in CSR_FRAME_TYPES:
            return ProcessResult()

        self.counters.inc("cnt_msgs_rx")

        # FR-10/11/12: sequence gap/dup tracking, run BEFORE symbol filter
        # and msg_type/flags validation, on every message regardless of
        # outcome. Sequence continuity is a feed-level property ("per
        # feed", FR-10) -- if it only ran on messages that already passed
        # the symbol filter, an unwatched-symbol message would silently
        # consume a seq_num slot without advancing expected_seq, and the
        # very next watched message would look like it arrived after a
        # gap that never happened. Caught by
        # sim/test_golden_model_handcase.py: a message for an unwatched
        # symbol between two watched ones produced a phantom cnt_seq_gap.
        # FR-7's "no other effect" for filtered messages reads as "no
        # effect on book/signal/risk state", not as forbidding this
        # feed-level bookkeeping, which real sequenced feeds require
        # regardless of which symbols a given subscriber cares about.
        is_dup = False
        if self.expected_seq is None:
            self.expected_seq = msg.seq_num
        if msg.seq_num < self.expected_seq:
            self.counters.inc("cnt_seq_dup")
            is_dup = True
        else:
            if msg.seq_num > self.expected_seq:
                gap = msg.seq_num - self.expected_seq
                self.counters.inc("cnt_seq_gap", gap)
                self.seq_gap = True
            self.expected_seq = msg.seq_num + 1
        if msg.flags & FLAG_SNAPSHOT:
            self.seq_gap = False  # FR-12

        # FR-8/FR-9: msg_type/flags validation, run BEFORE the symbol
        # filter -- the mirror image of the seq/dup reordering just above,
        # and for an architectural reason rather than a spec-priority one:
        # md_parser.v (S2, already committed) is the module that checks
        # msg_type/flags, and it sits upstream of symbol_filter.v in the
        # pipeline (master spec S3.1's block diagram: md_parser ->
        # symbol_filter -> seq_monitor -> tob_engine). By the time a
        # message would reach a symbol filter in the real datapath, an
        # undefined msg_type or a reserved flags bit has already dropped
        # it -- md_parser never forwards msg_valid for it, and there is no
        # symbol-filter-shaped module upstream of md_parser to have
        # filtered it first. A message that is simultaneously on an
        # unwatched symbol_id and has a bad msg_type therefore reports
        # err_msg_type in the real RTL, never cnt_msgs_filtered, regardless
        # of what its symbol_id is. This was a real ordering bug in this
        # model (filter was checked first) caught by design-decision
        # review while writing the S3 (symbol_filter/seq_monitor/tob_engine)
        # contracts, before any S3 test exercised the combination --
        # docs/design_decisions.md D12. See
        # sim/test_golden_model_handcase.py messages 21-22 for the
        # corner case this fixes.
        if msg.msg_type not in VALID_MSG_TYPES:
            self.counters.inc("err_msg_type")
            return ProcessResult()

        if msg.flags & FLAG_RESERVED_MASK:
            self.counters.inc("err_flags")
            return ProcessResult()

        # FR-7: symbol filter. Only ever sees messages md_parser.v already
        # validated (msg_type/flags both OK) -- see the comment above.
        if msg.symbol_id not in self.cfg.watched_symbols():
            self.counters.inc("cnt_msgs_filtered")
            return ProcessResult()

        # Counted as accepted here regardless of is_dup: a duplicate is
        # still a watched, well-formed message that reached the point of
        # book-application consideration -- it's dropped for being stale,
        # not for being invalid. This is what makes S10's own invariant
        # (cnt_msgs_rx = filtered + accepted + sum(err_*)) balance; there
        # is no separate bucket for "duplicate" in that equation.
        self.counters.inc("cnt_msgs_accepted")
        if is_dup:
            # FR-11: drop message, no book modification.
            return ProcessResult()

        book = self._book(msg.symbol_id)
        book_modifying = msg.msg_type in (MSG_QUOTE, MSG_CLEAR)

        # D17: captured BEFORE this message refreshes book.last_update_cycle
        # below, specifically so GATE_STALE's check (further down) measures
        # the gap that existed BEFORE this message arrived, not the (always
        # zero) gap between this message and itself. See D17's writeup in
        # docs/design_decisions.md for why the original unconditional
        # "update the timestamp, then check the gap against a value already
        # equal to current_cycle" ordering made GATE_STALE unreachable.
        prev_update_cycle = book.last_update_cycle

        if msg.msg_type == MSG_QUOTE:
            # FR-14: replace price+qty for the addressed side.
            # FR-15 (D14): qty=0 invalidates that side WITHOUT altering the
            # stored price -- the price write is conditional on quantity !=
            # 0, not unconditional like FR-14's general case. Any side
            # value other than SIDE_BID selects ask (golden_model.py's own
            # convention throughout, not just 0/1 -- matches
            # docs/contracts/md_parser.md's "msg_side: any value 0-255, no
            # validation needed here").
            if msg.side == SIDE_BID:
                if msg.quantity != 0:
                    book.bid_price = msg.price
                book.bid_qty = msg.quantity
                book.bid_valid = msg.quantity != 0
            else:
                if msg.quantity != 0:
                    book.ask_price = msg.price
                book.ask_qty = msg.quantity
                book.ask_valid = msg.quantity != 0
            book.last_update_cycle = self.current_cycle
        elif msg.msg_type == MSG_CLEAR:
            # FR-16: clear both sides.
            book.bid_valid = False
            book.ask_valid = False
            book.last_update_cycle = self.current_cycle
            self.counters.inc("cnt_book_clear")
        elif msg.msg_type == MSG_TRADE:
            # FR-19/FR-25: does not modify book price/qty; refreshes staleness.
            book.last_trade_side = msg.side
            book.last_update_cycle = self.current_cycle
            self.counters.inc("cnt_trades")
        elif msg.msg_type == MSG_HEARTBEAT:
            # FR-19: refreshes staleness timer only.
            book.last_update_cycle = self.current_cycle
            self.counters.inc("cnt_heartbeats")

        if book.crossed:
            self.counters.inc("cnt_crossed")

        result = ProcessResult()
        if not book_modifying:
            return result

        # -- ML bookkeeping (D30): the spec's own §10 defines cnt_ml_events
        #    as "valid feature vectors processed" -- the ML branch is a
        #    SEPARATE, parallel pipeline off book_upd_valid (master spec
        #    S3.1's two-convergent-paths architecture), not gated on
        #    whether the deterministic signal engine also fired an intent.
        #    Must run for every book-modifying event, BEFORE the buy_ok/
        #    sell_ok early-returns below -- it was previously placed after
        #    them, so it silently never counted an ML-processed event that
        #    produced no deterministic signal (D30, found via external
        #    audit, independently confirmed against this file and the
        #    spec's own §10 text before fixing).
        self.counters.inc("cnt_ml_events")
        if adverse_risk:
            self.counters.inc("cnt_ml_adverse")
        else:
            self.counters.inc("cnt_ml_benign")

        # -- signal engine (S6.6, FR-35..40) --
        buy_ok = (
            book.bid_valid
            and book.ask_valid
            and not book.crossed
            and (book.ask_price - book.bid_price) >= self.cfg.min_spread
            and book.bid_qty > (book.ask_qty << self.cfg.imb_shift)
        )
        sell_ok = (
            book.bid_valid
            and book.ask_valid
            and not book.crossed
            and (book.ask_price - book.bid_price) >= self.cfg.min_spread
            and book.ask_qty > (book.bid_qty << self.cfg.imb_shift)
        )
        if buy_ok and sell_ok:
            # FR-37: impossible by construction; if it ever happens, no
            # order, flag the conflict.
            self.counters.inc("err_signal_conflict")
            return result

        order_side: Optional[int] = None
        order_price: Optional[int] = None
        if buy_ok:
            order_side = SIDE_BID
            order_price = book.ask_price
            self.counters.inc("cnt_signal_buy")
            result.signal_fired = "buy"
        elif sell_ok:
            order_side = SIDE_ASK
            order_price = book.bid_price
            self.counters.inc("cnt_signal_sell")
            result.signal_fired = "sell"
        else:
            return result

        order_qty = self.cfg.order_qty

        # -- risk engine, all 9 gates, lowest-numbered wins (S8.2, FR-41..48) --
        gates_fired: list[int] = []
        if self.kill_latched:
            gates_fired.append(GATE_KILL)
        if order_qty > self.cfg.max_order_qty:
            gates_fired.append(GATE_SIZE)
        signed_qty = order_qty if order_side == SIDE_BID else -order_qty
        prospective_position = self.position[msg.symbol_id] + signed_qty
        if abs(prospective_position) > self.cfg.max_position:
            gates_fired.append(GATE_POSITION)
        if abs(order_price - book.mid) > self.cfg.price_band:
            gates_fired.append(GATE_BAND)
        # D17: uses prev_update_cycle (captured before THIS message's own
        # refresh above), not book.last_update_cycle -- the latter was
        # already overwritten to self.current_cycle by this same message,
        # which made the gap always read 0 and GATE_STALE unreachable.
        if (self.current_cycle - prev_update_cycle) > self.cfg.max_age:
            gates_fired.append(GATE_STALE)
        if self.seq_gap:
            gates_fired.append(GATE_SEQGAP)
        if book.crossed:
            gates_fired.append(GATE_CROSSED)
        if self.token_bucket <= 0:
            gates_fired.append(GATE_THROTTLE)
        reduced_qty = order_qty
        if adverse_risk:
            if self.cfg.ml_action == 0:
                gates_fired.append(GATE_ML)
            else:
                reduced_qty = max(1, order_qty >> self.cfg.ml_reduce_shift)

        # D30: cnt_rej_ml is GATE_NAME[GATE_ML] -- the loop above already
        # increments it exactly once whenever GATE_ML fired. A redundant
        # second `inc("cnt_rej_ml")` used to sit here, unconditionally
        # double-counting every ML-blocked order (found via external audit,
        # independently confirmed: GATE_ML in gates_fired implies
        # adverse_risk is already true, so the removed line's guard was
        # never selective -- it fired every single time the loop above
        # already counted it).
        for g in gates_fired:
            self.counters.inc(GATE_NAME[g])

        if gates_fired:
            reject_reason = min(gates_fired)
            if self.cfg.cfg_reject_report:
                # D51: a 0x11 reject-report frame shares order_builder.v's
                # SAME 2-deep TX queue as an accepted 0x10 order --
                # `want_push = order_valid | (cfg_reject_report &
                # reject_reason != 0)` and `overflow = want_push &
                # (count_after_pop >= 2)` (rtl/order_builder.v:139-140,157)
                # apply identically to both frame types. This model used to
                # let a reject-report bypass the queue entirely (no
                # _retire_tx_slots call, no occupancy check, no append) --
                # found by extending tb_top's soak from 209 to 5,000
                # messages (D51): with reject-reporting on and rejects far
                # outnumbering accepts, real RTL's shared queue genuinely
                # fills up and drops frames (cnt_order_overflow read 11 on
                # real hardware vs. 0-1 this model predicted before this
                # fix, since it only ever pushed accepted orders into the
                # busy-queue it checks for overflow). Mirror the accept
                # path's exact check/append here instead of special-casing
                # "reject" as queue-exempt.
                self._retire_tx_slots(self.current_cycle)
                if len(self._tx_busy_until) >= 2:
                    self.counters.inc("cnt_order_overflow")
                    result.order_dropped_overflow = True
                    return result
                self._tx_push(self.current_cycle)
                result.order = OrderRecord(
                    ORDER_MSG_REJECT,
                    msg.symbol_id,
                    order_side,
                    reject_reason,
                    order_price,
                    order_qty,
                    msg.seq_num & 0xFFFF,
                    TICK_TO_TRADE_CYCLES,
                )
            return result

        # Accepted. Consume one throttle token and one TX slot (S7.5,
        # S8.4), or overflow if both TX slots are already occupied.
        self._retire_tx_slots(self.current_cycle)
        if len(self._tx_busy_until) >= 2:
            self.counters.inc("cnt_order_overflow")
            result.order_dropped_overflow = True
            return result

        # D16: position tracks what was ACTUALLY filled -- reduced_qty when
        # gate 0x09's ml_action=1 reduce path applied, not the pre-reduction
        # order_qty signed_qty was computed from. Gate 0x03's own check
        # above deliberately still used the unreduced order_qty (FR-48: the
        # ML reduction is gate 0x09's own action, independent of gates
        # 0x01-0x08's evaluation) -- only the final ledger update changes.
        final_signed_qty = reduced_qty if order_side == SIDE_BID else -reduced_qty
        self.token_bucket -= 1
        self.position[msg.symbol_id] = self.position[msg.symbol_id] + final_signed_qty
        self._tx_push(self.current_cycle)

        self.counters.inc("cnt_orders_tx")
        self.counters.record_latency(TICK_TO_TRADE_CYCLES)

        result.order = OrderRecord(
            ORDER_MSG_NEW,
            msg.symbol_id,
            order_side,
            0x00,
            order_price,
            reduced_qty,
            msg.seq_num & 0xFFFF,
            TICK_TO_TRADE_CYCLES,
        )
        return result

    # -- frame-level entry point (FR-1..FR-6) -----------------------------

    def process_frame(
        self,
        payload: bytes,
        arrival_cycle: Optional[int] = None,
        fcs_ok: bool = True,
        adverse_risk_fn=None,
    ) -> list[ProcessResult]:
        """Process one frame's already-extracted payload (post EtherType/
        IPv4/UDP-port classification -- that's frame_classifier's job, not
        modeled byte-for-byte here since D1 found the vendor MAC does most
        of it for LINK_MODE=1; only the message-count/length checks below
        are ours regardless of link mode).

        `adverse_risk_fn(Message) -> bool` lets a test drive gate 0x09
        without a real feature/classifier pipeline (S6 work, not S1).
        """
        self.counters.inc("cnt_frames_rx")
        if not fcs_ok:
            self.counters.inc("err_fcs")
            return []

        messages, bad_length = parse_frame_payload(payload)
        if bad_length:
            self.counters.inc("err_frame_len")
        if not messages:
            return []

        results = []
        for i, raw in enumerate(messages):
            msg_cycle = None if arrival_cycle is None else arrival_cycle + i
            adverse = False
            if adverse_risk_fn is not None:
                adverse = adverse_risk_fn(Message.decode(raw))
            results.append(self.process_message(raw, msg_cycle, adverse))
        return results
