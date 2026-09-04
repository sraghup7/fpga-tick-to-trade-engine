`timescale 1ns / 1ps

// rtl/feature_extractor.v
//
// F0-F7 feature computation (master spec S3.1 [G2], S5.3/S5.5,
// FR-20/21/24/25). After each book-modifying update it computes eight raw
// 32-bit fixed-point features feeding the ML classifier via a later
// normalizer. BIT-EXACT reference: sim/feature_golden.py (FeatureTracker) --
// this file is a restatement of that executable definition; on any
// disagreement the Python file wins (same precedent as golden_model.py).
// D13 (docs/design_decisions.md) pins the one thing the spec leaves open:
// the shared F5/F7 window.
//
// Window semantics (D13): one W-deep sliding window PER SLOT backs both F5
// and F7. Every entry is (is_update:1b, abs_mid_delta:32b). The window
// advances on EVERY msg_applied cycle for that slot, of ANY msg_type:
// book-modifying events (QUOTE/CLEAR) push (1, |F1|); TRADE/HEARTBEAT push
// (0,0). F5 = popcount of is_update over the W entries; F7 = sum of the
// abs deltas, saturated only at the final 32-bit unsigned output. Both are
// RECOMPUTED from the whole window every event -- never maintained as an
// incremental add-newest/subtract-oldest sum, which would corrupt the
// result the instant a saturated value fell off the end (D13's pitfall).
// The current event's own entry is included in its own F5/F7 ("the last W
// events, as of and including now"). A CLEAR resets that slot's history to
// the all-zero state and is then itself treated as a fresh first event
// (F1=F3=F4=0 for it, F6 back to 0, window restarts with its own (1,0)
// entry); prev_* are then updated to the post-clear book state exactly as
// feature_golden's unconditional tail writes them, so the NEXT event is not
// a first event.
//
// Per-slot history (FR-21): prev_bid_price/qty, prev_ask_price/qty, a
// seen_first bit, a last_trade_dir register (F6; only -1/0/+1 written, 32-bit
// two's-complement for uniformity), and the window. All cleared by rst_n.
// Stored as packed vectors, slot s at bits [s*W +: W] (W per-field), so a
// runtime slot index is a plain variable part-select -- no unpacked arrays.
//
// Feature math (S2.2 of the contract; feature_golden bit-exact):
//   F0 = sat_unsigned(ask - bid)          F1 = sat_signed(mid - prev_mid), 0 first
//   F2 = sat_signed(bid_qty - ask_qty)    F3 = sat_signed(bid_qty - prev_bid_qty), 0 first
//   F4 = sat_signed(ask_qty - prev_ask_qty), 0 first   F5 = window popcount
//   F6 = last_trade_dir (0/±1)            F7 = sat_unsigned(sum of window abs)
// where mid = (bid_price + ask_price) >> 1 computed on the FULL 33-bit sum.
// Signed outputs (F1..F4, F6) are two's-complement; F0/F5/F7 unsigned.
//
// Timing (S2.5): book state inputs are the POST-update state of the applied
// slot. On the cycle book_upd_valid is high the module computes F0-F7
// combinationally from pre-this-event history + this event's inputs, and on
// that cycle's clock edge registers the vector (feat_valid pulses exactly
// one cycle later, one cycle after book_upd_valid) AND updates the history
// registers / window. TRADE/HEARTBEAT cycles (msg_applied & !book_upd_valid)
// produce no feature output; they only advance the window and, for TRADE,
// update F6.
//
// Post-update inputs are the tob_engine.v next_* scalar ports (D23, commit
// 3f30320; fix contract docs/contracts/feature_extractor_patch.md), NOT the
// registered bid_price/ask_price/etc buses: a register written with <= on a
// clock edge is not visible to another module reading it on that same edge,
// so the registered buses only reflect the book as it stood BEFORE the
// triggering message's own effect. next_* are the applied slot's
// combinational post-update state, valid whenever msg_applied is high -- for
// TRADE/HEARTBEAT (no book change) they equal current state, a no-op. These
// four ports are the D23-twin of signal_engine.v's fix; applied_slot is
// still needed to index the per-slot prev_*/window/last_trade_dir history.
// Risk-appropriate valid/crossed fail-safe forcing stays downstream in
// ml_policy.v (FR-26/31), which reads tob_engine.v's REGISTERED
// bid_valid/ask_valid/crossed buses at a pipeline cycle far enough past the
// triggering event's register commit that no staleness applies (same D23
// reasoning as risk_engine.v).
//
// bid_valid/ask_valid are deliberately not consumed anywhere (S2.7): raw
// features are computed mechanically from whatever price/qty tob_engine
// presents. F0 saturates to 0 when ask < bid -- not a sentinel. FR-26
// safe-state forcing belongs to a later ML-path stage.
//
// Verilog-2001 only.

module feature_extractor #(
    parameter integer NUM_SYMBOLS = 4,
    parameter integer WINDOW      = 16   // elaboration-time (D13); one of
                                          // 4, 8, 16, 32
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from md_parser.v -- only meaningful on a msg_applied cycle
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_side,

    // from tob_engine.v -- see contract S1 for why both are needed
    input  wire                       msg_applied,     // any accepted msg
    input  wire                       book_upd_valid,  // QUOTE|CLEAR subset
    input  wire [1:0]                 applied_slot,
    // post-update ("next") state of the APPLIED slot (tob_engine.v's next_*
    // outputs, D23) -- consumed combinationally on the book_upd_valid cycle.
    input  wire [31:0] next_bid_price,   // the four this module reads (S2.7:
    input  wire [31:0] next_bid_qty,     // next_bid_valid/next_ask_valid/
    input  wire [31:0] next_ask_price,   // next_crossed are deliberately NOT
    input  wire [31:0] next_ask_qty,     // consumed -- see FR-26 note above)

    // one feature vector per book-modifying event, registered one cycle
    // after book_upd_valid (S2.5). F1..F4/F6 signed two's-complement,
    // F0/F5/F7 unsigned.
    output reg          feat_valid,
    output reg  [1:0]   feat_slot,
    output reg  [31:0]  feat_f0_spread,
    output reg  [31:0]  feat_f1_mid_delta,
    output reg  [31:0]  feat_f2_imbalance,
    output reg  [31:0]  feat_f3_bid_chg,
    output reg  [31:0]  feat_f4_ask_chg,
    output reg  [31:0]  feat_f5_update_rate,
    output reg  [31:0]  feat_f6_last_trade_dir,
    output reg  [31:0]  feat_f7_volatility
);

    localparam [7:0] MSG_QUOTE = 8'h01;
    localparam [7:0] MSG_TRADE = 8'h02;
    localparam [7:0] MSG_CLEAR = 8'h03;
    localparam [7:0] MSG_HEARTBEAT = 8'hFF;

    // ---- per-slot state (FR-21), packed; slot s at [s*W +: W] ----
    reg [NUM_SYMBOLS*32-1:0]    prev_bp;    // prev bid price  (32/slot)
    reg [NUM_SYMBOLS*32-1:0]    prev_bq;    // prev bid qty
    reg [NUM_SYMBOLS*32-1:0]    prev_ap;    // prev ask price
    reg [NUM_SYMBOLS*32-1:0]    prev_aq;    // prev ask qty
    reg [NUM_SYMBOLS*32-1:0]    last_trade_dir;   // F6, 32/slot (only -1/0/+1)
    reg [NUM_SYMBOLS-1:0]       seen_first;
    reg [NUM_SYMBOLS*WINDOW-1:0]      win_upd;   // per slot: W x is_update,
                                                 //   bit s*W+j = entry j (j=0 newest)
    reg [NUM_SYMBOLS*WINDOW*32-1:0]   win_abs;   // per slot: W x 32-bit abs delta,
                                                 //   entry j of slot s at
                                                 //   [s*WINDOW*32 + j*32 +: 32]

    integer j;

    // Saturating 32-bit signed difference of two unsigned 32-bit operands
    // (a - b), clamped to [-2^31, 2^31-1]. A plain 33-bit difference is
    // enough: both operands are < 2^32.
    function [31:0] sat_sub;
        input [31:0] a;
        input [31:0] b;
        reg signed [32:0] d;
        begin
            d = $signed({1'b0, a}) - $signed({1'b0, b});
            if (d > 33'sd2147483647) begin        // > 2^31-1
                sat_sub = 32'h7FFFFFFF;
            end else if (d < -33'sd2147483648) begin  // < -2^31
                sat_sub = 32'h80000000;
            end else begin
                sat_sub = d[31:0];
            end
        end
    endfunction

    // ---- event classification (inputs are only meaningful on msg_applied) ----
    wire book = msg_applied & book_upd_valid;         // QUOTE or CLEAR
    wire clev = book & (msg_type == MSG_CLEAR);
    wire [1:0] sidx = applied_slot;

    // ---- combinational F0-F7 for the active slot (registered when book) ----
    reg [31:0] sbp, sbq, sap, saq;        // this event's post-update book
    reg        first_ev;
    reg [32:0] midsum, pmsum;
    reg [31:0] c_f0, c_f1, c_f2, c_f3, c_f4, c_f5, c_f6, c_f7, c_absf1;
    reg [63:0] f7acc;
    reg [5:0]  f5cnt;
    reg        e_upd;
    reg [31:0] e_abs;
    always @(*) begin
        sbp = next_bid_price;
        sbq = next_bid_qty;
        sap = next_ask_price;
        saq = next_ask_qty;

        // first-event rule: a CLEAR resets the slot first (so it is always a
        // first event); otherwise first until the slot's first book event.
        first_ev = clev | ~seen_first[sidx];

        midsum    = {1'b0, sbp} + {1'b0, sap};
        pmsum     = {1'b0, prev_bp[sidx*32 +: 32]} + {1'b0, prev_ap[sidx*32 +: 32]};

        c_f0 = (sap >= sbp) ? (sap - sbp) : 32'd0;                 // sat unsigned
        c_f1 = first_ev ? 32'd0 : sat_sub(midsum[32:1], pmsum[32:1]);
        c_f2 = sat_sub(sbq, saq);
        c_f3 = first_ev ? 32'd0 : sat_sub(sbq, prev_bq[sidx*32 +: 32]);
        c_f4 = first_ev ? 32'd0 : sat_sub(saq, prev_aq[sidx*32 +: 32]);
        c_absf1 = c_f1[31] ? (32'd0 - c_f1) : c_f1;                // |F1|, <= 2^31
        c_f6 = clev ? 32'd0 : last_trade_dir[sidx*32 +: 32];

        // F5/F7 over the effective POST-push window for this cycle's entry:
        // entry 0 is this event's own push, entries j>=1 are the stored
        // window shifted up by one (oldest dropped). On a CLEAR the stored
        // window was reset, so only this event's own (1, 0) entry remains.
        f7acc = 64'd0;
        f5cnt = 6'd0;
        for (j = 0; j < WINDOW; j = j + 1) begin : f_window
            if (j == 0) begin
                e_upd = book;                       // is_update: only QUOTE/CLEAR
                e_abs = book ? c_absf1 : 32'd0;
            end else if (clev) begin
                e_upd = 1'b0;
                e_abs = 32'd0;
            end else begin
                e_upd = win_upd[sidx*WINDOW + (j-1)];
                e_abs = win_abs[sidx*WINDOW*32 + (j-1)*32 +: 32];
            end
            f5cnt = f5cnt + e_upd;
            f7acc = f7acc + {32'd0, e_abs};
        end
        c_f5 = f5cnt;
        // F7 saturates ONLY at the final output, never on a partial sum.
        c_f7 = (f7acc[63:32] != 32'd0) ? 32'hFFFFFFFF : f7acc[31:0];
    end

    // temp slices for the active slot's window shift (read once per edge)
    reg [WINDOW-1:0]      wu_sl;
    reg [WINDOW*32-1:0]   wa_sl;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feat_valid <= 1'b0;
            feat_slot  <= 2'd0;
            feat_f0_spread       <= 32'd0;
            feat_f1_mid_delta    <= 32'd0;
            feat_f2_imbalance    <= 32'd0;
            feat_f3_bid_chg      <= 32'd0;
            feat_f4_ask_chg      <= 32'd0;
            feat_f5_update_rate  <= 32'd0;
            feat_f6_last_trade_dir <= 32'd0;
            feat_f7_volatility   <= 32'd0;
            prev_bp       <= {NUM_SYMBOLS*32{1'b0}};
            prev_bq       <= {NUM_SYMBOLS*32{1'b0}};
            prev_ap       <= {NUM_SYMBOLS*32{1'b0}};
            prev_aq       <= {NUM_SYMBOLS*32{1'b0}};
            last_trade_dir <= {NUM_SYMBOLS*32{1'b0}};
            seen_first    <= {NUM_SYMBOLS{1'b0}};
            win_upd       <= {NUM_SYMBOLS*WINDOW{1'b0}};
            win_abs       <= {NUM_SYMBOLS*WINDOW*32{1'b0}};
        end else begin
            // feature-vector output, registered one cycle after book_upd_valid
            if (book) begin
                feat_valid <= 1'b1;
                feat_slot  <= sidx;
                feat_f0_spread        <= c_f0;
                feat_f1_mid_delta     <= c_f1;
                feat_f2_imbalance     <= c_f2;
                feat_f3_bid_chg       <= c_f3;
                feat_f4_ask_chg       <= c_f4;
                feat_f5_update_rate   <= c_f5;
                feat_f6_last_trade_dir <= c_f6;
                feat_f7_volatility    <= c_f7;
            end else begin
                feat_valid <= 1'b0;
            end

            if (msg_applied) begin
                if (book) begin
                    // prev_* track this event's post-update book state for
                    // EVERY book event incl. CLEAR (feature_golden's
                    // unconditional tail write) -- so the event AFTER a
                    // clear computes deltas against the stale book, not 0.
                    prev_bp[sidx*32 +: 32] <= sbp;
                    prev_bq[sidx*32 +: 32] <= sbq;
                    prev_ap[sidx*32 +: 32] <= sap;
                    prev_aq[sidx*32 +: 32] <= saq;
                    seen_first[sidx] <= 1'b1;
                    if (clev) begin
                        // reset history to all-zero (D13), then this CLEAR is
                        // itself the first post-reset event: window restarts
                        // with only its own (1, abs_f1=0) entry.
                        win_upd[sidx*WINDOW +: WINDOW] <= {{(WINDOW-1){1'b0}}, 1'b1};
                        win_abs[sidx*WINDOW*32 +: WINDOW*32] <= {{(WINDOW-1)*32{1'b0}}, 32'd0};
                        last_trade_dir[sidx*32 +: 32] <= 32'd0;
                    end else begin
                        wu_sl = win_upd[sidx*WINDOW +: WINDOW];
                        wa_sl = win_abs[sidx*WINDOW*32 +: WINDOW*32];
                        win_upd[sidx*WINDOW +: WINDOW] <= {wu_sl[WINDOW-2:0], 1'b1};
                        win_abs[sidx*WINDOW*32 +: WINDOW*32] <= {wa_sl[(WINDOW-1)*32-1:0], c_absf1};
                    end
                end else begin
                    // TRADE / HEARTBEAT: push (0, 0) into the window; a TRADE
                    // also updates F6 (FR-25). No feature output.
                    wu_sl = win_upd[sidx*WINDOW +: WINDOW];
                    wa_sl = win_abs[sidx*WINDOW*32 +: WINDOW*32];
                    win_upd[sidx*WINDOW +: WINDOW] <= {wu_sl[WINDOW-2:0], 1'b0};
                    win_abs[sidx*WINDOW*32 +: WINDOW*32] <= {wa_sl[(WINDOW-1)*32-1:0], 32'd0};
                    if (msg_type == MSG_TRADE) begin
                        last_trade_dir[sidx*32 +: 32] <= (msg_side == 8'h00) ? 32'd1
                                                                             : 32'hFFFFFFFF;
                    end
                end
            end
        end
    end

endmodule
