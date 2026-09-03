`timescale 1ns / 1ps

// rtl/common/counter_sat.v
//
// Saturating up-counter: increments on `incr`, holds at its maximum value
// (never wraps), synchronous clear with priority over `incr`, synchronous
// active-low reset. `incr` is a plain per-cycle enable (the caller pulses it
// for exactly the cycles to count). `saturated` is high while count == max.
//
// Verilog-2001 only.

module counter_sat #(
    parameter WIDTH = 32
) (
    input  wire             clk,
    input  wire             rst_n,   // active-low, synchronous
    input  wire             clear,   // synchronous clear to 0, priority over incr
    input  wire             incr,    // pulse: increment by 1 this cycle
    output reg  [WIDTH-1:0] count,
    output wire             saturated // high when count == {WIDTH{1'b1}} (max value)
);

    localparam [WIDTH-1:0] MAX = {WIDTH{1'b1}};

    always @(posedge clk) begin
        if (!rst_n || clear) begin
            count <= {WIDTH{1'b0}};
        end else if (incr && count != MAX) begin
            count <= count + 1'b1;
        end
    end

    assign saturated = (count == MAX);

endmodule
