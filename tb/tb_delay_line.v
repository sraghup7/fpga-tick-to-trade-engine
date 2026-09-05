`timescale 1ns / 1ps

// Self-checking testbench for rtl/common/delay_line.v (contract
// docs/contracts/ml_integration.md S2.1).
//
// Icarus:
//   iverilog -g2001 -Wall -o tb_delay_line.vvp rtl/common/delay_line.v tb/tb_delay_line.v
//   vvp tb_delay_line.vvp
//
// Two instances -- DEPTH=1 (identity+one-cycle) and DEPTH=3 (the value the
// S6 alignment register actually uses). Every expected value below is hand
// derived from the shift-register semantics (out at end of cycle k == input
// presented at cycle k-DEPTH), not copied from a simulator run.
//
// Verilog-2001 only.

module tb_delay_line;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg        in_valid = 1'b0;
    reg [7:0]  in_data = 8'd0;

    wire        out1_valid, out3_valid;
    wire [7:0]  out1_data, out3_data;

    delay_line #(.WIDTH(8), .DEPTH(1)) u_d1 (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data),
        .out_valid(out1_valid), .out_data(out1_data)
    );
    delay_line #(.WIDTH(8), .DEPTH(3)) u_d3 (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data),
        .out_valid(out3_valid), .out_data(out3_data)
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
                $display("FAIL: %0d: got %02x, expected %02x", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    // Present (v, d) for exactly one clock cycle; on return the rising edge
    // that latches it has fired and out_* reflects the post-edge stages.
    task cycle;
        input        v;
        input [7:0]  d;
        begin
            @(negedge clk);
            in_valid = v;
            in_data  = d;
            @(posedge clk);
            #1;
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0; in_valid = 1'b0; in_data = 8'd0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        do_reset;
        chk(0, out1_valid, 1'b0);
        chk(1, out3_valid, 1'b0);

        // ============ DEPTH=1: single value, one cycle of delay ============
        cycle(1'b1, 8'hAA);
        chk(10, out1_valid, 1'b1);
        chk8(11, out1_data, 8'hAA);
        // DEPTH=3 not yet populated after a single cycle
        chk(12, out3_valid, 1'b0);

        // ============ DEPTH=3: distinct value each cycle, 6 cycles =========
        // After cycle k (k=1..6) out3 == input of cycle k-2 for k>=3.
        do_reset;
        cycle(1'b1, 8'h01);
        chk(20, out3_valid, 1'b0);
        cycle(1'b1, 8'h02);
        chk(21, out3_valid, 1'b0);
        cycle(1'b1, 8'h03);
        chk(22, out3_valid, 1'b1); chk8(23, out3_data, 8'h01);
        cycle(1'b1, 8'h04);
        chk(24, out3_valid, 1'b1); chk8(25, out3_data, 8'h02);
        cycle(1'b1, 8'h05);
        chk(26, out3_valid, 1'b1); chk8(27, out3_data, 8'h03);
        cycle(1'b1, 8'h06);
        chk(28, out3_valid, 1'b1); chk8(29, out3_data, 8'h04);

        // ============ gap: one in_valid=0 between two =1 cycles ============
        // Input valid: 1 (0x11), 0, 1 (0x22). Out must show a single 0 in the
        // matching position three cycles later -- 0x11 at cycle 3, gap (0) at
        // cycle 4, 0x22 at cycle 5 -- not a merged/continuous pulse.
        do_reset;
        cycle(1'b1, 8'h11);
        chk(30, out3_valid, 1'b0);
        cycle(1'b0, 8'h00);
        chk(31, out3_valid, 1'b0);
        cycle(1'b1, 8'h22);
        chk(32, out3_valid, 1'b1); chk8(33, out3_data, 8'h11);
        cycle(1'b0, 8'h00);
        chk(34, out3_valid, 1'b0);   // the gap lands here
        cycle(1'b0, 8'h00);
        chk(35, out3_valid, 1'b1); chk8(36, out3_data, 8'h22);

        // ============ reset mid-stream clears the whole pipeline ===========
        // out3_valid is high now; pulse rst_n low while in_valid stays high,
        // release, and confirm no PRE-reset data leaks out. The held input
        // (0x5C, still driven through reset) re-latches at the release edge,
        // so out stays 0 for the release cycle + one refill cycle, then shows
        // 0x5C (the current input, not the stale 0x5A/0x5B that preceded
        // reset) on the third cycle.
        do_reset;
        cycle(1'b1, 8'h5A);
        cycle(1'b1, 8'h5B);
        cycle(1'b1, 8'h5C);
        chk(40, out3_valid, 1'b1);
        @(negedge clk);
        rst_n = 1'b0;
        @(negedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;
        chk(41, out3_valid, 1'b0);   // cleared
        cycle(1'b1, 8'h77);
        chk(42, out3_valid, 1'b0);
        cycle(1'b1, 8'h78);
        chk(43, out3_valid, 1'b1);   // current input finally reaches out
        chk8(44, out3_data, 8'h5C);  // the held-through-reset input, not stale

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
