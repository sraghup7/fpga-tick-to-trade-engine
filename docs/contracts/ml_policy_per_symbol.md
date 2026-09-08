## Contract: make `ml_policy.v`'s `adverse_risk` hysteresis state per-symbol, not a single global register

### Status: ready to hand off. Found by an external review (a second Opus-model
pass over the repo, given the master spec and `docs/design_decisions.md` and
pointed at the RTL); independently confirmed by reading the actual RTL
(`rtl/ml_policy.v`) and the matching Python reference (`sim/ml_golden.py`)
before writing this contract — both genuinely have the bug described below,
bit-exact with each other.

### S0. The bug, in one sentence, and why it matters

`rtl/ml_policy.v` has exactly one `adverse_risk` register (currently
`output reg adverse_risk`, 1 bit) shared across every watched symbol.
`tob_top.v` runs `NUM_SYMBOLS` (default 4) independent feeds through the
same classifier pipeline, each producing its own `ml_valid`/`ml_slot`/`z`
event — but the hysteresis hold state that decides `adverse_risk` in the
`cfg_ml_th_low < z < cfg_ml_th_high` band is not per-slot: an adverse
verdict computed for symbol 1's event overwrites the SAME register a
benign or hold-band verdict for symbol 3 will next read. Concretely: if
symbol 1 sets `adverse_risk=1` (a genuine `z >= th_high` event) and then
symbol 3's next event lands with `z` in the hold band, symbol 3's order
gets gated (`risk_engine.v` gate `0x09`, FR-48) not because of anything
about symbol 3, but because of symbol 1's unrelated state. This is silent
cross-contamination between feeds that are supposed to be independent
(every other per-symbol quantity in this design — `tob_engine.v`'s book,
`feature_extractor.v`'s F0-F7 history, `risk_engine.v`'s position ledger —
is correctly a `NUM_SYMBOLS`-wide vector; this is the one place the
pattern was dropped).

This is **not** an RTL-vs-golden-model bug — `sim/ml_golden.py`'s
`MLClassifier.adverse_risk` (line 106) is the identical single-scalar
design, so RTL and golden model agree with each other, just on the wrong
thing. Both need the same fix, in lockstep, or the golden-model comparison
in `tb/tb_top.v` will stop being bit-exact once the RTL changes alone.

**Decision (master spec §0, FR-28, 2026-09-08): per-symbol is correct.**
FR-28's "hold previous value" is a per-*instrument* risk estimate (the
model is estimating adverse selection risk for a specific book), not a
per-*wire* one — and every other piece of per-message state in this
pipeline (`feature_extractor.v`'s window history, `risk_engine.v`'s
position ledger) already keys off slot. This contract implements that
decision; it is not asking you to make it.

### S1. `rtl/ml_policy.v` — exact change

**Only the `adverse_risk` output and the always-block logic that sets it
change.** `score_raw`/`risk_level`/`ml_event_valid`/`ml_adverse_pulse`/
`ml_benign_pulse`/`ml_safe_forced_pulse` stay exactly as they are —
scalar, reflecting the most recent ML event across any symbol (there is
no per-symbol addressing for these in the §9 register map, and this
contract does not add any — see S5 explicitly-out-of-scope). Add a
`NUM_SYMBOLS` parameter if the module doesn't already expose one usable
here — it already does (`parameter integer NUM_SYMBOLS = 4`, line 67 of
the current file, currently unused inside the module body except in the
port widths of `bid_valid`/`ask_valid`/`crossed`). Reuse it.

**Port change:**
```verilog
// was: output reg          adverse_risk,
output reg  [NUM_SYMBOLS-1:0] adverse_risk,   // per-symbol hysteresis state
```

**Logic change** (replace the single always-block's `adverse_risk`
assignments — everything else in that block, including the
`score_raw`/`risk_level`/pulse outputs, is unchanged):

- On reset: `adverse_risk <= {NUM_SYMBOLS{1'b0}};` (all symbols start
  benign — same reset value every symbol effectively had before, just
  now stated per-bit).
- On `ml_valid`: only bit `ml_slot` of `adverse_risk` changes; every other
  slot's bit holds. Concretely, replace each `adverse_risk <= 1'bX;`
  assignment in the existing `if (safe_state_c) / else if (z >=
  cfg_ml_th_high) / else if (z <= cfg_ml_th_low) / else` chain with
  `adverse_risk[ml_slot] <= 1'bX;` (a partial-bit non-blocking assign to
  one bit of the reg vector — standard Verilog-2001, no new construct
  needed). The hold-band branch's `adverse_risk <= adverse_risk;` becomes
  `adverse_risk[ml_slot] <= adverse_risk[ml_slot];` (reads back the SAME
  slot's own held bit, not some other slot's — this is the crux of the
  fix; getting this one line wrong index would silently reintroduce a
  narrower version of the same bug).
- `ml_adverse_pulse`/`ml_benign_pulse` (used for `cnt_ml_adverse`/
  `cnt_ml_benign`, S10's invariant `cnt_ml_events = cnt_ml_adverse +
  cnt_ml_benign`) must still be derived from the hold branch's OWN slot's
  bit — i.e. wherever the current code reads `adverse_risk` on the
  right-hand side of the hold-branch pulse assignments
  (`ml_adverse_pulse <= adverse_risk; ml_benign_pulse <= ~adverse_risk;`),
  read `adverse_risk[ml_slot]` (the PRE-update value, same as today —
  these are combinational reads of the register's current contents before
  this cycle's own write takes effect, exactly as the scalar version
  already correctly does).
- Update the module header comment's description of `adverse_risk` to say
  per-symbol (the existing header already thoroughly documents the
  snapshot/alignment mechanism — S5.4/FR-28/29 references, hysteresis
  description — just the "single register" framing needs a sentence
  changed, not a rewrite).

**Do not** touch the fail-safe snapshot mechanism (`raw_d1_valid`/
`raw_d1_slot`/`u_fs_align`/`fs_snap_out`), `safe_state_c`, or
`sat_risk_level` — none of that is slot-aggregation logic, it already
operates correctly on a per-event basis and is orthogonal to this bug.

### S2. `rtl/risk_engine.v` — ripple

`adverse_risk` is currently a 1-bit input port (line 149) read directly
at two call sites: `gate_ml_fired_c` (line ~343) and `reduced_qty_c`
(line ~367). Both currently read the whole (scalar) `adverse_risk`; both
must instead read the bit for THIS message's own slot — `sig_slot`, the
aligned intent's slot, already available at both use sites (it's the same
signal `gate_position_fired_c`/`next_pos` already index `position_r` by).

```verilog
// port (was: input wire adverse_risk,)
input  wire [NUM_SYMBOLS-1:0] adverse_risk,

// was: wire gate_ml_fired_c = adverse_risk & ~cfg_ml_action;
wire gate_ml_fired_c = adverse_risk[sig_slot] & ~cfg_ml_action;

// was: wire [31:0] reduced_qty_c = (adverse_risk & cfg_ml_action) ? ...
wire [31:0] reduced_qty_c = (adverse_risk[sig_slot] & cfg_ml_action) ? ...
```

`risk_engine.v` already has a `NUM_SYMBOLS` parameter (used for
`position_r`'s width) — reuse it for `adverse_risk`'s port width the same
way.

### S3. `rtl/tob_top.v` — ripple

The internal wire `adverse_risk` (line 457, `wire adverse_risk;`) widens
to `wire [NUM_SYMBOLS-1:0] adverse_risk;`. Both connections (`u_policy`'s
output at line 581 and `u_risk`'s input at line 666) are already
plain-name port connections (`.adverse_risk (adverse_risk)`) — no change
needed there beyond the wire declaration's width, Verilog connects the
full vector automatically.

### S4. Python reference — `sim/ml_golden.py` and `sim/gen_top_soak_vectors.py`

**`MLClassifier` (`sim/ml_golden.py`):**
- `self.adverse_risk = 0` (line 106) becomes a per-symbol structure —
  simplest is `self.adverse_risk: dict[int, int] = {}` (a slot -> 0/1
  dict, defaulting a never-seen slot to 0, matching the RTL's all-zero
  reset), OR a fixed-size list if you'd rather pin `NUM_SYMBOLS` into the
  constructor (either is fine; pick whichever reads more naturally against
  the rest of this file's style — check `FeatureTracker` in
  `sim/feature_golden.py` for the existing per-symbol-dict convention this
  codebase already uses and match it, since that's the established
  pattern for per-symbol Python state here).
- `classify()` (line 108) gains a required `slot: int` parameter (make it
  the first positional argument after `self`, before `features`, so call
  sites read naturally: `clf.classify(slot, x, bid_valid, ask_valid,
  crossed, seq_gap)` — or keyword-only if you prefer explicitness at call
  sites; either is acceptable, just update every call site to match).
  Inside, replace every bare `self.adverse_risk` read/write with the
  per-slot lookup (defaulting an unseen slot to 0, same as the RTL's
  reset value) — the hold branch (`adverse = self.adverse_risk`) reads
  THIS slot's own last value, and the final `self.adverse_risk = adverse`
  writes back to THIS slot only, leaving every other slot's stored value
  untouched (the same crux point as S1's RTL fix — get the indexing right
  here or this reference stops being a faithful model of the fix).
- Add a one-line docstring/comment note that this now matches
  `ml_policy.v`'s per-symbol `adverse_risk[NUM_SYMBOLS-1:0]` (post-fix),
  citing `docs/design_decisions.md`'s entry for this contract once it
  exists (the person landing this fix should add that entry — see S6).

**`gen_top_soak_vectors.py`'s `_compute_adverse_risk_stream`** (the only
caller of `clf.classify()`, lines ~248 and ~261): needs the slot for each
message. `symbols` (the function's own parameter, the watched-symbol-ID
tuple) already establishes slot ordering the same way the RTL's
`SYMBOL_0..3` registers do — slot for a given `msg.symbol_id` is
`symbols.index(msg.symbol_id)`. Compute that once per message (or once
per `book = books[msg.symbol_id]` lookup, same place) and pass it as the
new first argument to both `clf.classify(...)` call sites. Do not change
anything else in this function — the shadow-book/seq-gap/dup logic above
those two call sites is unrelated to this fix and already correct.

### S5. Explicitly out of scope

- `score_raw`/`risk_level`/`ml_event_valid`/`ml_adverse_pulse`/
  `ml_benign_pulse`/`ml_safe_forced_pulse` stay scalar (last ML event
  across any symbol) — the §9 register map has no per-symbol addressing
  for ML telemetry, and adding one is a register-map change this contract
  does not make. `cnt_ml_adverse`/`cnt_ml_benign`/`cnt_ml_safe_forced`
  (aggregate, feed-wide counters, §10) are unaffected either way — they
  count EVENTS, not "was this particular gating decision correct for this
  slot," so this fix changes WHICH orders get gated, not whether these
  specific counters still sum correctly (they do, by construction, same
  as before).
- `feature_extractor.v`, `feature_normalizer.v`, `ml_classifier_wrap.v` —
  none of these are touched; they are already correctly per-slot (feature
  history) or per-event-stateless (the classifier itself, which computes
  `z` fresh from `x` every event with no persisting state of its own).
- `csr_block.v` — no register-map changes.
- The fail-safe snapshot/alignment mechanism (D28-class fix,
  `docs/contracts/ml_policy_align_fix.md`) — unrelated bug class, already
  fixed, not to be touched.
- Renumbering or otherwise changing `ml_slot`'s width/encoding — it's
  already `[1:0]`, matching `NUM_SYMBOLS=4`; this contract does not change
  `NUM_SYMBOLS`.

### S6. Testbench requirements

- **`tb/tb_ml_policy.v`**: add a new directed case (after the existing
  D28-class P1-P3 regression, following that section's own tag-numbering
  convention — the next free block/tag range) that is the actual
  regression for this bug: drive a genuine adverse event on slot 0 (`z >=
  cfg_ml_th_high`, healthy book, no fail-safe forcing), then a SEPARATE
  event on slot 1 with `z` in the hold band (strictly between
  `cfg_ml_th_low` and `cfg_ml_th_high`) and a healthy book. Assert slot
  1's resulting `adverse_risk[1]` is **0** (slot 1 has never had an event
  before, so its own hold-band default is 0 — it must NOT inherit slot
  0's just-set adverse bit). Then a third event, back on slot 0 in the
  hold band: assert `adverse_risk[0]` is still **1** (slot 0's own hold
  correctly persists ITS OWN prior verdict). This is the minimum case
  that actually distinguishes "per-symbol, correct" from "shared scalar,
  bug" — a test that only ever drives one slot cannot catch this class of
  bug (confirmed: the existing P1-P3 cases are all single-slot and
  already pass on the unfixed RTL, which is exactly why this bug shipped
  unnoticed). Also re-run the full existing P1-P3 D28-class suite
  unmodified — they should still pass (single-slot behavior is a special
  case of the fixed per-slot behavior, not something the fix changes).
- **`tb/tb_risk_engine.v`**: existing cases (block I/J, the D16/ML-reduce
  and ML-block-path cases) all drive `d_adv` (the tb's `adverse_risk`
  stand-in, fed to `risk_engine.v`'s `dut.adverse_risk` port through the
  align delay line — check the actual port wiring in the file, since this
  tb feeds `adverse_risk` alongside `sig_slot`/`sig_price`/etc through its
  own `u_tb_align` delay line, not as a bare top-level input) on slot 0
  only today. Widen `d_adv` (or however the tb currently threads the
  adverse bit through its own delay-line payload) to `NUM_SYMBOLS` bits
  and update every existing call site to drive the full vector (setting
  every OTHER slot's bit to something deliberately different from the
  slot under test — e.g. the opposite value — is the right way to prove
  `risk_engine.v`'s new `adverse_risk[sig_slot]` indexing is actually
  correct and not, say, always reading bit 0 regardless of `sig_slot`).
  Add one new directed case: slot 0 adverse=1, slot 1 adverse=0, an order
  on slot 1 must NOT be blocked by gate `0x09` even though slot 0's bit is
  set.
- Full `bash scripts/run_sim.sh` (not `RUN_SIM_FAST=1`) must pass,
  including `tb_top`'s randomized soak (regenerate
  `tb/stimulus/tb_top_soak_*` since `gen_top_soak_vectors.py` changed —
  `run_sim.sh` already does this automatically when the stimulus files
  are missing/stale, per D44's own note; if it doesn't pick up the change
  automatically, delete the stale `tb/stimulus/tb_top_soak_*` files
  yourself before running).

### S7. Acceptance criteria

**Yours to verify (iverilog):**
- `rtl/ml_policy.v`, `rtl/risk_engine.v`, `rtl/tob_top.v` all compile under
  `iverilog -g2001 -Wall`, no new warnings, no inferred latches.
- `tb_ml_policy` passes, including the new per-symbol regression (S6).
- `tb_risk_engine` passes, including the new per-symbol regression (S6).
- `tb_tob_top` and `tb_top` pass (the latter regenerating its soak
  stimulus against the updated `gen_top_soak_vectors.py`).
- Full `bash scripts/run_sim.sh` passes.
- `git diff` on every file not listed in S1-S4 above (in particular
  `feature_extractor.v`, `feature_normalizer.v`, `ml_classifier_wrap.v`,
  `csr_block.v`, `signal_engine.v`, `tob_engine.v`) is empty.
- **Mutation check**: revert just the `ml_policy.v` hold-branch indexing
  fix (`adverse_risk[ml_slot] <= adverse_risk[ml_slot];` back to reading
  a different/wrong index, or back to the scalar) on a scratch copy and
  confirm the new S6 regression fails with the exact cross-contamination
  symptom described in S0 — the same discipline every other contract in
  this repo uses (see `docs/design_decisions.md` D45 for the most recent
  example of this project's own verification bar).
- In your report, state explicitly which of `dict[int, int]` vs. a fixed
  list you chose for `MLClassifier.adverse_risk` and why, and confirm the
  hold-branch write-back in BOTH the RTL and the Python reference reads
  and writes the SAME slot's own bit (this is the one line in each file
  most likely to silently regress back to a narrower version of this bug
  if copy-pasted carelessly).

**Mine to verify (independent re-check per this project's established
workflow, `docs/design_decisions.md`'s "self-implemented" vs. contract
convention):** re-diff every changed file, re-compile and re-run every
testbench myself, and re-run at least one of the mutation checks you
report.
