## Contract: `feature_extractor.v` timing-closure fix, v2 (supersedes v1)

### Status: v1 FAILED real Vivado verification. Read this section before touching any code.

The first version of this contract (implemented, and previously verified by you
via `iverilog` -- all testbenches passed) split the F5/F7 window's 16-term
adder tree into two half-window partial sums (`f5cnt_lo/hi`, `f7acc_lo/hi`),
registered one cycle after `book_upd_valid`, combined one cycle later. It
compiled clean and every simulation passed. **It did not close timing on
real hardware.** Independent Vivado synthesis+place+route (my job, per the
v1 contract's own acceptance-criteria split -- you have no Vivado access)
measured **post-route WNS = -8.277 ns** against the required 0 ns at 125 MHz
-- barely better than the pre-fix baseline of -9.127 ns, and still 36 logic
levels on the critical path.

**Root cause of the v1 shortfall** (found by reading Vivado's actual routed
timing report, not guessed): the 16-vs-8-term adder tree was never the
dominant cost. The real cost is computing *this event's own* F1 (mid-price
delta) and its absolute value (`c_absf1`) -- two chained 33-bit additions
(`midsum`, `pmsum`) followed by a saturating subtraction and an abs, all pure
combinational logic with no register in between. v1 registered the *result*
of that chain one cycle before finalizing F5/F7, but the F1/abs chain itself
still ran start-to-finish inside a single clock edge, unchanged from before
the patch, because entry `j==0` of the window (this event's own contribution)
was still combined into the accumulator in the *same* cycle it was computed.
Splitting the historical window's width did nothing to shorten that.
`e_abs = book ? c_absf1 : 32'd0;` at `rtl/feature_extractor.v` (pre-patch
baseline, the file you're about to edit) is exactly where the two costs met
in one cycle.

**This v2 design fixes the actual bottleneck two ways, not one:**

1. **The F1 computation itself is now split across two pipeline stages**
   (compute the two 33-bit sums one cycle, do the saturating subtract + abs
   the next), instead of one cycle doing both.
2. **F5/F7 switch from "recompute the whole window every event" to an
   incremental running accumulator** (add the newest entry, subtract the one
   falling out of the window) -- replacing an up-to-32-term adder tree with a
   single add/subtract per event. This is architecturally the more obvious
   design and was originally rejected in `docs/design_decisions.md` D13 for
   a real reason (**read that reasoning below before implementing** -- it is
   not optional context, it is the one way to get this wrong silently).

Together, these give three pipeline stages of roughly equal, comfortably
small depth, instead of one 36-level stage. `feat_valid` now pulses **three**
cycles after `book_upd_valid`, not one (pre-D26) or two (v1). This ripples
into `tob_top.v`'s `ALIGN_DEPTH` and four testbenches -- all spelled out
below.

I will independently re-verify this entire design (iverilog first, then real
Vivado synthesis+place+route) exactly as I did for v1. If it *also* fails
post-route timing, I will not ask you to guess again -- I'll trace the new
critical path myself and write a v3 with the real numbers in hand, same as
this one.

---

### S0. Why the incremental accumulator is safe here (read before coding)

D13's original objection: *"a sliding-window sum's natural efficient
implementation is incremental -- add the newest value, subtract the value
falling out of the window -- which breaks under per-cycle saturation: once a
contribution has been clamped on the way in, its original value is gone and
can't be correctly subtracted back out later."*

That objection is about clamping a *stored, per-entry* value before it goes
into the window or into a running total. It does not apply here as long as
one rule is followed absolutely:

> **Every value added to or subtracted from the running accumulator, and
> every value stored in the window array, is the true, unsaturated
> per-event magnitude. Saturation happens exactly once, at the very last
> step, when producing the 32-bit `feat_f7_volatility` output register --
> and that saturated value is never written back into the accumulator or
> the window array.**

This is in fact already how F7 has always worked in this codebase: `c_absf1`
(this event's own `|F1|`) is never clamped when computed or when pushed into
`win_abs` -- only the final 64-bit-to-32-bit reduction is saturating. v2 just
stops recomputing the sum of `win_abs` from scratch every cycle and instead
maintains it incrementally, without changing what gets stored anywhere. If
you find yourself writing code that stores or subtracts `feat_f7_volatility`
(the clamped output) instead of the raw per-event magnitude, stop -- that is
exactly the D13 bug, reintroduced.

F5 (a plain popcount of `is_update` bits, values 0 or 1) has no saturation
behavior at all, so the same treatment for it is unconditionally safe.

---

### S1. Current (baseline) file you are patching

`rtl/feature_extractor.v` at its last-committed state (commit `dadde20` and
unchanged since -- **you do not need to undo anything**; the v1 patch was
never committed, so the file in front of you does not contain any v1 code).
Read the whole file before starting; its header comments (D13 window
semantics, D23 `next_*` port rationale) are still entirely accurate and
should be preserved, only the timing/pipelining sections need rewriting.

Key facts from that file you must preserve exactly:
- `book = msg_applied & book_upd_valid` (QUOTE or CLEAR only).
- `clev = book & (msg_type == MSG_CLEAR)`.
- `sidx = applied_slot`.
- The window pushes on **every** `msg_applied` cycle (any `msg_type`), not
  only book-modifying ones (D13) -- TRADE/HEARTBEAT push `(is_update=0,
  abs=0)`. This means the retirement pipeline you're adding must run for
  every `msg_applied` event, not just `book` ones, or interleaved TRADE
  events would retire into the window out of arrival order relative to a
  book event still in flight. See S2.4.
- `prev_bp/prev_bq/prev_ap/prev_aq/last_trade_dir/seen_first` update
  **immediately**, one cycle after `msg_applied`/`book`, exactly as today --
  **do not** move these into the new multi-stage pipeline. They only ever
  depend on `sbp/sbq/sap/saq` (a direct, same-cycle copy of the `next_*`
  ports -- cheap, no chain), so they have no timing problem and must keep
  updating at the same 1-cycle latency so back-to-back events on the same
  slot see correctly-updated history. This is unchanged from baseline; call
  it out in your report so I can confirm you didn't touch it.
- `sat_sub` function: unchanged, reused as-is.
- FR-23 (master spec) permits add/subtract/shift/compare only, no
  multiply/divide -- the incremental accumulator's add-one/subtract-one is
  fully legal; this was already re-checked, no need to re-derive it.

---

### S2. The new design

#### S2.1 Three combinational stages, two register boundaries before the output register

```
cycle T   (book_upd_valid may be high)         : stage 0 -- cheap features +
                                                   the two wide 33-bit sums
  |  register edge (T -> T+1)
cycle T+1                                       : stage 1 -- F1 = sat_sub of
                                                   the two REGISTERED sums,
                                                   then |F1|
  |  register edge (T+1 -> T+2)
cycle T+2                                       : stage 2 -- incremental
                                                   accumulate: read the
                                                   window's current oldest
                                                   entry (a register read,
                                                   cheap), combine with this
                                                   event's now-fully-computed
                                                   contribution
  |  register edge (T+2 -> T+3) -- feat_valid pulses here, window/accumulator
     state updates here
```

#### S2.2 Stage 0 (combinational, replaces the current single `always @(*)` block's first half)

Compute, exactly as today, from `next_bid_price/next_bid_qty/next_ask_price/
next_ask_qty` and the per-slot `prev_*`/`seen_first` state:

```verilog
wire book = msg_applied & book_upd_valid;
wire clev = book & (msg_type == MSG_CLEAR);
wire [1:0] sidx = applied_slot;

reg [31:0] sbp, sbq, sap, saq;
reg        first_ev;
reg [32:0] midsum, pmsum;
reg [31:0] c_f0, c_f2, c_f3, c_f4, c_f6;
always @(*) begin
    sbp = next_bid_price;
    sbq = next_bid_qty;
    sap = next_ask_price;
    saq = next_ask_qty;

    first_ev = clev | ~seen_first[sidx];

    midsum = {1'b0, sbp} + {1'b0, sap};
    pmsum  = {1'b0, prev_bp[sidx*32 +: 32]} + {1'b0, prev_ap[sidx*32 +: 32]};

    c_f0 = (sap >= sbp) ? (sap - sbp) : 32'd0;
    c_f2 = sat_sub(sbq, saq);
    c_f3 = first_ev ? 32'd0 : sat_sub(sbq, prev_bq[sidx*32 +: 32]);
    c_f4 = first_ev ? 32'd0 : sat_sub(saq, prev_aq[sidx*32 +: 32]);
    c_f6 = clev ? 32'd0 : last_trade_dir[sidx*32 +: 32];
end
```

Note what is deliberately **not** here any more: `c_f1`/`c_absf1` and
anything about the window. F0/F2/F3/F4/F6 are each a single subtract (or
cheaper) -- they were never the timing problem, they just have to ride along
in the pipeline so all eight features still leave the module together on one
`feat_valid` pulse.

Register at the `T -> T+1` edge into new stage-1 registers (name them
`p1_valid, p1_book, p1_clev, p1_slot, p1_first_ev, p1_midsum, p1_pmsum,
p1_f0, p1_f2, p1_f3, p1_f4, p1_f6`; `p1_valid <= msg_applied` -- this is the
"is this a real event at all" flag that must ride the *entire* pipeline so
TRADE/HEARTBEAT events still retire into the window at the same latency as
book events, see S2.4).

#### S2.3 Stage 1 (combinational, new)

```verilog
reg [31:0] c_f1, c_absf1;
always @(*) begin
    c_f1    = p1_first_ev ? 32'd0 : sat_sub(p1_midsum[32:1], p1_pmsum[32:1]);
    c_absf1 = c_f1[31] ? (32'd0 - c_f1) : c_f1;
end
```

This is now a single saturating subtraction plus an abs, operating on
*already-registered* operands -- roughly the same depth as any one of
F2/F3/F4's single subtractions, not the double-add-then-subtract chain it
used to be chained into in one cycle.

Register at `T+1 -> T+2` into stage-2 registers: `p2_valid (<= p1_valid),
p2_book (<= p1_book), p2_clev (<= p1_clev), p2_slot (<= p1_slot), p2_f0 (<=
p1_f0), p2_f1 (<= c_f1), p2_f2..p2_f4 (<= p1_f2..p1_f4), p2_f6 (<= p1_f6)`,
plus two new registers that carry this event's window contribution forward:

```verilog
p2_push_abs <= p1_book ? c_absf1 : 32'd0;   // this event's abs delta, or 0
p2_push_upd <= p1_book;                     // this event's is_update bit
```

(`p2_push_abs`/`p2_push_upd` reproduce exactly the `j==0` entry the old
`always @(*)` for-loop used to construct combinationally in the same cycle
as the window read -- the only change is that it's now a registered value
one cycle later, computed from the now-registered `c_absf1`.)

#### S2.4 Stage 2 (combinational, new) -- incremental accumulate

New per-slot state, replacing the from-scratch recompute. **Use a 40-bit
accumulator, not 64.** `|F1| <= 2^31` and `WINDOW` is at most 32 (D13's
legal set is 4/8/16/32), so the window sum can never exceed `32 * 2^31 =
2^36` -- 37 bits is exact for the worst case across every legal `WINDOW`
value, and 40 bits leaves comfortable margin while still being far
shallower than 64. **Do not hardcode a width derived from today's
`WINDOW=16` instantiation (which would only need 36 bits)** -- this module
is a reusable, parameterized block, and D13 explicitly permits `WINDOW` up
to 32; a width sized only for the current instantiation is exactly the kind
of invariant that silently breaks the next time something composed with
this module changes, which is the whole failure mode this project's own
`design_decisions.md` D27 entry is about. A 40-bit adder is roughly a third
the carry-chain depth of the 64-bit one this contract originally specified
-- worth getting right before implementation, not after:

```verilog
reg [39:0] f7_acc [0:NUM_SYMBOLS-1];   // unsaturated running sum, per slot
                                        // (40 bits: exact worst case across
                                        // WINDOW<=32 is 37 bits; margin, not
                                        // tied to today's WINDOW=16 default)
reg [5:0]  f5_cnt [0:NUM_SYMBOLS-1];   // running popcount, per slot (0..WINDOW)
```

(`win_abs`/`win_upd` stay exactly as declared today -- same packed-vector
per-slot shift window, same layout, same width. They're still needed to know
what value is falling out of the window each cycle.)

```verilog
reg [31:0] old_abs;
reg        old_upd;
reg [39:0] new_f7acc;
reg [6:0]  new_f5cnt;   // one extra bit of headroom for the intermediate sum
always @(*) begin
    old_abs = win_abs[p2_slot*WINDOW*32 + (WINDOW-1)*32 +: 32];
    old_upd = win_upd[p2_slot*WINDOW + (WINDOW-1)];

    if (p2_clev) begin
        // window reset (D13): only this event's own entry survives
        new_f7acc = {8'd0, p2_push_abs};
        new_f5cnt = {6'd0, p2_push_upd};
    end else begin
        new_f7acc = f7_acc[p2_slot] + {8'd0, p2_push_abs} - {8'd0, old_abs};
        new_f5cnt = {1'b0, f5_cnt[p2_slot]} + p2_push_upd - old_upd;
    end
end
```

`old_abs`/`old_upd` are plain register reads (the window array as it stands
*before* this cycle's shift) -- cheap, no chain. The add/subtract above is
the only arithmetic in this stage: a single 40-bit add/subtract pair, far
shallower than any adder tree (and roughly a third the carry-chain depth of
a 64-bit one -- see the width note in S2.4 above).

**Every `msg_applied` event goes through this stage, not just book events**
(`p2_valid`, threaded from `p1_valid <= msg_applied`, gates the window/
accumulator update below) -- this is what keeps window retirement order
matching true arrival order even when a TRADE/HEARTBEAT is interleaved with
a QUOTE/CLEAR that's still in flight two stages behind or ahead of it. Do
not gate the window/accumulator update on `p2_book` -- only the *feature
output* (`feat_valid` etc.) is gated on `p2_book`; the window and accumulator
must update for every retiring event regardless of type, exactly as today.

#### S2.5 Final register stage (existing `always @(posedge clk or negedge rst_n)` block)

```verilog
feat_valid <= p2_valid & p2_book;
feat_slot  <= p2_slot;
feat_f0_spread         <= p2_f0;
feat_f1_mid_delta      <= p2_f1;
feat_f2_imbalance      <= p2_f2;
feat_f3_bid_chg        <= p2_f3;
feat_f4_ask_chg        <= p2_f4;
feat_f6_last_trade_dir <= p2_f6;
feat_f5_update_rate    <= {26'd0, new_f5cnt[5:0]};
feat_f7_volatility     <= (new_f7acc[39:32] != 8'd0) ? 32'hFFFFFFFF : new_f7acc[31:0];

if (p2_valid) begin
    f7_acc[p2_slot] <= new_f7acc;
    f5_cnt[p2_slot] <= new_f5cnt[5:0];
    if (p2_clev) begin
        win_abs[p2_slot*WINDOW*32 +: WINDOW*32] <= {{(WINDOW-1)*32{1'b0}}, p2_push_abs};
        win_upd[p2_slot*WINDOW +: WINDOW]       <= {{(WINDOW-1){1'b0}}, p2_push_upd};
    end else begin
        win_abs[p2_slot*WINDOW*32 +: WINDOW*32] <= {win_abs[p2_slot*WINDOW*32 +: (WINDOW-1)*32], p2_push_abs};
        win_upd[p2_slot*WINDOW +: WINDOW]       <= {win_upd[p2_slot*WINDOW +: (WINDOW-1)], p2_push_upd};
    end
end
```

(Use temp regs for the shift RHS, same style as the current `wu_sl`/`wa_sl`,
if you prefer -- purely a style choice, either is correct.)

Reset block: add `f7_acc[i] <= 40'd0; f5_cnt[i] <= 6'd0;` for `i = 0` to
`NUM_SYMBOLS-1` (a `for` loop using an `integer`, same style as the rest of
the reset block), plus reset every new `p1_*`/`p2_*` register to its zero/
invalid state. Delete the old `f7acc`/`f5cnt`/`c_f1`/`c_f5`/`c_f7`/`c_absf1`
single-cycle for-loop entirely -- it's fully replaced.

`prev_bp/prev_bq/prev_ap/prev_aq/seen_first/last_trade_dir` updates: **copy
verbatim from the current file, unchanged, still keyed off `sbp/sbq/sap/saq`
and `book`/`clev`/`sidx` from stage 0** (not `p1_*`/`p2_*`) -- see S1's
warning about why these must not move into the new pipeline.

#### S2.6 Header comment

Update the module's top-of-file timing comment (currently describing the
pre-D26 single-cycle behavior) to describe the new 3-stage pipeline and
explicitly restate the D13-safety rule from S0 (saturate once, at the
output register, never store or feed back the saturated value). Future
readers of this file need that rule spelled out at the point where the
incremental accumulator is introduced, not just in `design_decisions.md`.

---

### S3. `tob_top.v` ripple

`feat_valid` now pulses **3** cycles after `book_upd_valid` (was 1
pre-D26, was 2 in the failed v1). The ML branch total latency becomes:
`feat_valid +3` -> `norm_valid +4` -> `ml_valid`/`z` `+5` -> `adverse_risk`
`+6`. Signal branch is still 1 cycle. Update:

```verilog
localparam ALIGN_DEPTH = 5;   // feature_extractor.v now takes 3 cycles to
                              // feat_valid (D26 v2 timing patch: F1 split
                              // across 2 stages + incremental F5/F7
                              // accumulator); ML branch is 6 cycles total,
                              // signal branch still 1
```

`order_builder`'s `TRIGGER_DELAY (2 + ALIGN_DEPTH)` instantiation does not
need a separate edit -- it already references `ALIGN_DEPTH` symbolically.

---

### S4. Testbench ripple

Same four files as v1, but each needs **two** extra idle cycles inserted
where v1's (now-irrelevant) report added one, because latency grew by 2
cycles from the pre-D26 baseline (1 -> 3), not by 1 (1 -> 2). Work from the
current, unmodified files -- do not try to reapply anything resembling v1's
diff.

- **`tb/tb_feature_extractor.v`**: in the `ev` task, after the existing
  `@(posedge clk); #1;` at the end, add **two more** `@(posedge clk); #1;`
  pairs (three total idle posedges after the drive cycle, instead of one).
  Update the file's header comment ("registered one cycle after
  book_upd_valid") to say three cycles.
- **`tb/tb_feature_tob_chain.v`**: in the `fire` task, after `P1: book
  commits, vector registers` / `#1;`, insert **two** extra
  `@(posedge clk); #1;` cycles before the existing `N1: deassert` /
  `P2: c_* captures the vector` sequence (so there are three posedges
  between the drive cycle and the capture, not one). Update the header
  comments describing "one cycle after book_upd_valid" similarly.
- **`tb/tb_ml_chain.v`**: the pipeline-timing header comment and the
  `fire`-equivalent task currently assume `feat_valid +1, norm_valid +2,
  ml_valid/z +3, adverse_risk +4`. Change to `+3/+4/+5/+6` and insert **two**
  extra `@(posedge clk); #1;` cycles before the existing `P1: norm_valid
  latches` step.
- **`tb/tb_tob_top.v`**: re-run as-is first. Its `adv(60)`-style timeout
  windows were generous enough to absorb v1's one extra cycle without
  changes; two extra cycles (5 total vs. the original 3) is a bigger delta,
  so explicitly re-check T6/T7 (the ML-gate cases) still land within
  whatever window `adv()` gives them before assuming no edit is needed. If
  a timeout needs widening, widen only the numeric argument to `adv()`, not
  the test logic itself.

---

### S5. Acceptance criteria

**Yours to verify (iverilog) -- do all of this before reporting back:**

- `rtl/feature_extractor.v` compiles under `iverilog -g2001 -Wall` with no
  new warnings.
- `tb_feature_extractor`, `tb_feature_tob_chain`, `tb_ml_chain`, `tb_tob_top`
  (all four, including T6/T7) pass.
- `sim/test_feature_golden_handcase.py` and `sim/test_ml_golden_handcase.py`
  pass **unmodified** -- the golden models describe the *functional*
  behavior (F0-F7 values), which this patch must not change at all, only
  when the vector is registered and how it's computed internally.
- Full regression (`bash scripts/run_sim.sh`, not `RUN_SIM_FAST=1`) passes,
  including the 1,000,000-message soak.
- `git diff` on every file NOT listed in S3/S4 (in particular
  `tob_engine.v`, `feature_normalizer.v`, `ml_classifier_wrap.v`,
  `ml_policy.v`, `risk_engine.v`, `csr_block.v`, `order_builder.v`) is empty.
- No inferred latches (`vivado`'s or `iverilog`'s lint, whichever you use,
  should report none -- this codebase has zero tolerance for them).
- In your report, explicitly confirm: (a) you did not move the
  `prev_*`/`seen_first`/`last_trade_dir` updates into the new pipeline, and
  (b) you never store or subtract the *saturated* `feat_f7_volatility`
  value anywhere -- only raw per-event magnitudes (S0's rule). These are
  the two easiest ways to silently reintroduce a real bug here, so call
  them out by name rather than making me go looking.

**Mine to verify (Vivado -- do not attempt, you don't have access):**

- Fresh `synth_design` -> `opt_design` -> `place_design` -> `route_design`
  on `tob_top` at `xc7a35tfgg484-2`, 125 MHz (`rx_clk`, 8 ns period).
- Post-route WNS >= 0 ns.
- Confirm the previous critical path (through `f7acc`/`s1_f7acc_lo`, or
  whatever this design's equivalent net is named) is no longer the worst
  offender, and that no *new* path introduced by the extra pipeline stage
  becomes the new worst offender at a similarly bad margin.
- Zero blackboxes, zero latches (already covered by iverilog/Vivado lint,
  re-confirmed post-synthesis).

I will report the actual measured WNS and the new worst path either way --
if it's still negative, I'll trace it exactly like I did for v1 and come
back with a v3 grounded in real numbers, not another guess.

---

### Explicitly out of scope

- The separate, tiny `mdio_ctrl.v` hold violation (`WHS = -0.002 ns`,
  unrelated clock domain) -- not touched by this contract.
- `docs/contracts/ml_integration.md`'s now-twice-stale `ALIGN_DEPTH`
  derivation text -- left as historical record, corrected via a future
  `design_decisions.md` entry, not by editing that file in place.
- Any change to `sim/feature_golden.py` -- this patch changes *when* F0-F7
  are registered and *how* F5/F7 are computed internally, never *what*
  value they produce. If your iverilog testing finds a golden-model
  mismatch, that is a sign of a real bug in the patch, not a reason to
  touch the golden model.
- Running Vivado, or reporting a WNS/slack number -- that's mine, listed
  above, because you don't have access to verify it.
- Reducing `WINDOW` itself, or otherwise changing F5/F7's functional
  definition -- this contract only changes the pipeline/implementation,
  never the spec-level behavior.
