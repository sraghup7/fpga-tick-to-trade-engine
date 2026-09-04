`timescale 1ns / 1ps

// Simulation-only stand-ins for the two vendor RGMII/MAC leaf modules
// tob_top.v instantiates. NEVER synthesized, never part of the real build
// (scripts/build.tcl / rtl/vendor/alinx_mac/ are authoritative).
//
// Why these exist: rtl/vendor/alinx_mac/util_gmii_to_rgmii.v instantiates
// Xilinx ODDR/IDDR/BUFG primitives (no Icarus sim models exist), and
// mac_top.v's full RX path needs real Ethernet frames. tob_top's own
// testbench (tb/tb_tob_top.v) drives at mac_top.v's UDP boundary instead
// (contract S3), so it binds tob_top's `mac_top`/`util_gmii_to_rgmii`
// instantiations to these behavioral stand-ins by compiling this file in
// place of the vendor RTL. Same substitution discipline as
// tb/sim_models/xilinx_ip_sim_models.v.
//
// The mac_top stand-in exposes forceable scalar test hooks (rx_frame /
// udp_rec_data_length / udp_rec_data_valid / mac_rec_error /
// udp_checksum_error) so the testbench can inject a received UDP payload
// and confirm the engine's TX path byte-for-byte through the same boundary
// tb/tb_eth_mac_if_rx.v / tb_eth_mac_if_tx.v already exercise.
//
// Verilog-2001 only.

// ---------------------------------------------------------------------
// util_gmii_to_rgmii stand-in: the only parts tob_top's engine depends on
// are the two clocks (gmii_rx_clk recovered from rgmii_rxc; gmii_tx_clk
// tied to it, per D2) and quiet RX lines. TX nibbles are passed through
// combinationally for completeness -- nothing in the testbench consumes
// them.
// ---------------------------------------------------------------------
module util_gmii_to_rgmii (
    input           reset,
    output [3:0]    rgmii_td,
    output          rgmii_tx_ctl,
    output          rgmii_txc,
    input  [3:0]    rgmii_rd,
    input           rgmii_rx_ctl,
    output          gmii_rx_clk,
    input           rgmii_rxc,
    input  [7:0]    gmii_txd,
    input           gmii_tx_en,
    input           gmii_tx_er,
    output          gmii_tx_clk,
    output          gmii_crs,
    output          gmii_col,
    output [7:0]    gmii_rxd,
    output          gmii_rx_dv,
    output          gmii_rx_er,
    input  [1:0]    speed_selection,
    input           duplex_mode
);
    assign gmii_rx_clk = rgmii_rxc;
    assign gmii_tx_clk = rgmii_rxc;
    assign rgmii_txc   = rgmii_rxc;
    assign rgmii_td    = gmii_txd[3:0];
    assign rgmii_tx_ctl = gmii_tx_en;
    assign gmii_rxd    = 8'd0;
    assign gmii_rx_dv  = 1'b0;
    assign gmii_rx_er  = 1'b0;
    assign gmii_crs    = 1'b0;
    assign gmii_col    = 1'b0;
endmodule

// ---------------------------------------------------------------------
// mac_top stand-in: emulates the eth_mac_if.v-facing UDP boundary.
//   RX: a registered-read RAM whose contents the testbench supplies by
//       forcing `sim_rx_frame` (<= 16 payload bytes). udp_rec_data_valid /
//       udp_rec_data_length are plain regs with no internal driver, so the
//       testbench drives them with force/release exactly the way
//       tb_eth_mac_if_rx.v drives its mocked boundary.
//   TX: captures the 16 ram_wr_data bytes after each udp_tx_req and pulses
//       mac_send_end when done, mirroring mac_top.v's mac_send_end handshake
//       eth_mac_if.v's TX FSM waits on. The testbench reads tx_ram[] /
//       tx_frame_cnt after waiting for a capture.
// ---------------------------------------------------------------------
module mac_top (
    input                gmii_tx_clk,
    input                gmii_rx_clk,
    input                rst_n,
    input  [47:0]        source_mac_addr,
    input  [7:0]         TTL,
    input  [31:0]        source_ip_addr,
    input  [31:0]        destination_ip_addr,
    input  [15:0]        udp_send_source_port,
    input  [15:0]        udp_send_destination_port,
    input  [7:0]         ram_wr_data,
    input                ram_wr_en,
    output               udp_ram_data_req,
    input  [15:0]        udp_send_data_length,
    output               udp_tx_end,
    output               almost_full,
    input                udp_tx_req,
    input                arp_request_req,
    output               mac_data_valid,
    output               mac_send_end,
    output [7:0]         mac_tx_data,
    input                rx_dv,
    input  [7:0]         mac_rx_datain,
    output reg [7:0]     udp_rec_ram_rdata,
    input  [10:0]        udp_rec_ram_read_addr,
    output reg [15:0]    udp_rec_data_length,
    output reg           udp_rec_data_valid,
    output               arp_found,
    output               mac_not_exist,
    output reg           mac_rec_error,
    output reg           udp_checksum_error
);

    assign udp_ram_data_req = 1'b0;
    assign udp_tx_end       = 1'b0;
    assign almost_full      = 1'b0;
    assign mac_data_valid   = 1'b0;
    assign mac_tx_data      = 8'd0;
    assign arp_found        = 1'b0;
    assign mac_not_exist    = 1'b0;

    // ---- RX test hooks (driven by force from the testbench) ----
    reg [127:0] sim_rx_frame = 128'd0;   // up to a 16-byte UDP payload

    // registered read of the "receive RAM", mirroring the real mac / the
    // tb_eth_mac_if_rx.v mock
    always @(posedge gmii_rx_clk) begin
        if (udp_rec_ram_read_addr < 16'd16)
            udp_rec_ram_rdata <= sim_rx_frame[(127 - 8*udp_rec_ram_read_addr) -: 8];
        else
            udp_rec_ram_rdata <= 8'h00;
    end

    // udp_rec_data_length / udp_rec_data_valid / mac_rec_error /
    // udp_checksum_error intentionally have NO internal driver: the
    // testbench owns them via force/release. Default them to 0 so the
    // engine never sees X before the first force.
    initial begin
        udp_rec_data_length = 16'd0;
        udp_rec_data_valid  = 1'b0;
        mac_rec_error       = 1'b0;
        udp_checksum_error  = 1'b0;
    end

    // ---- TX capture ----
    reg [7:0] tx_ram [0:15];
    reg [4:0] tx_wr_cnt;
    reg       tx_run;
    reg       mac_send_end;
    integer   tx_frame_cnt;

    always @(posedge gmii_rx_clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_run        <= 1'b0;
            tx_wr_cnt     <= 5'd0;
            mac_send_end  <= 1'b0;
            tx_frame_cnt  <= 0;
        end else begin
            mac_send_end <= 1'b0;
            if (udp_tx_req) begin
                tx_run    <= 1'b1;
                tx_wr_cnt <= 5'd0;
            end
            if (tx_run && ram_wr_en) begin
                tx_ram[tx_wr_cnt[3:0]] <= ram_wr_data;
                if (tx_wr_cnt == 5'd15) begin
                    tx_run       <= 1'b0;
                    mac_send_end <= 1'b1;
                    tx_frame_cnt <= tx_frame_cnt + 1;
                end else begin
                    tx_wr_cnt <= tx_wr_cnt + 1'b1;
                end
            end
        end
    end

endmodule
