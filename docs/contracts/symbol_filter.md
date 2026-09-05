# Contract: `rtl/symbol_filter.v`

Status: ready to hand off. Self-contained. **Depends on `rtl/md_parser.v`
already existing** (it does — S2, committed) only for its port shapes below;
you do not need to instantiate `md_parser.v` itself, only match its
`msg_valid`/`msg_symbol_id` output contract (`docs/contracts/md_parser.md`).
Can be implemented in parallel with `docs/contracts/seq_monitor.md` — the
two modules do not depend on each other (see §1).

## 1. Background (why this exists, and a real bug this contract avoids repeating)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain) parsing a synthetic market-data feed. `symbol_filter.v` is the
master spec's "4-entry symbol CAM" (§3.1 block `[E]`): it watches up to 4
configured `symbol_id`s and tells downstream logic which of them (if any) a
given decoded message belongs to, so `tob_engine.v` can maintain book state
for only 4 symbols' worth of registers instead of one register set per
possible 8-bit `symbol_id` (256 of them).

**Read this before assuming symbol_filter.v gates the byte/message stream
downstream — it must not.** The master spec's block diagram (§3.1) draws
`md_parser → symbol_filter → seq_monitor → tob_engine` as a straight chain,
which looks like each stage blocks non-matching messages from reaching the
next. That reading is wrong for this project and was the exact mistake a
first draft of `sim/golden_model.py` made (`docs/design_decisions.md` D12's
sibling bug, same root cause): `seq_monitor.v`'s job (FR-10, "per feed"
sequence tracking) requires seeing **every** message md_parser.v completes,
including ones on unwatched symbols — otherwise an unwatched-symbol message
silently consumes a `seq_num` slot without `seq_monitor.v` ever advancing
its expected-sequence counter, and the next watched message looks like it
arrived after a gap that never happened. Consequence for this module:
**`symbol_filter.v` and `seq_monitor.v` are parallel siblings, both wired
directly off `md_parser.v`'s outputs — not a serial pipeline where one
gates the other's input.** `symbol_filter.v` does not need to know
`seq_monitor.v` exists at all, and vice versa; `tob_engine.v` is the module
that combines both of their verdicts (see `docs/contracts/tob_engine.md`
§1). Do not add any port here for talking to `seq_monitor.v` directly.

**`md_parser.v` has already validated `msg_type`/`flags` (FR-8/FR-9) by the
time this module sees anything** — `msg_valid` only pulses for a
type-and-flags-clean message (`docs/contracts/md_parser.md`). This module
therefore never has to think about `err_msg_type`/`err_flags` at all; it
only ever needs to look at messages where `msg_valid=1`.

## 2. What you're building

**File:** `rtl/symbol_filter.v`
**Testbench:** `tb/tb_symbol_filter.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module symbol_filter (
    input  wire        clk,
    input  wire        rst_n,   // active-low; match the reset style already
                                 // used elsewhere in this repo (see
                                 // rtl/eth_mac_if.v or rtl/tob_top.v)

    // from md_parser.v -- only messages it already validated matter here
    input  wire        msg_valid,
    input  wire [7:0]  msg_symbol_id,

    // config (S9 CSR map: SYMBOL_0..3 @ 0x08-0x14, SYMBOL_EN @ 0x18).
    // Direct ports, standing in for csr_block.v, which does not exist yet
    // (same pattern as every other module landed so far in this repo --
    // bottom-up, config wired directly until the CSR block lands).
    input  wire [7:0]  cfg_symbol_0,
    input  wire [7:0]  cfg_symbol_1,
    input  wire [7:0]  cfg_symbol_2,
    input  wire [7:0]  cfg_symbol_3,
    input  wire [3:0]  cfg_symbol_en,   // bit i enables slot i

    // to tob_engine.v (and anything else that needs "which of the 4
    // watched-symbol slots did this message match")
    output wire        filt_valid,   // msg_valid AND matched an enabled slot
    output wire [1:0]  filt_slot,    // matched slot index 0-3; meaningful
                                      // only when filt_valid=1

    // status: one-cycle pulse per message on an unwatched symbol (FR-7,
    // counted as cnt_msgs_filtered by a later counters block -- this
    // module only emits the raw pulse)
    output wire        filt_dropped
);
```

Do not parameterize `NUM_SYMBOLS` — the master spec's register map (§9)
hard-codes exactly 4 symbol slots (`SYMBOL_0`..`SYMBOL_3`), and a
runtime-sized array of ports isn't legal Verilog-2001 anyway (see §2.4).
Four scalar `cfg_symbol_*` ports, matching the CSR map's own naming, is the
whole interface — don't build anything more general.

### 2.2 Match rule (FR-7)

For a cycle where `msg_valid=1`:

1. For each slot `i` in `0..3`: slot `i` **matches** iff
   `cfg_symbol_en[i]==1` AND `cfg_symbol_i == msg_symbol_id`.
2. If **any** slot matches, `filt_valid=1` and `filt_slot` is the
   **lowest-numbered** matching slot. (Configuring two enabled slots to the
   same `symbol_id` is a misconfiguration, not a case this module needs to
   detect or reject — lowest-index-wins is simply what a priority encoder
   naturally does, and nothing downstream needs a "duplicate config"
   error.)
3. If **no** slot matches, `filt_dropped=1` and `filt_valid=0` (`filt_slot`
   don't-care).

For a cycle where `msg_valid=0`: both `filt_valid` and `filt_dropped` are 0,
regardless of `msg_symbol_id`'s value (it's meaningless when `msg_valid` is
low — `md_parser.v`'s `msg_symbol_id` register holds whatever the last
completed message decoded to, valid or not, per how `md_parser.v` is built;
this module must not react to that stale value).

### 2.3 Timing: pure combinational gating, like `frame_classifier.v`

Same reasoning as `rtl/frame_classifier.v`'s accept/reject gate
(`docs/contracts/frame_classifier.md` §2.4, already-merged precedent in this
repo): the match decision needs no state and no history — it's a pure
function of `msg_symbol_id` and the four `cfg_symbol_*`/`cfg_symbol_en`
registers, all of which are already stable the cycle `msg_valid` pulses.
`filt_valid`, `filt_slot`, and `filt_dropped` must all be **combinational**
outputs, valid the same cycle as `msg_valid` — zero added latency, no FSM,
no registered pipeline stage. Do not register these outputs "to be safe";
that would add a cycle to every message's tick-to-trade latency for no
behavioral benefit, and this repo's whole datapath is built around latency
being a synthesis-time constant (NFR-1), not something to spend carelessly.

### 2.4 Why four scalar ports, not an array

Verilog-2001 module ports cannot be a SystemVerilog-style unpacked array
(`input wire [7:0] cfg_symbol [0:3]` is not legal port syntax in this
dialect). A flattened single bus (`input wire [31:0] cfg_symbol_flat`) would
also work, but four scalar ports directly named after the CSR register map's
own `SYMBOL_0..3` naming is simpler to wire up correctly from `tob_top.v`
later and impossible to get the slicing/ordering wrong on, which a flattened
bus is not. Follow the register map's naming exactly.

## 3. Testbench requirements (`tb/tb_symbol_filter.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o symbol_filter_tb.vvp rtl/symbol_filter.v tb/tb_symbol_filter.v && vvp symbol_filter_tb.vvp`),
no manual waveform inspection. Drive `msg_valid`/`msg_symbol_id` and the
`cfg_*` inputs directly (no need to instantiate `md_parser.v`). Cover, at
minimum:

- **Default config** (`cfg_symbol_0..3 = 1,2,3,4`, `cfg_symbol_en = 4'hF`,
  matching the CSR map's power-on defaults): a message on each of symbols
  1, 2, 3, 4 in turn matches slot 0, 1, 2, 3 respectively; `filt_dropped`
  never pulses for any of them.
- **Unwatched symbol** (e.g. `symbol_id=99` against the default config):
  `filt_valid=0`, `filt_dropped=1`, for one cycle only.
- **Disabled slot**: configure slot 2's `cfg_symbol_en` bit to 0 while
  `cfg_symbol_2` still equals an incoming message's `symbol_id` — must be
  treated as unwatched (`filt_dropped=1`), not matched, proving the enable
  bit is actually checked and not just the ID comparison.
- **Duplicate configured ID, lowest-slot-wins**: configure both
  `cfg_symbol_0` and `cfg_symbol_2` to the same value (both enabled), send a
  message for that symbol, confirm `filt_slot==0` (slot 0, not slot 2).
- **`msg_valid=0`**: with `msg_symbol_id` driven to some watched value,
  hold `msg_valid` low — `filt_valid` and `filt_dropped` must both stay 0.
  This is the case most likely to be silently wrong in an implementation
  that forgets to gate the match logic on `msg_valid` at all.
- **Back-to-back messages, mixed watched/unwatched**, at least 8 messages
  in a row alternating matched slots and drops with no gap cycles between
  them: confirms there's no stuck state or one-cycle lag anywhere (there
  shouldn't be any state at all per §2.3, but prove it, don't assume it).
- On any mismatch, `$display` what was expected vs. what happened (which
  message, expected `filt_valid`/`filt_slot`/`filt_dropped` vs. actual),
  then a final `$display("FAIL")` / `$display("PASS")` line — this
  project's plain self-checking-Verilog convention (see `tb/tb_frame_classifier.v`
  for the exact style already established).

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o symbol_filter_tb.vvp rtl/symbol_filter.v tb/tb_symbol_filter.v` compiles with zero warnings.
- [ ] `vvp symbol_filter_tb.vvp` prints `PASS`.
- [ ] `rtl/symbol_filter.v` is Verilog-2001 only (no SystemVerilog, no
      unpacked-array ports).
- [ ] `filt_valid`/`filt_slot`/`filt_dropped` are purely combinational —
      no registers, no FSM, per §2.3. If your implementation needs a clock
      edge to produce any of these three outputs, you've added unneeded
      latency; re-read §2.3.
- [ ] The disabled-slot case (§3) is tested and correctly treated as
      unwatched, not matched.
- [ ] The duplicate-configured-ID case (§3) is tested and resolves to the
      lowest slot index.
- [ ] No inferred latches (this module should need no `always` block with
      incomplete branches at all, given §2.3 — if you find yourself writing
      one, reconsider the approach).

## 5. Explicitly out of scope

- Anything about `msg_type`/`flags` validity — already handled entirely by
  `md_parser.v` upstream (§1); this module only ever looks at
  `msg_valid`-gated messages.
- Sequence-gap/duplicate detection — `seq_monitor.v`'s job entirely, wired
  in parallel off `md_parser.v`, not through this module (§1). Do not add
  any seq-related port here.
- Combining this module's `filt_valid`/`filt_slot` with `seq_monitor.v`'s
  duplicate verdict to decide whether to actually update book state — that
  combining logic belongs to `tob_engine.v` (`docs/contracts/tob_engine.md`
  §1), not here.
- Counters that persist `filt_dropped`'s count (`cnt_msgs_filtered`) — this
  module only emits the raw one-cycle pulse; a later CSR/counters block
  owns accumulating it, same pattern as every prior module's `err_*`
  outputs in this repo.
- Any runtime-reconfigurable number of symbol slots — hard-coded at 4,
  matching the CSR register map (§2.1/§2.4).
