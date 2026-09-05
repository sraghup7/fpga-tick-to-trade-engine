`timescale 1ns / 1ps

// Self-checking testbench for rtl/feature_normalizer.v (master spec S3.1
// [G3], FR-22/FR-23; contract docs/contracts/feature_normalizer.md S3).
//
// Icarus:
//   iverilog -g2001 -Wall -o feature_normalizer_tb.vvp rtl/feature_normalizer.v tb/tb_feature_normalizer.v
//   vvp feature_normalizer_tb.vvp
//
// Each normalized lane is x_i = sat8(raw_i - offset_i) >>> shift_i, with an
// ARITHMETIC (sign-preserving) shift -- the negative-diff case below is the
// one that silently fails if the RTL treats the operand as unsigned (a
// logical shift of -500 >>> 3 would give 0x1FFFFFC1, not -63). The module
// registers its output one cycle after feat_valid, so the testbench samples
// the x_* buses at the posedge following the feat_valid drive cycle (c_*
// regs capture pre-edge values each posedge, same convention as the other
// S3 TBs).
//
// Hand-computed cases (contract S3):
//   c1  lane 0  raw=100  off=50  sh=2  -> diff 50  -> 12
//   c2  lane 1  raw=0    off=500 sh=3  -> diff -500 -> -63  (floor semantics;
//       -500/8 = -62.5 rounds toward -inf, NOT -62 -- the arithmetic-shift case)
//   c3  lane 2  raw=100000 off=0 sh=0  -> 127     (saturate high)
//   c4  lane 3  raw=-100000  off=0 sh=0 -> -128    (saturate low)
//   c5  lane 4  raw=1016  off=0  sh=3  -> diff 1016 -> exactly 127, kept 127
//   c6  lane 5  raw=-1024 off=0  sh=3  -> exactly -128, kept -128
//   c7  lane 6  raw=42    off=0  sh=0  -> 42      (identity/pass-through)
//   c8  all eight lanes simultaneously on one feat_valid pulse, distinct
//       configs per lane, incl. lane 7 raw=-5 off=3 sh=1 -> -8>>>1 = -4
//   c9  feat_valid=0: norm_valid stays 0 regardless of data driven
//
// On any mismatch: FAIL line naming the case and lane with expected vs.
// actual; final PASS/FAIL.
//
// Verilog-2001 only.

module tb_feature_normalizer;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg        feat_valid = 1'b0;
    reg [1:0]  feat_slot = 2'd0;
    reg [31:0] feat_f0_spread, feat_f1_mid_delta, feat_f2_imbalance;
    reg [31:0] feat_f3_bid_chg, feat_f4_ask_chg, feat_f5_update_rate;
    reg [31:0] feat_f6_last_trade_dir, feat_f7_volatility;

    reg [31:0] cfg_offset_0, cfg_shift_0;
    reg [31:0] cfg_offset_1, cfg_shift_1;
    reg [31:0] cfg_offset_2, cfg_shift_2;
    reg [31:0] cfg_offset_3, cfg_shift_3;
    reg [31:0] cfg_offset_4, cfg_shift_4;
    reg [31:0] cfg_offset_5, cfg_shift_5;
    reg [31:0] cfg_offset_6, cfg_shift_6;
    reg [31:0] cfg_offset_7, cfg_shift_7;

    wire        norm_valid;
    wire [1:0]  norm_slot;
    wire signed [7:0] x0, x1, x2, x3, x4, x5, x6, x7;

    feature_normalizer dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .feat_valid          (feat_valid),
        .feat_slot           (feat_slot),
        .feat_f0_spread      (feat_f0_spread),
        .feat_f1_mid_delta   (feat_f1_mid_delta),
        .feat_f2_imbalance   (feat_f2_imbalance),
        .feat_f3_bid_chg     (feat_f3_bid_chg),
        .feat_f4_ask_chg     (feat_f4_ask_chg),
        .feat_f5_update_rate (feat_f5_update_rate),
        .feat_f6_last_trade_dir (feat_f6_last_trade_dir),
        .feat_f7_volatility  (feat_f7_volatility),
        .cfg_offset_0 (cfg_offset_0), .cfg_shift_0 (cfg_shift_0),
        .cfg_offset_1 (cfg_offset_1), .cfg_shift_1 (cfg_shift_1),
        .cfg_offset_2 (cfg_offset_2), .cfg_shift_2 (cfg_shift_2),
        .cfg_offset_3 (cfg_offset_3), .cfg_shift_3 (cfg_shift_3),
        .cfg_offset_4 (cfg_offset_4), .cfg_shift_4 (cfg_shift_4),
        .cfg_offset_5 (cfg_offset_5), .cfg_shift_5 (cfg_shift_5),
        .cfg_offset_6 (cfg_offset_6), .cfg_shift_6 (cfg_shift_6),
        .cfg_offset_7 (cfg_offset_7), .cfg_shift_7 (cfg_shift_7),
        .norm_valid          (norm_valid),
        .norm_slot           (norm_slot),
        .x0 (x0), .x1 (x1), .x2 (x2), .x3 (x3),
        .x4 (x4), .x5 (x5), .x6 (x6), .x7 (x7)
    );

    reg fail = 1'b0;
    integer tc = 0;

    // Capture normalized outputs at each posedge (pre-edge), so the sample
    // taken after a feat_valid drive cycle holds that cycle's result.
    reg         c_valid;
    reg [1:0]   c_slot;
    reg signed [7:0] c_x0, c_x1, c_x2, c_x3, c_x4, c_x5, c_x6, c_x7;
    always @(posedge clk) begin
        c_valid = norm_valid;
        c_slot  = norm_slot;
        c_x0 = x0; c_x1 = x1; c_x2 = x2; c_x3 = x3;
        c_x4 = x4; c_x5 = x5; c_x6 = x6; c_x7 = x7;
    end

    // Drive feat_valid high for exactly one clock cycle with the given data,
    // then return after the following idle posedge (c_* = this cycle's
    // normalized result). Config is NOT touched here.
    task drive_feat;
        input [1:0]  slot;
        input [31:0] r0, r1, r2, r3, r4, r5, r6, r7;
        begin
            @(negedge clk);
            feat_valid = 1'b1;
            feat_slot  = slot;
            feat_f0_spread       = r0;
            feat_f1_mid_delta    = r1;
            feat_f2_imbalance    = r2;
            feat_f3_bid_chg      = r3;
            feat_f4_ask_chg      = r4;
            feat_f5_update_rate  = r5;
            feat_f6_last_trade_dir = r6;
            feat_f7_volatility   = r7;
            @(negedge clk);
            feat_valid = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    // Assert + release reset.
    task do_reset;
        begin
            @(negedge clk);
            feat_valid = 1'b0;
            rst_n = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    // Check one lane's captured value against expectation.
    task chk;
        input integer      tag;
        input integer      lane;
        input signed [7:0] exp;
        reg signed [7:0]   got;
        begin
            case (lane)
                0: got = c_x0;
                1: got = c_x1;
                2: got = c_x2;
                3: got = c_x3;
                4: got = c_x4;
                5: got = c_x5;
                6: got = c_x6;
                7: got = c_x7;
            endcase
            if (c_valid !== 1'b1 || got !== exp) begin
                $display("FAIL: case %0d lane %0d: x=%0d, expected %0d (valid=%b)",
                         tag, lane, got, exp, c_valid);
                fail = 1'b1;
            end
        end
    endtask

    // Check all eight lanes + valid + slot against expectations.
    task chk8;
        input integer      tag;
        input [1:0]        eslot;
        input signed [7:0] e0, e1, e2, e3, e4, e5, e6, e7;
        begin
            if (c_valid !== 1'b1) begin
                $display("FAIL: case %0d: norm_valid=%b, expected 1", tag, c_valid);
                fail = 1'b1;
            end
            if (c_slot !== eslot) begin
                $display("FAIL: case %0d: norm_slot=%0d, expected %0d", tag, c_slot, eslot);
                fail = 1'b1;
            end
            if (c_x0 !== e0) begin $display("FAIL: case %0d lane 0: x=%0d, expected %0d", tag, c_x0, e0); fail = 1'b1; end
            if (c_x1 !== e1) begin $display("FAIL: case %0d lane 1: x=%0d, expected %0d", tag, c_x1, e1); fail = 1'b1; end
            if (c_x2 !== e2) begin $display("FAIL: case %0d lane 2: x=%0d, expected %0d", tag, c_x2, e2); fail = 1'b1; end
            if (c_x3 !== e3) begin $display("FAIL: case %0d lane 3: x=%0d, expected %0d", tag, c_x3, e3); fail = 1'b1; end
            if (c_x4 !== e4) begin $display("FAIL: case %0d lane 4: x=%0d, expected %0d", tag, c_x4, e4); fail = 1'b1; end
            if (c_x5 !== e5) begin $display("FAIL: case %0d lane 5: x=%0d, expected %0d", tag, c_x5, e5); fail = 1'b1; end
            if (c_x6 !== e6) begin $display("FAIL: case %0d lane 6: x=%0d, expected %0d", tag, c_x6, e6); fail = 1'b1; end
            if (c_x7 !== e7) begin $display("FAIL: case %0d lane 7: x=%0d, expected %0d", tag, c_x7, e7); fail = 1'b1; end
        end
    endtask

    initial begin
        do_reset;

        // ---- c1: in-range positive, lane 0 ----
        cfg_offset_0 = 32'd50; cfg_shift_0 = 32'd2;
        drive_feat(2'd0, 32'd100, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        chk(1, 0, 8'sd12);

        // ---- c2: NEGATIVE diff, arithmetic shift (S2.4), lane 1 ----
        // diff = -500; -500 >>> 3 = -63 (floor), NOT -62 and NOT a logical
        // shift of the unsigned pattern (0x1FFFFFC1).
        cfg_offset_1 = 32'd500; cfg_shift_1 = 32'd3;
        drive_feat(2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        chk(2, 1, -8'sd63);

        // ---- c3: saturate high, lane 2 ----
        cfg_offset_2 = 32'd0; cfg_shift_2 = 32'd0;
        drive_feat(2'd0, 32'd0, 32'd0, 32'd100000, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        chk(3, 2, 8'sd127);

        // ---- c4: saturate low, lane 3 ----
        cfg_offset_3 = 32'd0; cfg_shift_3 = 32'd0;
        drive_feat(2'd0, 32'd0, 32'd0, 32'd0, -32'd100000, 32'd0, 32'd0, 32'd0, 32'd0);
        chk(4, 3, -8'sd128);

        // ---- c5: boundary exactly 127 (post-shift), lane 4: 1016>>>3=127 ----
        cfg_offset_4 = 32'd0; cfg_shift_4 = 32'd3;
        drive_feat(2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd1016, 32'd0, 32'd0, 32'd0);
        chk(5, 4, 8'sd127);

        // ---- c6: boundary exactly -128 (post-shift), lane 5: -1024>>>3=-128 ----
        cfg_offset_5 = 32'd0; cfg_shift_5 = 32'd3;
        drive_feat(2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, -32'd1024, 32'd0, 32'd0);
        chk(6, 5, -8'sd128);

        // ---- c7: identity (offset=0, shift=0), lane 6 ----
        cfg_offset_6 = 32'd0; cfg_shift_6 = 32'd0;
        drive_feat(2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd42, 32'd0);
        chk(7, 6, 8'sd42);

        // ---- c8: all eight lanes at once on one feat_valid pulse ----
        cfg_offset_0 = 32'd50;  cfg_shift_0 = 32'd2;   // F0:  100-50=50  >>>2 = 12
        cfg_offset_1 = 32'd500; cfg_shift_1 = 32'd3;   // F1:  0-500=-500 >>>3 = -63
        cfg_offset_2 = 32'd0;   cfg_shift_2 = 32'd0;   // F2:  100000 -> 127
        cfg_offset_3 = 32'd0;   cfg_shift_3 = 32'd0;   // F3:  -100000 -> -128
        cfg_offset_4 = 32'd0;   cfg_shift_4 = 32'd3;   // F4:  1016>>>3 = 127
        cfg_offset_5 = 32'd0;   cfg_shift_5 = 32'd3;   // F5:  -1024>>>3 = -128
        cfg_offset_6 = 32'd0;   cfg_shift_6 = 32'd0;   // F6:  42 -> 42
        cfg_offset_7 = 32'd3;   cfg_shift_7 = 32'd1;   // F7:  -5-3=-8 >>>1 = -4
        drive_feat(2'd3,
                   32'd100, 32'd0, 32'd100000, -32'd100000,
                   32'd1016, -32'd1024, 32'd42, -32'd5);
        chk8(8, 2'd3, 8'sd12, -8'sd63, 8'sd127, -8'sd128,
                     8'sd127, -8'sd128, 8'sd42, -8'sd4);

        // ---- c9: feat_valid=0 -> norm_valid stays 0, whatever data is
        //      driven (this cycle and the idle cycle after) ----
        @(negedge clk);
        feat_valid = 1'b0;
        feat_f0_spread       = 32'hDEADBEEF;
        feat_f1_mid_delta    = 32'h80000001;
        feat_f7_volatility   = 32'hFFFFFFFF;
        @(negedge clk);
        @(posedge clk);
        #1;
        tc = tc + 1;
        if (c_valid !== 1'b0) begin
            $display("FAIL: case 9: norm_valid=%b, expected 0 (feat_valid low)", c_valid);
            fail = 1'b1;
        end
        // one more idle cycle: still 0 (nothing re-triggered it)
        @(posedge clk);
        #1;
        if (c_valid !== 1'b0) begin
            $display("FAIL: case 9: norm_valid=%b, expected 0 on following idle cycle", c_valid);
            fail = 1'b1;
        end
        feat_valid = 1'b0;

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
