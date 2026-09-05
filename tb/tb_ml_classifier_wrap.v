`timescale 1ns / 1ps

// Self-checking testbench for rtl/ml_classifier_wrap.v (contract
// docs/contracts/ml_integration.md S3.4).
//
// Icarus (run from the repo root so $readmemh finds model/weights.mem):
//   iverilog -g2001 -Wall -o tb_ml_classifier_wrap.vvp rtl/ml_classifier_wrap.v tb/tb_ml_classifier_wrap.v
//   vvp tb_ml_classifier_wrap.vvp
//
// Uses the placeholder weights (w_i=1 for all i, bias=0) so z = SUM x_i and
// every expected value below is hand-checkable by simple addition.
//
// Verilog-2001 only.

module tb_ml_classifier_wrap;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg        norm_valid = 1'b0;
    reg [1:0]  norm_slot = 2'd0;
    reg signed [7:0] x0, x1, x2, x3, x4, x5, x6, x7;

    wire        ml_valid;
    wire [1:0]  ml_slot;
    wire signed [31:0] z;

    ml_classifier_wrap u_dut (
        .clk(clk), .rst_n(rst_n),
        .norm_valid(norm_valid), .norm_slot(norm_slot),
        .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .x4(x4), .x5(x5), .x6(x6), .x7(x7),
        .ml_valid(ml_valid), .ml_slot(ml_slot), .z(z)
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

    // Present a feature vector for exactly one cycle; on return the latching
    // posedge has fired and ml_valid/ml_slot/z reflect this vector.
    task drive;
        input        v;
        input [1:0]  slot;
        input signed [7:0] a0, a1, a2, a3, a4, a5, a6, a7;
        begin
            @(negedge clk);
            norm_valid = v;
            norm_slot  = slot;
            x0 = a0; x1 = a1; x2 = a2; x3 = a3;
            x4 = a4; x5 = a5; x6 = a6; x7 = a7;
            @(posedge clk);
            #1;
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0; norm_valid = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        do_reset;
        chk(0, ml_valid, 1'b0);

        // ---- all-zero features: z = 0 ----
        drive(1'b1, 2'd0, 0, 0, 0, 0, 0, 0, 0, 0);
        chk(10, ml_valid, 1'b1);
        chk(11, ml_slot, 2'd0);
        chkz(12, z, 32'sd0);

        // ---- all-max-positive: z = 8 * 127 = 1016 ----
        drive(1'b1, 2'd1, 127, 127, 127, 127, 127, 127, 127, 127);
        chkz(13, z, 32'sd1016);

        // ---- all-max-negative: z = 8 * (-128) = -1024 ----
        drive(1'b1, 2'd2, -128, -128, -128, -128, -128, -128, -128, -128);
        chkz(14, z, -32'sd1024);

        // ---- mixed signs: 10-20+30-40+50-60+70-80 = -40 ----
        drive(1'b1, 2'd3, 10, -20, 30, -40, 50, -60, 70, -80);
        chk(15, ml_valid, 1'b1);
        chk(16, ml_slot, 2'd3);   // norm_slot passes through unchanged
        chkz(17, z, -32'sd40);

        // ---- norm_valid=0 produces no ml_valid pulse ----
        drive(1'b0, 2'd0, 0, 0, 0, 0, 0, 0, 0, 0);
        chk(18, ml_valid, 1'b0);

        // ---- back-to-back norm_valid pulses: both pipelined, none dropped ----
        do_reset;
        drive(1'b1, 2'd0, 5, 5, 5, 5, 5, 5, 5, 5);   // z = 40
        chkz(20, z, 32'sd40);
        drive(1'b1, 2'd1, 3, 3, 3, 3, 3, 3, 3, 3);   // z = 24
        chk(21, ml_valid, 1'b1);
        chk(22, ml_slot, 2'd1);
        chkz(23, z, 32'sd24);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
