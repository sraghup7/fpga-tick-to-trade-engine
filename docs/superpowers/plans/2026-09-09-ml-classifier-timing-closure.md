# ML Classifier Timing Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the `rtl/ml_classifier_wrap.v` setup-timing violation (`WNS = -3.842 ns`) introduced when real trained ML weights replaced the placeholder, using the minimum RTL change that actually closes it — a zero-added-latency rewrite first, a 1-cycle pipeline only if that isn't enough — and fix an unrelated latent `SNAPSHOT_DEPTH` wiring gap found during the investigation.

**Architecture:** The violation is caused by two additive, netlist-confirmed issues in `ml_classifier_wrap.v`'s combinational accumulator: an unbalanced 8-way serial adder chain, and 15 bits of unused accumulator width whose sign-extension costs real carry-chain delay. Both are fixed by reassociating the sum into a balanced tree and narrowing to a bound-asserted 20-bit accumulator — a bit-exact, zero-latency change. Only if that doesn't close the classifier's own path does the plan add a single pipeline stage, which then cascades into `tob_top.v`'s `ALIGN_DEPTH`, `ml_policy.v`'s `SNAPSHOT_DEPTH`, and five testbenches. Weight-based DSP48E1 inference and a DSP cascade architecture were both investigated and ruled out (weights are elaboration-time constants; see the spec for the full analysis) — not part of this plan.

**Tech Stack:** Verilog-2001 (Icarus 12.0 for simulation, Vivado 2024.2 for synthesis/timing), Python 3.11 (`model/train.py`).

**Spec:** `docs/superpowers/specs/2026-09-09-ml-classifier-timing-closure-design.md` — read this first; it has the full root-cause analysis (verified against the actual routed netlist), the rejected alternatives (DSP inference, DSP cascade) and why, and the accepted retrain-risk policy this plan documents in Task 7.

## Global Constraints

- Verilog-2001 only, no vendor-primitive instantiation (repo `CLAUDE.md` / NFR-9). No `(* use_dsp = ... *)` attributes or hand-instantiated `DSP48E1` — the spec's root-cause analysis shows these would not help here (weights are elaboration-time constants) and are explicitly rejected approaches.
- Every RTL change must compile with `iverilog -g2001 -Wall` with zero warnings and zero inferred latches.
- The accumulator bound `|bias| + Σ 128·|w_i| < 2^(ACC_W-1)` (`ACC_W = 20`) must be enforced in BOTH `rtl/ml_classifier_wrap.v` (simulation-time check) and `model/train.py`'s export path (Python-time check) — this is the correctness invariant the whole zero-latency fix depends on, and it must be caught in two independent places, not one.
- `z`'s bit-exactness against the pre-existing wide/serial semantics is the hard gate: `tb/tb_ml_classifier_wrap.v` (placeholder weights, hand cases) and `tb/tb_ml_bit_exact.v` (4,860 real trained golden vectors) must both still pass after every RTL change in this plan.
- `ALIGN_DEPTH` (`rtl/tob_top.v`) and the value `ml_policy.v`'s `SNAPSHOT_DEPTH` actually receives must always be equal — enforced by explicit parameter wiring (Task 3), never by coincidental matching defaults.
- This plan's own scope is the ML classifier's specific timing path only — a build-wide `make synth` PASS is not this plan's success criterion (two other, unrelated timing failures exist in the current build and are explicitly out of scope; see spec).

---

## File Structure

```
rtl/ml_classifier_wrap.v   MODIFY (Task 1): balanced-tree, narrowed accumulator, bound check;
                            MODIFY AGAIN (Task 6, conditional): pipeline into 2 stages
rtl/tob_top.v                MODIFY (Task 3): explicit SNAPSHOT_DEPTH wiring;
                              MODIFY AGAIN (Task 6, conditional): ALIGN_DEPTH 4->5
model/train.py                 MODIFY (Task 2): matching ACC_W bound check in export()
model/tests/test_export_format.py   MODIFY (Task 2): new test for the bound check
tb/tb_ml_classifier_wrap.v        MODIFY (Task 6, conditional only): +1 cycle offset
tb/tb_ml_chain.v                    MODIFY (Task 6, conditional only)
tb/tb_ml_policy.v                    MODIFY (Task 6, conditional only): new SNAPSHOT_DEPTH
tb/tb_tob_top.v                       MODIFY (Task 6, conditional only)
tb/tb_top.v                            MODIFY (Task 6, conditional only)
docs/contracts/ml_integration.md         MODIFY (Task 6, conditional only): S1.3 timing table
fpga_tick_to_trade_master_spec.md          MODIFY (Task 6, conditional only): S1.3/S7.1
docs/design_decisions.md                     MODIFY (Task 7): new D53 entry
Makefile / CLAUDE.md / README.md               MODIFY (Task 7): retrain-timing policy note
```

---

### Task 1: Rewrite `ml_classifier_wrap.v`'s accumulator — balanced tree, narrowed width, bound check

**Files:**
- Modify: `rtl/ml_classifier_wrap.v`

**Interfaces:**
- No port/parameter changes. `z`'s bit-exact value for any weight/bias set satisfying the `ACC_W` bound is unchanged from the current wide/serial computation — this task changes only how `z` is computed internally, not what it computes.

- [ ] **Step 1: Read the current file and confirm the starting point**

```bash
cat rtl/ml_classifier_wrap.v
```

Confirm it matches what the spec's "Problem" section quotes (the 8 products `p0..p7`, then `z_c = bias + p0+p1+...+p7` as a single wide expression, registered into `z`). If it has diverged from that, STOP and report BLOCKED — the rest of this task's steps assume this exact starting shape.

- [ ] **Step 2: Replace the accumulator logic**

Find (the `w_mem`/`bias_mem` declaration through the `z_c` assignment):

```verilog
    reg signed [7:0]  w_mem    [0:7];
    reg signed [31:0] bias_mem [0:0];
    initial begin
        $readmemh(WEIGHTS_FILE, w_mem);
        $readmemh(BIAS_FILE, bias_mem);
    end

    wire signed [31:0] bias = bias_mem[0];

    // Exact int8 x int8 -> int16 products (S5.4).
    wire signed [15:0] p0 = $signed(x0) * $signed(w_mem[0]);
    wire signed [15:0] p1 = $signed(x1) * $signed(w_mem[1]);
    wire signed [15:0] p2 = $signed(x2) * $signed(w_mem[2]);
    wire signed [15:0] p3 = $signed(x3) * $signed(w_mem[3]);
    wire signed [15:0] p4 = $signed(x4) * $signed(w_mem[4]);
    wire signed [15:0] p5 = $signed(x5) * $signed(w_mem[5]);
    wire signed [15:0] p6 = $signed(x6) * $signed(w_mem[6]);
    wire signed [15:0] p7 = $signed(x7) * $signed(w_mem[7]);

    wire signed [31:0] z_c = bias
        + $signed(p0) + $signed(p1) + $signed(p2) + $signed(p3)
        + $signed(p4) + $signed(p5) + $signed(p6) + $signed(p7);
```

Replace with:

```verilog
    // ACC_W bound (docs/superpowers/specs/2026-09-09-ml-classifier-timing-closure-design.md):
    // the balanced-tree, narrowed accumulator below is bit-exact against
    // the original wide/serial computation only if
    // |bias| + SUM 128*|w_i| < 2^(ACC_W-1). Checked in simulation right
    // after $readmemh below (ignored by synthesis, same as $readmemh's own
    // initial-block convention); model/train.py's export() enforces the
    // identical bound in Python before these .mem files are ever written,
    // so this check should never actually fire -- it exists as a second,
    // independent guard against a future retrain silently violating it.
    localparam integer ACC_W = 20;

    reg signed [7:0]  w_mem    [0:7];
    reg signed [31:0] bias_mem [0:0];
    initial begin: load_and_check
        integer i;
        integer bound;
        $readmemh(WEIGHTS_FILE, w_mem);
        $readmemh(BIAS_FILE, bias_mem);
        bound = (bias_mem[0] < 0) ? -bias_mem[0] : bias_mem[0];
        for (i = 0; i < 8; i = i + 1) begin
            bound = bound + 128 * ((w_mem[i] < 0) ? -w_mem[i] : w_mem[i]);
        end
        if (bound >= (1 << (ACC_W-1))) begin
            $display("FATAL: ml_classifier_wrap ACC_W=%0d bound violated: |bias|+SUM128|w_i|=%0d >= 2^%0d",
                      ACC_W, bound, ACC_W-1);
            $finish;
        end
    end

    wire signed [31:0] bias = bias_mem[0];
    // Truncating bias to a dedicated signed wire (not a bare bit-select) --
    // bit-selecting a signed vector directly (`bias[ACC_W-1:0]`) strips
    // Verilog's `signed` attribute from the result, which would silently
    // force unsigned arithmetic on this term (and, per Verilog's
    // context-sensitive signed-expression rules, risks doing so for the
    // WHOLE sum, not just this term) -- the same class of footgun
    // feature_normalizer.v's own `>>>` note already warns about elsewhere
    // in this codebase.
    wire signed [ACC_W-1:0] bias_trunc = bias[ACC_W-1:0];

    // Exact int8 x int8 -> int16 products (S5.4) -- unchanged.
    wire signed [15:0] p0 = $signed(x0) * $signed(w_mem[0]);
    wire signed [15:0] p1 = $signed(x1) * $signed(w_mem[1]);
    wire signed [15:0] p2 = $signed(x2) * $signed(w_mem[2]);
    wire signed [15:0] p3 = $signed(x3) * $signed(w_mem[3]);
    wire signed [15:0] p4 = $signed(x4) * $signed(w_mem[4]);
    wire signed [15:0] p5 = $signed(x5) * $signed(w_mem[5]);
    wire signed [15:0] p6 = $signed(x6) * $signed(w_mem[6]);
    wire signed [15:0] p7 = $signed(x7) * $signed(w_mem[7]);

    // Balanced-tree, narrowed-width sum (docs/design_decisions.md D53) --
    // replaces the previous left-to-right 32-bit chain. Reassociation is
    // exact in two's complement as long as no intermediate overflows its
    // declared width, which the ACC_W bound above guarantees.
    wire signed [ACC_W-1:0] s0 = $signed(p0) + $signed(p1);
    wire signed [ACC_W-1:0] s1 = $signed(p2) + $signed(p3);
    wire signed [ACC_W-1:0] s2 = $signed(p4) + $signed(p5);
    wire signed [ACC_W-1:0] s3 = $signed(p6) + $signed(p7);
    wire signed [ACC_W-1:0] t0 = s0 + s1;
    wire signed [ACC_W-1:0] t1 = s2 + s3;
    wire signed [ACC_W-1:0] acc = (t0 + t1) + bias_trunc;
    wire signed [31:0] z_c = {{(32-ACC_W){acc[ACC_W-1]}}, acc};
```

(Keeping the final result named `z_c` and 32 bits wide means the `always` block below — `z <= z_c;` — needs no change at all.)

- [ ] **Step 3: Compile-check**

```bash
iverilog -g2001 -Wall -o /tmp/lint_ml.vvp rtl/ml_classifier_wrap.v tb/tb_ml_classifier_wrap.v
```

Expected: compiles with zero warnings. If Icarus warns about the `bound`/`i` integer declarations inside the named `initial` block, confirm the block is written as `initial begin: load_and_check` with `integer i; integer bound;` declared as the first statements inside it (Verilog-2001 allows local variable declarations in a named block) — this is required syntax, not optional style.

- [ ] **Step 4: Run the existing hand-case testbench**

```bash
vvp /tmp/lint_ml.vvp
```

Expected: `PASS` (unchanged — `tb/tb_ml_classifier_wrap.v` already overrides `WEIGHTS_FILE`/`BIAS_FILE` to point at the placeholder fixture `tb/stimulus/ml_placeholder_weights.mem`/`ml_placeholder_bias.mem`, `w_i=1` for all `i`, `bias=0` — well within the `ACC_W` bound, and the hand-computed expected `z` values in that testbench must still match exactly, since reassociating a sum of `1*x_i` terms is trivially exact).

- [ ] **Step 5: Run the real-weight bit-exactness harness**

```bash
python scripts/gen_ml_bit_exact_vectors.py
iverilog -g2001 -Wall -o /tmp/lint_bitexact.vvp rtl/ml_classifier_wrap.v tb/tb_ml_bit_exact.v
vvp /tmp/lint_bitexact.vvp
```

Expected: `PASS: all 4860 golden vectors bit-exact`. This is the real test of the rewrite — all 4,860 vectors use the actual trained weights (`[4,-80,14,44,7,-114,26,-52]`, bias `-1302`), which the spec already confirmed satisfy the `ACC_W=20` bound (44,950 vs. the bound's `2^19=524288`) with wide margin.

If this fails, the bug is in the rewrite (most likely the `bias_trunc` signedness handling, or an off-by-one in the tree grouping) — debug that, do not weaken the bound or revert to the wide/serial form.

- [ ] **Step 6: Run the full sim suite**

```bash
RUN_SIM_FAST=1 bash scripts/run_sim.sh
```

Expected: `ALL TESTS PASSED`.

- [ ] **Step 7: Commit**

```bash
git add rtl/ml_classifier_wrap.v
git commit -m "fix: ml_classifier_wrap.v -- balanced-tree, narrowed (ACC_W=20) accumulator closes the serial-chain + sign-extension cost (D53)"
```

---

### Task 2: Add the matching `ACC_W` bound check to `model/train.py`'s export path

**Files:**
- Modify: `model/train.py` (the `export()` function)
- Modify: `model/tests/test_export_format.py` (add a test for the new check)

**Interfaces:**
- `export()`'s signature and callers are unchanged — this adds an internal validation, not a new parameter.

- [ ] **Step 1: Write the failing test**

Add to `model/tests/test_export_format.py` (append; keep the existing test untouched):

```python
def test_export_rejects_weights_violating_acc_w_bound():
    """model/train.py's export() must reject a weight/bias combination that
    would violate rtl/ml_classifier_wrap.v's ACC_W=20 accumulator bound
    (|bias| + SUM 128*|w_i| < 2**19) -- this is the Python-side half of the
    two-independent-guards requirement from docs/design_decisions.md D53;
    the RTL-side half is ml_classifier_wrap.v's own initial-block check.
    """
    import numpy as np
    import pytest
    import train

    # All 8 weights at the int8 extreme (-128) plus a large bias: clearly
    # violates the bound (8*128*128 + a huge bias is nowhere near 2**19... use
    # an intentionally-broken huge bias to force the violation unambiguously).
    weights_i8 = np.array([-128, -128, -128, -128, -128, -128, -128, -128], dtype=np.int8)
    bias_i32 = np.int32(2_000_000)  # forces |bias|+SUM128|w_i| well past 2**19

    with pytest.raises(ValueError, match=r"(?i)acc_w|bound|accumulator"):
        train.export(
            offsets=np.zeros(8, dtype=np.int64),
            shifts=np.zeros(8, dtype=np.int64),
            weights_i8=weights_i8,
            bias_i32=bias_i32,
            t_high=10,
            t_low=5,
            threshold_source="percentile_fallback_95",
            x_val_i8=np.zeros((1, 8), dtype=np.int8),
            z_val=np.array([0], dtype=np.int32),
            y_val=np.array([0], dtype=np.int8),
        )
```

(If `export()`'s actual current parameter list differs from this call -- e.g. the `threshold_source` parameter added in an earlier fix wave -- match the real signature; check `model/train.py`'s current `def export(` before writing this call.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd model && python -m pytest tests/test_export_format.py::test_export_rejects_weights_violating_acc_w_bound -v`
Expected: FAIL — `export()` currently has no such check, so no `ValueError` is raised (or the call succeeds silently).

- [ ] **Step 3: Add the bound check to `export()`**

In `model/train.py`, find the start of the `export()` function body (find `def export(` and its first executable line). Add, as the very first statements in the function body (before anything else runs):

```python
    # ACC_W bound (rtl/ml_classifier_wrap.v, docs/design_decisions.md D53):
    # the RTL's balanced-tree accumulator is only bit-exact if
    # |bias| + SUM 128*|w_i| < 2**19 (ACC_W=20). Checked here, independent
    # of the RTL's own initial-block check, so a bad retrain fails loudly
    # in Python before ever producing a .mem file.
    ACC_W = 20
    bound = int(abs(int(bias_i32))) + sum(128 * abs(int(w)) for w in weights_i8)
    if bound >= 2 ** (ACC_W - 1):
        raise ValueError(
            f"weights/bias violate the ml_classifier_wrap.v ACC_W={ACC_W} accumulator "
            f"bound: |bias|+sum(128*|w_i|)={bound} >= 2**{ACC_W - 1}"
        )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd model && python -m pytest tests/test_export_format.py -v`
Expected: all PASS, including the new test.

Also confirm the REAL current weights still export cleanly (the bound check must not reject legitimate data):

Run: `cd model && python train.py`
Expected: completes normally, same as before (weights `[4,-80,14,44,7,-114,26,-52]`, bias `-1302` give `bound=44950`, comfortably under `2**19=524288`).

- [ ] **Step 5: Run the full model test suite**

Run: `cd model && python -m pytest tests/ -v`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add model/train.py model/tests/test_export_format.py
git commit -m "fix: model/train.py export() enforces the ACC_W=20 accumulator bound (D53)"
```

---

### Task 3: Fix `ml_policy`'s `SNAPSHOT_DEPTH` wiring gap in `tob_top.v`

**Files:**
- Modify: `rtl/tob_top.v`

**Interfaces:** none — this is a parameter-wiring fix with no behavior change today (both sides already evaluate to `4`).

- [ ] **Step 1: Confirm the current gap**

```bash
grep -n "ml_policy u_policy\|risk_engine #(" rtl/tob_top.v
```

Expected: `risk_engine #(` shows an explicit `.ALIGN_DEPTH (ALIGN_DEPTH)` override a few lines above its instantiation, while `ml_policy u_policy (` has no `#(...)` block at all before it (confirmed during this plan's investigation: `ml_policy`'s own `SNAPSHOT_DEPTH` parameter silently defaults to `4`, coincidentally matching `ALIGN_DEPTH`, with no explicit connection).

- [ ] **Step 2: Add the explicit wiring**

Find:

```verilog
    ml_policy u_policy (
        .clk                  (gmii_rx_clk),
```

Replace with:

```verilog
    ml_policy #(
        .SNAPSHOT_DEPTH (ALIGN_DEPTH)   // must match -- same reasoning as
                                        // risk_engine's own explicit
                                        // .ALIGN_DEPTH wiring above; this
                                        // was previously an unwired
                                        // coincidental match (D53)
    ) u_policy (
        .clk                  (gmii_rx_clk),
```

Do not change any other line of this instantiation (its port connections are unrelated to this fix).

- [ ] **Step 3: Compile-check and verify no behavior change**

```bash
iverilog -g2001 -Wall -o /tmp/lint.vvp rtl/*.v rtl/common/*.v tb/sim_models/tob_top_sim_leaves.v
```

Expected: compiles with zero warnings (this is the same rtl-lint invocation `scripts/run_sim.sh` uses).

Run the two testbenches that instantiate `tob_top`:

```bash
iverilog -g2001 -Wall -o /tmp/tb_tob_top.vvp rtl/tob_top.v rtl/frame_classifier.v rtl/md_parser.v rtl/symbol_filter.v rtl/seq_monitor.v rtl/tob_engine.v rtl/signal_engine.v rtl/risk_engine.v rtl/order_builder.v rtl/csr_block.v rtl/latency_histogram.v rtl/feature_extractor.v rtl/feature_normalizer.v rtl/ml_classifier_wrap.v rtl/ml_policy.v rtl/eth_mac_if.v rtl/common/sync_2ff.v rtl/common/mdio_ctrl.v rtl/common/delay_line.v tb/sim_models/tob_top_sim_leaves.v tb/tb_tob_top.v
vvp /tmp/tb_tob_top.vvp
```

Expected: `PASS` (identical to before this change — `SNAPSHOT_DEPTH` still evaluates to `4`, so nothing about the design's actual behavior changed, only how that `4` gets there).

- [ ] **Step 4: Run the full sim suite**

```bash
RUN_SIM_FAST=1 bash scripts/run_sim.sh
```

Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add rtl/tob_top.v
git commit -m "fix: explicitly wire ml_policy's SNAPSHOT_DEPTH from ALIGN_DEPTH instead of relying on a coincidental matching default (D53)"
```

---

### Task 4: Re-synthesize and check whether the ML classifier's own path now closes

**Files:** none (this task runs tools and inspects output; no code changes)

**Interfaces:** none. **This task's outcome decides whether Task 5 (pipelining) is needed at all** — read Step 4 carefully before deciding this task is "done."

- [ ] **Step 1: Run synthesis through implementation**

```bash
make synth
```

Expected: this most likely still exits non-zero / prints `ERROR: negative setup slack -- refusing to write a bitstream.` — that is EXPECTED and does NOT mean this task failed. Two other, unrelated timing failures exist in this build (an async-reset-fanout path and a `risk_engine` price-band path — see the spec's "Explicitly out of scope" section) that this plan does not fix. A non-zero exit here is normal; do not attempt to fix those other paths.

- [ ] **Step 2: Extract the top failing paths, not just the overall WNS**

```bash
grep -n "Slack (VIOLATED)" -A 6 results/build/timing_summary.rpt | head -80
```

(If `results/build/timing_summary.rpt` doesn't exist or looks stale, re-run Step 1 first — `make synth`'s underlying `scripts/build.tcl` writes this file before its own gate check, per its own header comment, so it should be fresh even though the build "failed.")

- [ ] **Step 3: Identify whether the ML classifier's own path is among the violations**

Look through the violated paths for any `Source`/`Destination` under the `u_norm`/`u_ml` hierarchy (e.g. `u_norm/x*_reg[*]/C`, `u_ml/*_reg[*]/D` or `u_ml/*_reg[*]/C` to anywhere) — the same hierarchy the ORIGINAL failing path (before Task 1) was in (`u_norm/x7_reg[5]/C` → `u_ml/z_reg[29]/D`).

```bash
grep -n "Slack (VIOLATED)" -A 6 results/build/timing_summary.rpt | grep -B 6 "u_norm/\|u_ml/"
```

- [ ] **Step 4: Report the decision clearly**

Write a short note (in your task report, not a repo file) stating one of:

- **"ML path closed"** — no `u_norm`/`u_ml` path appears among the violated paths at all. In this case: **Task 5 (pipelining) is NOT needed.** Skip directly to Task 6 (documentation). Confirm this conclusion by also checking `results/build/timing_summary.rpt`'s `Intra Clock Table` (the per-clock-domain summary near the top) — the `rx_clk` row's `WNS` should now reflect only the OTHER (out-of-scope) failing paths' slack, not anything as severe as the original `-3.842 ns` if the ML path itself is gone from the violation list. Include the actual current `rx_clk` WNS value in your report either way, for the record.
- **"ML path still violated"** — a `u_norm`/`u_ml` path (or a NEW ML-branch path this rewrite introduced, e.g. inside the balanced tree itself) still appears with `Slack (VIOLATED)`. In this case: **proceed to Task 5.** Include the exact `Source`/`Destination`/slack value of that path in your report — Task 5 needs it.

Either way, this task's own git history has nothing to commit (no files changed) — just report the decision.

---

### Task 5 (CONDITIONAL — only if Task 4 found the ML path still violated): Pipeline the classifier into 2 stages

**Skip this task entirely if Task 4 reported "ML path closed."** If you are executing this task, Task 4's report should have given you the exact still-violated path — read that report before starting.

**Files:**
- Modify: `rtl/ml_classifier_wrap.v` (split into 2 registered stages)
- Modify: `rtl/tob_top.v` (`ALIGN_DEPTH` 4 → 5)
- Modify: `tb/tb_ml_classifier_wrap.v`, `tb/tb_ml_chain.v`, `tb/tb_ml_policy.v`, `tb/tb_tob_top.v`, `tb/tb_top.v` (cycle-offset expectations)
- Modify: `docs/contracts/ml_integration.md`, `fpga_tick_to_trade_master_spec.md` (timing tables)

**Interfaces:**
- `ml_classifier_wrap.v`: `ml_valid`/`ml_slot`/`z` now register 2 cycles after `norm_valid` (was 1). Port list unchanged.
- `tob_top.v`: `ALIGN_DEPTH` changes value (4→5); `ml_policy`'s wired `SNAPSHOT_DEPTH` changes automatically since Task 3 already wired it from `ALIGN_DEPTH`.

- [ ] **Step 1: Split `ml_classifier_wrap.v` into 2 pipeline stages**

Read the current file (post-Task-1) and replace the products + tree logic with a version that registers the products first, then computes the tree from the registered products on the next cycle:

```verilog
    reg signed [15:0] p0_r, p1_r, p2_r, p3_r, p4_r, p5_r, p6_r, p7_r;
    reg               stage1_valid;
    reg [1:0]         stage1_slot;

    wire signed [15:0] p0 = $signed(x0) * $signed(w_mem[0]);
    wire signed [15:0] p1 = $signed(x1) * $signed(w_mem[1]);
    wire signed [15:0] p2 = $signed(x2) * $signed(w_mem[2]);
    wire signed [15:0] p3 = $signed(x3) * $signed(w_mem[3]);
    wire signed [15:0] p4 = $signed(x4) * $signed(w_mem[4]);
    wire signed [15:0] p5 = $signed(x5) * $signed(w_mem[5]);
    wire signed [15:0] p6 = $signed(x6) * $signed(w_mem[6]);
    wire signed [15:0] p7 = $signed(x7) * $signed(w_mem[7]);

    wire signed [ACC_W-1:0] s0 = $signed(p0_r) + $signed(p1_r);
    wire signed [ACC_W-1:0] s1 = $signed(p2_r) + $signed(p3_r);
    wire signed [ACC_W-1:0] s2 = $signed(p4_r) + $signed(p5_r);
    wire signed [ACC_W-1:0] s3 = $signed(p6_r) + $signed(p7_r);
    wire signed [ACC_W-1:0] t0 = s0 + s1;
    wire signed [ACC_W-1:0] t1 = s2 + s3;
    wire signed [ACC_W-1:0] acc = (t0 + t1) + bias_trunc;
    wire signed [31:0] z_c = {{(32-ACC_W){acc[ACC_W-1]}}, acc};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            stage1_slot  <= 2'd0;
            p0_r <= 16'sd0; p1_r <= 16'sd0; p2_r <= 16'sd0; p3_r <= 16'sd0;
            p4_r <= 16'sd0; p5_r <= 16'sd0; p6_r <= 16'sd0; p7_r <= 16'sd0;
            ml_valid <= 1'b0;
            ml_slot  <= 2'd0;
            z        <= 32'sd0;
        end else begin
            stage1_valid <= norm_valid;
            stage1_slot  <= norm_slot;
            p0_r <= p0; p1_r <= p1; p2_r <= p2; p3_r <= p3;
            p4_r <= p4; p5_r <= p5; p6_r <= p6; p7_r <= p7;

            ml_valid <= stage1_valid;
            ml_slot  <= stage1_slot;
            z        <= z_c;
        end
    end
```

Update the module's own header comment (the "Timing:" paragraph near the top) to say `ml_valid` registers 2 cycles after `norm_valid`, not 1.

- [ ] **Step 2: Update `tob_top.v`'s `ALIGN_DEPTH`**

Find `localparam ALIGN_DEPTH = 4;` and change the value to `5`, updating its comment to explain the +1 (classifier now takes 2 cycles instead of 1, per Task 5/D53).

- [ ] **Step 3: Update every testbench with a hardcoded cycle-offset expectation**

For each of `tb/tb_ml_classifier_wrap.v`, `tb/tb_ml_chain.v`, `tb/tb_tob_top.v`, `tb/tb_top.v`: find the assertion(s) checking `ml_valid` arrives exactly 1 cycle after `norm_valid` (or after the equivalent upstream trigger), and update the cycle count by +1. For `tb/tb_ml_policy.v`: re-run with `-DTB_SNAPSHOT_DEPTH=5` instead of the current default, and update the file's own header comment describing the default depth.

(This step is intentionally not more prescriptive than that — the exact line numbers may have moved since this plan was written, and each testbench's existing structure/task/macro pattern for expressing "N cycles after trigger" should be followed exactly, not reinvented. If any testbench's structure makes this ambiguous, STOP and report BLOCKED with specifics rather than guessing.)

- [ ] **Step 4: Update the two docs with explicit per-stage latency numbers**

`docs/contracts/ml_integration.md` §1.3 and `fpga_tick_to_trade_master_spec.md` §S1.3/§S7.1: find the stated per-stage cycle table (`feature_extractor +1, feature_normalizer +2, ml_classifier_wrap +3` or similar) and update `ml_classifier_wrap`'s entry to `+4` (2 cycles later than `feature_normalizer`'s `+2`, matching the new 2-cycle classifier latency), and update any stated `ALIGN_DEPTH` value from 4 to 5.

- [ ] **Step 5: Full verification**

Repeat Task 1's Steps 3-6 (compile-check, hand-case testbench, `tb_ml_bit_exact.v`, full `run_sim.sh`) against the now-pipelined module — all must still pass, since the underlying arithmetic (balanced tree, `ACC_W=20`) is unchanged from Task 1, only WHEN it's registered changed.

- [ ] **Step 6: Re-run Task 4's synthesis check**

Repeat Task 4's Steps 1-4 against this pipelined design. If the ML path is STILL violated, add a third pipeline stage (split the tree further — e.g. register `s0..s3` in their own stage, then `t0/t1`+bias in a final stage) rather than guessing; this would add a further +1 cycle and cascade the same way (ALIGN_DEPTH 5→6, etc.) — if you reach this point, STOP and report back rather than continuing to iterate silently, since a 3rd stage means this plan's "add exactly 1 cycle" assumption was wrong and is worth a fresh look before continuing.

- [ ] **Step 7: Commit**

```bash
git add rtl/ml_classifier_wrap.v rtl/tob_top.v tb/tb_ml_classifier_wrap.v tb/tb_ml_chain.v tb/tb_ml_policy.v tb/tb_tob_top.v tb/tb_top.v docs/contracts/ml_integration.md fpga_tick_to_trade_master_spec.md
git commit -m "fix: pipeline ml_classifier_wrap.v into 2 stages to close remaining timing violation; ALIGN_DEPTH/SNAPSHOT_DEPTH 4->5 (D53)"
```

---

### Task 6: Documentation — design-decision entry and retrain-timing policy

**Files:**
- Modify: `docs/design_decisions.md` (append D53)
- Modify: `Makefile` (a comment on the `ml:` target) and/or `CLAUDE.md`/`README.md` (wherever `make ml`'s flow is described)

**Interfaces:** none — pure documentation, last task in this plan.

- [ ] **Step 1: Append D53 to `docs/design_decisions.md`**

Find the current last entry (`## D52 — ...`) and its final paragraph (search for the exact text of D52's last sentence to find the insertion point precisely, the same way D52 itself was inserted after D51 — insert AFTER D52's content and BEFORE the `---` separator that precedes `## Summary — §17 open question disposition`, giving your new entry its own `---` separator before that Summary section, matching the file's existing per-entry convention).

Write an entry (matching the established `## D53 — <one-line summary>` / bold **Status:** / narrative-paragraphs style used by every other entry in this file) covering:
- The root cause: real trained weights (D52) turned a previously-optimized-away multiply-accumulate into real logic; the failure was an unbalanced 8-way serial adder chain plus 15 unused accumulator bits (both confirmed against the actual routed netlist, not assumed), not a DSP-inference gap (weights are elaboration-time constants — this was investigated and ruled out, along with a DSP-cascade approach).
- The fix actually applied: state which of Task 1 (zero-latency) or Task 1+Task 5 (pipelined) closed it, based on what actually happened when this plan was executed.
- The `SNAPSHOT_DEPTH` wiring gap found and fixed (Task 3), independent of whether pipelining was needed.
- The accepted policy: because weights are synthesis-time constants, a future retrain can change the design's timing with no RTL change at all; **re-synthesizing and re-checking timing is now a required step after any retrain**, not an automated part of `make ml` (documented as a manual step, per Step 2 below).
- Reference the spec (`docs/superpowers/specs/2026-09-09-ml-classifier-timing-closure-design.md`) for the full analysis.
- Explicitly note (matching this plan's own scope) that two OTHER timing failures remain in the build, unrelated to the ML classifier, and are not addressed by this work.

- [ ] **Step 2: Document the retrain-timing policy**

Find wherever `make ml`'s behavior is currently documented (check `Makefile`'s own comment above the `ml:` target, and `CLAUDE.md`'s "What this repo is" paragraph, and `README.md`, for the most relevant/visible spot — likely more than one). Add a sentence stating: after `make ml` regenerates trained weights, `make synth` must be re-run and its timing report re-checked before trusting any existing bitstream, because weight VALUES (not just RTL) affect synthesis timing (D53) — do not assume a previously-passing build stays valid across a retrain.

- [ ] **Step 3: Verify no contradictions**

```bash
grep -n "D53\|ACC_W\|SNAPSHOT_DEPTH" docs/design_decisions.md CLAUDE.md README.md Makefile
```

Read through the matches and confirm nothing contradicts what was actually implemented (e.g., if Task 5/pipelining did NOT run, the D53 entry and any doc mentioning `ALIGN_DEPTH`/`SNAPSHOT_DEPTH` values must say they stayed at 4, not 5).

- [ ] **Step 4: Commit**

```bash
git add docs/design_decisions.md Makefile CLAUDE.md README.md
git commit -m "docs: D53 entry -- ML classifier timing closure, SNAPSHOT_DEPTH wiring fix, retrain-timing policy"
```

## Self-Review Notes

- **Spec coverage:** Phase 1 -> Task 1, Phase 2 -> folded into Task 1's own verification steps (and repeated in Task 5 if it runs), Phase 3 -> Task 4, Phase 4 -> Task 5 (conditional), Phase 5 -> Task 3, Phase 6 -> Task 6. All six spec phases have a corresponding task.
- **Conditional task handled explicitly:** Task 5 is clearly marked conditional on Task 4's decision gate, with Task 4 itself instructed to produce an unambiguous "closed" vs. "still violated" report rather than leaving that judgment implicit.
- **Type/signature consistency:** `ml_classifier_wrap.v`'s port list is unchanged in both Task 1 and Task 5 (only internal timing/registers change) — no other task depends on a signature this plan alters. `export()`'s new bound-check (Task 2) raises before touching any of its existing behavior, so no caller-visible change.
