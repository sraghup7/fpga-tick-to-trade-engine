## Contract: fix `risk_engine.v`'s `ALIGN_DEPTH` misalignment (D28)

### Status: ready to hand off. Fixes a real, live bug in already-committed, already-integrated RTL — not a new feature.

`risk_engine.v`'s own header comment (D17) states an invariant that is no
longer true: *"tob_engine's `msg_applied` for a triggering message arrives
one cycle before signal_engine's matching `sig_valid`... the one-cycle
pipeline alignment is automatic by construction."* That was true through
S7/S9. When S6 (`docs/contracts/ml_integration.md`) added the ML branch's
alignment delay, `u_risk`'s `.sig_valid` port in `tob_top.v` was retargeted
to `sig_valid_aligned` -- delayed `ALIGN_DEPTH` cycles -- but
`risk_engine.v` itself was never touched, so its `.msg_applied`,
`.applied_slot`, `.bid_price`, `.ask_price`, `.crossed` ports are still
wired to the raw, real-time signals ([tob_top.v:616-659](../../rtl/tob_top.v)).
Nobody re-derived D17's invariant when that rewiring happened. Full writeup
in `docs/design_decisions.md` D28 -- read it for the confirmed root-cause
trace before starting; this contract assumes you have.

**What's actually broken:** gates 0x04 (price band), 0x05 (staleness), and
0x07 (crossed) read book state / timestamps *as of whenever the aligned
signal happens to arrive* instead of *as of the specific message that
triggered this signal*. `pend_prev_cycle`/`pend_msg_cycle` (gate 0x05's
inputs) are a single non-per-slot register pair overwritten on every
`msg_applied` -- by the time `sig_valid_aligned` arrives (`ALIGN_DEPTH`
cycles after the triggering message), one or more intervening messages have
already overwritten them. Gates 0x04/0x07 have the same problem reading
`bid_price[sig_slot]`/`ask_price[sig_slot]`/`crossed[sig_slot]` in real
time. **Gates 0x01/02/03/06/08/09 are unaffected** -- they only read the
already-correctly-aligned `sig_slot`/`sig_side`/`sig_price`/`sig_qty` bus
plus live config/state that's meant to be evaluated at the gate's own
cycle, not snapshotted.

---

### S0. The fix, in one sentence

Give `risk_engine.v` its own internal delay line, keyed on the module's
*raw* (pre-alignment) `sig_valid`, that carries a snapshot of the
book-state/timestamp values taken at exactly the cycle they're known-correct
(the raw `sig_valid`'s own cycle, per D17's still-valid capture mechanism)
forward by `ALIGN_DEPTH`, so they land already correctly time-referenced
when the *aligned* `sig_valid` arrives to actually evaluate the gates.

This does **not** touch `tob_top.v`'s existing `u_align` instance (which
delays `sig_slot`/`sig_side`/`sig_price`/`sig_qty` -- those are already
correct and untouched) -- it adds a second, separate delay line, entirely
inside `risk_engine.v`, for the data D28 found was missing one.

---

### S1. Why the raw `sig_valid` cycle is the right capture point (read before coding)

From `signal_engine.v:148-178` (unchanged by this contract, read-only
context): `sig_valid <= 1'b1` fires *exactly one cycle* after
`book_upd_valid`, unconditionally -- there is no other timing signal_engine
can produce. Call the triggering message's own cycle `T` (when
`book_upd_valid`/`msg_applied` fire for it); the *raw* `sig_valid` (what
`tob_top.v` currently calls `sig_valid`, before `u_align`) fires at `T+1`.

At `T+1`:
- `pend_prev_cycle`/`pend_msg_cycle` were just refreshed at `T`'s clock edge
  (D17's existing mechanism, unchanged by this contract) and are correct
  for message `T` specifically -- nothing else can have touched them
  between `T` and `T+1`, because that's only one cycle.
- `bid_price[applied_slot]`/`ask_price[applied_slot]`/`crossed[applied_slot]`
  already reflect message `T`'s own update (they're registered at `T`'s
  edge, same as every other per-slot bus in this codebase -- this is the
  same "one cycle past the triggering event's register commit" timing D23
  already established as safe elsewhere).

So `T+1` -- the raw `sig_valid`'s own cycle -- is the single correct moment
to snapshot this data for message `T`. The bug is purely that risk_engine
currently re-reads live registers at `T+1+ALIGN_DEPTH` instead of
snapshotting them at `T+1` and carrying the snapshot forward.

---

### S2. The change

#### S2.1 New ports and parameter

```verilog
module risk_engine #(
    parameter integer NUM_SYMBOLS = 4,
    parameter integer ALIGN_DEPTH = 1   // MUST equal tob_top.v's own
                                        // ALIGN_DEPTH -- see S3
) (
    ...
    // from signal_engine.v -- the ALIGNED intent (unchanged meaning/timing)
    input  wire        sig_valid,
    input  wire [1:0]  sig_slot,
    input  wire [7:0]  sig_side,
    input  wire [31:0] sig_price,
    input  wire [31:0] sig_qty,

    // NEW: signal_engine.v's RAW (pre-alignment) sig_valid/sig_slot -- fires
    // exactly one cycle after this message's own book_upd_valid, per
    // signal_engine.v's own always block. Used ONLY to time the internal
    // snapshot below; never used to gate the actual order decision.
    input  wire        sig_valid_raw,
    input  wire [1:0]  sig_slot_raw,

    input  wire                       msg_applied,
    input  wire [1:0]                 applied_slot,
    input  wire [NUM_SYMBOLS*32-1:0]  bid_price,
    input  wire [NUM_SYMBOLS*32-1:0]  ask_price,
    input  wire [NUM_SYMBOLS-1:0]     crossed,
    ...
```

`msg_applied`/`applied_slot`/`bid_price`/`ask_price`/`crossed` stay exactly
as they are -- still needed, unchanged, for `last_update_cycle`'s own
real-time refresh (D17's existing mechanism is correct and untouched).

#### S2.2 The internal snapshot + delay line

Add, near the existing staleness-timestamp state:

```verilog
// ---- D28: snapshot this message's book-state at the RAW sig_valid cycle
//      (T+1, per S1 -- exactly when D17's capture is known-correct for it),
//      then carry the snapshot forward ALIGN_DEPTH cycles via an internal
//      delay_line so it arrives already time-correct alongside the ALIGNED
//      sig_valid. Fixes D28: gates 0x04/0x05/0x07 were reading live
//      registers at the aligned arrival cycle instead. ----
wire [31:0] snap_bp      = bid_price[sig_slot_raw*32 +: 32];
wire [31:0] snap_ap      = ask_price[sig_slot_raw*32 +: 32];
wire        snap_crossed = crossed[sig_slot_raw];
// pend_prev_cycle/pend_msg_cycle: existing registers (declared below,
// unchanged capture logic), read combinationally here -- correct for THIS
// message exactly when sig_valid_raw is high (S1).

wire [128:0] gate_snap_in = {snap_bp, snap_ap, snap_crossed,
                             pend_prev_cycle, pend_msg_cycle};
wire [128:0] gate_snap_out;
wire         gate_snap_out_valid;   // must coincide with sig_valid every
                                    // cycle -- see S2.3's consistency note

delay_line #(
    .WIDTH (129),
    .DEPTH (ALIGN_DEPTH)
) u_gate_align (
    .clk       (clk),
    .rst_n     (rst_n),
    .in_valid  (sig_valid_raw),
    .in_data   (gate_snap_in),
    .out_valid (gate_snap_out_valid),
    .out_data  (gate_snap_out)
);

wire [31:0] a_bp        = gate_snap_out[128:97];
wire [31:0] a_ap        = gate_snap_out[96:65];
wire        a_crossed   = gate_snap_out[64];
wire [31:0] a_pend_prev = gate_snap_out[63:32];
wire [31:0] a_pend_msg  = gate_snap_out[31:0];
```

(`rtl/common/delay_line.v` already exists and is used twice elsewhere --
`order_builder.v`'s `TRIGGER_DELAY` and `tob_top.v`'s own `u_align`. Reuse
it as-is; do not write a new delay mechanism.)

#### S2.3 Rewire the three affected gates

```verilog
wire [31:0] s_bp = a_bp;   // was: bid_price[sig_slot*32 +: 32]
wire [31:0] s_ap = a_ap;   // was: ask_price[sig_slot*32 +: 32]
...
wire gate_crossed_fired_c = a_crossed;              // was: crossed[sig_slot]
wire gate_stale_fired_c = (a_pend_msg - a_pend_prev) > cfg_max_age;
                                                     // was: pend_msg_cycle - pend_prev_cycle
```

Everything downstream of `s_bp`/`s_ap`/`gate_crossed_fired_c`/
`gate_stale_fired_c` (the `midsum`/`mid`/`band_diff` computation, the
reject-reason priority mux, the registered gate pulses) is **unchanged** --
only where these four wires get their input changes.

`cfg_max_age`/`cfg_price_band` (the *configuration*, as opposed to the
*data* being compared) stay exactly as they are -- read live, at the gate's
actual evaluation cycle. Only the timestamp/book-state data needed a time
fix; the config values are meant to reflect whatever's currently
programmed, matching every other gate.

**Consistency note, important:** `gate_snap_out_valid` (from `u_gate_align`)
must be high on exactly the same cycles `sig_valid` (the port, fed by
`sig_valid_aligned` at the top level) is high -- both are `sig_valid_raw`
delayed by the same `ALIGN_DEPTH`, just via two separate delay-line
instances (this one, and `tob_top.v`'s `u_align`). If `ALIGN_DEPTH` passed
to this module's instantiation ever drifts from `tob_top.v`'s own
`ALIGN_DEPTH` localparam, this silently breaks again -- the same failure
mode D28 exists to close. **Do not rely on `gate_snap_out_valid` for
anything at runtime** (the existing `sig_valid` port is still what gates
the order decision, unchanged) -- but the testbench in S4 must directly
verify the two coincide, so a future depth-mismatch is caught by
simulation, not discovered on a third audit.

#### S2.4 Header comment

Rewrite the D17 paragraph (module header, currently describing "the
one-cycle pipeline alignment is automatic by construction") to describe the
new mechanism: the raw-`sig_valid`-keyed snapshot + internal delay line,
why `T+1` is the correct capture point (S1's reasoning), and an explicit
note that this fix exists because that automatic-by-construction claim
stopped being true once S6 inserted `ALIGN_DEPTH` between signal_engine and
this module. Reference D28.

---

### S3. `tob_top.v` ripple

`u_risk`'s instantiation needs two new port connections and one new
parameter binding -- both already exist as top-level wires, no new wiring
required elsewhere:

```verilog
risk_engine #(
    .ALIGN_DEPTH (ALIGN_DEPTH)   // reuse the existing localparam -- do not
                                 // hardcode a number here
) u_risk (
    ...
    .sig_valid      (sig_valid_aligned),
    .sig_slot       (sig_slot_aligned),
    ...
    .sig_valid_raw  (sig_valid),       // signal_engine's raw output --
    .sig_slot_raw   (sig_slot),        // already a top-level wire (u_csr
                                       // already reads these two)
    .msg_applied    (msg_applied),
    .applied_slot   (applied_slot),
    ...
```

No other `tob_top.v` change. `ALIGN_DEPTH` itself is untouched by this
contract (whatever value the in-flight `feature_extractor_timing_patch.md`
v2 work lands it at is fine -- this fix is correct for any `ALIGN_DEPTH`,
by construction, which is the point).

---

### S4. Testbench changes

#### S4.1 `tb/tb_risk_engine.v` -- this is the important one

The existing testbench drives `sig_valid` directly and checks gate outputs
roughly one cycle later; it has no concept of a separate raw/aligned signal
because risk_engine didn't have one before. It needs real rework, not a
cosmetic port addition:

- Instantiate the DUT with a **non-trivial `ALIGN_DEPTH`** (pick something
  small but clearly more than 1, e.g. 3, so a bug that only shows up under
  real delay -- not the degenerate depth-1 case -- gets exercised).
- Every existing directed test drives `sig_valid_raw`/`sig_slot_raw` (mimic
  signal_engine's own one-cycle-after-book_upd_valid timing relative to
  whatever `msg_applied`/`applied_slot` it's already driving), then drives
  the corresponding `sig_valid`/`sig_slot`/`sig_side`/`sig_price`/`sig_qty`
  **`ALIGN_DEPTH` cycles later** (mimicking what `tob_top.v`'s real
  `u_align` would produce) instead of on the same cycle as before. This is
  the single biggest mechanical change to the file -- work through it
  carefully, one existing test block at a time, rather than trying to patch
  the driving task generically on the first pass.
- **New test, the one that actually proves the fix**: fire a triggering
  signal (`sig_valid_raw`/`sig_slot_raw` for slot A, with a specific
  `bid_price[A]`/`ask_price[A]`/known-non-crossed/known-fresh-arrival-gap
  book state), then **before** the aligned `sig_valid` for it arrives
  (i.e., during the `ALIGN_DEPTH`-cycle gap), drive one or more additional
  `msg_applied` events on a **different slot** and on **slot A itself**
  that change `bid_price[A]`/`ask_price[A]`/`crossed[A]` and refresh
  `last_update_cycle[A]` to something that would flip gates 0x04/0x05/0x07's
  verdicts if read in real time. Confirm the ORIGINAL triggering signal's
  gate evaluation reflects the state as of ITS OWN triggering message, not
  the poisoning ones. This is the regression test for D28 -- without it,
  this bug (or one just like it) can reappear silently the next time
  something upstream changes.
- Add an assertion-style check (a `fail`-flagging comparison, matching this
  testbench's existing self-checking style) that `gate_snap_out_valid`
  (expose it via a debug hierarchical reference, or add a temporary debug
  output port removed before landing -- your choice) coincides with
  `sig_valid` on every cycle for the duration of the test, per S2.3's
  consistency note.

#### S4.2 `tb/tb_tob_top.v`

Re-run as-is first. If none of the existing directed cases interleave
enough same-slot traffic during the `ALIGN_DEPTH` window to exercise this
bug (likely, since finding it required inventing a specific "poison
message" test), add one new case that does: a signal-triggering event
followed immediately by more traffic on the same slot before the risk
decision lands, checking the eventual `reject_reason`/`gate_*_fired`
outputs match what the ORIGINAL triggering message's book state implies,
not what the most recent state says.

#### S4.3 Golden model

No change expected -- `sim/golden_model.py` presumably already evaluates
gates 0x04/0x05/0x07 against the triggering message's own state (it has no
`ALIGN_DEPTH` concept at all, since it's a behavioral reference, not a
pipelined one). If `test_golden_model_handcase.py` or the full regression
surfaces a mismatch, that's a sign this RTL fix has a bug, not a reason to
touch the golden model.

---

### S5. Acceptance criteria

**Yours to verify (iverilog):**

- `rtl/risk_engine.v` compiles under `iverilog -g2001 -Wall`, no new
  warnings, no inferred latches.
- `tb_risk_engine` passes, including the new poison-message test from S4.1
  and the `gate_snap_out_valid`/`sig_valid` coincidence check.
- `tb_tob_top` passes, including any new case from S4.2.
- Full regression (`bash scripts/run_sim.sh`, not `RUN_SIM_FAST=1`) passes.
- `git diff` on every file not listed above (in particular
  `signal_engine.v`, `tob_engine.v`, `feature_extractor.v`,
  `feature_normalizer.v`, `ml_classifier_wrap.v`, `ml_policy.v`,
  `order_builder.v`, `csr_block.v`) is empty.
- In your report, explicitly confirm the fix works for an `ALIGN_DEPTH`
  other than the current committed value (i.e., that you tested with a
  testbench-local depth different from whatever `tob_top.v` currently
  declares) -- the whole point is that this must not need re-deriving every
  time `ALIGN_DEPTH` changes again.

**Mine to verify (Vivado):** this is a logic/timing-correctness fix, not a
combinational-depth change -- I don't expect it to move the critical path
meaningfully, but I'll re-synthesize as part of the next real hardware
verification pass regardless, since that's standing practice for any RTL
change touching the fast path.

---

### Explicitly out of scope

- `ml_policy.v`'s identical bug class (real-time `bid_valid`/`ask_valid`/
  `crossed` reads at `ml_slot`, D28's "not this contract" note) -- needs its
  own fix with its own capture point, not folded in here.
- The separate, still-unexplained `u_risk/token_bucket_reg[*]` latch
  inference (D28's other confirmed-but-unexplained finding) -- a real
  NFR-10 violation, but a different root cause requiring its own
  investigation before a fix can be written.
- Any change to `sim/golden_model.py` unless S4.3's regression actually
  finds a real mismatch.
- Re-deriving or changing `ALIGN_DEPTH`'s actual value -- that's
  `feature_extractor_timing_patch.md`'s concern, not this one's.
