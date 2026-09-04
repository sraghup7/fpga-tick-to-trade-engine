`timescale 1ns / 1ps

// rtl/ml_policy.v
//
// ML policy stage (master spec S3.1 [Q], S5.4/S5.5, FR-28/29/31/33; contract
// docs/contracts/ml_integration.md S4). Turns ml_classifier_wrap.v's raw
// score z into the 1-bit adverse_risk verdict that risk_engine.v's gate 0x09
// consumes, via a hysteresis threshold (FR-28/29), plus partial fail-safe
// forcing (FR-26/31) and the FR-33 telemetry pulses feeding csr_block.v's
// counters.
//
// Hysteresis (FR-28/29): adverse_risk sets when z >= cfg_ml_th_high, clears
// when z <= cfg_ml_th_low, and HOLDS its current value in the band
// cfg_ml_th_low < z < cfg_ml_th_high (no chatter around the threshold).
//
// Fail-safe forcing (FR-26/31, contract S1.4): when the addressed slot's book
// is invalid on either side, crossed, or the feed has a sticky sequence gap,
// adverse_risk is forced to 1 regardless of z. Staleness forcing is
// deliberately NOT implemented here -- risk_engine.v's own gate 0x05 already
// independently blocks any stale order, and per-event staleness would need a
// duplicate of risk_engine.v's pend_* timestamp mechanism (contract S1.4,
// flagged, not silently dropped).
//
// Telemetry (FR-33): score_raw (32-bit) and risk_level (8-bit,
// saturate((z + offset) >> shift), S5.4) are produced but have no consumer
// wired yet (contract S1.4); they are reserved outputs. The four counter
// pulses drive csr_block.v's cnt_ml_events/cnt_ml_adverse/cnt_ml_benign/
// cnt_ml_safe_forced. Exactly one of ml_adverse_pulse/ml_benign_pulse fires
// per event -- including the hold zone, where the pulse follows the HELD
// adverse_risk -- so S10's invariant cnt_ml_events = cnt_ml_adverse +
// cnt_ml_benign holds on every event. safe_state_c forces both
// ml_safe_forced_pulse and ml_adverse_pulse, satisfying cnt_ml_safe_forced
// <= cnt_ml_adverse by construction.
//
// bid_valid/ask_valid/crossed are tob_engine.v's REGISTERED buses, read at
// ml_slot one cycle past the triggering event's register commit -- safe per
// D23 (same reasoning as risk_engine.v); seq_gap is seq_monitor.v's feed-wide
// sticky level.
//
// Verilog-2001 only.

module ml_policy #(
    parameter integer NUM_SYMBOLS = 4   // matches every other S3/S5/S6 module
) (
    input  wire        clk,
    input  wire        rst_n,

    // from ml_classifier_wrap.v
    input  wire         ml_valid,
    input  wire [1:0]   ml_slot,
    input  wire signed [31:0] z,

    // fail-safe inputs -- tob_engine.v's REGISTERED buses (safe to read here,
    // well past the triggering event's register commit) and seq_monitor.v's
    // feed-wide sticky bit
    input  wire [NUM_SYMBOLS-1:0] bid_valid,
    input  wire [NUM_SYMBOLS-1:0] ask_valid,
    input  wire [NUM_SYMBOLS-1:0] crossed,
    input  wire                    seq_gap,

    // config (S9 CSR map), direct ports from csr_block.v
    input  wire signed [31:0] cfg_ml_th_high,   // 0x48
    input  wire signed [31:0] cfg_ml_th_low,    // 0x4C
    input  wire [31:0] cfg_ml_score_offset,     // 0x54
    input  wire [31:0] cfg_ml_score_shift,      // 0x58

    // to risk_engine.v -- persisting hysteresis level, valid every cycle
    output reg          adverse_risk,

    // telemetry (FR-33) -- no consumer wired yet (S1.4), reserved
    output reg  signed [31:0] score_raw,
    output reg  [7:0]         risk_level,

    // to csr_block.v -- one-cycle pulses per ML event
    output reg          ml_event_valid,
    output reg          ml_adverse_pulse,
    output reg          ml_benign_pulse,
    output reg          ml_safe_forced_pulse
);

    wire safe_state_c = ~bid_valid[ml_slot] | ~ask_valid[ml_slot]
                       | crossed[ml_slot] | seq_gap;

    // risk_level = saturate((z + offset) >> shift) into [0,255], S5.4. The
    // shift is a TRUE arithmetic (sign-extending) right shift by the low 5
    // bits -- same >>> footgun as feature_normalizer.v: the shifted
    // intermediate must be declared `reg signed` or >>> degrades to a logical
    // shift.
    function [7:0] sat_risk_level;
        input signed [31:0] zin;
        input [31:0] offset;
        input [31:0] shift;
        reg signed [31:0] shifted;
        begin
            shifted = (zin + $signed(offset)) >>> shift[4:0];
            if (shifted > 32'sd255)      sat_risk_level = 8'd255;
            else if (shifted < 32'sd0)   sat_risk_level = 8'd0;
            else                          sat_risk_level = shifted[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adverse_risk        <= 1'b0;
            score_raw           <= 32'sd0;
            risk_level          <= 8'd0;
            ml_event_valid      <= 1'b0;
            ml_adverse_pulse    <= 1'b0;
            ml_benign_pulse     <= 1'b0;
            ml_safe_forced_pulse <= 1'b0;
        end else if (ml_valid) begin
            ml_event_valid <= 1'b1;
            score_raw      <= z;
            risk_level     <= sat_risk_level(z, cfg_ml_score_offset, cfg_ml_score_shift);
            if (safe_state_c) begin
                adverse_risk         <= 1'b1;
                ml_safe_forced_pulse <= 1'b1;
                ml_adverse_pulse     <= 1'b1;
                ml_benign_pulse      <= 1'b0;
            end else if (z >= cfg_ml_th_high) begin
                adverse_risk         <= 1'b1;
                ml_adverse_pulse     <= 1'b1;
                ml_benign_pulse      <= 1'b0;
                ml_safe_forced_pulse <= 1'b0;
            end else if (z <= cfg_ml_th_low) begin
                adverse_risk         <= 1'b0;
                ml_adverse_pulse     <= 1'b0;
                ml_benign_pulse      <= 1'b1;
                ml_safe_forced_pulse <= 1'b0;
            end else begin
                // hysteresis hold: adverse_risk keeps its current value; the
                // pulse still fires on exactly one of the two buckets so
                // cnt_ml_events = cnt_ml_adverse + cnt_ml_benign holds.
                adverse_risk         <= adverse_risk;
                ml_adverse_pulse     <= adverse_risk;
                ml_benign_pulse      <= ~adverse_risk;
                ml_safe_forced_pulse <= 1'b0;
            end
        end else begin
            ml_event_valid      <= 1'b0;
            ml_adverse_pulse    <= 1'b0;
            ml_benign_pulse     <= 1'b0;
            ml_safe_forced_pulse <= 1'b0;
            // adverse_risk/score_raw/risk_level hold their last value
        end
    end

endmodule
