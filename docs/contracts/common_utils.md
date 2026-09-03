# Contract: `rtl/common/sync_2ff.v` + `rtl/common/counter_sat.v`

Status: ready to hand off. Self-contained. Two small, independent utility
modules used throughout the rest of the datapath — get these exactly right
and don't add anything beyond what's specified; they'll be instantiated
dozens of times.

## 1. Background

This is a Verilog-2001-only FPGA project (Artix-7, 125 MHz single clock
domain, see repo `CLAUDE.md` if you want the full context — not required to
do this task). Two shared utility modules are needed before other modules can
be written against them:

- `sync_2ff.v` — a standard two-flip-flop synchronizer, needed anywhere a
  single-bit signal crosses into this design's clock domain (e.g. a reset
  released asynchronously by an external reset controller, brought in
  synchronously — see `docs/design_decisions.md` decision D2 for the concrete
  case this exists for, not required reading to implement this).
- `counter_sat.v` — a saturating up-counter: increments up to a maximum and
  then **holds** (never wraps/overflows), with a synchronous clear. Used for
  every error/event counter in the design (dozens of them), so it must be
  correct and must never wrap silently — a counter that wraps back to 0 would
  misreport "no errors" after enough errors occurred, which is exactly the
  failure mode this project's verification plan is built to catch.

## 2. `rtl/common/sync_2ff.v`

### Interface

```verilog
module sync_2ff #(
    parameter RESET_VALUE = 1'b0
) (
    input  wire clk,
    input  wire rst_n,      // active-low, asynchronous reset of the synchronizer's own FFs
    input  wire async_in,   // the potentially-asynchronous / untimed input
    output wire sync_out    // async_in, resynchronized to clk, two-FF deep
);
```

### Behavior

- Two flip-flops in series, both clocked by `clk`. `async_in` feeds the first
  FF's input; the first FF's output feeds the second FF's input; the second
  FF's output is `sync_out`.
- Both FFs reset asynchronously to `RESET_VALUE` on `rst_n` deasserted (low).
- No combinational path from `async_in` to `sync_out` — it must take exactly
  2 clock edges for a change on `async_in` to appear on `sync_out` (this is
  the whole point of the module; do not "optimize" it to fewer stages).
- Do **not** add a third stage, a debounce filter, or any other feature —
  this is intentionally the minimal standard 2-FF synchronizer, not a
  general-purpose input conditioner.

### Testbench (`tb/tb_sync_2ff.v`, Icarus, self-checking)

- Drive `async_in` with a clock-relationship-free toggle pattern (e.g. change
  it at a non-integer-multiple period relative to `clk`, or just change it at
  essentially arbitrary times including right at a `clk` edge to exercise the
  metastability-adjacent timing — full metastability obviously can't be
  simulated in RTL sim, that's not the point; the point is checking the
  2-cycle latency and correct reset behavior).
- Assert: `sync_out` always changes exactly 2 `clk` edges after `async_in`
  changes (within simulation's discrete-event resolution).
- Assert: on `rst_n` deasserted, both internal FFs (or observably, `sync_out`
  within 2 cycles) go to `RESET_VALUE` regardless of `async_in`.
- Print `PASS`/`FAIL` per this project's plain self-checking-Verilog
  convention (no UVM/SVA — Verilog-2001 project-wide).

## 3. `rtl/common/counter_sat.v`

### Interface

```verilog
module counter_sat #(
    parameter WIDTH = 32
) (
    input  wire             clk,
    input  wire             rst_n,   // active-low, synchronous
    input  wire             clear,   // synchronous clear to 0, priority over incr
    input  wire             incr,    // pulse: increment by 1 this cycle
    output reg  [WIDTH-1:0] count,
    output wire             saturated // high when count == {WIDTH{1'b1}} (max value)
);
```

### Behavior

- On reset (`rst_n` low) or `clear` high: `count` goes to 0 synchronously on
  the next clock edge. `clear` takes priority over `incr` if both are
  asserted the same cycle (i.e. clearing while also told to increment results
  in 0, not 1 — clear wins).
- On `incr` high (and not clearing/resetting): `count` increments by 1,
  **unless `count` is already at its maximum value** (`{WIDTH{1'b1}}`), in
  which case it **holds** at the maximum — it must never wrap to 0.
- `saturated` is a combinational (or registered, your choice, just be
  consistent and correct) indicator that `count` is currently at max.
- `incr` asserted for multiple consecutive cycles increments once per cycle
  (it's a plain enable, not an edge-detected pulse — the caller is
  responsible for pulsing it for exactly the cycles they want counted; this
  module does not do its own edge detection).
- Parameterized by `WIDTH` — must work correctly for any `WIDTH >= 1` (test
  at least `WIDTH=4` in your testbench to make saturation easy to hit, and
  the default `WIDTH=32` to make sure the parameter actually plumbs through).

### Testbench (`tb/tb_counter_sat.v`, Icarus, self-checking)

- With a small `WIDTH` (e.g. 4, max value 15): pulse `incr` for more than 15
  cycles, verify `count` reaches 15 and then **holds at 15** (does not wrap
  to 0) for as long as `incr` stays asserted, and `saturated` is high exactly
  while `count == 15`.
- Verify `clear` resets `count` to 0 from any value, including from the
  saturated state, and that asserting `clear` and `incr` in the same cycle
  results in `count == 0` on the next edge (clear wins).
- Verify `rst_n` behaves like `clear` (goes to 0).
- Print `PASS`/`FAIL` per this project's plain self-checking-Verilog
  convention.

## 4. Acceptance criteria (both modules)

- [ ] Both files are Verilog-2001 only — no SystemVerilog constructs
      (`always_ff`, `logic`, interfaces, `assert`, etc.). This project's
      hand-written RTL is Verilog-2001 exclusively.
- [ ] `iverilog -g2001 -Wall -o sync_2ff_tb.vvp rtl/common/sync_2ff.v tb/tb_sync_2ff.v && vvp sync_2ff_tb.vvp` compiles with zero warnings and prints `PASS`.
- [ ] `iverilog -g2001 -Wall -o counter_sat_tb.vvp rtl/common/counter_sat.v tb/tb_counter_sat.v && vvp counter_sat_tb.vvp` compiles with zero warnings and prints `PASS`.
- [ ] Neither module contains logic beyond what's specified above — no extra
      ports, no extra features, no "just in case" generality. If you think
      something's missing, flag it in your handoff notes rather than adding
      it silently.
- [ ] No inferred latches (every `reg` assigned in every branch of every
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- Any multi-bit CDC (that needs an async FIFO, a different and more involved
  module — not this contract).
- Debouncing (that's a separate future module if/when needed for the board's
  physical keys — not this contract, even though `sync_2ff` might be used
  *inside* such a module later).
- Anything project-specific (risk gates, counters with specific bit
  assignments, etc.) — these are generic utilities with no knowledge of the
  rest of the datapath.
