# Contract: fix `order_builder.v`'s fixed-2-cycle `trigger_seq`/`latency_cyc` assumption (patches `rtl/order_builder.v`)

Status: ready to hand off. **Not a new module** — a correctness patch to
one already-committed module (`rtl/order_builder.v`, S8), found during S6
integration and recorded as `docs/design_decisions.md` D25. **Read D25 in
full before this contract** — it has the complete trail (what broke, why
the full regression including the 1M-message soak didn't catch it, why
`latency_histogram.v` is affected too). This contract is the fix D25
flagged as needed.

## 1. Background

### 1.1 The bug, precisely

`order_builder.v` recovers each accepted/rejected order's `trigger_seq`
and `latency_cyc` from an **unconditional two-stage shift register**
(`seq_d0`/`seq_d1`, `ingress_d0`/`ingress_d1`) that blindly shifts
`msg_seq_num[15:0]`/`cur_cycle` every clock cycle — no gating, no
explicit tagging. This works only because it relies on a hand-matched
constant: "the total registered latency from `md_parser`'s `msg_valid` to
the matching `order_valid`/`reject_reason` is exactly two cycles"
(`order_builder.v`'s own header comment) — `signal_engine.v` registers
once, `risk_engine.v` registers once, everything else between
(`symbol_filter`/`seq_monitor`/`tob_engine`'s `book_upd_valid` path) is
combinational.

S6 (`docs/contracts/ml_integration.md`) inserted a 3-cycle alignment delay
line between `signal_engine.v` and `risk_engine.v` (`ALIGN_DEPTH=3`) so
the ML branch's `adverse_risk` verdict and the signal branch's order
intent arrive at `risk_engine.v` together. That's correct and necessary,
but it silently invalidated `order_builder.v`'s hardcoded "two cycles"
assumption — the real latency is now `2 + ALIGN_DEPTH = 5` cycles.
`order_builder.v` was not touched by S6 (correctly out of that contract's
scope), so today `seq_d1`/`ingress_d1` hold whatever message arrived
**three events after** the actual trigger, not the trigger itself. Every
order frame's `trigger_seq` misattributes the triggering message, and
`latency_cyc` (and, downstream, every `latency_histogram.v` bucket) is
computed against the wrong ingress timestamp.

### 1.2 The fix

Don't hand-match a constant a second time — **reuse `rtl/common/
delay_line.v`** (built for exactly this purpose in S6) as the shift
register, with its depth as a module **parameter** instead of a hardcoded
`2`. `tob_top.v` then supplies the correct total (`2 + ALIGN_DEPTH`)
explicitly, from the same `ALIGN_DEPTH` `localparam` the alignment delay
line itself already uses — one source of truth, not two constants that
have to be kept in sync by hand. If a future change alters the
signal→risk latency again, updating `tob_top.v`'s single parameter
connection is the only thing required; `order_builder.v` itself never
needs to know why its delay is whatever it is.

**Why `delay_line.v`, not a bigger hand-rolled shift register:** it
already exists, is already independently tested at arbitrary `DEPTH`
(`tb/tb_delay_line.v`), and using it here is the same fix in spirit as
D23/the `feature_extractor.v` patch — stop re-deriving something that's
already been built and verified once, reuse it. `order_builder.v`'s
`msg_seq_num[15:0]`/`cur_cycle` (48 bits total) become the delay line's
`in_data`, driven with `in_valid` tied high (unconditional, matching the
module's existing documented behavior — this pipeline was never gated on
`msg_valid`, and stays that way).

### 1.3 What this patch does *not* touch, and why

- **`tb_order_builder.v`'s existing coverage is untouched.** The new
  `TRIGGER_DELAY` parameter **defaults to `2`** — the exact depth
  `tb_order_builder.v`'s DUT instance (`order_builder dut (...)`, no
  parameter override today) already assumes throughout its `cc_of`/
  `seq_of` history-lookup logic (§2 of `docs/contracts/order_builder.md`).
  Nothing in that file needs to change.
- **`risk_engine.v`, `signal_engine.v`, `rtl/common/delay_line.v`,
  `csr_block.v`, `latency_histogram.v` are not touched.** This is purely
  an `order_builder.v` interface change (one new parameter, one internal
  mechanism swap) plus the one-line `tob_top.v` instantiation update that
  supplies it.
- **`latency_histogram.v`'s own bucket/BRAM logic is correct as built** —
  it faithfully records whatever `latency_cyc` it's handed. This patch
  fixes the value at the source; no downstream change is needed for its
  measurements to become correct.

## 2. What you're building

**File:** `rtl/order_builder.v` (patch), `rtl/tob_top.v` (one instantiation
line)
**Testbenches:** `tb/tb_order_builder.v` unchanged in behavior (default
parameter preserves it byte-for-byte); new `tb/tb_order_builder_delay.v`
(§2.3)

### 2.1 `order_builder.v` port/parameter changes

**Add** a module parameter, defaulting to today's behavior:

```verilog
module order_builder #(
    parameter integer TRIGGER_DELAY = 2   // cycles from md_parser's
                                           // msg_valid to the matching
                                           // order_valid/reject_reason;
                                           // tob_top.v supplies the real
                                           // value (2 + ALIGN_DEPTH)
) (
    ... unchanged port list ...
```

**Remove** the existing hand-rolled shift register entirely:

```verilog
// old (delete):
reg [15:0] seq_d0, seq_d1;
reg [31:0] ingress_d0, ingress_d1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        seq_d0     <= 16'd0;
        seq_d1     <= 16'd0;
        ingress_d0 <= 32'd0;
        ingress_d1 <= 32'd0;
    end else begin
        seq_d0     <= msg_seq_num[15:0];
        seq_d1     <= seq_d0;
        ingress_d0 <= cur_cycle;
        ingress_d1 <= ingress_d0;
    end
end
```

**Add**, in its place, an instance of `rtl/common/delay_line.v`:

```verilog
wire [47:0] trigger_delay_out;
wire        trigger_delay_valid_unused;   // unconditional pipeline; not
                                            // consumed, matches the old
                                            // code's lack of gating

delay_line #(
    .WIDTH (48),   // msg_seq_num[15:0] (16) + cur_cycle (32)
    .DEPTH (TRIGGER_DELAY)
) u_trigger_delay (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (1'b1),
    .in_data   ({msg_seq_num[15:0], cur_cycle}),
    .out_valid (trigger_delay_valid_unused),
    .out_data  (trigger_delay_out)
);

wire [15:0] seq_captured     = trigger_delay_out[47:32];
wire [31:0] ingress_captured = trigger_delay_out[31:0];
```

**Change** `new_rec`'s construction to read the new signals:

```verilog
// old:
wire [143:0] new_rec =
    { push_msg_type, sym_id_c,  order_side, reject_reason,
      order_price,   order_qty, seq_d1,     ingress_d1 };

// new:
wire [143:0] new_rec =
    { push_msg_type, sym_id_c,       order_side, reject_reason,
      order_price,   order_qty,      seq_captured, ingress_captured };
```

Nothing else in `order_builder.v` changes — the queue push/pop logic,
`lat_diff`'s live computation at pop time (§S2.3 of `docs/contracts/
order_builder.md`), and the wire encoding are all downstream of
`seq_captured`/`ingress_captured` exactly as they were downstream of
`seq_d1`/`ingress_d1`.

### 2.2 `tob_top.v` change

`order_builder.v`'s instantiation (`u_ob`) needs the parameter supplied,
using the **same `ALIGN_DEPTH` `localparam`** the alignment delay line
(`u_align`, S6) already defines — one source of truth, not a second
hand-copied constant:

```verilog
// old:
order_builder u_ob (

// new:
order_builder #(
    .TRIGGER_DELAY (2 + ALIGN_DEPTH)   // signal_engine + risk_engine's own
                                        // 1-cycle registers, plus S6's
                                        // alignment delay (docs/design_
                                        // decisions.md D25)
) u_ob (
```

No other port connections on `u_ob` change.

### 2.3 New testbench: `tb/tb_order_builder_delay.v`

`tb_order_builder.v`'s existing DUT instance stays at the default
`TRIGGER_DELAY=2` — proving the *default* case still works is already
fully covered there. This new, small, dedicated testbench proves the
**parameterization itself** is correct at a *non-default* depth — the
exact depth `tob_top.v` will actually use (`TRIGGER_DELAY=5`, i.e.
`2 + ALIGN_DEPTH` with today's `ALIGN_DEPTH=3`) — so the fix is verified
against the real value in use, not just trusted by inspection.

Structure: mirrors `tb_order_builder.v`'s own `step`/history-array
pattern (§2 of `docs/contracts/order_builder.md`) at a much smaller
scale — instantiate `order_builder #(.TRIGGER_DELAY(5)) dut (...)`, drive
`msg_seq_num`/`cur_cycle` for at least 8 cycles while recording what was
presented on each cycle (a small `cc_of`/`seq_of` history array, same
idea as `tb_order_builder.v`'s), fire `order_valid=1` on a specific later
cycle, and confirm the resulting queued record's `trigger_seq` equals
`msg_seq_num` from **exactly 5 cycles earlier** (not 2) and `latency_cyc`
(computed at drain time, `cur_cycle` at pop minus the captured
`ingress_cycle`) is computed against `cur_cycle` from that same 5-cycles-
earlier point. Cover at least:

- **The direct regression:** a single triggering message, confirm
  `trigger_seq` is the 5-cycles-earlier value, not the 2-cycles-earlier
  one a pre-patch (or wrongly-parameterized) DUT would report — this is
  the exact numeric signature of D25's bug, verify it directly.
- **Two decisions close together** (mirroring `tb_order_builder.v`'s own
  T8 spirit, at the new depth): confirm each decision's `trigger_seq`
  tracks its own triggering message, not a neighbor's, at `DEPTH=5`.
- **`TRIGGER_DELAY=1`** (a second DUT instance in the same file, or a
  second block if the file structure allows): the boundary/minimum case,
  confirming the parameter isn't silently clamped or off-by-one at the
  small end.

`$display("PASS")`/`$display("FAIL")` per this project's convention.

## 3. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o order_builder_tb.vvp rtl/order_builder.v rtl/common/delay_line.v tb/tb_order_builder.v` compiles with zero warnings; `vvp` prints `PASS` — **every existing case passes unmodified**, confirming the default parameter preserves current behavior exactly.
- [ ] `iverilog -g2001 -Wall -o order_builder_delay_tb.vvp rtl/order_builder.v rtl/common/delay_line.v tb/tb_order_builder_delay.v` compiles with zero warnings; `vvp` prints `PASS`.
- [ ] `iverilog -g2001 -Wall -o tob_top_tb.vvp` with the full `tb_tob_top.v` file list (per `scripts/run_sim.sh`, now including `rtl/common/delay_line.v` twice-consumed — once by `u_align`, once by `u_ob`'s new internal instance, both from the same file) compiles and passes, **including T6/T7** (the S6 ML-gate cases) — confirm their reject/order frames still decode correctly with `order_builder.v` now correctly reporting `trigger_seq`/`latency_cyc` at the real 5-cycle depth (their `chk` assertions don't currently check these two fields, but a manual `$display` inspection of the T6/T7 frames should show a *plausible*, non-zero, non-garbage `trigger_seq` matching the actual triggering message's `seq`).
- [ ] `RUN_SIM_FAST=1 bash scripts/run_sim.sh` reports `ALL TESTS PASSED`.
- [ ] `git diff` on `rtl/risk_engine.v`, `rtl/signal_engine.v`, `rtl/common/delay_line.v`, `rtl/csr_block.v`, `rtl/latency_histogram.v` is empty — none of these are touched by this contract.
- [ ] No inferred latches in the patched module; every `reg`/`wire` assigned on every path or has a clear default.

## 4. Explicitly out of scope

- Adding a `trigger_seq`/`latency_cyc` correctness check to `tb_tob_top.v`'s
  existing T1–T7 cases — worth doing eventually, not required to close
  D25's specific bug, which is about the *value being wrong*, not about
  test coverage gaps elsewhere. (`tb/tb_order_builder_delay.v`, §2.3, is
  the testbench that actually proves the fix.)
- Any change to `docs/contracts/order_builder.md`'s own S2.2/S2.3
  sections describing the (now-superseded) fixed-2-cycle design — update
  that contract's text to describe the parameterized `delay_line.v`-based
  mechanism as a documentation follow-up, not required for the fix itself
  to be correct or verified.
- Re-deriving `ALIGN_DEPTH`'s own value (still `3`, unchanged) — this
  contract only fixes `order_builder.v`'s dependency on it.
