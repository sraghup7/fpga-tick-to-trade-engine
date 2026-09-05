`timescale 1ns / 1ps

// rtl/common/delay_line.v
//
// Generic N-cycle valid+data delay line (S6 alignment register; contract
// docs/contracts/ml_integration.md S2). Delays a {valid, data} pair by
// exactly DEPTH cycles so two parallel pipeline branches that converge on a
// single consumer can be re-aligned in time -- here, the signal branch's
// order intent is delayed by (ML-branch depth - signal-branch depth) so it
// reaches risk_engine.v on the same cycle the ML verdict's registered value
// reflects the SAME triggering event (S1.3 of the contract).
//
// Behavior: a DEPTH-stage shift register of {valid, data} pairs. out_valid/
// out_data reflect whatever was presented at in_valid/in_data exactly DEPTH
// cycles earlier. DEPTH >= 1 (DEPTH=0 is not supported -- there is no
// zero-latency identity case to implement, and allowing it would silently
// hide a wiring mistake where ALIGN_DEPTH should be non-zero). On !rst_n
// every stage's valid clears to 0 (data don't-care) so no stale garbage can
// leak out of reset; data also clears for a clean start.
//
// State is an unpacked reg array indexed by a compile-time-bounded for-loop
// integer -- DEPTH is fixed at elaboration (NFR-11), so there is no runtime
// index and no variable-iteration structure. This matches the codebase's
// existing precedent for BRAM-shaped/array state (latency_histogram.v's
// bucket array).
//
// Verilog-2001 only.

module delay_line #(
    parameter integer WIDTH = 1,
    parameter integer DEPTH = 1   // >= 1; DEPTH=0 not supported
) (
    input  wire             clk,
    input  wire             rst_n,   // active-low, async-assert/sync-deassert
    input  wire             in_valid,
    input  wire [WIDTH-1:0] in_data,
    output wire             out_valid,
    output wire [WIDTH-1:0] out_data
);

    // Stage 0 holds the input delayed one cycle; stage i holds it delayed
    // i+1 cycles; out_* taps stage DEPTH-1 (DEPTH cycles of delay).
    reg         valid_pipe [0:DEPTH-1];
    reg [WIDTH-1:0] data_pipe [0:DEPTH-1];

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DEPTH; i = i + 1) begin
                valid_pipe[i] <= 1'b0;
                data_pipe[i]  <= {WIDTH{1'b0}};
            end
        end else begin
            valid_pipe[0] <= in_valid;
            data_pipe[0]  <= in_data;
            for (i = 1; i < DEPTH; i = i + 1) begin
                valid_pipe[i] <= valid_pipe[i-1];
                data_pipe[i]  <= data_pipe[i-1];
            end
        end
    end

    assign out_valid = valid_pipe[DEPTH-1];
    assign out_data  = data_pipe[DEPTH-1];

endmodule
