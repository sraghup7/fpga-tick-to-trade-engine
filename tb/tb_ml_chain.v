`timescale 1ns / 1ps

// Self-checking cross-module regression chaining the REAL ML branch end to
// end: tob_engine.v -> feature_extractor.v -> feature_normalizer.v ->
// ml_classifier_wrap.v -> ml_policy.v (no tob_top.v). Mirrors
// tb_signal_tob_chain.v / tb_feature_tob_chain.v: drive message-shaped
// stimulus into tob_engine.v's own inputs and check the final ML verdict
// against hand-computed values (equivalent to sim/ml_golden.py's MLClassifier
// with the placeholder weights w_i=1, bias=0 -- see that file / contract
// docs/contracts/ml_integration.md S5/S6).
//
// Icarus (run from repo root so $readmemh finds model/weights.mem):
//   iverilog -g2001 -Wall -o tb_ml_chain.vvp rtl/tob_engine.v rtl/feature_extractor.v \
//     rtl/feature_normalizer.v rtl/ml_classifier_wrap.v rtl/ml_policy.v tb/tb_ml_chain.v
//   vvp tb_ml_chain.vvp
//
// Pipeline timing (contract S1.3): book_upd_valid at cycle 0, feat_valid +1,
// norm_valid +2, ml_valid (and z) +3, adverse_risk/pulses registered at +4.
// feature_normalizer's cfg_offset_i/cfg_shift_i are all 0 (identity
// normalization), so x_i = raw feature clamped to int8 -- every raw feature
// below is chosen small enough (< 128) that no clamp fires, making z a plain
// sum of the raw F0-F7.
//
// Thresholds: cfg_ml_th_high=50, cfg_ml_th_low=-50.
//
// Cases (all NUM_SYMBOLS=4):
//   A   slot 0: QUOTE bid 100/10 (ask invalid -> fail-safe forced adverse,
//       z=11), then QUOTE ask 110/5 (both sides valid -> z=132 >= 50 ->
//       threshold adverse, not forced).
//   B   slot 0: CLEAR -> both sides invalid -> fail-safe forced adverse
//       regardless of z.
//   C   slot 2: QUOTE bid 500/10 -> ml_slot=2 routes end to end (z=11, forced
//       adverse because slot 2's ask is invalid).
//
// Verilog-2001 only.

module tb_ml_chain;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg [7:0]  msg_type = 8'd0;
    reg [7:0]  msg_side = 8'd0;
    reg [31:0] msg_price = 32'd0;
    reg [31:0] msg_quantity = 32'd0;
    reg        filt_valid = 1'b0;
    reg [1:0]  filt_slot = 2'd0;
    reg        err_seq_dup = 1'b0;

    wire [31:0] next_bid_price, next_bid_qty, next_ask_price, next_ask_qty;
    wire [31:0] feat_f0_spread, feat_f1_mid_delta, feat_f2_imbalance;
    wire [31:0] feat_f3_bid_chg, feat_f4_ask_chg, feat_f5_update_rate;
    wire [31:0] feat_f6_last_trade_dir, feat_f7_volatility;
    wire        norm_valid;
    wire [1:0]  norm_slot;
    wire signed [7:0] x0, x1, x2, x3, x4, x5, x6, x7;
    wire        ml_valid;
    wire [1:0]  ml_slot;
    wire signed [31:0] z;
    wire        adverse_risk;
    wire        ml_event_valid, ml_adverse_pulse, ml_benign_pulse, ml_safe_forced_pulse;

    reg signed [31:0] cfg_ml_th_high = 32'sd50;
    reg signed [31:0] cfg_ml_th_low  = -32'sd50;

    localparam [7:0] QUOTE = 8'h01;
    localparam [7:0] CLEAR = 8'h03;
    localparam [7:0] SIDE_BID = 8'h00;
    localparam [7:0] SIDE_ASK = 8'h01;

    tob_engine u_tob (
        .clk(clk), .rst_n(rst_n),
        .msg_type(msg_type), .msg_side(msg_side),
        .msg_price(msg_price), .msg_quantity(msg_quantity),
        .filt_valid(filt_valid), .filt_slot(filt_slot), .err_seq_dup(err_seq_dup),
        .msg_applied(), .applied_slot(), .book_upd_valid(),
        .cnt_book_clear_pulse(), .cnt_trades_pulse(), .cnt_heartbeats_pulse(), .cnt_crossed_pulse(),
        .bid_price(), .bid_qty(), .bid_valid(), .ask_price(), .ask_qty(), .ask_valid(), .crossed(),
        .next_bid_price(next_bid_price), .next_bid_qty(next_bid_qty), .next_bid_valid(),
        .next_ask_price(next_ask_price), .next_ask_qty(next_ask_qty), .next_ask_valid(), .next_crossed()
    );

    feature_extractor #(.NUM_SYMBOLS(4), .WINDOW(16)) u_feat (
        .clk(clk), .rst_n(rst_n),
        .msg_type(msg_type), .msg_side(msg_side),
        .msg_applied(u_tob.msg_applied),
        .book_upd_valid(u_tob.book_upd_valid),
        .applied_slot(u_tob.applied_slot),
        .next_bid_price(next_bid_price), .next_bid_qty(next_bid_qty),
        .next_ask_price(next_ask_price), .next_ask_qty(next_ask_qty),
        .feat_valid(), .feat_slot(),
        .feat_f0_spread(feat_f0_spread), .feat_f1_mid_delta(feat_f1_mid_delta),
        .feat_f2_imbalance(feat_f2_imbalance), .feat_f3_bid_chg(feat_f3_bid_chg),
        .feat_f4_ask_chg(feat_f4_ask_chg), .feat_f5_update_rate(feat_f5_update_rate),
        .feat_f6_last_trade_dir(feat_f6_last_trade_dir), .feat_f7_volatility(feat_f7_volatility)
    );

    feature_normalizer u_norm (
        .clk(clk), .rst_n(rst_n),
        .feat_valid(u_feat.feat_valid), .feat_slot(u_feat.feat_slot),
        .feat_f0_spread(feat_f0_spread), .feat_f1_mid_delta(feat_f1_mid_delta),
        .feat_f2_imbalance(feat_f2_imbalance), .feat_f3_bid_chg(feat_f3_bid_chg),
        .feat_f4_ask_chg(feat_f4_ask_chg), .feat_f5_update_rate(feat_f5_update_rate),
        .feat_f6_last_trade_dir(feat_f6_last_trade_dir), .feat_f7_volatility(feat_f7_volatility),
        .cfg_offset_0(32'd0), .cfg_shift_0(32'd0),
        .cfg_offset_1(32'd0), .cfg_shift_1(32'd0),
        .cfg_offset_2(32'd0), .cfg_shift_2(32'd0),
        .cfg_offset_3(32'd0), .cfg_shift_3(32'd0),
        .cfg_offset_4(32'd0), .cfg_shift_4(32'd0),
        .cfg_offset_5(32'd0), .cfg_shift_5(32'd0),
        .cfg_offset_6(32'd0), .cfg_shift_6(32'd0),
        .cfg_offset_7(32'd0), .cfg_shift_7(32'd0),
        .norm_valid(norm_valid), .norm_slot(norm_slot),
        .x0(x0), .x1(x1), .x2(x2), .x3(x3), .x4(x4), .x5(x5), .x6(x6), .x7(x7)
    );

    ml_classifier_wrap u_ml (
        .clk(clk), .rst_n(rst_n),
        .norm_valid(norm_valid), .norm_slot(norm_slot),
        .x0(x0), .x1(x1), .x2(x2), .x3(x3), .x4(x4), .x5(x5), .x6(x6), .x7(x7),
        .ml_valid(ml_valid), .ml_slot(ml_slot), .z(z)
    );

    ml_policy #(.NUM_SYMBOLS(4)) u_policy (
        .clk(clk), .rst_n(rst_n),
        .ml_valid(ml_valid), .ml_slot(ml_slot), .z(z),
        .bid_valid(u_tob.bid_valid), .ask_valid(u_tob.ask_valid),
        .crossed(u_tob.crossed), .seq_gap(1'b0),
        .cfg_ml_th_high(cfg_ml_th_high), .cfg_ml_th_low(cfg_ml_th_low),
        .cfg_ml_score_offset(32'd0), .cfg_ml_score_shift(32'd0),
        .adverse_risk(adverse_risk), .score_raw(), .risk_level(),
        .ml_event_valid(ml_event_valid), .ml_adverse_pulse(ml_adverse_pulse),
        .ml_benign_pulse(ml_benign_pulse), .ml_safe_forced_pulse(ml_safe_forced_pulse)
    );

    reg     fail = 1'b0;

    task chk;
        input integer tag;
        input        got;
        input        exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: got %b, expected %b", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    task chkz;
        input integer tag;
        input integer got;
        input integer exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: z=%0d, expected %0d", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    task chks;
        input integer tag;
        input [1:0]  got;
        input [1:0]  exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: slot=%0d, expected %0d", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    // captures (sampled at the right pipeline cycles inside `fire`)
    reg        c_ml_valid;
    reg [1:0]  c_slot;
    reg signed [31:0] c_z;
    reg        c_adverse, c_ev, c_forced, c_adv_pulse, c_ben_pulse;

    // Present one message and advance the whole ML pipeline (4 clock cycles
    // past the message's commit edge) so adverse_risk/pulses reflect it.
    // z/ml_slot are sampled on ml_valid's own cycle (+3); the verdicts are
    // sampled one cycle later (+4).
    task fire;
        input [7:0]  mt;
        input [7:0]  ms;
        input [31:0] mp;
        input [31:0] mq;
        input [1:0]  fs;
        begin
            @(negedge clk);                    // cycle 0: present
            msg_type = mt; msg_side = ms; msg_price = mp; msg_quantity = mq;
            filt_valid = 1'b1; filt_slot = fs; err_seq_dup = 1'b0;
            @(posedge clk); #1;                // P0: book commits, feat_valid latches
            @(negedge clk);
            filt_valid = 1'b0; err_seq_dup = 1'b0;
            @(posedge clk); #1;                // P1: norm_valid latches
            @(posedge clk); #1;                // P2: ml_valid/z latch
            @(negedge clk);                    // cycle 3: ml_valid/z visible
            c_ml_valid = ml_valid; c_slot = ml_slot; c_z = z;
            @(posedge clk); #1;                // P3: adverse/pulses latch
            c_adverse  = adverse_risk;
            c_ev       = ml_event_valid;
            c_forced   = ml_safe_forced_pulse;
            c_adv_pulse = ml_adverse_pulse;
            c_ben_pulse = ml_benign_pulse;
            @(negedge clk);
            @(posedge clk); #1;                // settle
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        do_reset;

        // ============== Block A: slot 0 bid then ask (z crosses T_high) ====
        fire(QUOTE, SIDE_BID, 32'd100, 32'd10, 2'd0);
        chk(1, c_ml_valid, 1'b1);
        chks(2, c_slot, 2'd0);
        chkz(3, c_z, 32'sd11);         // 0+0+10+0+0+1+0+0
        chk(4, c_adverse, 1'b1);       // ask invalid -> forced
        chk(5, c_forced, 1'b1);

        fire(QUOTE, SIDE_ASK, 32'd110, 32'd5, 2'd0);
        chk(6, c_ml_valid, 1'b1);
        chks(7, c_slot, 2'd0);
        chkz(8, c_z, 32'sd132);        // 10+55+5+0+5+2+0+55
        chk(9, c_adverse, 1'b1);       // z=132 >= 50 -> threshold adverse
        chk(10, c_forced, 1'b0);       // both sides valid -> not forced
        chk(11, c_adv_pulse, 1'b1);

        // ============== Block B: CLEAR forces fail-safe adverse ============
        fire(CLEAR, SIDE_BID, 32'd0, 32'd0, 2'd0);
        chk(12, c_adverse, 1'b1);      // both sides invalid -> forced
        chk(13, c_forced, 1'b1);
        chk(14, c_ev, 1'b1);

        // ============== Block C: multi-symbol ml_slot routing (slot 2) ======
        fire(QUOTE, SIDE_BID, 32'd500, 32'd10, 2'd2);
        chk(15, c_ml_valid, 1'b1);
        chks(16, c_slot, 2'd2);        // slot 2 routed end to end
        chkz(17, c_z, 32'sd11);        // slot 2's own features (0+0+10+0+0+1+0+0)
        chk(18, c_adverse, 1'b1);      // slot 2 ask invalid -> forced
        chk(19, c_forced, 1'b1);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
