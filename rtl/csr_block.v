`timescale 1ns / 1ps

// rtl/csr_block.v
//
// Control plane (master spec S3.1 [M], S9, S10, FR-56..58; contract
// docs/contracts/csr_block.md). Single source of truth for every cfg_*
// register this pipeline's modules take as stand-in ports, and the single
// accumulation point for every err_*/cnt_*_pulse/gate_*_fired raw pulse the
// built modules emit. Read/written over CSR frames (0x20 write / 0x21
// read-request / 0x22 read-response) in the same 16-byte fixed-width
// envelope as every other frame type.
//
// D19 points this module pins down (docs/design_decisions.md D19):
//   * Ingress shares frame_classifier.v's byte stream (in_data/in_valid) --
//     the same one md_parser.v consumes; only 0x20/0x21 in byte 0 are
//     recognized, everything else is silently ignored (the way md_parser.v
//     silently ignores 0x20/0x21 today).
//   * Egress is a standalone resp_payload/resp_start/resp_busy interface --
//     NOT eth_mac_if.v's -- to be arbitrated onto the real TX path at S10.
//   * Counter addresses 0xA0..0x134 are assigned here in S10's listed
//     order; the 0x138+ histogram range is reserved and reads 0.
//   * STATUS bits 7:5 stay reserved (0) -- a documented master-spec gap.
//
// Semantics highlights (contract S2.3/S2.5/S2.6):
//   * CTRL bits 1-3 (kill clear / counter clear / seq-gap clear) are
//     self-clearing: they emit a one-cycle pulse the cycle the write
//     completes and never latch -- CTRL read-back shows them as 0 while
//     plain level bits 0/4 persist.
//   * All counters are 32-bit saturating (never wrap), cleared together by
//     CTRL.bit2. lat_min/lat_max are the exception: counter clear resets
//     them to their identity extremes (0xFFFFFFFF / 0), not 0, so a fresh
//     min/max is always established by the next lat_valid.
//   * cnt_orders_tx counts only accepted transmissions -- ob_tx_start with
//     payload msg_type 0x10 -- never the 0x11 reject-diagnostic frames.
//   * STATUS bit0 live-mirrors risk_engine's kill_latched (already latched
//     until CTRL.bit1); bits 1-4 are sticky-until-counter-clear.
//
// cfg_* outputs are pin-compatible with every existing module's cfg_*
// input ports; wiring them to the pipeline is tob_top.v (S10) work.
//
// Verilog-2001 only.

module csr_block #(
    parameter integer NUM_SYMBOLS = 4
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // ---- CSR ingress: shared byte stream (frame_classifier.v's
    // out_data/out_valid, D19 point 1) ----
    input  wire [7:0]  in_data,
    input  wire        in_valid,

    // ---- CSR egress: standalone (D19 point 2), same one-shot-pulse shape
    // as order_builder.v's tx_payload/tx_start/tx_busy ----
    output reg  [127:0] resp_payload,
    output reg           resp_start,
    input  wire           resp_busy,

    // =====================================================================
    // cfg_* outputs -- pin-compatible with existing modules' cfg_* ports
    // =====================================================================
    output reg  [7:0]  cfg_symbol_0,
    output reg  [7:0]  cfg_symbol_1,
    output reg  [7:0]  cfg_symbol_2,
    output reg  [7:0]  cfg_symbol_3,
    output reg  [3:0]  cfg_symbol_en,
    output reg  [31:0] cfg_min_spread,
    output reg  [1:0]  cfg_imb_shift,
    output reg  [31:0] cfg_order_qty,
    output reg  [31:0] cfg_max_order_qty,
    output reg  [31:0] cfg_max_position,
    output reg  [31:0] cfg_price_band,
    output reg  [31:0] cfg_max_age,
    output reg  [31:0] cfg_token_max,
    output reg  [31:0] cfg_token_refill_cycles,
    output reg         cfg_ml_action,
    output reg  [3:0]  cfg_ml_reduce_shift,
    output wire        cfg_kill_clear,      // CTRL bit1, self-clearing pulse
    output reg         cfg_reject_report,   // CTRL bit4
    output wire        cfg_seq_gap_clear,   // CTRL bit3, self-clearing pulse
    output reg  [31:0] cfg_offset_0, output reg [31:0] cfg_shift_0,
    output reg  [31:0] cfg_offset_1, output reg [31:0] cfg_shift_1,
    output reg  [31:0] cfg_offset_2, output reg [31:0] cfg_shift_2,
    output reg  [31:0] cfg_offset_3, output reg [31:0] cfg_shift_3,
    output reg  [31:0] cfg_offset_4, output reg [31:0] cfg_shift_4,
    output reg  [31:0] cfg_offset_5, output reg [31:0] cfg_shift_5,
    output reg  [31:0] cfg_offset_6, output reg [31:0] cfg_shift_6,
    output reg  [31:0] cfg_offset_7, output reg [31:0] cfg_shift_7,
    output reg         cfg_enable,          // CTRL bit0
    output reg  [15:0] cfg_udp_port,
    output reg  [31:0] cfg_stats_period,
    output reg  signed [31:0] cfg_ml_th_high,
    output reg  signed [31:0] cfg_ml_th_low,
    output reg  [31:0] cfg_ml_score_offset,
    output reg  [31:0] cfg_ml_score_shift,
    output reg  [31:0] cfg_ml_window,
    output wire        ml_bypass,            // ML_CTRL bit8, debug only

    // =====================================================================
    // STATUS-feeding level inputs (S2.6)
    // =====================================================================
    input  wire         kill_latched,        // risk_engine.v
    input  wire         seq_gap,             // seq_monitor.v (level)
    input  wire [NUM_SYMBOLS-1:0] crossed,   // tob_engine.v

    // =====================================================================
    // Pulse inputs accumulated into saturating counters (S2.5)
    // =====================================================================
    input  wire         frame_start,         // eth_mac_if.v D11 -- cnt_frames_rx
    input  wire         err_frame_len,       // frame_classifier.v
    input  wire         md_msg_valid,        // md_parser.v msg_valid
    input  wire         err_msg_type,        // md_parser.v
    input  wire         err_flags,           // md_parser.v
    input  wire         err_fcs,             // stand-in, no source yet (S1.3)
    input  wire         err_ethertype,
    input  wire         err_ip,
    input  wire         err_udp_port,
    input  wire         filt_valid,          // symbol_filter.v -> accepted
    input  wire         filt_dropped,        // symbol_filter.v -> filtered
    input  wire         err_seq_dup,         // seq_monitor.v
    input  wire         seq_gap_pulse,       // seq_monitor.v
    input  wire         cnt_book_clear_pulse, // tob_engine.v
    input  wire         cnt_trades_pulse,
    input  wire         cnt_heartbeats_pulse,
    input  wire         cnt_crossed_pulse,
    input  wire         sig_valid,           // signal_engine.v
    input  wire [7:0]   sig_side,            // 0x00 buy / 0x01 sell
    input  wire         err_signal_conflict, // signal_engine.v
    input  wire         ml_event_valid,      // stand-in, ml_policy.v is S6
    input  wire         ml_adverse_pulse,
    input  wire         ml_benign_pulse,
    input  wire         ml_safe_forced_pulse,
    input  wire         gate_kill_fired,     // risk_engine.v, one per gate
    input  wire         gate_size_fired,
    input  wire         gate_position_fired,
    input  wire         gate_band_fired,
    input  wire         gate_stale_fired,
    input  wire         gate_seqgap_fired,
    input  wire         gate_crossed_fired,
    input  wire         gate_throttle_fired,
    input  wire         gate_ml_fired,
    input  wire         ob_tx_start,         // order_builder.v tx_start
    input  wire [127:0] ob_tx_payload,       // byte 0 = msg_type (0x10 NEW)
    input  wire         cnt_order_overflow_pulse,  // order_builder.v
    input  wire         lat_valid,           // stand-in for latency_histogram.v
    input  wire [15:0]  lat_value
);

    // =====================================================================
    // S2.2 CSR frame ingress decode (mirrors md_parser.v's byte-serial shape)
    // =====================================================================
    reg [3:0]  byte_cnt;
    reg [7:0]  csr_msg_type_r;
    reg [15:0] csr_addr_r;
    reg [31:0] csr_data_r;
    reg        csr_complete_d;   // one cycle after byte 15 lands

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt       <= 4'd0;
            csr_msg_type_r <= 8'd0;
            csr_addr_r     <= 16'd0;
            csr_data_r     <= 32'd0;
            csr_complete_d <= 1'b0;
        end else begin
            csr_complete_d <= 1'b0;
            if (in_valid) begin
                case (byte_cnt)
                    4'd0:  csr_msg_type_r <= in_data;
                    4'd2:  csr_addr_r[15:8] <= in_data;
                    4'd3:  csr_addr_r[7:0]  <= in_data;
                    4'd4:  csr_data_r[31:24] <= in_data;
                    4'd5:  csr_data_r[23:16] <= in_data;
                    4'd6:  csr_data_r[15:8]  <= in_data;
                    4'd7:  csr_data_r[7:0]   <= in_data;
                    default: ;
                endcase
                if (byte_cnt == 4'd15) begin
                    byte_cnt       <= 4'd0;
                    csr_complete_d <= 1'b1;
                end else begin
                    byte_cnt <= byte_cnt + 1'b1;
                end
            end
        end
    end

    wire csr_write_valid = csr_complete_d & (csr_msg_type_r == 8'h20);
    wire csr_read_valid  = csr_complete_d & (csr_msg_type_r == 8'h21);

    // =====================================================================
    // S2.3 CTRL (0x00): self-clearing pulse bits vs plain level bits
    // =====================================================================
    assign cfg_kill_clear    = csr_write_valid & (csr_addr_r == 16'h0000) & csr_data_r[1];
    assign cfg_seq_gap_clear = csr_write_valid & (csr_addr_r == 16'h0000) & csr_data_r[3];
    wire   counter_clear_pulse = csr_write_valid & (csr_addr_r == 16'h0000) & csr_data_r[2];

    // =====================================================================
    // cfg register storage + write decode (all of S2.3's table; CTRL and
    // ML_CTRL decode to their packed fields). One always, one write per
    // address per cycle; un-written registers hold.
    // =====================================================================
    reg ml_bypass_r;
    assign ml_bypass = ml_bypass_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_symbol_0          <= 8'd1;
            cfg_symbol_1          <= 8'd2;
            cfg_symbol_2          <= 8'd3;
            cfg_symbol_3          <= 8'd4;
            cfg_symbol_en         <= 4'hF;
            cfg_min_spread        <= 32'd2;
            cfg_imb_shift         <= 2'd1;
            cfg_order_qty         <= 32'd100;
            cfg_max_order_qty     <= 32'd500;
            cfg_max_position      <= 32'd1000;
            cfg_price_band        <= 32'd50;
            cfg_max_age           <= 32'd1250000;
            cfg_token_max         <= 32'd8;
            cfg_token_refill_cycles <= 32'd12500;
            cfg_udp_port          <= 16'd60000;
            cfg_stats_period      <= 32'd12500000;
            cfg_ml_th_high        <= 32'sd0;
            cfg_ml_th_low         <= 32'sd0;
            cfg_ml_action         <= 1'b0;
            cfg_ml_reduce_shift   <= 4'd0;
            ml_bypass_r           <= 1'b0;
            cfg_ml_score_offset   <= 32'd0;
            cfg_ml_score_shift    <= 32'd0;
            cfg_ml_window         <= 32'd16;
            cfg_offset_0          <= 32'd0; cfg_shift_0 <= 32'd0;
            cfg_offset_1          <= 32'd0; cfg_shift_1 <= 32'd0;
            cfg_offset_2          <= 32'd0; cfg_shift_2 <= 32'd0;
            cfg_offset_3          <= 32'd0; cfg_shift_3 <= 32'd0;
            cfg_offset_4          <= 32'd0; cfg_shift_4 <= 32'd0;
            cfg_offset_5          <= 32'd0; cfg_shift_5 <= 32'd0;
            cfg_offset_6          <= 32'd0; cfg_shift_6 <= 32'd0;
            cfg_offset_7          <= 32'd0; cfg_shift_7 <= 32'd0;
            cfg_enable            <= 1'b0;
            cfg_reject_report     <= 1'b0;
        end else if (csr_write_valid) begin
            case (csr_addr_r)
                16'h0000: begin
                    cfg_enable        <= csr_data_r[0];
                    cfg_reject_report <= csr_data_r[4];
                end
                16'h0008: cfg_symbol_0 <= csr_data_r[7:0];
                16'h000C: cfg_symbol_1 <= csr_data_r[7:0];
                16'h0010: cfg_symbol_2 <= csr_data_r[7:0];
                16'h0014: cfg_symbol_3 <= csr_data_r[7:0];
                16'h0018: cfg_symbol_en <= csr_data_r[3:0];
                16'h001C: cfg_min_spread <= csr_data_r;
                16'h0020: cfg_imb_shift  <= csr_data_r[1:0];
                16'h0024: cfg_order_qty  <= csr_data_r;
                16'h0028: cfg_max_order_qty <= csr_data_r;
                16'h002C: cfg_max_position <= csr_data_r;
                16'h0030: cfg_price_band <= csr_data_r;
                16'h0034: cfg_max_age    <= csr_data_r;
                16'h0038: cfg_token_max  <= csr_data_r;
                16'h003C: cfg_token_refill_cycles <= csr_data_r;
                16'h0040: cfg_udp_port   <= csr_data_r[15:0];
                16'h0044: cfg_stats_period <= csr_data_r;
                16'h0048: cfg_ml_th_high <= csr_data_r;
                16'h004C: cfg_ml_th_low  <= csr_data_r;
                16'h0050: begin
                    cfg_ml_action       <= csr_data_r[0];
                    cfg_ml_reduce_shift <= csr_data_r[4:1];
                    ml_bypass_r         <= csr_data_r[8];
                end
                16'h0054: cfg_ml_score_offset <= csr_data_r;
                16'h0058: cfg_ml_score_shift  <= csr_data_r;
                16'h005C: cfg_ml_window       <= csr_data_r;
                16'h0060: cfg_offset_0 <= csr_data_r;
                16'h0064: cfg_offset_1 <= csr_data_r;
                16'h0068: cfg_offset_2 <= csr_data_r;
                16'h006C: cfg_offset_3 <= csr_data_r;
                16'h0070: cfg_offset_4 <= csr_data_r;
                16'h0074: cfg_offset_5 <= csr_data_r;
                16'h0078: cfg_offset_6 <= csr_data_r;
                16'h007C: cfg_offset_7 <= csr_data_r;
                16'h0080: cfg_shift_0 <= csr_data_r;
                16'h0084: cfg_shift_1 <= csr_data_r;
                16'h0088: cfg_shift_2 <= csr_data_r;
                16'h008C: cfg_shift_3 <= csr_data_r;
                16'h0090: cfg_shift_4 <= csr_data_r;
                16'h0094: cfg_shift_5 <= csr_data_r;
                16'h0098: cfg_shift_6 <= csr_data_r;
                16'h009C: cfg_shift_7 <= csr_data_r;
                default: ;   // unmapped / counter-range writes are ignored
            endcase
        end
    end

    // =====================================================================
    // S2.5 counters (saturating) + lat_min/max/last
    // =====================================================================
    reg [31:0] cnt_frames_rx;
    reg [31:0] cnt_msgs_rx;
    reg [31:0] cnt_msgs_filtered;
    reg [31:0] cnt_msgs_accepted;
    reg [31:0] cnt_err_fcs;
    reg [31:0] cnt_err_ethertype;
    reg [31:0] cnt_err_ip;
    reg [31:0] cnt_err_udp_port;
    reg [31:0] cnt_err_frame_len;
    reg [31:0] cnt_err_msg_type;
    reg [31:0] cnt_err_flags;
    reg [31:0] cnt_err_signal_conflict;
    reg [31:0] cnt_seq_gap;
    reg [31:0] cnt_seq_dup;
    reg [31:0] cnt_crossed;
    reg [31:0] cnt_book_clear;
    reg [31:0] cnt_trades;
    reg [31:0] cnt_heartbeats;
    reg [31:0] cnt_signal_buy;
    reg [31:0] cnt_signal_sell;
    reg [31:0] cnt_ml_events;
    reg [31:0] cnt_ml_adverse;
    reg [31:0] cnt_ml_benign;
    reg [31:0] cnt_ml_safe_forced;
    reg [31:0] cnt_rej_kill;
    reg [31:0] cnt_rej_size;
    reg [31:0] cnt_rej_position;
    reg [31:0] cnt_rej_band;
    reg [31:0] cnt_rej_stale;
    reg [31:0] cnt_rej_seqgap;
    reg [31:0] cnt_rej_crossed;
    reg [31:0] cnt_rej_throttle;
    reg [31:0] cnt_rej_ml;
    reg [31:0] cnt_orders_tx;
    reg [31:0] cnt_order_overflow;
    reg [31:0] lat_min;
    reg [31:0] lat_max;
    reg [31:0] lat_last;

    function [31:0] satinc;
        input [31:0] v;
        begin
            satinc = (v == 32'hFFFFFFFF) ? v : v + 32'd1;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_frames_rx          <= 32'd0;
            cnt_msgs_rx            <= 32'd0;
            cnt_msgs_filtered      <= 32'd0;
            cnt_msgs_accepted      <= 32'd0;
            cnt_err_fcs            <= 32'd0;
            cnt_err_ethertype      <= 32'd0;
            cnt_err_ip             <= 32'd0;
            cnt_err_udp_port       <= 32'd0;
            cnt_err_frame_len      <= 32'd0;
            cnt_err_msg_type       <= 32'd0;
            cnt_err_flags          <= 32'd0;
            cnt_err_signal_conflict<= 32'd0;
            cnt_seq_gap            <= 32'd0;
            cnt_seq_dup            <= 32'd0;
            cnt_crossed            <= 32'd0;
            cnt_book_clear         <= 32'd0;
            cnt_trades             <= 32'd0;
            cnt_heartbeats         <= 32'd0;
            cnt_signal_buy         <= 32'd0;
            cnt_signal_sell        <= 32'd0;
            cnt_ml_events          <= 32'd0;
            cnt_ml_adverse         <= 32'd0;
            cnt_ml_benign          <= 32'd0;
            cnt_ml_safe_forced     <= 32'd0;
            cnt_rej_kill           <= 32'd0;
            cnt_rej_size           <= 32'd0;
            cnt_rej_position       <= 32'd0;
            cnt_rej_band           <= 32'd0;
            cnt_rej_stale          <= 32'd0;
            cnt_rej_seqgap         <= 32'd0;
            cnt_rej_crossed        <= 32'd0;
            cnt_rej_throttle       <= 32'd0;
            cnt_rej_ml             <= 32'd0;
            cnt_orders_tx          <= 32'd0;
            cnt_order_overflow     <= 32'd0;
            lat_min                <= 32'hFFFFFFFF;   // identity extremes...
            lat_max                <= 32'd0;
            lat_last               <= 32'd0;
        end else if (counter_clear_pulse) begin
            cnt_frames_rx          <= 32'd0;
            cnt_msgs_rx            <= 32'd0;
            cnt_msgs_filtered      <= 32'd0;
            cnt_msgs_accepted      <= 32'd0;
            cnt_err_fcs            <= 32'd0;
            cnt_err_ethertype      <= 32'd0;
            cnt_err_ip             <= 32'd0;
            cnt_err_udp_port       <= 32'd0;
            cnt_err_frame_len      <= 32'd0;
            cnt_err_msg_type       <= 32'd0;
            cnt_err_flags          <= 32'd0;
            cnt_err_signal_conflict<= 32'd0;
            cnt_seq_gap            <= 32'd0;
            cnt_seq_dup            <= 32'd0;
            cnt_crossed            <= 32'd0;
            cnt_book_clear         <= 32'd0;
            cnt_trades             <= 32'd0;
            cnt_heartbeats         <= 32'd0;
            cnt_signal_buy         <= 32'd0;
            cnt_signal_sell        <= 32'd0;
            cnt_ml_events          <= 32'd0;
            cnt_ml_adverse         <= 32'd0;
            cnt_ml_benign          <= 32'd0;
            cnt_ml_safe_forced     <= 32'd0;
            cnt_rej_kill           <= 32'd0;
            cnt_rej_size           <= 32'd0;
            cnt_rej_position       <= 32'd0;
            cnt_rej_band           <= 32'd0;
            cnt_rej_stale          <= 32'd0;
            cnt_rej_seqgap         <= 32'd0;
            cnt_rej_crossed        <= 32'd0;
            cnt_rej_throttle       <= 32'd0;
            cnt_rej_ml             <= 32'd0;
            cnt_orders_tx          <= 32'd0;
            cnt_order_overflow     <= 32'd0;
            lat_min                <= 32'hFFFFFFFF;   // ...not 0
            lat_max                <= 32'd0;
            lat_last               <= 32'd0;
        end else begin
            if (frame_start)                  cnt_frames_rx      <= satinc(cnt_frames_rx);
            if (md_msg_valid | err_msg_type | err_flags)
                                              cnt_msgs_rx        <= satinc(cnt_msgs_rx);
            if (filt_dropped)                 cnt_msgs_filtered  <= satinc(cnt_msgs_filtered);
            if (filt_valid)                   cnt_msgs_accepted  <= satinc(cnt_msgs_accepted);
            if (err_fcs)                      cnt_err_fcs        <= satinc(cnt_err_fcs);
            if (err_ethertype)                cnt_err_ethertype  <= satinc(cnt_err_ethertype);
            if (err_ip)                       cnt_err_ip         <= satinc(cnt_err_ip);
            if (err_udp_port)                 cnt_err_udp_port   <= satinc(cnt_err_udp_port);
            if (err_frame_len)                cnt_err_frame_len  <= satinc(cnt_err_frame_len);
            if (err_msg_type)                 cnt_err_msg_type   <= satinc(cnt_err_msg_type);
            if (err_flags)                    cnt_err_flags      <= satinc(cnt_err_flags);
            if (err_signal_conflict)          cnt_err_signal_conflict <= satinc(cnt_err_signal_conflict);
            if (seq_gap_pulse)                cnt_seq_gap        <= satinc(cnt_seq_gap);
            if (err_seq_dup)                  cnt_seq_dup        <= satinc(cnt_seq_dup);
            if (cnt_crossed_pulse)            cnt_crossed        <= satinc(cnt_crossed);
            if (cnt_book_clear_pulse)         cnt_book_clear     <= satinc(cnt_book_clear);
            if (cnt_trades_pulse)             cnt_trades         <= satinc(cnt_trades);
            if (cnt_heartbeats_pulse)         cnt_heartbeats     <= satinc(cnt_heartbeats);
            if (sig_valid & (sig_side == 8'h00)) cnt_signal_buy  <= satinc(cnt_signal_buy);
            if (sig_valid & (sig_side == 8'h01)) cnt_signal_sell <= satinc(cnt_signal_sell);
            if (ml_event_valid)               cnt_ml_events      <= satinc(cnt_ml_events);
            if (ml_adverse_pulse)             cnt_ml_adverse     <= satinc(cnt_ml_adverse);
            if (ml_benign_pulse)              cnt_ml_benign      <= satinc(cnt_ml_benign);
            if (ml_safe_forced_pulse)         cnt_ml_safe_forced <= satinc(cnt_ml_safe_forced);
            if (gate_kill_fired)              cnt_rej_kill       <= satinc(cnt_rej_kill);
            if (gate_size_fired)              cnt_rej_size       <= satinc(cnt_rej_size);
            if (gate_position_fired)          cnt_rej_position   <= satinc(cnt_rej_position);
            if (gate_band_fired)              cnt_rej_band       <= satinc(cnt_rej_band);
            if (gate_stale_fired)             cnt_rej_stale      <= satinc(cnt_rej_stale);
            if (gate_seqgap_fired)            cnt_rej_seqgap     <= satinc(cnt_rej_seqgap);
            if (gate_crossed_fired)           cnt_rej_crossed    <= satinc(cnt_rej_crossed);
            if (gate_throttle_fired)          cnt_rej_throttle   <= satinc(cnt_rej_throttle);
            if (gate_ml_fired)                cnt_rej_ml         <= satinc(cnt_rej_ml);
            // 0x10 = NEW accepted order only; 0x11 reject diagnostics never
            // count (keeps the S10 invariant signal == orders + rejects +
            // overflow balanced)
            if (ob_tx_start & (ob_tx_payload[127:120] == 8'h10))
                                              cnt_orders_tx      <= satinc(cnt_orders_tx);
            if (cnt_order_overflow_pulse)     cnt_order_overflow <= satinc(cnt_order_overflow);
            if (lat_valid) begin
                lat_last <= {16'd0, lat_value};
                lat_min  <= (lat_value < lat_min) ? {16'd0, lat_value} : lat_min;
                lat_max  <= (lat_value > lat_max) ? {16'd0, lat_value} : lat_max;
            end
        end
    end

    // =====================================================================
    // S2.6 STATUS sticky bits (bits 1-4 sticky-until-counter-clear; bit 0
    // is a live mirror of kill_latched, read combinationally in rd32)
    // =====================================================================
    reg status_seq_gap;
    reg status_crossed;
    reg status_stale;
    reg status_ml_adv;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status_seq_gap  <= 1'b0;
            status_crossed  <= 1'b0;
            status_stale    <= 1'b0;
            status_ml_adv   <= 1'b0;
        end else if (counter_clear_pulse) begin
            status_seq_gap  <= 1'b0;
            status_crossed  <= 1'b0;
            status_stale    <= 1'b0;
            status_ml_adv   <= 1'b0;
        end else begin
            if (seq_gap_pulse)      status_seq_gap <= 1'b1;
            // D20: level-based, not edge-triggered -- `crossed` (unlike the
            // other three sticky triggers) is a persisting LEVEL, not a
            // one-shot pulse. Latching only on a 0->1 edge meant a book that
            // stayed crossed straight through a counter_clear_pulse would
            // never re-set this bit, since the level never actually fell to
            // 0 first. A plain level check re-asserts every cycle the fault
            // is still live, which is what a sticky-since-last-clear flag is
            // for.
            if (|crossed)            status_crossed <= 1'b1;
            if (gate_stale_fired)    status_stale   <= 1'b1;
            if (ml_adverse_pulse)    status_ml_adv  <= 1'b1;
        end
    end

    // =====================================================================
    // S2.4 read mux (config live values, counters, STATUS) and response
    // =====================================================================
    function [31:0] rd32;
        input [15:0] a;
        begin
            case (a)
                16'h0000: rd32 = {27'd0, cfg_reject_report, 3'b000, cfg_enable};
                16'h0004: rd32 = {27'd0, status_ml_adv, status_stale,
                                        status_crossed, status_seq_gap,
                                        kill_latched};
                16'h0008: rd32 = {24'd0, cfg_symbol_0};
                16'h000C: rd32 = {24'd0, cfg_symbol_1};
                16'h0010: rd32 = {24'd0, cfg_symbol_2};
                16'h0014: rd32 = {24'd0, cfg_symbol_3};
                16'h0018: rd32 = {28'd0, cfg_symbol_en};
                16'h001C: rd32 = cfg_min_spread;
                16'h0020: rd32 = {30'd0, cfg_imb_shift};
                16'h0024: rd32 = cfg_order_qty;
                16'h0028: rd32 = cfg_max_order_qty;
                16'h002C: rd32 = cfg_max_position;
                16'h0030: rd32 = cfg_price_band;
                16'h0034: rd32 = cfg_max_age;
                16'h0038: rd32 = cfg_token_max;
                16'h003C: rd32 = cfg_token_refill_cycles;
                16'h0040: rd32 = {16'd0, cfg_udp_port};
                16'h0044: rd32 = cfg_stats_period;
                16'h0048: rd32 = cfg_ml_th_high[31:0];
                16'h004C: rd32 = cfg_ml_th_low[31:0];
                16'h0050: rd32 = {23'd0, ml_bypass_r, 3'b000,
                                        cfg_ml_reduce_shift, cfg_ml_action};
                16'h0054: rd32 = cfg_ml_score_offset;
                16'h0058: rd32 = cfg_ml_score_shift;
                16'h005C: rd32 = cfg_ml_window;
                16'h0060: rd32 = cfg_offset_0;
                16'h0064: rd32 = cfg_offset_1;
                16'h0068: rd32 = cfg_offset_2;
                16'h006C: rd32 = cfg_offset_3;
                16'h0070: rd32 = cfg_offset_4;
                16'h0074: rd32 = cfg_offset_5;
                16'h0078: rd32 = cfg_offset_6;
                16'h007C: rd32 = cfg_offset_7;
                16'h0080: rd32 = cfg_shift_0;
                16'h0084: rd32 = cfg_shift_1;
                16'h0088: rd32 = cfg_shift_2;
                16'h008C: rd32 = cfg_shift_3;
                16'h0090: rd32 = cfg_shift_4;
                16'h0094: rd32 = cfg_shift_5;
                16'h0098: rd32 = cfg_shift_6;
                16'h009C: rd32 = cfg_shift_7;
                16'h00A0: rd32 = cnt_frames_rx;
                16'h00A4: rd32 = cnt_msgs_rx;
                16'h00A8: rd32 = cnt_msgs_filtered;
                16'h00AC: rd32 = cnt_msgs_accepted;
                16'h00B0: rd32 = cnt_err_fcs;
                16'h00B4: rd32 = cnt_err_ethertype;
                16'h00B8: rd32 = cnt_err_ip;
                16'h00BC: rd32 = cnt_err_udp_port;
                16'h00C0: rd32 = cnt_err_frame_len;
                16'h00C4: rd32 = cnt_err_msg_type;
                16'h00C8: rd32 = cnt_err_flags;
                16'h00CC: rd32 = cnt_err_signal_conflict;
                16'h00D0: rd32 = cnt_seq_gap;
                16'h00D4: rd32 = cnt_seq_dup;
                16'h00D8: rd32 = cnt_crossed;
                16'h00DC: rd32 = cnt_book_clear;
                16'h00E0: rd32 = cnt_trades;
                16'h00E4: rd32 = cnt_heartbeats;
                16'h00E8: rd32 = cnt_signal_buy;
                16'h00EC: rd32 = cnt_signal_sell;
                16'h00F0: rd32 = cnt_ml_events;
                16'h00F4: rd32 = cnt_ml_adverse;
                16'h00F8: rd32 = cnt_ml_benign;
                16'h00FC: rd32 = cnt_ml_safe_forced;
                16'h0100: rd32 = cnt_rej_kill;
                16'h0104: rd32 = cnt_rej_size;
                16'h0108: rd32 = cnt_rej_position;
                16'h010C: rd32 = cnt_rej_band;
                16'h0110: rd32 = cnt_rej_stale;
                16'h0114: rd32 = cnt_rej_seqgap;
                16'h0118: rd32 = cnt_rej_crossed;
                16'h011C: rd32 = cnt_rej_throttle;
                16'h0120: rd32 = cnt_rej_ml;
                16'h0124: rd32 = cnt_orders_tx;
                16'h0128: rd32 = cnt_order_overflow;
                16'h012C: rd32 = lat_min;
                16'h0130: rd32 = lat_max;
                16'h0134: rd32 = lat_last;
                default: rd32 = 32'd0;   // unmapped + reserved histogram range
            endcase
        end
    endfunction

    // A read request that arrives while resp_busy is high is dropped
    // silently -- CSR reads are diagnostic traffic, not the fast path. The
    // ~resp_start term guards against double-issue on the cycle after a
    // response when resp_busy's lag has not yet asserted.
    wire issue_resp = csr_read_valid & ~resp_busy & ~resp_start;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_payload <= 128'd0;
            resp_start   <= 1'b0;
        end else begin
            resp_payload <= 128'd0;
            resp_start   <= 1'b0;
            if (issue_resp) begin
                // 0x22 read response: {msg_type, 0, addr, data, 8 reserved}
                resp_payload <= {8'h22, 8'd0, csr_addr_r, rd32(csr_addr_r),
                                 64'd0};
                resp_start   <= 1'b1;
            end
        end
    end

endmodule
