# Contract: `rtl/risk_engine.v`

Status: ready to hand off, but **this is the largest, highest-stakes
contract in the project so far — read all of §1 and §2 before starting,
not just skim for the port list.** Two real bugs in `sim/golden_model.py`
were found and fixed while designing this module's interface (D16, D17),
one of which (D17) made an entire required gate completely unreachable in
the reference model until it was fixed. Depends on
`docs/contracts/signal_engine.md`, `docs/contracts/tob_engine.md`,
`docs/contracts/seq_monitor.md` output shapes — all three already built and
committed (S3/S5).

## 1. Background (design principle, the nine gates, and what this module does NOT do yet)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain). `risk_engine.v` is the master spec's pre-trade risk block
(§3.1 block `[I]`, §8, FR-41..48): every order intent from `signal_engine.v`
passes through nine independent gates, evaluated in parallel in a single
cycle (FR-42), before it can become an accepted order. **This is the last
stage of the fast path and must never be slower, disableable, or
bypassable (FR-41, §8.1) — this is the single requirement to defend most
carefully while implementing.**

| ID | Gate | Blocks when |
| :-- | :-- | :-- |
| `0x01` | Kill switch | `kill_latched` |
| `0x02` | Max order size | `sig_qty > cfg_max_order_qty` |
| `0x03` | Max position | `\|position ± sig_qty\| > cfg_max_position` |
| `0x04` | Price band | `\|sig_price − mid\| > cfg_price_band` |
| `0x05` | Stale data | cycles since the symbol's last touch `> cfg_max_age` |
| `0x06` | Sequence gap | `seq_gap` (sticky, from `seq_monitor.v`) |
| `0x07` | Crossed book | `crossed[slot]` (from `tob_engine.v`) |
| `0x08` | Throttle | token bucket empty |
| `0x09` | ML (adverse selection) | `adverse_risk == 1` and `cfg_ml_action == 0` |

**Reject-reason priority is by gate number, lowest wins (FR-43) — but every
gate that fired still gets its own counter incremented**, not just the
reported one. This module exposes nine independent `gate_*_fired` pulses
for exactly that reason; a later CSR/counters block accumulates them (same
"raw pulse, counters elsewhere" pattern as every prior module in this
repo).

**Three things this contract deliberately does NOT build**, each with a
plain input port standing in for it instead (same pattern as `cfg_*` ports
standing in for `csr_block.v` everywhere else in this repo):

- `ml_policy.v` doesn't exist yet (S6, blocked on the ML collaborator's S4).
  `adverse_risk` is a plain 1-bit input, exactly mirroring
  `sim/golden_model.py`'s `process_message(..., adverse_risk: bool)`
  parameter.
- No free-running cycle counter exists yet (FR-53/54's full
  timestamp-carrying infrastructure is S9's job). `cur_cycle` is a plain
  32-bit input — whatever eventually drives it (a small dedicated counter,
  or S9's fuller mechanism) is out of scope here; this module only needs
  *a* monotonically-incrementing value, not ownership of producing one.
- TX-slot/overflow tracking (§7.5, `cnt_order_overflow`) is **not** one of
  the nine numbered gates and `T22_overflow` is not part of S7's gate list
  (`T15`-`T21` only) — it's deferred to whichever module actually paces
  transmission (`order_builder.v`/`eth_mac_if.v`, S8). This module accepts
  an order whenever no gate fires; it does not know or care whether the
  TX path can accept it yet.

## 2. What you're building

**File:** `rtl/risk_engine.v`
**Testbench:** `tb/tb_risk_engine.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module risk_engine #(
    parameter integer NUM_SYMBOLS = 4   // matches every other S3/S5 module
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low; FR-18-style reset semantics
                                 // apply here too (§2.7): no stale
                                 // kill_latched/position/token state
                                 // readable after reset.

    // from signal_engine.v -- one order intent per pulse
    input  wire        sig_valid,
    input  wire [1:0]  sig_slot,
    input  wire [7:0]  sig_side,     // SIDE_BID(0x00)/SIDE_ASK(0x01)
    input  wire [31:0] sig_price,
    input  wire [31:0] sig_qty,

    // from tob_engine.v -- msg_applied/applied_slot fire on EVERY accepted
    // message (any msg_type), one cycle before signal_engine.v's matching
    // sig_valid for the same triggering message when it's book-modifying
    // and signal-worthy (docs/contracts/tob_engine.md, S2.4 below). Also
    // used for gate 0x07 (crossed) and gate 0x04's mid-price.
    input  wire                       msg_applied,
    input  wire [1:0]                 applied_slot,
    input  wire [NUM_SYMBOLS*32-1:0]  bid_price,
    input  wire [NUM_SYMBOLS*32-1:0]  ask_price,
    input  wire [NUM_SYMBOLS-1:0]     crossed,

    // from seq_monitor.v -- feed-wide sticky bit, not per-slot (gate 0x06)
    input  wire         seq_gap,

    // ML verdict, external -- ml_policy.v doesn't exist yet (S1's third bullet)
    input  wire         adverse_risk,

    // free-running cycle counter, external (S1's second bullet). Must be
    // monotonically incrementing (wraparound-safe subtraction is used, see
    // S2.4 -- no explicit handling needed as long as elapsed spans stay
    // well under 2^32, true for any realistic cfg_max_age).
    input  wire [31:0] cur_cycle,

    // kill switch, ALREADY synchronized (2FF, rtl/common/sync_2ff.v) --
    // that synchronization is board-integration's job (tob_top.v), not
    // this module's. Active-low, matching D6's board convention.
    input  wire        kill_sw_n,

    // config (S9 CSR map), direct ports standing in for csr_block.v, same
    // pattern as every other S3/S5 module
    input  wire [31:0] cfg_max_order_qty,   // 0x28, default 500
    input  wire [31:0] cfg_max_position,    // 0x2C, default 1000
    input  wire [31:0] cfg_price_band,      // 0x30, default 50
    input  wire [31:0] cfg_max_age,         // 0x34, default 1_250_000
    input  wire [31:0] cfg_token_max,       // 0x38, default 8
    input  wire [31:0] cfg_token_refill_cycles, // 0x3C, default 12_500
    input  wire        cfg_ml_action,       // ML_CTRL bit0: 0 block / 1 reduce
    input  wire [3:0]  cfg_ml_reduce_shift, // ML_CTRL bits 4:1, 0-15
    input  wire        cfg_kill_clear,      // CTRL bit1, one-cycle pulse

    // order decision: registered one cycle after sig_valid (same
    // convention as every S3/S5 module's data outputs)
    output reg         order_valid,
    output reg  [1:0]  order_slot,
    output reg  [7:0]  order_side,
    output reg  [31:0] order_price,
    output reg  [31:0] order_qty,       // D16: reduced_qty when ML reduce
                                         // applied, else sig_qty unchanged
    output reg  [7:0]  reject_reason,   // 0x00 = accepted; else lowest-
                                         // numbered fired gate ID (1-9)

    // one pulse per gate per evaluated intent, registered alongside the
    // above (FR-43: every fired gate counts, not just the reported one)
    output reg         gate_kill_fired,
    output reg         gate_size_fired,
    output reg         gate_position_fired,
    output reg         gate_band_fired,
    output reg         gate_stale_fired,
    output reg         gate_seqgap_fired,
    output reg         gate_crossed_fired,
    output reg         gate_throttle_fired,
    output reg         gate_ml_fired,

    // status: level outputs for STATUS register / LED (board integration's
    // job to actually wire to a pin) and debug visibility
    output wire        kill_latched,
    output wire [NUM_SYMBOLS*32-1:0] position   // signed two's-complement
                                                  // per slot, FR-45
);
```

### 2.2 Kill switch (FR-46/47)

One register, `kill_latched`. Assert wins over clear if both occur the same
cycle (safety-first — this project's established fail-safe philosophy,
same reasoning as FR-26's forced-safe classifier state elsewhere):

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)            kill_latched <= 1'b0;
    else if (~kill_sw_n)   kill_latched <= 1'b1;   // assert: highest priority
    else if (cfg_kill_clear) kill_latched <= 1'b0; // explicit clear only
    // else: hold. Deassertion alone (kill_sw_n returning to 1) does NOT
    // clear it -- FR-46's explicit requirement.
end
```

`kill_sw_n` arrives already 2FF-synchronized — do not add your own
synchronizer here; that would just add unneeded latency to a signal that's
already clean by the time it reaches this module.

### 2.3 Token bucket throttle (FR-8.4, gate `0x08`)

A **continuously free-running** refill counter, independent of message
arrival — not a lazy "compute elapsed cycles when a message shows up"
calculation (which is how `sim/golden_model.py` does it, using Python's
division; see the note below for why RTL should NOT copy that structure
literally). `refill_ctr` increments every cycle; when it would reach
`cfg_token_refill_cycles`, `token_bucket` gains one token (saturating at
`cfg_token_max`) and the counter carries its remainder forward (not reset
to 0 — preserves exactness across boundaries, matching
`sim/golden_model.py`'s `_last_refill_cycle += refills * refill_cycles`):

```verilog
wire refill_tick = (refill_ctr + 32'd1) >= cfg_token_refill_cycles;
wire [31:0] refill_ctr_next = refill_tick
    ? (refill_ctr + 32'd1 - cfg_token_refill_cycles)
    : (refill_ctr + 32'd1);
wire [31:0] token_after_refill = (refill_tick && token_bucket < cfg_token_max)
    ? token_bucket + 32'd1 : token_bucket;
```

`gate_throttle_fired` (§2.5) reads `token_after_refill`, not the
pre-refill `token_bucket` — matching `sim/golden_model.py`'s ordering,
which refills *before* checking. `token_bucket`'s single next-state
expression must combine this refill with any same-cycle consumption from
an accepted order (§2.6) — **do not write two separate non-blocking
assignments to `token_bucket` in the same `always` block**; only the
textually-last one would actually apply, silently dropping the other. On
reset, `token_bucket <= cfg_token_max` (sampling the config input directly
at the reset edge — standard, valid Verilog; every other S3/S5 module's
`cfg_*` ports are stable well before reset deasserts).

**Why continuous per-cycle refill instead of literally translating
`sim/golden_model.py`'s `elapsed // refill_cycles` (a batch division at
each message):** that Python code computes an exact result lazily, only
when a message needs it — building a real hardware divider to replicate
that structure would be expensive for no benefit. A counter that
increments every cycle and rolls over at the same boundary points produces
an **identical** `token_bucket` value at any point it's actually read
(any sig_valid cycle), because "N refill periods have elapsed" is the same
fact whether computed by division at one instant or by continuously
counting up to it — there's no approximation here, just a different (and
simpler-to-build) way of arriving at the same number.

### 2.4 Staleness (gate `0x05`) — D17, read this before writing any of this section

**`sim/golden_model.py` had this gate completely unreachable until
`docs/design_decisions.md` D17 fixed it, and the exact same bug is trivial
to reproduce in RTL if you don't design around it deliberately.** The root
cause: comparing "now" against a per-symbol last-touch timestamp is wrong
if the *triggering message itself* has already refreshed that timestamp by
the time the comparison runs. In this pipeline, `tob_engine.v`'s
`msg_applied`/`applied_slot` for a given triggering message arrive exactly
**one cycle before** `signal_engine.v`'s matching `sig_valid`/`sig_slot`
for that same message (when it's book-modifying and signal-worthy) — so a
naive "read `last_update_cycle[sig_slot]` combinationally when `sig_valid`
fires" would see the value *this same message already wrote one cycle
earlier*, always reading an elapsed gap of ~0, exactly reproducing D17 in
hardware.

**The fix: pipeline the *pre-update* timestamp forward by one cycle,
alongside the message, instead of re-reading the (by-then-already-updated)
per-slot state at the `sig_valid` cycle.**

```verilog
// Per-slot staleness timestamps -- refreshed on EVERY msg_applied event of
// ANY msg_type (matching sim/golden_model.py: all four message types
// touch book.last_update_cycle), independent of whether that message ends
// up producing a signal.
reg [NUM_SYMBOLS*32-1:0] last_update_cycle;   // flattened, slot i at [i*32 +: 32]

// Captured the cycle a message arrives (msg_applied), BEFORE this same
// cycle's write below overwrites the per-slot value -- these are the
// values gate 0x05 will actually compare against, one cycle later.
reg [31:0] pend_prev_cycle;   // last_update_cycle[applied_slot] as it was
                               // BEFORE this message
reg [31:0] pend_msg_cycle;    // cur_cycle at the moment this message arrived

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        last_update_cycle <= {NUM_SYMBOLS*32{1'b0}};
        pend_prev_cycle    <= 32'd0;
        pend_msg_cycle     <= 32'd0;
    end else if (msg_applied) begin
        pend_prev_cycle <= last_update_cycle[applied_slot*32 +: 32]; // OLD value
        pend_msg_cycle  <= cur_cycle;
        last_update_cycle[applied_slot*32 +: 32] <= cur_cycle;       // refresh
    end
end
```

Because `book_upd_valid` (`tob_engine.v`) can only ever be high on a cycle
where `msg_applied` is *also* high (it's `msg_applied & (QUOTE|CLEAR)`),
and `sig_valid` is `book_upd_valid` registered one cycle later, `pend_prev_cycle`/
`pend_msg_cycle` are **guaranteed** to hold exactly this same triggering
message's captured values on the cycle `sig_valid` reads them — no explicit
"is this the right message" bookkeeping needed, the one-cycle pipeline
alignment is automatic by construction. `gate_stale_fired` (§2.5) is:

```verilog
wire gate_stale_fired_c = (pend_msg_cycle - pend_prev_cycle) > cfg_max_age;
```

**Do not** compute this as `(cur_cycle - last_update_cycle[sig_slot])` read
fresh at the `sig_valid` cycle — that is the exact D17 bug, reintroduced in
hardware. If your testbench's D17-regression case (§3) passes with that
version too, your test isn't actually exercising the pipeline correctly;
re-check it against the case in `sim/test_golden_model_handcase.py`
(`n3`-`n6`) directly.

### 2.5 The other six gates, and reject-reason priority

All computed combinationally on the `sig_valid` cycle, from the *applied
slot's* current state (`bid_price`/`ask_price`/`crossed` sliced at
`sig_slot`, `position` sliced at `sig_slot`):

```verilog
wire gate_kill_fired_c     = kill_latched;
wire gate_size_fired_c     = (sig_qty > cfg_max_order_qty);

// FR-45/FR-48: gate 0x03 uses the UNREDUCED sig_qty, deliberately -- see
// S2.6. signed_qty/prospective computed at >=33 bits to avoid overflow.
wire signed [32:0] signed_qty     = (sig_side == 8'h00) ? {1'b0, sig_qty}
                                                          : -{1'b0, sig_qty};
wire signed [32:0] prospective    = signed_qty
                                     + $signed(position[sig_slot*32 +: 32]);
wire        [32:0] abs_prospective = prospective[32] ? -prospective : prospective;
wire gate_position_fired_c = (abs_prospective > {1'b0, cfg_max_position});
```

**Erratum, corrected in-line above (previously read
`$signed({1'b0, position[sig_slot*32 +: 32]})`):** `position` is a *stored*
two's-complement signed value, not a genuinely-unsigned magnitude like
`sig_qty` — a literal `{1'b0, ...}` zero-pad forces what should be the sign
bit to `0` before widening, turning a negative position into a huge
positive number instead of preserving it, breaking every gate `0x03` check
after the first short sale. `$signed(position[sig_slot*32 +: 32])` applied
directly (no manual padding) is correct: Verilog's signed-arithmetic
context sign-extends a `$signed`-tagged narrower operand automatically when
it's added to the wider `signed_qty`. `sig_qty`'s own `{1'b0, sig_qty}`
padding a few lines above is *not* the same mistake — `sig_qty` is a
genuinely unsigned magnitude (never negative on the wire), so zero-extending
it is correct; only an already-signed stored value like `position` needs
sign-extension instead. Same distinction applies to `final_signed_qty`/
`next_pos` in §2.6 below — sign-extend `position`, zero-extend `sig_qty`/
`reduced_qty_c`.
```verilog

// FR-4-style overflow-safe mid: 33-bit sum before the shift (feature_extractor.v
// precedent, docs/contracts/feature_extractor.md), then a SIGNED difference
// against sig_price -- both are unsigned prices, so a plain unsigned
// subtraction underflows exactly like the spread/mid footguns already
// documented in signal_engine.v/feature_normalizer.v's contracts.
wire [32:0] midsum = {1'b0, bid_price[sig_slot*32 +: 32]}
                    + {1'b0, ask_price[sig_slot*32 +: 32]};
wire [31:0] mid    = midsum[32:1];
wire signed [32:0] band_diff = $signed({1'b0, sig_price}) - $signed({1'b0, mid});
wire        [32:0] abs_band  = band_diff[32] ? -band_diff : band_diff;
wire gate_band_fired_c     = (abs_band > {1'b0, cfg_price_band});

wire gate_stale_fired_c    = (pend_msg_cycle - pend_prev_cycle) > cfg_max_age; // S2.4
wire gate_seqgap_fired_c   = seq_gap;
wire gate_crossed_fired_c  = crossed[sig_slot];
wire gate_throttle_fired_c = (token_after_refill == 32'd0);                    // S2.3
wire gate_ml_fired_c       = adverse_risk & ~cfg_ml_action;
```

`reject_reason` is a plain priority encode, lowest gate number wins
(FR-43):

```verilog
wire [7:0] reject_reason_c =
    gate_kill_fired_c     ? 8'd1 :
    gate_size_fired_c     ? 8'd2 :
    gate_position_fired_c ? 8'd3 :
    gate_band_fired_c     ? 8'd4 :
    gate_stale_fired_c    ? 8'd5 :
    gate_seqgap_fired_c   ? 8'd6 :
    gate_crossed_fired_c  ? 8'd7 :
    gate_throttle_fired_c ? 8'd8 :
    gate_ml_fired_c       ? 8'd9 : 8'd0;
wire accepted_c = sig_valid & (reject_reason_c == 8'd0);
```

**Every** `gate_*_fired_c` wire above (not just the one that becomes
`reject_reason`) drives its own output pulse (registered, §2.7) — a
message can trip several gates at once, and FR-43 requires every one of
their counters to increment, even though only the lowest-numbered gate
becomes the reported reason.

### 2.6 ML reduce and the accepted-order state update (D16)

```verilog
wire [31:0] reduced_qty_c = (adverse_risk & cfg_ml_action)
    ? ((sig_qty >> cfg_ml_reduce_shift) == 32'd0 ? 32'd1 : (sig_qty >> cfg_ml_reduce_shift))
    : sig_qty;
```

(`max(1, sig_qty >> shift)` — the floor-to-1 matters: a large shift must
never produce a zero-quantity "order.")

**D16: when `accepted_c`, the position ledger update uses `reduced_qty_c`'s
signed value, NOT `signed_qty` from §2.5's gate-`0x03` check.**
`sim/golden_model.py` had a real bug here (fixed, documented in
`docs/design_decisions.md` D16): the *gate check* correctly uses the
unreduced quantity (FR-48 — the ML reduction is gate 0x09's own action,
independent of gates 0x01-0x08's evaluation), but the *actual ledger
update*, once accepted, must reflect what was actually ordered:

```verilog
wire signed [32:0] final_signed_qty = (sig_side == 8'h00) ? {1'b0, reduced_qty_c}
                                                             : -{1'b0, reduced_qty_c};
```

`position[sig_slot]` updates by `final_signed_qty` on an `accepted_c`
cycle, not `signed_qty`. `order_qty` (the registered output, §2.1) is
`reduced_qty_c` as well, matching `sim/golden_model.py`'s
`OrderRecord.quantity = reduced_qty`.

### 2.7 Committing state and registering the output

On an `accepted_c` cycle: `token_bucket <= token_bucket_next` (§2.3's
combined refill+consume expression) and `position[sig_slot] <=
position[sig_slot] + final_signed_qty` (§2.6). On any other cycle
(including a rejected `sig_valid`), `token_bucket` still applies its
free-running refill (§2.3 runs regardless of acceptance) but is **not**
decremented, and `position` does not change.

`order_valid`/`order_slot`/`order_side`/`order_price`/`order_qty`/
`reject_reason`/all nine `gate_*_fired` outputs are registered one cycle
after `sig_valid` (same convention as every S3/S5 data output — e.g.
`docs/contracts/feature_extractor.md` §2.5). On a cycle where `sig_valid`
is low, all of the above hold `order_valid<=0`/`gate_*_fired<=0`/
`reject_reason<=8'd0` the following cycle.

**Reset (FR-18-style, applied to this module's own state):** `kill_latched`,
`position` (all slots), `token_bucket` (to `cfg_token_max`), `refill_ctr`,
`last_update_cycle` (all slots), `pend_prev_cycle`/`pend_msg_cycle` all
reset to their stated defaults — no stale value readable from any of them
immediately after `rst_n` deasserts.

## 3. Testbench requirements (`tb/tb_risk_engine.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o risk_engine_tb.vvp rtl/risk_engine.v tb/tb_risk_engine.v && vvp risk_engine_tb.vvp`),
no manual waveform inspection. Drive `sig_*`/`msg_applied`/`applied_slot`/
the book-state buses/`seq_gap`/`adverse_risk`/`cur_cycle`/`kill_sw_n`/
`cfg_*` directly (no need to instantiate `signal_engine.v`/`tob_engine.v`/
`seq_monitor.v`). Cover, at minimum:

- **T15-style, gate `0x02`:** `sig_qty` at, one below, one above
  `cfg_max_order_qty` — fires only above.
- **T16-style, gate `0x03`:** walk `position[slot]` to within one unit of
  `±cfg_max_position` via a sequence of accepted orders, confirm the gate
  fires exactly when the *next* order would cross the limit, in both
  directions (long and short).
- **T17-style, gate `0x04`:** `sig_price` at the band edge and one tick
  outside it, both above and below `mid` (exercises the signed-subtraction
  footgun in both directions, §2.5).
- **T18-style, gate `0x05` — port `sim/test_golden_model_handcase.py`'s
  `n3`-`n6` sequence directly** (same cycle numbers, same `max_age`): a
  fresh touch, silence past `max_age`, a rejected intent
  (`reject_reason==5`), then an accepted one shortly after. This is the
  regression test for D17 — see §2.4's explicit warning about the naive
  version that would pass a less careful test.
- **T19-style, gate `0x08`:** burst enough accepted orders to empty the
  token bucket (`cfg_token_max` orders back-to-back), confirm the next
  intent is throttled, then advance `cur_cycle`/hold time past
  `cfg_token_refill_cycles` and confirm a token becomes available again
  without a message needing to arrive to "trigger" the refill (§2.3's
  free-running design) — i.e. drive `cur_cycle` forward with no `sig_valid`
  activity in between, then send one intent and confirm it succeeds.
- **T20-style, gate `0x01`:** assert `kill_sw_n` mid-stream, confirm every
  subsequent intent is blocked with `reject_reason==1` regardless of how
  favorable it otherwise is; confirm deasserting `kill_sw_n` alone does
  **not** clear it; confirm `cfg_kill_clear` does.
- **T21-style, multi-gate (FR-43):** construct an intent that trips two
  gates at once (e.g. kill switch asserted **and** oversized qty) — confirm
  `reject_reason==1` (lowest wins) but **both** `gate_kill_fired` and
  `gate_size_fired` pulse that cycle.
- **Gate `0x06`/`0x07` (seq gap / crossed):** `seq_gap=1` blocks regardless
  of everything else being favorable; `crossed[slot]=1` likewise. Confirm
  each in isolation (only that gate fires).
- **D16 regression, ML reduce path:** `adverse_risk=1`, `cfg_ml_action=1`,
  a `cfg_ml_reduce_shift` that halves `sig_qty`, otherwise gate-clean intent
  — confirm `order_qty` reports the reduced value AND `position` updates by
  the reduced value, not the original `sig_qty` (port
  `sim/test_golden_model_handcase.py`'s `n1`/`n2` values directly).
- **ML block path:** `adverse_risk=1`, `cfg_ml_action=0` — `gate_ml_fired`
  pulses, `reject_reason==9`, no order.
- **`sig_valid=0`:** `order_valid` stays low the following cycle regardless
  of what the other inputs read.
- **Reset:** `kill_latched`, all four slots' `position`, and the token
  bucket read their documented defaults immediately after `rst_n`
  deasserts, with no dependency on pre-reset state.
- On any mismatch, `$display` what was expected vs. what happened (which
  case, which field/gate, expected vs. actual), then a final
  `$display("FAIL")` / `$display("PASS")` line — this project's plain
  self-checking-Verilog convention.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o risk_engine_tb.vvp rtl/risk_engine.v tb/tb_risk_engine.v` compiles with zero warnings.
- [ ] `vvp risk_engine_tb.vvp` prints `PASS`.
- [ ] `rtl/risk_engine.v` is Verilog-2001 only (no SystemVerilog).
- [ ] Gate `0x05` uses the pipelined `pend_prev_cycle`/`pend_msg_cycle` pair
      (§2.4), not a fresh re-read of `last_update_cycle[sig_slot]` at the
      `sig_valid` cycle — the D17 regression test (§3) is the check for
      this, but also read your own RTL and confirm which one it actually
      does.
- [ ] D16's position update uses `reduced_qty_c`'s signed value, not the
      unreduced `signed_qty` gate `0x03`'s own check used (§2.6) — these
      are deliberately different variables for deliberately different
      purposes; verify both are actually used where specified, not
      collapsed into one by mistake.
- [ ] `token_bucket`'s refill is a single, continuously-incrementing
      process (§2.3), not gated on message/signal activity, and its
      next-state expression combines refill and consumption in one
      assignment (no double-write bug).
- [ ] `reject_reason` priority is lowest-gate-number-wins, and **every**
      fired gate's own `gate_*_fired` pulse fires, not just the reported
      one (T21-style test, §3).
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- `ml_policy.v`/`ml_classifier_wrap.v` — `adverse_risk` is an external
  input here; computing it is S6, blocked on the ML collaborator's S4.
- A dedicated free-running cycle-counter *module* — `cur_cycle` is a plain
  input; whatever drives it (a small counter, or S9's fuller FR-53/54
  infrastructure) is a separate concern.
- TX-slot pacing / `cnt_order_overflow` (§7.5) — not one of the nine gates,
  not part of S7's gate list, deferred to `order_builder.v`/`eth_mac_if.v`
  (S8). This module accepts whenever no gate fires, regardless of whether
  anything downstream can actually transmit yet.
- `cfg_reject_report`/the `0x11` diagnostic frame encoder (FR-44) — D7
  already deferred this past S7's gate; `reject_reason` as a raw signal
  (for counters and testbench assertions) is all this milestone needs.
- Driving the physical kill-switch LED — `kill_latched` is exposed as a
  status output; wiring it to a pin is board-integration's job
  (`tob_top.v`), not this module's.
- 2FF-synchronizing `kill_sw_n` itself — arrives already synchronized
  (§2.2); this module must not add its own synchronizer on top.
- Counters that persist any `gate_*_fired`/`cnt_*` count — this module
  only emits raw pulses; a later CSR/counters block owns accumulating
  them, same pattern as every prior module in this repo.
