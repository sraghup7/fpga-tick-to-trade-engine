`timescale 1ns / 1ps

// Self-checking testbench for rtl/common/counter_sat.v.
//
// Icarus:
//   iverilog -g2001 -Wall -o counter_sat_tb.vvp rtl/common/counter_sat.v tb/tb_counter_sat.v
//   vvp counter_sat_tb.vvp
//
// Checks:
//   - increments once per `incr` cycle, saturates and HOLDS at max (no wrap)
//   - `saturated` high exactly while count == max
//   - `clear` wins over `incr` when both asserted the same cycle
//   - synchronous reset behaves like clear
//   - parameter plumbing at WIDTH=4 (easy to saturate) and WIDTH=32 (default)
//
// Verilog-2001 only.

module tb_counter_sat;

    reg clk = 1'b0;
    always #5 clk = ~clk;   // 10 ns period

    // --- two DUTs: WIDTH=4 (saturation reachable) and WIDTH=32 (default) ---
    wire [3:0]  count4;
    wire        sat4;
    reg         incr4, clear4;

    wire [31:0] count32;
    wire        sat32;
    reg         incr32, clear32;

    reg        rst_n = 1'b0;

    counter_sat #(.WIDTH(4)) dut4 (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (clear4),
        .incr      (incr4),
        .count     (count4),
        .saturated (sat4)
    );

    counter_sat #(.WIDTH(32)) dut32 (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (clear32),
        .incr      (incr32),
        .count     (count32),
        .saturated (sat32)
    );

    reg fail = 1'b0;

    // Apply inputs for one clk cycle; afterwards #1 has passed so count is stable.
    task tick4;
        input i;
        input c;
        begin
            @(negedge clk);
            incr4 = i; clear4 = c;
            @(posedge clk);
            #1;
        end
    endtask

    task tick32;
        input i;
        input c;
        begin
            @(negedge clk);
            incr32 = i; clear32 = c;
            @(posedge clk);
            #1;
        end
    endtask

    integer k;

    initial begin
        incr4 = 1'b0; clear4 = 1'b0;
        incr32 = 1'b0; clear32 = 1'b0;

        // --- reset to 0 ---
        rst_n = 1'b0;
        #40;
        rst_n = 1'b1;
        #1;
        if (count4 !== 4'd0) begin $display("FAIL: count4=%0d after reset", count4); fail = 1'b1; end
        if (count32 !== 32'd0) begin $display("FAIL: count32=%0d after reset", count32); fail = 1'b1; end
        if (sat4 !== 1'b0) begin $display("FAIL: sat4 high after reset"); fail = 1'b1; end
        if (sat32 !== 1'b0) begin $display("FAIL: sat32 high after reset"); fail = 1'b1; end

        // --- WIDTH=4: increment 18 cycles; expect 1..14 then hold at 15 ---
        for (k = 1; k <= 18; k = k + 1) begin
            tick4(1'b1, 1'b0);
            if (k < 15) begin
                if (count4 !== k[3:0]) begin
                    $display("FAIL: count4=%0d after %0d incrs (expected %0d)", count4, k, k);
                    fail = 1'b1;
                end
                if (sat4 !== 1'b0) begin $display("FAIL: sat4 high at count=%0d", count4); fail = 1'b1; end
            end else begin
                if (count4 !== 4'd15) begin
                    $display("FAIL: count4=%0d after %0d incrs (expected 15, saturated)", count4, k);
                    fail = 1'b1;
                end
                if (sat4 !== 1'b1) begin $display("FAIL: sat4 low at count=15"); fail = 1'b1; end
            end
        end

        // --- hold at max while incr keeps asserting ---
        tick4(1'b1, 1'b0);
        if (count4 !== 4'd15) begin $display("FAIL: count4=%0d, wrapped from 15", count4); fail = 1'b1; end
        if (sat4 !== 1'b1) begin $display("FAIL: sat4 low at count=15"); fail = 1'b1; end

        // --- clear wins over incr in the same cycle (from saturated) ---
        tick4(1'b1, 1'b1);
        if (count4 !== 4'd0) begin $display("FAIL: clear+incr gave %0d (expected 0, clear wins)", count4); fail = 1'b1; end
        if (sat4 !== 1'b0) begin $display("FAIL: sat4 high after clear"); fail = 1'b1; end

        // --- plain clear ---
        tick4(1'b1, 1'b0);
        tick4(1'b1, 1'b0);
        tick4(1'b1, 1'b0);
        if (count4 !== 4'd3) begin $display("FAIL: count4=%0d after 3 incrs", count4); fail = 1'b1; end
        tick4(1'b0, 1'b1);
        if (count4 !== 4'd0) begin $display("FAIL: count4=%0d after clear", count4); fail = 1'b1; end

        // --- WIDTH=32 (default): plumbing check, count/clear/reset ---
        tick32(1'b1, 1'b0);
        if (count32 !== 32'd1) begin $display("FAIL: count32=%0d after 1 incr", count32); fail = 1'b1; end
        if (sat32 !== 1'b0) begin $display("FAIL: sat32 high at count=1"); fail = 1'b1; end
        tick32(1'b1, 1'b0);
        if (count32 !== 32'd2) begin $display("FAIL: count32=%0d after 2 incrs", count32); fail = 1'b1; end
        tick32(1'b1, 1'b1);   // clear wins
        if (count32 !== 32'd0) begin $display("FAIL: clear+incr gave %0d (expected 0)", count32); fail = 1'b1; end

        // --- synchronous reset behaves like clear ---
        tick32(1'b1, 1'b0);
        tick32(1'b1, 1'b0);
        if (count32 !== 32'd2) begin $display("FAIL: count32=%0d before reset", count32); fail = 1'b1; end
        rst_n = 1'b0;
        #40;
        if (count32 !== 32'd0) begin $display("FAIL: count32=%0d after reset", count32); fail = 1'b1; end
        if (count4 !== 4'd0) begin $display("FAIL: count4=%0d after reset", count4); fail = 1'b1; end
        rst_n = 1'b1;

        // --- no-op cycle (neither incr nor clear) holds the count ---
        tick4(1'b0, 1'b0);
        if (count4 !== 4'd0) begin $display("FAIL: count4=%0d after no-op", count4); fail = 1'b1; end

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
