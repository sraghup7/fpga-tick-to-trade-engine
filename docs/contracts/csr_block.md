# Contract: `rtl/csr_block.v`

Status: ready to hand off, but **read all of §1 first** — this module has
to pin down four things the master spec leaves genuinely unspecified (the
CSR frame wire protocol, the counter address map, the TX-side interface
shape, and the `STATUS` register's scope), recorded as
`docs/design_decisions.md` D19. Depends on every already-built module for
its `cfg_*` fan-out and `err_*`/`cnt_*_pulse`/`gate_*_fired` fan-in
(`symbol_filter.v`, `seq_monitor.v`, `tob_engine.v`, `signal_engine.v`,
`risk_engine.v`, `order_builder.v`, `md_parser.v`, `frame_classifier.v` —
all S2/S3/S5/S7/S8, all committed).

## 1. Background

### 1.1 What this module does

FPGA project (Artix-7 XC7A35T, Verilog-2001 only, single 125 MHz clock
domain). `csr_block.v` is the master spec's control-plane block (§3.1 block
`[M]`, §9, §10, FR-56..58): it is the **single source of truth** for every
`cfg_*` register this pipeline's other modules currently take as direct
stand-in input ports, and the **single accumulation point** for every
`err_*`/`cnt_*_pulse`/`gate_*_fired` raw one-cycle pulse those modules
already emit. It is read/written over CSR frames (`0x20` write / `0x21`
read-request / `0x22` read-response) carried in the same 16-byte
fixed-width envelope as every other frame type in this system.

Every already-built module was written to take its `cfg_*` values as plain
input ports "standing in for `csr_block.v`" (their own contracts say this
explicitly). **This contract does not touch any of that RTL** — it only
adds a new module whose outputs are pin-compatible with those existing
`cfg_*` input ports. Wiring `csr_block.v`'s outputs to the rest of the
pipeline's `cfg_*` inputs is `tob_top.v` integration work (S10), not this
contract's job — this module is built and tested standalone, same as every
prior S3/S5/S7/S8 module.

### 1.2 Four things this contract has to pin down (D19)

The master spec names the CSR frame `msg_type` values and the `0x00`-`0x9C`
register addresses, but leaves genuinely open: how a CSR frame physically
reaches this module, where its `0x22` read-response frame goes, what
addresses the `0xA0`+ counters occupy, and what `STATUS`'s ambiguous bits
7:5 mean. All four are resolved in `docs/design_decisions.md` D19 — read it
before this section, the summary:

1. **Ingress:** CSR frames share `frame_classifier.v`'s existing byte
   stream (`in_data`/`in_valid`) — the same one `md_parser.v` consumes.
   Nothing in the current RTL demuxes by UDP port (checked directly:
   `cfg_udp_port` has no consumer anywhere), so there is no second port to
   tap even if this design wanted one. `csr_block.v` runs its own small
   byte-serial decode of the same stream, recognizing only `0x20`/`0x21` in
   byte 0; everything else (market-data frames) is silently ignored, the
   same way `md_parser.v` already silently ignores `0x20`/`0x21` today.
2. **Egress:** a `0x22` read-response does **not** go through
   `eth_mac_if.v` directly here. `order_builder.v` already exclusively
   drives `tx_payload`/`tx_start`/`tx_busy`; arbitrating a second master
   onto that single interface is S10 integration work. This module exposes
   its own `resp_payload`/`resp_start`/`resp_busy` — same shape, standalone
   testable, to be muxed in at `tob_top.v` time.
3. **Counter addresses `0xA0`+:** assigned by this contract in §10's own
   listed order, 4 bytes apart, `0xA0`-`0x134`. The 64-bucket histogram
   (`0x138`+) is explicitly **not** implemented here — that's
   `latency_histogram.v`'s data; this module reserves the range and reads
   it back as `0` until a follow-up wires a real passthrough.
4. **`STATUS` bits 7:5** ("side-valid map"): 4 symbols need 8 bits, the
   register only has 3. Left reserved (`0`), documented as a known spec
   gap rather than silently guessed at. Bits 0-4 are defined in §2.6.

### 1.3 Two more real gaps found while grounding this contract

- **No `err_fcs`/`err_ethertype`/`err_ip`/`err_udp_port` source exists
  anywhere in the current RTL.** The vendored MAC verifies these before
  `eth_mac_if.v` asserts anything (D1) but exposes none of them as named
  pulses. This module takes them as stand-in input ports (same pattern as
  `adverse_risk` standing in for `ml_policy.v` in `risk_engine.v`) — tie
  them to `0` in any testbench/integration until real signals exist.
- **ML counters have no source yet either** (`cnt_ml_events`,
  `cnt_ml_adverse`, `cnt_ml_benign`, `cnt_ml_safe_forced` — `ml_policy.v`
  is S6, not started). Same treatment: stand-in pulse inputs, tied to `0`
  for now.

## 2. What you're building

**File:** `rtl/csr_block.v`
**Testbench:** `tb/tb_csr_block.v` (self-checking, Icarus)

### 2.1 Module interface

```verilog
module csr_block #(
    parameter integer NUM_SYMBOLS = 4   // matches symbol_filter.v/tob_engine.v
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, same reset style as the rest of this repo

    // ---- CSR ingress: shared byte stream, same one md_parser.v consumes
    // (frame_classifier.v's out_data/out_valid, D19 point 1) ----
    input  wire [7:0]  in_data,
    input  wire        in_valid,

    // ---- CSR egress: NOT wired to eth_mac_if.v in this contract (D19
    // point 2) -- same shape as order_builder.v's TX interface, arbitrated
    // in at S10 ----
    output reg  [127:0] resp_payload,
    output reg           resp_start,
    input  wire           resp_busy,

    // =====================================================================
    // cfg_* OUTPUTS -- pin-compatible with every existing module's cfg_*
    // input ports. See §2.3/§2.4 for the address each comes from.
    // =====================================================================

    // -> symbol_filter.v, order_builder.v
    output reg  [7:0]  cfg_symbol_0,
    output reg  [7:0]  cfg_symbol_1,
    output reg  [7:0]  cfg_symbol_2,
    output reg  [7:0]  cfg_symbol_3,
    output reg  [3:0]  cfg_symbol_en,

    // -> signal_engine.v
    output reg  [31:0] cfg_min_spread,
    output reg  [1:0]  cfg_imb_shift,
    output reg  [31:0] cfg_order_qty,

    // -> risk_engine.v
    output reg  [31:0] cfg_max_order_qty,
    output reg  [31:0] cfg_max_position,
    output reg  [31:0] cfg_price_band,
    output reg  [31:0] cfg_max_age,
    output reg  [31:0] cfg_token_max,
    output reg  [31:0] cfg_token_refill_cycles,
    output reg          cfg_ml_action,
    output reg  [3:0]   cfg_ml_reduce_shift,
    output wire          cfg_kill_clear,     // CTRL bit1, self-clearing pulse, §2.5

    // -> order_builder.v
    output reg          cfg_reject_report,   // CTRL bit4

    // -> seq_monitor.v
    output wire         cfg_seq_gap_clear,   // CTRL bit3, self-clearing pulse, §2.5

    // -> feature_normalizer.v
    output reg  [31:0] cfg_offset_0, output reg [31:0] cfg_shift_0,
    output reg  [31:0] cfg_offset_1, output reg [31:0] cfg_shift_1,
    output reg  [31:0] cfg_offset_2, output reg [31:0] cfg_shift_2,
    output reg  [31:0] cfg_offset_3, output reg [31:0] cfg_shift_3,
    output reg  [31:0] cfg_offset_4, output reg [31:0] cfg_shift_4,
    output reg  [31:0] cfg_offset_5, output reg [31:0] cfg_shift_5,
    output reg  [31:0] cfg_offset_6, output reg [31:0] cfg_shift_6,
    output reg  [31:0] cfg_offset_7, output reg [31:0] cfg_shift_7,

    // -> not consumed by any built module yet; register storage only,
    // read/write must still work correctly for T24 (§1.1's "pin-compatible
    // outputs" principle doesn't apply -- there is no consumer port to be
    // compatible with, so these are plain outputs nothing connects to yet)
    output reg          cfg_enable,          // CTRL bit0
    output reg  [15:0] cfg_udp_port,        // 0x40
    output reg  [31:0] cfg_stats_period,    // 0x44
    output reg  signed [31:0] cfg_ml_th_high,       // 0x48
    output reg  signed [31:0] cfg_ml_th_low,        // 0x4C
    output reg  [31:0] cfg_ml_score_offset,  // 0x54
    output reg  [31:0] cfg_ml_score_shift,   // 0x58
    output reg  [31:0] cfg_ml_window,        // 0x5C
    output wire         ml_bypass,            // ML_CTRL bit8, debug only

    // =====================================================================
    // STATUS-feeding level inputs (§2.6)
    // =====================================================================
    input  wire         kill_latched,               // risk_engine.v
    input  wire         seq_gap,                     // seq_monitor.v
    input  wire [NUM_SYMBOLS-1:0] crossed,           // tob_engine.v

    // =====================================================================
    // Pulse INPUTS accumulated into saturating counters (§2.5). Every one
    // of these is a raw one-cycle pulse from an already-built module's own
    // output port of the same name (or noted stand-in where nothing drives
    // it yet, §1.3).
    // =====================================================================

    // ingress / frame-level (frame_classifier.v, md_parser.v)
    input  wire         frame_start,          // eth_mac_if.v, D11 -- cnt_frames_rx
    input  wire         err_frame_len,        // frame_classifier.v
    input  wire         md_msg_valid,         // md_parser.v's msg_valid
    input  wire         err_msg_type,         // md_parser.v
    input  wire         err_flags,            // md_parser.v

    // stand-in, no source yet (§1.3)
    input  wire         err_fcs,
    input  wire         err_ethertype,
    input  wire         err_ip,
    input  wire         err_udp_port,

    // symbol_filter.v
    input  wire         filt_valid,           // -> cnt_msgs_accepted
    input  wire         filt_dropped,         // -> cnt_msgs_filtered

    // seq_monitor.v
    input  wire         err_seq_dup,          // -> cnt_seq_dup
    input  wire         seq_gap_pulse,        // -> cnt_seq_gap

    // tob_engine.v
    input  wire         cnt_book_clear_pulse,
    input  wire         cnt_trades_pulse,
    input  wire         cnt_heartbeats_pulse,
    input  wire         cnt_crossed_pulse,

    // signal_engine.v
    input  wire         sig_valid,
    input  wire [7:0]   sig_side,             // 0x00 buy / 0x01 sell
    input  wire         err_signal_conflict,

    // stand-in, ml_policy.v not built yet (§1.3)
    input  wire         ml_event_valid,       // -> cnt_ml_events
    input  wire         ml_adverse_pulse,     // -> cnt_ml_adverse
    input  wire         ml_benign_pulse,      // -> cnt_ml_benign
    input  wire         ml_safe_forced_pulse, // -> cnt_ml_safe_forced

    // risk_engine.v -- one gate_*_fired per gate, 1:1 with cnt_rej_*
    input  wire         gate_kill_fired,
    input  wire         gate_size_fired,
    input  wire         gate_position_fired,
    input  wire         gate_band_fired,
    input  wire         gate_stale_fired,
    input  wire         gate_seqgap_fired,
    input  wire         gate_crossed_fired,
    input  wire         gate_throttle_fired,
    input  wire         gate_ml_fired,

    // order_builder.v
    input  wire         ob_tx_start,          // order_builder.v's tx_start
    input  wire [127:0] ob_tx_payload,        // order_builder.v's tx_payload,
                                               // byte 0 read to tell NEW (cnt_orders_tx)
                                               // from REJECT (not counted)
    input  wire         cnt_order_overflow_pulse,

    // latency (stand-in until latency_histogram.v exists, §1.2 point 3)
    input  wire         lat_valid,
    input  wire [15:0]  lat_value
);
```

### 2.2 CSR frame ingress decode

16-byte fixed-width envelope, big-endian, same convention as every other
frame type in this system:

| Offset | Size | Field | Notes |
| :-- | :-- | :-- | :-- |
| 0 | 1 | `msg_type` | `0x20` write, `0x21` read-request; anything else ignored |
| 1 | 1 | reserved | must be 0 on write; ignored on decode |
| 2 | 2 | `addr` | register byte address, big-endian |
| 4 | 4 | `data` | write value (0x20 only; don't-care on 0x21) |
| 8-15 | 8 | reserved | ignored on decode |

Mirrors `md_parser.v`'s own byte-serial shape exactly (`docs/contracts/md_parser.md`
if unfamiliar) — a free-running mod-16 `byte_cnt` over cycles `in_valid` is
high, latching `msg_type` at `byte_cnt==0`, `addr` at `byte_cnt==2,3`,
`data` at `byte_cnt==4..7`, and pulsing a one-cycle `csr_valid` the cycle
*after* byte 15 lands (same "registers need one clock edge to capture the
last byte" reasoning as `docs/contracts/md_parser.md` §2.6). No
frame-boundary awareness needed here either, for the same reason
`md_parser.v` doesn't need it: `frame_classifier.v` only ever forwards
whole multiples of 16 bytes.

```verilog
reg [3:0] byte_cnt;
reg [7:0] csr_msg_type_r;
reg [15:0] csr_addr_r;
reg [31:0] csr_data_r;
reg csr_complete_d;   // one cycle after byte 15

// on every in_valid cycle: byte_cnt <= byte_cnt + 1 (wraps 15->0);
// latch csr_msg_type_r/csr_addr_r/csr_data_r at the matching byte_cnt
// values; csr_complete_d <= (byte_cnt == 4'd15) & in_valid, registered.

wire csr_write_valid = csr_complete_d & (csr_msg_type_r == 8'h20);
wire csr_read_valid  = csr_complete_d & (csr_msg_type_r == 8'h21);
```

`csr_write_valid`/`csr_read_valid` are the two pulses §2.3/§2.7 key off.
Any other `csr_msg_type_r` value on `csr_complete_d` is silently dropped —
no error counter for this (a market-data frame arriving here is expected,
routine traffic, not a CSR error).

### 2.3 Register write decode

`CTRL` (`0x00`) has mixed bit semantics — **read this before writing the
decode**:

| Bit | Name | Semantics |
| :-- | :-- | :-- |
| 0 | engine enable | plain level, read back exactly what was last written (`cfg_enable`) |
| 1 | kill clear | **self-clearing**: a write with bit1=1 produces a one-cycle `cfg_kill_clear` pulse the cycle *after* the write completes; the stored `CTRL` register's bit1 always reads back `0` (never latches) |
| 2 | counter clear | **self-clearing**, same pulse shape, drives all counters (§2.5) and the sticky `STATUS` bits (§2.6) to clear; stored bit2 always reads `0` |
| 3 | seq-gap clear | **self-clearing**, drives `cfg_seq_gap_clear` (`seq_monitor.v`'s own clear input); stored bit3 always reads `0` |
| 4 | reject reporting | plain level, `cfg_reject_report` (FR-44) |
| 31:5 | reserved | ignored on write, read back `0` |

```verilog
wire [31:0] ctrl_wdata_c = /* csr_data_r, on csr_write_valid & (csr_addr_r == 16'h0000) */;

// self-clearing pulses -- one cycle, registered from the write itself
assign cfg_kill_clear     = csr_write_valid & (csr_addr_r == 16'h0000) & ctrl_wdata_c[1];
assign cfg_seq_gap_clear  = csr_write_valid & (csr_addr_r == 16'h0000) & ctrl_wdata_c[3];
wire   counter_clear_pulse = csr_write_valid & (csr_addr_r == 16'h0000) & ctrl_wdata_c[2];

// plain level bits -- stored, CTRL.bit1/2/3 never latch (always read 0)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cfg_enable        <= 1'b0;
        cfg_reject_report <= 1'b0;
    end else if (csr_write_valid & (csr_addr_r == 16'h0000)) begin
        cfg_enable        <= ctrl_wdata_c[0];
        cfg_reject_report <= ctrl_wdata_c[4];
    end
end
```

Every other writable register (`0x08`-`0x9C`) is a plain level: on
`csr_write_valid` with `csr_addr_r` matching its address, register
`csr_data_r` (truncated/typed to the field's own width — e.g.
`cfg_imb_shift <= csr_data_r[1:0]`, `cfg_ml_action <= csr_data_r[0]`,
`cfg_ml_reduce_shift <= csr_data_r[4:1]`) into the matching `cfg_*` output;
otherwise hold. `ML_CTRL` (`0x50`) packs three fields into one register —
decode bit0 into `cfg_ml_action`, bits 4:1 into `cfg_ml_reduce_shift`, bit8
into `ml_bypass`, same "one write, multiple `cfg_*` targets" shape as
`CTRL` itself. The full address table (write-decode and read-mux both key
off this same table):

| Addr | Register | Width | Reset default | Target |
| :-- | :-- | :-- | :-- | :-- |
| `0x00` | `CTRL` | 32 (mixed, see above) | `0x0` | see above |
| `0x04` | `STATUS` | 32 (read-only, §2.6) | — | — |
| `0x08` | `SYMBOL_0` | 8 | `1` | `cfg_symbol_0` |
| `0x0C` | `SYMBOL_1` | 8 | `2` | `cfg_symbol_1` |
| `0x10` | `SYMBOL_2` | 8 | `3` | `cfg_symbol_2` |
| `0x14` | `SYMBOL_3` | 8 | `4` | `cfg_symbol_3` |
| `0x18` | `SYMBOL_EN` | 4 | `0xF` | `cfg_symbol_en` |
| `0x1C` | `MIN_SPREAD` | 32 | `2` | `cfg_min_spread` |
| `0x20` | `IMB_SHIFT` | 2 | `1` | `cfg_imb_shift` |
| `0x24` | `ORDER_QTY` | 32 | `100` | `cfg_order_qty` |
| `0x28` | `MAX_ORDER_QTY` | 32 | `500` | `cfg_max_order_qty` |
| `0x2C` | `MAX_POSITION` | 32 | `1000` | `cfg_max_position` |
| `0x30` | `PRICE_BAND` | 32 | `50` | `cfg_price_band` |
| `0x34` | `MAX_AGE` | 32 | `1250000` | `cfg_max_age` |
| `0x38` | `TOKEN_MAX` | 32 | `8` | `cfg_token_max` |
| `0x3C` | `TOKEN_REFILL` | 32 | `12500` | `cfg_token_refill_cycles` |
| `0x40` | `UDP_PORT` | 16 | `60000` | `cfg_udp_port` (no consumer yet, §2.1) |
| `0x44` | `STATS_PERIOD` | 32 | `12500000` | `cfg_stats_period` (no consumer yet) |
| `0x48` | `ML_TH_HIGH` | 32 signed | `0` | `cfg_ml_th_high` (no consumer yet) |
| `0x4C` | `ML_TH_LOW` | 32 signed | `0` | `cfg_ml_th_low` (no consumer yet) |
| `0x50` | `ML_CTRL` | 32 (packed, see above) | `0x0` | `cfg_ml_action`/`cfg_ml_reduce_shift`/`ml_bypass` |
| `0x54` | `ML_SCORE_OFFSET` | 32 | `0` | `cfg_ml_score_offset` (no consumer yet) |
| `0x58` | `ML_SCORE_SHIFT` | 32 | `0` | `cfg_ml_score_shift` (no consumer yet) |
| `0x5C` | `ML_WINDOW` | 32 | `16` | `cfg_ml_window` (no consumer yet) |
| `0x60`,`0x64`,...,`0x7C` | `ML_OFFSET_0..7` | 32 each | `0` | `cfg_offset_0..7` |
| `0x80`,`0x84`,...,`0x9C` | `ML_SHIFT_0..7` | 32 each | `0` | `cfg_shift_0..7` |

A write to any address not in this table (and not in the counters range,
§2.4) is silently ignored — no error counter, matching `STATUS`/`CTRL`'s
own "reserved bits read 0" treatment; this is a config bus, not a
message-validity gate.

### 2.4 Register read mux and read-response emission

On `csr_read_valid`, look up `csr_addr_r` against the same table as §2.3
(config registers, current live value — not the write-cycle's data, the
currently-held register) plus the counters table (§2.5) plus `STATUS`
(§2.6); any address outside all of these (including the reserved histogram
range `0x138`+) reads back `0`. Assemble and emit a `0x22` frame on
`resp_payload`/`resp_start`, same shape and same one-shot-pulse discipline
as `order_builder.v`'s `tx_payload`/`tx_start` (`docs/contracts/order_builder.md`
§2.5 — `resp_start` must self-gate the same way against `resp_busy`'s
documented one-cycle lag, if the eventual S10 arbiter reproduces
`eth_mac_if.v`'s lag; this contract's own testbench models `resp_busy`
with that same lag to catch the same class of bug order_builder.v's did).

| Offset | Size | Field |
| :-- | :-- | :-- |
| 0 | 1 | `msg_type` = `0x22` |
| 1 | 1 | reserved (0) |
| 2 | 2 | `addr` (echoed back, big-endian) |
| 4 | 4 | `data` (the read value, big-endian) |
| 8-15 | 8 | reserved (0) |

A `csr_read_valid` that arrives while `resp_busy` (a prior response still
draining) is dropped silently — no queue, unlike `order_builder.v`'s 2-deep
one. CSR reads are diagnostic/config traffic, not the fast path; a lost
read is a "retry from the host" case, not a correctness gate, and adding a
queue here would duplicate `order_builder.v`'s own already-solved
complexity for no requirement that asks for it (§5).

### 2.5 Counter accumulation

All 32-bit, **saturating** (never wraps — `cnt <= (cnt == 32'hFFFFFFFF) ?
cnt : cnt + 1'b1` on each trigger pulse), cleared together by
`counter_clear_pulse` (§2.3). Addresses assigned in §10's listed order, 4
bytes apart from `0xA0`:

| Addr | Counter | Increments on |
| :-- | :-- | :-- |
| `0xA0` | `cnt_frames_rx` | `frame_start` |
| `0xA4` | `cnt_msgs_rx` | `md_msg_valid \| err_msg_type \| err_flags` |
| `0xA8` | `cnt_msgs_filtered` | `filt_dropped` |
| `0xAC` | `cnt_msgs_accepted` | `filt_valid` |
| `0xB0` | `err_fcs` | `err_fcs` (stand-in, §1.3) |
| `0xB4` | `err_ethertype` | `err_ethertype` (stand-in) |
| `0xB8` | `err_ip` | `err_ip` (stand-in) |
| `0xBC` | `err_udp_port` | `err_udp_port` (stand-in) |
| `0xC0` | `err_frame_len` | `err_frame_len` |
| `0xC4` | `err_msg_type` | `err_msg_type` |
| `0xC8` | `err_flags` | `err_flags` |
| `0xCC` | `err_signal_conflict` | `err_signal_conflict` |
| `0xD0` | `cnt_seq_gap` | `seq_gap_pulse` |
| `0xD4` | `cnt_seq_dup` | `err_seq_dup` |
| `0xD8` | `cnt_crossed` | `cnt_crossed_pulse` |
| `0xDC` | `cnt_book_clear` | `cnt_book_clear_pulse` |
| `0xE0` | `cnt_trades` | `cnt_trades_pulse` |
| `0xE4` | `cnt_heartbeats` | `cnt_heartbeats_pulse` |
| `0xE8` | `cnt_signal_buy` | `sig_valid & (sig_side == 8'h00)` |
| `0xEC` | `cnt_signal_sell` | `sig_valid & (sig_side == 8'h01)` |
| `0xF0` | `cnt_ml_events` | `ml_event_valid` (stand-in, §1.3) |
| `0xF4` | `cnt_ml_adverse` | `ml_adverse_pulse` (stand-in) |
| `0xF8` | `cnt_ml_benign` | `ml_benign_pulse` (stand-in) |
| `0xFC` | `cnt_ml_safe_forced` | `ml_safe_forced_pulse` (stand-in) |
| `0x100` | `cnt_rej_kill` | `gate_kill_fired` |
| `0x104` | `cnt_rej_size` | `gate_size_fired` |
| `0x108` | `cnt_rej_position` | `gate_position_fired` |
| `0x10C` | `cnt_rej_band` | `gate_band_fired` |
| `0x110` | `cnt_rej_stale` | `gate_stale_fired` |
| `0x114` | `cnt_rej_seqgap` | `gate_seqgap_fired` |
| `0x118` | `cnt_rej_crossed` | `gate_crossed_fired` |
| `0x11C` | `cnt_rej_throttle` | `gate_throttle_fired` |
| `0x120` | `cnt_rej_ml` | `gate_ml_fired` |
| `0x124` | `cnt_orders_tx` | `ob_tx_start & (ob_tx_payload[127:120] == 8'h10)` |
| `0x128` | `cnt_order_overflow` | `cnt_order_overflow_pulse` |
| `0x12C` | `lat_min` | see below |
| `0x130` | `lat_max` | see below |
| `0x134` | `lat_last` | `lat_valid` (stand-in, §1.2 point 3): `lat_last <= lat_value` |

`lat_min`/`lat_max` (FR-55): on `lat_valid`, `lat_min <= (lat_value <
lat_min) ? lat_value : lat_min` and `lat_max <= (lat_value > lat_max) ?
lat_value : lat_max`; both reset to their identity extreme
(`lat_min` resets to `32'hFFFFFFFF`, `lat_max` to `32'd0`) so the first
`lat_valid` always establishes both correctly. These two are the one
exception to "saturating counters never move on `counter_clear_pulse`
beyond resetting to 0" — `counter_clear_pulse` resets them back to their
identity extremes, not to `0`, otherwise a cleared `lat_min` would read `0`
forever (a fresh min needs to start "infinitely high", not `0`).

`cnt_orders_tx`'s trigger is read from `ob_tx_payload[127:120]` (the
`msg_type` byte, MSB-aligned per `order_builder.v`'s own
`tx_payload`/`resp_payload` convention) specifically to exclude `0x11`
reject-diagnostic frames (`cfg_reject_report=1`) from this counter — the
spec's own invariant (§10) is `cnt_signal_buy + cnt_signal_sell =
cnt_orders_tx + Σcnt_rej_* + cnt_order_overflow`, which only balances if
`cnt_orders_tx` counts *accepted* transmissions, not diagnostic ones.

### 2.6 `STATUS` (`0x04`) — read-only, sticky, D19 point 4

```text
bit0  kill latched     -- NOT sticky-via-counter-clear; mirrors risk_engine.v's
                           own kill_latched level directly (already latched
                           until CTRL.bit1 per FR-46/47 -- re-latching it here
                           independently would let the two disagree)
bit1  seq gap           -- sticky: set on seq_gap_pulse, held until counter_clear_pulse
bit2  crossed            -- sticky: set whenever (|crossed) is 1 -- LEVEL, not
                           edge-triggered (D20). `crossed` (tob_engine.v) is a
                           persisting level, unlike the other three sticky
                           triggers here which are genuine one-shot pulses --
                           re-check this every cycle, not just on a 0->1
                           transition, or a book that stays crossed straight
                           through a counter_clear_pulse will never re-set
                           this bit (D20 found exactly this bug in the first
                           implementation of this contract)
bit3  stale              -- sticky: set on gate_stale_fired, held until counter_clear_pulse
bit4  ML-adverse         -- sticky: set on ml_adverse_pulse (stand-in, §1.3),
                           held until counter_clear_pulse
bits 7:5  side-valid map -- RESERVED, always 0 (D19 point 4 -- 4 symbols need
                           8 bits, register only has 3; not solved here)
bits 31:8 reserved, always 0
```

`counter_clear_pulse` (CTRL bit2, §2.3) clears bits 1-4 the same cycle it
clears the counters — one "start clean" operation, matching FR-56's
"counters and histogram" framing (`STATUS`'s sticky bits are diagnostic
telemetry, same category).

### 2.7 What this contract does *not* wire up

Every `cfg_*`/status-feeding input listed in §2.1 is a **standalone port**
on this module — this contract does not modify `symbol_filter.v`,
`seq_monitor.v`, `tob_engine.v`, `signal_engine.v`, `risk_engine.v`, or
`order_builder.v` to actually connect to `csr_block.v`'s outputs, and does
not modify `frame_classifier.v`/`eth_mac_if.v` to actually feed this
module's `in_data`/`in_valid` or arbitrate `resp_*` onto the real TX path.
That wiring is `tob_top.v` integration (S10) — this module is built and
tested in isolation, same discipline as every prior S3/S5/S7/S8 contract.

## 3. Testbench requirements (`tb/tb_csr_block.v`)

Self-checking, Icarus-runnable
(`iverilog -g2001 -Wall -o csr_block_tb.vvp rtl/csr_block.v tb/tb_csr_block.v && vvp csr_block_tb.vvp`),
no manual waveform inspection. Drive `in_data`/`in_valid` as a byte-serial
CSR frame source (a small task that pushes 16 bytes for a given
`msg_type`/`addr`/`data`, mirroring how `tb_md_parser.v` already drives
`md_parser.v`) and every pulse/level input directly. Cover, at minimum:

- **`T24_csr`'s own requirement, directly:** for a representative sample
  covering every register width/semantics category in §2.3's table (a
  plain 32-bit level like `MAX_ORDER_QTY`, an 8-bit like `SYMBOL_0`, a
  packed register like `ML_CTRL`, a self-clearing `CTRL` bit), write via a
  `0x20` frame, then read back via a `0x21`/`0x22` round trip, confirm the
  value matches, and confirm the corresponding `cfg_*` output actually
  changed (not just the internal storage).
- **`CTRL` self-clearing bits:** write `CTRL` with bit1/bit2/bit3 set,
  confirm `cfg_kill_clear`/`counter_clear_pulse`/`cfg_seq_gap_clear` each
  pulse for exactly one cycle, and confirm a subsequent `CTRL` readback
  shows those bits back at `0` (never latched) while bit0/bit4 (plain
  levels, set in the same write) persist correctly.
- **Counter accumulation and saturation:** pulse each trigger in §2.5's
  table individually, confirm only the matching counter increments (no
  cross-talk between counters); pulse one repeatedly past `0xFFFFFFFF`,
  confirm it saturates rather than wrapping.
- **`counter_clear_pulse`:** increment several counters and set several
  `STATUS` sticky bits, issue the clear, confirm all counters read `0` and
  `STATUS` bits 1-4 read `0` — **except** `lat_min`/`lat_max`, which must
  reset to their identity extremes (`0xFFFFFFFF`/`0`), not `0` (this is the
  case most likely to be implemented wrong by symmetry with the other
  counters — call it out explicitly if it fails).
- **`cnt_orders_tx` vs. reject frames:** drive `ob_tx_start` with
  `ob_tx_payload`'s `msg_type` byte as `0x10` (counts) and separately as
  `0x11` (must not count) — confirm only the `0x10` case increments
  `cnt_orders_tx`.
- **`STATUS` bit0 vs. bits 1-4:** set `kill_latched` high without ever
  issuing `counter_clear_pulse`, confirm `STATUS` bit0 tracks it live
  (both up and back down when `kill_latched` deasserts) — unlike bits 1-4,
  which must stay stuck high until the clear even after their trigger
  pulse has long since ended.
- **CSR read while `resp_busy`:** issue a `0x21` read request while
  `resp_busy` is asserted (model it with the same one-cycle-lag-after-
  `resp_start` shape `tb_order_builder.v` used for `tx_busy`); confirm the
  read is silently dropped (no `resp_start`, no corruption of any register
  state) rather than queued or corrupting a subsequent read.
- **Non-CSR traffic on the shared byte stream:** drive a well-formed
  market-data-shaped 16-byte sequence (`msg_type` in `{0x01,0x02,0x03,0xFF}`)
  through `in_data`/`in_valid`; confirm no `csr_write_valid`/`csr_read_valid`
  ever fires and no register changes — this is the case that would catch
  `csr_block.v` accidentally reacting to market-data traffic on the shared
  stream (D19 point 1).
- **Unmapped address:** write and read an address not in any table (e.g.
  `0x200`, inside the reserved histogram range) — write is a silent no-op,
  read returns `0`, no other register is disturbed.
- On any mismatch, `$display` what was expected vs. actual (register name,
  address, expected, actual), then a final `$display("FAIL")` /
  `$display("PASS")` line — this project's plain self-checking-Verilog
  convention.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall -o csr_block_tb.vvp rtl/csr_block.v tb/tb_csr_block.v` compiles with zero warnings.
- [ ] `vvp csr_block_tb.vvp` prints `PASS`.
- [ ] `rtl/csr_block.v` is Verilog-2001 only (no SystemVerilog).
- [ ] Every register in §2.3's table round-trips write→read correctly, and
      the write actually changes the corresponding `cfg_*` output (T24 gate).
- [ ] `CTRL` bits 1-3 never read back as `1` (self-clearing verified, not
      just pulse-generation verified).
- [ ] Every counter in §2.5's table saturates at `0xFFFFFFFF`, never wraps.
- [ ] `counter_clear_pulse` resets `lat_min`/`lat_max` to their identity
      extremes, not `0`.
- [ ] `cnt_orders_tx` excludes `0x11` reject-diagnostic frames.
- [ ] `STATUS` bit0 is a live mirror of `kill_latched`; bits 1-4 are sticky
      until `counter_clear_pulse`; bits 7:5 always read `0`.
- [ ] Market-data-shaped traffic on the shared `in_data`/`in_valid` stream
      never triggers a CSR write or read.
- [ ] No inferred latches (every `reg` assigned on every path through its
      `always` block, or has a clear default).

## 5. Explicitly out of scope

- Wiring `cfg_*` outputs to any other module's `cfg_*` inputs, or wiring
  `in_data`/`in_valid`/`resp_*` to `frame_classifier.v`/`eth_mac_if.v` —
  `tob_top.v` integration, S10 (§2.7).
- Arbitrating `resp_payload`/`resp_start` with `order_builder.v`'s
  `tx_payload`/`tx_start` onto the single real TX interface — S10.
- The 64-bucket latency histogram itself (BRAM storage, bucket-index
  computation) — `latency_histogram.v`, a separate S9 module. This
  contract only reserves its address range and returns `0` for it.
- Real `err_fcs`/`err_ethertype`/`err_ip`/`err_udp_port` signal sources —
  no such signals exist anywhere in the current RTL yet (§1.3); this module
  takes stand-in input ports, tied to `0` until real sources exist.
- Real ML counter sources (`cnt_ml_events`/`cnt_ml_adverse`/
  `cnt_ml_benign`/`cnt_ml_safe_forced`) — `ml_policy.v` is S6, not started
  (§1.3); stand-in input ports, tied to `0` for now.
- A read queue for CSR requests arriving while `resp_busy` — dropped
  silently instead (§2.4); CSR traffic is diagnostic, not the fast path.
- `stats_reporter.v`'s periodic `0x12` stats-frame emission (FR-56's
  "every `cfg_stats_period` cycles" half) — a separate module; this
  contract only stores `cfg_stats_period` as a register, doesn't act on it.
- `debug_uart.v`'s UART fallback ingress (FR-59) — separate module, no
  interaction with this one.
- Reloadable ML weights (§14.8) — explicitly out of scope per the master
  spec itself, not just this contract.
