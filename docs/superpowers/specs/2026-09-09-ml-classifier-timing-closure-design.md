# ML Classifier Timing Closure — Design

## Problem

`rtl/ml_classifier_wrap.v` computes `z = bias + Σ w_i·x_i` (8 signed int8
features/weights, int16 exact products, int32 accumulator) entirely
combinationally in one cycle: `x0..x7` arrive already registered from
`feature_normalizer.v`, and this module's own `z_c` expression (an unbroken
left-to-right sum of 8 products plus bias) is registered into `z` on the
next clock edge, with no pipeline stage in between.

Until 2026-09-09 this module was loaded with a documented placeholder weight
set (`w_i = 1` for all `i`, `bias = 0`) specifically chosen to be
hand-computable — and, as an unplanned side effect, because Vivado
constant-folds `x_i * 1` away entirely, so the placeholder build's
`z_c` synthesized to nothing but wire-forwarding. Timing closed trivially
(`WNS = +0.141 ns`, `DSP = 0`).

`docs/design_decisions.md` D52 landed the project's first real training
pipeline and real trained weights (`[4, -80, 14, 44, 7, -114, 26, -52]`,
bias `-1302`). No RTL changed — only the two `.mem` files' contents — but
re-synthesizing against these real weights broke timing closure:

```
WNS = -3.842 ns   (8 ns period; needs ~11.8 ns)
Setup: 342 failing endpoints (rx_clk group), -201.165 ns total violation

Worst path:
  Source:      u_norm/x7_reg[5]/C
  Destination: u_ml/z_reg[29]/D
  Data Path Delay: 11.825 ns (logic 7.392 ns, route 4.433 ns)
  Logic Levels: 24  (CARRY4=16, LUT1=1, LUT2=6, LUT5=1)
```

## Root cause (confirmed against the actual routed netlist, `results/build/timing_summary.rpt`)

Two independent, additive causes, both verified directly against the
routed report rather than assumed:

1. **The 8-way sum is a literal serial chain, not a balanced tree.** The
   netlist shows `z_c_carry → z_c__39_carry → z_c__81_carry →
   z_c__129_carry → z_c__180_carry → ...` — one adder per `+` in the
   source expression, left to right, matching the Verilog exactly. Vivado
   does not rebalance adder expressions on its own. Each stage costs
   roughly 1.2 ns (carry-chain propagation plus inter-adder routing), and
   there are 7 of them.
2. **The accumulator is 15 bits wider than it needs to be, and those extra
   bits cost real delay.** `z` is declared `signed [31:0]`, but the true
   bound on `|z|` for ANY int8 weight set is `|bias| + Σ 128·|w_i|`. For
   the current weights that's `1302 + 128·(4+80+14+44+7+114+26+52) =
   44,950` — representable in 17 signed bits. The remaining ~15 bits of
   the declared 32-bit width are pure sign-extension, and the tail of the
   failing path (`i__carry__4/5/6`, ~1.1 ns) is exactly the carry ripple
   computing those don't-care bits, because Vivado's range analysis
   doesn't see through the 8-deep serial chain to prove they're constant.

Two things ruled out, also verified rather than assumed:

- **DSP48E1 inference does not apply here** (note: the part uses DSP48E1,
  not DSP48A1 — DSP48A1 is Spartan-6/3A; the part in this project is
  Artix-7). The weights are loaded via `$readmemh` into a `reg` array with
  no write port, read at fixed indices — Vivado treats them as
  elaboration-time constants and constant-folds each multiply into a
  shift-add network (confirmed in the netlist: `u_ml/p7__0_carry__0` is a
  two-`CARRY4` constant-multiply structure for `x7 * (-52)`, not a
  generic multiplier). Forcing DSP48E1 mapping would not help even if it
  worked: a combinationally-used DSP48E1 has a 4-5 ns A→P delay on this
  speed grade — slower than the constant shift-add already there — and
  running it at 125 MHz registered would cost 2 cycles inside the DSP
  itself, worse than the 1-cycle pipeline this design tries to avoid.
  DSP48E1 only becomes relevant here if the weights ever become
  runtime/CSR-writable (they are explicitly not, per FR-32).
- **A DSP cascade (`PCIN`/`PCOUT`) architecture is the wrong tool for 8
  constant weights** — it would consume the entire 8-DSP budget, requires
  hand-instantiated primitives (against this project's inference-only
  convention outside the one vendored MAC), and costs roughly one pipeline
  register per cascaded DSP (~8 cycles) to run at speed. It is the right
  answer for a much wider, runtime-configurable feature vector — not this.

## Fix

### Phase 1 — Zero-latency RTL fix (try this first, no cascading changes)

Rewrite `z_c` as a balanced binary tree, narrowed to a `localparam integer
ACC_W = 20` accumulator (comfortable headroom over the current 17-bit
requirement, and covers any realistic int8 weight/bias combination:
worst case `8 · 128 · 128 = 131,072 < 2^19`), sign-extended back to the
full 32-bit `z` only at the very end:

```verilog
localparam integer ACC_W = 20;   // bound: |bias| + SUM 128*|w_i| < 2^(ACC_W-1)

// Truncating bias to a dedicated signed wire (not a bare bit-select) --
// bit-selecting a signed vector directly (`bias[ACC_W-1:0]`) strips
// Verilog's `signed` attribute from the result, which would silently
// force unsigned arithmetic on this term (and, per Verilog's
// context-sensitive signed-expression rules, risks doing so for the
// WHOLE sum, not just this term) -- exactly the kind of signed/unsigned
// footgun feature_normalizer.v's own `>>>` note already warns about
// elsewhere in this codebase.
wire signed [ACC_W-1:0] bias_trunc = bias[ACC_W-1:0];

wire signed [ACC_W-1:0] s0 = $signed(p0) + $signed(p1);
wire signed [ACC_W-1:0] s1 = $signed(p2) + $signed(p3);
wire signed [ACC_W-1:0] s2 = $signed(p4) + $signed(p5);
wire signed [ACC_W-1:0] s3 = $signed(p6) + $signed(p7);
wire signed [ACC_W-1:0] t0 = s0 + s1;
wire signed [ACC_W-1:0] t1 = s2 + s3;
wire signed [ACC_W-1:0] acc = (t0 + t1) + bias_trunc;

// in the always block, replacing `z <= z_c;`:
z <= {{(32-ACC_W){acc[ACC_W-1]}}, acc};
```

Both changes are exact, not approximations:
- Reassociating a sum in two's-complement arithmetic is bit-exact as long
  as no intermediate term overflows its declared width — true here by
  construction, since every partial sum stays within `ACC_W` bits given
  the bound above.
- Narrowing to `ACC_W` then sign-extending back to 32 bits is bit-exact
  *iff* the bound `|bias| + Σ128·|w_i| < 2^(ACC_W-1)` holds. This is a
  real obligation, not a comment: guard it with an `initial`-block
  assertion in the RTL (Verilog-2001, ignored by synthesis, checked in
  simulation) **and** the equivalent check in `model/train.py`'s
  `.mem`-writing path, so a future retrain that would violate it fails
  loudly in Python before ever reaching synthesis — the same pattern this
  project already uses for other width contracts (`risk_engine.v`'s
  D16/FR-45 comments, `feature_normalizer.v`'s `>>>` footgun note).

This changes zero interface, zero latency, zero downstream contract — no
`ALIGN_DEPTH`, `SNAPSHOT_DEPTH`, testbench, or doc updates needed if it
closes timing on its own.

### Phase 2 — Bit-exactness verification (must pass before touching synthesis)

Run, in order: `tb/tb_ml_classifier_wrap.v` (hand-cases, still against the
placeholder weights — these must still resolve to the same values, since
the math is unchanged, only reassociated/narrowed), `tb/tb_ml_bit_exact.v`
(all 4,860 real trained golden vectors — must still show bit-exact `z`),
then the full `RUN_SIM_FAST=1 bash scripts/run_sim.sh` (must still end
`ALL TESTS PASSED`).

If any of these fail, the bound assertion or the reassociation itself is
wrong — that is the thing to debug, not a reason to fall back to adding a
pipeline stage.

### Phase 3 — Targeted re-synthesis check

Re-run `make synth` (or the equivalent Vivado MCP synthesis+implementation
flow) and specifically inspect whether the ML classifier's own path
(`u_norm/x7_reg[*]/C` → `u_ml/z_reg[*]/D`, or wherever the new balanced-tree
logic's worst point lands) still violates setup timing — look at the top
N failing paths (`report_timing -max_paths 50`), not just the overall
design `WNS`.

**Explicitly out of scope for this plan** (per an explicit scoping
decision): the same build shows at least two other, independent timing
failures with nothing to do with the ML classifier — an async-reset-fanout
path in a `**async_default**` path group (`u_rst_sync/ff2_reg/C` →
`u_csr/cnt_rej_band_reg[19]/CLR`), and a `risk_engine` price-band path
(`u_align/u_risk/band_diff[30]`, -2.282 ns per `results/build/
v2_critical_path.rpt`). This plan's deliverable is **"the ML classifier's
own path no longer violates"**, not **"`make synth`'s overall gate
passes"** — the latter needs those other two issues independently
investigated and fixed, which is out of scope here.

### Phase 4 (conditional) — Pipeline, only if Phase 3 shows the ML path still violated

If the zero-latency fix isn't enough on its own, split into two pipeline
stages instead of one combinational stage:

- **Stage 1 (registered):** the 8 products `p0..p7`.
- **Stage 2 (registered, into `z`):** the same balanced-tree,
  narrowed-accumulator sum from Phase 1, now starting from registered
  products instead of the normalizer's registered outputs.

This adds exactly 1 cycle (`ml_valid` at `norm_valid+2` instead of `+1`).
If this cascades, it touches:

- `rtl/tob_top.v`: `localparam ALIGN_DEPTH` (currently 4) → 5.
- `rtl/ml_policy.v`: `SNAPSHOT_DEPTH` parameter (currently defaults to 4,
  see Phase 5 below) → must become 5, explicitly wired (see Phase 5).
- Testbenches with hardcoded cycle-offset expectations: `tb/
  tb_ml_classifier_wrap.v`, `tb/tb_ml_chain.v`, `tb/tb_ml_policy.v` (via
  `-DTB_SNAPSHOT_DEPTH`), `tb/tb_tob_top.v`, `tb/tb_top.v`.
- Docs stating the current per-stage latency numbers: `docs/contracts/
  ml_integration.md` §1.3, master spec §S1.3/§S7.1.

If Phase 3 still doesn't close after this, add a third stage (split the
tree further) rather than guessing a deeper pipeline up front — same
"minimum viable fix, verify, escalate only if needed" discipline as
Phase 1→3→4.

### Phase 5 — Fix `SNAPSHOT_DEPTH`'s wiring gap (do this regardless of whether Phase 4 happens)

Confirmed directly against `rtl/tob_top.v`: `ml_policy`'s instantiation
(`ml_policy u_policy (...)`, around line 592) passes **no** parameter
override at all — it silently relies on the module's own default
`SNAPSHOT_DEPTH = 4` numerically happening to equal `ALIGN_DEPTH`. This is
asymmetric with the adjacent `risk_engine` instantiation, which explicitly
does `.ALIGN_DEPTH (ALIGN_DEPTH)` with a comment that it must match. Fix
by adding the equivalent explicit wiring:

```verilog
ml_policy #(
    .SNAPSHOT_DEPTH (ALIGN_DEPTH)   // must match -- see risk_engine's own
                                    // explicit .ALIGN_DEPTH wiring above
) u_policy (
    ...
```

This is a real latent bug independent of the timing-closure work — today
it's harmless only because both constants happen to be 4 — and should be
fixed either way, whether or not Phase 4 ends up changing the depth.

### Phase 6 — Documentation

A new `docs/design_decisions.md` entry covering: the root cause (adder
chain shape + accumulator width, confirmed against the routed netlist),
the fix applied (Phase 1, and Phase 4 if it was needed), the `SNAPSHOT_DEPTH`
wiring fix, and the accepted policy on retrain risk (below). Update
`docs/contracts/ml_integration.md` and the master spec's timing tables
only if Phase 4 happened (Phase 1 alone changes no contract).

## Accepted policy: retrain-timing risk

Because the classifier's weights are elaboration-time constants and
different weight VALUES produce different shift-add synthesis structures
(a weight like `0x55` costs more constant-multiply terms than `0x80`),
**a future retrain can change synthesis timing with no RTL change at
all** — a real tension with this project's fixed-cycle-count design goal.

**Decision (confirmed with the project owner):** accept this, and make
"re-synthesize and re-check timing" an explicit required step after any
retrain, documented as part of the `make ml` flow's own instructions
(`Makefile`'s `ml:` target comment, and/or `CLAUDE.md`/`README.md`'s
description of what running `make ml` entails) — not automated into the
`make ml` target itself (that target's job is training + golden-vector
export, not synthesis, and `make synth` already exists as a separate,
correctly-scoped step). The `ACC_W` bound assertion from Phase 1 is a
narrower, complementary safeguard (catches an actual overflow risk,
not a timing risk) and doesn't substitute for this policy.

## Explicitly out of scope

- The async-reset-fanout timing failure and the `risk_engine` price-band
  timing failure (Phase 3) — separate investigations.
- Any change to `hls4ml/` or the real ML IP export — unaffected by this
  work either way (this fix applies to the hand-written fallback
  classifier; if/when a real hls4ml IP replaces it, that IP's own timing
  is a separate concern).
- Constraining future model quantization to keep weights "timing-cheap"
  (the rejected alternative policy) — not pursued; may be revisited later
  if the accepted policy proves too disruptive in practice.
