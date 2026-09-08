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
// abs deltas, saturated only at the final 32-bit unsigned output. The
// current event's own entry is included in its own F5/F7 ("the last W
// events, as of and including now"). A CLEAR resets that slot's history to
// the all-zero state and is then itself treated as a fresh first event
// (F1=F3=F4=0 for it, F6 back to 0, window restarts with its own (1,0)
// entry); prev_* are then updated to the post-clear book state exactly as
// feature_golden's unconditional tail writes them, so the NEXT event is not
// a first event.
//
// Timing (D26/D27 timing-closure patch, v2 -- supersedes the original
// single-cycle design and a failed v1 half-window-split attempt, see
// docs/design_decisions.md D26/D27 and docs/contracts/
// feature_extractor_timing_patch.md for the full trace): F0-F7 are computed
// across a THREE-stage pipeline instead of one cycle, because the real
// timing bottleneck was never F5/F7's window width -- it was computing this
// event's own F1 (mid-price delta, two chained 33-bit adds + a saturating
// subtract + abs) and combining it into the window accumulator in the same
// clock edge.
//
//   stage 0 (book_upd_valid's own cycle): the two wide 33-bit sums
//     (midsum/pmsum) plus every OTHER feature except F1 (F0/F2/F3/F4/F6,
//     each a single subtract or cheaper -- never the bottleneck).
//   stage 1: F1 = sat_sub of the two now-REGISTERED sums, then |F1| --
//     a single saturating subtract operating on already-registered
//     operands, not the double-add-then-subtract chain stage 0 used to run
//     in one cycle.
//   stage 2: F5/F7 combine THIS event's now-fully-computed contribution
//     with an INCREMENTAL running accumulator per slot (add the newest
//     entry, subtract the one falling out of the window) instead of
//     recomputing the whole window's sum from scratch every event. This
//     replaces an up-to-32-term adder tree with a single add/subtract.
//
// feat_valid therefore pulses THREE cycles after book_upd_valid (was one
// cycle pre-D26, two cycles in the failed v1 half-window-split attempt).
// The window arrays (win_upd/win_abs) still hold every slot's last W
// entries and are still needed, now only to know which entry is falling
// out of the window each cycle -- they are read, not recomputed over.
//
// D13-safety rule for the incremental accumulator (do not violate this):
// F5/F7's accumulator (f7_acc/f5_cnt below) and the window arrays always
// hold the TRUE, UNSATURATED per-event magnitude. Saturation happens
// EXACTLY ONCE, when producing the 32-bit feat_f7_volatility output
// register -- that saturated value is NEVER written back into f7_acc or
// win_abs. D13 originally rejected an incremental accumulator specifically
// because a naive version would clamp a stored per-entry value and then be
// unable to correctly subtract it back out once saturated; this design
// avoids that failure mode by never storing or subtracting anything but the
// raw magnitude, with saturation confined to the single final output step.
//
// Per-slot history (FR-21): prev_bid_price/qty, prev_ask_price/qty, a
// seen_first bit, a last_trade_dir register (F6; only -1/0/+1 written, 32-bit
// two's-complement for uniformity), and the window. All cleared by rst_n.
// Stored as packed vectors, slot s at bits [s*W +: W] (W per-field), so a
// runtime slot index is a plain variable part-select -- no unpacked arrays.
// f7_acc/f5_cnt (new, D26/D27) are per-slot unpacked arrays instead, same
// style already used elsewhere in this codebase (e.g. latency_histogram.v).
//
// Feature math (S2.2 of the contract; feature_golden bit-exact):
//   F0 = sat_unsigned(ask - bid)          F1 = sat_signed(mid - prev_mid), 0 first
//   F2 = sat_signed(bid_qty - ask_qty)    F3 = sat_signed(bid_qty - prev_bid_qty), 0 first
//   F4 = sat_signed(ask_qty - prev_ask_qty), 0 first   F5 = window popcount
//   F6 = last_trade_dir (0/±1)            F7 = sat_unsigned(sum of window abs)
// where mid = (bid_price + ask_price) >> 1 computed on the FULL 33-bit sum.
// Signed outputs (F1..F4, F6) are two's-complement; F0/F5/F7 unsigned.
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
// prev_bp/prev_bq/prev_ap/prev_aq/seen_first/last_trade_dir update
// IMMEDIATELY, one cycle after msg_applied/book -- deliberately NOT moved
// into the new multi-stage pipeline above, since they only ever depend on
// sbp/sbq/sap/saq (a direct, same-cycle copy of the next_* ports -- cheap,
// no chain) and back-to-back events on the same slot must see correctly
// updated history one cycle later, independent of how deep the F0-F7
// output pipeline is.
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

    // one feature vector per book-modifying event, registered THREE cycles
    // after book_upd_valid (D26/D27 v2 timing patch, S2.5). F1..F4/F6
    // signed two's-complement, F0/F5/F7 unsigned.
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

    // ---- D26/D27 v2: incremental F5/F7 accumulator state, per slot.
    //      40 bits: |F1| <= 2^31 and WINDOW <= 32 (D13's legal set is
    //      4/8/16/32), so the window sum can never exceed 32*2^31 = 2^36 --
    //      37 bits is exact for the worst case across every legal WINDOW
    //      value; 40 leaves margin without paying anywhere near a 64-bit
    //      adder's carry-chain depth. Sized for the parameter's full legal
    //      range, not today's WINDOW=16 instantiation (see contract S2.4). ----
    reg [39:0] f7_acc [0:NUM_SYMBOLS-1];   // unsaturated running sum, per slot
    reg [5:0]  f5_cnt [0:NUM_SYMBOLS-1];   // running popcount, per slot (0..WINDOW)

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

    // =====================================================================
    // Stage 0 (combinational, book_upd_valid's own cycle): the two wide
    // 33-bit sums, plus every feature except F1 (each a single subtract or
    // cheaper -- never the timing bottleneck; see file header).
    // =====================================================================
    reg [31:0] sbp, sbq, sap, saq;        // this event's post-update book
    reg        first_ev;
    reg [32:0] midsum, pmsum;
    reg [31:0] c_f0, c_f2, c_f4, c_f6;
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
        c_f2 = sat_sub(sbq, saq);
        // D40: F3's sat_sub moved to stage 1 (see below) -- computing it here
        // chains tob_engine.v's own next_bid_qty derivation directly into a
        // 33-bit saturating subtract in the SAME cycle, which was fine until
        // D39's pin-placement fix shifted routing enough to violate by a
        // hair. c_f4 (ask side) is the structurally identical computation and
        // is NOT moved -- it measured +0.478 ns of margin in the same run,
        // comfortably positive; only fix what's actually violating.
        c_f4 = first_ev ? 32'd0 : sat_sub(saq, prev_aq[sidx*32 +: 32]);
        c_f6 = clev ? 32'd0 : last_trade_dir[sidx*32 +: 32];
    end

    // ---- stage-1 pipeline registers: hold stage 0's cheap features plus
    //      the two wide sums, one cycle, so stage 1 can compute F1 from
    //      already-registered operands instead of chaining straight off
    //      the two adds. p1_valid tracks EVERY msg_applied (not just book
    //      events) so TRADE/HEARTBEAT still retire into the window at the
    //      same pipeline depth as book events (D13 ordering requirement,
    //      contract S2.4). ----
    reg        p1_valid;      // = msg_applied, carried for window retirement
    reg        p1_book;       // = book, gates the feature output downstream
    reg        p1_clev;
    reg [1:0]  p1_slot;
    reg        p1_first_ev;
    reg [32:0] p1_midsum, p1_pmsum;
    reg [31:0] p1_f0, p1_f2, p1_f4, p1_f6;
    // D40: F3's two operands, registered as-is (no arithmetic on them yet --
    // that's the whole fix, see stage 1 below).
    reg [31:0] p1_sbq, p1_prev_bq;

    // =====================================================================
    // Stage 1 (combinational): F1 from the now-REGISTERED sums, then |F1|.
    // A single saturating subtract + abs on already-registered operands --
    // this is the piece that used to be chained directly off two live 33-bit
    // adds in one cycle; splitting it here is the actual timing fix (see
    // file header -- the window width was never the bottleneck).
    //
    // D40: F3 gets the identical treatment for the identical reason -- sat_sub
    // now runs on p1_sbq/p1_prev_bq (both plain registers, no chain) instead
    // of chaining off tob_engine.v's live next_bid_qty in the same cycle that
    // computation itself completes.
    // =====================================================================
    reg [31:0] c_f1, c_absf1, c_f3;
    always @(*) begin
        c_f1    = p1_first_ev ? 32'd0 : sat_sub(p1_midsum[32:1], p1_pmsum[32:1]);
        c_absf1 = c_f1[31] ? (32'd0 - c_f1) : c_f1;                // |F1|, <= 2^31
        c_f3    = p1_first_ev ? 32'd0 : sat_sub(p1_sbq, p1_prev_bq);
    end

    // ---- stage-2 pipeline registers: this event's fully-computed
    //      contribution, ready to combine into the incremental F5/F7
    //      accumulator. p2_push_abs/p2_push_upd reproduce exactly the
    //      j==0 window entry the pre-D26 design constructed combinationally
    //      in the same cycle as the window read -- now a registered value
    //      derived from the now-registered c_absf1. ----
    reg        p2_valid, p2_book, p2_clev;
    reg [1:0]  p2_slot;
    reg [31:0] p2_f0, p2_f1, p2_f2, p2_f3, p2_f4, p2_f6;
    reg [31:0] p2_push_abs;   // this event's abs delta to push, or 0
    reg        p2_push_upd;   // this event's is_update bit to push

    // =====================================================================
    // Stage 2 (combinational): incremental accumulate. old_abs/old_upd are
    // plain register reads of the window array as it stands BEFORE this
    // cycle's shift -- cheap, no chain. The add/subtract below is the only
    // arithmetic in this stage: a single 40-bit add/subtract pair, far
    // shallower than recomputing an up-to-32-term sum from scratch.
    //
    // D13-safety rule (see file header): f7_acc/win_abs always hold the
    // TRUE, UNSATURATED per-event magnitude; saturation happens ONLY once,
    // producing feat_f7_volatility below, and that saturated value is never
    // written back into f7_acc or win_abs.
    // =====================================================================
    reg [31:0] old_abs;
    reg        old_upd;
    reg [39:0] new_f7acc;
    reg [6:0]  new_f5cnt;   // one extra bit of headroom for the intermediate sum
    always @(*) begin
        old_abs = win_abs[p2_slot*WINDOW*32 + (WINDOW-1)*32 +: 32];
        old_upd = win_upd[p2_slot*WINDOW + (WINDOW-1)];

        if (p2_clev) begin
            // window reset (D13): only this event's own entry survives
            new_f7acc = {8'd0, p2_push_abs};
            new_f5cnt = {6'd0, p2_push_upd};
        end else begin
            new_f7acc = f7_acc[p2_slot] + {8'd0, p2_push_abs} - {8'd0, old_abs};
            new_f5cnt = {1'b0, f5_cnt[p2_slot]} + p2_push_upd - old_upd;
        end
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

            p1_valid    <= 1'b0;
            p1_book     <= 1'b0;
            p1_clev     <= 1'b0;
            p1_slot     <= 2'd0;
            p1_first_ev <= 1'b0;
            p1_midsum   <= 33'd0;
            p1_pmsum    <= 33'd0;
            p1_f0 <= 32'd0; p1_f2 <= 32'd0;
            p1_f4 <= 32'd0; p1_f6 <= 32'd0;
            p1_sbq <= 32'd0; p1_prev_bq <= 32'd0;

            p2_valid <= 1'b0;
            p2_book  <= 1'b0;
            p2_clev  <= 1'b0;
            p2_slot  <= 2'd0;
            p2_f0 <= 32'd0; p2_f1 <= 32'd0; p2_f2 <= 32'd0;
            p2_f3 <= 32'd0; p2_f4 <= 32'd0; p2_f6 <= 32'd0;
            p2_push_abs <= 32'd0;
            p2_push_upd <= 1'b0;

            prev_bp       <= {NUM_SYMBOLS*32{1'b0}};
            prev_bq       <= {NUM_SYMBOLS*32{1'b0}};
            prev_ap       <= {NUM_SYMBOLS*32{1'b0}};
            prev_aq       <= {NUM_SYMBOLS*32{1'b0}};
            last_trade_dir <= {NUM_SYMBOLS*32{1'b0}};
            seen_first    <= {NUM_SYMBOLS{1'b0}};
            win_upd       <= {NUM_SYMBOLS*WINDOW{1'b0}};
            win_abs       <= {NUM_SYMBOLS*WINDOW*32{1'b0}};
            for (j = 0; j < NUM_SYMBOLS; j = j + 1) begin
                f7_acc[j] <= 40'd0;
                f5_cnt[j] <= 6'd0;
            end
        end else begin
            // ---- stage 2 -> output: finalize the retiring event (the one
            //      that was in stage 2 THIS cycle) and update the
            //      accumulator/window for every retiring msg_applied event,
            //      not just book ones (D13 ordering, contract S2.4). ----
            feat_valid <= p2_valid & p2_book;
            feat_slot  <= p2_slot;
            feat_f0_spread         <= p2_f0;
            feat_f1_mid_delta      <= p2_f1;
            feat_f2_imbalance      <= p2_f2;
            feat_f3_bid_chg        <= p2_f3;
            feat_f4_ask_chg        <= p2_f4;
            feat_f6_last_trade_dir <= p2_f6;
            feat_f5_update_rate    <= {26'd0, new_f5cnt[5:0]};
            feat_f7_volatility     <= (new_f7acc[39:32] != 8'd0) ? 32'hFFFFFFFF
                                                                  : new_f7acc[31:0];

            if (p2_valid) begin
                f7_acc[p2_slot] <= new_f7acc;
                f5_cnt[p2_slot] <= new_f5cnt[5:0];
                if (p2_clev) begin
                    win_upd[p2_slot*WINDOW +: WINDOW] <= {{(WINDOW-1){1'b0}}, p2_push_upd};
                    win_abs[p2_slot*WINDOW*32 +: WINDOW*32] <= {{(WINDOW-1)*32{1'b0}}, p2_push_abs};
                end else begin
                    wu_sl = win_upd[p2_slot*WINDOW +: WINDOW];
                    wa_sl = win_abs[p2_slot*WINDOW*32 +: WINDOW*32];
                    win_upd[p2_slot*WINDOW +: WINDOW] <= {wu_sl[WINDOW-2:0], p2_push_upd};
                    win_abs[p2_slot*WINDOW*32 +: WINDOW*32] <= {wa_sl[(WINDOW-1)*32-1:0], p2_push_abs};
                end
            end

            // ---- stage 1 -> stage 2: register this event's fully-computed
            //      contribution ----
            p2_valid <= p1_valid;
            p2_book  <= p1_book;
            p2_clev  <= p1_clev;
            p2_slot  <= p1_slot;
            p2_f0 <= p1_f0;
            p2_f1 <= c_f1;
            p2_f2 <= p1_f2;
            p2_f3 <= c_f3;
            p2_f4 <= p1_f4;
            p2_f6 <= p1_f6;
            p2_push_abs <= p1_book ? c_absf1 : 32'd0;
            p2_push_upd <= p1_book;

            // ---- stage 0 -> stage 1: register this cycle's event ----
            p1_valid    <= msg_applied;
            p1_book     <= book;
            p1_clev     <= clev;
            p1_slot     <= sidx;
            p1_first_ev <= first_ev;
            p1_midsum   <= midsum;
            p1_pmsum    <= pmsum;
            p1_f0 <= c_f0;
            p1_f2 <= c_f2;
            p1_f4 <= c_f4;
            p1_f6 <= c_f6;
            p1_sbq     <= sbq;
            p1_prev_bq <= prev_bq[sidx*32 +: 32];

            // ---- prev_*/seen_first/last_trade_dir: UNCHANGED, immediate,
            //      one cycle after msg_applied/book (see file header for
            //      why these are deliberately NOT part of the pipeline
            //      above). Keyed off stage 0's book/clev/sidx/sbp/sbq/sap/
            //      saq, not p1_*/p2_*. ----
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
                        // reset history to all-zero (D13); the window/
                        // accumulator reset itself happens in the stage-2
                        // block above, two cycles later, keyed on p2_clev.
                        last_trade_dir[sidx*32 +: 32] <= 32'd0;
                    end
                end else begin
                    // TRADE / HEARTBEAT: a TRADE updates F6 (FR-25). The
                    // window push for this event happens in the stage-2
                    // block above, two cycles later, keyed on p2_valid.
                    if (msg_type == MSG_TRADE) begin
                        last_trade_dir[sidx*32 +: 32] <= (msg_side == 8'h00) ? 32'd1
                                                                             : 32'hFFFFFFFF;
                    end
                end
            end
        end
    end

endmodule
