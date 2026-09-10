`timescale 1ns / 1ps

// rtl/ml_classifier_wrap.v
//
// Fallback linear classifier (master spec S3.1 [P], S5.4/S5.6, FR-27;
// contract docs/contracts/ml_integration.md S3). Hand-written, NOT
// hls4ml-generated: hls4ml/ is still empty, so per master spec S15 this
// module stands in for the hls4ml IP with a zero-change port list -- S4's
// training pipeline HAS now run (docs/design_decisions.md D52) and
// model/weights.mem/model/bias.mem hold real trained, quantized weights,
// exactly the "only these two files change" swap this module was designed
// for from the start -- this file and all its wiring are unchanged.
//
// The model is a single Dense(8->1) linear layer with no activation:
//
//     z = bias + SUM_{i=0..7} w_i * x_i
//
// exactly per S5.4's parameter-format table: signed 8-bit features and
// weights (int8), exact signed 16-bit products, signed 32-bit accumulator.
// Weights and bias are elaboration-time-loaded from .mem files via
// $readmemh -- the same "baked at synthesis" hardware contract the real
// hls4ml IP will have (S9's note that weights are not CSR-writable).
// model/weights.mem/bias.mem are real trained values (D52) -- still not
// evidence of real adverse-selection prediction (a synthetic proxy label,
// per ml_engineer_brief.md SS5); see docs/design_decisions.md D52 for the
// full training/verification record, including the RTL bit-exactness
// harness (tb/tb_ml_bit_exact.v) that checks every one of 4,860 real
// golden vectors against this exact module.
//
// The eight 16-bit product intermediates are held explicitly (not folded into
// one wide expression) -- matches S5.4's table literally and keeps every
// width auditable, same spirit as risk_engine.v's D16/FR-45 signed-width
// comments and feature_normalizer.v's >>> footgun note.
//
// Timing: z/ml_valid/ml_slot register exactly one cycle after norm_valid
// (S1.3: feat_valid +1, norm_valid +2, ml_valid +3), norm_slot passes through
// unchanged. Back-to-back norm_valid pulses are independent -- no cross-event
// state.
//
// Verilog-2001 only.

module ml_classifier_wrap #(
    parameter WEIGHTS_FILE = "model/weights.mem",
    parameter BIAS_FILE    = "model/bias.mem"
) (
    input  wire        clk,
    input  wire        rst_n,

    // from feature_normalizer.v
    input  wire         norm_valid,
    input  wire [1:0]   norm_slot,
    input  wire signed [7:0] x0, x1, x2, x3, x4, x5, x6, x7,

    // to ml_policy.v -- registered one cycle after norm_valid
    output reg          ml_valid,
    output reg  [1:0]   ml_slot,
    output reg  signed [31:0] z
);

    reg signed [7:0]  w_mem    [0:7];
    reg signed [31:0] bias_mem [0:0];
    initial begin
        $readmemh(WEIGHTS_FILE, w_mem);
        $readmemh(BIAS_FILE, bias_mem);
    end

    wire signed [31:0] bias = bias_mem[0];

    // Exact int8 x int8 -> int16 products (S5.4).
    wire signed [15:0] p0 = $signed(x0) * $signed(w_mem[0]);
    wire signed [15:0] p1 = $signed(x1) * $signed(w_mem[1]);
    wire signed [15:0] p2 = $signed(x2) * $signed(w_mem[2]);
    wire signed [15:0] p3 = $signed(x3) * $signed(w_mem[3]);
    wire signed [15:0] p4 = $signed(x4) * $signed(w_mem[4]);
    wire signed [15:0] p5 = $signed(x5) * $signed(w_mem[5]);
    wire signed [15:0] p6 = $signed(x6) * $signed(w_mem[6]);
    wire signed [15:0] p7 = $signed(x7) * $signed(w_mem[7]);

    wire signed [31:0] z_c = bias
        + $signed(p0) + $signed(p1) + $signed(p2) + $signed(p3)
        + $signed(p4) + $signed(p5) + $signed(p6) + $signed(p7);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ml_valid <= 1'b0;
            ml_slot  <= 2'd0;
            z        <= 32'sd0;
        end else begin
            ml_valid <= norm_valid;
            ml_slot  <= norm_slot;
            z        <= z_c;
        end
    end

endmodule
