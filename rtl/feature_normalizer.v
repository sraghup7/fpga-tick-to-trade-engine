`timescale 1ns / 1ps

// rtl/feature_normalizer.v
//
// Raw-to-int8 feature normalizer (master spec S3.1 [G3], FR-22/FR-23).
// Maps feature_extractor.v's eight raw 32-bit features to signed 8-bit
// values for the (not-yet-built) hls4ml classifier IP, using only
// subtract/shift/compare -- no multiplier, no divider (FR-23).
//
// The formula, applied IDENTICALLY to all eight lanes (S2.2):
//
//     x_i = sat_[-128,127]( (raw_i - offset_i) >>> shift_i )
//
// Every raw value's full 32 bits are reinterpreted as two's-complement
// signed before the subtraction -- the raw feature's "unsigned vs signed"
// provenance (docs/contracts/feature_extractor.md S2.2) is irrelevant here,
// because (raw - offset) can legitimately go negative even for a
// conceptually-unsigned feature. There is nothing per-feature to special
// case; all eight lanes share one code path (a single normalization
// function, instantiated eight times).
//
// The shift is a TRUE arithmetic (sign-extending) right shift by the low 5
// bits of shift_i. This is the module's one real footgun: Verilog's >>>
// only sign-extends when its left operand is declared/cast `signed`;
// applied to an unsigned reg it degrades to a logical shift. diff is
// therefore held in a `reg signed` intermediate. Floor semantics: a
// negative diff shifts toward negative infinity (Python's >> behavior), so
// -500 >>> 3 == -63, not -62.
//
// Saturation is exact at the boundaries: shifted > 127 -> 127, shifted <
// -128 -> -128, else the low 8 bits. Never wraps (FR-22).
//
// Timing (S2.3): all eight lanes are computed combinationally and
// registered together on feat_valid's clock edge -- norm_valid pulses for
// exactly one cycle, one cycle after feat_valid; norm_slot carries
// feat_slot through unchanged. No cross-lane state, so back-to-back
// feat_valid pulses are simply independent.
//
// cfg_offset_i / cfg_shift_i are direct ports (S9 CSR ML_OFFSET_0..7 @
// 0x60-0x7C, ML_SHIFT_0..7 @ 0x80-0x9C), standing in for csr_block.v,
// which does not exist yet. Shift amounts >= 32 are undefined (S2.2) and
// get no handling.
//
// Verilog-2001 only.

module feature_normalizer (
    input  wire         clk,
    input  wire         rst_n,   // active-low, async-assert/sync-deassert

    // from feature_extractor.v -- eight raw 32-bit features
    input  wire         feat_valid,
    input  wire [1:0]   feat_slot,
    input  wire [31:0]  feat_f0_spread,
    input  wire [31:0]  feat_f1_mid_delta,
    input  wire [31:0]  feat_f2_imbalance,
    input  wire [31:0]  feat_f3_bid_chg,
    input  wire [31:0]  feat_f4_ask_chg,
    input  wire [31:0]  feat_f5_update_rate,
    input  wire [31:0]  feat_f6_last_trade_dir,
    input  wire [31:0]  feat_f7_volatility,

    // config: ML_OFFSET_0..7 / ML_SHIFT_0..7, one pair per feature
    input  wire [31:0]  cfg_offset_0, input  wire [31:0] cfg_shift_0,
    input  wire [31:0]  cfg_offset_1, input  wire [31:0] cfg_shift_1,
    input  wire [31:0]  cfg_offset_2, input  wire [31:0] cfg_shift_2,
    input  wire [31:0]  cfg_offset_3, input  wire [31:0] cfg_shift_3,
    input  wire [31:0]  cfg_offset_4, input  wire [31:0] cfg_shift_4,
    input  wire [31:0]  cfg_offset_5, input  wire [31:0] cfg_shift_5,
    input  wire [31:0]  cfg_offset_6, input  wire [31:0] cfg_shift_6,
    input  wire [31:0]  cfg_offset_7, input  wire [31:0] cfg_shift_7,

    // normalized outputs -- signed 8-bit, for ml_classifier_wrap.v.
    // Registered one cycle after feat_valid.
    output reg          norm_valid,
    output reg  [1:0]   norm_slot,
    output reg  signed [7:0] x0, x1, x2, x3, x4, x5, x6, x7
);

    // One lane's normalization. raw/off/shf are taken as their 32-bit
    // two's-complement patterns ($signed reinterprets, never sign-changes
    // the data); the diff intermediate is `reg signed` so that >>> really
    // sign-extends (S2.4).
    function signed [7:0] norm8;
        input [31:0] raw;
        input [31:0] off;
        input [31:0] shf;
        reg signed [31:0] diff;
        reg signed [31:0] shifted;
        begin
            diff    = $signed(raw) - $signed(off);   // ordinary 32-bit sub
            shifted = diff >>> shf[4:0];             // arithmetic shift
            if (shifted > 32'sd127) begin
                norm8 = 8'sd127;
            end else if (shifted < -32'sd128) begin
                norm8 = -8'sd128;
            end else begin
                norm8 = shifted[7:0];                // in range: low 8 bits
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            norm_valid <= 1'b0;
            norm_slot  <= 2'd0;
            x0 <= 8'sd0; x1 <= 8'sd0; x2 <= 8'sd0; x3 <= 8'sd0;
            x4 <= 8'sd0; x5 <= 8'sd0; x6 <= 8'sd0; x7 <= 8'sd0;
        end else begin
            norm_valid <= feat_valid;
            norm_slot  <= feat_slot;
            x0 <= norm8(feat_f0_spread, cfg_offset_0, cfg_shift_0);
            x1 <= norm8(feat_f1_mid_delta, cfg_offset_1, cfg_shift_1);
            x2 <= norm8(feat_f2_imbalance, cfg_offset_2, cfg_shift_2);
            x3 <= norm8(feat_f3_bid_chg, cfg_offset_3, cfg_shift_3);
            x4 <= norm8(feat_f4_ask_chg, cfg_offset_4, cfg_shift_4);
            x5 <= norm8(feat_f5_update_rate, cfg_offset_5, cfg_shift_5);
            x6 <= norm8(feat_f6_last_trade_dir, cfg_offset_6, cfg_shift_6);
            x7 <= norm8(feat_f7_volatility, cfg_offset_7, cfg_shift_7);
        end
    end

endmodule
