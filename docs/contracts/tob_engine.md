# Contract: `rtl/tob_engine.v`

Status: ready to hand off. Self-contained. **Depends on `docs/contracts/symbol_filter.md`
and `docs/contracts/seq_monitor.md`** for its port shapes below (both
modules' interfaces are already fully specified; you do not need those two
modules built/working to develop against this contract, only to match their
documented output shapes).

## 1. Background (why this exists, and how it combines its two upstream siblings)

This is an FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz
clock domain) parsing a synthetic market-data feed. `tob_engine.v` is the
master spec's top-of-book state block (§3.1 block `[G]`, FR-13..19): for
each of the 4 watched-symbol slots, it holds the current best bid/ask price
and quantity, and applies incoming quote/clear/trade/heartbeat messages to
that state exactly as the master spec's §6.3 requirements describe.

**This module is where `symbol_filter.v`'s and `seq_monitor.v`'s verdicts
actually get combined** — see `docs/contracts/symbol_filter.md` §1 and
`docs/contracts/seq_monitor.md` §1 for why those two modules are parallel
siblings off `md_parser.v` rather than a serial chain. A message should be
**applied** to book state iff:

```text
msg_applied = filt_valid AND NOT err_seq_dup
```

— i.e. `symbol_filter.v` says it's on a watched symbol, **and**
`seq_monitor.v` says it's not a duplicate/reorder (FR-11: "drop message, no
book modification"). Note what's deliberately **not** part of this gate:
`seq_monitor.v`'s sticky `seq_gap` output. FR-10 is explicit that a
sequence gap sets a sticky flag and increments a counter, but does **not**
block the book update itself — book state keeps updating normally through
a gap; the sticky flag only matters later, to `risk_engine.v`'s gate `0x06`
(not built yet, S7). Do not gate `msg_applied` on `seq_gap` — that would be
a real behavioral bug, not just an extra safety check.

**This gate applies uniformly to all four `msg_type` values**, not just
`QUOTE`/`CLEAR` — a duplicate or unwatched `TRADE`/`HEARTBEAT` message must
not increment `cnt_trades`/`cnt_heartbeats` either (confirmed against
`sim/golden_model.py`'s `process_message`: the `if is_dup: return` happens
once, before the `msg_type` dispatch, and applies to all four branches
identically — there's no reason this module's behavior should differ from
the reference it must match).

## 2. What you're building

**File:** `rtl/tob_engine.v`
**Testbench:** `tb/tb_tob_engine.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module tob_engine #(
    parameter integer NUM_SYMBOLS = 4   // matches symbol_filter.v's 4 slots
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low; match the reset style
                                 // already used elsewhere in this repo.
                                 // FR-18: book state must read as invalid
                                 // for every slot immediately after reset,
                                 // with no stale value observable.

    // from md_parser.v -- meaningful only when msg_applied (derived below)
    // is high for this cycle
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_side,
    input  wire [31:0] msg_price,
    input  wire [31:0] msg_quantity,

    // from symbol_filter.v
    input  wire        filt_valid,
    input  wire [1:0]  filt_slot,

    // from seq_monitor.v
    input  wire        err_seq_dup,

    // status: msg_applied = filt_valid & !err_seq_dup, pulses for every
    // message type once it clears the FR-11 dup gate (see S1). Exposed
    // directly because feature_extractor.v needs it for TRADE/HEARTBEAT
    // triggers (docs/contracts/feature_extractor.md S1) as well as for
    // QUOTE/CLEAR.
    output wire        msg_applied,
    output wire [1:0]  applied_slot,   // valid when msg_applied=1

    // book_upd_valid = msg_applied & (msg_type==QUOTE | msg_type==CLEAR):
    // specifically the "book was modified" pulse feature_extractor.v's
    // FR-20 trigger needs (docs/contracts/feature_extractor.md S1) --
    // narrower than msg_applied.
    output wire        book_upd_valid,

    // status pulses for a later CSR/counters block (S10) -- raw,
    // un-accumulated, same pattern as every other module's err_*/cnt_*
    // outputs in this repo
    output wire        cnt_book_clear_pulse,   // msg_applied & CLEAR
    output wire        cnt_trades_pulse,       // msg_applied & TRADE
    output wire        cnt_heartbeats_pulse,   // msg_applied & HEARTBEAT
    output wire        cnt_crossed_pulse,      // msg_applied & crossed[applied_slot]
                                                // (post-update), re-evaluated
                                                // on EVERY applied message,
                                                // not only ones that changed
                                                // price/qty -- see S2.4

    // per-slot committed book state (flattened, one bus per field --
    // Verilog-2001 has no legal 2D-array port syntax; slot i occupies bits
    // [(i+1)*WIDTH-1 : i*WIDTH] of each bus, same flattening convention as
    // symbol_filter.v's scalar-port choice reversed for a 4-wide field --
    // see S2.5 for why buses here instead of 24 scalar ports)
    output wire [NUM_SYMBOLS*32-1:0] bid_price,
    output wire [NUM_SYMBOLS*32-1:0] bid_qty,
    output wire [NUM_SYMBOLS-1:0]    bid_valid,
    output wire [NUM_SYMBOLS*32-1:0] ask_price,
    output wire [NUM_SYMBOLS*32-1:0] ask_qty,
    output wire [NUM_SYMBOLS-1:0]    ask_valid,
    output wire [NUM_SYMBOLS-1:0]    crossed
);
```

### 2.2 Applying a message (FR-13..17, and D14's fix to FR-15)

On a cycle where `msg_applied` is high, for the slot `applied_slot`:

- **`msg_type == 0x01` (QUOTE) — FR-14/FR-15/D14:** the addressed side is
  `bid` if `msg_side == 8'h00`, else `ask` (**any** non-zero `msg_side`
  value selects ask — not just `0x01` — matching
  `docs/contracts/md_parser.md`'s "any value 0-255, no validation needed
  here" and `sim/golden_model.py`'s own `if side==SIDE_BID: ... else: ...`
  structure exactly).
  - `<side>_qty <= msg_quantity` and `<side>_valid <= (msg_quantity != 0)`
    **unconditionally**.
  - `<side>_price <= msg_price` **only if `msg_quantity != 0`** — if
    `msg_quantity == 0`, the price register for that side must **hold its
    previous value**, not be overwritten with `msg_price`. This is D14
    (`docs/design_decisions.md`): a `sim/golden_model.py` bug where this
    exact behavior was missing got caught and fixed while writing this
    contract, specifically because FR-15's text says "clears validity
    **without altering stored price**" and the original code didn't
    actually do that. `sim/test_golden_model_handcase.py` messages 24-25
    are the regression test for this — read them before implementing, they
    show exactly the case that must not regress (a `qty=0` quote carrying
    a deliberately wrong price must not corrupt the stored price).
  - The **other** side (not addressed by `msg_side`) is untouched.
- **`msg_type == 0x03` (CLEAR) — FR-16:** `bid_valid <= 0` and
  `ask_valid <= 0` for the slot. **Prices and quantities are left
  unchanged** (not zeroed) — matching `sim/golden_model.py`'s `MSG_CLEAR`
  branch, which only touches the two `valid` bits. `cnt_book_clear_pulse`
  fires this cycle.
- **`msg_type == 0x02` (TRADE) — FR-19:** no book-state fields change at
  all (no price/qty/valid write of any kind). `cnt_trades_pulse` fires this
  cycle. (`msg_side` for a TRADE identifies the aggressor side — this
  module does not need it for anything; `feature_extractor.v` reads it
  independently, see `docs/contracts/feature_extractor.md`.)
- **`msg_type == 0xFF` (HEARTBEAT) — FR-19:** no book-state fields change.
  `cnt_heartbeats_pulse` fires this cycle.

On a cycle where `msg_applied` is low, no slot's book state changes, and
none of the four `cnt_*_pulse` outputs fire.

### 2.3 Crossed detection (FR-17)

For every slot, continuously (combinationally, not just on an applied-message
cycle — see §2.4 for the important exception to that phrase):

```text
crossed[i] = bid_valid[i] AND ask_valid[i] AND (bid_price[i] >= ask_price[i])
```

### 2.4 `cnt_crossed_pulse`: re-evaluated on every applied message, not just book-modifying ones

This is a real, slightly counter-intuitive detail worth getting right,
because `sim/golden_model.py` does it this specific way and this module
must match it bit-for-bit: `cnt_crossed_pulse` fires whenever `msg_applied`
is high **and** the addressed slot's `crossed` bit is true **after** this
cycle's update — **for all four `msg_type` values**, including `TRADE` and
`HEARTBEAT`, which never modify price/qty. Concretely: if a symbol's book
is already crossed from an earlier bad update, every subsequent applied
`TRADE` or `HEARTBEAT` message for that symbol re-triggers
`cnt_crossed_pulse`, even though nothing about the book changed on that
cycle. This is not a bug to "fix" by only checking `crossed` on
`QUOTE`/`CLEAR` cycles — `sim/golden_model.py`'s `process_message` checks
`if book.crossed: counters.inc('cnt_crossed')` unconditionally, after the
`msg_type` dispatch, for every message that reaches that point (i.e. every
`msg_applied` cycle). Match it.

### 2.5 Why flattened buses, not per-slot scalar ports

`symbol_filter.v` uses four separate scalar `cfg_symbol_0..3` ports because
there are only 4 of them and they map 1:1 onto the CSR register map's own
`SYMBOL_0..3` naming. This module has **6 state fields × 4 slots**, and
listing out `bid_price_0, bid_price_1, bid_price_2, bid_price_3,
bid_qty_0, ...` (24 ports for the 32-bit/1-bit fields alone) is unwieldy
and error-prone to wire up correctly downstream. A flattened bus per field
— slot `i`'s value at bits `[(i*32)+31 : i*32]` for the 32-bit fields, bit
`i` for the 1-bit fields — is the standard Verilog-2001 idiom for this
shape of data and is what `feature_extractor.v` (`docs/contracts/feature_extractor.md`)
expects to consume. Use the `+:` indexed part-select operator (legal in
Verilog-2001) to read/write a slot's slice with a variable slot index, e.g.
`bid_price[applied_slot*32 +: 32]`.

## 3. Testbench requirements (`tb/tb_tob_engine.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o tob_engine_tb.vvp rtl/tob_engine.v tb/tb_tob_engine.v && vvp tob_engine_tb.vvp`),
no manual waveform inspection. Drive `msg_type`/`msg_side`/`msg_price`/
`msg_quantity`/`filt_valid`/`filt_slot`/`err_seq_dup` directly (no need to
instantiate `symbol_filter.v`/`seq_monitor.v`/`md_parser.v`). Cover, at
minimum:

- **Reset state (FR-18):** immediately after `rst_n` deasserts, every
  slot's `bid_valid`/`ask_valid`/`crossed` must read 0, with no dependency
  on whatever driven inputs happened to be present before reset.
- **QUOTE bid then QUOTE ask, same slot (FR-14):** two messages, addressing
  bid then ask for slot 0, confirm both sides land correctly and
  independently (setting ask must not disturb the already-set bid).
- **QUOTE with `msg_quantity=0` (FR-15/D14):** set a side to a known
  price/qty first, then send a `qty=0` quote for that side carrying a
  *different* price than what's stored — confirm `valid` clears, `qty`
  reads 0, and **price is unchanged** from the first message's value, not
  overwritten. This is the case D14 exists for — get it explicitly right,
  don't just assume the conditional write is correct because the code
  looks right.
- **CLEAR (FR-16):** set both sides valid, then CLEAR — both `valid` bits
  drop to 0, but `bid_price`/`bid_qty`/`ask_price`/`ask_qty` still read
  their pre-clear values (not zeroed). `cnt_book_clear_pulse` fires exactly
  once, coincident with the CLEAR.
- **TRADE and HEARTBEAT touch nothing (FR-19):** set up a valid book, send
  a TRADE then a HEARTBEAT, confirm zero change to any price/qty/valid
  field across both, and confirm `cnt_trades_pulse`/`cnt_heartbeats_pulse`
  each fire exactly once, on the correct message.
- **Crossed detection (FR-17):** construct bid >= ask via two QUOTEs, e.g.
  bid=110/ask=100, confirm `crossed[slot]` reads 1 and stays 1 until an
  update uncrosses it (e.g. ask requoted to 120), then confirm it drops to
  0.
- **`cnt_crossed_pulse` on a non-book-modifying message while already
  crossed (§2.4):** construct a crossed book, then send a TRADE for that
  same slot — `cnt_crossed_pulse` must fire on the TRADE cycle even though
  no price/qty changed. This is the case most likely to be silently missed
  by an implementation that only checks `crossed` on `QUOTE`/`CLEAR` —
  don't skip it.
- **`msg_applied` gating (FR-11 interaction):** with `filt_valid=1` but
  `err_seq_dup=1` (simulating a duplicate on a watched symbol), send a
  QUOTE that would otherwise change book state — confirm **nothing**
  changes (no price/qty/valid write, no `cnt_*_pulse` fires, including
  `cnt_crossed_pulse` even if the book happens to already be crossed).
  Then with `filt_valid=0` (unwatched), confirm the same "nothing happens"
  result.
- **Independent slots don't interfere:** apply different QUOTE sequences to
  slots 0 and 2 (skip 1 and 3), confirm each slot's final state reflects
  only its own messages, and slots 1/3 remain at their reset (invalid)
  state throughout.
- On any mismatch, `$display` what was expected vs. what happened (which
  slot, which field, expected vs. actual), then a final `$display("FAIL")`
  / `$display("PASS")` line — this project's plain self-checking-Verilog
  convention.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o tob_engine_tb.vvp rtl/tob_engine.v tb/tb_tob_engine.v` compiles with zero warnings.
- [ ] `vvp tob_engine_tb.vvp` prints `PASS`.
- [ ] `rtl/tob_engine.v` is Verilog-2001 only (no SystemVerilog).
- [ ] FR-18 verified explicitly: no stale value readable on any book-state
      output immediately after reset.
- [ ] D14's conditional price-write (§2.2) is implemented and tested
      exactly as specified — the price register write is gated on
      `msg_quantity != 0`, not unconditional.
- [ ] `msg_applied` gates all four `msg_type` branches identically,
      including `TRADE`/`HEARTBEAT`'s counter pulses, per §1/§2.2.
- [ ] `cnt_crossed_pulse`'s §2.4 behavior (re-fires on non-book-modifying
      messages while already crossed) is implemented and tested — not
      "fixed" to only fire on `QUOTE`/`CLEAR`.
- [ ] `CLEAR` leaves price/qty fields unchanged (only touches `valid`
      bits), per FR-16 and `sim/golden_model.py`.
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- Computing `filt_valid`/`filt_slot` or `err_seq_dup` themselves — those
  come from `symbol_filter.v`/`seq_monitor.v` respectively
  (`docs/contracts/symbol_filter.md`, `docs/contracts/seq_monitor.md`).
- Feature extraction (F0-F7), normalization, or anything ML-path related —
  `feature_extractor.v`'s job entirely (`docs/contracts/feature_extractor.md`),
  consuming this module's `book_upd_valid`/`msg_applied`/state outputs but
  not built as part of this contract.
- The spread+imbalance signal rule (FR-35..40) — `signal_engine.v`'s job,
  not built yet, not this milestone.
- Age-based staleness tracking (gate `0x05`, `MAX_AGE`) — not this
  module's job; see `docs/contracts/seq_monitor.md` §5 for the same note.
  Do not add a `last_update_cycle` timestamp register here; that's a
  future S7 (risk engine) addition once gate `0x05` is actually being
  built, not before.
- Any risk-gate evaluation of `crossed` (gate `0x07`) — this module only
  exposes the raw `crossed` status bit per slot; consuming it to block an
  order is `risk_engine.v`'s job, S7, not this one.
- Counters that persist any of the `cnt_*_pulse` outputs' counts — this
  module only emits the raw pulses; a later CSR/counters block owns
  accumulating them, same pattern as every prior module.
