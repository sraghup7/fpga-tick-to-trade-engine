## Contract: build `tb/tb_top.v` — the full-system integration test (T26_soak, master spec §11.4/§13)

### Status: ready to hand off. New file(s) only — no existing RTL or testbench is modified. Runs in PARALLEL with a separate contract (`ml_policy_align_fix.md`) and a separate Claude-side task (spec-text only) — see "Scope boundary" at the end.

**Why this matters, concretely, not just as a checklist item:** D30 found two real bugs in `sim/golden_model.py`'s counter bookkeeping (a double-incremented `cnt_rej_ml`, and ML-event counters that silently never fired for a whole class of messages) that sat completely undetected because nothing ever drove the full system and compared every counter against a reference. D28 found `risk_engine.v` reading stale book state across an alignment boundary — again, something a real end-to-end soak with interleaved same-slot traffic would have caught mechanically instead of needing an external audit to spot it by inspection. This file is the test that makes the *next* version of either bug class fail loudly and automatically, per master spec §11.4's own `T26_soak` row: *"1,000,000 random messages, full output+counter comparison."*

Read `docs/design_decisions.md` D28 and D30 before starting, for the exact shape of bug this test exists to catch.

---

### S0. What you're building, in one sentence

A self-checking Verilog testbench that instantiates the **real** `tob_top.v` (with the same behavioral MAC/PHY stand-ins `tb_tob_top.v` already uses), streams a generated message feed through it, and checks **every order-record byte and every counter** against `sim/golden_model.py` (deterministic path) + `sim/ml_golden.py` (ML verdict) — not a re-test of any single module's own behavior (every module already has one), but a check that the *whole wired system* produces the *same answer* an independent reference implementation does, byte-for-byte and counter-for-counter, at real scale.

---

### S1. Architecture — reuse two existing patterns, do not invent new ones

#### S1.1 Driving the DUT: copy `tb/tb_tob_top.v`'s approach

Read `tb/tb_tob_top.v` in full first — its header explains exactly why: the real `rtl/tob_top.v` is instantiated as DUT, but its two vendor leaf modules (`mac_top.v`, `util_gmii_to_rgmii.v`) are swapped for `tb/sim_models/tob_top_sim_leaves.v`'s behavioral stand-ins (bound by name at compile time — no `rtl/vendor/` code needs simulating real Ethernet frames). Stimulus is driven at `mac_top.v`'s own UDP boundary (`udp_rec_data_valid`/`udp_rec_data_length`/`udp_rec_ram_rdata` in, `ram_wr_data`/`udp_tx_req`/`mac_send_end` out) via force/release on the stand-in's scalar test hooks — this **is** the master spec's "GMII-side interface" (§13's own description of `tb_top.v`), one level above the raw RGMII pins, and is what makes streaming thousands of messages tractable in simulation.

Reuse this exact mechanism. Do not attempt to drive real RGMII bit-level signals.

#### S1.2 Streaming stimulus at scale: copy `tb/tb_parser_soak.v`'s approach

Read `tb/tb_parser_soak.v` and `sim/gen_soak_vectors.py` in full. The pattern: a Python generator produces a flat byte stream, written to `tb/stimulus/*.mem` ($readmemh format, gitignored — regenerable, never committed), which the testbench loads once via `$readmemh` and streams byte-by-byte with a small inter-frame gap. Reuse this exact mechanism for driving frames into the UDP boundary from S1.1, and for loading the expected-output data described in S2.

---

### S2. New Python generator (`sim/gen_top_soak_vectors.py`)

This does not exist yet — you are writing it. It is the one piece of real integration work neither existing generator does: **wiring `sim/feed_gen.py`'s message generation through BOTH `sim/ml_golden.py` (to decide `adverse_risk` per message, the fallback classifier's real behavior) AND `sim/golden_model.py` (to get the fully gated order output + final counters)**, since `golden_model.py`'s own `process_message` takes `adverse_risk` as an explicit argument by design (D31: it does not compute ML itself) — nothing currently combines the two into one full-system reference driver.

Produce three output files per run (mirroring `gen_soak_vectors.py`'s `//`-comment header style, all under `tb/stimulus/`, all gitignored):

1. **Input stream** (`tb_top_soak_in.mem`): the raw frame bytes, exactly like `gen_soak_vectors.py` produces today — reuse `feed_gen.py`'s scenarios (mix `_normal`/`_crossed`/`_gaps`/`_trigger` for realistic coverage, not just `_normal` alone; unlike the parser-only soak, this test's whole point is exercising interleaved, same-slot, signal-triggering traffic, since that's what D28/D30's bugs actually needed to be caught).
2. **Expected order-record stream** (`tb_top_soak_expected_orders.mem`): every `OrderRecord` `golden_model.py` produces, in order, encoded via `OrderRecord.encode()` (already exists, 16 bytes, big-endian, matches the real wire format exactly) — one hex byte per line, same format as input.
3. **Expected final counters** (`tb_top_soak_expected_counters.txt`): every counter in `sim/golden_model.py`'s `Counters.as_dict()`, one `name=value` line, after processing the entire stream. **Exclude `lat_min`/`lat_max`/`lat_last`/histogram from bit-exact comparison** — see S3.3 for why and what to check instead.

CLI shape, matching `gen_soak_vectors.py`'s existing convention:

```
python sim/gen_top_soak_vectors.py --count 10000 --seed 7 --out-prefix tb/stimulus/tb_top_soak
```

---

### S3. The testbench (`tb/tb_top.v`)

#### S3.1 Structure

- Instantiate DUT + sim-model leaves exactly as `tb_tob_top.v` does (S1.1). Reuse its clock/reset setup (`sys_clk`/`rgmii_rxc`, `PHY_RESET_HOLD_CYCLES` shortened for simulation, wait for `dut.engine_rst_n`).
- Load `tb_top_soak_in.mem` and `tb_top_soak_expected_orders.mem` via `$readmemh`; load `tb_top_soak_expected_counters.txt` via `$fscanf` (master spec §13's own description explicitly calls out both mechanisms for this file).
- Stream the input frames into the UDP boundary (S1.1's force/release pattern), one message-frame at a time, matching whatever inter-frame timing `feed_gen.py`'s scenarios already encode (do not invent new spacing).
- Capture every TX-boundary output frame (same boundary `tb_tob_top.v`'s T1 case already reads a single order from) into a queue as it arrives.

#### S3.2 Order-record comparison

For each captured 16-byte output frame, compare byte-for-byte against the next entry in the expected-orders stream, **except `latency_cyc` (the low 16 bits)** — see S3.3. On any mismatch: print the order index, expected vs. actual for every field (`msg_type`/`symbol_id`/`side`/`reject_reason`/`price`/`quantity`/`trigger_seq`), matching master spec §13's own requirement ("prints message index, expected, actual, and book state, then fails"). Also assert the two streams have the same **length** (a dropped or extra order is itself a real bug, and would otherwise desync every later comparison silently).

#### S3.3 Latency: check the invariant, not a predicted number

`golden_model.py` cannot independently predict the RTL's exact cycle-accurate `latency_cyc` (that number is a hardware timing artifact, not something a behavioral reference computes from first principles). Do not try to make the Python side produce it. Instead, exercise master spec NFR-1/2's own invariant directly (the same one `T25_latency` already checks in isolation): collect every captured order's `latency_cyc`, and assert **all of them are identical** (single-occupancy latency histogram — max == min == every value, by construction of the fixed-depth pipeline). A single outlier is a real bug (something took a different number of cycles for one message) and must fail loudly with the offending order's index and its differing value.

#### S3.4 Counter comparison

At the end of the run, read back every counter via the CSR register interface — reuse `tb_tob_top.v`'s T2 case as the exact pattern (write/read round trip through the same shared tap). Compare each against `tb_top_soak_expected_counters.txt`'s corresponding value, one line per mismatch (`counter_name: expected=X actual=Y`), not just a single aggregate pass/fail — a future regression should tell you *which* counter drifted, exactly the information D30's own bugs needed to be found quickly instead of by external audit.

#### S3.5 Directed cases first, soak second

Master spec §11.4 lists `T26_soak` as one row, but do not write only a soak — start with a handful of small, fast, directed cases (reuse `gen_top_soak_vectors.py` with `--count` in the tens, not thousands) covering the specific bug classes D28/D30 exist because of:

- Interleaved same-slot traffic during the ML/signal alignment window (the exact D28 pattern — a triggering signal followed immediately by more same-slot traffic before the risk/ML decision lands).
- A tight-spread book that produces `cnt_ml_events` but no `signal_fired` (the exact D30 pattern — an ML event with no corresponding deterministic signal).
- At least one message on every reject-reason path (0x01–0x09) so every `cnt_rej_*` counter is provably exercised at least once, not just left at its reset value where a bug could hide.

Only after these pass, move to a larger randomized soak.

---

### S4. Acceptance criteria — staged, report progress at each stage rather than going silent until the end

1. **Directed cases (S3.5) pass**, iverilog, byte-exact order comparison + counter comparison both clean.
2. **A randomized soak at `--count 1000` passes** (order stream, counters, and the latency invariant from S3.3).
3. **A randomized soak at `--count 10000` passes.** This is the minimum bar for calling this contract done — report at this point even if you continue toward the stretch goal below.
4. **Stretch goal, not a hard requirement for this contract**: scale toward the master spec's literal `T26_soak` target of 1,000,000 messages (matching `tb_parser_soak.v`'s own scale). If runtime or memory becomes impractical at that scale, report exactly where it stopped being practical and why, rather than silently truncating — that's real information for the next iteration, not a failure to hide.
5. `rtl/` and every existing `tb/*.v` file are **untouched** — this contract only adds `tb/tb_top.v` and `sim/gen_top_soak_vectors.py` (plus gitignored `tb/stimulus/tb_top_soak_*` outputs).
6. Full existing regression (`bash scripts/run_sim.sh`) still passes unchanged — confirms nothing was accidentally modified.
7. In your report: the exact message count reached, a summary of what the directed cases covered, and confirmation that a deliberately-broken copy of `sim/golden_model.py` (e.g., reintroduce D30's own double-increment bug on a scratch copy) makes this new test fail — proving the counter comparison in S3.4 is a real, discriminating check and not a silent no-op.

**Mine to verify (Vivado):** none needed — this is a testbench-only addition, no RTL changes, no timing impact.

---

### Scope boundary — read this, another contract and another task are running in parallel

- **`ml_policy.v`'s D28-class fix is a SEPARATE contract** (`docs/contracts/ml_policy_align_fix.md`), possibly running at the same time as this one. It adds two new ports to `ml_policy.v` and two new port connections in `tob_top.v`'s `u_policy` instantiation — it does **not** change `tob_top.v`'s own top-level port list, so this contract's DUT instantiation (which only touches `tob_top.v`'s external ports, per S1.1) is unaffected regardless of which contract lands first. No coordination needed.
- **NFR-7 and the `cnt_rej_ml` reduce-mode spec wording are being handled separately** (`fpga_tick_to_trade_master_spec.md`, `docs/design_decisions.md` only) — do not touch either file as part of this contract.
- Do not touch `docs/design_decisions.md` — a D-entry documenting this will be written after independent verification, same as every prior contract in this project.

### Explicitly out of scope

- Any RTL change of any kind.
- Modifying `tb/tb_tob_top.v`, `tb/tb_parser_soak.v`, `sim/gen_soak_vectors.py`, `sim/golden_model.py`, or `sim/ml_golden.py` — read-only references for this contract, reuse their patterns, don't edit them.
- Reproducing the full `T27`–`T29` feature/ML directed-test coverage — those already exist in `tb_feature_extractor.v`/`tb_ml_classifier_wrap.v`/etc.; this file's job is end-to-end wiring + counter conservation at scale, not re-testing any single module's own math.
