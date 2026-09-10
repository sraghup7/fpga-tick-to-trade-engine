`timescale 1ns / 1ps

// Self-checking testbench for rtl/ml_classifier_wrap.v against the REAL
// trained golden vectors exported by model/train.py (FR-34, master spec
// T35_ml_bit_exact) -- as opposed to tb/tb_ml_classifier_wrap.v's hand-
// computed placeholder-weight cases. Regenerate stimulus first:
//   python scripts/gen_ml_bit_exact_vectors.py
// Then, from the repo root:
//   iverilog -g2001 -Wall -o tb_ml_bit_exact.vvp rtl/ml_classifier_wrap.v tb/tb_ml_bit_exact.v
//   vvp tb_ml_bit_exact.vvp
//
// Verilog-2001 only.

`include "sim/vectors/ml_bit_exact_count.vh"

module tb_ml_bit_exact;

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

    reg [7:0]  x_mem [0:(`ML_BIT_EXACT_N * 8) - 1];
    reg [31:0] z_expected [0:`ML_BIT_EXACT_N - 1];

    initial begin
        $readmemh("sim/vectors/ml_bit_exact_x.mem", x_mem);
        $readmemh("sim/vectors/ml_bit_exact_z.mem", z_expected);
    end

    integer i;
    integer mismatches;
    reg fail;

    task drive;
        input signed [7:0] a0, a1, a2, a3, a4, a5, a6, a7;
        begin
            @(negedge clk);
            norm_valid = 1'b1;
            norm_slot  = 2'd0;
            x0 = a0; x1 = a1; x2 = a2; x3 = a3;
            x4 = a4; x5 = a5; x6 = a6; x7 = a7;
            @(posedge clk);
            #1;
        end
    endtask

    // D53: ml_classifier_wrap.v now registers z 2 cycles after norm_valid
    // (was 1), so back-to-back drive() calls (one per vector, streamed with
    // no gap to also exercise true pipelined back-to-back behavior) present
    // vector i's inputs but leave z showing vector (i-1)'s result by the time
    // drive() returns -- one settle cycle (norm_valid=0) drains the last
    // vector's own result after the loop.
    task settle;
        begin
            @(negedge clk);
            norm_valid = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        @(negedge clk);
        rst_n = 1'b0; norm_valid = 1'b0;
        @(negedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        mismatches = 0;
        fail = 1'b0;

        for (i = 0; i < `ML_BIT_EXACT_N; i = i + 1) begin
            drive(
                x_mem[i*8+0], x_mem[i*8+1], x_mem[i*8+2], x_mem[i*8+3],
                x_mem[i*8+4], x_mem[i*8+5], x_mem[i*8+6], x_mem[i*8+7]
            );
            // D53: z reflects vector (i-1) here (2-cycle latency, streamed
            // back-to-back) -- nothing to check yet on the very first vector.
            if (i > 0) begin
                if (z !== $signed(z_expected[i-1])) begin
                    mismatches = mismatches + 1;
                    if (mismatches <= 10) begin
                        $display("FAIL: vector %0d: z=%0d, expected %0d", i-1, z, $signed(z_expected[i-1]));
                    end
                    fail = 1'b1;
                end
            end
        end
        // Drain: one settle cycle brings up the LAST vector's own result.
        settle;
        if (z !== $signed(z_expected[`ML_BIT_EXACT_N-1])) begin
            mismatches = mismatches + 1;
            if (mismatches <= 10) begin
                $display("FAIL: vector %0d: z=%0d, expected %0d",
                         `ML_BIT_EXACT_N-1, z, $signed(z_expected[`ML_BIT_EXACT_N-1]));
            end
            fail = 1'b1;
        end

        if (fail) begin
            $display("FAIL: %0d / %0d golden vectors mismatched", mismatches, `ML_BIT_EXACT_N);
            $finish;
        end
        $display("PASS: all %0d golden vectors bit-exact", `ML_BIT_EXACT_N);
        $finish;
    end

endmodule
