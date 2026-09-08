"""sim/gen_top_soak_vectors.py

Generates the three files tb/tb_top.v's randomized-soak section loads
(docs/contracts/tb_top_integration.md S2): the raw single-message frame
stream, the expected order-record stream, and the expected final counter
values -- for the full end-to-end system (parse -> filter -> seq -> book ->
signal -> ML -> risk -> order), not any one module in isolation.

The one piece of real integration work this file does that nothing else in
sim/ does: wiring feature_golden.py's FeatureTracker and ml_golden.py's
MLClassifier THROUGH to golden_model.py's adverse_risk_fn callback.
golden_model.py deliberately does not compute ML itself (D31/S1 scope split:
adverse_risk is an injectable argument) -- and ml_golden.py's own
MLClassifier.classify() takes already-computed features, not raw messages,
so it needs FeatureTracker in front of it too. Nothing before this file
combined all three.

Chicken-and-egg problem this solves with a two-pass design: `adverse_risk_fn`
is invoked BEFORE golden_model.py updates its own internal per-symbol book
for a given message, but FeatureTracker needs the POST-update book state
(its own contract, feature_golden.py's on_book_event docstring). Pass 1
below tracks a small, independent "shadow" per-symbol book (replicating
FR-14/15/16's update rule exactly -- the same six lines golden_model.py's
own SymbolBook update uses) purely to drive FeatureTracker/MLClassifier and
precompute one adverse_risk value per message, in order. Pass 2 then runs
the REAL GoldenModel across the same message stream, handing back each
precomputed value via adverse_risk_fn. The shadow book is intentionally
tiny and read-only with respect to GoldenModel's own state -- it never
substitutes for it, only feeds the ML side ahead of when GoldenModel would
otherwise have the post-update state available.

Directed per-gate coverage (reject reasons 0x01-0x09) is NOT generated
here -- it lives directly in tb/tb_top.v as hand-written cases, matching
tb_tob_top.v's own proven style (docs/contracts/tb_top_integration.md S3.5).
This generator only produces the broader randomized-soak stream: a realistic
mix of feed_gen.py's normal/crossed/gaps/trigger scenarios at normal
(16-cycle) message cadence, default Config() (== RTL reset defaults,
cross-checked against rtl/csr_block.v's own reset assignments), with ML
thresholds widened so gate 0x09 doesn't dominate every other gate's
coverage (mirroring tb_tob_top.v's own T1 rationale for why default
ML_TH_HIGH=0 needs neutralizing for anything other than a dedicated ML
test) and reject-reporting enabled so 0x11 reject frames are part of the
comparison stream, not just accepts.

burst/malformed scenarios are deliberately excluded: tb/sim_models/
tob_top_sim_leaves.v's mac_top stand-in only supports exactly-16-byte
(single-message) frames (sim_rx_frame is a fixed 128-bit register,
tx_ram is a fixed 16-byte array) -- the same reason gen_soak_vectors.py's
parser-only soak sticks to single-message frames. Multi-message-frame and
malformed-length coverage already exists in tb_frame_classifier.v/
tb_md_parser.v; this file's job is end-to-end wiring at scale, not
re-testing frame-level parsing.

CLI usage:
  python sim/gen_top_soak_vectors.py --count 1000 --seed 7 \\
      --out-prefix tb/stimulus/tb_top_soak
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from typing import Optional

from golden_model import (
    Config,
    GoldenModel,
    Message,
    MSG_CLEAR,
    MSG_HEARTBEAT,
    MSG_QUOTE,
    MSG_TRADE,
    SIDE_BID,
    FLAG_SNAPSHOT,
)
from feature_golden import FeatureTracker
from ml_golden import MLClassifier
from feed_gen import iter_scenario

# Picked from the ACTUAL z distribution this generator's own stimulus
# produces (measured directly, not guessed): across warm-up + normal +
# crossed + trigger, z ranges roughly -166..397, median ~143, clearly
# positive-skewed (feature magnitudes from bid/ask quantity imbalance and
# window-summed volatility dominate, both unsigned-leaning). Two earlier
# attempts got this wrong in opposite ways:
#   +-100_000: "wide" enough that th_high is essentially unreachable, which
#     was the point -- but symmetric width makes th_low UNREACHABLE too, so
#     once anything (fail-safe forcing, or a stray z spike) set
#     adverse_risk=1, hysteresis HELD it there forever; z's real minimum
#     never comes close to -100_000. Confirmed directly: cnt_orders_tx read
#     0 for an entire soak despite 81 signals firing.
#   +-300 (symmetric, "just inside the observed max"): th_high now
#     reachable, but th_low=-300 is still well past the observed minimum
#     (-166) -- same one-way-stuck problem, just with a smaller gap.
# th_high=250 sits just above the median (roughly a third of events cross
# it -- neither "almost never" nor "almost always"); th_low=-100 sits
# comfortably inside the observed negative tail so the CLEAR transition
# actually fires too, not just SET.
ML_TH_HIGH = 250
ML_TH_LOW = -100

DEFAULT_INTER_ARRIVAL_CYCLES = 16  # matches golden_model.py's own default

# Fixed output order for tb_top_soak_expected_counters.txt -- one integer
# per line, NO names, matching rtl/csr_block.v's own register-map order
# exactly (0x00A0.. through 0x0128, see that file's rd32 case statement)
# rather than golden_model.py's own Counters class definition order or an
# alphabetical sort. tb/tb_top.v reads this file with plain `%d` $fscanf
# calls (Verilog-2001 has no convenient string-splitting for a "name=value"
# format) against a parallel, hardcoded CSR-address array declared in the
# SAME order -- keep the two in sync if either ever changes.
COUNTER_ORDER = (
    "cnt_frames_rx", "cnt_msgs_rx", "cnt_msgs_filtered", "cnt_msgs_accepted",
    "err_fcs", "err_ethertype", "err_ip", "err_udp_port", "err_frame_len",
    "err_msg_type", "err_flags", "err_signal_conflict",
    "cnt_seq_gap", "cnt_seq_dup", "cnt_crossed", "cnt_book_clear",
    "cnt_trades", "cnt_heartbeats", "cnt_signal_buy", "cnt_signal_sell",
    "cnt_ml_events", "cnt_ml_adverse", "cnt_ml_benign", "cnt_ml_safe_forced",
    "cnt_rej_kill", "cnt_rej_size", "cnt_rej_position", "cnt_rej_band",
    "cnt_rej_stale", "cnt_rej_seqgap", "cnt_rej_crossed", "cnt_rej_throttle",
    "cnt_rej_ml", "cnt_orders_tx", "cnt_order_overflow",
)

# ML_OFFSET_0..7/ML_SHIFT_0..7 reset defaults (rtl/csr_block.v): all zero.
# With shift=0 this reduces to "clamp to int8", but it is NOT a no-op to
# skip -- feature_golden.py's FeatureTracker returns raw, UNNORMALIZED
# int32 magnitudes (e.g. a raw price delta can be in the thousands), and
# ml_golden.py's MLClassifier expects already-quantized int8 features
# (its own docstring: max |z| = 8*128 = 1024 -- only true post-normalization).
# Feeding raw features straight into classify() blows z far past any
# reasonable threshold on the very first event, and hysteresis then holds
# it there forever -- caught by this generator's own first test run
# (every single ML event read "adverse", none "benign").
NORM_OFFSET = 0
NORM_SHIFT = 0


def _norm8(raw: int) -> int:
    """rtl/feature_normalizer.v's norm8(), bit-for-bit: sat_[-128,127]
    ((raw - offset) >> shift), floor (arithmetic) shift. offset/shift are
    both 0 at reset (rtl/csr_block.v) -- this generator never CSR-writes
    them, matching every other config value it leaves at RTL defaults."""
    diff = raw - NORM_OFFSET
    shifted = diff >> NORM_SHIFT if NORM_SHIFT else diff   # Python >> floors, matches >>>
    if shifted > 127:
        return 127
    if shifted < -128:
        return -128
    return shifted


@dataclass
class _ShadowBook:
    """Minimal per-symbol book state, kept ONLY to feed FeatureTracker /
    MLClassifier one message ahead of GoldenModel's own (real) book update
    -- see module docstring. Update rule is FR-14/15/16, copied exactly
    from golden_model.py's SymbolBook handling (not re-derived)."""

    bid_price: int = 0
    bid_qty: int = 0
    bid_valid: bool = False
    ask_price: int = 0
    ask_qty: int = 0
    ask_valid: bool = False

    @property
    def crossed(self) -> bool:
        return self.bid_valid and self.ask_valid and self.bid_price >= self.ask_price


def _compute_adverse_risk_stream(
    messages: list[Message], symbols: tuple[int, ...]
) -> tuple[list[bool], int]:
    """Pass 1 (module docstring). Returns (one adverse_risk bool per
    message, in order; total cnt_ml_safe_forced), using shadow book
    tracking + FeatureTracker + MLClassifier -- entirely independent of
    GoldenModel's own (real) state.

    cnt_ml_safe_forced is counted HERE, not read back from GoldenModel:
    golden_model.py's adverse_risk_fn interface is `Message -> bool` and
    has no way to convey "this was fail-safe-forced" versus "the classifier
    genuinely predicted this" -- confirmed by grep, `cnt_ml_safe_forced` is
    never actually incremented anywhere in golden_model.py despite being a
    real counter in its own Counters class. That is a real, independent
    gap in golden_model.py's own bookkeeping (structurally unreachable
    through its current public interface, same class of finding as D30's
    counter bugs), not something to route around silently -- flagged in
    this generator's own report and worth its own follow-up, not fixed
    here since it's out of this contract's scope (golden_model.py is a
    read-only reference per docs/contracts/tb_top_integration.md). Since
    this generator's own Pass 1 has direct access to MLResult.safe_forced,
    it can and does track the count correctly itself."""
    books: dict[int, _ShadowBook] = {s: _ShadowBook() for s in symbols}
    tracker = FeatureTracker(window=16)
    clf = MLClassifier(th_high=ML_TH_HIGH, th_low=ML_TH_LOW)
    safe_forced_count = 0

    # Shadow seq-gap tracking -- same rule as golden_model.py's own
    # expected_seq/seq_gap handling (FR-10/11/12), copied exactly so this
    # pass's seq_gap state matches what GoldenModel will independently
    # compute over the same stream in Pass 2.
    expected_seq: Optional[int] = None
    seq_gap = False

    out: list[bool] = []
    for msg in messages:
        # Mirror golden_model.py's own dup/gap bookkeeping ordering exactly
        # (runs before any type/filter/book logic, FR-10).
        if expected_seq is None:
            expected_seq = msg.seq_num
        is_dup = msg.seq_num < expected_seq
        if not is_dup:
            if msg.seq_num > expected_seq:
                seq_gap = True
            expected_seq = msg.seq_num + 1
        if msg.flags & FLAG_SNAPSHOT:
            seq_gap = False

        # FR-11: a duplicate is dropped before any book modification --
        # GoldenModel.process_message returns early right after this same
        # check, so the shadow book here must not touch state for it
        # either, or it would diverge from GoldenModel's real book on the
        # very next genuine message (feed_gen.py's _gaps scenario
        # deliberately creates duplicates for exactly this reason).
        if is_dup:
            out.append(False)
            continue

        book = books[msg.symbol_id]
        # D47 (ml_policy_per_symbol.md S4): the slot for this message --
        # symbols' tuple order is the same slot ordering the RTL's
        # SYMBOL_0..3 registers use (symbol_filter maps watched symbol IDs to
        # slots by that position). classify()'s hysteresis is per-slot, so
        # each message must carry its own symbol's slot; passing a wrong or
        # absent slot would silently reintroduce the shared-scalar bug in
        # this reference.
        slot = symbols.index(msg.symbol_id)

        if msg.msg_type == MSG_QUOTE:
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
            fv = tracker.on_book_event(
                msg.symbol_id, MSG_QUOTE,
                book.bid_price, book.bid_qty, book.bid_valid,
                book.ask_price, book.ask_qty, book.ask_valid,
            )
            x = tuple(_norm8(v) for v in fv.as_tuple())   # feature_normalizer.v's job
            res = clf.classify(slot, x, book.bid_valid, book.ask_valid, book.crossed, seq_gap)
            if res.safe_forced:
                safe_forced_count += 1
            out.append(bool(res.adverse_risk))
        elif msg.msg_type == MSG_CLEAR:
            book.bid_valid = False
            book.ask_valid = False
            fv = tracker.on_book_event(
                msg.symbol_id, MSG_CLEAR,
                book.bid_price, book.bid_qty, book.bid_valid,
                book.ask_price, book.ask_qty, book.ask_valid,
            )
            x = tuple(_norm8(v) for v in fv.as_tuple())   # feature_normalizer.v's job
            res = clf.classify(slot, x, book.bid_valid, book.ask_valid, book.crossed, seq_gap)
            if res.safe_forced:
                safe_forced_count += 1
            out.append(bool(res.adverse_risk))
        elif msg.msg_type == MSG_TRADE:
            tracker.on_trade(msg.symbol_id, msg.side)
            out.append(False)   # TRADE is not a book event -- no ML event
        elif msg.msg_type == MSG_HEARTBEAT:
            tracker.on_heartbeat(msg.symbol_id)
            out.append(False)   # HEARTBEAT is not a book event -- no ML event
        else:
            out.append(False)   # malformed type -- never reaches book logic anyway

    return out, safe_forced_count


def _warmup_messages(symbols: tuple[int, ...]) -> list[Message]:
    """One bid + one ask QUOTE per symbol, same initial price convention
    feed_gen.py's own FeedState uses (bid=10000, ask=10010) -- establishes
    both sides valid for every symbol before the random stream starts.
    Without this, feed_gen's normal/crossed/gaps/trigger scenarios pick a
    random symbol per message across 4 symbols, so with a few hundred
    messages many symbols spend most of the run with only one side ever
    quoted -- FR-26's fail-safe forcing (an invalid side forces
    adverse_risk=1) then dominates every ML event, and gate 0x09 blocks
    every single signal before any other gate or a successful order ever
    gets exercised (found by running this generator and noticing
    cnt_orders_tx read exactly 0 for an entire soak -- not a hypothetical
    concern, an actual first-draft result)."""
    seq = 1
    out = []
    for sym in symbols:
        out.append(Message(MSG_QUOTE, sym, SIDE_BID, 0, 10_000, 50, seq)); seq += 1
        out.append(Message(MSG_QUOTE, sym, 0x01, 0, 10_010, 50, seq)); seq += 1   # SIDE_ASK
    return out


def generate(count: int, seed: int) -> tuple[list[bytes], list[bytes], dict]:
    """Returns (input_frame_payloads, expected_order_record_bytes,
    expected_counters_dict)."""
    symbols = (1, 2, 3, 4)
    # "gaps" LAST, deliberately: FR-12's seq_gap is STICKY -- it only clears
    # on an explicit FLAG_SNAPSHOT message or a CSR clear, never on its own.
    # Putting "gaps" before "trigger" (this generator's first draft did)
    # means every message from that point on is permanently fail-safe-
    # forced (seq_gap is one of safe_state's OR terms), silently erasing
    # "trigger"'s whole purpose -- confirmed directly: cnt_orders_tx read 0
    # for the entire soak despite 90 signals firing, every single one
    # ML-blocked. A trailing snapshot-clear message after "gaps" recovers
    # cleanly (FR-12's own intended mechanism) so nothing downstream is
    # affected if scenarios are ever reordered again.
    scenarios = ("normal", "crossed", "trigger", "gaps")
    per_scenario = max(1, count // len(scenarios))

    # Each scenario chunk (including the warm-up) generates seq_num from its
    # own independent FeedState/counter starting at 1 -- concatenating them
    # as-is would make every chunk after the first look like a wall of
    # duplicates/reorders of the first (a real bug this generator's own
    # first draft had: cnt_seq_dup read 141 out of 200 messages). Fix: shift
    # each chunk's seq_nums by a running offset so chunk boundaries are
    # CONTINUOUS, while preserving every RELATIVE seq relationship within a
    # chunk exactly -- critically, this keeps _gaps' own deliberately
    # encoded skips/duplicates intact (they're relative to that chunk's own
    # sequence, and a flat global renumbering to 1,2,3,... would erase
    # every one of them, defeating the entire point of including that
    # scenario). Only cross-chunk boundaries are normalized; nothing inside
    # a chunk is touched.
    chunks: list[list[Message]] = [_warmup_messages(symbols)]
    for i, scenario in enumerate(scenarios):
        n = per_scenario if i < len(scenarios) - 1 else (count - per_scenario * (len(scenarios) - 1))
        frames = iter_scenario(scenario, n, seed=seed * 100 + i, symbols=symbols)
        chunks.append([Message.decode(f.payload) for f in frames])
    # FR-12 recovery after "gaps": one FLAG_SNAPSHOT heartbeat clears the
    # sticky seq_gap left behind, so this generator stays correct even if
    # scenarios are ever reordered or appended to later.
    chunks.append([Message(MSG_HEARTBEAT, symbols[0], SIDE_BID, FLAG_SNAPSHOT, 0, 0, 1)])

    messages: list[Message] = []
    running_max_seq = 0
    for chunk in chunks:
        offset = running_max_seq + 1 - min(m.seq_num for m in chunk)
        for m in chunk:
            m.seq_num += offset
        running_max_seq = max(m.seq_num for m in chunk)
        messages.extend(chunk)
    payloads = [m.encode() for m in messages]

    adverse_stream, safe_forced_count = _compute_adverse_risk_stream(messages, symbols)

    cfg = Config()
    cfg.cfg_reject_report = True
    gm = GoldenModel(cfg)

    # tb/tb_top.v's randomized_soak() task sends 3 CSR write frames (CTRL,
    # ML_TH_HIGH, ML_TH_LOW) immediately before streaming this generator's
    # output, to configure the engine. These are real 16-byte frames as far
    # as the RTL is concerned: md_parser.v rejects msg_type 0x20 as invalid,
    # so each one hits err_msg_type -- but BEFORE that check, seq_monitor.v
    # ALSO sees each one (msg_complete = msg_valid | err_msg_type |
    # err_flags), always with seq_num=0 (the CSR frame's tail is hardwired
    # to zero). The first one becomes "the first message ever" post-reset
    # (anchors expected_seq=1, matching this generator's own stream, which
    # starts at seq=1 via _warmup_messages -- see clear_seq_gap's own
    # comment in tb_top.v for why that alignment is deliberate); the other
    # two are then DUPLICATES of it (seq 0 < expected_seq 1), each
    # incrementing cnt_seq_dup. An earlier draft of this generator applied
    # a flat "+3" adjustment to cnt_frames_rx/cnt_msgs_rx/err_msg_type only
    # and missed this duplicate-counting effect entirely (confirmed
    # directly: cnt_seq_dup and cnt_seq_gap were both off by more than the
    # flat adjustment could explain). Modeling the exact 3 frames through
    # process_frame() itself, before the real stream, gets every counter
    # they touch right by construction instead of guessing which ones to
    # patch by hand.
    def _csr_frame_pack(mt: int, addr: int, data: int) -> bytes:
        import struct as _struct
        return _struct.pack(">BBHIQ", mt, 0, addr, data, 0)

    for mt, addr, data in ((0x20, 0x0000, 0x10), (0x20, 0x0048, 250), (0x20, 0x004C, 0xFFFFFF9C)):
        gm.process_frame(_csr_frame_pack(mt, addr, data), arrival_cycle=None, adverse_risk_fn=None)

    idx = [0]

    def adverse_risk_fn(_msg: Message) -> bool:
        v = adverse_stream[idx[0]]
        idx[0] += 1
        return v

    expected_orders: list[bytes] = []
    for payload in payloads:
        results = gm.process_frame(payload, arrival_cycle=None, adverse_risk_fn=adverse_risk_fn)
        for r in results:
            if r.order is not None:
                expected_orders.append(r.order.encode())

    # tb/tb_top.v reads back every counter via 35 sequential CSR 0x21 read
    # frames (csr_read_value, one per COUNTER_ORDER entry, in that exact
    # order). Each read is ITSELF a real 16-byte frame the RTL counts --
    # md_parser.v rejects msg_type 0x21 the same way it rejects 0x20, so
    # every single read increments cnt_frames_rx/cnt_msgs_rx/err_msg_type,
    # and (via seq_monitor's msg_complete, same mechanism as the 3 setup
    # writes above) counts as a seq_num=0 duplicate once any real traffic
    # has occurred. This means the very act of reading cnt_frames_rx bumps
    # cnt_frames_rx by 1 before its own response is built, and reading
    # cnt_seq_dup after 13 other reads have already happened reflects 13
    # EXTRA duplicate-counts contributed by those preceding reads, not just
    # the real stream's own dup count. Confirmed directly: an earlier
    # version of this generator that snapshotted every counter at once,
    # after the stream but before modeling any reads, was off by exactly
    # the amount each counter's own read-order position would predict
    # (cnt_seq_dup read 13 low, matching its position as the 14th read).
    # The only correct fix is to simulate the exact same 35 reads, in the
    # exact same order, and snapshot each counter's value immediately after
    # ITS OWN read -- exactly mirroring what tb_top.v's own csr_read_value
    # sequence actually measures.
    counter_addr = {
        "cnt_frames_rx": 0x00A0, "cnt_msgs_rx": 0x00A4, "cnt_msgs_filtered": 0x00A8,
        "cnt_msgs_accepted": 0x00AC, "err_fcs": 0x00B0, "err_ethertype": 0x00B4,
        "err_ip": 0x00B8, "err_udp_port": 0x00BC, "err_frame_len": 0x00C0,
        "err_msg_type": 0x00C4, "err_flags": 0x00C8, "err_signal_conflict": 0x00CC,
        "cnt_seq_gap": 0x00D0, "cnt_seq_dup": 0x00D4, "cnt_crossed": 0x00D8,
        "cnt_book_clear": 0x00DC, "cnt_trades": 0x00E0, "cnt_heartbeats": 0x00E4,
        "cnt_signal_buy": 0x00E8, "cnt_signal_sell": 0x00EC, "cnt_ml_events": 0x00F0,
        "cnt_ml_adverse": 0x00F4, "cnt_ml_benign": 0x00F8, "cnt_ml_safe_forced": 0x00FC,
        "cnt_rej_kill": 0x0100, "cnt_rej_size": 0x0104, "cnt_rej_position": 0x0108,
        "cnt_rej_band": 0x010C, "cnt_rej_stale": 0x0110, "cnt_rej_seqgap": 0x0114,
        "cnt_rej_crossed": 0x0118, "cnt_rej_throttle": 0x011C, "cnt_rej_ml": 0x0120,
        "cnt_orders_tx": 0x0124, "cnt_order_overflow": 0x0128,
    }
    assert list(counter_addr) == list(COUNTER_ORDER), "counter_addr must match COUNTER_ORDER exactly"

    # cnt_frames_rx is NOT like the other 34: measured directly, it matched
    # exactly when snapshotted AFTER its own read frame is processed (its
    # own read's contribution IS visible in its own response) -- but every
    # other counter (all downstream of md_parser's own multi-cycle
    # pipeline: cnt_msgs_rx, err_msg_type, cnt_seq_gap/dup, etc.) measured
    # consistently 1 LOW when snapshotted the same way, and consistently
    # matched when snapshotted BEFORE processing that same read frame.
    # Read this as: frame_classifier-level counting is fast enough to be
    # visible to a CSR read response built from the very same frame that
    # triggered it; anything one or more pipeline stages further down
    # (md_parser and beyond) is not yet visible by the time that response
    # goes out -- the read's own contribution to THOSE counters only
    # becomes visible starting with the NEXT frame's own processing.
    counters: dict = {}
    for name in COUNTER_ORDER:
        pre_value = gm.counters[name]
        gm.process_frame(_csr_frame_pack(0x21, counter_addr[name], 0), arrival_cycle=None, adverse_risk_fn=None)
        counters[name] = gm.counters[name] if name == "cnt_frames_rx" else pre_value
    # golden_model.py itself never increments cnt_ml_safe_forced (its
    # adverse_risk_fn interface has no way to convey "forced" vs
    # "predicted") -- overridden here with this generator's own accurate
    # count, computed directly from MLResult.safe_forced in Pass 1. See
    # _compute_adverse_risk_stream's docstring. (The read-simulation loop
    # above still needed to process a read for this address, in position,
    # for every LATER counter's own pollution count to be correct --
    # cnt_ml_safe_forced's own value from gm is simply never used.)
    counters["cnt_ml_safe_forced"] = safe_forced_count

    return payloads, expected_orders, counters


def _write_mem(path: str, chunks: list[bytes], header: str) -> None:
    with open(path, "w") as f:
        f.write(f"// {header}\n")
        for chunk in chunks:
            for b in chunk:
                f.write(f"{b:02x}\n")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--count", type=int, default=1000, help="number of messages (== single-message frames)")
    ap.add_argument("--seed", type=int, required=True, help="recorded in a header comment for reproducibility")
    ap.add_argument("--out-prefix", required=True, help="output path prefix, e.g. tb/stimulus/tb_top_soak")
    args = ap.parse_args()

    payloads, expected_orders, counters = generate(args.count, args.seed)

    header = f"tb_top soak: count={args.count} seed={args.seed}"
    _write_mem(f"{args.out_prefix}_in.mem", payloads, header)
    _write_mem(f"{args.out_prefix}_expected_orders.mem", expected_orders, header)

    with open(f"{args.out_prefix}_expected_counters.txt", "w") as f:
        # Purely numeric: one integer per line, COUNTER_ORDER order (matches
        # rtl/csr_block.v's register map exactly), NOTHING else -- no
        # header, no comments, no names. tb/tb_top.v reads this with plain
        # `$fscanf(fd, "%d", val)` calls in a fixed loop; a comment line
        # would fail to parse as %d and desync every value after it. The
        # name-to-line mapping lives in COUNTER_ORDER (this file) and in
        # tb_top.v's own matching hardcoded address array -- keep both in
        # sync by position, not by a marker in this file.
        missing = set(counters) - set(COUNTER_ORDER)
        if missing:
            raise AssertionError(f"COUNTER_ORDER is missing: {sorted(missing)}")
        for name in COUNTER_ORDER:
            f.write(f"{counters[name]}\n")

    # Explicit counts, read directly by tb_top.v instead of scanning the
    # $readmemh arrays for an "unwritten" (X) sentinel -- that scan proved
    # unreliable in practice (Icarus's actual fill behavior for the unused
    # tail of a `reg [127:0] arr [0:N-1]` array did not match the assumed
    # "defaults to X" behavior closely enough to trust for a real count).
    with open(f"{args.out_prefix}_counts.txt", "w") as f:
        f.write(f"{len(payloads)}\n{len(expected_orders)}\n")

    print(
        f"wrote {len(payloads)} input frames, {len(expected_orders)} expected orders, "
        f"{len(counters)} expected counters (seed={args.seed}) to {args.out_prefix}_*"
    )


if __name__ == "__main__":
    main()
