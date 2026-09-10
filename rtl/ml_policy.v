`timescale 1ns / 1ps

// rtl/ml_policy.v
//
// ML policy stage (master spec S3.1 [Q], S5.4/S5.5, FR-28/29/31/33; contract
// docs/contracts/ml_integration.md S4; per-symbol adverse_risk decision
// docs/design_decisions.md D47 + docs/contracts/ml_policy_per_symbol.md).
// Turns ml_classifier_wrap.v's raw score z into the per-symbol adverse_risk
// verdict vector that risk_engine.v's gate 0x09 consumes, via a hysteresis
// threshold (FR-28/29), plus partial fail-safe forcing (FR-26/31) and the
// FR-33 telemetry pulses feeding csr_block.v's counters.
//
// Per-symbol (D47, FR-28, §0 decision 2026-09-08): adverse_risk is a
// NUM_SYMBOLS-wide vector indexed by ml_slot -- one hysteresis bit per
// watched instrument, NOT a single register shared across every feed. Each
// event updates only its own slot's bit; every other slot's bit holds. (This
// was a single shared scalar: an adverse verdict computed for one symbol's
// event was read by the next event on ANY symbol, so an unrelated symbol's
// order could be gated by this one's state -- silent cross-contamination
// between feeds that are supposed to be independent. risk_engine.v's gate
// 0x09 reads adverse_risk[sig_slot], this module's ml_slot-indexed bit.)
//
// Hysteresis (FR-28/29), per slot s: adverse_risk[s] sets when z >=
// cfg_ml_th_high, clears when z <= cfg_ml_th_low, and HOLDS its current
// value in the band cfg_ml_th_low < z < cfg_ml_th_high (no chatter around
// the threshold). The hold-band pulse (below) follows the EVENT'S OWN slot's
// held bit -- a hold-band event on a slot that has never been adverse stays
// benign and pulses ml_benign_pulse, regardless of what other slots hold.
//
// Fail-safe forcing (FR-26/31, contract S1.4): when the addressed slot's book
// is invalid on either side, crossed, or the feed has a sticky sequence gap,
// adverse_risk[ml_slot] is forced to 1 regardless of z. Staleness forcing is
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
// adverse_risk[ml_slot] of the event's OWN slot (its pre-update bit) -- so
// S10's invariant cnt_ml_events = cnt_ml_adverse + cnt_ml_benign holds on
// every event. safe_state_c forces both
// ml_safe_forced_pulse and ml_adverse_pulse, satisfying cnt_ml_safe_forced
// <= cnt_ml_adverse by construction.
//
// D28-class fail-safe snapshot (docs/design_decisions.md D28; contract
// docs/contracts/ml_policy_align_fix.md): bid_valid/ask_valid/crossed are
// tob_engine.v's REGISTERED buses. An earlier version of this header claimed
// they could be read live at ml_slot "safe per D23 (same reasoning as
// risk_engine.v)" -- that reasoning was already stale when written: the ML
// branch has no alignment stage between the triggering event and ml_valid, so
// ml_valid fires 5 cycles after the triggering message's own book_upd_valid
// (feature_extractor 3 + feature_normalizer 1 + ml_classifier_wrap 1), by
// which time one or more intervening messages on the same slot may have
// already changed that slot's validity/crossed state (D28 flagged this as
// ml_policy.v's identical bug class, deliberately deferred to this contract).
// The fix (this file): the triggering message's per-slot state is SNAPSHOTed
// one cycle after ITS OWN book_upd_valid (raw_d1_* + u_fs_align, below -- the
// same T+1 capture cycle D23 guarantees the registered buses are correct for
// this specific message, the same reasoning D28's risk_engine.v fix uses) and
// carried forward SNAPSHOT_DEPTH cycles so it arrives already time-correct on
// the cycle ml_valid actually fires. seq_gap is deliberately NOT snapshotted
// -- it is seq_monitor.v's feed-wide sticky level, meant to reflect current
// feed health at the decision's own cycle, not any specific message's state.
//
// SNAPSHOT_DEPTH (5 today) is the cycles from a message's book_upd_valid to
// its ml_valid minus the one cycle already spent capturing the snapshot at
// T+1 -- i.e. feature_extractor's 3 + feature_normalizer's 1 +
// ml_classifier_wrap's 2 (D53 -- ml_classifier_wrap became 2 cycles when it
// was pipelined to close a timing violation). rtl/tob_top.v now wires this
// parameter explicitly from its own ALIGN_DEPTH (D53) rather than relying on
// a coincidentally-matching default, because the two ARE required to agree:
// ALIGN_DEPTH = (this branch's total latency) - signal_engine.v's own
// latency, and SNAPSHOT_DEPTH as derived above are algebraically identical
// as long as signal_engine.v's latency (2 cycles) and this module's own
// capture-to-decision offset (1 cycle) both hold -- if either changes, the
// two would need to be re-derived together, not just kept equal by
// coincidence. tb_ml_chain.v's and tb_tob_top.v's `fs_snap_out_valid !==
// ml_valid` assertions are the guard that would catch a violation of that
// condition. The tb still instantiates this module directly with a
// non-default depth in some cases (SNAPSHOT_DEPTH is a genuine parameter of
// this module, not hardwired to tob_top.v's value) -- that is a testbench
// convenience, not evidence the two are decoupled in the actual design.
//
// Verilog-2001 only.

module ml_policy #(
    parameter integer NUM_SYMBOLS = 4,   // matches every other S3/S5/S6 module
    // Cycles from this message's own book_upd_valid to when ml_valid fires
    // for it, MINUS the one cycle already spent capturing the snapshot at
    // T+1 -- see docs/contracts/ml_policy_align_fix.md S1 for the full
    // derivation (currently 5: feature_extractor's 3 + feature_normalizer's
    // 1 + ml_classifier_wrap's 2, minus the T+1 capture offset; D53 --
    // ml_classifier_wrap became 2 cycles when pipelined to close a timing
    // violation).
    // rtl/tob_top.v now wires this parameter explicitly from its own
    // ALIGN_DEPTH (D53) -- the two must agree as long as signal_engine.v's
    // latency and this module's own capture-to-decision offset both hold;
    // see the module-level comment above for the full derivation and the
    // guard (tb_ml_chain.v/tb_tob_top.v's drift assertions).
    parameter integer SNAPSHOT_DEPTH = 4
) (
    input  wire        clk,
    input  wire        rst_n,

    // NEW (D28-class fix): the triggering message's own book_upd_valid/
    // applied_slot, from tob_engine.v -- already top-level wires in
    // tob_top.v (u_feat already consumes both). Used ONLY to time the
    // internal snapshot below; never used to gate adverse_risk directly.
    input  wire        book_upd_valid,
    input  wire [1:0]  applied_slot,

    // from ml_classifier_wrap.v
    input  wire         ml_valid,
    input  wire [1:0]   ml_slot,
    input  wire signed [31:0] z,

    // fail-safe inputs -- tob_engine.v's REGISTERED buses. bid_valid/
    // ask_valid/crossed are now consumed via the internal snapshot below,
    // NOT read live at ml_slot -- see the header. seq_gap stays live
    // (feed-wide sticky state, not per-message data).
    input  wire [NUM_SYMBOLS-1:0] bid_valid,
    input  wire [NUM_SYMBOLS-1:0] ask_valid,
    input  wire [NUM_SYMBOLS-1:0] crossed,
    input  wire                    seq_gap,

    // config (S9 CSR map), direct ports from csr_block.v
    input  wire signed [31:0] cfg_ml_th_high,   // 0x48
    input  wire signed [31:0] cfg_ml_th_low,    // 0x4C
    input  wire [31:0] cfg_ml_score_offset,     // 0x54
    input  wire [31:0] cfg_ml_score_shift,      // 0x58

    // to risk_engine.v -- persisting per-symbol hysteresis level, valid every
    // cycle. D47: one bit per watched symbol, indexed by ml_slot on update;
    // risk_engine.v's gate 0x09 reads adverse_risk[sig_slot].
    output reg [NUM_SYMBOLS-1:0] adverse_risk,

    // telemetry (FR-33) -- no consumer wired yet (S1.4), reserved
    output reg  signed [31:0] score_raw,
    output reg  [7:0]         risk_level,

    // to csr_block.v -- one-cycle pulses per ML event
    output reg          ml_event_valid,
    output reg          ml_adverse_pulse,
    output reg          ml_benign_pulse,
    output reg          ml_safe_forced_pulse
);

    // ---- D28-class fix: snapshot this message's per-slot fail-safe inputs
    //      one cycle after ITS OWN book_upd_valid (T+1, exactly when D23
    //      guarantees tob_engine.v's registered bid_valid/ask_valid/crossed
    //      are correct for this specific message), then carry the snapshot
    //      forward so it arrives already time-correct on the cycle ml_valid
    //      actually fires for this same message
    //      (docs/contracts/ml_policy_align_fix.md S1). seq_gap is
    //      deliberately excluded -- feed-wide sticky state, not per-message
    //      data, correctly read live below. ----
    reg        raw_d1_valid;
    reg [1:0]  raw_d1_slot;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_d1_valid <= 1'b0;
            raw_d1_slot  <= 2'd0;
        end else begin
            raw_d1_valid <= book_upd_valid;
            raw_d1_slot  <= applied_slot;
        end
    end

    wire [2:0] fs_snap_in = {bid_valid[raw_d1_slot], ask_valid[raw_d1_slot],
                              crossed[raw_d1_slot]};
    wire [2:0] fs_snap_out;
    wire       fs_snap_out_valid;   // must coincide with ml_valid every cycle --
                                     // tb/tb_ml_policy.v asserts this directly

    delay_line #(
        .WIDTH (3),
        .DEPTH (SNAPSHOT_DEPTH)
    ) u_fs_align (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (raw_d1_valid),
        .in_data   (fs_snap_in),
        .out_valid (fs_snap_out_valid),
        .out_data  (fs_snap_out)
    );

    wire a_bid_valid = fs_snap_out[2];
    wire a_ask_valid = fs_snap_out[1];
    wire a_crossed   = fs_snap_out[0];

    // fail-safe state from the ALIGNED snapshot (this message's own book
    // state), not the live per-slot buses at ml_slot (D28-class bug this
    // file used to have); seq_gap stays live.
    wire safe_state_c = ~a_bid_valid | ~a_ask_valid | a_crossed | seq_gap;

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
            adverse_risk        <= {NUM_SYMBOLS{1'b0}};
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
            // D47 (ml_policy_per_symbol.md S1): only the addressed slot's bit
            // changes; every other slot's bit holds. score_raw/risk_level/
            // pulses stay scalar (last ML event across any symbol).
            if (safe_state_c) begin
                adverse_risk[ml_slot] <= 1'b1;
                ml_safe_forced_pulse <= 1'b1;
                ml_adverse_pulse     <= 1'b1;
                ml_benign_pulse      <= 1'b0;
            end else if (z >= cfg_ml_th_high) begin
                adverse_risk[ml_slot] <= 1'b1;
                ml_adverse_pulse     <= 1'b1;
                ml_benign_pulse      <= 1'b0;
                ml_safe_forced_pulse <= 1'b0;
            end else if (z <= cfg_ml_th_low) begin
                adverse_risk[ml_slot] <= 1'b0;
                ml_adverse_pulse     <= 1'b0;
                ml_benign_pulse      <= 1'b1;
                ml_safe_forced_pulse <= 1'b0;
            end else begin
                // hysteresis hold: THIS slot's own bit keeps its current
                // value (NOT some other slot's -- the crux of the D47 fix);
                // the pulse still fires on exactly one of the two buckets,
                // following the event's own slot's pre-update bit, so
                // cnt_ml_events = cnt_ml_adverse + cnt_ml_benign holds.
                adverse_risk[ml_slot] <= adverse_risk[ml_slot];
                ml_adverse_pulse     <= adverse_risk[ml_slot];
                ml_benign_pulse      <= ~adverse_risk[ml_slot];
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
