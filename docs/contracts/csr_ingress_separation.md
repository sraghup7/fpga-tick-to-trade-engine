## Contract: stop CSR read/write frames (`0x20`/`0x21`) from polluting ingress counters, and add §10's counter-invariant assertions

### Status: ready to hand off. Found by an external review (a second
Opus-model pass over the repo, given the master spec and
`docs/design_decisions.md` and pointed at the RTL); independently
confirmed by reading `rtl/md_parser.v`, `rtl/seq_monitor.v`,
`rtl/csr_block.v`, `sim/golden_model.py`, and `sim/gen_top_soak_vectors.py`
before writing this contract. The two halves (counter-pollution fix,
invariant assertions) are bundled in one contract deliberately: the
assertions cannot be added truthfully until the thing they'd assert stops
being false (see S0).

### S0. The bug, and why the two halves are bundled

`csr_block.v` taps the *same* `frame_classifier.v` → `md_parser.v` byte
stream as market data (`docs/design_decisions.md` D19) — there is no
second ingress path. `md_parser.v` decodes `msg_type` from byte 0 of every
complete 16-byte frame on that stream, market data or CSR, and its
`type_ok` check only recognizes `MSG_QUOTE`/`MSG_TRADE`/`MSG_CLEAR`/
`MSG_HEARTBEAT` — so every CSR write (`0x20`) or read-request (`0x21`)
frame fails `type_ok` and is treated exactly like a genuinely malformed
message: `err_msg_type` fires, which (via `csr_block.v:484`,
`if (md_msg_valid | err_msg_type | err_flags) cnt_msgs_rx <=
satinc(cnt_msgs_rx);`) inflates `cnt_msgs_rx`, and (via
`seq_monitor.v:98`, `msg_complete = msg_valid | err_msg_type |
err_flags`) is ALSO seen by the sequence monitor with `seq_num=0` (the
CSR frame's tail is hardwired to zero), which looks like a duplicate
(`cnt_seq_dup++`) once any real traffic has occurred.

`sim/gen_top_soak_vectors.py` already models this exactly (D44 item 1's
fix), which is why `tb/tb_top.v`'s 35/35 counters currently pass — but
that means the test is currently checking that RTL and golden model agree
on a wrong number, not that the number is right. Concretely, per §10's own
stated invariant `cnt_msgs_rx = cnt_msgs_filtered + cnt_msgs_accepted +
err_msg_type + err_flags` (message-level errors only — frame-level ones
like `err_fcs`/`err_ethertype`/`err_frame_len` are excluded by
construction, since a frame that fails those never reaches `md_parser.v`
at all): `err_msg_type` in the current expected-counter file is `12`,
entirely CSR-frame noise (3 setup writes + up to 9 counter reads that
happened to occur before the soak's real error traffic, depending on
generator ordering), not evidence of a single malformed market-data
message. On real hardware, §11.6 item 2's own success criterion
("`cnt_msgs_rx` equals host count exactly") will not hold the moment
anyone reads a counter mid-session — this is a predictable S11 failure,
not a surprise. It's also one field away from being actively dangerous:
CSR frames currently carry a hardwired zero tail, so they only ever look
like *duplicates*; a nonzero tail in that position would look like a
*sequence gap*, latching the sticky `seq_gap` and gate `0x06` shut until a
snapshot arrives — this fix removes that risk by construction (CSR frames
stop being visible to `seq_monitor.v` at all, so they can never look like
anything to it, gap or duplicate).

**This is why the fix and the invariant assertions are one contract, not
two**: §10 already says the five invariants are "asserted in the
testbench." They aren't (checked directly — no assertion exists anywhere
today), and invariant 1 specifically *can't* be added as a real assertion
truthfully until CSR frames stop inflating `cnt_msgs_rx`/`err_msg_type`.
Fix first, then assert — in the same contract, so the assertion lands
already correct instead of needing its own follow-up.

### S1. `rtl/md_parser.v` — the actual fix (one file)

CSR frame types share this byte stream by design (D19) — they are not
malformed messages, they're a different, legitimate frame category on the
same wire. Recognize them explicitly instead of letting them fall through
to "undefined `msg_type`":

```verilog
// alongside the existing MSG_QUOTE/MSG_TRADE/MSG_CLEAR/MSG_HEARTBEAT
// localparams:
localparam [7:0] MSG_CSR_WRITE    = 8'h20;   // S9: CSR write frame
localparam [7:0] MSG_CSR_READ_REQ = 8'h21;   // S9: CSR read-request frame

// was: wire type_ok = (msg_type == MSG_QUOTE) || ... || (msg_type == MSG_HEARTBEAT);
// (type_ok itself is UNCHANGED -- CSR frames still do not count as valid
// market-data messages; msg_valid must never fire for them)
wire type_ok = (msg_type == MSG_QUOTE) || (msg_type == MSG_TRADE) ||
               (msg_type == MSG_CLEAR) || (msg_type == MSG_HEARTBEAT);

// NEW:
wire is_csr_type = (msg_type == MSG_CSR_WRITE) || (msg_type == MSG_CSR_READ_REQ);

// was: assign err_msg_type = complete_d & ~type_ok;
assign err_msg_type = complete_d & ~type_ok & ~is_csr_type;

// msg_valid is UNCHANGED -- still requires type_ok, which CSR frames never satisfy:
assign msg_valid    = complete_d & type_ok & flags_ok;
```

`err_flags` (`complete_d & type_ok & ~flags_ok`) already implicitly
excludes CSR frames today (`type_ok` is false for them regardless of this
fix) — no change needed there.

**Why this one change is sufficient, and nothing else in `rtl/` needs to
change:** `seq_monitor.v`'s `msg_complete = msg_valid | err_msg_type |
err_flags` becomes `0 | 0 | 0` for a CSR frame once `err_msg_type` stops
firing for it (`msg_valid` and `err_flags` were already `0` for CSR frames
before this fix, since both require `type_ok`) — so `seq_monitor.v`'s
entire `if (msg_complete)` block simply never executes for a CSR frame;
`expected_seq` is untouched, no phantom duplicate or gap. `csr_block.v`'s
own `cnt_msgs_rx <= satinc(cnt_msgs_rx)` condition
(`md_msg_valid | err_msg_type | err_flags`) becomes `0` the same way.
Verify this reasoning holds by re-reading both files after the
`md_parser.v` change — **do not edit `seq_monitor.v` or `csr_block.v`
themselves** unless your own re-reading finds this reasoning wrong (if it
does, say so explicitly in your report rather than silently patching
around it).

`csr_block.v`'s own CSR read/write EXECUTION logic (recognizing `0x20`/
`0x21` in byte 0 and acting on `addr`/`data`) is a separate, independent
byte-serial decode straight off the raw stream (D19 item 1) — it does not
read `md_parser.v`'s `msg_type`/`err_msg_type` at all, so this fix has no
effect on CSR functionality itself.

**`cnt_frames_rx` is deliberately left unchanged** — it counts Ethernet
frames at the frame-classifier level, regardless of payload semantics,
and no §10 invariant depends on excluding CSR frames from it (only
`cnt_msgs_rx` and the invariant built on it are in scope here). If you
believe `cnt_frames_rx` should also exclude CSR frames, say so in your
report rather than changing it unilaterally — that's a scope call for the
next contract, not this one.

### S2. `sim/golden_model.py` — matching fix

`process_message()` currently increments `cnt_msgs_rx` unconditionally
(near the top of the function) and runs the seq-gap/dup tracking block
unconditionally on every message, mirroring `msg_complete`'s current
(buggy) scope; `err_msg_type` fires via `if msg.msg_type not in
VALID_MSG_TYPES`. All three need the same CSR exclusion, in the same
place `md_parser.v`'s fix draws the line — **before** any counter is
touched, not after:

```python
# alongside VALID_MSG_TYPES:
CSR_FRAME_TYPES = (0x20, 0x21)   # S9 -- share this byte stream (D19), not market data

# at the top of process_message, right after `msg = Message.decode(raw)`,
# BEFORE the existing `self.counters.inc("cnt_msgs_rx")` call and BEFORE
# the seq-gap/dup tracking block:
if msg.msg_type in CSR_FRAME_TYPES:
    return ProcessResult()
```

Move the existing `self.counters.inc("cnt_msgs_rx")` line so it runs
AFTER this new early return (i.e., the CSR check must be the very first
thing `process_message` does with a decoded message, before any counter
side effect). The existing `if msg.msg_type not in VALID_MSG_TYPES:
self.counters.inc("err_msg_type")` check further down is unaffected by
this change (CSR frame types never reach it now, having already returned)
and does not need to change itself — do not touch it.

Do not change `process_frame`'s own frame-level counters
(`cnt_frames_rx` etc.) — matches S1's RTL scope decision.

### S3. `sim/gen_top_soak_vectors.py` — simplify to match

The elaborate "simulate the exact N reads, snapshot each counter
immediately before/after its own read frame" apparatus
(`_csr_frame_pack`, the loop building `counters: dict`, lines ~374-448 as
of this writing) exists ONLY because CSR frames used to have measurable,
pipeline-depth-dependent side effects on `cnt_frames_rx` vs. every other
counter (D44 item 2). After S1/S2, every counter this generator currently
adjusts for CSR-frame effects — `cnt_msgs_rx`, `err_msg_type`,
`cnt_seq_dup`, `cnt_seq_gap` — has **zero** effect from CSR frames by
construction; only `cnt_frames_rx` still moves (S1's explicit scope
decision). Concretely:

- Keep calling `gm.process_frame()` for the 3 CSR setup-write frames and
  the 35 CSR read frames, in the same order `tb/tb_top.v` actually sends
  them (this still matters for `cnt_frames_rx`'s own count, and keeps this
  generator an honest simulation of the real frame sequence rather than a
  hand-computed shortcut).
- The pre/post-snapshot distinction for the 35 reads (`counters[name] =
  gm.counters[name] if name == "cnt_frames_rx" else pre_value`) becomes
  unnecessary for every counter EXCEPT `cnt_frames_rx` itself, since every
  other counter's value cannot change as a result of processing a CSR
  read frame anymore (S1/S2 make that a structural guarantee, not an
  empirical one) — simplify to snapshotting every counter's value straight
  after all 38 CSR frames (3 writes + 35 reads) have been processed, with
  `cnt_frames_rx` still needing its own already-correct handling (it moves
  with every one of the 38 frames, same as before).
- Update this file's own header/inline comments (D44's cited reasoning,
  the "1 LOW when snapshotted the same way" paragraph) to describe the
  NEW, simpler reality rather than leaving stale reasoning that no longer
  matches the code — a future reader should not have to reconstruct that
  this comment predates a fix.
- Do not change anything about the real-message stream processing
  (`adverse_risk_fn`, `payloads`, `expected_orders` construction) — none
  of that is CSR-frame-related.

### S4. `tb/tb_top.v` — add §10's five counter-invariant assertions

§10 lists five invariants and says they're "asserted in the testbench."
None currently are (checked directly). Add them to `randomized_soak`'s
counter-comparison block (after the existing per-counter mismatch loop,
`tb/tb_top.v` around what is today lines 761-769), computed from the
REAL RTL readback values (the same `rd_val` the existing loop already
reads via `csr_read_value`), not from `expected_counters[]` — the point
is to check the RTL is self-consistent, independent of whether it happens
to agree with the golden model on any individual number (this is exactly
the class of bug — RTL and golden model agreeing on a wrong number — that
made this whole contract necessary in the first place, so the new checks
must not be able to pass merely because both sides share the same bug).

Store every counter's readback into a persistent array during the
existing loop (parallel to `expected_counters[]`, e.g. `actual_counters
[0:34]`, assigned from `rd_val` on each iteration — the loop already
reads every value, it just currently discards `rd_val` after the
mismatch check). Then, using `COUNTER_ORDER`'s fixed positions (the same
0-34 indexing `counter_addr[]` already uses — cite the index comments
already present at each `counter_addr[i] = ...` line):

```text
1. cnt_msgs_rx            == cnt_msgs_filtered + cnt_msgs_accepted + err_msg_type + err_flags
   (message-level errors only, per S0's derivation above -- NOT every err_*
   counter: err_fcs/err_ethertype/err_ip/err_udp_port/err_frame_len are
   frame-level, a frame failing those never reaches md_parser.v to become
   part of cnt_msgs_rx's count at all; err_signal_conflict is a downstream
   signal-stage error, also not part of md_parser.v's per-message count.)
2. cnt_signal_buy + cnt_signal_sell == cnt_orders_tx + cnt_rej_kill + cnt_rej_size
   + cnt_rej_position + cnt_rej_band + cnt_rej_stale + cnt_rej_seqgap
   + cnt_rej_crossed + cnt_rej_throttle + cnt_rej_ml + cnt_order_overflow
3. cnt_ml_events == cnt_ml_adverse + cnt_ml_benign
4. cnt_rej_ml <= cnt_ml_adverse
5. cnt_ml_safe_forced <= cnt_ml_adverse
```

Each is a `$display("FAIL: invariant N: ...")` + `fail = 1'b1;` on
violation, matching this file's existing style exactly (see the mismatch
loop immediately above where you're adding this, or `ck`/`ck_pos` in
`tb/tb_risk_engine.v` for the same house style in another testbench).
Run these checks unconditionally at the end of `randomized_soak` (after
the counter-mismatch loop) — they should hold whether or not any
individual counter mismatch also fired, since they're checking a
different property (internal RTL consistency, not RTL-vs-golden-model
agreement).

### S5. Explicitly out of scope

- `csr_block.v`, `seq_monitor.v` — no RTL changes (S1 explains why none
  are needed).
- `cnt_frames_rx` continuing to count CSR frames — a deliberate scope
  decision (S1), not an oversight; flag disagreement in your report
  rather than changing it.
- FR-3's `cfg_udp_port` gap, `T26_soak`'s actual size, §9's `STATUS` bits
  7:5 — separate, already-tracked gaps (master spec §0), unrelated to
  this contract.
- `docs/contracts/ml_policy_per_symbol.md` — a separate contract, touches
  `ml_policy.v`/`risk_engine.v`/`tob_top.v`; no overlap with this one's
  files, safe to implement in either order or in parallel.
- Adding a `csr_frame_pulse`-style new output port on `md_parser.v` — not
  needed (S1 explains why `csr_block.v` doesn't need one), don't add
  unused ports.

### S6. Acceptance criteria

**Yours to verify (iverilog + Python):**
- `rtl/md_parser.v` compiles under `iverilog -g2001 -Wall`, no new
  warnings, no inferred latches.
- `tb_md_parser` passes, including a NEW directed case proving `0x20`/
  `0x21` frames produce `err_msg_type=0`/`msg_valid=0` (both, simultaneously
  — a CSR frame is invisible to both signals, not merely "not an error")
  while every currently-tested genuinely-undefined `msg_type` still
  correctly fires `err_msg_type=1`.
- `tb_seq_monitor`: re-run as-is first (should be unaffected, since this
  fix is entirely upstream of it) to confirm the "no RTL change needed
  here" claim in S1 holds in practice, not just in your own re-reading.
- `python sim/test_golden_model_handcase.py` (or wherever the existing
  hand-case regression lives) passes; add a new hand-case proving a CSR
  write/read-request message produces zero counter effect through
  `process_message` (mirroring the new `tb_md_parser` case above).
- `tb_top` passes, including the new S4 invariant assertions — and
  distinctly: confirm invariant 1 specifically holds using REAL numbers
  (not just "no mismatch fired") by printing the actual computed
  left/right sides in your report, so it's checkable that this isn't
  passing vacuously.
- Full `bash scripts/run_sim.sh` (not `RUN_SIM_FAST=1`) passes.
- `git diff` on every file not listed in S1-S4 (in particular
  `csr_block.v`, `seq_monitor.v`, `frame_classifier.v`, every risk/ML/
  signal module) is empty.
- **Mutation check**: revert just the `md_parser.v` `is_csr_type`
  exclusion on a scratch copy and confirm the new S4 invariant 1
  assertion actually fails (not just the pre-existing counter-mismatch
  loop) — the whole point of adding a real assertion is that it catches
  this bug class even if a future golden-model change accidentally
  re-introduces the same mistake on both sides at once; this mutation
  check is the only way to confirm the assertion, not just the fix,
  actually works.

**Mine to verify (independent re-check per this project's established
workflow):** re-diff every changed file, re-compile and re-run every
testbench myself, and re-run the mutation check you report.
