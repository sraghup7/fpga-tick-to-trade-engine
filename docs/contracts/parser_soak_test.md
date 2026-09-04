# Contract: 1,000,000-message zero-loss soak test for the parser stage

Status: ready to hand off, **but only after** `rtl/frame_classifier.v` and
`rtl/md_parser.v` both exist and pass their own contracts'
(`docs/contracts/frame_classifier.md`, `docs/contracts/md_parser.md`)
acceptance criteria. This task chains those two already-finished modules
together and stress-tests them at volume; it does not add any new RTL.
Self-contained otherwise.

## 1. Background (why this exists)

This project's S2 milestone gate (its Ethernet market-data parser stage)
requires two things: the directed tests already covered by
`tb/tb_frame_classifier.v` and `tb/tb_md_parser.v`, **and** a demonstration
that the parser chain (`frame_classifier.v → md_parser.v`) processes
1,000,000 well-formed messages back-to-back with **zero loss** — no message
silently dropped, no spurious error pulse, no field corruption. That's a
throughput/conservation property distinct from the directed correctness
tests, and this contract is only that.

This is Python + Verilog work, not new module design: a small Python script
generates the stimulus (reusing existing project code, not reimplementing
anything), and a Verilog testbench streams it through both existing DUTs
and checks the invariant.

## 2. What you're building

**Files:**
- `sim/gen_soak_vectors.py` (new)
- `tb/tb_parser_soak.v` (new)

### 2.1 `sim/gen_soak_vectors.py`

This project already has `sim/feed_gen.py`, which has a function
`iter_scenario(scenario, count, seed)` — call it with
`scenario="normal"`, which (per that file's own code) generates exactly one
16-byte, well-formed quote message per frame, for `count` frames. **Do not
modify `feed_gen.py` or reimplement message generation** — this script's
only job is to call that existing function and write its output in a
different (simpler) file format that a Verilog testbench can load quickly.

Write a small script that:

1. Takes `--count` (default 1,000,000), `--seed` (required), `--out`
   (required, output file path) as command-line arguments.
2. Calls `feed_gen.iter_scenario("normal", count, seed)`.
3. For each generated frame (each is exactly 16 bytes — assert this and
   fail loudly if it's ever not true, don't silently handle a different
   size), writes each of its 16 bytes as one two-hex-digit line (e.g.
   `4a`), suitable for Verilog's `$readmemh` to load directly. Write one
   `//`-prefixed header comment line at the top of the file recording the
   scenario/count/seed used (`$readmemh` skips `//` comments; it does
   **not** skip `#` comments, unlike `feed_gen.py`'s own file format — make
   sure you use `//`, not `#`).
4. Prints a one-line summary when done (message count and total byte count
   written), so a human running it can sanity-check the numbers before the
   (slow) Verilog run.

Run it from inside `sim/` (so its `import feed_gen` resolves the same way
`sim/feed_gen.py`'s own existing imports do), e.g.:

```bash
cd sim
python gen_soak_vectors.py --count 1000000 --seed 7 --out ../tb/stimulus/s2_soak.mem
```

This should produce a file with 1,000,001 lines (1 header comment +
16,000,000 byte lines) — confirm the line count matches before moving on to
the Verilog side.

The generated `.mem` file is large (tens of MB) and fully regenerable from
this script — add `tb/stimulus/*.mem` to the repo's `.gitignore` (check
what's already there first and place it near the other generated-artifact
patterns) rather than committing the file itself. Only `gen_soak_vectors.py`
is checked in.

### 2.2 `tb/tb_parser_soak.v`

Instantiate `frame_classifier` and `md_parser` chained exactly as they sit
in the real datapath (`frame_classifier`'s `out_data`/`out_valid` feed
`md_parser`'s `in_data`/`in_valid`). Load the `.mem` file generated above
into a Verilog memory array with `$readmemh` at the start of simulation.

For each of the 1,000,000 messages, in order:

1. Pulse `frame_start` for one cycle with `rx_len = 16` (every message in
   this generated set is its own 16-byte frame, by construction of the
   "normal" scenario — see §2.1).
2. Stream that message's 16 bytes on `rx_data`/`rx_valid` into
   `frame_classifier`.
3. Leave a short gap (a couple of idle cycles is enough — this is a
   throughput/conservation check, not a minimum-inter-frame-gap timing
   test) before the next frame's `frame_start`.

While this runs, count, across the whole run:

- Every `msg_valid` pulse out of `md_parser` (should end at exactly
  1,000,000 — this is the headline "zero loss" number).
- Every `err_frame_len`, `err_msg_type`, and `err_flags` pulse (should all
  end at exactly 0 — the "normal" scenario never generates a malformed
  frame or message; any nonzero count here means something is being
  misclassified, not that the stimulus is bad).

Additionally, **spot-check field correctness** on a regular interval (e.g.
every 10,000th decoded message, not all 1,000,000 — checking all of them
individually is unnecessary given the directed tests already prove
byte-for-byte correctness at small scale; this is about catching something
that only shows up at volume, like a counter wrapping or misaligning after
many messages): for the spot-checked message, compare its decoded
`msg_type`/`msg_symbol_id`/`msg_side`/`msg_flags`/`msg_price`/
`msg_quantity`/`msg_seq_num` fields directly against the 16 raw bytes at
that message's known offset in the same memory array you loaded via
`$readmemh` (offset = message index × 16 bytes; the field layout is
`docs/contracts/md_parser.md` §2.2 — you don't need a second Python-side
"expected values" file, the raw input bytes already are ground truth since
the wire format is self-describing at fixed offsets).

At the end of the run, print a single `PASS`/`FAIL` line (this project's
convention): `PASS` only if all of (a) msg_valid count == 1,000,000, (b) all
three error-pulse counts == 0, (c) every spot-checked message's fields
matched.

This is a genuinely long-running simulation (16,000,000+ byte transfers).
Allow it several minutes to run; don't reduce the message count to make it
faster — 1,000,000 is the actual requirement, and a run that only proves
zero loss over (say) 10,000 messages doesn't satisfy it. If it turns out to
be impractically slow (say, over 10 minutes on ordinary hardware), report
that back rather than silently shrinking the test.

## 3. Acceptance criteria

- [ ] `python sim/gen_soak_vectors.py --count 1000000 --seed <any> --out tb/stimulus/s2_soak.mem` runs without error and reports 1,000,000 messages / 16,000,000 bytes written.
- [ ] `tb/stimulus/*.mem` is gitignored; only `sim/gen_soak_vectors.py` is committed.
- [ ] `iverilog -g2001 -Wall -o parser_soak_tb.vvp rtl/frame_classifier.v rtl/md_parser.v tb/tb_parser_soak.v` compiles with zero warnings.
- [ ] `vvp parser_soak_tb.vvp` prints a final line showing exactly 1,000,000 messages decoded, zero error pulses of any kind, and zero spot-check mismatches, followed by `PASS`.
- [ ] `sim/feed_gen.py` is not modified.
- [ ] The Verilog testbench does not reimplement message-field validation
      logic from scratch — it compares against the raw loaded bytes
      directly (§2.2), not against a hand-written expectation table.

## 4. Explicitly out of scope

- Generating or testing any *malformed* traffic at volume — that's already
  covered by the directed tests in `tb/tb_frame_classifier.v` (bad lengths)
  and `tb/tb_md_parser.v` (bad `msg_type`/`flags`); this soak test is
  specifically about the clean, high-volume path.
- Minimum inter-frame-gap / line-rate timing precision — a short fixed idle
  gap between frames is fine; this isn't a "cycles-per-frame" performance
  benchmark.
- Anything about `symbol_filter.v`, `seq_monitor.v`, book state, signal, or
  risk gates — this test stops at `md_parser.v`'s output.
- Wiring either module into `rtl/tob_top.v` — that's a later, separate
  integration step, not part of this contract.
