## Contract: fix `ml_policy.v`'s stale fail-safe read (D28's own flagged "not this contract" item)

### Status: ready to hand off. Fixes a real, live bug in already-committed, already-integrated RTL — not a new feature. This runs in PARALLEL with a separate contract (`tb_top_integration.md`) and a separate Claude-side task (spec-text only) — see "Scope boundary" at the end before touching anything.

`ml_policy.v`'s own header says: *"bid_valid/ask_valid/crossed are
tob_engine.v's REGISTERED buses, read at ml_slot one cycle past the
triggering event's register commit -- safe per D23 (same reasoning as
risk_engine.v)."* This claim is **false** for the same structural reason
D28 found it false in `risk_engine.v`: it was written when the ML branch
had no alignment stage between the triggering event and where these signals
get read. Full writeup in `docs/design_decisions.md` D28 (the paragraph
titled "`ml_policy.v` has the identical bug class") — read it before
starting; this contract assumes you have, and assumes you've read D28's own
fix (`docs/contracts/risk_engine_align_fix.md`, already landed in
`rtl/risk_engine.v`) since this fix reuses its exact technique.

**What's actually broken:** `ml_policy.v` reads `bid_valid[ml_slot]`,
`ask_valid[ml_slot]`, `crossed[ml_slot]` **live**, at the cycle `ml_valid`
fires — which is 5 cycles after the triggering message's own
`book_upd_valid` (derivation in S1 below). By then, one or more intervening
messages on the same slot may have already changed that slot's
validity/crossed state. The fail-safe check
(`safe_state_c = ~bid_valid[ml_slot] | ~ask_valid[ml_slot] | crossed[ml_slot]
| seq_gap`, [ml_policy.v:81](../../rtl/ml_policy.v:81)) can therefore force
(or fail to force) `adverse_risk` based on a DIFFERENT message's book state
than the one that actually produced this `z`/`ml_slot` — the same class of
bug D28 fixed in `risk_engine.v`'s gates 0x04/0x05/0x07, just on the ML
branch instead of the signal branch.

**`seq_gap` is NOT part of this bug** — it's `seq_monitor.v`'s feed-wide
sticky bit, not per-slot/per-message data. It's supposed to reflect current
feed health, not a snapshot of any specific triggering message, so it
correctly stays live. Only `bid_valid[ml_slot]`/`ask_valid[ml_slot]`/
`crossed[ml_slot]` need the fix.

---

### S0. The fix, in one sentence

Give `ml_policy.v` its own internal snapshot + delay line — same technique
as D28's `risk_engine.v` fix — that captures `bid_valid[applied_slot]`/
`ask_valid[applied_slot]`/`crossed[applied_slot]` one cycle after the
triggering message's `book_upd_valid` (exactly when D23 guarantees they're
correct for that message), then carries the 3-bit snapshot forward so it
lands already time-correct on the same cycle `ml_valid` actually fires.

---

### S1. Deriving the exact delay — read this before writing any code, the number is not obvious and reusing the wrong existing constant will silently reintroduce a variant of this same bug

Call the triggering message's own cycle `T` (when `book_upd_valid`/
`applied_slot` are valid for it, from `tob_engine.v` — both already
top-level wires in `tob_top.v`, already consumed by `u_feat`). Trace the ML
branch's latency cycle by cycle (each module below has exactly one clocked
`always` block — confirmed by grep before writing this contract, not
assumed):

| Cycle | Event |
| :-- | :-- |
| `T` | `book_upd_valid` high for the triggering message |
| `T+1` | `feature_extractor.v`'s book state for this message is committed (D23) — the correct capture cycle for per-slot data, same reasoning as D28 |
| `T+3` | `feat_valid` fires (`feature_extractor.v`'s own documented 3-cycle pipeline, D26/D27 v2) |
| `T+4` | `norm_valid` fires (`feature_normalizer.v`: exactly one clocked always block) |
| `T+5` | `ml_valid` fires (`ml_classifier_wrap.v`: exactly one clocked always block) — **this is the cycle `ml_policy.v`'s own always block reads `bid_valid[ml_slot]`/etc, right now, live and wrong** |
| `T+6` | `adverse_risk` commits (`ml_policy.v`'s own one clocked always block) — matches `tob_top.v`'s own comment "ML branch is 6 cycles total" |

The snapshot must be **captured** at `T+1` (per D23, same as D28) and must
**arrive** at `T+5` (when `ml_valid` fires and the always block actually
reads it). That's a delay of **`T+5 − T+1 = 4` cycles**.

**Do not reuse `tob_top.v`'s `ALIGN_DEPTH` for this.** It is currently also
`4`, but that is a coincidence, not a structural identity — `ALIGN_DEPTH`
is defined as `ML_branch_total(6) − signal_branch_own_latency(2)`, a
completely different relationship involving `signal_engine.v`'s own latency
(a different branch entirely, currently 2 cycles post-D40, previously 1
pre-D40). This fix's `4` comes from `feature_extractor`+`feature_normalizer`
+`ml_classifier_wrap`'s combined depth, and has nothing to do with
`signal_engine.v`. If a future change alters either number independently
(e.g. `signal_engine.v` needs a third pipeline stage some day, or
`feature_normalizer.v` gains a stage), `ALIGN_DEPTH` and this module's own
correct delay will diverge, and wiring them together would silently break
in a way nothing catches until the next audit. **Give this its own
parameter, independently derived, even though it numerically equals
`ALIGN_DEPTH` today.**

---

### S2. The change (`rtl/ml_policy.v`)

#### S2.1 New parameter and ports

```verilog
module ml_policy #(
    parameter integer NUM_SYMBOLS = 4,
    // Cycles from this message's own book_upd_valid to when ml_valid fires
    // for it, MINUS the one cycle already spent capturing the snapshot at
    // T+1 -- see docs/contracts/ml_policy_align_fix.md S1 for the full
    // derivation (currently 4: feature_extractor's 3 + feature_normalizer's
    // 1 + ml_classifier_wrap's 1, minus the T+1 capture offset).
    // DELIBERATELY NOT tied to tob_top.v's ALIGN_DEPTH -- that parameter
    // derives from a different relationship (this branch's total latency
    // minus signal_engine.v's own latency) and only coincides with this
    // value today; see S1.
    parameter integer SNAPSHOT_DEPTH = 4
) (
    input  wire        clk,
    input  wire        rst_n,

    // NEW: the triggering message's own book_upd_valid/applied_slot, from
    // tob_engine.v -- already top-level wires in tob_top.v (u_feat already
    // consumes both). Used ONLY to time the internal snapshot below; never
    // used to gate adverse_risk directly.
    input  wire        book_upd_valid,
    input  wire [1:0]  applied_slot,

    // from ml_classifier_wrap.v
    input  wire         ml_valid,
    input  wire [1:0]   ml_slot,
    input  wire signed [31:0] z,

    // fail-safe inputs -- tob_engine.v's REGISTERED buses. bid_valid/
    // ask_valid/crossed are now consumed via the internal snapshot below,
    // NOT read live at ml_slot -- see S2.2. seq_gap stays live (feed-wide
    // sticky state, not per-message data -- see file header, unaffected by
    // this fix).
    input  wire [NUM_SYMBOLS-1:0] bid_valid,
    input  wire [NUM_SYMBOLS-1:0] ask_valid,
    input  wire [NUM_SYMBOLS-1:0] crossed,
    input  wire                    seq_gap,
    ...
```

Everything else in the port list is unchanged.

#### S2.2 The internal snapshot + delay line

Add, before the existing `safe_state_c` wire:

```verilog
// ---- D28-class fix: snapshot this message's per-slot fail-safe inputs one
//      cycle after ITS OWN book_upd_valid (T+1, exactly when D23 guarantees
//      tob_engine.v's registered bid_valid/ask_valid/crossed are correct
//      for this specific message), then carry the snapshot forward so it
//      arrives already time-correct on the cycle ml_valid actually fires
//      for this same message (docs/contracts/ml_policy_align_fix.md S1).
//      seq_gap is deliberately excluded -- feed-wide sticky state, not
//      per-message data, correctly read live below. ----
reg        raw_d1_valid;
reg [1:0]  raw_d1_slot;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        raw_d1_valid <= 1'b0;
        raw_d1_slot  <= 2'd0;
    end else begin
        raw_d1_valid <= book_upd_valid;
        raw_d1_slot  <= applied_slot;
    end
end

wire [2:0] fs_snap_in = {bid_valid[raw_d1_slot], ask_valid[raw_d1_slot],
                          crossed[raw_d1_slot]};
wire [2:0] fs_snap_out;
wire       fs_snap_out_valid;   // must coincide with ml_valid every cycle --
                                 // see S2.3's consistency note

delay_line #(
    .WIDTH (3),
    .DEPTH (SNAPSHOT_DEPTH)
) u_fs_align (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (raw_d1_valid),
    .in_data   (fs_snap_in),
    .out_valid (fs_snap_out_valid),
    .out_data  (fs_snap_out)
);

wire a_bid_valid = fs_snap_out[2];
wire a_ask_valid = fs_snap_out[1];
wire a_crossed   = fs_snap_out[0];
```

(`rtl/common/delay_line.v` already exists — used by `order_builder.v`,
`tob_top.v`'s `u_align`, and `risk_engine.v`'s own D28 fix. Reuse it as-is;
do not write a new delay mechanism.)

#### S2.3 Rewire `safe_state_c`

```verilog
wire safe_state_c = ~a_bid_valid | ~a_ask_valid | a_crossed | seq_gap;
// was: ~bid_valid[ml_slot] | ~ask_valid[ml_slot] | crossed[ml_slot] | seq_gap
```

**Consistency note, important (same as D28's own contract):**
`fs_snap_out_valid` must be high on exactly the same cycles `ml_valid` is
high — both trace back to `raw_d1_valid` (itself `book_upd_valid` delayed
one cycle) delayed by `SNAPSHOT_DEPTH`, and by S1's derivation this should
exactly coincide with `ml_valid`'s own arrival. **Do not rely on
`fs_snap_out_valid` for anything at runtime** — `ml_valid` is still what
gates the `always` block, unchanged — but the testbench in S4 must directly
verify the two coincide, so a future latency change anywhere in the
`feature_extractor`→`feature_normalizer`→`ml_classifier_wrap` chain is
caught by simulation immediately, not discovered on a fourth audit.

#### S2.4 Header comment

Rewrite the paragraph currently claiming "safe per D23 (same reasoning as
risk_engine.v)" — that reasoning was already stale before this fix (it's
exactly what made this a bug). Describe the new snapshot mechanism, cite
S1's derivation for why the delay is `4` today and why it is its own
parameter rather than reusing `ALIGN_DEPTH`. Reference D28's original
flag and this contract.

---

### S3. `tob_top.v` ripple

`u_policy`'s instantiation needs two new port connections — both already
exist as top-level wires (`u_feat` already consumes both):

```verilog
ml_policy u_policy (
    .clk                  (gmii_rx_clk),
    .rst_n                (engine_rst_n),
    .book_upd_valid       (book_upd_valid),   // NEW -- already a top-level wire
    .applied_slot         (applied_slot),     // NEW -- already a top-level wire
    .ml_valid             (ml_valid),
    .ml_slot              (ml_slot),
    .z                    (ml_z),
    .bid_valid            (bid_valid),
    .ask_valid            (ask_valid),
    .crossed              (crossed),
    .seq_gap              (seq_gap),
    ...
```

`SNAPSHOT_DEPTH` is not overridden at instantiation — the module's own
default (`4`, S1's derivation) is correct for the current design. **No
other `tob_top.v` change** — do not touch `ALIGN_DEPTH`, the signal-branch
`u_align` instance, or anything in `risk_engine.v`.

---

### S4. Testbench changes

#### S4.1 `tb/tb_ml_policy.v` — this is the important one

The existing testbench presumably drives `ml_valid`/`ml_slot`/`z` directly
with no concept of a separate "triggering event" upstream of it, since
`ml_policy.v` didn't need one before. It needs real rework:

- Instantiate the DUT with a **non-trivial `SNAPSHOT_DEPTH`**, e.g. 3 —
  something small but clearly more than 1, and **deliberately different
  from `tob_top.v`'s current `ALIGN_DEPTH` (4)** so a mistaken
  `SNAPSHOT_DEPTH`-reuses-`ALIGN_DEPTH` wiring bug cannot pass by
  coincidence (S1's warning).
- Every existing directed test drives `book_upd_valid`/`applied_slot` (a
  new stimulus this testbench didn't need before) for the triggering
  event, then drives `bid_valid`/`ask_valid`/`crossed` to whatever state
  should be captured, then drives `ml_valid`/`ml_slot`/`z`
  **`SNAPSHOT_DEPTH + 1` cycles after `book_upd_valid`** (the `+1` is the
  `T+1` capture offset from S1 — work through this arithmetic carefully
  per test case, don't assume the existing timing offsets still apply).
- **New test, the one that actually proves the fix**: fire a triggering
  `book_upd_valid`/`applied_slot` for slot A with a known-valid,
  known-non-crossed book state (so `safe_state_c` should read 0 for this
  message), then **before** `ml_valid`/`ml_slot` for it arrives (during the
  `SNAPSHOT_DEPTH`-cycle gap), drive `bid_valid`/`ask_valid`/`crossed` to a
  poisoned state on slot A (e.g. `ask_valid[A] = 0` or `crossed[A] = 1`).
  Confirm `adverse_risk`/`ml_safe_forced_pulse` reflect slot A's state AS OF
  THE TRIGGERING MESSAGE (not forced), not the poisoning state that arrives
  later. Then add the mirror case: a triggering message with a genuinely
  bad book state, poisoned back to "healthy" before `ml_valid` arrives —
  confirm the fail-safe still fires (using the ORIGINAL bad state), proving
  the fix isn't just "read whatever's most convenient."
- Add a coincidence check (matching D28's own testbench pattern) that
  `fs_snap_out_valid` (expose via hierarchical reference or a temporary
  debug port, your choice, removed before landing) coincides with
  `ml_valid` on every cycle for the duration of the test.

#### S4.2 `tb/tb_ml_chain.v` / `tb/tb_tob_top.v`

Re-run as-is first. If neither interleaves enough same-slot traffic during
the ML branch's ~5-cycle window to exercise this bug, add one case that
does: a signal that should NOT be fail-safe-forced, followed immediately by
traffic on the same slot that WOULD flip the fail-safe check if read live,
checking the eventual `adverse_risk` reflects the original triggering
message's book state.

#### S4.3 Golden model

No change expected — check `sim/ml_golden.py`'s fail-safe forcing logic; if
it has no pipeline-depth concept (likely, since it's a behavioral
reference, same as `sim/golden_model.py`'s relationship to `risk_engine.v`
per D28's own S4.3), it already evaluates against the triggering message's
own state and needs no change. If a mismatch surfaces, that's a sign this
RTL fix has a bug, not a reason to touch the golden model.

---

### S5. Acceptance criteria

**Yours to verify (iverilog):**

- `rtl/ml_policy.v` compiles under `iverilog -g2001 -Wall`, no new warnings,
  no inferred latches.
- `tb_ml_policy` passes, including both new poison-message tests from S4.1
  and the `fs_snap_out_valid`/`ml_valid` coincidence check.
- `tb_ml_chain` and `tb_tob_top` pass, including any new case from S4.2.
- Full regression (`bash scripts/run_sim.sh`, not `RUN_SIM_FAST=1`) passes.
- `git diff` on every file not listed above (in particular
  `risk_engine.v`, `signal_engine.v`, `tob_engine.v`, `feature_extractor.v`,
  `feature_normalizer.v`, `ml_classifier_wrap.v`, `order_builder.v`,
  `csr_block.v`, and `tob_top.v`'s `ALIGN_DEPTH`/`u_align`/`u_risk` sections)
  is empty.
- In your report, explicitly confirm you tested with `SNAPSHOT_DEPTH`
  different from `ALIGN_DEPTH`'s current value (S1/S4.1) — the whole point
  is proving these two are not accidentally coupled.

**Mine to verify (Vivado):** a small combinational/latch-risk change (one
new 1-cycle register plus a 3-bit `delay_line` instance) — I don't expect a
meaningful timing impact, but I'll re-synthesize as part of the next real
hardware verification pass regardless, per standing practice for any RTL
change.

---

### Scope boundary — read this, another contract and another task are running in parallel

- **`tb/tb_top.v` (full-system integration test) is a SEPARATE contract**
  (`docs/contracts/tb_top_integration.md`), possibly running at the same
  time as this one. It is a **new file** and should only ever read
  `tob_top.v`'s top-level port list (which this contract does not change)
  — it does not touch `rtl/ml_policy.v` or `tb/tb_ml_policy.v`. No
  coordination needed as long as both contracts' own file lists (this
  one's S5, the other's own acceptance section) are respected.
- **NFR-7 and the `cnt_rej_ml` reduce-mode spec wording are being handled
  separately** (`fpga_tick_to_trade_master_spec.md`,
  `docs/design_decisions.md` only) — do not touch either file as part of
  this contract.
- Do not touch `docs/design_decisions.md` — a D-entry documenting this fix
  will be written after independent verification, same as every prior
  contract in this project.

### Explicitly out of scope

- Any change to `risk_engine.v` (D28's own fix, already landed and
  verified) — this contract only extends the same technique to a different
  module.
- Any change to `ALIGN_DEPTH`, `TRIGGER_DELAY`, or any other top-level
  latency parameter — this fix is entirely internal to `ml_policy.v` plus
  two new port connections in `tob_top.v`; it does not change any pipeline
  depth any other module depends on.
- `score_raw`/`risk_level` (telemetry outputs, no consumer wired yet per
  the module's own header) — untouched, out of scope.
