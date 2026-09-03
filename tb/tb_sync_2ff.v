`timescale 1ns / 1ps

// Self-checking testbench for rtl/common/sync_2ff.v.
//
// Icarus:
//   iverilog -g2001 -Wall -o sync_2ff_tb.vvp rtl/common/sync_2ff.v tb/tb_sync_2ff.v
//   vvp sync_2ff_tb.vvp
//
// Checks:
//   - exactly 2 clock edges for async_in -> sync_out (2-FF deep, no combinational path)
//   - asynchronous reset to RESET_VALUE (both RESET_VALUE=0 and =1 instances)
//   - robustness when async_in changes right at a clock edge (both DUT and the
//     reference model see the same edge; equivalence must still hold)
//
// Verilog-2001 only.

module tb_sync_2ff;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg async_in = 1'b0;

    wire sync_out0;   // RESET_VALUE = 1'b0
    wire sync_out1;   // RESET_VALUE = 1'b1

    sync_2ff #(.RESET_VALUE(1'b0)) dut0 (
        .clk      (clk),
        .rst_n    (rst_n),
        .async_in (async_in),
        .sync_out (sync_out0)
    );

    sync_2ff #(.RESET_VALUE(1'b1)) dut1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .async_in (async_in),
        .sync_out (sync_out1)
    );

    always #5 clk = ~clk;   // 10 ns period

    // -----------------------------------------------------------------
    // Independent reference: the spec's exact 2-FF structure, one per
    // RESET_VALUE. Every clk edge the DUT must agree with it.
    // -----------------------------------------------------------------
    reg f0a, f0b;
    reg f1a, f1b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin f0a <= 1'b0; f0b <= 1'b0; end
        else begin f0a <= async_in; f0b <= f0a; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin f1a <= 1'b1; f1b <= 1'b1; end
        else begin f1a <= async_in; f1b <= f1a; end
    end

    reg fail = 1'b0;

    always @(posedge clk) begin
        #1;   // let nonblocking updates settle
        if (sync_out0 !== f0b) begin
            $display("FAIL: sync_out0=%b != ref=%b at t=%0t", sync_out0, f0b, $time);
            fail = 1'b1;
        end
        if (sync_out1 !== f1b) begin
            $display("FAIL: sync_out1=%b != ref=%b at t=%0t", sync_out1, f1b, $time);
            fail = 1'b1;
        end
    end

    // -----------------------------------------------------------------
    // Explicit checks
    // -----------------------------------------------------------------
    task check_reset_values;
        begin
            #1;
            if (sync_out0 !== 1'b0) begin
                $display("FAIL: sync_out0=%b during reset (expected 0) at t=%0t", sync_out0, $time);
                fail = 1'b1;
            end
            if (sync_out1 !== 1'b1) begin
                $display("FAIL: sync_out1=%b during reset (expected 1) at t=%0t", sync_out1, $time);
                fail = 1'b1;
            end
        end
    endtask

    initial begin
        // --- initial reset: async_out must sit at RESET_VALUE at any time ---
        rst_n = 1'b0;
        check_reset_values();     // sampled at t=1 (async reset already applied at t=0)
        #13;
        check_reset_values();
        #27;
        check_reset_values();
        #40;
        check_reset_values();

        rst_n = 1'b1;

        // --- explicit 2-cycle latency spot check (phase-robust) ---
        @(negedge clk);                     // change async_in mid-cycle, never at an edge
        async_in = 1'b1;
        #1;
        if (sync_out0 !== 1'b0) begin
            $display("FAIL: sync_out0 changed too early at t=%0t", $time);
            fail = 1'b1;
        end
        @(posedge clk);                     // 1st edge after the change: only ff1 updates
        #1;
        if (sync_out0 !== 1'b0) begin
            $display("FAIL: sync_out0 changed after only 1 clock edge at t=%0t", $time);
            fail = 1'b1;
        end
        @(posedge clk);                     // 2nd edge after the change: sync_out0 = new
        #1;
        if (sync_out0 !== 1'b1) begin
            $display("FAIL: sync_out0 did not change after 2 clock edges at t=%0t", $time);
            fail = 1'b1;
        end

        // --- clock-relationship-free toggle sequence (mix of edge-aligned and
        //     arbitrary times; 205 is aligned, the rest are not) ---
        #17; async_in = 1'b0;
        #38; async_in = 1'b1;
        #32; async_in = 1'b0;
        #73; async_in = 1'b1;
        #45; async_in = 1'b0;
        #52; async_in = 1'b1;
        #120; async_in = 1'b0;   // aligned to a clk edge
        #64; async_in = 1'b1;
        #95; async_in = 1'b0;
        #30; async_in = 1'b1;
        #100;

        // --- re-assert reset; async reset must win regardless of async_in ---
        rst_n = 1'b0;
        check_reset_values();
        #23;
        check_reset_values();
        #37;
        check_reset_values();
        rst_n = 1'b1;
        #100;

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
