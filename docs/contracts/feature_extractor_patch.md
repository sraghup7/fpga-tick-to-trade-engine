# Contract: fix `feature_extractor.v` reading a stale book (patches `rtl/feature_extractor.v`)

Status: ready to hand off. **Not a new module, and not the S6 integration
contract** — a correctness patch to one already-committed module
(`rtl/feature_extractor.v`, S3), required before S6 wires it into
`tob_top.v` for the first time. This is the D23-twin defect flagged (not
fixed) in `docs/design_decisions.md` D23 and in
`docs/contracts/tob_engine_signal_patch.md` §1.3 — **read D23 in full
before this contract**, it has the complete verification trail for the
identical bug in `signal_engine.v`, which this contract mirrors exactly.

Once this lands, verified and committed, the separate S6 integration
contract (`ml_classifier_wrap.v`, `ml_policy.v`, the alignment register,
and `tob_top.v` wiring) follows — not part of this contract.

## 1. Background

### 1.1 The bug, precisely

`feature_extractor.v` computes F0–F7 from `tob_engine.v`'s
`bid_price`/`bid_qty`/`ask_price`/`ask_qty` outputs, indexed by
`applied_slot`, gated on `book_upd_valid` — combinationally, on the *same*
cycle the triggering message arrives. Those outputs are wired only to
`tob_engine.v`'s **registered** state (`assign bid_price = bid_price_r;`,
etc.), and a register written with `<=` on a clock edge isn't visible to
another module reading it on that *same* edge — only starting the next
cycle. So `feature_extractor.v` would see the book as it stood **before**
the triggering message's own effect, despite its own header comment's
explicit claim: "book state inputs are the POST-update state of the
applied slot." Byte-for-byte the same defect D23 found and fixed in
`signal_engine.v` — same registered bus, same `book_upd_valid` gating, same
wrong assumption.

This has never been exercised end-to-end because `feature_extractor.v` is
not yet instantiated in `tob_top.v` (S6 was blocked on S4's ML work) — no
existing testbench chains it against the real `tob_engine.v`, so nothing
has ever caught it. §2.3 closes that gap permanently.

### 1.2 The fix

Identical in shape to the `signal_engine.v` fix: `tob_engine.v` already
exposes the applied slot's post-update state combinationally, added by the
D23 patch (`3f30320`):

```verilog
output wire [31:0] next_bid_price,
output wire [31:0] next_bid_qty,
output wire         next_bid_valid,
output wire [31:0] next_ask_price,
output wire [31:0] next_ask_qty,
output wire         next_ask_valid,
output wire         next_crossed
```

`feature_extractor.v` only needs four of these: `next_bid_price`,
`next_bid_qty`, `next_ask_price`, `next_ask_qty`. It does **not** need
`next_bid_valid`/`next_ask_valid`/`next_crossed` — its own header already
states "`bid_valid`/`ask_valid` are deliberately not consumed anywhere
(S2.7)"; F0's saturating-unsigned formula handles an invalid/zero side
mechanically (saturates to 0, not a sentinel), and crossed-book/invalid-book
fail-safe forcing (FR-26/FR-31) belongs downstream in `ml_policy.v` (S6
integration contract, not this one) — it will read `tob_engine.v`'s
already-existing REGISTERED `bid_valid`/`ask_valid`/`crossed` buses
directly, the same way `risk_engine.v` already reads the registered
`crossed` bus for gate `0x07`, at a pipeline cycle far enough past the
triggering event's register commit that no staleness applies (confirmed
safe by the same reasoning D23 already applied to `risk_engine.v` — see
`tob_engine_signal_patch.md` §1.3).

**Why this shape:** exposing already-computed combinational wires as new
scalar ports changes nothing about `feature_extractor.v`'s own timing — it
still registers `feat_valid` and the F0–F7 vector exactly one cycle after
`book_upd_valid`, as before. `prev_bid`/`prev_ask`/the window
state/`last_trade_dir` (FR-21) are untouched by this patch: those are
genuinely PRIOR-event history, correctly read from `prev_bp`/`prev_bq`/
`prev_ap`/`prev_aq`, which this bug never affected — only the CURRENT
event's own post-update `sbp`/`sbq`/`sap`/`saq` were wrong.

### 1.3 What this patch does *not* touch, and why

- **`risk_engine.v` is unaffected** — same reasoning as D23: it reads
  `tob_engine.v`'s registered bus at `sig_slot`, which by the time it's
  read is at least one full cycle past the triggering message's register
  commit.
- **`feature_normalizer.v` is unaffected.** It consumes only
  `feature_extractor.v`'s registered `feat_f0..f7` outputs, one cycle after
  `feat_valid` — already-committed values by construction, no same-cycle
  race.
- **`tob_top.v` is not touched by this contract.** `feature_extractor.v`
  is not instantiated there yet; that instantiation, along with
  `feature_normalizer.v`, `ml_classifier_wrap.v`, `ml_policy.v`, and the
  alignment register, is the separate S6 integration contract's job.

## 2. What you're building

**File:** `rtl/feature_extractor.v` (patch only — no new module)
**Testbenches:** `tb/tb_feature_extractor.v` (rewritten to match the new
port shape, same coverage, new cases), new `tb/tb_feature_tob_chain.v`
(§2.3)

### 2.1 Port changes

**Remove** these four `NUM_SYMBOLS`-wide input ports entirely:

```verilog
input  wire [NUM_SYMBOLS*32-1:0]  bid_price,
input  wire [NUM_SYMBOLS*32-1:0]  bid_qty,
input  wire [NUM_SYMBOLS*32-1:0]  ask_price,
input  wire [NUM_SYMBOLS*32-1:0]  ask_qty,
```

**Add** four scalar input ports in their place, matching `tob_engine.v`'s
existing `next_*` outputs 1:1:

```verilog
input  wire [31:0] next_bid_price,
input  wire [31:0] next_bid_qty,
input  wire [31:0] next_ask_price,
input  wire [31:0] next_ask_qty,
```

The `NUM_SYMBOLS` parameter **stays** — `prev_bp`/`prev_bq`/`prev_ap`/
`prev_aq`/`last_trade_dir`/`seen_first`/`win_upd`/`win_abs` are genuinely
per-slot history across all `NUM_SYMBOLS` slots, unrelated to this bug and
unchanged by this patch. `applied_slot` also stays (still needed for
`feat_slot <= sidx` and indexing the per-slot history arrays).

### 2.2 Internal rewire — the entire behavioral change

In the combinational block (`always @(*)`), repoint `sbp`/`sbq`/`sap`/`saq`
from the old bus to the new scalar ports:

```verilog
// old (delete):
sbp = bid_price [sidx*32 +: 32];
sbq = bid_qty   [sidx*32 +: 32];
sap = ask_price [sidx*32 +: 32];
saq = ask_qty   [sidx*32 +: 32];

// new:
sbp = next_bid_price;
sbq = next_bid_qty;
sap = next_ask_price;
saq = next_ask_qty;
```

Nothing else changes. Every downstream computation (`c_f0`..`c_f7`,
`midsum`/`pmsum`, the window push logic, `prev_*` updates, the registered
output block) reads `sbp`/`sbq`/`sap`/`saq`, which now simply come from a
different (correct) source — same as the `signal_engine.v` fix's `s_bp`/
`s_bq`/etc.

### 2.3 New cross-module regression: `tb/tb_feature_tob_chain.v`

Mirrors `tb/tb_signal_tob_chain.v` exactly in spirit and structure:
instantiates the **real** `rtl/tob_engine.v` and `rtl/feature_extractor.v`
together (no `tob_top.v`), drives message-shaped stimulus into
`tob_engine.v`'s own inputs, and checks `feature_extractor.v`'s
`feat_f0_spread` (and other F-values where relevant) against hand-computed
expectations matching `sim/feature_golden.py`'s post-update semantics.

Cover, at minimum:

- **The headline reproduction, direct analog of D23's own case:** QUOTE
  bid slot 0, price 1000, qty 100 (first event on this slot — establishes
  the book; expect `feat_valid` with `feat_f0_spread = 0`, since ask is
  still 0 and `sap < sbp`, saturating per F0's own rule — this is the
  baseline, not the interesting assertion). Then QUOTE ask slot 0, price
  1010, qty 50. On **this second message's own triggering cycle**, confirm
  `feat_f0_spread = 10` (`1010 - 1000`, using THIS message's own just-
  applied ask price) — registered one cycle later, as `feat_valid` always
  is. A buggy (pre-patch) RTL would instead compute `feat_f0_spread = 0`
  (reading the stale, not-yet-committed ask price from before this
  message, `sap = 0 < sbp = 1000`, wrongly saturating) — this is the exact
  numeric signature of the bug, verify it directly.
- **Mirror on the bid side:** establish ask first (QUOTE ask slot 1, price
  1010, qty 50), then QUOTE bid slot 1, price 1000, qty 100 — same
  `feat_f0_spread = 10` expectation on the bid QUOTE's own cycle.
- **A second QUOTE on an already-established slot** (price change, not
  first-touch): confirm F0 reflects the NEW price immediately (same cycle
  class as above) while F1/F3/F4 correctly use the PRIOR event's `prev_*`
  values (unaffected by this bug, but worth confirming the two mechanisms
  — current-event post-update state vs. prior-event history — don't get
  confused with each other in the fix).
- **Multiple symbols interleaved** (`NUM_SYMBOLS=4`): confirm slot 2's
  feature vector doesn't pick up slot 0's book state, and vice versa —
  exercises `applied_slot`/`sidx` routing end to end through both real
  modules.
- **TRADE/HEARTBEAT between two QUOTEs:** confirm no `feat_valid` pulse
  (per `book` gating, unaffected by this patch) and that the following
  QUOTE's F0 is still computed correctly from its own post-update state.
- On any mismatch, `$display` what was expected vs. actual (message,
  expected `feat_f0_spread`/other checked fields, actual), then a final
  `$display("FAIL")` / `$display("PASS")` line.

## 3. Testbench requirements

### 3.1 `tb/tb_feature_extractor.v` — rewrite to the new port shape, same coverage

The DUT's interface changed (§2.1): replace whatever bus-driving stimulus
helper currently sets `bid_price`/`bid_qty`/`ask_price`/`ask_qty` (indexed
per slot) with direct assignment to the four new scalar `next_*` ports.
`applied_slot` remains independently driven, exactly as `prev_*` history
and the window state are exercised across slots today.

**Every existing test case must be preserved, under the new port shape,
with equivalent coverage** — this is a mechanical adaptation of the
stimulus-driving layer, not a re-derivation of what to test. Preserve
every case covering: first-event zeroing of F1/F3/F4, F0's saturate-to-0
rule, F2's raw imbalance, the CLEAR reset-then-first-event behavior
(D13), the shared F5/F7 window's push/popcount/running-sum semantics
(including the saturation-only-at-final-output rule), F6's TRADE-side
update, multi-symbol independence, and `book_upd_valid=0` /
`msg_applied=0` no-ops.

Add new cases (mirroring `tob_engine_signal_patch.md` §3.1's shape):

- A QUOTE (bid side) where `next_bid_price`/`next_bid_qty` differ from
  what the OLD registered bus would have shown at that same cycle —
  confirm `feat_f0_spread`/`feat_f2_imbalance` reflect the `next_*` values,
  not stale ones. Mirror for the ask side.
- A TRADE/HEARTBEAT cycle: confirm the `next_*` inputs are simply not
  consulted (no `feat_valid`, `book` gating unaffected) — this is the case
  that would catch an accidental new dependency on `next_*` bleeding into
  the non-book-modifying path.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o feature_extractor_tb.vvp rtl/feature_extractor.v tb/tb_feature_extractor.v` compiles with zero warnings; `vvp` prints `PASS`.
- [ ] `iverilog -g2001 -Wall -o feature_tob_chain_tb.vvp rtl/tob_engine.v rtl/feature_extractor.v tb/tb_feature_tob_chain.v` compiles with zero warnings; `vvp` prints `PASS`.
- [ ] The headline reproduction (§2.3, bid QUOTE then ask QUOTE, `feat_f0_spread = 10` on the ask QUOTE's own cycle, registered one cycle later) is verified directly, not just trusted from the broader suite.
- [ ] Every existing `tb_feature_extractor.v` case (pre-patch) still passes, unmodified in intent, adapted only for the new port shape.
- [ ] `feature_extractor.v`'s registered-output timing is unchanged — `feat_valid` still pulses exactly one cycle after `book_upd_valid`.
- [ ] `feature_extractor.v` still has its `NUM_SYMBOLS` and `WINDOW` parameters — this patch does not remove either (unlike the `signal_engine.v` fix, which dropped `NUM_SYMBOLS` entirely — `feature_extractor.v` still needs it for per-slot history).
- [ ] No inferred latches; every `reg` assigned on every path or has a clear default.

## 5. Explicitly out of scope

- `ml_policy.v`, `ml_classifier_wrap.v`, the alignment register, or any
  `tob_top.v` wiring — the S6 integration contract, written and delivered
  separately after this patch is verified and committed.
- `feature_normalizer.v` — confirmed unaffected (§1.3), not touched.
- Adding `next_bid_valid`/`next_ask_valid`/`next_crossed` consumption to
  `feature_extractor.v` — deliberately not needed here (§1.2); FR-26/31
  fail-safe forcing is `ml_policy.v`'s job, reading `tob_engine.v`'s
  existing registered `bid_valid`/`ask_valid`/`crossed` buses directly.
- Any change to `sim/feature_golden.py` or the master spec's feature
  definitions (FR-20..26) — this is a bug fix bringing the RTL in line
  with the already-specified golden model, not a new rule.
