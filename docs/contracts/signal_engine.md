# Contract: `rtl/signal_engine.v`

Status: ready to hand off. Self-contained. **Depends on `docs/contracts/tob_engine.md`'s
output shapes** (already built and committed — `rtl/tob_engine.v`, S3); you
do not need anything else from that milestone, and nothing from
`feature_extractor.v`/`feature_normalizer.v` (this is the *deterministic*
signal path, §3.2's other, independent convergent path — it does not touch
the ML path at all).

**Read §1 and §2.4 before starting** — this contract exists because a
genuine bit-exactness gap against `sim/golden_model.py` was found and fixed
(`docs/design_decisions.md` D15) while designing this module's arithmetic;
the naive, obvious implementation of one line of this spec is wrong.

## 1. Background (why this exists, and the arithmetic trap D15 exists to avoid)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain). `signal_engine.v` is the master spec's deterministic
spread+imbalance decision rule (§3.1 block `[H]`, §3.2 "signal path (fast)",
FR-35..40): after each book-modifying update, it decides whether the book
currently justifies a buy or sell order intent, using only comparisons,
subtraction, and shifts (FR-39 — no multiplier, no DSP on this path).

**FR-37 says buy and sell firing simultaneously is "impossible by
construction" — that claim is only true if this module's arithmetic matches
`sim/golden_model.py`'s exactly, and the obvious 32-bit implementation of
the imbalance shift does not.** `sim/golden_model.py` computes
`book.ask_qty << self.cfg.imb_shift` in Python, whose integers never
overflow. A plain 32-bit `ask_qty << cfg_imb_shift` in RTL can: with
`bid_qty = ask_qty = 0x80000000` and `imb_shift = 1`, both `ask_qty << 1`
and `bid_qty << 1` wrap to `0` in 32 bits, making `bid_qty >
(ask_qty << 1)` **and** `ask_qty > (bid_qty << 1)` both read true — a
spurious conflict the golden model would never produce for that exact
input (verified empirically, not just reasoned about — see
`docs/design_decisions.md` D15). §2.4 below specifies the fix; implement it
from the start, don't discover this the hard way in simulation.

## 2. What you're building

**File:** `rtl/signal_engine.v`
**Testbench:** `tb/tb_signal_engine.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module signal_engine #(
    parameter integer NUM_SYMBOLS = 4   // matches tob_engine.v
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low; match the reset style
                                 // already used elsewhere in this repo

    // from tob_engine.v -- post-update state of the applied slot
    // (docs/contracts/tob_engine.md), gated on book_upd_valid (FR-40:
    // evaluated only on book-modifying messages, not on a timer)
    input  wire                       book_upd_valid,
    input  wire [1:0]                 applied_slot,
    input  wire [NUM_SYMBOLS*32-1:0]  bid_price,
    input  wire [NUM_SYMBOLS*32-1:0]  bid_qty,
    input  wire [NUM_SYMBOLS-1:0]     bid_valid,
    input  wire [NUM_SYMBOLS*32-1:0]  ask_price,
    input  wire [NUM_SYMBOLS*32-1:0]  ask_qty,
    input  wire [NUM_SYMBOLS-1:0]     ask_valid,
    input  wire [NUM_SYMBOLS-1:0]     crossed,

    // config (S9 CSR map: MIN_SPREAD @0x1C default 2, IMB_SHIFT @0x20
    // default 1 range 0-3, ORDER_QTY @0x24 default 100). Direct ports,
    // standing in for csr_block.v, which does not exist yet -- same
    // pattern as every S3 module's cfg_* ports.
    input  wire [31:0] cfg_min_spread,
    input  wire [1:0]  cfg_imb_shift,   // 0-3, matches the CSR field's range
    input  wire [31:0] cfg_order_qty,

    // order intent: registered one cycle after book_upd_valid (same
    // convention as feature_extractor.v/feature_normalizer.v -- see S2.3).
    // sig_side reuses the wire-format SIDE_BID(0x00)/SIDE_ASK(0x01)
    // encoding (docs/contracts/md_parser.md S2.2), matching
    // sim/golden_model.py's OrderRecord.side.
    output reg         sig_valid,
    output reg  [1:0]  sig_slot,
    output reg  [7:0]  sig_side,
    output reg  [31:0] sig_price,
    output reg  [31:0] sig_qty,

    // status: one-cycle pulse, combinational with book_upd_valid (same
    // timing convention as every other module's err_*/status pulses in
    // this repo, e.g. frame_classifier.v's err_frame_len). FR-37: fires
    // instead of emitting any order intent. See S2.4/S2.5 for why this is
    // provably unreachable under a correct implementation, and S5 for what
    // that means for testing it.
    output wire        err_signal_conflict
);
```

### 2.2 The two rules (FR-35/FR-36)

For the applied slot (`bid_price`/`bid_qty`/`bid_valid`/`ask_price`/
`ask_qty`/`ask_valid`/`crossed`, all sliced at `applied_slot`):

```text
buy_ok  = bid_valid AND ask_valid AND NOT crossed
          AND (ask_price - bid_price) >= cfg_min_spread
          AND bid_qty > (ask_qty << cfg_imb_shift)      -- wide-precision, S2.4

sell_ok = bid_valid AND ask_valid AND NOT crossed
          AND (ask_price - bid_price) >= cfg_min_spread
          AND ask_qty > (bid_qty << cfg_imb_shift)      -- wide-precision, S2.4
```

Both are evaluated combinationally from the current-cycle inputs on any
`book_upd_valid` cycle.

**`crossed` is a required, independent input — do not try to derive "not
crossed" from the spread comparison instead.** `ask_price - bid_price`,
computed as plain unsigned 32-bit subtraction, **underflows to a huge
positive value** when the book is actually crossed (`bid_price >=
ask_price`) — a crossed book can look like it has an enormous spread if
nothing else catches it. Reading `tob_engine.v`'s already-computed
`crossed[applied_slot]` output directly and ANDing it in is what actually
guards against this; nothing needs to be done to "fix" the spread
subtraction itself, since `~crossed` zeroes the whole AND term regardless
of what a misleading wrapped spread value would otherwise say.

### 2.3 Timing and order-intent output (FR-38)

Same convention as every S3 module: combinational evaluation on the
`book_upd_valid` cycle, registered output one cycle later.

- If `buy_ok` (and not a conflict, S2.5): `sig_valid<=1`,
  `sig_slot<=applied_slot`, `sig_side<=8'h00` (BID), `sig_price<=ask_price`
  (buy at the ask), `sig_qty<=cfg_order_qty`.
- If `sell_ok` (and not `buy_ok`, not a conflict): `sig_valid<=1`,
  `sig_side<=8'h01` (ASK), `sig_price<=bid_price` (sell at the bid),
  `sig_qty<=cfg_order_qty`.
- If neither, or `book_upd_valid` was low that cycle, or a conflict fired:
  `sig_valid<=0` the next cycle (`sig_slot`/`sig_side`/`sig_price`/
  `sig_qty` don't-care).

### 2.4 Why the imbalance-shift comparison needs wide-precision arithmetic (D15)

Zero-extend `bid_qty`/`ask_qty` by `cfg_imb_shift`'s maximum width (3 bits —
`IMB_SHIFT`'s CSR range is 0-3) **before** shifting, and do the `>`
comparison at that wider width:

```verilog
wire [34:0] ask_shifted = {3'b0, ask_qty} << cfg_imb_shift;
wire [34:0] bid_shifted = {3'b0, bid_qty} << cfg_imb_shift;
wire        buy_qty_ok  = ({3'b0, bid_qty} > ask_shifted);
wire        sell_qty_ok = ({3'b0, ask_qty} > bid_shifted);
```

35 bits is enough headroom that a 32-bit quantity shifted left by up to 3
bits can never lose a bit off the top — this is the whole fix. **Do not**
implement this as a plain `ask_qty << cfg_imb_shift` on a 32-bit wire; that
silently drops bits for large quantities and can produce a spurious
`buy_ok & sell_ok` conflict that `sim/golden_model.py` (Python's unbounded
integers) never would, breaking bit-exactness for large-quantity inputs
that a soak test could eventually generate. `docs/design_decisions.md` D15
has the full derivation and a concrete failing example if you want to
verify this yourself before trusting the fix.

### 2.5 `err_signal_conflict` (FR-37) — defensive, and provably unreachable once §2.4 is implemented correctly

With §2.4's wide-precision shift in place, `buy_ok AND sell_ok` becomes
mathematically impossible for any 32-bit `bid_qty`/`ask_qty` combination —
matching the golden model exactly, which is the whole point of §2.4. Build
the check anyway, exactly as FR-37 states (`conflict = book_upd_valid &
buy_ok & sell_ok`; on conflict, suppress `sig_valid` and pulse
`err_signal_conflict` instead) — it's cheap, it's what the spec explicitly
asks for, and it costs nothing to leave in even though no legal input can
trigger it. See §5 (testbench) for how to actually exercise this specific
branch, since ordinary input stimulus provably cannot reach it once §2.4 is
implemented correctly.

## 3. Testbench requirements (`tb/tb_signal_engine.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o signal_engine_tb.vvp rtl/signal_engine.v tb/tb_signal_engine.v && vvp signal_engine_tb.vvp`),
no manual waveform inspection. Drive `book_upd_valid`/`applied_slot`/the
book-state buses/`cfg_*` directly (no need to instantiate `tob_engine.v`).
Cover, at minimum:

- **T13-style exact spread threshold (buy):** valid, uncrossed book with a
  favorable imbalance ratio, spread exactly `== cfg_min_spread` — fires.
  Spread `== cfg_min_spread - 1` — does not fire. Spread
  `== cfg_min_spread + 1` — fires. All three with everything else held
  constant, isolating the spread boundary specifically.
- **T14-style exact spread threshold (sell):** mirror of the above with the
  imbalance ratio favoring sell instead.
- **Imbalance boundary, strict inequality:** `bid_qty == (ask_qty <<
  cfg_imb_shift)` exactly — must **not** fire (the rule is `>`, not `>=`).
  `bid_qty == (ask_qty << cfg_imb_shift) + 1` — must fire. Repeat for the
  sell side.
- **Crossed book blocks both, regardless of qty ratio:** construct a
  crossed book (`bid_price >= ask_price`) with an otherwise-favorable
  imbalance for buy — confirm no signal fires, and confirm
  `err_signal_conflict` does **not** fire either (a crossed book isn't a
  conflict, it's just "no signal").
  the case §2.2 exists to guard against — a naive implementation that
  derives "not crossed" only from the spread subtraction would likely
  mis-fire here.
- **Either side invalid blocks both:** `bid_valid=0` (or `ask_valid=0`)
  with everything else favorable — no signal.
- **D15's overflow-safety case, directly:** `bid_qty = ask_qty =
  32'h80000000`, `cfg_imb_shift = 1`, valid uncrossed book with adequate
  spread — confirm **no** signal fires and `err_signal_conflict` does
  **not** fire either. This is the regression test for D15; if your
  implementation used a plain 32-bit shift instead of §2.4's wide one, this
  is the case that catches it (both qty conditions would incorrectly read
  true).
- **`err_signal_conflict` itself, via `force`:** since §2.4 makes the
  conflict genuinely unreachable through `bid_qty`/`ask_qty` alone, use
  Icarus's `force`/`release` on the DUT's internal `buy_ok`/`sell_ok` wires
  (hierarchical reference, e.g. `force dut.buy_ok = 1'b1; force
  dut.sell_ok = 1'b1;` on a `book_upd_valid` cycle, then `release` both)
  to directly exercise the conflict-handling branch: confirm
  `err_signal_conflict` pulses and `sig_valid` does **not** assert that
  cycle. This is testing FR-37's defensive logic in isolation, not
  claiming the scenario is reachable via normal operation — say so in a
  comment at that test case, don't present it as a realistic stimulus.
- **`book_upd_valid=0`:** with otherwise-signal-worthy inputs held
  constant, `sig_valid` must stay low that cycle and the one after.
- **Independent slots:** interleave buy-worthy events on one slot and
  sell-worthy events on another, confirm `sig_slot` correctly identifies
  which.
- On any mismatch, `$display` what was expected vs. what happened, then a
  final `$display("FAIL")` / `$display("PASS")` line — this project's
  plain self-checking-Verilog convention.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o signal_engine_tb.vvp rtl/signal_engine.v tb/tb_signal_engine.v` compiles with zero warnings.
- [ ] `vvp signal_engine_tb.vvp` prints `PASS`.
- [ ] `rtl/signal_engine.v` is Verilog-2001 only (no SystemVerilog).
- [ ] The imbalance-shift comparison uses a ≥35-bit intermediate (§2.4), not
      a plain 32-bit shift — check your own RTL for this explicitly, the
      bug is silent (no warning, no simulation mismatch under
      small/realistic test quantities) unless the D15 test case (§3)
      specifically exercises it.
- [ ] `crossed` is read directly from `tob_engine.v`'s output and ANDed in
      as its own term, not re-derived from the spread subtraction (§2.2).
- [ ] The strict-inequality imbalance boundary (`==` doesn't fire, `+1`
      does) is tested on both sides.
- [ ] No multiplier or divider anywhere (FR-39) — only add/subtract/shift/
      compare.
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- The nine pre-trade risk gates (gate `0x01`-`0x09`, including the ML gate
  `0x09`) — `risk_engine.v`'s job, not built yet, S7. `sig_valid`/`sig_side`/
  `sig_price`/`sig_qty` are an **intent**, not a guaranteed order; nothing
  here decides whether it actually gets transmitted.
- Order-frame encoding/transmission — `order_builder.v`, not built yet, S8.
- Anything ML-path related (features, normalization, classifier,
  hysteresis) — an entirely separate, parallel path (§3.2); this module
  does not read `feature_extractor.v`/`feature_normalizer.v` outputs at
  all, and nothing here needs the alignment shift register that
  reconciles the two paths' depths (that's built once both paths exist,
  not part of either path itself).
- Counters that persist `err_signal_conflict`'s count (`err_signal_conflict`
  the counter, S10) — this module only emits the raw pulse; a later
  CSR/counters block owns accumulating it.
- Runtime CSR wiring for `cfg_min_spread`/`cfg_imb_shift`/`cfg_order_qty` —
  direct ports for now, same as every other S3 module; `csr_block.v`
  doesn't exist yet.
