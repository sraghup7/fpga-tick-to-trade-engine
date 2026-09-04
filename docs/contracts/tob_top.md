# Contract: `rtl/tob_top.v`

Status: ready to hand off, but **read all of §1 first** — this is the
first contract that wires already-committed modules *together* instead of
building a new one, and it comes with a two-clock-domain architecture, a
TX arbiter, and two small prerequisite patches to already-committed
`csr_block.v`. Rebuilds the existing S0 skeleton (`sys_clk`/`rst_n`/
`key_in`/`led` only, board-bringup heartbeat) into the real integration
top. Depends on every module through S9 (all committed) plus the vendored
MAC tree (`rtl/vendor/alinx_mac/`, D1) and `rtl/common/{mdio_ctrl,sync_2ff}.v`
(both committed).

## 1. Background

### 1.1 What this module does

FPGA project (Artix-7 XC7A35T, ALINX AX7035B, JLSemi JL2121(D) PHY,
Verilog-2001 only). `tob_top.v` is the master spec's board-level top
(§3.1's full block diagram, §13's `rtl/` tree top file): physical RGMII/
MDIO/KEY/LED pins in, a fully wired tick-to-trade engine inside. Every
module it instantiates is already independently built, contracted, and
verified — this contract's own job is getting the **wiring** right, not
inventing new datapath behavior.

### 1.2 Two clock domains (D2) — read this before anything else

The entire engine (`frame_classifier.v` through `csr_block.v`/
`latency_histogram.v`) runs on **`gmii_rx_clk`**, the RGMII receive clock
recovered from the link partner inside `util_gmii_to_rgmii.v` (D2 — ALINX's
own MAC ties `gmii_tx_clk` directly from `gmii_rx_clk`, so there is
genuinely one 125 MHz domain for the whole datapath, no CDC at that
boundary). `sys_clk` (50 MHz board oscillator) is retained **only** for PHY
reset sequencing and `mdio_ctrl.v` — a separate, slower domain that
exchanges nothing with the engine except a reset-release edge (crossed via
`rtl/common/sync_2ff.v`, per D2's own follow-on note).

**A concrete bug this contract exists to prevent (D22 point 2):**
`mdio_ctrl.v`'s `CLK_HZ` parameter **defaults to `125_000_000`**. Since it
runs off `sys_clk` here, **it must be instantiated with `.CLK_HZ(50_000_000)`
explicitly** — otherwise its internal MDC divider computes the wrong
period, silently driving the PHY's MDIO clock over the IEEE 802.3 clause
22 2.5 MHz maximum with no assertion anywhere to catch it. §2.3 below.

### 1.3 What this contract does *not* attempt (D22 point 3)

- **No ML path.** `feature_extractor.v`/`feature_normalizer.v` are **not
  instantiated** — they have no consumer until `ml_classifier_wrap.v`/
  `ml_policy.v` exist (S6, blocked on S4/the ML collaborator).
  `risk_engine.v`'s `adverse_risk` input is a fixed tie-off (`1'b0`) here,
  same stand-in principle its own contract already established, just
  resolved at this integration level instead of a testbench.
- **No T26 soak testbench.** The master spec's 1,000,000-message soak
  (`tb/tb_top.v`, §11.3) "drives the GMII-side interface" — `mac_top.v`'s
  own RX/TX boundary, the same one `tb/tb_eth_mac_if_rx.v`/
  `tb_eth_mac_if_tx.v` already drive standalone. That testbench can
  instantiate the engine chain directly, without `tob_top.v`, `mac_top.v`,
  `util_gmii_to_rgmii.v`, or `mdio_ctrl.v` in the loop — a separate,
  later task. §3 below is a smaller connectivity/smoke check: does this
  contract's *wiring* correctly connect pieces that are each already
  independently, exhaustively verified.
- **No physical-layer timing closure.** RGMII pin constraints,
  `create_clock` definitions, IDELAY/pad-skew validation against real
  hardware, and the PHY's actual minimum reset-pulse width are S11
  (Hardware) concerns — no board has measured any of this yet
  (`PREREQUISITES.md` has no such number recorded). §2.2 below specifies a
  conservative placeholder reset hold count, explicitly flagged as
  provisional rather than a real measured figure.

### 1.4 Prerequisite: two small patches to already-committed `csr_block.v`

Flagged as deferred follow-ups in D19/D21; this is the integration point
where they're actually needed. **Split into its own contract,
`docs/contracts/csr_block_patch.md`** — export `counter_clear_pulse` as a
new output port, and wire the reserved `0x138`+ histogram address range to
a new `hist_rd_addr`/`hist_rd_data` readout — since it's a small,
independently-verifiable unit of work (own testbench cases, own
acceptance criteria) that should land and pass on its own before the much
larger integration in this contract is attempted. **Read that contract in
full before starting on `tob_top.v` itself** — §2.6 below assumes both
patches are already applied and both new ports already exist on
`csr_block.v`.

### 1.5 A gap this integration closes for free

`mac_top.v` already carries D5's patch exposing `mac_rec_error` (FCS/CRC
failure) and `udp_checksum_error` (IP header checksum failure — UDP
checksum itself is deliberately not verified, §4.1). `docs/contracts/csr_block.md`
§1.3 flagged `err_fcs`/`err_ethertype`/`err_ip`/`err_udp_port` as having
*no source anywhere in the current RTL* when `csr_block.v` was contracted.
Wiring `mac_rec_error` → `err_fcs` and `udp_checksum_error` → `err_ip`
(§2.4 below) closes two of those four stand-ins for real.
`err_ethertype`/`err_udp_port` stay tied to `0` — `mac_top.v` doesn't
expose a distinct signal for either failure mode (a wrong-EtherType or
wrong-port frame is simply never dispatched to anything, D1/D3), so there
is genuinely nothing to wire there yet.

## 2. What you're building

**File:** `rtl/tob_top.v`
**Testbench:** `tb/tb_tob_top.v` (self-checking, Icarus — connectivity/smoke
level, §3)

### 2.1 Module interface

```verilog
module tob_top #(
    // Board/network identity -- compile-time constants, not CSR-runtime-
    // configurable (the register map, §9, has no MAC/IP address fields).
    // Placeholder defaults; the real host IP/port must be set correctly
    // before S11 hardware bring-up -- not resolved by this contract, no
    // host address is specified anywhere in the master spec.
    parameter [47:0] BOARD_MAC_ADDR   = 48'h00_0a_35_01_02_03,  // matches
                                          // the §4.1 static-ARP example
    parameter [31:0] BOARD_IP_ADDR    = {8'd192, 8'd168, 8'd1, 8'd10},
    parameter [7:0]  BOARD_TTL        = 8'd64,
    parameter [31:0] HOST_IP_ADDR     = {8'd192, 8'd168, 8'd1, 8'd1},   // PLACEHOLDER
    parameter [15:0] HOST_UDP_PORT    = 16'd60000,   // matches cfg_udp_port's default
    parameter [15:0] BOARD_UDP_PORT   = 16'd60001    // this board's own outgoing source port
) (
    input  wire        sys_clk,   // 50 MHz board oscillator
    input  wire        rst_n,     // active-low pushbutton reset
    input  wire [3:0]  key_in,    // KEY1..KEY4, active-low; key_in[0] = kill switch (§2.10)
    output wire [3:0]  led,       // §2.11

    // RGMII (physical pins)
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        rgmii_txc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    input  wire        rgmii_rxc,

    // MDIO (physical pins)
    output wire        mdc,
    inout  wire        mdio,

    // PHY hardware reset (D4: "PHY reset polarity/timing, reset.v's
    // pattern -- active-low e_reset")
    output wire        phy_reset_n
);
```

### 2.2 Clock and reset architecture

```verilog
wire gmii_tx_clk, gmii_rx_clk;
wire gmii_rx_dv, gmii_rx_er;
wire [7:0] gmii_rxd;
wire gmii_tx_en;
wire [7:0] gmii_txd;
wire gmii_crs, gmii_col;   // unused by mac_top.v, still present on util_gmii_to_rgmii's port list

util_gmii_to_rgmii u_phy_if (
    .reset            (1'b0),   // matches the ALINX reference top's own tie-off
    .rgmii_td         (rgmii_txd),
    .rgmii_tx_ctl     (rgmii_tx_ctl),
    .rgmii_txc        (rgmii_txc),
    .rgmii_rd         (rgmii_rxd),
    .rgmii_rx_ctl     (rgmii_rx_ctl),
    .rgmii_rxc        (rgmii_rxc),
    .gmii_rx_clk      (gmii_rx_clk),
    .gmii_txd         (gmii_txd),
    .gmii_tx_en       (gmii_tx_en),
    .gmii_tx_er       (1'b0),      // matches the reference tie-off
    .gmii_tx_clk      (gmii_tx_clk),
    .gmii_crs         (gmii_crs),
    .gmii_col         (gmii_col),
    .gmii_rxd         (gmii_rxd),
    .gmii_rx_dv       (gmii_rx_dv),
    .gmii_rx_er       (gmii_rx_er),
    .speed_selection  (2'b10),     // gigabit fixed, matches §4.1's 1000BASE-T
    .duplex_mode      (1'b1)       // full duplex fixed
);
```

`gmii_rx_clk` is the engine's `clk` for every module instantiated from
§2.4 onward. **`sys_clk`-domain reset generation** (a simple free-running
counter, matching D4's "`reset.v`'s pattern"):

```verilog
localparam integer PHY_RESET_HOLD_CYCLES = 500_000;  // ~10ms @ 50MHz --
    // PLACEHOLDER (§1.3): no measured JL2121(D) minimum reset pulse width
    // is on file yet; revisit against the datasheet before S11 bring-up.

reg [19:0] reset_cnt;   // wide enough for PHY_RESET_HOLD_CYCLES
reg        phy_reset_n_r;
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        reset_cnt     <= 20'd0;
        phy_reset_n_r <= 1'b0;
    end else if (reset_cnt < PHY_RESET_HOLD_CYCLES) begin
        reset_cnt <= reset_cnt + 1'b1;
    end else begin
        phy_reset_n_r <= 1'b1;
    end
end
assign phy_reset_n = phy_reset_n_r;
```

**Engine reset**, synchronized into the `gmii_rx_clk` domain (D2's
follow-on) with the already-built `rtl/common/sync_2ff.v`:

```verilog
wire engine_rst_n;
sync_2ff #(.RESET_VALUE(1'b0)) u_rst_sync (
    .clk       (gmii_rx_clk),
    .async_in  (phy_reset_n_r),
    .sync_out  (engine_rst_n)
);
```

Every module in §2.4 onward takes `.clk(gmii_rx_clk)`, `.rst_n(engine_rst_n)`.

### 2.3 PHY bring-up (`mdio_ctrl.v`)

```verilog
wire mdio_start, mdio_busy, mdio_done;

// One-shot start: pulse once phy_reset_n_r rises (sys_clk domain -- no CDC
// needed, both this trigger and mdio_ctrl.v live in the same domain).
reg phy_reset_n_d;
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) phy_reset_n_d <= 1'b0;
    else        phy_reset_n_d <= phy_reset_n_r;
end
assign mdio_start = phy_reset_n_r & ~phy_reset_n_d;

mdio_ctrl #(
    .CLK_HZ(50_000_000)   // D22 point 2 -- MUST override the 125MHz default;
                          // this instance runs on sys_clk
) u_mdio (
    .clk   (sys_clk),
    .rst_n (rst_n),
    .start (mdio_start),
    .busy  (mdio_busy),
    .done  (mdio_done),
    .mdc   (mdc),
    .mdio  (mdio)
);
```

`mdio_done` is a **one-cycle pulse** (`mdio_ctrl.v`'s own contract), not a
level — latch it for LED3 (§2.11), since a one-cycle blink is invisible:

```verilog
reg mdio_done_latched;
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n)         mdio_done_latched <= 1'b0;
    else if (mdio_done) mdio_done_latched <= 1'b1;
end
```

Never cleared except at reset — a one-shot "PHY bring-up sequence
completed" indicator, not a true link-up signal (this board's reference
tree doesn't expose one to `mdio_ctrl.v`, and adding one is out of scope
here). `mdio_done_latched` lives in the `sys_clk` domain; LED3 reading a
`sys_clk`-domain level from `gmii_rx_clk`-domain logic elsewhere needs no
synchronizer of its own — it's a slow-changing status bit read directly by
board silicon, not sampled by any clocked logic on the other side.

### 2.4 `mac_top.v` and `eth_mac_if.v`

```verilog
wire [7:0]  udp_rec_ram_rdata;
wire [10:0] udp_rec_ram_read_addr;
wire [15:0] udp_rec_data_length;
wire        udp_rec_data_valid;
wire [7:0]  ram_wr_data;
wire        ram_wr_en;
wire        almost_full;
wire [15:0] udp_send_data_length;
wire        udp_tx_req;
wire        mac_send_end;
wire        mac_rec_error, udp_checksum_error;

mac_top u_mac (
    .gmii_tx_clk  (gmii_tx_clk),
    .gmii_rx_clk  (gmii_rx_clk),
    .rst_n        (engine_rst_n),
    .source_mac_addr             (BOARD_MAC_ADDR),
    .TTL                         (BOARD_TTL),
    .source_ip_addr              (BOARD_IP_ADDR),
    .destination_ip_addr         (HOST_IP_ADDR),
    .udp_send_source_port        (BOARD_UDP_PORT),
    .udp_send_destination_port   (HOST_UDP_PORT),
    .ram_wr_data                 (ram_wr_data),
    .ram_wr_en                   (ram_wr_en),
    .udp_ram_data_req            (),   // not consumed by eth_mac_if.v (D1's boundary doesn't use it)
    .udp_send_data_length        (udp_send_data_length),
    .udp_tx_end                  (),   // not consumed (eth_mac_if.v uses mac_send_end)
    .almost_full                 (almost_full),
    .udp_tx_req                  (udp_tx_req),
    .arp_request_req             (1'b0),   // no ARP requester needed (§4.1: host sets a static ARP entry)
    .mac_data_valid               (gmii_tx_en),   // drives util_gmii_to_rgmii's input directly
    .mac_send_end                (mac_send_end),
    .mac_tx_data                 (gmii_txd),      // drives util_gmii_to_rgmii's input directly
    .rx_dv                       (gmii_rx_dv),
    .mac_rx_datain                (gmii_rxd),
    .udp_rec_ram_rdata           (udp_rec_ram_rdata),
    .udp_rec_ram_read_addr       (udp_rec_ram_read_addr),
    .udp_rec_data_length         (udp_rec_data_length),
    .udp_rec_data_valid          (udp_rec_data_valid),
    .arp_found                   (),
    .mac_not_exist                (),
    .mac_rec_error                (mac_rec_error),        // D5 -- §1.5
    .udp_checksum_error           (udp_checksum_error)    // D5 -- §1.5
);
```

(`mac_top.v`'s `mac_tx_data`/`mac_data_valid` are its own GMII TX outputs —
connecting them directly to `gmii_txd`/`gmii_tx_en`, the same wires
`util_gmii_to_rgmii`'s GMII TX inputs already use, is a plain single-driver
net; no intermediate wire needed.)

```verilog
wire [7:0]  eth_rx_data;
wire        eth_rx_valid, eth_rx_last;
wire        eth_frame_start;
wire [15:0] eth_rx_len;
wire [127:0] eth_tx_payload;
wire         eth_tx_start;
wire         eth_tx_busy;

eth_mac_if u_eth_if (
    .clk  (gmii_rx_clk),
    .rst_n(engine_rst_n),
    .rx_data (eth_rx_data), .rx_valid(eth_rx_valid), .rx_last(eth_rx_last),
    .frame_start(eth_frame_start), .rx_len(eth_rx_len),
    .tx_payload(eth_tx_payload), .tx_start(eth_tx_start), .tx_busy(eth_tx_busy),
    .udp_rec_ram_rdata(udp_rec_ram_rdata),
    .udp_rec_ram_read_addr(udp_rec_ram_read_addr),
    .udp_rec_data_length(udp_rec_data_length),
    .udp_rec_data_valid(udp_rec_data_valid),
    .ram_wr_data(ram_wr_data), .ram_wr_en(ram_wr_en), .almost_full(almost_full),
    .udp_send_data_length(udp_send_data_length), .udp_tx_req(udp_tx_req),
    .mac_send_end(mac_send_end)
);
```

### 2.5 The engine chain

All 1:1 name-matched connections (the "pin-compatible" discipline every
contract since S3 has followed) — no new signal derivation needed, just
instantiate in this order and connect identically-named ports:

```
eth_mac_if.rx_data/rx_valid  --> frame_classifier.rx_data/rx_valid
eth_mac_if.frame_start/rx_len --> frame_classifier.frame_start/rx_len
frame_classifier.out_data/out_valid --> md_parser.in_data/in_valid
                                     --> csr_block.in_data/in_valid  (§2.7 -- shared tap, D19)

md_parser.msg_valid/msg_symbol_id --> symbol_filter.msg_valid/msg_symbol_id
md_parser.msg_valid/err_msg_type/err_flags/msg_seq_num/msg_flags --> seq_monitor.*
md_parser.msg_type/msg_side/msg_price/msg_quantity --> tob_engine.msg_type/msg_side/msg_price/msg_quantity
symbol_filter.filt_valid/filt_slot --> tob_engine.filt_valid/filt_slot
seq_monitor.err_seq_dup --> tob_engine.err_seq_dup

tob_engine.next_{bid,ask}_{price,qty,valid}/next_crossed --> signal_engine.next_*
    (D23 -- NOT tob_engine's registered bid_price/ask_price/etc bus, which is
    one message stale on book_upd_valid's own cycle;
    docs/contracts/tob_engine_signal_patch.md)
tob_engine.book_upd_valid/applied_slot --> signal_engine.book_upd_valid/applied_slot

signal_engine.sig_* --> risk_engine.sig_*
tob_engine.{bid,ask}_{price,qty,valid}/crossed --> risk_engine.* (the REGISTERED
    bus -- correct here, unlike signal_engine.v: risk_engine reads it at
    sig_slot, at least one cycle after book_upd_valid, by which point the
    register write has already committed, D23)
seq_monitor.seq_gap --> risk_engine.seq_gap
risk_engine.kill_sw_n <= key_in[0] (through a sync_2ff.v instance, §2.10)
risk_engine.adverse_risk = 1'b0  (§1.3 -- no ML path yet)

risk_engine.order_* /reject_reason --> order_builder.order_*/reject_reason
md_parser.msg_seq_num --> order_builder.msg_seq_num
order_builder.tx_payload/tx_start --> eth_tx_payload/eth_tx_start (through the TX arbiter, §2.8)
eth_tx_busy --> order_builder.tx_busy (directly -- order_builder never waits on the arbiter, §2.8)
```

`cur_cycle` (§2.9) fans out to `risk_engine.cur_cycle` and
`order_builder.cur_cycle` identically (both already take it as the same
free-running counter per their own contracts).

### 2.6 `csr_block.v` and `latency_histogram.v`

```verilog
csr_block u_csr (
    .clk(gmii_rx_clk), .rst_n(engine_rst_n),
    .in_data(eth_rx_data /* frame_classifier's out_data, shared tap, D19 */),
    .in_valid(/* frame_classifier's out_valid */),
    .resp_payload(csr_resp_payload), .resp_start(csr_resp_start), .resp_busy(csr_resp_busy),
    // cfg_* outputs -> every consumer's identically-named cfg_* input
    // (symbol_filter.v, seq_monitor.v, signal_engine.v, risk_engine.v,
    // order_builder.v, feature_normalizer.v -- N/A here per §1.3)
    ...
    // STATUS-feeding inputs
    .kill_latched(risk_engine_kill_latched), .seq_gap(seq_monitor_seq_gap), .crossed(tob_engine_crossed),
    // pulse inputs -- one-to-one from every module's identically-named
    // err_*/cnt_*_pulse/gate_*_fired/filt_dropped/filt_valid output
    .frame_start(eth_frame_start),
    .err_frame_len(frame_classifier_err_frame_len),
    .md_msg_valid(md_parser_msg_valid), .err_msg_type(...), .err_flags(...),
    .err_fcs(mac_rec_error), .err_ethertype(1'b0), .err_ip(udp_checksum_error), .err_udp_port(1'b0),  // §1.5
    .filt_valid(...), .filt_dropped(...),
    .err_seq_dup(...), .seq_gap_pulse(...),
    .cnt_book_clear_pulse(...), .cnt_trades_pulse(...), .cnt_heartbeats_pulse(...), .cnt_crossed_pulse(...),
    .sig_valid(...), .sig_side(...), .err_signal_conflict(...),
    .ml_event_valid(1'b0), .ml_adverse_pulse(1'b0), .ml_benign_pulse(1'b0), .ml_safe_forced_pulse(1'b0),  // §1.3
    .gate_kill_fired(...), /* ... all 9 gates ... */
    .ob_tx_start(ob_tx_start), .ob_tx_payload(ob_tx_payload), .cnt_order_overflow_pulse(...),
    .lat_valid(hist_lat_valid), .lat_value(hist_lat_value),
    .counter_clear_pulse(counter_clear_pulse),           // §1.4 patch 1
    .hist_rd_addr(hist_rd_addr), .hist_rd_data(hist_rd_data)  // §1.4 patch 2
);

latency_histogram u_hist (
    .clk(gmii_rx_clk), .rst_n(engine_rst_n),
    .ob_tx_start(ob_tx_start), .ob_tx_payload(ob_tx_payload),
    .cfg_counter_clear(counter_clear_pulse),
    .lat_valid(hist_lat_valid), .lat_value(hist_lat_value),
    .hist_rd_addr(hist_rd_addr), .hist_rd_data(hist_rd_data)
);
```

`ob_tx_start`/`ob_tx_payload` here are **`order_builder.v`'s own outputs**,
tapped directly (both `csr_block.v` and `latency_histogram.v` already
expect exactly this tap per their own contracts) — not the arbiter's
output. Neither module needs to know the arbiter exists.

### 2.7 CSR ingress tap (D19 point 1)

`frame_classifier.v`'s `out_data`/`out_valid` fan out to **two**
independent listeners: `md_parser.in_data`/`in_valid` (unchanged) and
`csr_block.in_data`/`in_valid` (new). A plain wire fan-out — no arbitration
needed, since each module's own byte-serial decode ignores frames whose
`msg_type` it doesn't recognize (§1.1 of `docs/contracts/csr_block.md`).

### 2.8 TX arbitration (D22 point 1)

```verilog
assign eth_tx_payload  = ob_tx_start ? ob_tx_payload : csr_resp_payload;
assign eth_tx_start    = ob_tx_start | (csr_resp_start & ~ob_tx_start);
assign csr_resp_busy   = eth_tx_busy | ob_tx_start;
```

`order_builder.v`'s request always wins and is never delayed by this mux
(`eth_tx_busy` feeds `order_builder.tx_busy` directly, §2.5 — the arbiter
sits only on the payload/start side, never in `order_builder.v`'s own
busy-sensing path). `csr_block.v`'s `resp_busy` input reflects the shared
path's real busy state OR'd with "the fast path wants this cycle," so its
own already-built self-gate (`~resp_busy & ~resp_start`) correctly holds
off with zero new logic inside `csr_block.v`. A simultaneous request from
both is `order_builder.v`'s win, and the CSR read is silently dropped —
already the accepted behavior of `csr_block.v`'s own busy-drop policy, not
a new failure mode.

### 2.9 `cur_cycle`

```verilog
reg [31:0] cur_cycle;
always @(posedge gmii_rx_clk or negedge engine_rst_n) begin
    if (!engine_rst_n) cur_cycle <= 32'd0;
    else                cur_cycle <= cur_cycle + 32'd1;
end
```

Free-running, never cleared except at reset (FR-53) — the same counter
`risk_engine.v`/`order_builder.v` have always expected as a plain input,
now with a real source.

### 2.10 Kill switch

```verilog
wire kill_sw_n_sync;
sync_2ff #(.RESET_VALUE(1'b1)) u_kill_sync (   // idle-high (active-low switch, not pressed)
    .clk(gmii_rx_clk), .async_in(key_in[0]), .sync_out(kill_sw_n_sync)
);
```

Feeds `risk_engine.kill_sw_n` directly. `key_in[0]` is an asynchronous
physical pushbutton — routed through `sync_2ff.v` (the same 2-FF
synchronizer used for the reset-release edge, §2.2) since it crosses into
the `gmii_rx_clk` domain with no other timing relationship to it.

### 2.11 LED assignment

Not spec-mandated (§3.1 only says "LED[3:0] status") — a plain diagnostic
choice, documented here so it's not re-litigated later:

```verilog
assign led[0] = cur_cycle[24];              // heartbeat, ~3.7 Hz @ 125MHz (same idea as the S0 skeleton)
assign led[1] = risk_engine_kill_latched;   // kill latch status
assign led[2] = csr_status_bit[1] | csr_status_bit[2] | csr_status_bit[3];  // any sticky fault (seq-gap/crossed/stale)
assign led[3] = mdio_done_latched;          // PHY bring-up sequence completed
```

`csr_status_bit[N]` means reading `csr_block.v`'s own internal
`STATUS`-feeding sticky signals directly (`status_seq_gap`/`status_crossed`/
`status_stale`) rather than round-tripping through a CSR read — these are
plain internal `reg`s in `csr_block.v`, not currently exposed as ports;
either expose them as new outputs (same category as the two §1.4 patches)
or, more simply, OR together the *inputs* that feed them
(`seq_gap_pulse`/`(|tob_engine_crossed)`/`gate_stale_fired`) directly at
this integration level — either is acceptable, this LED is diagnostic
only, not a correctness-gating signal.

## 3. Testbench requirements (`tb/tb_tob_top.v`)

**Connectivity/smoke-level, not a re-run of every module's own behavior**
(§1.3) — every module wired here already has its own exhaustive,
independently-verified testbench. This testbench exists to catch **wiring
mistakes**: a swapped port, a missing connection, an inverted polarity.
Self-checking, Icarus-runnable. Since `mac_top.v`/`util_gmii_to_rgmii.v`
involve vendor RTL with its own timing (D1's `TX_HEADER_DELAY` etc.,
already verified standalone by `tb/tb_eth_mac_if_rx.v`/`tb_eth_mac_if_tx.v`),
drive this testbench at `mac_top.v`'s own boundary — `udp_rec_ram_rdata`/
`udp_rec_data_length`/`udp_rec_data_valid` in, `ram_wr_data`/`ram_wr_en`/
`udp_tx_req`/`mac_send_end` out — the same boundary those two testbenches
already exercise, so `mac_top.v`/`util_gmii_to_rgmii.v` do not need to be
instantiated in *this* testbench at all (matching D22 point 3's own
reasoning for why `tb_top.v`'s eventual soak works the same way). Cover,
at minimum:

- **One message end-to-end:** drive one well-formed 16-byte QUOTE message
  (watched symbol, spread/imbalance shaped to fire the signal) through the
  `udp_rec_*` boundary, confirm a `0x10` NEW order eventually appears on
  the `ram_wr_data`/`udp_tx_req` boundary with the expected fields — proof
  the whole chain (`frame_classifier` → ... → `order_builder` → the TX
  arbiter → `eth_mac_if`) is correctly wired end to end.
- **CSR write/read round trip through the shared tap:** drive a `0x20`
  write frame through the same `udp_rec_*` boundary (e.g. `MAX_ORDER_QTY`),
  confirm the corresponding `cfg_max_order_qty` net (probed via
  hierarchical reference) changed; drive a `0x21` read request, confirm a
  `0x22` response appears via the TX arbiter with the written value.
- **TX arbiter priority:** engineer a cycle where `order_builder.v` and
  `csr_block.v` both want to transmit simultaneously (drive an accepted
  order and a pending CSR read request to land the same cycle); confirm
  the order's `0x10` frame goes out, not the CSR response, and confirm the
  dropped CSR response does not corrupt any subsequent read.
- **`err_fcs`/`err_ip` wiring (§1.5):** force `mac_rec_error`/
  `udp_checksum_error` (via hierarchical force on the `mac_top.v`-boundary
  stand-in, since this testbench doesn't instantiate the real vendor
  module) and confirm `csr_block.v`'s corresponding counters increment.
- **`mdio_ctrl.v` CLK_HZ (D22 point 2):** confirm the instantiation in
  `rtl/tob_top.v` actually specifies `.CLK_HZ(50_000_000)` — a static
  source-level check (`grep`/inspection) is acceptable here in lieu of a
  simulated MDC-frequency measurement, since `mdio_ctrl.v`'s own behavior
  at a given `CLK_HZ` is already covered by `tb/tb_mdio_ctrl.v`.
- On any mismatch, `$display` what was expected vs. actual, then a final
  `$display("FAIL")` / `$display("PASS")` line.

## 4. Acceptance criteria

- [ ] `iverilog -g2001 -Wall` compiles `rtl/tob_top.v` plus every module it
      instantiates with zero warnings (excluding pre-existing vendor-tree
      warnings, if any, which are not this contract's to fix).
- [ ] `tb/tb_tob_top.v` prints `PASS`.
- [ ] `rtl/tob_top.v` itself is Verilog-2001 only; vendor files
      (`rtl/vendor/alinx_mac/*`) are untouched except the already-applied
      D5 patch.
- [ ] The two `csr_block.v` patches (§1.4) are applied and
      `tb/tb_csr_block.v` still passes, unmodified, after both.
- [ ] `mdio_ctrl.v` is instantiated with `.CLK_HZ(50_000_000)`, not the
      125 MHz default (D22 point 2).
- [ ] `order_builder.v`'s TX request is never delayed by the arbiter (its
      own `tx_busy` input comes directly from `eth_mac_if.v`, not gated by
      `csr_block.v`'s request state).
- [ ] `csr_block.v`'s `resp_busy` correctly reflects both the shared path's
      real busy state and `order_builder.v`'s own current request.
- [ ] `err_fcs`/`err_ip` are wired to `mac_rec_error`/`udp_checksum_error`;
      `err_ethertype`/`err_udp_port` remain tied to `0` (§1.5 — no real
      source exists yet, not a mistake).
- [ ] No inferred latches; every `reg` assigned on every path through its
      `always` block or has a clear default.

## 5. Explicitly out of scope

- `feature_extractor.v`/`feature_normalizer.v`/`ml_classifier_wrap.v`/
  `ml_policy.v`/the `[ALIGN]` shift register — S6, blocked on S4, not
  instantiated here (§1.3).
- `tb/tb_top.v`'s own T26 1,000,000-message soak — a separate, later task;
  §3's testbench here is connectivity-level only (§1.3).
- `stats_reporter.v`'s periodic `0x12` stats-frame emission and
  `debug_uart.v`'s UART fallback ingress (FR-59) — separate modules,
  neither built yet, no interaction with this contract.
- XDC constraints (`constraints/tob_pins.xdc`/`tob_timing.xdc`), synthesis,
  timing closure, utilization reporting — S10's *later* phase (`WNS > 0`,
  NFR-7) and S12, not this contract; this contract only needs to compile
  and simulate correctly.
- The exact PHY hardware-reset hold duration — a placeholder value is used
  (§2.2), explicitly flagged as provisional pending the real datasheet
  figure or S11 board measurement.
- Real host `HOST_IP_ADDR`/port deployment values — placeholder parameters
  (§2.1); the actual host's address isn't specified anywhere in the master
  spec and must be filled in before real hardware bring-up.
- A true PHY link-up status signal for LED3 — `mdio_done` (bring-up
  sequence completed) stands in; this board's reference tree doesn't wire
  a link-up bit to `mdio_ctrl.v` and adding one is out of scope here.
