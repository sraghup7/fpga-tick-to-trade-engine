# Risk Engine Timing Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two remaining post-D53 timing violations — `risk_engine.v`'s token-bucket path (-0.752ns) and the async-reset-fanout recovery path (-0.012ns) — restoring a build-wide gate-passing state (`WNS >= 0`) without changing observable behavior anywhere.

**Architecture:** Violation 1 is fixed by algebraic restructuring of `risk_engine.v`'s token-bucket update logic (no pipelining, no added latency, bit-exact) — proven equivalent to the current expressions by direct case analysis, not by re-deriving the design from scratch. Violation 2 is fixed by adding a missing `phys_opt_design` call to the synthesis flow (a one-line, zero-RTL-risk change whose whole job includes high-fanout net replication) — with a conditional, more invasive local-reset-tree hardening only if that alone isn't durably enough.

**Tech Stack:** Verilog-2001 (Icarus Verilog 12.0 for simulation), Vivado 2024.2 (`xc7a35tfgg484-2`), Python (golden model comparison only — no golden-model code change expected).

**Spec:** No separate spec document — this plan was authorized directly from a verified technical exchange (a written problem statement sent for external review, a second opinion received back, and independent verification of every load-bearing claim in that opinion before proceeding) rather than a formal brainstorm/spec cycle, since the fix design was already fully derived and checked before this plan was written. The full technical background lives in this plan's tasks below; there is no separate `docs/superpowers/specs/` file for this work.

## Global Constraints

- Verilog-2001 only, no vendor-primitive instantiation (repo `CLAUDE.md` / NFR-9).
- Every RTL change must compile with `iverilog -g2001 -Wall` with zero warnings and zero inferred latches.
- `token_bucket` (the register name) must not be renamed or restructured in a way that changes its bit width or its role as the module's externally-probed state — `tb/tb_risk_engine.v:224` hierarchically probes `dut.token_bucket` directly (`always @(posedge clk) if (tb_watch_en && dut.token_bucket > tb_max_seen) tb_max_seen = dut.token_bucket;`) and must keep working unmodified.
- `refill_ctr` MAY be renamed (nothing outside `risk_engine.v` hierarchically probes it by name — confirmed by grep across `tb/`, `sim/`, `docs/`).
- Every existing testbench must still pass with **zero behavior change** — this is a bit-exactness-preserving refactor, not a functional change. In particular: `sim/golden_model.py`'s token-bucket refill timing is modeled to the exact cycle (see its own D51 comment, around line 419-433) — any change that shifts which cycle a refill or an accept/reject decision lands on will break `tb_top`'s soak comparison the same way D51 originally did. This plan's whole point is to avoid that: no pipelining, same-cycle decisions throughout.
- `docs/contracts/risk_engine.md` §2.3 is the authoritative RTL contract for this exact logic and must be kept in sync with whatever code actually ships.
- Next design-decision number is **D54** (last entry in `docs/design_decisions.md` is D53).

---

### Task 1: Restructure `risk_engine.v`'s token-bucket arithmetic + equivalence testbench

**Files:**
- Modify: `rtl/risk_engine.v`
- Modify: `tb/tb_risk_engine.v` (add a new equivalence check block; do not remove the existing D45 watch block at line ~220-226)
- Modify: `docs/contracts/risk_engine.md` (§2.3, to match the new code, and fix one pre-existing stale detail found while touching this section — see Step 5)

**Interfaces:** none — `risk_engine.v`'s port list is unchanged; this only touches internal state/combinational logic. `token_bucket` keeps its name, width, and semantics (the value CSR reads and `tb_risk_engine.v:224` probes). `refill_ctr` is renamed to `refill_ctr_p1` (see Step 1 for why) — purely internal, not port-visible, not CSR-visible, not testbench-probed.

**The problem, precisely** (verified against a fresh `results/build/timing_summary.rpt`, current build):

```
Slack (VIOLATED) :        -0.752ns
  Source:                 u_risk/refill_ctr_reg[1]/C
  Destination:            u_risk/token_bucket_reg[31]/D
  Path Type:              Setup (Max at Slow Process Corner)
  Data Path Delay:        8.685ns  (logic 5.418ns (62.386%)  route 3.267ns (37.615%))
  Logic Levels:           27  (CARRY4=22 LUT4=2 LUT5=1 LUT6=2)
```

The routed netlist shows two chained 32-bit ripple-carry structures running
combinationally in one cycle with no register between them: first an
incrementer+comparator computing `refill_tick`, then a second carry chain
computing `token_bucket`'s next value (an add, immediately followed by a
conditional subtract on the SAME value). `cfg_token_max`/
`cfg_token_refill_cycles` are runtime-writable 32-bit CSR registers (not
elaboration-time constants), so Vivado can't constant-fold either compare —
the fix must restructure the arithmetic itself, not rely on synthesis
optimizing away unreachable width.

**The current code** (`rtl/risk_engine.v`, for reference — lines are
approximate, search for the exact text):

```verilog
reg [31:0] refill_ctr;
reg [31:0] token_bucket;
...
wire refill_tick = (refill_ctr + 32'd1) >= cfg_token_refill_cycles;
wire [31:0] refill_ctr_next = refill_tick
    ? (refill_ctr + 32'd1 - cfg_token_refill_cycles)
    : (refill_ctr + 32'd1);
wire [31:0] token_bucket_eff = boot_done ? token_bucket : cfg_token_max;
wire [31:0] token_after_refill = (refill_tick && (token_bucket_eff < cfg_token_max))
    ? (token_bucket_eff + 32'd1)
    : token_bucket_eff;
wire gate_throttle_fired_c = (token_after_refill == 32'd0);
...
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        refill_ctr   <= 32'd0;
        token_bucket <= 32'd0;
        boot_done    <= 1'b0;
    end else begin
        refill_ctr <= refill_ctr_next;
        boot_done  <= 1'b1;
        if (accepted_c) token_bucket <= (token_after_refill == 32'd0)
                                         ? 32'd0 : token_after_refill - 32'd1;
        else            token_bucket <= token_after_refill;
    end
end
```

- [ ] **Step 1: Rewrite the state declarations and combinational logic**

Find:

```verilog
    // ---- free-running token bucket (S2.3) ----
    reg [31:0] refill_ctr;
    reg [31:0] token_bucket;
```

Replace with:

```verilog
    // ---- free-running token bucket (S2.3) ----
    // D54: refill_ctr_p1 stores (the old refill_ctr's value) + 1 as a
    // maintained invariant, instead of storing refill_ctr and adding 1 to
    // it every time refill_tick needs to be checked. This keeps the "+1"
    // off risk_engine's own critical path (u_risk/refill_ctr_reg[1]/C ->
    // u_risk/token_bucket_reg[31]/D, -0.752ns pre-fix) -- refill_tick
    // becomes a direct 32-bit compare against a register, with no
    // incrementer in front of it. The "+1" still happens, just on
    // refill_ctr_p1's OWN next-state path (a separate register-to-register
    // path, not the one that was violated) instead of on the forward path
    // into token_bucket. Provably equivalent: refill_ctr_p1 == (what
    // refill_ctr would have held) + 1, maintained from reset (refill_ctr
    // started at 0, so refill_ctr_p1 starts at 1) through every update.
    // Nothing outside this module ever reads refill_ctr by name (grepped
    // tb/, sim/, docs/ before renaming) -- token_bucket keeps its name
    // unchanged, since tb/tb_risk_engine.v:224 hierarchically probes it.
    reg [31:0] refill_ctr_p1;
    reg [31:0] token_bucket;
```

Find:

```verilog
    wire refill_tick = (refill_ctr + 32'd1) >= cfg_token_refill_cycles;
    wire [31:0] refill_ctr_next = refill_tick
        ? (refill_ctr + 32'd1 - cfg_token_refill_cycles)
        : (refill_ctr + 32'd1);
    // D38: substitute cfg_token_max for token_bucket until the reset-time
    // synchronous load actually lands (see boot_done's declaration above).
    wire [31:0] token_bucket_eff = boot_done ? token_bucket : cfg_token_max;
    wire [31:0] token_after_refill = (refill_tick && (token_bucket_eff < cfg_token_max))
        ? (token_bucket_eff + 32'd1)
        : token_bucket_eff;
```

Replace with:

```verilog
    // D54: direct compare, no incrementer -- refill_ctr_p1 already holds
    // (old refill_ctr)+1.
    wire refill_tick = (refill_ctr_p1 >= cfg_token_refill_cycles);
    // D54: refill_ctr_p1_next maintains the "+1" invariant: it must equal
    // (what the old refill_ctr_next would have been) + 1. Derivation:
    //   old refill_ctr_next = refill_tick ? (refill_ctr+1-cfg) : (refill_ctr+1)
    //                        = refill_tick ? (refill_ctr_p1-cfg) : refill_ctr_p1
    //   new refill_ctr_p1_next = old refill_ctr_next + 1
    //                          = refill_tick ? (refill_ctr_p1-cfg+1) : (refill_ctr_p1+1)
    // This add/subtract now lives entirely on refill_ctr_p1's own
    // register-to-register path, decoupled from token_bucket's path below.
    wire [31:0] refill_ctr_p1_next = refill_tick
        ? (refill_ctr_p1 - cfg_token_refill_cycles + 32'd1)
        : (refill_ctr_p1 + 32'd1);
    // D38: substitute cfg_token_max for token_bucket until the reset-time
    // synchronous load actually lands (see boot_done's declaration above).
    wire [31:0] token_bucket_eff = boot_done ? token_bucket : cfg_token_max;
    // D54: inc replaces "refill_tick && (token_bucket_eff < cfg_token_max)"
    // -- same expression, named so the merged token_bucket_next below reads
    // clearly.
    wire inc = refill_tick && (token_bucket_eff < cfg_token_max);
```

Find:

```verilog
    wire gate_throttle_fired_c = (token_after_refill == 32'd0);
```

Replace with:

```verilog
    // D54: token_after_refill == 0 iff (!inc && token_bucket_eff == 0) --
    // proof: when inc is true, token_bucket_eff < cfg_token_max is
    // required, so token_bucket_eff+1 <= cfg_token_max <= 32'hFFFFFFFF,
    // meaning it can only be 0 by wrapping, which would require
    // token_bucket_eff == 32'hFFFFFFFF -- impossible given
    // token_bucket_eff < cfg_token_max already holds. So inc==1 implies
    // token_after_refill != 0 always; when inc==0, token_after_refill ==
    // token_bucket_eff unchanged, so it's 0 exactly when
    // token_bucket_eff is. This lets gate_throttle_fired_c be computed
    // directly with no dependency on a materialized token_after_refill
    // signal.
    wire gate_throttle_fired_c = (!inc && (token_bucket_eff == 32'd0));
```

- [ ] **Step 2: Rewrite the sequential update block**

Find:

```verilog
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refill_ctr   <= 32'd0;
            token_bucket <= 32'd0;   // D38: constant reset value -- boot_done
                                      // substitutes cfg_token_max until loaded
            boot_done    <= 1'b0;
        end else begin
            refill_ctr <= refill_ctr_next;
            boot_done  <= 1'b1;
            // single next-state expression: refill combined with any
            // same-cycle consumption -- never two separate NBA writes.
            // D45: clamp at 0 instead of letting the subtraction wrap.
            // gate_throttle_fired_c (stage 1, above) samples token_bucket
            // one cycle before THIS decrement commits, so back-to-back
            // aligned intents on consecutive cycles can each see the same
            // not-yet-decremented value and all pass the gate -- accepted_c
            // can therefore still be 1 here when token_after_refill is
            // already 0. Without the clamp, token_bucket wraps to
            // 32'hFFFFFFFF, which is not zero, so gate_throttle_fired_c
            // never fires again for the rest of the run (FR-41's
            // non-bypassable gate 0x08 silently and permanently disabled).
            // This guard fixes ONLY that permanent-disable failure mode --
            // it does not fix the underlying over-admission on a
            // back-to-back burst (docs/design_decisions.md D45), which is a
            // separate, larger change deliberately deferred.
            if (accepted_c) token_bucket <= (token_after_refill == 32'd0)
                                             ? 32'd0 : token_after_refill - 32'd1;
            else            token_bucket <= token_after_refill;
        end
    end
```

Replace with:

```verilog
    // D54: token_bucket_next replaces the old "compute token_after_refill,
    // then conditionally subtract 1 from it" chain (two SERIAL 32-bit
    // carry chains) with a single mux over 4 independently-computable
    // candidates (each needs at most ONE 32-bit add or subtract, not two
    // chained). Case-by-case equivalence to the original expressions:
    //   (inc=1, accepted_c=1): old = (eff+1), then clamp-check sees
    //     eff+1 != 0 (proven above), so subtracts 1 back: eff+1-1 = eff.
    //   (inc=1, accepted_c=0): old = eff+1, no subtract.
    //   (inc=0, accepted_c=1): old = eff unchanged, then clamp-check:
    //     eff==0 ? 0 : eff-1.
    //   (inc=0, accepted_c=0): old = eff unchanged, no subtract.
    // Every branch below matches one of these four cases exactly.
    wire [31:0] token_bucket_next =
        inc ? (accepted_c ? token_bucket_eff : (token_bucket_eff + 32'd1))
            : (accepted_c ? ((token_bucket_eff == 32'd0) ? 32'd0 : (token_bucket_eff - 32'd1))
                          : token_bucket_eff);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refill_ctr_p1 <= 32'd1;   // D54: represents (old refill_ctr=0)+1
            token_bucket  <= 32'd0;   // D38: constant reset value -- boot_done
                                       // substitutes cfg_token_max until loaded
            boot_done     <= 1'b0;
        end else begin
            refill_ctr_p1 <= refill_ctr_p1_next;
            boot_done     <= 1'b1;
            // D45: the clamp-at-0 behavior (never wrap to 32'hFFFFFFFF) is
            // folded into token_bucket_next's (inc=0, accepted_c=1) branch
            // above -- same guard, same reasoning (gate_throttle_fired_c
            // samples token_bucket one cycle before this commits, so
            // back-to-back aligned intents can still both pass the gate;
            // without the clamp gate 0x08 would silently disable itself
            // permanently, FR-41). D45's own separately-deferred
            // over-admission-on-a-burst issue is unchanged by this task.
            token_bucket <= token_bucket_next;
        end
    end
```

- [ ] **Step 3: Compile-check**

```bash
iverilog -g2001 -Wall -o /tmp/lint.vvp rtl/*.v rtl/common/*.v tb/sim_models/tob_top_sim_leaves.v
```

Expected: zero warnings, zero errors.

- [ ] **Step 4: Add a continuous equivalence-check block to `tb/tb_risk_engine.v`**

This proves the rewritten expressions produce byte-identical `token_bucket`
values to the ORIGINAL expressions, across the file's ENTIRE existing test
sequence — not a separate bolted-on randomized loop. Two facts about this
file matter for how to wire this in correctly (verified directly, don't
re-derive from scratch):

- `cfg_token_max`/`cfg_token_refill_cycles` (declared around lines 151-152)
  are plain testbench `reg`s, driven by direct assignment throughout the
  file's directed tests (e.g. `cfg_token_max = 32'd2;
  cfg_token_refill_cycles = 32'd100;` around line 687) — **not** written
  via a CSR-bus task. There is no "CSR-write task" to reuse for these two
  signals; they're forced directly. The file's directed tests already
  exercise several different `(cfg_token_max, cfg_token_refill_cycles)`
  combinations (100/100000, 8/12500, 2/100, 2/1000000 among them) — good
  natural variety, though none currently hit `cfg_token_max == 0` or
  `cfg_token_refill_cycles == 1`. Add two small additional directed blocks
  (following the existing file's own style — find a natural point between
  two existing test blocks, not necessarily at the very end) that briefly
  set `cfg_token_max = 32'd0;` and separately `cfg_token_refill_cycles =
  32'd1;` for a handful of cycles each, specifically to exercise those two
  boundary values under the equivalence check below (no new pass/fail
  assertions needed for these blocks themselves beyond letting the
  continuous equivalence check run over them).
- The file's pass/fail convention is a single shared `reg fail` flag,
  set `fail = 1'b1;` on any mismatch throughout the file, checked once at
  the very end (around line 1114-1122: `if (fail) begin $display("FAIL");
  $finish; end $display("PASS"); $finish;`). A **separate, independently
  time-boxed** `initial` block racing its own `for` loop against this
  file's own `$finish` would risk truncation mid-check and a false sense
  of coverage. Instead, drive the equivalence check from an `always
  @(posedge clk)` block that runs continuously for the file's entire
  natural lifetime (from reset deassertion to whatever `$finish` the
  existing test sequence already reaches) and folds into the SAME shared
  `fail` flag other checks in this file already use.

Add, near the file's other state declarations (before the main `initial
begin` test sequence):

```verilog
    // ---- D54 equivalence check: reference (OLD, pre-D54) expressions
    //      computed in a shadow state, compared against the DUT's (NEW,
    //      restructured) token_bucket every cycle for this file's entire
    //      test run -- independent of Steps 1-2's hand-proof, this
    //      exercises every directed test in this file (including the two
    //      new boundary blocks above) and checks bit-for-bit agreement,
    //      not just the hand-checked cases. Runs continuously rather than
    //      as a separately time-boxed loop so it can never be truncated by
    //      this file's own final $finish. This is a literal, direct
    //      transcription of the ORIGINAL pre-D54 expressions (quoted in
    //      this task's own background section above) -- an independent
    //      re-derivation, not a shortcut that agrees with Steps 1-2's math
    //      by construction. ----
    reg [31:0] ref_refill_ctr = 32'd0;
    reg [31:0] ref_token_bucket = 32'd0;
    reg        ref_boot_done = 1'b0;
    integer    d54_mismatches = 0;
    reg        d54_active = 1'b0;   // gates tracking until first post-reset edge

    // Combinational shadow of the ORIGINAL (pre-D54) expressions, using
    // the reference state above instead of the DUT's registers.
    reg        ref_refill_tick;
    reg [31:0] ref_refill_ctr_next;
    reg [31:0] ref_token_bucket_eff;
    reg [31:0] ref_token_after_refill;
    always @(*) begin
        ref_refill_tick      = (ref_refill_ctr + 32'd1) >= cfg_token_refill_cycles;
        ref_refill_ctr_next  = ref_refill_tick
            ? (ref_refill_ctr + 32'd1 - cfg_token_refill_cycles)
            : (ref_refill_ctr + 32'd1);
        ref_token_bucket_eff = ref_boot_done ? ref_token_bucket : cfg_token_max;
        ref_token_after_refill = (ref_refill_tick && (ref_token_bucket_eff < cfg_token_max))
            ? (ref_token_bucket_eff + 32'd1)
            : ref_token_bucket_eff;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            ref_refill_ctr   <= 32'd0;
            ref_token_bucket <= 32'd0;
            ref_boot_done    <= 1'b0;
            d54_active       <= 1'b0;
        end else begin
            if (d54_active && (ref_token_bucket !== dut.token_bucket)) begin
                $display("FAIL: D54 equivalence mismatch: ref=%0d dut=%0d (cfg_token_max=%0d cfg_token_refill_cycles=%0d accepted_c=%b)",
                          ref_token_bucket, dut.token_bucket,
                          cfg_token_max, cfg_token_refill_cycles, dut.accepted_c);
                d54_mismatches = d54_mismatches + 1;
                fail = 1'b1;
            end
            ref_refill_ctr <= ref_refill_ctr_next;
            if (dut.accepted_c) ref_token_bucket <= (ref_token_after_refill == 32'd0)
                                                     ? 32'd0 : ref_token_after_refill - 32'd1;
            else                ref_token_bucket <= ref_token_after_refill;
            ref_boot_done <= 1'b1;
            d54_active <= 1'b1;
        end
    end
```

At the very end of the file, near the existing final `if (fail) ... $finish`
block, add one line reporting the mismatch count for visibility (this does
NOT replace the `fail` flag already being set above — it's just a summary
line):

```verilog
$display("D54 equivalence check: %0d mismatches over the full test run", d54_mismatches);
```

- [ ] **Step 5: Update `docs/contracts/risk_engine.md` §2.3**

Find (§2.3, "Token bucket throttle"):

```markdown
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
```

Replace with:

```markdown
A **continuously free-running** refill counter, independent of message
arrival — not a lazy "compute elapsed cycles when a message shows up"
calculation (which is how `sim/golden_model.py` does it, using Python's
division; see the note below for why RTL should NOT copy that structure
literally). The counter (`refill_ctr_p1`) stores the count **plus one** as
a maintained invariant (D54) — this keeps the "+1" off the critical
register-to-register path into `token_bucket` (a real timing violation
this exact "+1 then compare" structure caused once real weights elsewhere
in the design changed placement/routing pressure — see
`docs/design_decisions.md` D54). Conceptually it's still "increments every
cycle; when it would reach `cfg_token_refill_cycles`, `token_bucket` gains
one token (saturating at `cfg_token_max`) and the counter carries its
remainder forward" — D54 changed how that's expressed in RTL, not what it
computes:

```verilog
wire refill_tick = (refill_ctr_p1 >= cfg_token_refill_cycles);
wire [31:0] refill_ctr_p1_next = refill_tick
    ? (refill_ctr_p1 - cfg_token_refill_cycles + 32'd1)
    : (refill_ctr_p1 + 32'd1);
wire inc = refill_tick && (token_bucket_eff < cfg_token_max);
wire [31:0] token_bucket_next =
    inc ? (accepted_c ? token_bucket_eff : (token_bucket_eff + 32'd1))
        : (accepted_c ? ((token_bucket_eff == 32'd0) ? 32'd0 : (token_bucket_eff - 32'd1))
                      : token_bucket_eff);
```

`gate_throttle_fired` (§2.5) fires when `!inc && token_bucket_eff == 32'd0`
— algebraically identical to the pre-D54 "`token_after_refill == 0`" check
(D54 proves `inc` being true makes that impossible), just computed without
ever materializing an intermediate `token_after_refill` signal. `token_bucket`'s
single next-state expression (`token_bucket_next`, D54) still combines
refill with any same-cycle consumption from an accepted order (§2.6) in one
expression — **do not write two separate non-blocking assignments to
`token_bucket` in the same `always` block**; only the textually-last one
would actually apply, silently dropping the other. On reset, `token_bucket
<= 32'd0` (a plain constant clear — NOT `cfg_token_max`, which is a runtime
CSR value Xilinx FDCE/FDPE primitives cannot async-reset to directly; see
`docs/design_decisions.md` D38 for why this line previously said
`cfg_token_max` inaccurately and `token_bucket_eff`/`boot_done` exist to
substitute the config value in combinationally until the first real cycle).
```

(The reset-value correction in that last paragraph fixes a pre-existing
inaccuracy in this doc found while updating this section — the actual RTL
has reset to a constant `0` since D38, not `cfg_token_max` as this doc
previously claimed; unrelated to D54's own change but cheap to fix in the
same edit since this exact paragraph was already being rewritten.)

- [ ] **Step 6: Run tests**

```bash
iverilog -g2001 -Wall -o /tmp/tb_risk_engine.vvp rtl/risk_engine.v rtl/common/delay_line.v tb/sim_models/*.v tb/tb_risk_engine.v
vvp /tmp/tb_risk_engine.vvp
```

Expected: the file's final `PASS` (not `FAIL`), plus a `D54 equivalence
check: 0 mismatches over the full test run` line (any nonzero count means
the restructured RTL disagrees with the original expressions somewhere in
the existing test sequence — a real problem, not a testbench issue, since
the reference logic is a direct transcription of the unmodified original
code). If the existing testbench doesn't compile standalone this way,
check its own file header for the actual file list it needs and use that
instead — don't guess blindly.

Then run the full suite:

```bash
RUN_SIM_FAST=1 bash scripts/run_sim.sh
```

Expected: `ALL TESTS PASSED`. This is the real bit-exactness gate — if
`tb_top`'s 5,009-message soak still matches (same order/counter mismatch
counts as the current baseline, all pre-existing/D51-documented), this
change introduced no observable behavior difference anywhere in the full
system, confirming the equivalence proof holds end-to-end and not just in
the new isolated testbench.

- [ ] **Step 7: Commit**

```bash
git add rtl/risk_engine.v tb/tb_risk_engine.v docs/contracts/risk_engine.md
git commit -m "fix: risk_engine.v token-bucket arithmetic restructured to close timing violation (D54)

Store refill_ctr+1 instead of refill_ctr (keeps the +1 off the critical
path into token_bucket; refill_tick becomes a direct compare) and collapse
the chained increment-then-conditional-decrement into a single 4-way mux
over independently-computable candidates (proven equivalent by case
analysis: token_after_refill==0 iff !inc && eff==0, so the old clamp only
ever applied on the no-increment branch). Zero added latency, zero
behavior change -- bit-exact per a new randomized 2000-cycle equivalence
testbench plus the existing full-system soak's unchanged mismatch counts.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: Add `phys_opt_design` to `scripts/build.tcl`

**Files:**
- Modify: `scripts/build.tcl`

**Interfaces:** none — build-flow change only, no RTL/testbench touched.

**Background:** the second violation (`u_rst_sync/ff2_reg/C` →
`u_csr/cnt_ml_benign_reg[28]/CLR`, `**async_default**` Recovery check,
`-0.012ns`) is a routing problem: the reset synchronizer's output, after
one inverting LUT (active-low → active-high for the `CLR` pin), fans out
to 10,881 destination pins (`fo=10881` in the timing report), and whichever
one is physically farthest away blows the recovery-time budget. This is
exactly the class of problem `phys_opt_design`'s automatic high-fanout net
replication addresses, and `scripts/build.tcl` currently never calls it —
confirmed directly (`grep -n "phys_opt_design\|place_design\|route_design"
scripts/build.tcl` shows the flow goes `opt_design` → `place_design` →
`route_design` with nothing in between).

- [ ] **Step 1: Confirm the current flow**

```bash
grep -n "opt_design\|place_design\|route_design\|phys_opt_design" scripts/build.tcl
```

Expected: `opt_design`, `place_design`, `route_design` each appear once, in
that order, with no `phys_opt_design` anywhere.

- [ ] **Step 2: Add the call**

Find:

```tcl
opt_design
place_design
route_design
```

Replace with:

```tcl
opt_design
place_design
# D54: phys_opt_design (post-placement optimization) was missing from this
# flow entirely. Its jobs include automatic replication of high-fanout
# nets -- exactly the mechanism needed to close the async-reset-fanout
# recovery-check violation (u_rst_sync's output fans out to 10,881 pins
# after one inverting LUT; report_high_fanout_nets after this step should
# show that net's fanout reduced by replication). Zero RTL change; this is
# a pure build-flow addition.
phys_opt_design
route_design
```

- [ ] **Step 3: Commit**

```bash
git add scripts/build.tcl
git commit -m "fix: add missing phys_opt_design step to scripts/build.tcl (D54)

place_design was followed directly by route_design with no post-placement
optimization pass -- phys_opt_design's high-fanout net replication is the
standard fix for the async-reset-fanout recovery violation on
u_rst_sync's output (fo=10881 after its inverting LUT). Zero RTL change.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: Re-synthesize and determine the decision gate (both violations, and whether Task 4 is needed)

**Files:** none (this task runs tools and inspects output; no code changes)

**Interfaces:** none. **This task's outcome decides whether Task 4
(reset-tree hardening) is needed at all** — read Step 4 carefully.

- [ ] **Step 1: Run synthesis through implementation**

```bash
make synth
```

This runs a full Vivado synthesis + implementation flow (several minutes).
It may still exit non-zero if either violation isn't fully closed — that's
expected and not automatically a task failure; read the actual numbers in
Step 2 before deciding.

- [ ] **Step 2: Extract every violated path**

```bash
grep -n "Slack (VIOLATED)" -A 8 results/build/timing_summary.rpt
```

- [ ] **Step 3: Check for NEW violations Task 1 might have introduced**

Task 1 added a new register-to-register path (`refill_ctr_p1` ->
`refill_ctr_p1`, its own next-state update) that didn't exist in quite this
form before. Confirm this path is NOT itself now violated:

```bash
grep -n "Slack (VIOLATED)" -A 6 results/build/timing_summary.rpt | grep -B 6 "refill_ctr_p1"
```

Expected: no matches. If there IS a match, this is a genuine new problem
this task must report clearly (do not silently ignore a new violation just
because the two known ones are gone).

- [ ] **Step 4: Report the decision clearly**

Write a short note (in your task report, not a repo file) stating the
current `WNS`/`WHS` and, for EACH of the two original violations
specifically:

- **Violation 1 (risk_engine token-bucket):** closed, or still violated
  (report the exact slack either way)?
- **Violation 2 (async-reset-fanout recovery):** closed, or still
  violated? If closed, report the margin. Per this plan's own technical
  background: a pass with a thin margin (under **0.5ns**) on this specific
  path should be treated as "closed by placement luck, not durably fixed"
  — `phys_opt_design` alone might not have actually replicated the
  high-fanout net; confirm by checking `report_high_fanout_nets` output for
  the specific net that was `fo=10881` before this task's changes (search
  `vivado.log` or re-run `report_high_fanout_nets` if the build script
  doesn't already produce it — check `scripts/build.tcl` for whether this
  report is generated, and if not, note that as a gap rather than
  guessing).

State one of:
- **"Both violations closed, durably"** (violation 2's margin is >= 0.5ns
  AND `report_high_fanout_nets` confirms the previously-10,881-fanout net
  was actually reduced by replication, not just coincidentally not on the
  critical path this run). In this case: **Task 4 is NOT needed.**
- **"Violation 1 closed, violation 2 still violated OR closed only by thin
  margin/unconfirmed replication."** In this case: **Task 4 (reset-tree
  hardening) is needed next.**
- **"Violation 1 still violated"** — this would mean Task 1's equivalence
  proof or its implementation has a real bug Task 1's own review missed;
  this is NOT a "proceed to Task 4" situation, it's a stop-and-reassess
  situation. Flag clearly and do not proceed past this task.

Either way, this task's own git history has nothing to commit (no files
changed) — just report the decision clearly at the top of your report and
in your final summary message.

---

### Task 4 (CONDITIONAL — only if Task 3 says it's needed): Local per-module reset-tree hardening

**Do not dispatch this task if Task 3 reported "Both violations closed,
durably."**

**Files:**
- Modify: `rtl/tob_top.v`

**Interfaces:** none externally — this changes how `engine_rst_n` reaches
each module instance internally, not any module's port list.

**Background:** `engine_rst_n` (the 2FF-synchronized reset,
`rtl/common/sync_2ff.v` instantiated as `u_rst_sync`) currently fans out
directly to roughly 20 module instantiations in `tob_top.v`, each with
potentially many internal registers using it as an async reset — this
single point of fanout is what `phys_opt_design` (Task 2) is being asked
to fix via automatic replication. If that isn't durably sufficient, the
more explicit fix is a small, manually-instantiated local reset buffer per
module instance, so no single flip-flop drives more than a modest number
of loads directly.

**Two constraints that make this correctness-sensitive, not just a
mechanical copy-paste:**

1. **Every local reset buffer must have the exact same depth (1 extra
   register stage) as every other one.** `sim/golden_model.py`'s D51 fix
   assumes `cur_cycle` (in `tob_top.v`) and `refill_ctr`/`refill_ctr_p1`
   (in `risk_engine.v`) leave reset on the same cycle (see the D51 comment
   in `sim/golden_model.py` around line 419-433, and
   `docs/design_decisions.md` D51). Uneven reset-release depth across
   module instances would silently break this and reintroduce a D51-class
   bug — this is the single most important thing to get right in this
   task.
2. **Each local buffer register needs a `(* keep = "true" *)` attribute**
   (or equivalent — check what attribute syntax this codebase's other
   `KEEP`/`DONT_TOUCH`-sensitive RTL already uses, if any, via `grep -rn
   "keep\|dont_touch" rtl/`) so synthesis doesn't merge the now-identical
   local buffers back into a single register, defeating the whole point.

**Task 3's actual finding (this section written after Task 3 ran, per the
plan's own deferral):** `phys_opt_design` made **zero modifications** — its
own log states `"No setup violation found. The netlist was not modified"`,
because `place_design` had already reached a barely-non-negative WNS
(0.239ns estimated) before `phys_opt_design` even ran, and Vivado's
`phys_opt_design` structurally skips all setup optimization once WNS is
already ≥ 0. This means the mechanism Task 2 was counting on can **never**
harden an already-passing-by-margin path — it is conditionally gated on the
opposite of what we need. The worst destination this run was
`u_feat/win_abs_reg[87]/CLR` (feature_extractor, not `csr_block.v` as
originally seen) at a 0.528ns margin on a still-`fo=10876` net (was
`fo=10881` — essentially unchanged) — confirming the net itself was never
touched. The fix below is therefore a deterministic RTL change, not a
build-flow constraint that depends on Vivado's heuristics.

**The exact fix:** one local reset buffer per module instance currently
wired to `engine_rst_n` in `rtl/tob_top.v` — confirmed by grep to be
exactly 19 consumers (18 module instantiations plus one bare register,
`cur_cycle`, that uses `engine_rst_n` directly in its own `always` block):
`u_mac`, `u_eth_if`, `u_fc`, `u_md`, `u_sym`, `u_seq`, `u_tob`, `u_sig`,
`u_feat`, `u_norm`, `u_ml`, `u_policy`, `u_align`, `u_kill_sync`,
`cur_cycle`, `u_risk`, `u_ob`, `u_csr`, `u_hist`.

Each buffer is **independently async-reset by `engine_rst_n` directly** —
NOT a synchronous pipeline register. This is the critical design choice:
a plain `always @(posedge clk) buf <= engine_rst_n;` would add a real
1-cycle delay to reset release (and, worse, a 1-cycle delay to reset
*assertion* propagating too, since a purely synchronous register can't
react to an async event between clock edges). Instead, every buffer below
uses the SAME `always @(posedge gmii_rx_clk or negedge engine_rst_n)`
async-sensitivity pattern as `engine_rst_n` itself already has — meaning
every buffer releases on the exact same clock edge as `engine_rst_n`'s own
release, with zero added cycle latency anywhere. This is a pure fanout/
placement fix: `engine_rst_n` now only drives 19 flip-flops directly
(trivial fanout, easy to route anywhere), and each of those 19 flip-flops'
own output then drives only ONE module's internal registers — letting
Vivado's placer put each buffer physically next to its own consumer
instead of needing one single point to reach ~10,881 scattered
destinations across the whole die.

- [ ] **Step 1: Add the 19 local reset buffers to `rtl/tob_top.v`**

Find (the existing reset synchronizer, unchanged):

```verilog
    // ---- engine reset, synchronized into the gmii_rx_clk domain ----
    wire engine_rst_n;
    sync_2ff #(.RESET_VALUE(1'b0)) u_rst_sync (
        .clk      (gmii_rx_clk),
        .rst_n    (phy_reset_n_r),   // async reset held while the PHY reset is low
        .async_in (phy_reset_n_r),
        .sync_out (engine_rst_n)
    );
```

Immediately after it, add:

```verilog
    // ---- D54 (Task 4): local reset-fanout buffers, one per module
    // instance. Each is independently async-reset by engine_rst_n
    // directly (same posedge-clk-or-negedge-rst_n pattern engine_rst_n
    // itself uses) -- NOT a synchronous pipeline stage, so every buffer
    // releases on the exact same clock edge engine_rst_n itself releases
    // on. Zero cycle-timing change anywhere; this only reduces engine_rst_n's
    // own fanout to 19 (trivial to route) and gives each of these 19
    // buffers' own, much smaller, LOCAL fanout to its own module -- letting
    // placement put each buffer physically next to its own consumer
    // instead of one point reaching ~10,881 scattered destinations
    // (docs/design_decisions.md D54). (* keep = "true" *) stops synthesis
    // from merging these 19 logically-identical registers back into one.
    (* keep = "true" *) reg rst_n_mac;
    (* keep = "true" *) reg rst_n_eth_if;
    (* keep = "true" *) reg rst_n_fc;
    (* keep = "true" *) reg rst_n_md;
    (* keep = "true" *) reg rst_n_sym;
    (* keep = "true" *) reg rst_n_seq;
    (* keep = "true" *) reg rst_n_tob;
    (* keep = "true" *) reg rst_n_sig;
    (* keep = "true" *) reg rst_n_feat;
    (* keep = "true" *) reg rst_n_norm;
    (* keep = "true" *) reg rst_n_ml;
    (* keep = "true" *) reg rst_n_policy;
    (* keep = "true" *) reg rst_n_align;
    (* keep = "true" *) reg rst_n_kill_sync;
    (* keep = "true" *) reg rst_n_cur_cycle;
    (* keep = "true" *) reg rst_n_risk;
    (* keep = "true" *) reg rst_n_ob;
    (* keep = "true" *) reg rst_n_csr;
    (* keep = "true" *) reg rst_n_hist;

    always @(posedge gmii_rx_clk or negedge engine_rst_n) begin
        if (!engine_rst_n) begin
            rst_n_mac       <= 1'b0;
            rst_n_eth_if    <= 1'b0;
            rst_n_fc        <= 1'b0;
            rst_n_md        <= 1'b0;
            rst_n_sym       <= 1'b0;
            rst_n_seq       <= 1'b0;
            rst_n_tob       <= 1'b0;
            rst_n_sig       <= 1'b0;
            rst_n_feat      <= 1'b0;
            rst_n_norm      <= 1'b0;
            rst_n_ml        <= 1'b0;
            rst_n_policy    <= 1'b0;
            rst_n_align     <= 1'b0;
            rst_n_kill_sync <= 1'b0;
            rst_n_cur_cycle <= 1'b0;
            rst_n_risk      <= 1'b0;
            rst_n_ob        <= 1'b0;
            rst_n_csr       <= 1'b0;
            rst_n_hist      <= 1'b0;
        end else begin
            rst_n_mac       <= 1'b1;
            rst_n_eth_if    <= 1'b1;
            rst_n_fc        <= 1'b1;
            rst_n_md        <= 1'b1;
            rst_n_sym       <= 1'b1;
            rst_n_seq       <= 1'b1;
            rst_n_tob       <= 1'b1;
            rst_n_sig       <= 1'b1;
            rst_n_feat      <= 1'b1;
            rst_n_norm      <= 1'b1;
            rst_n_ml        <= 1'b1;
            rst_n_policy    <= 1'b1;
            rst_n_align     <= 1'b1;
            rst_n_kill_sync <= 1'b1;
            rst_n_cur_cycle <= 1'b1;
            rst_n_risk      <= 1'b1;
            rst_n_ob        <= 1'b1;
            rst_n_csr       <= 1'b1;
            rst_n_hist      <= 1'b1;
        end
    end
```

- [ ] **Step 2: Rewire each of the 19 consumers to its own buffer**

Each of these is a one-line change (context lines shown so the correct
occurrence is unambiguous — several instantiations use identical
`.rst_n (engine_rst_n),` text, so match by the surrounding instance name):

| Instance | Find (within that instantiation's port list) | Replace with |
|---|---|---|
| `u_mac` | `.rst_n                    (engine_rst_n),` | `.rst_n                    (rst_n_mac),` |
| `u_eth_if` | `.rst_n                   (engine_rst_n),` | `.rst_n                   (rst_n_eth_if),` |
| `u_fc` | `.rst_n         (engine_rst_n),` | `.rst_n         (rst_n_fc),` |
| `u_md` | `.rst_n         (engine_rst_n),` | `.rst_n         (rst_n_md),` |
| `u_sym` | `.rst_n         (engine_rst_n),` | `.rst_n         (rst_n_sym),` |
| `u_seq` | `.rst_n            (engine_rst_n),` | `.rst_n            (rst_n_seq),` |
| `u_tob` | `.rst_n               (engine_rst_n),` | `.rst_n               (rst_n_tob),` |
| `u_sig` | `.rst_n               (engine_rst_n),` | `.rst_n               (rst_n_sig),` |
| `u_feat` | `.rst_n                  (engine_rst_n),` | `.rst_n                  (rst_n_feat),` |
| `u_norm` | `.rst_n              (engine_rst_n),` | `.rst_n              (rst_n_norm),` |
| `u_ml` | `.rst_n      (engine_rst_n),` | `.rst_n      (rst_n_ml),` |
| `u_policy` | `.rst_n                (engine_rst_n),` | `.rst_n                (rst_n_policy),` |
| `u_align` | `.rst_n     (engine_rst_n),` | `.rst_n     (rst_n_align),` |
| `u_kill_sync` | `.rst_n    (engine_rst_n),` | `.rst_n    (rst_n_kill_sync),` |
| `cur_cycle` (bare `always` block, not an instantiation) | `always @(posedge gmii_rx_clk or negedge engine_rst_n) begin`<br>`        if (!engine_rst_n) cur_cycle <= 32'd0;` | `always @(posedge gmii_rx_clk or negedge rst_n_cur_cycle) begin`<br>`        if (!rst_n_cur_cycle) cur_cycle <= 32'd0;` |
| `u_risk` | `.rst_n                    (engine_rst_n),` | `.rst_n                    (rst_n_risk),` |
| `u_ob` | `.rst_n                (engine_rst_n),` | `.rst_n                (rst_n_ob),` |
| `u_csr` | `.rst_n                  (engine_rst_n),` | `.rst_n                  (rst_n_csr),` |
| `u_hist` | `.rst_n             (engine_rst_n),` | `.rst_n             (rst_n_hist),` |

Verify each replacement immediately after making it by checking the
preceding few lines actually name the module instance the table says (the
exact whitespace in each `.rst_n` line varies by instantiation — use the
surrounding `module_name u_instance (` line just above each one, visible in
`rtl/tob_top.v`, to disambiguate rather than a blind global find/replace of
`engine_rst_n` — a global replace would also incorrectly touch
`u_rst_sync`'s own declaration and `sync_out (engine_rst_n)` itself,
neither of which should change).

After this step, `engine_rst_n` itself should be referenced in exactly 2
places in `rtl/tob_top.v`: its own declaration/instantiation (`wire
engine_rst_n; sync_2ff ... .sync_out (engine_rst_n)`) and the new buffer
`always` block's own sensitivity list / `if (!engine_rst_n)` condition —
confirm with `grep -c "engine_rst_n" rtl/tob_top.v` (expect exactly the
buffer block's own references plus the original declaration, not 19+
scattered module-port references anymore).

- [ ] **Step 3: Compile-check**

```bash
iverilog -g2001 -Wall -o /tmp/lint.vvp rtl/*.v rtl/common/*.v tb/sim_models/tob_top_sim_leaves.v
```

Expected: zero warnings, zero errors, zero inferred latches (the `(* keep
= "true" *)` attribute is synthesis-only syntax that Icarus should parse
and ignore harmlessly — if it doesn't, check Icarus's attribute-comment
syntax support and adjust if genuinely needed, but don't remove the
attribute just to silence a warning).

- [ ] **Step 4: Run tests**

```bash
RUN_SIM_FAST=1 bash scripts/run_sim.sh
```

Expected: `ALL TESTS PASSED`, identical mismatch/warning counts to the
pre-Task-4 baseline (this change is designed to be cycle-exact everywhere
— any behavior difference at all means something about the buffer
replication isn't as timing-transparent as designed, and needs
investigation before proceeding, not a golden-model update).

Then run the FULL (non-fast) soak, since this touches every module's reset
and the fast suite's smaller stimulus might not exercise every reset-timing
edge case:

```bash
bash scripts/run_sim.sh
```

Expected: `ALL TESTS PASSED` including the 1,000,000-message parser soak.

- [ ] **Step 5: Re-synthesize and confirm the specific path closes durably**

```bash
make synth
```

```bash
grep -n "Slack (VIOLATED)\|Slack (MET)" -A 8 results/build/timing_summary.rpt | grep -B 8 "u_rst_sync\|rst_n_mac\|rst_n_csr\|rst_n_feat"
```

Confirm: (a) no `u_rst_sync`-sourced path is VIOLATED, (b) the specific
`u_feat/win_abs_reg[87]/CLR`-style recovery path (or whatever is now the
worst reset-recovery path — the exact destination may shift) shows a
comfortable margin, and (c) — the actual proof this task worked — the
fanout of whichever net is now worst is nowhere near 10,876/10,881 anymore
(check the netlist resource names in the path detail; each buffer's own
local fanout should be a small fraction of the original, roughly `total
async-reset registers / 19`).

- [ ] **Step 6: Commit**

```bash
git add rtl/tob_top.v
git commit -m "fix: replicate engine_rst_n into 19 per-module local reset buffers to close async-reset-fanout recovery violation durably (D54)

phys_opt_design (added in this plan's own Task 2) turned out to
structurally never fire on this path: it only optimizes paths still
VIOLATED at the point it runs, and place_design had already reached a
barely-non-negative WNS (0.239ns) before phys_opt_design started, so it
skipped all setup optimization and made zero netlist modifications --
confirmed directly in vivado.log ('No setup violation found. The netlist
was not modified.'). The prior 0.528ns pass was placement luck, not a
durable fix (the target net's fanout was still fo=10876, essentially
unchanged from fo=10881 pre-fix).

Each of the 19 module instances (and cur_cycle's own always block)
previously wired directly to engine_rst_n now gets its own local reset
buffer, independently async-reset by engine_rst_n on the same clock edge
(not a synchronous pipeline stage -- zero cycle-timing change anywhere).
(* keep = 'true' *) prevents synthesis from merging the 19 logically-
identical buffers back into one.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: Documentation — D54 entry and drift cleanup

**Files:**
- Modify: `docs/design_decisions.md` (append D54)
- Modify: `CLAUDE.md` (fix the `tb/tb_top.v` "does not exist" claim — it
  does exist, confirmed directly; this drift was already flagged once
  during the D53 whole-branch review and never fixed)

**Interfaces:** none — pure documentation, last task in this plan.

- [ ] **Step 1: Append D54 to `docs/design_decisions.md`**

Find the current last entry (`## D53 — ...`) and its final paragraph, and
insert the new entry after it, before whatever separator/section follows
(matching the exact insertion convention used for D53 after D52, and D52
after D51 — read how those insertions were done if unsure).

Write an entry (matching the established `## D54 — <one-line summary>` /
bold **Status:** / narrative-paragraphs style used by every other entry)
covering:
- Both violations' root causes (the token-bucket's chained 32-bit
  arithmetic with runtime-CSR-driven, non-foldable comparators; the reset
  synchronizer's massive fanout after its active-low-to-active-high
  inverting LUT).
- The fix actually applied to each (state what Task 3 found — whether
  Task 4 ran or not, and the final `WNS`/`WHS`).
- Explicitly reference this plan
  (`docs/superpowers/plans/2026-09-10-risk-engine-timing-closure.md`) and
  `docs/contracts/risk_engine.md` §2.3 for the full arithmetic derivation.
- Note this closes out the "Explicitly out of scope" item from D53 that
  named these exact two violations.

- [ ] **Step 2: Fix `CLAUDE.md`'s stale `tb/tb_top.v` claim**

Find the sentence claiming `tb/tb_top.v` "still does not exist" (in the
"What this repo is" paragraph) and correct it — the file exists (it's
exercised by `scripts/run_sim.sh` and was itself the subject of a prior
commit extending its soak). Verify directly (`ls tb/tb_top.v`) before
editing, and word the correction so it doesn't just flip to a different
unverifiable absolute claim — say what's actually true and how to check it
if this table drifts again (matching this file's own stated convention of
preferring "check with `ls`" over hardcoded claims where the fact changes
often).

- [ ] **Step 3: Verify no contradictions**

```bash
grep -n "D54\|token_bucket\|refill_ctr" docs/design_decisions.md CLAUDE.md docs/contracts/risk_engine.md
```

Read through and confirm nothing contradicts what Tasks 1-4 actually did
(especially: if Task 4 did NOT run, don't describe a reset-tree that
doesn't exist; if it DID run, describe it accurately).

- [ ] **Step 4: Commit**

```bash
git add docs/design_decisions.md CLAUDE.md
git commit -m "docs: D54 entry -- risk_engine token-bucket + reset-fanout timing closure

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

## Self-Review Notes

- **Spec coverage:** both violations named in D53's "explicitly out of
  scope" note are addressed — Task 1 (risk_engine), Tasks 2-4 (reset
  fanout, with Task 4 conditional on Task 3's actual measurement rather
  than assumed necessary).
- **Conditional task handled explicitly:** Task 4 is clearly marked
  conditional, with Task 3 instructed to produce an unambiguous decision
  (including a concrete, non-vague margin threshold) rather than leaving
  that judgment implicit.
- **Type/signature consistency:** `risk_engine.v`'s port list is untouched
  by Task 1 (only internal state/logic changes); `token_bucket`'s name,
  width, and external-probe visibility (`tb_risk_engine.v:224`) are
  explicitly preserved. `refill_ctr`'s rename to `refill_ctr_p1` was
  checked against every other file in the repo (`grep -rn "refill_ctr"`)
  before this plan assumed it was safe.
- **Equivalence, not redesign:** Task 1's every replacement expression is
  derived from and proven equivalent to the CURRENT code by explicit case
  analysis in the plan text itself, plus a continuous equivalence-check
  block (a direct transcription of the unmodified original expressions,
  run alongside every existing directed test plus two new boundary-value
  blocks) as an independent, mechanical second check — not merely asserted.
