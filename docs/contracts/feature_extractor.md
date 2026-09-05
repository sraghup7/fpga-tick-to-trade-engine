# Contract: `rtl/feature_extractor.v`

Status: ready to hand off, but **read this whole contract before starting,
especially §1 and §2.5-2.7** — this module has more non-obvious design
constraints than any other S3 module, several of them resolved only while
writing this contract (see `docs/design_decisions.md` D13). Depends on
`docs/contracts/tob_engine.md`'s output shapes (not on `tob_engine.v` being
built yet).

**Bit-exactness reference: `sim/feature_golden.py`.** This is not optional
prose to skim — `sim/feature_golden.py`'s `FeatureTracker` class is the
literal, executable definition of correct behavior for this module, written
and hand-verified (`sim/test_feature_golden_handcase.py`) specifically to
resolve the ambiguities the master spec and `ml_engineer_brief.md` leave
open. Every rule in §2 below is a restatement of what that file does; if
anything here and `sim/feature_golden.py` ever seem to disagree, the Python
file is authoritative (same rule this repo already applies to
`sim/golden_model.py` for the deterministic path — see
`docs/contracts/md_parser.md` §2.5's precedent).

## 1. Background (why this is the hardest module in S3)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain) parsing a synthetic market-data feed. `feature_extractor.v` is
the master spec's F0-F7 computation block (§3.1 blocks `[G2]`, FR-20/21/24/25):
after each book-modifying update, it computes eight fixed-point features
(§5.3) that eventually feed a linear ML classifier via `feature_normalizer.v`.

**Two features, F5 (update rate) and F7 (short-term volatility), are
underspecified by the master spec and by `ml_engineer_brief.md` itself** —
that document says outright, of the shared window they're built from,
"decide whether the current event is included in the window or not, and
write it down." That write-down is `docs/design_decisions.md` D13 and
`sim/feature_golden.py`'s module docstring; read D13 once before starting,
it's short and explains the reasoning behind every rule in §2 below, not
just the rule itself.

**This module needs `tob_engine.v`'s *combined* apply signal, not just its
book-modifying one.** `tob_engine.v` (`docs/contracts/tob_engine.md`)
exposes two related pulses: `msg_applied` (any accepted, non-duplicate
message, of any `msg_type`) and `book_upd_valid` (the narrower subset that's
specifically `QUOTE`/`CLEAR`). This module needs **both**: `book_upd_valid`
triggers a full F0-F7 computation and output (FR-20's literal trigger), but
`msg_applied` alone (i.e. a `TRADE` or `HEARTBEAT` that isn't book-modifying)
still has to **advance the shared F5/F7 window** and, for `TRADE`
specifically, **update F6** — without producing a feature-vector output.
Missing this is the single most likely way to get F5 subtly wrong (see D13's
"why every event, not just book-modifying events" reasoning).

## 2. What you're building

**File:** `rtl/feature_extractor.v`
**Testbench:** `tb/tb_feature_extractor.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module feature_extractor #(
    parameter integer NUM_SYMBOLS = 4,
    parameter integer WINDOW      = 16   // elaboration-time (D13); one of
                                          // 4, 8, 16, 32 -- runtime
                                          // reconfiguration via CSR
                                          // ML_WINDOW is deferred, not this
                                          // contract's job (S5 out of scope)
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low; same reset style as the rest
                                 // of this repo. Resets ALL 4 slots' history
                                 // (prev_*, window, last_trade_dir,
                                 // seen_first) to the all-zero state --
                                 // identical to what a per-slot CLEAR does
                                 // (S2.4), just applied to every slot at once.

    // from md_parser.v -- only meaningful on a msg_applied cycle
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_side,

    // from tob_engine.v -- see S1 for why both are needed
    input  wire                       msg_applied,     // any accepted msg
    input  wire                       book_upd_valid,  // QUOTE|CLEAR subset
    input  wire [1:0]                 applied_slot,
    input  wire [NUM_SYMBOLS*32-1:0]  bid_price,       // post-update state
    input  wire [NUM_SYMBOLS*32-1:0]  bid_qty,
    input  wire [NUM_SYMBOLS*32-1:0]  ask_price,
    input  wire [NUM_SYMBOLS*32-1:0]  ask_qty,
    // bid_valid/ask_valid deliberately NOT consumed here -- see S2.7
    // (FR-26 masking is out of scope for this module).

    // one feature vector per book-modifying event, registered one cycle
    // after book_upd_valid (S2.5). All eight are plain 32-bit buses; F1,
    // F2, F3, F4, F6 hold two's-complement SIGNED values, F0/F5/F7 hold
    // plain unsigned values -- see S2.2's table. feature_normalizer.v
    // (docs/contracts/feature_normalizer.md) needs to know which is which.
    output reg          feat_valid,
    output reg  [1:0]   feat_slot,
    output reg  [31:0]  feat_f0_spread,
    output reg  [31:0]  feat_f1_mid_delta,
    output reg  [31:0]  feat_f2_imbalance,
    output reg  [31:0]  feat_f3_bid_chg,
    output reg  [31:0]  feat_f4_ask_chg,
    output reg  [31:0]  feat_f5_update_rate,
    output reg  [31:0]  feat_f6_last_trade_dir,
    output reg  [31:0]  feat_f7_volatility
);
```

### 2.2 The eight features (FR-20, S5.3, S5.5)

| ID | Sign | Formula (raw, pre-normalization) |
| :-- | :-- | :-- |
| F0 | unsigned | `ask_price[slot] - bid_price[slot]`, saturated to `[0, 2^32-1]` (never negative) |
| F1 | signed | `mid_t - mid_{t-1}` where `mid = (bid_price+ask_price) >> 1`; 0 on the first event after reset/clear |
| F2 | signed | `bid_qty[slot] - ask_qty[slot]` |
| F3 | signed | `bid_qty[slot] - prev_bid_qty`; 0 on the first event after reset/clear |
| F4 | signed | `ask_qty[slot] - prev_ask_qty`; 0 on the first event after reset/clear |
| F5 | unsigned | count of `is_update` slots in the shared `WINDOW`-deep window (S2.4) |
| F6 | signed | last trade's aggressor side: `+1` buy, `-1` sell, `0` = no trade yet (or reset since) |
| F7 | unsigned | sum of `abs_mid_delta` over the shared `WINDOW`-deep window (S2.4), saturated to `[0, 2^32-1]` |

F0 and F2 have no history dependency — compute them from the current
post-update `bid_price`/`bid_qty`/`ask_price`/`ask_qty` on every
`book_upd_valid` event, first event or not. **They are computed mechanically
regardless of `bid_valid`/`ask_valid`** — see S2.7.

### 2.3 Per-slot history state (FR-21)

For each of the `NUM_SYMBOLS` (4) slots, maintain:

- `prev_bid_price`, `prev_bid_qty`, `prev_ask_price`, `prev_ask_qty` (32-bit
  each) — the price/qty state as of the *previous* `book_upd_valid` event
  for this slot.
- `seen_first` (1 bit) — 0 until this slot's first `book_upd_valid` event
  since reset/clear.
- `last_trade_dir` (store as a 32-bit two's-complement register for
  uniformity with the output width, even though only `{-1, 0, +1}` are ever
  written) — F6's persistent state.
- The shared `WINDOW`-deep window itself (S2.4).

All of the above reset to zero (`seen_first` to 0, `last_trade_dir` to 0,
window empty/all-zero) on `rst_n`, **and on a `book_upd_valid` cycle where
`msg_type == 0x03` (CLEAR)** for that specific slot — reset it first, then
treat this same CLEAR event as slot's new "first event" (D13). Concretely:
on a CLEAR, `prev_bid_price`/`prev_bid_qty`/`prev_ask_price`/`prev_ask_qty`
become 0 and `seen_first`/`last_trade_dir`/the window are cleared *before*
this event's own F0-F7 are computed and pushed — so a CLEAR always produces
`F1=F3=F4=0` (first-event rule applies to it) and its own window slot is
`(is_update=1, abs_delta=0)`, exactly like any other first event.

**This "reset to 0" applies only to the CLEAR event's own computation — it
does not persist for the *next* event on that slot, and this is easy to
misread from the prose above alone (a real gap in this contract's first
draft: `sim/test_feature_golden_handcase.py` originally stopped at the
CLEAR itself and never exercised the event after it).** `seen_first` is set
true as part of processing the CLEAR (same clock edge that pushes the
CLEAR's own window entry), and `prev_bid_price`/`prev_bid_qty`/
`prev_ask_price`/`prev_ask_qty` are then written *again*, unconditionally,
to **this CLEAR event's own `bid_price`/`bid_qty`/`ask_price`/`ask_qty`
inputs** — i.e. whatever (stale, since `tob_engine.v`'s CLEAR doesn't zero
price/qty, only `valid`) book state `tob_engine.v` presented for the CLEAR
message itself, not 0. Consequence: the very next `book_upd_valid` event on
that slot is **not** a first event and computes a real, generally nonzero
F1/F3/F4 against that stale post-clear baseline — it does not see
`prev_bid_price` etc. still sitting at 0. `sim/test_feature_golden_handcase.py`
step 7 is the regression test for this exact transition; read it (and its
hand-derivation comment) before implementing, not just steps 1-6.

### 2.4 The shared F5/F7 window (D13 — read this before implementing)

One `WINDOW`-deep shift register **per slot**, each entry holding
`(is_update: 1 bit, abs_mid_delta: 32 bits)`. It advances on **every**
`msg_applied` cycle for that slot (any `msg_type`), not only
`book_upd_valid` ones:

- On `book_upd_valid` (QUOTE/CLEAR): push `(1, |F1|)` — this event's own
  computed F1, absolute value, saturated unsigned.
- On `msg_applied & !book_upd_valid` (TRADE/HEARTBEAT): push `(0, 0)`.

**F5 = count of `is_update=1` entries across all `WINDOW` slots. F7 = sum of
`abs_mid_delta` across all `WINDOW` slots — recomputed from scratch every
time, not maintained as an incremental running sum.** This is a deliberate
choice, not a missed optimization: an incremental sliding-window sum (add
newest, subtract the value falling off the end) breaks the instant any
value has been saturated on the way in, because the original unclamped
value needed for a correct subtraction is gone. Recomputing from the full
window every event sidesteps that bug class entirely — build F5/F7 as a
plain `WINDOW`-wide adder tree / popcount tree (`WINDOW` ≤ 32, so at most 5
tree levels; still just adds, so it's within FR-23's "add/subtract/shift/
compare only" constraint) that reads all `WINDOW` window slots combinationally
and produces the sum/count for **this** event, including the entry just
pushed. F7's tree output saturates to `[0, 2^32-1]` **only at the very end**
— do not saturate any intermediate partial sum.

### 2.5 Timing: registered output, one cycle after `book_upd_valid`

Same convention `md_parser.v` already established in this repo
(`docs/contracts/md_parser.md` §2.6): the per-slot history registers (§2.3)
and the window (§2.4) need one clock edge to actually latch this event's
contribution before `feat_f0..f7` can correctly reflect it. On the cycle
`book_upd_valid` is high, compute F0-F7 combinationally from the *current*
(pre-this-event) history registers plus this event's `bid_price`/`bid_qty`/
`ask_price`/`ask_qty`/`applied_slot` inputs; register that combinational
result into `feat_f0..f7`/`feat_slot`/`feat_valid` on the next clock edge,
and update the history registers (`prev_*`, window, `seen_first`) on that
same edge. `feat_valid` pulses for exactly one cycle, one cycle after
`book_upd_valid`. No feature-vector output for a `msg_applied &
!book_upd_valid` (TRADE/HEARTBEAT) cycle — only the window/`last_trade_dir`
update happens for those (§2.4, §2.6).

### 2.6 F6 update (FR-25) — independent of the F0-F7 output trigger

On a `msg_applied` cycle where `msg_type == 0x02` (TRADE): update that
slot's `last_trade_dir` register — `+1` if `msg_side == 8'h00` (bid/buy
aggressor), `-1` for any other `msg_side` value (matching
`docs/contracts/tob_engine.md` §2.2's "any non-zero side means ask"
convention, applied here to the aggressor-side meaning instead of the
book-side meaning, but the same any-nonzero-means-the-other-one rule).
This does **not** produce a feature-vector output by itself (TRADE is not
`book_upd_valid`) — it only updates the persistent register that the *next*
`book_upd_valid` event for that slot will read as F6. It also pushes `(0,
0)` into that slot's window, same as any other non-book-modifying event
(§2.4).

### 2.7 Why `bid_valid`/`ask_valid` are not inputs here

FR-26 requires that an invalid, crossed, or gapped book force the ML
classifier's decision to a safe state — but that forcing is explicitly
**not** this module's job. `feature_extractor.v` computes F0-F7 mechanically
from whatever price/qty state `tob_engine.v` presents, with no validity
masking of any kind — confirmed against `sim/feature_golden.py`, which never
reads a `*_valid` argument at all. A concrete consequence worth knowing
before you're surprised by it in testbench output: if `ask_price` is still
at its reset value of 0 while `bid_price` is a real quoted price, F0 (`ask -
bid`) goes negative and **saturates to 0** — not a sentinel, not an error,
just `0`, mechanically, same as any other out-of-range unsigned result.
That's correct behavior for this module; masking it into something more
"meaningful" is a later ML-path stage's job (not built yet), and doing it
here would make this module disagree with `sim/feature_golden.py`.

## 3. Testbench requirements (`tb/tb_feature_extractor.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o feature_extractor_tb.vvp rtl/feature_extractor.v tb/tb_feature_extractor.v && vvp feature_extractor_tb.vvp`),
no manual waveform inspection. Drive `msg_type`/`msg_side`/`msg_applied`/
`book_upd_valid`/`applied_slot`/the four book-state buses directly (no need
to instantiate `tob_engine.v`/`md_parser.v`). Build `WINDOW=4` for this
testbench specifically (small enough to exercise window rollover without
hundreds of setup cycles) via the module's parameter.

**Port the exact seven-step sequence from `sim/test_feature_golden_handcase.py`
byte-for-byte** (same slot, same book states, same message-type sequence,
same `window=4`) and assert your RTL's `feat_f0..f7` match that file's
hand-computed expected tuples for each of its four `book_upd_valid` steps
(steps 1, 2, 5, 6, 7 in that file — steps 3/4 are the TRADE/HEARTBEAT that
produce no output but must still be driven, in order, for the window state
to line up correctly at step 5; **step 7, the event right after step 6's
CLEAR, is not optional** — it's the only case in this sequence that
exercises §2.3's "reset applies only to the CLEAR event itself, not the one
after it" rule, and is easy to get wrong without a test forcing the issue).
This is the single most important test in this contract — it's the one
directly checking D13's window semantics end-to-end, not just in isolation.
Read `sim/test_feature_golden_handcase.py`
directly; don't re-derive the expected values independently (if your
by-hand recomputation disagrees with that file, the file wins — flag the
discrepancy rather than silently trusting your own re-derivation).

Beyond that ported sequence, also cover:

- **Reset (FR-18-equivalent for this module):** after `rst_n` deasserts,
  the first `book_upd_valid` event for any slot must behave exactly like
  "first event" (F1=F3=F4=0), regardless of what was driven before reset.
- **CLEAR mid-sequence resets that slot only:** run a few events on slot 0,
  send a CLEAR for slot 0, confirm the next event on slot 0 is treated as a
  fresh first event (F1=F3=F4=0, F6 back to 0) while a *different* slot's
  independently-running history is completely unaffected by slot 0's clear.
- **F0 saturation at 0** (§2.7): drive `ask_price < bid_price` for a
  `book_upd_valid` event and confirm `feat_f0_spread == 0`, not a wrapped
  huge unsigned value and not a negative-looking bit pattern.
- **`WINDOW` boundary exactness:** with `WINDOW=4`, run more than 4 events
  for one slot and confirm F5/F7 only ever reflect the most recent 4 — an
  event that has aged out of the window must stop contributing (this is
  effectively re-verifying the ported handcase's step 5, but with a couple
  more events pushed further to make sure the *oldest* handcase entries
  really did drop out, not just that step 5's specific numbers happened to
  match).
- **Independent per-slot state:** interleave events across 2+ slots,
  confirm each slot's F5/F7/F6/prev-history is entirely independent of the
  others' event history (no shared window, no cross-slot F6 bleed).
- On any mismatch, `$display` what was expected vs. what happened (which
  step, which feature, expected vs. actual, referencing the
  `sim/feature_golden.py`/`sim/test_feature_golden_handcase.py` step number
  where applicable), then a final `$display("FAIL")` / `$display("PASS")`
  line — this project's plain self-checking-Verilog convention.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o feature_extractor_tb.vvp rtl/feature_extractor.v tb/tb_feature_extractor.v` compiles with zero warnings.
- [ ] `vvp feature_extractor_tb.vvp` prints `PASS`.
- [ ] `rtl/feature_extractor.v` is Verilog-2001 only (no SystemVerilog).
- [ ] The ported `sim/test_feature_golden_handcase.py` sequence (§3) passes
      bit-exactly, including the TRADE/HEARTBEAT steps that produce no
      output but still advance the window.
- [ ] F5/F7 are recomputed from the full window every event (§2.4), not
      maintained as an incremental running sum — check your own RTL for a
      `<=` that only adds a new term without ever fully re-deriving the sum
      from the stored window; that's the bug pattern D13 exists to avoid.
- [ ] A CLEAR resets exactly one slot's history, not all four (unless
      `rst_n` itself is asserted).
- [ ] `bid_valid`/`ask_valid` are not read anywhere in this module (§2.7) —
      if your implementation needs them, you've added masking that belongs
      to a later stage.
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- FR-26's safe-state forcing on invalid/crossed/gapped book — explicitly
  not this module's job, see §2.7. A later ML-path stage's concern.
- Runtime reconfiguration of `WINDOW` via the `ML_WINDOW` CSR register
  (FR-32) — `WINDOW` is an elaboration-time parameter here (D13); wiring a
  runtime-variable window is deferred to whichever milestone actually needs
  it (S6).
- `feature_normalizer.v`'s int8 saturating normalization
  (`docs/contracts/feature_normalizer.md`) — this module's outputs are raw,
  unnormalized 32-bit values.
- The classifier itself (`ml_classifier_wrap.v`) or the hysteresis policy
  (`ml_policy.v`) — not built yet, not this milestone.
- Computing `msg_applied`/`book_upd_valid`/`applied_slot` or the book-state
  buses — those come from `tob_engine.v` (`docs/contracts/tob_engine.md`).
- Any counter that persists feature statistics — none exist in the S9/S10
  register/counter maps for raw features; nothing to add here.
