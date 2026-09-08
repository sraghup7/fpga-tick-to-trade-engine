## Contract: fix `risk_engine.v`'s D34 timing violation (patches the ALREADY-CORRECT D28 fix's own module)

### Status: ready to hand off. `risk_engine_align_fix.md` (D28) is done, correct, and independently verified -- this is a SEPARATE, NEW problem that only appeared once D28 landed alongside `feature_extractor_timing_patch.md` (D26/D27's v2) in the SAME synthesis run.

Real Vivado synthesis+place+route of the combined design (D28's `risk_engine.v`
fix + D26/D27 v2's `feature_extractor.v` fix, both independently verified
correct on their own) measured **post-route WNS = -2.282 ns** -- a huge
improvement over the pre-v2 baseline (-8.277 ns, D27), but still a real
violation. `feature_extractor.v` is now completely gone from the critical
path (confirmed absent from the top-10 violated paths entirely, not merely
improved). **The new worst path is entirely inside `risk_engine.v`**:

```
u_risk/u_gate_align/data_pipe_reg[4][98]/C -> u_risk/position_r_reg[16]/CE
Slack: -2.282 ns.  Logic Levels: 21 (CARRY4=12 LUT1=1 LUT2=2 LUT3=2 LUT6=4)
Data Path Delay: 10.063 ns (logic 4.923 ns, route 5.140 ns)
```

**Root cause, traced from the actual routed path, not guessed:** D28's
internal `u_gate_align` delay line's LAST register stage (holding the
snapshotted `bid_price`, per D28's bit layout) feeds DIRECTLY, with no
register in between, into `risk_engine.v`'s full nine-gate `reject_reason`
priority mux and the gate 0x04 band-diff arithmetic. That combinational cone
used to be fed by cheap top-level ports (`bid_price`/`ask_price` direct
wires); it is now fed by a register bank that placement put a meaningful
routing distance away, driving a comparatively large piece of logic (a
129-bit-wide delay line's output feeding a 9-way priority-mux). Neither
`feature_extractor_timing_patch.md` nor `risk_engine_align_fix.md` could have
caught this in isolation -- each contract's own acceptance criteria correctly
scoped Vivado verification to its own module's behavior, and neither
contract's author had the OTHER contract's finished state in front of them
(see `docs/design_decisions.md` D34 for the full writeup of why this is
structural, not an oversight in either contract).

**The fix, in one sentence:** split `risk_engine.v`'s nine-gate evaluation
across two pipeline stages -- evaluate all nine gates combinationally (same
logic as today, unchanged), register the nine resulting booleans plus the
order fields, then compute the `reject_reason` priority mux and the accept
decision from the REGISTERED gate vector one cycle later. This is the same
shape as D26/D27's `feature_extractor.v` fix (compute the expensive part,
register it, combine cheaply next cycle), applied to a different module.

---

### S0. The real, unavoidable tradeoff this introduces (read before objecting to it, and before implementing around it)

`risk_engine.v`'s own `sig_valid`-to-`order_valid` latency goes from 1 cycle
to 2. This has one genuine consequence you must NOT try to engineer away:
gate 0x03's position ledger (`position_r`) is only updated 2 cycles after
`sig_valid` now, not 1 -- so two ALIGNED signals for the SAME slot need to
arrive **at least 2 cycles apart** (not 1, as today) for the second one's
gate 0x03 check to see the first one's position update. This is real and
worth stating plainly rather than hiding: it is the same class of tradeoff
`docs/design_decisions.md` D28 itself already documented for `NFR-5`'s "one
message per cycle" claim (true architecturally, false under maximally dense
traffic, fine in practice at `NFR-4`'s 16-cycle nominal spacing). Do not
attempt to preserve the old same-cycle read/write relationship for gate
0x03 by decoupling it from the other eight gates -- `accepted_c` (which
gates the position write) fundamentally requires knowing ALL nine gates'
results, including the two slow ones (band, stale), so the write cannot
happen before the slow gates are known without producing a wrong answer.
There is no version of this fix that avoids widening this window; only
document it and add a test that shows the widened window is what it is
(S4).

---

### S1. Current (baseline) file you are patching

`rtl/risk_engine.v` at its current state (D28's fix already landed and
verified -- `sig_valid_raw`/`sig_slot_raw` ports, the `u_gate_align` delay
line, `a_bp`/`a_ap`/`a_crossed`/`a_pend_prev`/`a_pend_msg` all already exist
and are already correct; do not touch any of that). Read the whole file
before starting. The nine `gate_*_fired_c` wire definitions (lines ~254-279)
are UNCHANGED by this contract -- same logic, same inputs, computed at the
same cycle as today. Only what happens AFTER those nine booleans exist
changes.

---

### S2. The new design

#### S2.1 New stage-2 registers

Add, near the existing state registers:

```verilog
// ---- D34: stage-2 pipeline registers. All nine gates are still evaluated
//      together, at sig_valid's own cycle (FR-42's "single cycle" spirit
//      preserved -- this is still one message's gate vector, computed
//      together; it now takes two clock cycles to reach a decision, the
//      same tradeoff D26/D27 already made for feature_extractor.v's F0-F7).
//      Registering the nine booleans here, instead of continuing straight
//      into the priority mux, is what actually fixes D34 -- the mux and
//      the accept decision move to stage 2, cheap and shallow. ----
reg        r1_valid;
reg [1:0]  r1_slot;
reg [7:0]  r1_side;
reg [31:0] r1_price;
reg [31:0] r1_qty;           // UNREDUCED sig_qty (D18 reject-path reporting)
reg [31:0] r1_reduced_qty;
reg [31:0] r1_next_pos;      // prospective post-order position (D16)
reg        r1_gate_kill, r1_gate_size, r1_gate_position, r1_gate_band,
           r1_gate_stale, r1_gate_seqgap, r1_gate_crossed, r1_gate_throttle,
           r1_gate_ml;
```

#### S2.2 Stage 2 (new combinational block): priority mux + accept decision

```verilog
// ---- D34: reject_reason/accepted_c now computed from the REGISTERED gate
//      vector (r1_gate_*), one cycle after the gates themselves. This is
//      the only place reject_reason_c/accepted_c are computed -- delete the
//      old versions that read gate_*_fired_c directly. ----
wire [7:0] reject_reason_c =
    r1_gate_kill     ? 8'd1 :
    r1_gate_size     ? 8'd2 :
    r1_gate_position ? 8'd3 :
    r1_gate_band     ? 8'd4 :
    r1_gate_stale    ? 8'd5 :
    r1_gate_seqgap   ? 8'd6 :
    r1_gate_crossed  ? 8'd7 :
    r1_gate_throttle ? 8'd8 :
    r1_gate_ml       ? 8'd9 : 8'd0;
wire accepted_c = r1_valid & (reject_reason_c == 8'd0);
```

`reduced_qty_c`, `final_signed_qty`, `next_pos` (existing wires, computed
from LIVE `sig_qty`/`sig_side`/`sig_slot`/`position_r`, unchanged) stay
exactly as they are -- they still belong to stage 1, feeding the new
`r1_reduced_qty`/`r1_next_pos` registers below, not stage 2.

#### S2.3 Register stage 1 -> stage 2 (new always block, or fold into an existing one -- your choice, but keep it unconditional every cycle, not gated on `sig_valid`, matching how `p1_*` works in `feature_extractor.v`)

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r1_valid <= 1'b0;
        r1_slot  <= 2'd0;
        r1_side  <= 8'd0;
        r1_price <= 32'd0;
        r1_qty   <= 32'd0;
        r1_reduced_qty <= 32'd0;
        r1_next_pos    <= 32'd0;
        r1_gate_kill <= 1'b0; r1_gate_size <= 1'b0; r1_gate_position <= 1'b0;
        r1_gate_band <= 1'b0; r1_gate_stale <= 1'b0; r1_gate_seqgap <= 1'b0;
        r1_gate_crossed <= 1'b0; r1_gate_throttle <= 1'b0; r1_gate_ml <= 1'b0;
    end else begin
        r1_valid <= sig_valid;
        r1_slot  <= sig_slot;
        r1_side  <= sig_side;
        r1_price <= sig_price;
        r1_qty   <= sig_qty;
        r1_reduced_qty <= reduced_qty_c;
        r1_next_pos    <= next_pos[31:0];
        r1_gate_kill     <= gate_kill_fired_c;
        r1_gate_size     <= gate_size_fired_c;
        r1_gate_position <= gate_position_fired_c;
        r1_gate_band     <= gate_band_fired_c;
        r1_gate_stale    <= gate_stale_fired_c;
        r1_gate_seqgap   <= gate_seqgap_fired_c;
        r1_gate_crossed  <= gate_crossed_fired_c;
        r1_gate_throttle <= gate_throttle_fired_c;
        r1_gate_ml       <= gate_ml_fired_c;
    end
end
```

#### S2.4 Token bucket and position ledger: same structure, now driven by the NEW (stage-2) `accepted_c`

The token-bucket always-block's *structure* does not change at all -- it
already runs unconditionally every cycle with `accepted_c` only affecting
the extra decrement. Just make sure it references the new `accepted_c`
(S2.2), which it will automatically once the old `accepted_c` definition is
deleted and only the new one exists.

The position-ledger always-block changes which slot/value it writes (now
`r1_slot`/`r1_next_pos`, registered stage-2 values, not live `sig_slot`/
`next_pos`):

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        position_r <= {NUM_SYMBOLS*32{1'b0}};
    end else if (accepted_c) begin
        position_r[r1_slot*32 +: 32] <= r1_next_pos;
    end
end
```

#### S2.5 Order decision + gate pulses: now keyed on `r1_valid`, sourced from stage-2 registers

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        order_valid   <= 1'b0;
        order_slot    <= 2'd0;
        order_side    <= 8'd0;
        order_price   <= 32'd0;
        order_qty     <= 32'd0;
        reject_reason <= 8'd0;
        gate_kill_fired     <= 1'b0;
        gate_size_fired     <= 1'b0;
        gate_position_fired <= 1'b0;
        gate_band_fired     <= 1'b0;
        gate_stale_fired    <= 1'b0;
        gate_seqgap_fired   <= 1'b0;
        gate_crossed_fired  <= 1'b0;
        gate_throttle_fired <= 1'b0;
        gate_ml_fired       <= 1'b0;
    end else if (r1_valid) begin
        order_valid   <= accepted_c;
        order_slot    <= r1_slot;
        order_side    <= r1_side;
        order_price   <= r1_price;
        order_qty     <= accepted_c ? r1_reduced_qty : r1_qty;   // D18, unchanged rule
        reject_reason <= reject_reason_c;
        gate_kill_fired     <= r1_gate_kill;
        gate_size_fired     <= r1_gate_size;
        gate_position_fired <= r1_gate_position;
        gate_band_fired     <= r1_gate_band;
        gate_stale_fired    <= r1_gate_stale;
        gate_seqgap_fired   <= r1_gate_seqgap;
        gate_crossed_fired  <= r1_gate_crossed;
        gate_throttle_fired <= r1_gate_throttle;
        gate_ml_fired       <= r1_gate_ml;
    end else begin
        order_valid   <= 1'b0;
        reject_reason <= 8'd0;
        gate_kill_fired     <= 1'b0;
        gate_size_fired     <= 1'b0;
        gate_position_fired <= 1'b0;
        gate_band_fired     <= 1'b0;
        gate_stale_fired    <= 1'b0;
        gate_seqgap_fired   <= 1'b0;
        gate_crossed_fired  <= 1'b0;
        gate_throttle_fired <= 1'b0;
        gate_ml_fired       <= 1'b0;
    end
end
```

`order_valid` now pulses **2 cycles** after `sig_valid` (was 1).

#### S2.6 Header comment

Add a paragraph (after the existing D28 paragraph) describing this
mechanism: the nine gates are still evaluated together as one vector, but
combining them into a single accept/reject decision now takes one extra
cycle so the combinational path from `u_gate_align`'s output doesn't have to
also traverse the full priority mux in the same cycle. State the S0 tradeoff
explicitly in this comment, not just in the contract -- the next person
reading this file needs to know gate 0x03 now needs 2-cycle same-slot
spacing, not 1, without having to find this contract first.

---

### S3. Ripple: `order_builder.v`'s `TRIGGER_DELAY`

`risk_engine.v`'s own `sig_valid`-to-`order_valid` latency changes from 1
cycle to 2. `tob_top.v` instantiates `order_builder` with:

```verilog
order_builder #(.TRIGGER_DELAY (2 + ALIGN_DEPTH))   // signal_engine + risk_engine's own
                                                     // 1-cycle registers, plus S6's
                                                     // alignment delay (docs/design_...
```

The `2` in that formula is documented as "signal_engine + risk_engine's own
1-cycle registers" -- 1 cycle each. With risk_engine now taking 2 cycles,
this must become:

```verilog
order_builder #(.TRIGGER_DELAY (3 + ALIGN_DEPTH))   // signal_engine (1) + risk_engine's
                                                     // now-2-cycle gate pipeline (D34),
                                                     // plus S6's alignment delay
```

This is a `tob_top.v`-only change (one line + comment); `order_builder.v`
itself is parametric and needs no edit (same as D25's own resolution). This
is exactly the same class of ripple D25 already went through once for this
same parameter -- re-read `docs/design_decisions.md` D25 if the reasoning
here is unclear.

---

### S4. Testbench ripple

- **`tb/tb_risk_engine.v`**: every existing check currently waits for the
  decision 1 cycle after the aligned `sig_valid`; it now needs to wait 2.
  Concretely, wherever the testbench currently does something like "advance
  one cycle past the aligned pulse, then sample `c_*`", it now needs to
  advance one MORE cycle first. Given this file already has a
  `wait_sig_sample`-style helper (per D28's own rework) keyed off detecting
  when the aligned pulse has fully passed, update that helper's cycle count
  by one rather than re-deriving the whole waiting scheme from scratch.
  **Add a new directed test proving S0's tradeoff explicitly**: two aligned
  signals on the SAME slot exactly 1 cycle apart (not 2) should now show the
  SECOND one's gate 0x03 check missing the first one's position update
  (document this as expected, not a bug -- matching D28's own "NFR-5 vs.
  NFR-4" honesty) -- and a second case with the signals 2 cycles apart
  showing gate 0x03 correctly sees the update. This is the regression that
  proves the documented tradeoff is exactly what shipped, not something
  worse.
- **`tb/tb_tob_top.v`**: re-run as-is first; then re-check with the updated
  `TRIGGER_DELAY` -- `order_valid`'s total latency from `book_upd_valid`
  grows by 1 cycle, so any hardcoded expected `trigger_seq`/`latency_cyc`
  values in existing T-cases need re-deriving (same mechanical exercise as
  D25's own fix), and `adv()` timeout windows should be re-checked the same
  way D26/D27's v2 already asked for.
- **`tb/tb_order_builder.v`** / **`tb/tb_order_builder_delay.v`**: these test
  `order_builder.v` standalone with an explicit `TRIGGER_DELAY` parameter --
  no change needed unless they assert something about the *value* `2 +
  ALIGN_DEPTH` specifically rather than just parameterizing over it.

---

### S5. Acceptance criteria

**Yours to verify (iverilog):**

- `rtl/risk_engine.v` compiles under `iverilog -g2001 -Wall`, no new
  warnings, no inferred latches (the pre-existing, separately-tracked
  `token_bucket_reg` latches from D28/D29 are NOT this contract's problem --
  don't try to fix them here, don't let their presence block you either).
- `tb_risk_engine` passes, including the new S0-tradeoff regression (S4).
- `tb_tob_top` passes with the updated `TRIGGER_DELAY`.
- Full regression (`bash scripts/run_sim.sh`, not `RUN_SIM_FAST=1`) passes.
- `git diff` on every file not listed above (in particular `signal_engine.v`,
  `tob_engine.v`, `feature_extractor.v`, `feature_normalizer.v`,
  `ml_classifier_wrap.v`, `ml_policy.v`, `csr_block.v`) is empty except
  `order_builder.v`'s instantiation line in `tob_top.v` (S3).
- In your report, explicitly confirm you did NOT try to preserve the old
  1-cycle same-slot gate-0x03 spacing by decoupling it from the other eight
  gates (S0) -- state plainly that the new minimum safe same-slot spacing
  for position-ledger correctness is 2 cycles, not 1.

**Mine to verify (Vivado):**

- Fresh `synth_design` -> `opt_design` -> `place_design` -> `route_design`
  on `tob_top` at `xc7a35tfgg484-2`, 125 MHz.
- Post-route WNS >= 0 ns.
- Confirm the D34 path (`u_gate_align` -> `reject_reason`/`position_r`) is
  no longer the worst offender. If a NEW worst path appears inside stage 1
  (i.e., a single gate's OWN computation -- most likely `gate_band_fired_c`'s
  `midsum`/`band_diff` chain, which has the same "two chained arithmetic
  ops" shape that made `feature_extractor.v`'s F1 need its own two-way split
  -- is still too deep on its own), I will split that gate's computation the
  same way (register the intermediate sum, compute the compare next cycle)
  rather than asking for a guess a second time. Say so explicitly in this
  contract's own follow-up if that's what the numbers show.

---

### Explicitly out of scope

- The pre-existing `u_risk/token_bucket_reg` latch issue (D28/D29's other
  open finding) -- unrelated root cause, not addressed here.
- `ml_policy.v`'s identical D28-class bug (flagged in D28, still not fixed)
  -- different module, different contract.
- NFR-7's utilization gap (D32) -- unrelated.
- Reducing `WINDOW`, changing F0-F7 semantics, or touching
  `feature_extractor.v` in any way -- that contract is done and verified;
  this one is scoped to `risk_engine.v` and `tob_top.v`'s `order_builder`
  instantiation line only.
