# Contract: `rtl/latency_histogram.v`

Status: ready to hand off. Smaller and lower-risk than `csr_block.v`
(S9's other file, committed `b7e3e9a`) — this module has one job (bucket
already-computed latency values into a 64-entry BRAM) and three things
this contract has to pin down, recorded as `docs/design_decisions.md` D21.
Depends on `rtl/order_builder.v` (S8, committed) for its input signal
shapes and `rtl/csr_block.v` (S9, committed) for the pin-compatible output
ports it must match.

## 1. Background

### 1.1 What this module does

FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz clock
domain). `latency_histogram.v` is the master spec's latency instrumentation
block (§3.1 block `[L]`, FR-53..55, NFR-1/2): it observes every transmitted
order's already-computed tick-to-trade latency and buckets it into a
64-entry BRAM histogram, tracked for later CSR readout. It is the
mechanism behind this project's single most-scrutinized claim: "a single
occupied histogram bucket for the accepting path, max == min" (§2, §12.1)
— **a second occupied bucket during a normal-traffic test is a functional
bug, not a performance result** (§7, NFR-2). This module is what would
actually surface that bug if it existed.

### 1.2 Three things this contract has to pin down (D21)

The master spec names "64-bucket BRAM histogram" but leaves open where the
latency value comes from, what the bucket boundaries are, and how a reader
gets the bucket contents back out. Resolved in `docs/design_decisions.md`
D21 — read it before this section, the summary:

1. **Latency source:** this module does **not** independently timestamp
   anything. `order_builder.v` (S8) already computes ingress-to-egress
   `latency_cyc` per transmitted record and puts it on the wire
   (`docs/contracts/order_builder.md` §2.3) — this module reads that exact
   value straight off `ob_tx_start`/`ob_tx_payload[15:0]`, the same two
   signals `csr_block.v` already taps for `cnt_orders_tx` (same
   `msg_type==0x10`-only filter, excluding `0x11` reject-diagnostic
   frames). No `cur_cycle` or ingress-timestamp wiring needed here.
2. **Bucket boundaries:** exact 1-cycle resolution for `latency_cyc` values
   `0`-`62` (bucket index == the value itself), bucket `63` is a saturating
   catch-all for anything `>= 63`. **Not** a linear-shift bucket width —
   NFR-2/T25 need single-cycle jitter to be visible as a second occupied
   bucket, which a coarser bucket (e.g. 4 cycles/bucket) would silently
   hide. NFR-1's target is ≤22 cycles nominal, so the entire plausible
   nominal range gets full-precision buckets; bucket 63 absorbs the rare
   case of an order delayed behind a busy TX (`order_builder.v`'s 2-deep
   queue, §2.4 of its contract).
3. **Readout:** a standalone `hist_rd_addr[5:0]`/`hist_rd_data[31:0]`
   interface, **not** wired into `csr_block.v`'s CSR read mux by this
   contract — same "build and test standalone, wire at integration"
   discipline as every S8/S9 module so far. §1.3 below lists exactly what's
   deferred and why.

### 1.3 Two small gaps this contract leaves in already-committed `csr_block.v`

Not fixed here — flagged so they aren't forgotten before S10:

- `csr_block.v`'s CSR read mux currently hard-codes the `0x138`+ histogram
  address range to return `0` (its `default` case, `b7e3e9a`). Making
  FR-56's "on-demand CSR read" of histogram data work end-to-end needs a
  small follow-up patch wiring that address range to this module's
  `hist_rd_addr`/`hist_rd_data`.
- `csr_block.v`'s `counter_clear_pulse` (CTRL bit2) is currently an
  internal `wire`, not an output port. FR-56 groups "counters and
  histogram" together; this module takes a `cfg_counter_clear` input for
  that reason, but wiring it from `csr_block.v` needs that pulse exported.

Both are small, well-understood patches to already-shipped RTL (same
category as D18) — deliberately out of scope for *this* contract.

## 2. What you're building

**File:** `rtl/latency_histogram.v`
**Testbench:** `tb/tb_latency_histogram.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module latency_histogram (
    input  wire        clk,
    input  wire        rst_n,   // active-low, same reset style as the rest of this repo

    // from order_builder.v -- same two signals csr_block.v already taps
    input  wire         ob_tx_start,
    input  wire [127:0] ob_tx_payload,   // byte 0 = msg_type; bits [15:0] = latency_cyc

    // from csr_block.v (stand-in port for now, §1.3 -- CTRL bit2, one-cycle pulse)
    input  wire         cfg_counter_clear,

    // pin-compatible with csr_block.v's ALREADY-BUILT lat_valid/lat_value
    // input ports (committed b7e3e9a) -- straight connection at S10, no
    // changes needed to csr_block.v for this half of the wiring
    output wire         lat_valid,
    output wire [15:0]  lat_value,

    // standalone histogram readout (§1.2 point 3 / §1.3) -- registered
    // BRAM read, one cycle of latency
    input  wire [5:0]   hist_rd_addr,
    output reg  [31:0]  hist_rd_data
);
```

### 2.2 Deriving `lat_valid`/`lat_value`

```verilog
assign lat_valid = ob_tx_start & (ob_tx_payload[127:120] == 8'h10);
assign lat_value = ob_tx_payload[15:0];
```

Purely combinational — `ob_tx_start` is already a one-cycle pulse
(`docs/contracts/order_builder.md` §2.5), so `lat_valid` inherits that
shape with no extra registering needed. The `8'h10` (NEW) filter excludes
`0x11` reject-diagnostic frames from the latency histogram, mirroring
`csr_block.v`'s own `cnt_orders_tx` exclusion (`docs/contracts/csr_block.md`
§2.5) — a rejected order was never actually transmitted at the measured
latency in any meaningful sense, and NFR-1/2's claim is specifically about
the *accepting* path.

### 2.3 Bucket index (D21 point 2)

```verilog
wire [5:0] bucket_idx = (lat_value > 16'd63) ? 6'd63 : lat_value[5:0];
```

A comparator and a mux — no shifter, no divider. `lat_value[5:0]` is safe
to read directly whenever `lat_value <= 63` (its upper bits are
necessarily `0` in that range); the `> 63` branch overrides with the
saturating bucket `63` for anything larger, covering values all the way up
to `lat_value`'s full 16-bit range (a record delayed a long time behind a
busy TX is still valid input, just an off-nominal one this histogram
buckets into the catch-all rather than mis-indexing).

### 2.4 The 64-entry BRAM

Two separate `always` blocks over the same memory array — the standard
Xilinx dual-port BRAM inference shape (one write port, one *registered*
read port, independent addresses, both may fire the same cycle):

```verilog
reg [31:0] hist_mem [0:63];
integer i;

// write port: saturating increment on lat_valid, cleared by cfg_counter_clear
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < 64; i = i + 1) hist_mem[i] <= 32'd0;
    end else if (cfg_counter_clear) begin
        for (i = 0; i < 64; i = i + 1) hist_mem[i] <= 32'd0;
    end else if (lat_valid) begin
        hist_mem[bucket_idx] <= (hist_mem[bucket_idx] == 32'hFFFFFFFF)
                                 ? hist_mem[bucket_idx]
                                 : hist_mem[bucket_idx] + 32'd1;
    end
end

// read port: registered, one cycle of latency, standard BRAM shape
always @(posedge clk) begin
    hist_rd_data <= hist_mem[hist_rd_addr];
end
```

**Read port has no reset** — deliberate, matching standard BRAM inference
guidance (an unconditional reset on a memory-array read register can
prevent block-RAM mapping on some toolchains, forcing distributed LUTRAM
instead, which defeats the "BRAM, 64 buckets" architecture intent, §3.1
block `[L]`). `hist_rd_data` settles to a real value within one cycle of
any `hist_rd_addr` change regardless; nothing reads it before then.

**Saturating, same as every other counter in this project**
(`docs/contracts/csr_block.md` §2.5) — a bucket that hits `0xFFFFFFFF`
holds there rather than wrapping, so a long soak can never make a heavily
hit bucket read small.

**`cfg_counter_clear` and reset both do a full 64-entry sweep in one
cycle** — this is a `for` loop over a memory array, standard Verilog-2001,
synthesizes as parallel resets on every BRAM word (or, if the toolchain
prefers, the same effect via a global memory-init pragma at synthesis;
either is acceptable, the *simulated* behavior in the testbench is what
matters for this contract).

## 3. Testbench requirements (`tb/tb_latency_histogram.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o latency_histogram_tb.vvp rtl/latency_histogram.v tb/tb_latency_histogram.v && vvp latency_histogram_tb.vvp`),
no manual waveform inspection. Drive `ob_tx_start`/`ob_tx_payload`/
`cfg_counter_clear`/`hist_rd_addr` directly. Cover, at minimum:

- **T25's own property, directly:** drive several `ob_tx_start` pulses, all
  `msg_type=0x10` with the *same* `latency_cyc` value, confirm exactly one
  bucket is nonzero afterward (reading every one of the 64 buckets via
  `hist_rd_addr` and checking the rest are `0`) — this is the single most
  important case in this testbench, matching NFR-2's headline claim.
- **Distinct latencies land in distinct buckets:** drive a handful of
  different `latency_cyc` values (e.g. `10`, `11`, `22`), confirm each
  lands in its own exactly-matching bucket index — this is the case that
  would catch an accidentally-coarse bucket width (D21 point 2).
- **`0x11` exclusion:** drive `ob_tx_start` with `msg_type=0x11` and some
  `latency_cyc` value, confirm no bucket changes at all.
- **Saturating catch-all bucket:** drive `latency_cyc` values of `63`,
  `64`, and `1000` (or any value near the top of the 16-bit range) on
  separate pulses, confirm all three land in bucket `63`, and confirm
  bucket `62` never increments from any of them.
- **Per-bucket saturation:** force (or pulse enough times) a single bucket
  to `0xFFFFFFFE`, pulse it twice more, confirm it holds at `0xFFFFFFFF`
  rather than wrapping.
- **`cfg_counter_clear`:** build up several nonzero buckets, pulse
  `cfg_counter_clear` for one cycle, confirm every one of the 64 buckets
  reads back `0` immediately after.
- **Read port timing:** confirm `hist_rd_data` reflects `hist_mem` one
  cycle after `hist_rd_addr` changes (registered read, §2.4) — not
  same-cycle combinational.
- **`lat_valid`/`lat_value` pin-compatibility:** confirm both signals'
  widths and behavior match what `csr_block.v` already expects on its own
  `lat_valid`/`lat_value` input ports (1-bit pulse, 16-bit value) — a
  direct assertion this module's outputs would plug into `csr_block.v`
  without modification.
- On any mismatch, `$display` what was expected vs. actual (bucket index,
  expected, actual), then a final `$display("FAIL")` / `$display("PASS")`
  line — this project's plain self-checking-Verilog convention.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o latency_histogram_tb.vvp rtl/latency_histogram.v tb/tb_latency_histogram.v` compiles with zero warnings.
- [ ] `vvp latency_histogram_tb.vvp` prints `PASS`.
- [ ] `rtl/latency_histogram.v` is Verilog-2001 only (no SystemVerilog).
- [ ] A run of several same-latency accepted orders produces exactly one
      occupied bucket (T25's own property, §3's first case).
- [ ] `latency_cyc` values `0`-`62` map 1:1 to their own bucket index; `63`
      and above all saturate into bucket `63`.
- [ ] `0x11` reject-diagnostic frames never affect any bucket or `lat_valid`.
- [ ] Every bucket saturates at `0xFFFFFFFF`, never wraps.
- [ ] `cfg_counter_clear` resets all 64 buckets to `0` in one cycle.
- [ ] `hist_rd_data` is a registered (one-cycle-latency) read, not
      combinational.
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- Deriving `latency_cyc` independently from `cur_cycle`/ingress timestamps
  — this module only reads the value `order_builder.v` already computed
  and put on the wire (§1.2 point 1, D21).
- Wiring `hist_rd_addr`/`hist_rd_data` into `csr_block.v`'s CSR read mux,
  or wiring `lat_valid`/`lat_value` into `csr_block.v`'s existing input
  ports, or wiring `cfg_counter_clear` from `csr_block.v`'s internal
  `counter_clear_pulse` — all `tob_top.v`/S10 integration work, with two
  specific small follow-up patches to already-committed `csr_block.v`
  flagged in §1.3.
- `lat_min`/`lat_max`/`lat_last` — already implemented in `csr_block.v`
  (committed `b7e3e9a`, §2.5 of its contract) from the *same*
  `lat_valid`/`lat_value` values this module produces. Not duplicated
  here.
- `stats_reporter.v`'s periodic stats-frame emission of histogram data
  (FR-56's "stats frames every `cfg_stats_period` cycles" half) — a
  separate module, no interaction with this one.
- A bucket count other than 64, or a parameterized bucket width — both
  fixed, matching the master spec's own "64 buckets" architecture line and
  D21's exact-resolution reasoning, not tunables.
- Any behavior for `LINK_MODE=0` (raw Ethernet) or `debug_uart.v`'s UART
  fallback — this module only ever sees `order_builder.v`'s already-built
  wire-format output regardless of link mode; no separate handling needed.
