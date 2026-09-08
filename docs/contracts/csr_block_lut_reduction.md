## Contract: reduce `csr_block.v`'s LUT footprint (lowest priority of the four contracts in this batch — exploratory, correctness-gated)

### Status: ready to hand off, but explicitly the lowest-priority / most
optional item of this review pass. Found by an external review (a second
Opus-model pass over the repo); the underlying data point (`csr_block.v`
is the single largest hand-written LUT contributor, 2,335 LUTs / 11.2% of
the part) is already independently measured and recorded
(`docs/design_decisions.md` D41). This contract is about the FIX, which
D41 left as an open question — this is exploratory optimization work, not
a correctness bug, and should be picked up only after
`ml_policy_per_symbol.md`, `csr_ingress_separation.md`, and
`fr3_udp_port_match.md` (all correctness fixes) are done.

### S0. The idea, and the correctness trap in the obvious version of it

`csr_block.v` currently has ~32 independent 32-bit saturating counters
(`rtl/csr_block.v` lines ~344-378), each with its OWN dedicated
comparator + adder in one big always-block (lines ~483-522: `if
(gate_kill_fired) cnt_rej_kill <= satinc(cnt_rej_kill); if
(gate_size_fired) cnt_rej_size <= satinc(cnt_rej_size); ...`, one line
per counter), plus a flat ~60-way combinational read mux (lines ~570-650,
one `case` arm per register/counter address) for CSR reads. D41's
hypothesis: replace the 32 independent registers+incrementers with a
small shared RAM (distributed RAM, one read-modify-write incrementer)
addressed by "which counter fired this cycle," since the pulses are
"sparse and near-mutually-exclusive" — plus pipeline the read mux.

**The trap: "near-mutually-exclusive" is not true for every counter, and
getting this wrong silently drops real counts.** Confirmed by reading the
actual trigger conditions, not assumed:

- **The nine `cnt_rej_*` gate counters** (`cnt_rej_kill` through
  `cnt_rej_ml`) are driven from `risk_engine.v`'s `gate_*_fired` outputs,
  ALL registered in the SAME always-block on the SAME cycle
  (`risk_engine.v`'s stage-2 decision register, S2.5 of
  `docs/contracts/risk_engine_gate_pipeline_fix.md`). **FR-43 explicitly
  requires multiple gates to fire simultaneously and every one of their
  counters to increment** — `tb/tb_risk_engine.v`'s own block G / T21
  (kill + oversized qty on the same intent) is a real, currently-passing
  test proving this happens. A shared single-write-port incrementer bank
  cannot serve two simultaneous increments in the same cycle without
  either a second port, a small internal queue, or silently dropping one
  of them.
- **The four ML counters** (`cnt_ml_events`/`cnt_ml_adverse`/
  `cnt_ml_benign`/`cnt_ml_safe_forced`) have the same problem:
  `ml_policy.v`'s single always-block sets `ml_event_valid` alongside
  EITHER `ml_adverse_pulse` OR `ml_benign_pulse` every event (2-way
  simultaneity, every single event, not an edge case), and in the
  fail-safe-forced case ALSO sets `ml_safe_forced_pulse` at the same time
  (3-way simultaneity). This is normal, frequent operation, not a corner
  case — merging these naively would break `cnt_ml_events` on every
  single ML event.

**Rule for this contract: the nine `cnt_rej_*` counters and the four ML
counters (13 total) stay as individual dedicated registers/incrementers,
unconditionally.** Do not attempt to fold them into a shared bank — the
LUT/FF cost of correctly handling their proven simultaneity (a real
multi-write structure, or per-cycle serialization logic with its own
queue and the testbench burden of proving the queue never overflows
under FR-42's "single cycle" gate evaluation) is not worth it for a
"minor" cleanup item, and the risk of a subtle undercounting regression
that only shows up in a specific multi-gate scenario is exactly the kind
of bug this project's own verification discipline (D45, this session)
exists to prevent.

### S1. In scope: a shared-incrementer bank for the REMAINING ~19 counters — provisionally grouped, MUST be independently re-verified

The other counters (`cnt_frames_rx`, `cnt_msgs_rx`, `cnt_msgs_filtered`,
`cnt_msgs_accepted`, the eight `err_*` counters, `cnt_seq_gap`,
`cnt_seq_dup`, `cnt_crossed`, `cnt_book_clear`, `cnt_trades`,
`cnt_heartbeats`, `cnt_signal_buy`, `cnt_signal_sell`, `cnt_orders_tx`,
`cnt_order_overflow`) are, on a first read of their trigger conditions
and the modules that drive them, one-per-message-event and structurally
plausible candidates for sharing — but **"plausible on a read of the
code" is not the bar this project uses (see `docs/design_decisions.md`
D45's mutation-testing discipline, same session).** Before merging ANY
two counters into a shared bank:

1. Identify every counter's exact trigger signal and the module/pipeline
   stage that drives it.
2. For every PAIR of counters you intend to share a write port between,
   either prove from the RTL that their trigger conditions are
   structurally exclusive (e.g. `err_msg_type`/`err_flags` are proven
   exclusive today by `md_parser.v`'s own `type_ok`/`flags_ok` gating —
   cite the exact lines), OR write a targeted testbench case that tries
   to force both high on the same cycle and confirms the real RTL never
   allows it (not merely "the test I wrote didn't trigger it" — construct
   the case adversarially, the way `tb_risk_engine.v`'s T21/P1-P4 cases
   or `tb_ml_policy.v`'s P1-P3 cases do for their respective modules).
3. Any pair you cannot prove exclusive stays un-merged. A smaller LUT
   recovery with zero correctness risk is a strictly better outcome than
   D41's "~1,500+ LUTs" estimate with a latent undercounting bug —
   **do not chase the estimate at the expense of the rule in S0.**

`lat_min`/`lat_max`/`lat_last` are NOT saturating counters (min/max logic,
not increment) — leave them exactly as they are, not part of this
refactor.

### S2. Design shape (once S1's grouping is verified)

A small register-file/distributed-RAM bank (`N` entries, `N` = however
many counters survive S1's verification), one shared 32-bit
read-modify-write incrementer: on a cycle where exactly one bank member's
trigger pulse is high, read that entry, add 1 (or `satadd` for
`cnt_seq_gap`, which is D44's amount-based increment — keep that as a
special case, same as today, since it isn't a plain +1), write it back.
Address the entry either via a priority encoder over the (now-proven
mutually exclusive) pulse vector, or a small combinational lookup —
whichever is simpler given how many members S1's verification leaves you
with. CSR reads of these counters now need to read the SAME distributed
RAM by address instead of a plain register — update the read-mux arms for
every migrated counter accordingly (S3 covers the read side more
generally).

### S3. Pipelined read mux (independent of S1/S2 — do this regardless of how many counters end up shared)

The current ~60-way combinational `case` (config registers 0x00-0x9C plus
every counter 0xA0+) can be split into two stages: register `csr_addr`
(or the relevant high bits of it) one cycle, then resolve the case on the
registered address the next cycle. This is a pure timing/LUT change on
the READ path — it does not touch counter correctness at all, and is
lower-risk than S1/S2. Confirm against `csr_block.v`'s existing
`resp_start`/`resp_busy` read-response protocol (D19) that CSR reads
already tolerate multi-cycle latency before the response frame is built
(they should — a CSR response is already a serialized, multi-cycle TX
process, not a same-cycle combinational return) — if you find a place
that assumes same-cycle `rd32` validity, say so explicitly rather than
silently working around it.

### S4. Explicitly out of scope

- The nine `cnt_rej_*` gate counters and the four ML counters (S0) —
  never merge these into a shared incrementer in this contract.
- `lat_min`/`lat_max`/`lat_last` — different logic shape, not a plain
  increment, not touched here.
- Any change to what triggers a counter, what it counts, or its register
  address/width — this contract is purely an internal implementation
  change; every counter's externally observable value and address must
  be bit-identical to today's behavior for every possible input sequence.
- `docs/contracts/csr_ingress_separation.md`'s fix (which changes WHEN
  `cnt_msgs_rx`/`err_msg_type` increment, not how they're implemented
  internally) — implement that contract first or independently; this
  contract should be written against whichever `csr_block.v` state it
  lands on, and must not reintroduce the CSR-frame-counting bug that
  contract fixes.

### S5. Acceptance criteria

**Yours to verify (iverilog):**
- `rtl/csr_block.v` compiles under `iverilog -g2001 -Wall`, no new
  warnings, no inferred latches.
- `tb_csr_block.v` passes UNMODIFIED in its externally-observable
  behavior — every counter reads back the exact same value for the exact
  same stimulus as before this contract (this is the real acceptance
  bar: this contract must be invisible from the CSR interface's own
  point of view, only the internal implementation changes). Extend it
  with the S1 exclusivity-proof cases for every group you merge.
- `tb_risk_engine.v`'s T21 (multi-gate) and `tb_ml_policy.v`'s
  fail-safe-forced cases still pass unchanged, proving S0's carve-out
  held (these tests exercise `risk_engine.v`/`ml_policy.v` directly, not
  `csr_block.v`, but re-run them anyway as a sanity check that nothing
  about the counter INPUTS changed).
- `tb_tob_top`/`tb_top`: full regression, including a case that forces at
  least one of the confirmed real simultaneity scenarios (multi-gate
  reject, ML fail-safe-forced) through the full integrated design and
  confirms every affected counter's final value is still correct.
- Full `bash scripts/run_sim.sh` passes.
- In your report: state exactly which counters you merged, which you
  left individual and why (citing S1's exclusivity proof for each merged
  group), and report the actual LUT delta if you have Vivado access — if
  not, say so and I'll measure it (S6).
- **Mutation check**: on a scratch copy, force two members of one merged
  bank to pulse on the same cycle (bypassing whatever your RTL does to
  prevent it) and confirm your new testbench cases actually catch the
  resulting miscount — proving the verification added here would have
  caught the exact bug class S0 warns about, not just exercised the
  happy path.

**Mine to verify (Vivado + independent re-check):**
- Fresh `synth_design` → `opt_design` → `place_design` → `route_design`
  on `tob_top` at `xc7a35tfgg484-2`, 125 MHz.
- `report_utilization -hierarchical -hierarchical_depth 2` on the routed
  netlist, compared against D41's baseline (2,335 LUTs / 2,253 FFs for
  `csr_block.v`) — report the actual delta, whatever it turns out to be.
  A smaller-than-estimated recovery that is fully correct is an
  acceptable, honest outcome; report it as such rather than as a
  shortfall.
- Confirm post-route WNS/WHS are still ≥ the pre-this-contract baseline
  (`results/timing.md`) — a distributed-RAM read-modify-write structure
  can introduce new timing paths; if timing regresses, that's a real
  finding to report, not something to route around silently.
- Independent re-diff and re-compile of every changed file, re-run of
  the reported mutation check.
