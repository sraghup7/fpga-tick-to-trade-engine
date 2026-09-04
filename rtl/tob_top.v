`timescale 1ns / 1ps

// rtl/tob_top.v
//
// Board-level integration top (master spec S3.1 full block diagram, S13's
// rtl/ tree top; contract docs/contracts/tob_top.md). Physical
// RGMII/MDIO/KEY/LED pins in, a fully wired tick-to-trade engine inside.
// Replaces the S0 skeleton. Every instantiated module is already
// independently contracted and verified; this file's job is the WIRING.
//
// Two clock domains (D2): the whole engine runs on `gmii_rx_clk`, the
// RGMII receive clock recovered inside util_gmii_to_rgmii.v (ALINX's MAC
// ties gmii_tx_clk straight from gmii_rx_clk, so there is genuinely one
// 125 MHz domain for the datapath). `sys_clk` (50 MHz board oscillator)
// is retained only for PHY reset sequencing and mdio_ctrl.v -- a separate
// domain whose only exchange with the engine is the reset-release edge,
// crossed via sync_2ff.v into the engine's clock domain.
//
// D22 decisions implemented here:
//   * TX arbitration (D22 point 1): order_builder.v (fast path) always
//     wins the single eth_mac_if.v tx_payload/tx_start/tx_busy interface.
//     csr_block.v's resp_busy reflects the shared path's real busy OR'd
//     with order_builder's current request, so its own built-in
//     ~resp_busy & ~resp_start self-gate holds off with zero new logic.
//   * mdio_ctrl.v MUST be instantiated with .CLK_HZ(50_000_000) -- it runs
//     off sys_clk here, and its default (125 MHz) would silently overrun
//     IEEE 802.3 clause 22's 2.5 MHz MDC maximum (D22 point 2).
//   * No ML path (D22 point 3): feature_extractor/feature_normalizer are
//     not instantiated; risk_engine's adverse_risk is tied to 1'b0.
//   * err_fcs/err_ip are wired from mac_top's D5 outputs
//     (mac_rec_error / udp_checksum_error); err_ethertype/err_udp_port
//     stay tied to 0 -- mac_top exposes no distinct signal for either.
//
// Host addresses are compile-time parameters (not CSR-configurable); the
// defaults are placeholders per the contract -- real values must be set
// before S11 hardware bring-up.
//
// Verilog-2001 only.

module tob_top #(
    parameter [47:0] BOARD_MAC_ADDR  = 48'h00_0a_35_01_02_03,  // S4.1 static-ARP example
    parameter [31:0] BOARD_IP_ADDR   = {8'd192, 8'd168, 8'd1, 8'd10},
    parameter [7:0]  BOARD_TTL       = 8'd64,
    parameter [31:0] HOST_IP_ADDR    = {8'd192, 8'd168, 8'd1, 8'd1},   // PLACEHOLDER
    parameter [15:0] HOST_UDP_PORT   = 16'd60000,   // matches cfg_udp_port's default
    parameter [15:0] BOARD_UDP_PORT  = 16'd60001,
    // PHY reset hold in sys_clk cycles (~10 ms at 50 MHz). PLACEHOLDER per
    // the contract: no measured JL2121(D) minimum is on file yet (S11). The
    // default is the production value; the parameter exists so the Icarus
    // testbench can shorten the 10 ms hold -- simulation-only, default
    // behaviour is unchanged.
    parameter integer PHY_RESET_HOLD_CYCLES = 500_000
) (
    input  wire        sys_clk,   // 50 MHz board oscillator
    input  wire        rst_n,     // active-low pushbutton reset
    input  wire [3:0]  key_in,    // KEY1..KEY4, active-low; key_in[0] = kill switch
    output wire [3:0]  led,

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

    // PHY hardware reset (D4: active-low)
    output wire        phy_reset_n
);

    // =====================================================================
    // S2.2 clocks: gmii_rx_clk recovered from rgmii_rxc by util_gmii_to_rgmii
    // =====================================================================
    wire gmii_tx_clk, gmii_rx_clk;
    wire gmii_rx_dv, gmii_rx_er;
    wire [7:0] gmii_rxd;
    wire gmii_tx_en;
    wire [7:0] gmii_txd;
    wire gmii_crs, gmii_col;

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
        .gmii_tx_er       (1'b0),   // matches the reference tie-off
        .gmii_tx_clk      (gmii_tx_clk),
        .gmii_crs         (gmii_crs),
        .gmii_col         (gmii_col),
        .gmii_rxd         (gmii_rxd),
        .gmii_rx_dv       (gmii_rx_dv),
        .gmii_rx_er       (gmii_rx_er),
        .speed_selection  (2'b10),  // gigabit fixed (S4.1's 1000BASE-T)
        .duplex_mode      (1'b1)    // full duplex fixed
    );

    // ---- sys_clk-domain reset generation (D4's reset.v pattern) ----
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

    // ---- engine reset, synchronized into the gmii_rx_clk domain ----
    wire engine_rst_n;
    sync_2ff #(.RESET_VALUE(1'b0)) u_rst_sync (
        .clk      (gmii_rx_clk),
        .rst_n    (phy_reset_n_r),   // async reset held while the PHY reset is low
        .async_in (phy_reset_n_r),
        .sync_out (engine_rst_n)
    );

    // =====================================================================
    // S2.3 PHY bring-up (mdio_ctrl.v -- sys_clk domain)
    // =====================================================================
    wire mdio_start, mdio_busy, mdio_done;

    // One-shot start: pulse once phy_reset_n_r rises (same domain as
    // mdio_ctrl.v, no CDC needed).
    reg phy_reset_n_d;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) phy_reset_n_d <= 1'b0;
        else        phy_reset_n_d <= phy_reset_n_r;
    end
    assign mdio_start = phy_reset_n_r & ~phy_reset_n_d;

    mdio_ctrl #(
        .CLK_HZ(50_000_000)   // D22 point 2 -- MUST override the 125 MHz
                              // default; this instance runs on sys_clk
    ) u_mdio (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .start (mdio_start),
        .busy  (mdio_busy),
        .done  (mdio_done),
        .mdc   (mdc),
        .mdio  (mdio)
    );

    // mdio_done is a one-cycle pulse -- latch it for LED3.
    reg mdio_done_latched;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)         mdio_done_latched <= 1'b0;
        else if (mdio_done) mdio_done_latched <= 1'b1;
    end

    // =====================================================================
    // S2.4 mac_top.v and eth_mac_if.v
    // =====================================================================
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
        .gmii_tx_clk              (gmii_tx_clk),
        .gmii_rx_clk              (gmii_rx_clk),
        .rst_n                    (engine_rst_n),
        .source_mac_addr          (BOARD_MAC_ADDR),
        .TTL                      (BOARD_TTL),
        .source_ip_addr           (BOARD_IP_ADDR),
        .destination_ip_addr      (HOST_IP_ADDR),
        .udp_send_source_port     (BOARD_UDP_PORT),
        .udp_send_destination_port(HOST_UDP_PORT),
        .ram_wr_data              (ram_wr_data),
        .ram_wr_en                (ram_wr_en),
        .udp_ram_data_req         (),   // not consumed by eth_mac_if.v (D1)
        .udp_send_data_length     (udp_send_data_length),
        .udp_tx_end               (),   // eth_mac_if.v uses mac_send_end
        .almost_full              (almost_full),
        .udp_tx_req               (udp_tx_req),
        .arp_request_req          (1'b0),   // static ARP on the host (S4.1)
        .mac_data_valid           (gmii_tx_en),   // -> util_gmii_to_rgmii
        .mac_send_end             (mac_send_end),
        .mac_tx_data              (gmii_txd),    // -> util_gmii_to_rgmii
        .rx_dv                    (gmii_rx_dv),
        .mac_rx_datain            (gmii_rxd),
        .udp_rec_ram_rdata        (udp_rec_ram_rdata),
        .udp_rec_ram_read_addr    (udp_rec_ram_read_addr),
        .udp_rec_data_length      (udp_rec_data_length),
        .udp_rec_data_valid       (udp_rec_data_valid),
        .arp_found                (),
        .mac_not_exist            (),
        .mac_rec_error            (mac_rec_error),     // D5
        .udp_checksum_error       (udp_checksum_error) // D5
    );

    wire [7:0]  eth_rx_data;
    wire        eth_rx_valid, eth_rx_last;
    wire        eth_frame_start;
    wire [15:0] eth_rx_len;
    wire [127:0] eth_tx_payload;
    wire         eth_tx_start;
    wire         eth_tx_busy;

    eth_mac_if u_eth_if (
        .clk                     (gmii_rx_clk),
        .rst_n                   (engine_rst_n),
        .rx_data                 (eth_rx_data),
        .rx_valid                (eth_rx_valid),
        .rx_last                 (eth_rx_last),
        .frame_start             (eth_frame_start),
        .rx_len                  (eth_rx_len),
        .tx_payload              (eth_tx_payload),
        .tx_start                (eth_tx_start),
        .tx_busy                 (eth_tx_busy),
        .udp_rec_ram_rdata       (udp_rec_ram_rdata),
        .udp_rec_ram_read_addr   (udp_rec_ram_read_addr),
        .udp_rec_data_length     (udp_rec_data_length),
        .udp_rec_data_valid      (udp_rec_data_valid),
        .ram_wr_data             (ram_wr_data),
        .ram_wr_en               (ram_wr_en),
        .almost_full             (almost_full),
        .udp_send_data_length    (udp_send_data_length),
        .udp_tx_req              (udp_tx_req),
        .mac_send_end            (mac_send_end)
    );

    // =====================================================================
    // S2.5 engine chain -- frame_classifier -> md_parser -> ... -> order_builder
    // =====================================================================
    wire [7:0] fc_out_data;
    wire        fc_out_valid;
    wire        fc_err_frame_len;
    frame_classifier u_fc (
        .clk           (gmii_rx_clk),
        .rst_n         (engine_rst_n),
        .rx_data       (eth_rx_data),
        .rx_valid      (eth_rx_valid),
        .frame_start   (eth_frame_start),
        .rx_len        (eth_rx_len),
        .out_data      (fc_out_data),
        .out_valid     (fc_out_valid),
        .err_frame_len (fc_err_frame_len)
    );

    wire        md_msg_valid;
    wire [7:0]  md_msg_type;
    wire [7:0]  md_msg_symbol_id;
    wire [7:0]  md_msg_side;
    wire [7:0]  md_msg_flags;
    wire [31:0] md_msg_price;
    wire [31:0] md_msg_quantity;
    wire [31:0] md_msg_seq_num;
    wire        md_err_msg_type;
    wire        md_err_flags;

    md_parser u_md (
        .clk           (gmii_rx_clk),
        .rst_n         (engine_rst_n),
        .in_data       (fc_out_data),
        .in_valid      (fc_out_valid),
        .msg_valid     (md_msg_valid),
        .msg_type      (md_msg_type),
        .msg_symbol_id (md_msg_symbol_id),
        .msg_side      (md_msg_side),
        .msg_flags     (md_msg_flags),
        .msg_price     (md_msg_price),
        .msg_quantity  (md_msg_quantity),
        .msg_seq_num   (md_msg_seq_num),
        .err_msg_type  (md_err_msg_type),
        .err_flags     (md_err_flags)
    );

    wire        filt_valid;
    wire [1:0]  filt_slot;
    wire        filt_dropped;
    wire [7:0]  cfg_symbol_0, cfg_symbol_1, cfg_symbol_2, cfg_symbol_3;
    wire [3:0]  cfg_symbol_en;

    symbol_filter u_sym (
        .clk           (gmii_rx_clk),
        .rst_n         (engine_rst_n),
        .msg_valid     (md_msg_valid),
        .msg_symbol_id (md_msg_symbol_id),
        .cfg_symbol_0  (cfg_symbol_0),
        .cfg_symbol_1  (cfg_symbol_1),
        .cfg_symbol_2  (cfg_symbol_2),
        .cfg_symbol_3  (cfg_symbol_3),
        .cfg_symbol_en (cfg_symbol_en),
        .filt_valid    (filt_valid),
        .filt_slot     (filt_slot),
        .filt_dropped  (filt_dropped)
    );

    wire        err_seq_dup;
    wire [31:0] seq_gap_amount;
    wire        seq_gap_pulse;
    wire        seq_gap;
    wire        cfg_seq_gap_clear;

    seq_monitor u_seq (
        .clk              (gmii_rx_clk),
        .rst_n            (engine_rst_n),
        .msg_valid        (md_msg_valid),
        .err_msg_type     (md_err_msg_type),
        .err_flags        (md_err_flags),
        .msg_seq_num      (md_msg_seq_num),
        .msg_flags        (md_msg_flags),
        .cfg_seq_gap_clear(cfg_seq_gap_clear),
        .err_seq_dup      (err_seq_dup),
        .seq_gap_amount   (seq_gap_amount),
        .seq_gap_pulse    (seq_gap_pulse),
        .seq_gap          (seq_gap)
    );

    wire        msg_applied;
    wire [1:0]  applied_slot;
    wire        book_upd_valid;
    wire        cnt_book_clear_pulse;
    wire        cnt_trades_pulse;
    wire        cnt_heartbeats_pulse;
    wire        cnt_crossed_pulse;
    wire [127:0] bid_price, bid_qty;
    wire [3:0]   bid_valid;
    wire [127:0] ask_price, ask_qty;
    wire [3:0]   ask_valid;
    wire [3:0]   crossed;

    // D23: post-update ("next") state of the applied slot -- signal_engine.v
    // reads these (below), not the registered buses above, which are one
    // message stale on book_upd_valid's own cycle. risk_engine.v still
    // reads the registered buses above, at sig_slot, at least one cycle
    // later -- already post-update by the time it gets there (D23, confirmed
    // unaffected).
    wire [31:0] next_bid_price, next_bid_qty;
    wire         next_bid_valid;
    wire [31:0] next_ask_price, next_ask_qty;
    wire         next_ask_valid;
    wire         next_crossed;

    tob_engine u_tob (
        .clk                 (gmii_rx_clk),
        .rst_n               (engine_rst_n),
        .msg_type            (md_msg_type),
        .msg_side            (md_msg_side),
        .msg_price           (md_msg_price),
        .msg_quantity        (md_msg_quantity),
        .filt_valid          (filt_valid),
        .filt_slot           (filt_slot),
        .err_seq_dup         (err_seq_dup),
        .msg_applied         (msg_applied),
        .applied_slot        (applied_slot),
        .book_upd_valid      (book_upd_valid),
        .cnt_book_clear_pulse(cnt_book_clear_pulse),
        .cnt_trades_pulse    (cnt_trades_pulse),
        .cnt_heartbeats_pulse(cnt_heartbeats_pulse),
        .cnt_crossed_pulse   (cnt_crossed_pulse),
        .bid_price           (bid_price),
        .bid_qty             (bid_qty),
        .bid_valid           (bid_valid),
        .ask_price           (ask_price),
        .ask_qty             (ask_qty),
        .ask_valid           (ask_valid),
        .crossed             (crossed),
        .next_bid_price      (next_bid_price),
        .next_bid_qty        (next_bid_qty),
        .next_bid_valid      (next_bid_valid),
        .next_ask_price      (next_ask_price),
        .next_ask_qty        (next_ask_qty),
        .next_ask_valid      (next_ask_valid),
        .next_crossed        (next_crossed)
    );

    wire        sig_valid;
    wire [1:0]  sig_slot;
    wire [7:0]  sig_side;
    wire [31:0] sig_price;
    wire [31:0] sig_qty;
    wire        err_signal_conflict;
    wire [31:0] cfg_min_spread;
    wire [1:0]  cfg_imb_shift;
    wire [31:0] cfg_order_qty;

    signal_engine u_sig (
        .clk                 (gmii_rx_clk),
        .rst_n               (engine_rst_n),
        .book_upd_valid      (book_upd_valid),
        .applied_slot        (applied_slot),
        .next_bid_price      (next_bid_price),
        .next_bid_qty        (next_bid_qty),
        .next_bid_valid      (next_bid_valid),
        .next_ask_price      (next_ask_price),
        .next_ask_qty        (next_ask_qty),
        .next_ask_valid      (next_ask_valid),
        .next_crossed        (next_crossed),
        .cfg_min_spread      (cfg_min_spread),
        .cfg_imb_shift       (cfg_imb_shift),
        .cfg_order_qty       (cfg_order_qty),
        .sig_valid           (sig_valid),
        .sig_slot            (sig_slot),
        .sig_side            (sig_side),
        .sig_price           (sig_price),
        .sig_qty             (sig_qty),
        .err_signal_conflict (err_signal_conflict)
    );

    wire [31:0] cfg_max_order_qty;
    wire [31:0] cfg_max_position;
    wire [31:0] cfg_price_band;
    wire [31:0] cfg_max_age;
    wire [31:0] cfg_token_max;
    wire [31:0] cfg_token_refill_cycles;
    wire        cfg_ml_action;
    wire [3:0]  cfg_ml_reduce_shift;
    wire        cfg_kill_clear;

    wire kill_sw_n_sync;
    sync_2ff #(.RESET_VALUE(1'b1)) u_kill_sync (   // idle-high (not pressed)
        .clk      (gmii_rx_clk),
        .rst_n    (engine_rst_n),
        .async_in (key_in[0]),
        .sync_out (kill_sw_n_sync)
    );

    wire        order_valid;
    wire [1:0]  order_slot;
    wire [7:0]  order_side;
    wire [31:0] order_price;
    wire [31:0] order_qty;
    wire [7:0]  reject_reason;
    wire        gate_kill_fired;
    wire        gate_size_fired;
    wire        gate_position_fired;
    wire        gate_band_fired;
    wire        gate_stale_fired;
    wire        gate_seqgap_fired;
    wire        gate_crossed_fired;
    wire        gate_throttle_fired;
    wire        gate_ml_fired;
    wire        kill_latched;

    reg [31:0] cur_cycle;
    always @(posedge gmii_rx_clk or negedge engine_rst_n) begin
        if (!engine_rst_n) cur_cycle <= 32'd0;
        else               cur_cycle <= cur_cycle + 32'd1;
    end

    risk_engine u_risk (
        .clk                    (gmii_rx_clk),
        .rst_n                  (engine_rst_n),
        .sig_valid              (sig_valid),
        .sig_slot               (sig_slot),
        .sig_side               (sig_side),
        .sig_price              (sig_price),
        .sig_qty                (sig_qty),
        .msg_applied            (msg_applied),
        .applied_slot           (applied_slot),
        .bid_price              (bid_price),
        .ask_price              (ask_price),
        .crossed                (crossed),
        .seq_gap                (seq_gap),
        .adverse_risk           (1'b0),   // no ML path yet (S1.3/D22)
        .cur_cycle              (cur_cycle),
        .kill_sw_n              (kill_sw_n_sync),
        .cfg_max_order_qty      (cfg_max_order_qty),
        .cfg_max_position       (cfg_max_position),
        .cfg_price_band         (cfg_price_band),
        .cfg_max_age            (cfg_max_age),
        .cfg_token_max          (cfg_token_max),
        .cfg_token_refill_cycles(cfg_token_refill_cycles),
        .cfg_ml_action          (cfg_ml_action),
        .cfg_ml_reduce_shift    (cfg_ml_reduce_shift),
        .cfg_kill_clear         (cfg_kill_clear),
        .order_valid            (order_valid),
        .order_slot             (order_slot),
        .order_side             (order_side),
        .order_price            (order_price),
        .order_qty              (order_qty),
        .reject_reason          (reject_reason),
        .gate_kill_fired        (gate_kill_fired),
        .gate_size_fired        (gate_size_fired),
        .gate_position_fired    (gate_position_fired),
        .gate_band_fired        (gate_band_fired),
        .gate_stale_fired       (gate_stale_fired),
        .gate_seqgap_fired      (gate_seqgap_fired),
        .gate_crossed_fired     (gate_crossed_fired),
        .gate_throttle_fired    (gate_throttle_fired),
        .gate_ml_fired          (gate_ml_fired),
        .kill_latched           (kill_latched),
        .position               ()
    );

    wire cfg_reject_report;
    wire [127:0] ob_tx_payload;
    wire         ob_tx_start;
    wire         cnt_order_overflow_pulse;

    order_builder u_ob (
        .clk                  (gmii_rx_clk),
        .rst_n                (engine_rst_n),
        .msg_seq_num          (md_msg_seq_num),
        .order_valid          (order_valid),
        .order_slot           (order_slot),
        .order_side           (order_side),
        .order_price          (order_price),
        .order_qty            (order_qty),
        .reject_reason        (reject_reason),
        .cur_cycle            (cur_cycle),
        .cfg_symbol_0         (cfg_symbol_0),
        .cfg_symbol_1         (cfg_symbol_1),
        .cfg_symbol_2         (cfg_symbol_2),
        .cfg_symbol_3         (cfg_symbol_3),
        .cfg_reject_report    (cfg_reject_report),
        .tx_payload           (ob_tx_payload),
        .tx_start             (ob_tx_start),
        .tx_busy              (eth_tx_busy),   // direct -- never via the arbiter (D22)
        .cnt_order_overflow_pulse (cnt_order_overflow_pulse)
    );

    // =====================================================================
    // S2.8 TX arbitration (D22 point 1) -- a pure mux, no state of its own
    // =====================================================================
    wire [127:0] csr_resp_payload;
    wire         csr_resp_start;
    wire         csr_resp_busy;

    assign eth_tx_payload = ob_tx_start ? ob_tx_payload : csr_resp_payload;
    assign eth_tx_start   = ob_tx_start | (csr_resp_start & ~ob_tx_start);
    assign csr_resp_busy  = eth_tx_busy | ob_tx_start;

    // =====================================================================
    // S2.6 csr_block.v and latency_histogram.v
    // =====================================================================
    wire hist_lat_valid;
    wire [15:0] hist_lat_value;
    wire [5:0]  hist_rd_addr;
    wire [31:0] hist_rd_data;
    wire        counter_clear_pulse;

    csr_block u_csr (
        .clk                    (gmii_rx_clk),
        .rst_n                  (engine_rst_n),
        .in_data                (fc_out_data),   // shared tap, D19 point 1
        .in_valid               (fc_out_valid),
        .resp_payload           (csr_resp_payload),
        .resp_start             (csr_resp_start),
        .resp_busy              (csr_resp_busy),
        .cfg_symbol_0           (cfg_symbol_0),
        .cfg_symbol_1           (cfg_symbol_1),
        .cfg_symbol_2           (cfg_symbol_2),
        .cfg_symbol_3           (cfg_symbol_3),
        .cfg_symbol_en          (cfg_symbol_en),
        .cfg_min_spread         (cfg_min_spread),
        .cfg_imb_shift          (cfg_imb_shift),
        .cfg_order_qty          (cfg_order_qty),
        .cfg_max_order_qty      (cfg_max_order_qty),
        .cfg_max_position       (cfg_max_position),
        .cfg_price_band         (cfg_price_band),
        .cfg_max_age            (cfg_max_age),
        .cfg_token_max          (cfg_token_max),
        .cfg_token_refill_cycles(cfg_token_refill_cycles),
        .cfg_ml_action          (cfg_ml_action),
        .cfg_ml_reduce_shift    (cfg_ml_reduce_shift),
        .cfg_kill_clear         (cfg_kill_clear),
        .cfg_reject_report      (cfg_reject_report),
        .cfg_seq_gap_clear      (cfg_seq_gap_clear),
        // feature-normalizer / not-yet-consumed registers: no consumers in
        // this build, left unconnected
        .cfg_enable             (),
        .cfg_udp_port           (),
        .cfg_stats_period       (),
        .cfg_ml_th_high         (),
        .cfg_ml_th_low          (),
        .cfg_ml_score_offset    (),
        .cfg_ml_score_shift     (),
        .cfg_ml_window          (),
        .cfg_offset_0           (), .cfg_shift_0 (),
        .cfg_offset_1           (), .cfg_shift_1 (),
        .cfg_offset_2           (), .cfg_shift_2 (),
        .cfg_offset_3           (), .cfg_shift_3 (),
        .cfg_offset_4           (), .cfg_shift_4 (),
        .cfg_offset_5           (), .cfg_shift_5 (),
        .cfg_offset_6           (), .cfg_shift_6 (),
        .cfg_offset_7           (), .cfg_shift_7 (),
        .ml_bypass              (),
        .kill_latched           (kill_latched),
        .seq_gap                (seq_gap),
        .crossed                (crossed),
        .frame_start            (eth_frame_start),
        .err_frame_len          (fc_err_frame_len),
        .md_msg_valid           (md_msg_valid),
        .err_msg_type           (md_err_msg_type),
        .err_flags              (md_err_flags),
        .err_fcs                (mac_rec_error),      // D5 -- S1.5
        .err_ethertype          (1'b0),
        .err_ip                 (udp_checksum_error), // D5 -- S1.5
        .err_udp_port           (1'b0),
        .filt_valid             (filt_valid),
        .filt_dropped           (filt_dropped),
        .err_seq_dup            (err_seq_dup),
        .seq_gap_pulse          (seq_gap_pulse),
        .cnt_book_clear_pulse   (cnt_book_clear_pulse),
        .cnt_trades_pulse       (cnt_trades_pulse),
        .cnt_heartbeats_pulse   (cnt_heartbeats_pulse),
        .cnt_crossed_pulse      (cnt_crossed_pulse),
        .sig_valid              (sig_valid),
        .sig_side               (sig_side),
        .err_signal_conflict    (err_signal_conflict),
        .ml_event_valid         (1'b0),   // ml_policy.v is S6 (S1.3)
        .ml_adverse_pulse       (1'b0),
        .ml_benign_pulse        (1'b0),
        .ml_safe_forced_pulse   (1'b0),
        .gate_kill_fired        (gate_kill_fired),
        .gate_size_fired        (gate_size_fired),
        .gate_position_fired    (gate_position_fired),
        .gate_band_fired        (gate_band_fired),
        .gate_stale_fired       (gate_stale_fired),
        .gate_seqgap_fired      (gate_seqgap_fired),
        .gate_crossed_fired     (gate_crossed_fired),
        .gate_throttle_fired    (gate_throttle_fired),
        .gate_ml_fired          (gate_ml_fired),
        .ob_tx_start            (ob_tx_start),
        .ob_tx_payload          (ob_tx_payload),
        .cnt_order_overflow_pulse (cnt_order_overflow_pulse),
        .lat_valid              (hist_lat_valid),
        .lat_value              (hist_lat_value),
        .counter_clear_pulse    (counter_clear_pulse),
        .hist_rd_addr           (hist_rd_addr),
        .hist_rd_data           (hist_rd_data)
    );

    latency_histogram u_hist (
        .clk               (gmii_rx_clk),
        .rst_n             (engine_rst_n),
        .ob_tx_start       (ob_tx_start),
        .ob_tx_payload     (ob_tx_payload),
        .cfg_counter_clear (counter_clear_pulse),
        .lat_valid         (hist_lat_valid),
        .lat_value         (hist_lat_value),
        .hist_rd_addr      (hist_rd_addr),
        .hist_rd_data      (hist_rd_data)
    );

    // =====================================================================
    // S2.11 LED assignment (diagnostic, not spec-mandated)
    // =====================================================================
    assign led[0] = cur_cycle[24];                // heartbeat (~3.7 Hz @ 125 MHz)
    assign led[1] = kill_latched;                 // kill latch status
    assign led[2] = seq_gap | (|crossed) | gate_stale_fired;  // any sticky fault
    assign led[3] = mdio_done_latched;            // PHY bring-up completed

endmodule
