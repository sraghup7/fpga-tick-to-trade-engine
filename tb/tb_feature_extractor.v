`timescale 1ns / 1ps

// Self-checking testbench for rtl/feature_extractor.v (master spec S3.1
// [G2], FR-20/21/24/25; contract docs/contracts/feature_extractor.md S3).
//
// Icarus:
//   iverilog -g2001 -Wall -o feature_extractor_tb.vvp rtl/feature_extractor.v tb/tb_feature_extractor.v
//   vvp feature_extractor_tb.vvp
//
// Built with WINDOW=4 (elaboration parameter) so window rollover is reached
// in a handful of events. All expected tuples are copied verbatim from the
// authoritative reference -- sim/feature_golden.py run over the exact event
// streams this testbench drives (see sim/_tb_ground_truth.py), and for the
// ported case from sim/test_feature_golden_handcase.py itself. The feature
// vector is registered one cycle after book_upd_valid (S2.5), so the
// testbench samples feat_* at the posedge following the event's drive cycle
// (c_* regs capture pre-edge values each posedge, like the other S3 TBs).
//
// Each event is driven for exactly one cycle (inputs deasserted before the
// sampling edge). The four next_* scalar inputs (post-update state of the
// APPLIED slot) are driven directly to the event's post-update values --
// this module reads exactly the inputs it is given and never reconstructs
// tob_engine's update (S2.7), so the TB presents precisely the post-update
// states the reference was handed. Port shape note: feature_extractor.v was
// patched (docs/contracts/feature_extractor_patch.md, the D23-twin fix) to
// consume tob_engine.v's next_* scalar outputs instead of the registered
// per-symbol book buses it read before -- same one-cycle-post-update
// semantics, but now on a combinational (same-cycle-valid) source. The TB's
// per-slot book model (mbp/mbq/map/maq) is kept so each event can present
// the applied slot's post-update state exactly as before; `applied_slot`
// selects which slot's model entry drives the scalars, while prev_*/window/
// last_trade_dir history stays inside the DUT per slot (FR-21).
//
// Blocks (each preceded by a reset so per-block state matches the reference
// run it was generated from):
//   A   the six-step handcase port (s1,s2,s3 TRADE,s4 HEARTBEAT,s5,s6 CLEAR)
//       on slot 1 -- asserts the exact tuples test_feature_golden_handcase.py
//       hand-computes, end-to-end through D13's window semantics
//   B   slot 0 history + trade + CLEAR + post-clear quotes, INTERLEAVED with
//       slot 2's own history -- CLEAR resets only slot 0; slot 2's F5/F7/F6/
//       prev are untouched; also exercises F0 saturation to 0 on a crossed
//       book (slot 2: bid 200 > ask 50) and F6 slot isolation
//   C   slot 3 window rollover: 12+ events, oldest entries age out of the
//       4-deep window (F7 drops from 152-family sums to ~10 once the big
//       early |delta| falls off -- proves aging, not coincidental match)
//   D   build slot 0 history (incl. a crossed quote and a trade), assert
//       rst_n, then a fresh first event must yield F1=F3=F4=0 / F6=0
//   E   new for the next_* port shape: a price/qty-changing QUOTE on an
//       already-established slot on each side (F0/F2 must reflect the
//       presented next_* values, F1/F3/F4 the prior-event prev_* history),
//       and a TRADE + HEARTBEAT cycle proving next_* is not consulted on
//       non-book-modifying events (no feat_valid, window/book gating intact).
//
// On any mismatch: FAIL line naming the step, feature, and expected vs.
// actual; final PASS/FAIL.
//
// Verilog-2001 only.

module tb_feature_extractor;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg [7:0]  msg_type = 8'd0;
    reg [7:0]  msg_side = 8'd0;
    reg        msg_applied = 1'b0;
    reg        book_upd_valid = 1'b0;
    reg [1:0]  applied_slot = 2'd0;

    reg [31:0] d_next_bid_price, d_next_bid_qty, d_next_ask_price, d_next_ask_qty;

    wire       feat_valid;
    wire [1:0] feat_slot;
    wire [31:0] feat_f0_spread, feat_f1_mid_delta, feat_f2_imbalance;
    wire [31:0] feat_f3_bid_chg, feat_f4_ask_chg, feat_f5_update_rate;
    wire [31:0] feat_f6_last_trade_dir, feat_f7_volatility;

    localparam [7:0] QUOTE = 8'h01;
    localparam [7:0] TRADE = 8'h02;
    localparam [7:0] CLEAR = 8'h03;
    localparam [7:0] HEARTBEAT = 8'hFF;
    localparam [7:0] SIDE_BID = 8'h00;
    localparam [7:0] SIDE_ASK = 8'h01;

    feature_extractor #(
        .NUM_SYMBOLS (4),
        .WINDOW      (4)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .msg_type             (msg_type),
        .msg_side             (msg_side),
        .msg_applied          (msg_applied),
        .book_upd_valid       (book_upd_valid),
        .applied_slot         (applied_slot),
        .next_bid_price       (d_next_bid_price),
        .next_bid_qty         (d_next_bid_qty),
        .next_ask_price       (d_next_ask_price),
        .next_ask_qty         (d_next_ask_qty),
        .feat_valid           (feat_valid),
        .feat_slot            (feat_slot),
        .feat_f0_spread       (feat_f0_spread),
        .feat_f1_mid_delta    (feat_f1_mid_delta),
        .feat_f2_imbalance    (feat_f2_imbalance),
        .feat_f3_bid_chg      (feat_f3_bid_chg),
        .feat_f4_ask_chg      (feat_f4_ask_chg),
        .feat_f5_update_rate  (feat_f5_update_rate),
        .feat_f6_last_trade_dir (feat_f6_last_trade_dir),
        .feat_f7_volatility   (feat_f7_volatility)
    );

    reg     fail = 1'b0;
    integer tc = 0;

    // ---- per-slot book model: post-update state of each slot, the applied
    //      slot's entry drives the next_* scalars on its own event cycles ----
    reg [31:0] mbp [0:3];
    reg [31:0] mbq [0:3];
    reg [31:0] map [0:3];
    reg [31:0] maq [0:3];
    integer k;

    task drive_bus;
        begin
            d_next_bid_price = mbp[applied_slot];
            d_next_bid_qty   = mbq[applied_slot];
            d_next_ask_price = map[applied_slot];
            d_next_ask_qty   = maq[applied_slot];
        end
    endtask

    // Capture the registered feature vector at each posedge (pre-edge), so
    // the sample taken after an event's idle edge holds that event's vector.
    reg        c_valid;
    reg [1:0]  c_slot;
    reg [31:0] c_f0, c_f1, c_f2, c_f3, c_f4, c_f5, c_f6, c_f7;
    always @(posedge clk) begin
        c_valid = feat_valid;
        c_slot  = feat_slot;
        c_f0    = feat_f0_spread;
        c_f1    = feat_f1_mid_delta;
        c_f2    = feat_f2_imbalance;
        c_f3    = feat_f3_bid_chg;
        c_f4    = feat_f4_ask_chg;
        c_f5    = feat_f5_update_rate;
        c_f6    = feat_f6_last_trade_dir;
        c_f7    = feat_f7_volatility;
    end

    // Drive one applied event (any msg_type) for exactly one clock cycle,
    // then return after the following idle posedge -- c_* now holds the
    // event's feature vector (feat_valid=1 for QUOTE/CLEAR, 0 otherwise).
    task ev;
        input [7:0]  mt;
        input [7:0]  ms;
        input        buv;
        input [1:0]  slot;
        begin
            @(negedge clk);
            msg_type        = mt;
            msg_side        = ms;
            msg_applied     = 1'b1;
            book_upd_valid  = buv;
            applied_slot    = slot;
            drive_bus;
            @(negedge clk);
            msg_applied     = 1'b0;
            book_upd_valid  = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    // Assert + release reset, clear the book model, align to a clean edge.
    task do_reset;
        begin
            @(negedge clk);
            msg_applied = 1'b0;
            book_upd_valid = 1'b0;
            rst_n = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            for (k = 0; k < 4; k = k + 1) begin
                mbp[k] = 32'd0; mbq[k] = 32'd0;
                map[k] = 32'd0; maq[k] = 32'd0;
            end
            drive_bus;
            @(posedge clk);
            #1;
        end
    endtask

    // Book event with explicit full post-update slot state.
    task q;    // QUOTE
        input [1:0]  slot;
        input [31:0] bp, bq, ap, aq;
        begin
            mbp[slot] = bp; mbq[slot] = bq;
            map[slot] = ap; maq[slot] = aq;
            ev(QUOTE, SIDE_BID, 1'b1, slot);
        end
    endtask
    task cl;   // CLEAR (next_* = post-clear state: stale prices/quantities kept)
        input [1:0]  slot;
        input [31:0] bp, bq, ap, aq;
        begin
            mbp[slot] = bp; mbq[slot] = bq;
            map[slot] = ap; maq[slot] = aq;
            ev(CLEAR, SIDE_BID, 1'b1, slot);
        end
    endtask
    task tr;   // TRADE (no bus change)
        input [1:0] slot;
        input [7:0] side;
        begin
            ev(TRADE, side, 1'b0, slot);
        end
    endtask
    task hb;   // HEARTBEAT (no bus change)
        input [1:0] slot;
        begin
            ev(HEARTBEAT, SIDE_BID, 1'b0, slot);
        end
    endtask

    // Compare the last event's captured vector. Expected feature order:
    // f0 f1 f2 f3 f4 f5 f6 f7 (feature_golden's as_tuple order).
    task check_feat;
        input integer  tag;
        input          e_valid;
        input [1:0]    e_slot;
        input [31:0]   e0, e1, e2, e3, e4, e5, e6, e7;
        begin
            if (c_valid !== e_valid) begin
                $display("FAIL: step %0d: feat_valid=%b, expected %b", tag, c_valid, e_valid);
                fail = 1'b1;
            end
            if (e_valid && (c_slot !== e_slot)) begin
                $display("FAIL: step %0d: feat_slot=%0d, expected %0d", tag, c_slot, e_slot);
                fail = 1'b1;
            end
            // feature data is only meaningful while feat_valid=1; on
            // TRADE/HEARTBEAT cycles it holds the last vector (don't-care).
            if (e_valid) begin
                if (c_f0 !== e0) begin $display("FAIL: step %0d: F0=%0d, expected %0d", tag, c_f0, e0); fail = 1'b1; end
                if (c_f1 !== e1) begin $display("FAIL: step %0d: F1=%0d, expected %0d", tag, $signed(c_f1), e1); fail = 1'b1; end
                if (c_f2 !== e2) begin $display("FAIL: step %0d: F2=%0d, expected %0d", tag, $signed(c_f2), e2); fail = 1'b1; end
                if (c_f3 !== e3) begin $display("FAIL: step %0d: F3=%0d, expected %0d", tag, $signed(c_f3), e3); fail = 1'b1; end
                if (c_f4 !== e4) begin $display("FAIL: step %0d: F4=%0d, expected %0d", tag, $signed(c_f4), e4); fail = 1'b1; end
                if (c_f5 !== e5) begin $display("FAIL: step %0d: F5=%0d, expected %0d", tag, c_f5, e5); fail = 1'b1; end
                if (c_f6 !== e6) begin $display("FAIL: step %0d: F6=%0d, expected %0d", tag, $signed(c_f6), e6); fail = 1'b1; end
                if (c_f7 !== e7) begin $display("FAIL: step %0d: F7=%0d, expected %0d", tag, c_f7, e7); fail = 1'b1; end
            end
        end
    endtask

    initial begin
        do_reset;

        // ================= BLOCK A: the handcase port, slot 1 =================
        // (s1/s2/s5/s6 produce vectors; s3 TRADE and s4 HEARTBEAT advance the
        // window + F6 and produce nothing.)
        q(2'd1, 32'd100, 32'd10, 32'd0,  32'd0);   // s1
        check_feat(1, 1'b1, 2'd1, 32'd0, 32'd0, 32'd10, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        q(2'd1, 32'd100, 32'd10, 32'd110, 32'd5);  // s2
        check_feat(2, 1'b1, 2'd1, 32'd10, 32'd55, 32'd5, 32'd0, 32'd5, 32'd2, 32'd0, 32'd55);
        tr(2'd1, SIDE_ASK);                        // s3: F6 -> -1, no output
        check_feat(3, 1'b0, 2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        hb(2'd1);                                  // s4: no output
        check_feat(4, 1'b0, 2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        q(2'd1, 32'd102, 32'd8, 32'd110, 32'd5);   // s5
        check_feat(5, 1'b1, 2'd1, 32'd8, 32'd1, 32'd3, -32'd2, 32'd0, 32'd2, -32'd1, 32'd56);
        cl(2'd1, 32'd102, 32'd8, 32'd110, 32'd5);  // s6: CLEAR
        check_feat(6, 1'b1, 2'd1, 32'd8, 32'd0, 32'd3, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);

        // ================= BLOCK B: slot0 CLEAR mid-sequence + slot2 =========
        do_reset;
        q(2'd0, 32'd100, 32'd10, 32'd0,   32'd0);   // B1 slot0 first event
        check_feat(11, 1'b1, 2'd0, 32'd0, 32'd0, 32'd10, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        q(2'd2, 32'd0,   32'd0,  32'd50,  32'd5);   // B2 slot2 first event
        check_feat(12, 1'b1, 2'd2, 32'd50, 32'd0, -32'd5, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        q(2'd0, 32'd100, 32'd10, 32'd110, 32'd5);   // B3
        check_feat(13, 1'b1, 2'd0, 32'd10, 32'd55, 32'd5, 32'd0, 32'd5, 32'd2, 32'd0, 32'd55);
        q(2'd2, 32'd200, 32'd10, 32'd50,  32'd5);   // B4: crossed (200 > 50)
        check_feat(14, 1'b1, 2'd2, 32'd0, 32'd100, 32'd5, 32'd10, 32'd0, 32'd2, 32'd0, 32'd100);
        tr(2'd0, SIDE_BID);                        // B5: trade on slot0, no output
        check_feat(15, 1'b0, 2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        q(2'd0, 32'd100, 32'd10, 32'd110, 32'd5);  // B6: F6=+1 (slot0), slot2 untouched
        check_feat(16, 1'b1, 2'd0, 32'd10, 32'd0, 32'd5, 32'd0, 32'd0, 32'd3, 32'd1, 32'd55);
        q(2'd2, 32'd200, 32'd10, 32'd0,   32'd0);  // B7
        check_feat(17, 1'b1, 2'd2, 32'd0, -32'd25, 32'd10, 32'd0, -32'd5, 32'd3, 32'd0, 32'd125);
        cl(2'd0, 32'd100, 32'd10, 32'd110, 32'd5); // B8: CLEAR slot0 only
        check_feat(18, 1'b1, 2'd0, 32'd10, 32'd0, 32'd5, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        q(2'd0, 32'd105, 32'd12, 32'd110, 32'd5);  // B9: post-clear quote (slot0)
        check_feat(19, 1'b1, 2'd0, 32'd5, 32'd2, 32'd7, 32'd2, 32'd0, 32'd2, 32'd0, 32'd2);
        q(2'd2, 32'd55, 32'd4, 32'd60,  32'd3);    // B10: slot2 unaffected by slot0 clear
        check_feat(20, 1'b1, 2'd2, 32'd5, -32'd43, 32'd1, -32'd6, 32'd3, 32'd4, 32'd0, 32'd168);
        q(2'd0, 32'd105, 32'd12, 32'd115, 32'd4);  // B11
        check_feat(21, 1'b1, 2'd0, 32'd10, 32'd3, 32'd8, 32'd0, -32'd1, 32'd3, 32'd0, 32'd5);
        q(2'd2, 32'd55, 32'd4, 32'd62,  32'd2);    // B12: slot2 still continuous
        check_feat(22, 1'b1, 2'd2, 32'd7, 32'd1, 32'd2, 32'd0, -32'd1, 32'd4, 32'd0, 32'd169);

        // ================= BLOCK C: window rollover, slot3 ===================
        do_reset;
        q(2'd3, 32'd300, 32'd5, 32'd0,   32'd0);   // C1
        check_feat(31, 1'b1, 2'd3, 32'd0, 32'd0, 32'd5, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        q(2'd3, 32'd300, 32'd5, 32'd305, 32'd7);   // C2
        check_feat(32, 1'b1, 2'd3, 32'd5, 32'd152, -32'd2, 32'd0, 32'd7, 32'd2, 32'd0, 32'd152);
        hb(2'd3);
        check_feat(33, 1'b0, 2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        q(2'd3, 32'd310, 32'd6, 32'd305, 32'd7);   // C4
        check_feat(34, 1'b1, 2'd3, 32'd0, 32'd5, -32'd1, 32'd1, 32'd0, 32'd3, 32'd0, 32'd157);
        tr(2'd3, SIDE_ASK);
        check_feat(35, 1'b0, 2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        q(2'd3, 32'd310, 32'd6, 32'd315, 32'd8);   // C6: the 152-term fell off
        check_feat(36, 1'b1, 2'd3, 32'd5, 32'd5, -32'd2, 32'd0, 32'd1, 32'd2, -32'd1, 32'd10);
        hb(2'd3);                                  // C7
        hb(2'd3);                                  // C8
        q(2'd3, 32'd320, 32'd7, 32'd315, 32'd8);   // C9
        check_feat(39, 1'b1, 2'd3, 32'd0, 32'd5, -32'd1, 32'd1, 32'd0, 32'd2, -32'd1, 32'd10);
        q(2'd3, 32'd320, 32'd7, 32'd322, 32'd9);   // C10
        check_feat(40, 1'b1, 2'd3, 32'd2, 32'd4, -32'd2, 32'd0, 32'd1, 32'd2, -32'd1, 32'd9);
        hb(2'd3);                                  // C11
        q(2'd3, 32'd325, 32'd8, 32'd322, 32'd9);   // C12: only the newest 4 count
        check_feat(42, 1'b1, 2'd3, 32'd0, 32'd2, -32'd1, 32'd1, 32'd0, 32'd3, -32'd1, 32'd11);

        // ============ BLOCK D: reset mid-history = fresh first event =========
        do_reset;
        q(2'd0, 32'd110, 32'd5, 32'd100, 32'd4);   // D1: crossed ask<bid -> F0 sat 0
        check_feat(51, 1'b1, 2'd0, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        q(2'd0, 32'd110, 32'd5, 32'd115, 32'd3);   // D2
        check_feat(52, 1'b1, 2'd0, 32'd5, 32'd7, 32'd2, 32'd0, -32'd1, 32'd2, 32'd0, 32'd7);
        tr(2'd0, SIDE_BID);                        // D3
        check_feat(53, 1'b0, 2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        q(2'd0, 32'd112, 32'd6, 32'd115, 32'd3);   // D4
        check_feat(54, 1'b1, 2'd0, 32'd3, 32'd1, 32'd3, 32'd1, 32'd0, 32'd3, 32'd1, 32'd8);
        // D5: reset wipes slot0's history (incl. F6=+1 from D3) -- the next
        // book event is a fresh first event again.
        do_reset;
        q(2'd0, 32'd100, 32'd10, 32'd0, 32'd0);
        check_feat(55, 1'b1, 2'd0, 32'd0, 32'd0, 32'd10, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);

        // ============== BLOCK E: next_* shape-specific new cases ==============
        // E1-E3 (slot 0, ask side): a price/qty-CHANGING QUOTE on an
        // already-established slot. E3 presents next_ask_price=1030 /
        // next_ask_qty=60 -- what the old REGISTERED bus would have shown on
        // that same cycle is the stale pre-E3 ask (1010/50). F0 must be
        // 1030-1000=30 (not 1010-1000=10) and F2=100-60=40 (not 50): the
        // feature reflects the presented next_* values, not stale ones. F4
        // (60-50=10) and F1 (=10) still use the PRIOR event's prev_* history
        // -- current-event post-update vs prior-event history stay distinct.
        do_reset;
        q(2'd0, 32'd1000, 32'd100, 32'd0,   32'd0);    // E1: bid only (first event)
        check_feat(61, 1'b1, 2'd0, 32'd0, 32'd0, 32'd100, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        q(2'd0, 32'd1000, 32'd100, 32'd1010, 32'd50);  // E2: ask established
        check_feat(62, 1'b1, 2'd0, 32'd10, 32'd505, 32'd50, 32'd0, 32'd50, 32'd2, 32'd0, 32'd505);
        q(2'd0, 32'd1000, 32'd100, 32'd1030, 32'd60);  // E3: ask price+qty change
        check_feat(63, 1'b1, 2'd0, 32'd30, 32'd10, 32'd40, 32'd0, 32'd10, 32'd3, 32'd0, 32'd515);

        // E4-E6 (slot 1, bid side, mirror): a bid price/qty-CHANGING QUOTE.
        // E6 presents next_bid_price=1990 / next_bid_qty=80; the stale
        // pre-E6 bid (2000/100) would give F0=2010-2000=10 and F2=50, but the
        // presented next_* values demand F0=2010-1990=20 and F2=80-50=30.
        // F3 = 80-100 = -20 (change vs prior bid qty) confirms the deltas
        // still track the prior event's history, not the stale current state.
        q(2'd1, 32'd0,   32'd0,  32'd2010, 32'd50);    // E4: ask only (first event)
        check_feat(64, 1'b1, 2'd1, 32'd2010, 32'd0, -32'd50, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        q(2'd1, 32'd2000, 32'd100, 32'd2010, 32'd50);  // E5: bid established
        check_feat(65, 1'b1, 2'd1, 32'd10, 32'd1000, 32'd50, 32'd100, 32'd0, 32'd2, 32'd0, 32'd1000);
        q(2'd1, 32'd1990, 32'd80, 32'd2010, 32'd50);   // E6: bid price+qty change
        check_feat(66, 1'b1, 2'd1, 32'd20, -32'd5, 32'd30, -32'd20, 32'd0, 32'd3, 32'd0, 32'd1005);

        // E7-E10 (slot 2): TRADE and HEARTBEAT between two QUOTEs -- next_*
        // must simply NOT be consulted on non-book-modifying events: no
        // feat_valid pulse from either, and the completing QUOTE still
        // computes its vector from its own presented post-update state (the
        // two intervening events correctly show up only as window pushes --
        // F5=2, not 3 -- and the TRADE's F6=-1 persists into the quote).
        q(2'd2, 32'd500, 32'd20, 32'd0,  32'd0);       // E7: bid only (first event)
        check_feat(67, 1'b1, 2'd2, 32'd0, 32'd0, 32'd20, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        tr(2'd2, SIDE_ASK);                            // E8: TRADE, no output
        check_feat(68, 1'b0, 2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        hb(2'd2);                                      // E9: HEARTBEAT, no output
        check_feat(69, 1'b0, 2'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        q(2'd2, 32'd500, 32'd20, 32'd520, 32'd10);     // E10: completing ask QUOTE
        check_feat(70, 1'b1, 2'd2, 32'd20, 32'd260, 32'd10, 32'd0, 32'd10, 32'd2, -32'd1, 32'd260);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
