# Contract: `rtl/seq_monitor.v`

Status: ready to hand off. Self-contained. **Can be implemented in parallel
with `docs/contracts/symbol_filter.md`** — the two modules do not depend on
each other; both are parallel siblings wired directly off `rtl/md_parser.v`
(S2, committed — see §1 for why this matters more than it sounds).

## 1. Background (why this exists, and the architecture fact its interface depends on)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain) parsing a synthetic market-data feed. `seq_monitor.v` is the
master spec's gap/duplicate detector (§3.1 block `[F]`, FR-10/FR-11/FR-12):
every message on the feed carries a `seq_num`, and this module tracks
whether the feed's sequence is intact — a jump forward means lost messages
(gap), a repeat or backward jump means a duplicate/reorder.

**FR-10 says sequence tracking is a "per feed" property, not a per-watched-
symbol one — this module must see every message `md_parser.v` completes,
including ones on symbols nobody is watching, and including ones that
`md_parser.v` itself dropped for a bad `msg_type` or reserved `flags` bit.**
This is not a minor implementation nicety; it was a real, caught bug
(`sim/test_golden_model_handcase.py`'s own module docstring, and
`docs/design_decisions.md` D12): if sequence tracking only sees messages
that already passed a symbol filter or a type/flags check, an
unwatched-symbol (or type-invalid) message silently consumes a `seq_num`
slot without this module's expected-sequence counter ever advancing, and
the very next legitimate message looks like it arrived after a gap that
never happened.

**Consequence for this module's interface:** it does **not** sit
downstream of `symbol_filter.v` and does **not** only look at
`msg_valid`-gated messages. It takes `md_parser.v`'s three per-message
pulses directly — `msg_valid`, `err_msg_type`, `err_flags` (exactly one of
which fires per completed message, per `docs/contracts/md_parser.md`) —
and treats their logical OR as "a message just completed, its
`msg_seq_num`/`msg_flags` fields are valid this cycle," regardless of which
of the three actually fired. `md_parser.v`'s field registers (`msg_seq_num`
included) are unconditionally latched every completed message, valid or
not — confirmed by reading `rtl/md_parser.v` directly, not assumed — so
this is a real, available signal, not something that needs a change to
`md_parser.v` itself.

`symbol_filter.v` (`docs/contracts/symbol_filter.md`) is this module's
sibling, not its input: both take `md_parser.v`'s outputs directly and in
parallel, and `tob_engine.v` (`docs/contracts/tob_engine.md` §1) is the
module that combines `symbol_filter.v`'s "watched" verdict with this
module's "not a duplicate" verdict to decide whether to actually touch book
state.

## 2. What you're building

**File:** `rtl/seq_monitor.v`
**Testbench:** `tb/tb_seq_monitor.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module seq_monitor (
    input  wire         clk,
    input  wire         rst_n,   // active-low; match the reset style
                                  // already used elsewhere in this repo

    // from md_parser.v -- ALL three, see S1: exactly one pulses per
    // completed message, and this module reacts to any of the three
    input  wire         msg_valid,
    input  wire         err_msg_type,
    input  wire         err_flags,
    input  wire [31:0]  msg_seq_num,
    input  wire [7:0]   msg_flags,    // only bit 1 (FLAG_SNAPSHOT) is read

    // config: explicit seq-gap clear (S9 CTRL.bit3). Direct port, standing
    // in for csr_block.v, which does not exist yet (same pattern as
    // symbol_filter.v's cfg_symbol_* ports) -- one-cycle pulse clears the
    // sticky seq_gap output below on the next clock edge.
    input  wire         cfg_seq_gap_clear,

    // status: one-cycle pulse, coincides with the message-complete cycle
    // that turned out to be a duplicate/reorder (FR-11). tob_engine.v
    // treats this pulse directly as "do not apply this message to book
    // state" -- no separate "is_dup" signal, this pulse IS that signal.
    output wire         err_seq_dup,

    // FR-10: the gap amount for THIS message (0 if no gap), and a pulse
    // marking that a gap was detected this cycle. The counter that
    // accumulates this into cnt_seq_gap lives in a later CSR/counters
    // block and must add seq_gap_amount, not just increment by 1 -- see
    // S2.3.
    output wire [31:0]  seq_gap_amount,
    output wire         seq_gap_pulse,

    // FR-10/FR-12: sticky status bit (level, not pulse) -- set on any
    // detected gap, cleared only by a flags.snapshot=1 message or
    // cfg_seq_gap_clear.
    output wire         seq_gap
);
```

### 2.2 Expected-sequence tracking (FR-10/FR-11)

Internal state: one 32-bit `expected_seq` register, plus a 1-bit `seen_first`
register (both reset to 0 on `rst_n`).

On a cycle where `msg_valid | err_msg_type | err_flags` is high (call this
`msg_complete` — you can name your internal signal whatever you like, but
build it from exactly this OR):

1. **If `seen_first` is 0** (the very first message this module has ever
   seen since reset): set `expected_seq <= msg_seq_num + 1`, set
   `seen_first <= 1`, and do **not** treat this message as a gap or a
   duplicate regardless of its `msg_seq_num` value — there is no prior
   expectation to compare against yet. `err_seq_dup`, `seq_gap_pulse`, and
   `seq_gap_amount` are all 0 for this specific message.
2. **Otherwise, compare `msg_seq_num` against the current `expected_seq`**
   (plain unsigned 32-bit comparison/subtraction — this project does not
   need to handle `seq_num` wraparound, same assumption `sim/golden_model.py`
   makes):
   - `msg_seq_num < expected_seq`: **duplicate/reorder**. Pulse
     `err_seq_dup` for this cycle. Do **not** advance `expected_seq`.
   - `msg_seq_num == expected_seq`: exact match. `expected_seq <=
     msg_seq_num + 1`. No pulses.
   - `msg_seq_num > expected_seq`: **gap**. `seq_gap_amount <=
     msg_seq_num - expected_seq`, pulse `seq_gap_pulse` for this cycle, set
     the sticky `seq_gap` register to 1, and still advance `expected_seq
     <= msg_seq_num + 1` (a gap does not stop the sequence from moving
     forward — the next expected message is the one right after whatever
     just arrived, not the one that was skipped).

On a cycle where `msg_complete` is low, none of `err_seq_dup`,
`seq_gap_pulse`, `seq_gap_amount` fire/change, and `expected_seq`/`seen_first`
hold.

### 2.3 Snapshot clearing (FR-12) — runs on every completed message, unconditionally

Independently of the gap/duplicate logic in §2.2 (both apply on the same
`msg_complete` cycle, and both can be true at once — e.g. a duplicate
message that also happens to carry `flags.snapshot=1`; that combination is
not a contradiction and both effects apply): if `msg_complete` is high and
`msg_flags[1]` (the snapshot bit) is set, clear the sticky `seq_gap`
register on the next clock edge, regardless of whether this particular
message was itself a gap, a duplicate, or a clean exact match.

`cfg_seq_gap_clear`'s one-cycle pulse clears `seq_gap` the same way,
independently of any message activity — if it's asserted on a cycle where
`msg_complete` also fires and that message's own logic would otherwise set
`seq_gap` to 1 (a fresh gap detected the same cycle as an explicit clear
request), the clear does not need to "win" or "lose" against the new gap in
any specific documented way — this combination isn't expected in real
operation (a CSR write and live traffic landing on the exact same cycle),
so either outcome is acceptable and the testbench does not need to cover
it.

### 2.4 Why the OR-of-three trigger, not just `msg_valid`

This is the single most important non-obvious constraint in this contract
— see §1's full reasoning. In one sentence: sequence continuity has to be
tracked for every message that actually arrived on the wire, not just the
subset that turned out to be well-formed and on a watched symbol, or a
dropped bad-`msg_type` message between two good ones will look like a
phantom gap to whatever arrives next.

## 3. Testbench requirements (`tb/tb_seq_monitor.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o seq_monitor_tb.vvp rtl/seq_monitor.v tb/tb_seq_monitor.v && vvp seq_monitor_tb.vvp`),
no manual waveform inspection. Drive `msg_valid`/`err_msg_type`/`err_flags`/
`msg_seq_num`/`msg_flags` directly (no need to instantiate `md_parser.v`).
Cover, at minimum:

- **First message ever** (any `msg_seq_num`, e.g. 100): no `err_seq_dup`,
  no `seq_gap_pulse`, `seq_gap` stays 0.
- **Clean run**: a run of messages with exactly consecutive `msg_seq_num`
  values (e.g. 100, 101, 102, 103) via `msg_valid` — no pulses anywhere,
  `seq_gap` stays 0 throughout.
- **Gap via `err_msg_type`**: a message with `msg_valid=0, err_msg_type=1`
  and `msg_seq_num` two higher than expected — `seq_gap_pulse` fires,
  `seq_gap_amount==2`, `seq_gap` becomes sticky 1, `expected_seq` advances
  past it. This is the case §1/§2.4 exists to cover — do not skip it. The
  *next* message, sent with the now-correct next sequence number, must be
  recognized as in-sequence (no further gap), proving `expected_seq`
  tracked the type-invalid message correctly.
- **Gap via `err_flags`**: same shape as above but via `err_flags=1`
  instead of `err_msg_type`.
- **Duplicate**: send a clean run, then re-send the last message's exact
  `msg_seq_num` again — `err_seq_dup` pulses once, `expected_seq` does not
  move (confirmed by the next message using the *original* next-expected
  value, not one past the duplicate).
- **Reorder** (an older `seq_num`, not just an exact repeat): confirm it's
  also treated as `err_seq_dup` (§2.2's rule is `<`, not `==`).
- **Sticky gap persists across multiple subsequent clean messages**: after
  a gap, send 2-3 more in-sequence messages — `seq_gap` must stay 1 the
  whole time (it's sticky, not a one-shot pulse).
- **Snapshot clears the sticky gap**: after a gap, send a message with
  `msg_flags` bit 1 set — `seq_gap` drops to 0 the cycle after, even though
  that snapshot message might itself be perfectly in-sequence (i.e. the
  clear isn't conditional on the snapshot message *fixing* anything, it
  just always clears on that bit).
- **`cfg_seq_gap_clear` clears the sticky gap** independently of message
  traffic (assert it with no message activity on the same cycle) — after a
  gap, pulse it, confirm `seq_gap` drops to 0.
- **Gap amount larger than 1**: a jump of e.g. 5 — `seq_gap_amount==5`
  exactly (not clamped to 1, not off by one).
- On any mismatch, `$display` what was expected vs. what happened, then a
  final `$display("FAIL")` / `$display("PASS")` line — this project's
  plain self-checking-Verilog convention.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o seq_monitor_tb.vvp rtl/seq_monitor.v tb/tb_seq_monitor.v` compiles with zero warnings.
- [ ] `vvp seq_monitor_tb.vvp` prints `PASS`.
- [ ] `rtl/seq_monitor.v` is Verilog-2001 only (no SystemVerilog).
- [ ] The trigger for "a message completed" is `msg_valid | err_msg_type |
      err_flags`, not `msg_valid` alone — verify by re-reading your own
      RTL, not just the testbench passing (a testbench that only ever
      drives `msg_valid=1` cases would pass even with the wrong trigger).
- [ ] The type-invalid-message-consumes-a-seq-slot case (§3) is tested and
      passes.
- [ ] `seq_gap_amount` reports the exact gap size, not a saturated/clamped
      value.
- [ ] `seq_gap` is a sticky level output (persists across multiple
      messages), not a pulse.
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- Anything about `msg_type`/`flags` validity itself (deciding whether they
  *are* valid) — that's `md_parser.v`'s job entirely; this module only
  consumes its three status pulses.
- Symbol watching/filtering — `symbol_filter.v`'s job, running in parallel,
  not through this module (§1).
- Combining this module's `err_seq_dup` output with `symbol_filter.v`'s
  `filt_valid`/`filt_slot` to decide whether to update book state — that's
  `tob_engine.v`'s job (`docs/contracts/tob_engine.md` §1).
- A distinct "stale" status signal — the master spec's block-diagram label
  for this module ("gap detection, staleness," §3.1) is a loose summary;
  the age-based staleness check (gate `0x05`, `MAX_AGE`) is driven by
  per-symbol `last_update_cycle` timestamps that belong to `tob_engine.v`'s
  book state, evaluated later by `risk_engine.v` (not built yet, S7). Do
  not add cycle-counting or timestamp logic here.
- Counters that persist `err_seq_dup`'s or `seq_gap_pulse`'s counts
  (`cnt_seq_dup`, `cnt_seq_gap`) — this module only emits the raw pulses
  (and, for the gap case, the magnitude); a later CSR/counters block owns
  accumulating them.
- `seq_num` wraparound handling — not modeled by `sim/golden_model.py`
  either; out of scope for both references.
