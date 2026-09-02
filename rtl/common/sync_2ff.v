`timescale 1ns / 1ps

// rtl/common/sync_2ff.v
//
// Standard two-flip-flop synchronizer for a single-bit signal crossing into
// this design's clock domain. Exactly two FFs in series, no combinational
// path from async_in to sync_out, asynchronous reset of both FFs to
// RESET_VALUE. Intentionally minimal -- no third stage, no debounce.
//
// Verilog-2001 only.

module sync_2ff #(
    parameter RESET_VALUE = 1'b0
) (
    input  wire clk,
    input  wire rst_n,      // active-low, asynchronous reset of the synchronizer's own FFs
    input  wire async_in,   // the potentially-asynchronous / untimed input
    output wire sync_out    // async_in, resynchronized to clk, two-FF deep
);

    reg ff1;
    reg ff2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ff1 <= RESET_VALUE;
            ff2 <= RESET_VALUE;
        end else begin
            ff1 <= async_in;
            ff2 <= ff1;
        end
    end

    assign sync_out = ff2;

endmodule
