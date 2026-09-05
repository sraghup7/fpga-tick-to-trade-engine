`timescale 1ns / 1ps

// Self-checking testbench for rtl/ml_policy.v (contract
// docs/contracts/ml_integration.md S4.4).
//
// Icarus:
//   iverilog -g2001 -Wall -o tb_ml_policy.vvp rtl/ml_policy.v tb/tb_ml_policy.v
//   vvp tb_ml_policy.vvp
//
// Thresholds cfg_ml_th_high=20 / cfg_ml_th_low=-20 throughout; every
// expected verdict below is hand-derived from the hysteresis + fail-safe
// rules, not copied from a run.
//
// Verilog-2001 only.

module tb_ml_policy;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg        ml_valid = 1'b0;
    reg [1:0]  ml_slot = 2'd0;
    reg signed [31:0] z = 32'sd0;

    reg [3:0]  bid_valid = 4'd0;
    reg [3:0]  ask_valid = 4'd0;
    reg [3:0]  crossed   = 4'd0;
    reg        seq_gap   = 1'b0;

    reg signed [31:0] cfg_ml_th_high = 32'sd20;
    reg signed [31:0] cfg_ml_th_low  = -32'sd20;
    reg [31:0] cfg_ml_score_offset = 32'd0;
    reg [31:0] cfg_ml_score_shift  = 32'd0;

    wire        adverse_risk;
    wire signed [31:0] score_raw;
    wire [7:0]  risk_level;
    wire        ml_event_valid, ml_adverse_pulse, ml_benign_pulse, ml_safe_forced_pulse;

    ml_policy #(.NUM_SYMBOLS(4)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .ml_valid(ml_valid), .ml_slot(ml_slot), .z(z),
        .bid_valid(bid_valid), .ask_valid(ask_valid), .crossed(crossed), .seq_gap(seq_gap),
        .cfg_ml_th_high(cfg_ml_th_high), .cfg_ml_th_low(cfg_ml_th_low),
        .cfg_ml_score_offset(cfg_ml_score_offset), .cfg_ml_score_shift(cfg_ml_score_shift),
        .adverse_risk(adverse_risk), .score_raw(score_raw), .risk_level(risk_level),
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

    task chk8;
        input integer tag;
        input [7:0]  got;
        input [7:0]  exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: got %0d, expected %0d", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    // Present one ML event (ml_valid=1 for exactly one cycle). On return the
    // latching posedge has fired and adverse_risk/score_raw/risk_level and
    // the one-cycle pulses reflect this event; ml_valid is left asserted so
    // the caller can inspect the pulses before settle() clears them.
    task drive;
        input        v;
        input [1:0]  slot;
        input signed [31:0] zin;
        begin
            @(negedge clk);
            ml_valid = v;
            ml_slot  = slot;
            z        = zin;
            @(posedge clk);
            #1;
        end
    endtask

    // Deassert ml_valid and advance one cycle (pulses clear; adverse_risk/
    // score_raw/risk_level hold).
    task settle;
        begin
            @(negedge clk);
            ml_valid = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0; ml_valid = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        do_reset;
        // healthy baseline: all four slots valid, not crossed, no gap
        bid_valid = 4'b1111;
        ask_valid = 4'b1111;
        crossed   = 4'b0000;
        seq_gap   = 1'b0;
        chk(0, adverse_risk, 1'b0);
        chk(1, ml_event_valid, 1'b0);

        // ---- rising through T_high: z=25 -> adverse ----
        drive(1'b1, 2'd0, 32'sd25);
        chk(10, adverse_risk, 1'b1);
        chk(11, ml_adverse_pulse, 1'b1);
        chk(12, ml_benign_pulse, 1'b0);
        chk(13, ml_safe_forced_pulse, 1'b0);
        settle;

        // ---- falling through T_low: z=-25 -> benign ----
        drive(1'b1, 2'd0, -32'sd25);
        chk(14, adverse_risk, 1'b0);
        chk(15, ml_benign_pulse, 1'b1);
        chk(16, ml_adverse_pulse, 1'b0);
        settle;

        // ---- hold zone (from adverse): z=0 in (-20,20) -> holds 1 ----
        drive(1'b1, 2'd0, 32'sd25);
        settle;                              // adverse_risk now 1
        drive(1'b1, 2'd0, 32'sd0);
        chk(20, adverse_risk, 1'b1);         // held
        chk(21, ml_adverse_pulse, 1'b1);     // pulse follows held state
        chk(22, ml_benign_pulse, 1'b0);
        settle;

        // ---- hold zone (from benign): z=0 -> holds 0 ----
        drive(1'b1, 2'd0, -32'sd25);
        settle;                              // adverse_risk now 0
        drive(1'b1, 2'd0, 32'sd0);
        chk(23, adverse_risk, 1'b0);         // held
        chk(24, ml_benign_pulse, 1'b1);
        chk(25, ml_adverse_pulse, 1'b0);
        settle;

        // ---- fail-safe forcing overrides a benign z (each cause alone) ----
        // crossed[slot]
        crossed[0] = 1'b1;
        drive(1'b1, 2'd0, -32'sd25);
        chk(30, adverse_risk, 1'b1);
        chk(31, ml_safe_forced_pulse, 1'b1);
        chk(32, ml_adverse_pulse, 1'b1);
        settle;
        crossed[0] = 1'b0;

        // ~bid_valid[slot]
        bid_valid[0] = 1'b0;
        drive(1'b1, 2'd0, -32'sd25);
        chk(33, adverse_risk, 1'b1);
        chk(34, ml_safe_forced_pulse, 1'b1);
        settle;
        bid_valid[0] = 1'b1;

        // ~ask_valid[slot]
        ask_valid[0] = 1'b0;
        drive(1'b1, 2'd0, -32'sd25);
        chk(35, adverse_risk, 1'b1);
        chk(36, ml_safe_forced_pulse, 1'b1);
        settle;
        ask_valid[0] = 1'b1;

        // seq_gap
        seq_gap = 1'b1;
        drive(1'b1, 2'd0, -32'sd25);
        chk(37, adverse_risk, 1'b1);
        chk(38, ml_safe_forced_pulse, 1'b1);
        settle;
        seq_gap = 1'b0;

        // ---- ml_slot indexing: forcing reads at ml_slot, not slot 0 ----
        // slot 2 crossed, slot 0 healthy: benign z on slot 0 -> benign; on
        // slot 2 -> forced adverse.
        drive(1'b1, 2'd0, -32'sd25);   // restore benign baseline on slot 0
        settle;
        crossed[2] = 1'b1;
        drive(1'b1, 2'd2, -32'sd25);   // same benign z, addressed slot crossed
        chk(40, adverse_risk, 1'b1);
        chk(41, ml_safe_forced_pulse, 1'b1);
        settle;
        drive(1'b1, 2'd0, -32'sd25);   // slot 0 still healthy
        chk(42, adverse_risk, 1'b0);
        settle;
        crossed[2] = 1'b0;

        // ---- risk_level saturation (FR-33 / S5.4) ----
        cfg_ml_score_offset = 32'd0;
        cfg_ml_score_shift  = 32'd0;
        drive(1'b1, 2'd0, 32'sd300);
        chk8(50, risk_level, 8'd255);   // saturates, does not wrap to 44
        settle;
        drive(1'b1, 2'd0, -32'sd50);
        chk8(51, risk_level, 8'd0);
        settle;
        // mid-range with a nonzero shift: (100 >> 2) = 25
        cfg_ml_score_shift = 32'd2;
        drive(1'b1, 2'd0, 32'sd100);
        chk8(52, risk_level, 8'd25);
        settle;
        cfg_ml_score_shift = 32'd0;

        // ---- no ml_valid: outputs hold, no pulse ----
        drive(1'b0, 2'd0, 32'sd0);
        chk(60, ml_event_valid, 1'b0);
        chk(61, ml_adverse_pulse, 1'b0);
        chk(62, ml_benign_pulse, 1'b0);
        chk(63, ml_safe_forced_pulse, 1'b0);
        settle;

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
