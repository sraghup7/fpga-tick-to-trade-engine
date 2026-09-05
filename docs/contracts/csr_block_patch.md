# Contract: two small patches to `rtl/csr_block.v`

Status: ready to hand off. **Not a new module** — two small, additive
patches to already-committed `rtl/csr_block.v` (`b7e3e9a`), split out of
`docs/contracts/tob_top.md` §1.4 into its own contract so it can be
implemented and independently verified on its own, ahead of the much
larger `tob_top.v` integration. Both patches are new ports and new `case`
arms only — nothing that currently passes `tb/tb_csr_block.v` should
change behavior.

## 1. Background

### 1.1 Why these patches, and why now

`csr_block.v`'s own contract (`docs/contracts/csr_block.md` §1.3, written
before `latency_histogram.v` existed) deliberately left two things
unwired, flagged as deferred follow-ups: `counter_clear_pulse` (CTRL bit2)
was internal-only, and the `0x138`+ histogram address range always read
back `0`. `docs/design_decisions.md` D21 repeated the flag when
`latency_histogram.v` was contracted (it now exists, committed
`acfe9a3`, with exactly the `cfg_counter_clear` input and
`hist_rd_addr`/`hist_rd_data` port shapes these patches need to connect
to). `docs/design_decisions.md` D22 (`tob_top.v`'s own contract) is the
integration point that actually needs both — this contract pulls them out
so they can be built and verified as their own small, low-risk unit first
(same category as D18's direct `risk_engine.v` patch), rather than only
surfacing as part of the much larger integration task.

### 1.2 Patch 1: export `counter_clear_pulse`

Currently an internal `wire`, declared and driven at `rtl/csr_block.v:197`:

```verilog
wire   counter_clear_pulse = csr_write_valid & (csr_addr_r == 16'h0000) & csr_data_r[2];
```

Promote it to a module output. The **assignment itself does not change** —
only its declaration, from `wire ... = ...;` to a port-list `output wire`
plus a plain `assign` at the same point in the file:

```verilog
// in the port list:
output wire        counter_clear_pulse,   // CTRL bit2, one-cycle pulse (D19/D21)

// at its existing declaration site (rtl/csr_block.v:197), unchanged logic:
assign counter_clear_pulse = csr_write_valid & (csr_addr_r == 16'h0000) & csr_data_r[2];
```

This feeds `latency_histogram.v`'s `cfg_counter_clear` input directly at
integration time (`docs/contracts/latency_histogram.md` §1.3) — no other
change anywhere in `csr_block.v`.

### 1.3 Patch 2: wire the `0x138`+ histogram range to a real readout

`csr_block.v`'s `rd32` function currently returns `32'd0` for the entire
`0x138`+ range via its catch-all `default` arm (`rtl/csr_block.v:596`).
Add two new ports and 64 new `case` arms so a CSR read in that range
actually returns `latency_histogram.v`'s bucket data:

```verilog
// in the port list:
output wire [5:0]  hist_rd_addr,   // -> latency_histogram.v's hist_rd_addr
input  wire [31:0] hist_rd_data,   // <- latency_histogram.v's hist_rd_data (registered, 1-cycle lag)
```

**The subtlety here — read this before implementing, it is easy to get
wrong.** `latency_histogram.v`'s read port is **registered**: one cycle of
latency from `hist_rd_addr` to `hist_rd_data`
(`docs/contracts/latency_histogram.md` §2.4). If `hist_rd_addr` were driven
only at the moment `rd32` is evaluated (i.e. gated on `csr_read_valid`, the
same cycle the CSR response is assembled), `rd32` would read
`hist_rd_data` from the *previous* cycle's address — stale data, off by
one read, and a bug that would not show up unless the testbench happens to
change addresses between two histogram reads (§3 covers this explicitly).

The fix is to **not** gate `hist_rd_addr` on anything — drive it
combinationally and *continuously* straight off `csr_addr_r`:

```verilog
assign hist_rd_addr = (csr_addr_r - 16'h0138) >> 2;   // bucket index,
    // 4 bytes apart, 0x138-0x234 -- NOT a raw bit-slice of csr_addr_r:
    // 0x138 isn't aligned to a power-of-two boundary, so csr_addr_r[7:2]
    // alone would give bucket 14 for address 0x138 instead of bucket 0
```

`csr_addr_r` is latched during bytes 2-3 of *every* CSR frame — write or
read alike (`rtl/csr_block.v:171-172`) — which is at least 12 cycles before
`csr_complete_d`/`csr_read_valid` ever fires at byte 15
(`rtl/csr_block.v:179-181`). By continuously tracking `csr_addr_r` rather
than waiting for the read to actually resolve, `hist_rd_data` has ample
time to settle to the right bucket well before `rd32` is ever evaluated —
no new pipeline stage or extra state needed in `csr_block.v` itself; the
existing frame-decode latency already covers it. This also means
`hist_rd_addr` changes on *every* CSR frame (writes included, and reads to
non-histogram addresses too) — harmless, since nothing reads
`hist_rd_data` unless the frame turns out to be a read to the histogram
range.

In `rd32`, replace the single `default` catch-all's coverage of the
histogram range with 64 explicit arms (or an address-range `if`/ternary
ahead of the `case`, whichever is clearer — behavior is what's being
specified here, not a specific Verilog idiom):

```verilog
16'h0138: rd32 = hist_rd_data;
16'h013C: rd32 = hist_rd_data;
... // identically for every 4-byte-aligned address through 0x0234
16'h0234: rd32 = hist_rd_data;
default:  rd32 = 32'd0;   // genuinely unmapped addresses only, now
```

Every one of these 64 arms returns the *same* `hist_rd_data` expression —
correct, because `hist_rd_addr` (driven from the *same* `csr_addr_r` this
`rd32` call is itself keyed on) has already selected the right bucket by
the time any of them is evaluated. Addresses `0x235`+ (and anything below
`0x138` not already covered by §1.2/`docs/contracts/csr_block.md` §2.3's
table) still fall through to `default: rd32 = 32'd0`.

## 2. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o csr_block_tb.vvp rtl/csr_block.v tb/tb_csr_block.v` compiles with zero warnings.
- [ ] `vvp csr_block_tb.vvp` prints `PASS` — **every existing test case
      (C1-C11) passes unmodified.** Neither patch may change any currently-
      verified behavior; both are strictly additive.
- [ ] `counter_clear_pulse` is a new output port, identical in timing to
      the `CTRL.bit2` write pulse already verified by the existing `C2`
      test case (self-clearing, one cycle).
- [ ] `hist_rd_addr` changes combinationally and continuously with
      `csr_addr_r` on every CSR frame, not gated on `csr_read_valid` (§1.3
      — this is the single most important thing to get right in this
      patch).
- [ ] A CSR read of every address `0x138`-`0x234` (4-byte steps) returns
      exactly `hist_rd_data`'s value from one cycle after `hist_rd_addr`
      was driven for that address.
- [ ] A CSR read of an address just above `0x234` (e.g. `0x238`) still
      returns `0` via the `default` arm, unaffected by the new histogram
      arms.
- [ ] No inferred latches; every new `reg`/`wire` assigned unconditionally
      or has a clear default.

## 3. Testbench requirements (new cases in `tb/tb_csr_block.v`)

`latency_histogram.v` is **not** instantiated in this testbench —
`csr_block.v` is tested standalone, same discipline as every prior
contract. Model `hist_rd_data` with a small behavioral stand-in that
reproduces the *real* one-cycle registered-read lag (not an idealized
same-cycle stand-in — this is the case that would hide a timing bug in
this patch, same lesson as `order_builder.v`'s `tx_busy` stand-in and
`csr_block.v`'s own original `resp_busy` stand-in):

```verilog
// stand-in for latency_histogram.v's registered read port
reg [31:0] hist_mem_stub [0:63];
reg [31:0] hist_rd_data;
always @(posedge clk) hist_rd_data <= hist_mem_stub[hist_rd_addr];
// initialize hist_mem_stub[i] = some known, distinct pattern per i
// (e.g. 32'hCAFE_0000 | i) so a wrong bucket index is immediately visible
```

Add, at minimum:

- **C12: `counter_clear_pulse` export.** Write `CTRL` with bit2 set,
  confirm the new `counter_clear_pulse` *output port* pulses for exactly
  one cycle — distinct from (but consistent with) the existing `C2` case,
  which only checked the pulse's *internal* effect on the counters.
- **C13: histogram readback, exact addresses.** For a handful of bucket
  indices scattered across the range (e.g. `0`, `1`, `31`, `63`), issue a
  `0x21` read at the corresponding address (`0x138 + 4*i`), confirm the
  `0x22` response's data field equals `hist_mem_stub[i]`'s known pattern —
  proves both the address translation (`(csr_addr_r - 0x138) >> 2`) and
  the readout wiring are correct together.
- **C14: the continuous-address timing case, directly.** Issue two CSR
  reads back to back at *different* histogram addresses with no gap
  between them (frame N+1 starts immediately after frame N's last byte);
  confirm the second read's response reflects the second address's own
  bucket, not the first's — this is the case that would catch
  `hist_rd_addr` being gated on `csr_read_valid` instead of driven
  continuously (§1.3's central subtlety). Also verify with a *non-CSR*
  (market-data-shaped) frame interleaved between the two histogram reads,
  confirming `hist_rd_addr` tracking `csr_addr_r` on that intervening
  frame doesn't corrupt the next histogram read.
- **C15: boundary addresses.** Read `0x134` (`lat_last`, already-mapped,
  just below the histogram range — must still return its own already-
  verified value, unaffected by this patch) and `0x238` (just above the
  histogram range — must return `0` via `default`).
- On any mismatch, `$display` what was expected vs. actual (address,
  expected, actual), then the existing final `$display("FAIL")` /
  `$display("PASS")` line.

## 4. Explicitly out of scope

- Instantiating `latency_histogram.v` itself, or connecting `hist_rd_addr`/
  `hist_rd_data`/`counter_clear_pulse` to a real `latency_histogram.v`
  instance — that's `tob_top.v`'s job (`docs/contracts/tob_top.md` §2.6),
  a separate, later contract. This one only makes `csr_block.v` itself
  correct and independently testable against a behavioral stand-in.
- Any other register, counter, or `STATUS` bit — untouched, already
  correct and verified (D19/D20).
- Widening the histogram address range, changing the bucket count, or any
  change to `latency_histogram.v` itself — fixed at 64 buckets,
  `0x138`-`0x234`, per its own committed contract.
