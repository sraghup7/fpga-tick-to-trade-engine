`timescale 1ns / 1ps

// Self-checking cross-module regression chaining the REAL rtl/tob_engine.v
// and rtl/feature_extractor.v together (no tob_top.v, no other module).
//
// Icarus:
//   iverilog -g2001 -Wall -o feature_tob_chain_tb.vvp rtl/tob_engine.v rtl/feature_extractor.v tb/tb_feature_tob_chain.v
//   vvp feature_tob_chain_tb.vvp
//
// Why this testbench exists (D23, docs/design_decisions.md; contract
// docs/contracts/feature_extractor_patch.md S2.3): feature_extractor.v had
// the D23-twin latent defect -- its own header claimed it reads tob_engine.v's
// "post-update state of the applied slot," but it consumed tob_engine.v's
// registered bid_price/ask_price/etc buses combinationally on the same
// book_upd_valid cycle the triggering message arrives, i.e. the book as it
// stood BEFORE this message's own effect. No module-level testbench could
// catch it, because every standalone TB drives its DUT's book-state inputs
// directly ("the book already looks like X, THEN pulse book_upd_valid"),
// which is exactly the shape that makes a same-cycle stale read invisible.
// This file -- added with the fix, and wiring feature_extractor.v to
// tob_engine.v's next_* scalar ports -- drives message-shaped stimulus into
// tob_engine.v's own inputs and checks feature_extractor.v's feat_* against
// hand-computed expectations generated from sim/feature_golden.py's
// post-update semantics, not against whatever the (possibly still-buggy) RTL
// produces. Before the fix, with feature_extractor.v reading the registered
// buses instead, this same stimulus failed on essentially every book event:
// the headline case (a bid QUOTE then an ask QUOTE) reported feat_f0_spread
// = 0 where the ask's own just-applied price demands 10.
//
// Expectation semantics: feature_golden.py computes F0-F7 from the book
// state AFTER the triggering event was applied. feature_extractor.v must
// therefore read tob_engine.v's next_* scalar ports (combinational
// post-update state of the applied slot, D23) and register its vector one
// cycle after book_upd_valid. Each `fire` below drives one message cycle
// (book commits + vector registers at its posedge) followed by one idle
// cycle; on return the c_* capture regs (sampled pre-edge at the idle
// posedge) hold that message's registered feature vector.
//
// Block layout (each preceded by a reset, per the standalone TB's
// convention, so per-slot feature history starts fresh):
//   A   slot 0: the headline reproduction -- QUOTE bid 1000/100, then
//       QUOTE ask 1010/50 (expect feat_f0_spread = 10 from THIS ask's own
//       just-applied price on its own cycle), then a bid price-change QUOTE
//       (1005/100) confirming the NEW price is seen immediately while F1
//       keeps tracking prior-event history.
//   B   slot 1: the mirror -- QUOTE ask first, then QUOTE bid completes the
//       spread; same feat_f0_spread = 10 on the bid QUOTE's own cycle.
//   C   slots 2 & 0 interleaved: no cross-slot leakage of book state.
//   D   slot 3: TRADE + HEARTBEAT between the two QUOTEs of a spread build
//       -- no feat_valid pulse from either, and the completing QUOTE still
//       computes its F0 from its own post-update state (F6 = -1 from the
//       intervening TRADE, proving the TRADE advanced state correctly).
//
// Verilog-2001 only.

module tb_feature_tob_chain;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    // ---- tob_engine.v inputs (message-shaped stimulus) ----
    reg        rst_n = 1'b0;
    reg [7:0]  msg_type = 8'd0;
    reg [7:0]  msg_side = 8'd0;
    reg [31:0] msg_price = 32'd0;
    reg [31:0] msg_quantity = 32'd0;
    reg        filt_valid = 1'b0;
    reg [1:0]  filt_slot = 2'd0;
    reg        err_seq_dup = 1'b0;

    // ---- module boundary wires ----
    wire [31:0] next_bid_price, next_bid_qty, next_ask_price, next_ask_qty;
    wire        feat_valid;
    wire [1:0]  feat_slot;
    wire [31:0] feat_f0_spread, feat_f1_mid_delta, feat_f2_imbalance;
    wire [31:0] feat_f3_bid_chg, feat_f4_ask_chg, feat_f5_update_rate;
    wire [31:0] feat_f6_last_trade_dir, feat_f7_volatility;

    localparam [7:0] QUOTE     = 8'h01;
    localparam [7:0] TRADE     = 8'h02;
    localparam [7:0] CLEAR     = 8'h03;
    localparam [7:0] HEARTBEAT = 8'hFF;
    localparam [7:0] SIDE_BID  = 8'h00;
    localparam [7:0] SIDE_ASK  = 8'h01;

    tob_engine u_tob (
        .clk                  (clk),
        .rst_n                (rst_n),
        .msg_type             (msg_type),
        .msg_side             (msg_side),
        .msg_price            (msg_price),
        .msg_quantity         (msg_quantity),
        .filt_valid           (filt_valid),
        .filt_slot            (filt_slot),
        .err_seq_dup          (err_seq_dup),
        .msg_applied          (),
        .applied_slot         (),
        .book_upd_valid       (),
        .cnt_book_clear_pulse (),
        .cnt_trades_pulse     (),
        .cnt_heartbeats_pulse (),
        .cnt_crossed_pulse    (),
        .bid_price            (),
        .bid_qty              (),
        .bid_valid            (),
        .ask_price            (),
        .ask_qty              (),
        .ask_valid            (),
        .crossed              (),
        .next_bid_price       (next_bid_price),
        .next_bid_qty         (next_bid_qty),
        .next_bid_valid       (),
        .next_ask_price       (next_ask_price),
        .next_ask_qty         (next_ask_qty),
        .next_ask_valid       (),
        .next_crossed         ()
    );

    feature_extractor #(
        .NUM_SYMBOLS (4),
        .WINDOW      (4)
    ) u_feat (
        .clk                  (clk),
        .rst_n                (rst_n),
        .msg_type             (msg_type),
        .msg_side             (msg_side),
        .msg_applied          (u_tob.msg_applied),
        .book_upd_valid       (u_tob.book_upd_valid),
        .applied_slot         (u_tob.applied_slot),
        .next_bid_price       (next_bid_price),
        .next_bid_qty         (next_bid_qty),
        .next_ask_price       (next_ask_price),
        .next_ask_qty         (next_ask_qty),
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

    // Capture feat_* at each posedge (pre-edge), so the sample taken at the
    // idle posedge after a driven message cycle holds that message's
    // registered vector (feat_valid pulses one cycle after book_upd_valid --
    // same convention as tb_feature_extractor.v / tb_signal_tob_chain.v).
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

    reg     fail = 1'b0;
    integer tc = 0;

    // Drive one message for exactly one cycle (book commits + vector
    // registers at its posedge), then one idle cycle. On return c_* holds
    // that message's verdict.
    task fire;
        input [7:0]  mt;
        input [7:0]  ms;
        input [31:0] mp;
        input [31:0] mq;
        input [1:0]  fs;
        begin
            @(negedge clk);                      // N0: present the message
            msg_type     = mt;
            msg_side     = ms;
            msg_price    = mp;
            msg_quantity = mq;
            filt_valid   = 1'b1;
            filt_slot    = fs;
            err_seq_dup  = 1'b0;
            @(posedge clk);                      // P1: book commits, vector registers
            #1;
            @(negedge clk);                      // N1: deassert
            filt_valid   = 1'b0;
            err_seq_dup  = 1'b0;
            @(posedge clk);                      // P2: c_* captures the vector
            #1;
        end
    endtask

    // Compare the last fired message's vector against hand-computed golden
    // expectations (feature order f0 f1 f2 f3 f4 f5 f6 f7). Feature data is
    // only meaningful when e_valid is high.
    task check;
        input integer  tag;
        input          e_valid;
        input [1:0]    e_slot;
        input [31:0]   e0, e1, e2, e3, e4, e5, e6, e7;
        begin
            if (c_valid !== e_valid) begin
                $display("FAIL: msg %0d: feat_valid=%b, expected %b", tag, c_valid, e_valid);
                fail = 1'b1;
            end
            if (e_valid && (c_slot !== e_slot)) begin
                $display("FAIL: msg %0d: feat_slot=%0d, expected %0d", tag, c_slot, e_slot);
                fail = 1'b1;
            end
            if (e_valid) begin
                if (c_f0 !== e0) begin $display("FAIL: msg %0d: F0=%0d, expected %0d", tag, c_f0, e0); fail = 1'b1; end
                if (c_f1 !== e1) begin $display("FAIL: msg %0d: F1=%0d, expected %0d", tag, $signed(c_f1), e1); fail = 1'b1; end
                if (c_f2 !== e2) begin $display("FAIL: msg %0d: F2=%0d, expected %0d", tag, $signed(c_f2), e2); fail = 1'b1; end
                if (c_f3 !== e3) begin $display("FAIL: msg %0d: F3=%0d, expected %0d", tag, $signed(c_f3), e3); fail = 1'b1; end
                if (c_f4 !== e4) begin $display("FAIL: msg %0d: F4=%0d, expected %0d", tag, $signed(c_f4), e4); fail = 1'b1; end
                if (c_f5 !== e5) begin $display("FAIL: msg %0d: F5=%0d, expected %0d", tag, c_f5, e5); fail = 1'b1; end
                if (c_f6 !== e6) begin $display("FAIL: msg %0d: F6=%0d, expected %0d", tag, $signed(c_f6), e6); fail = 1'b1; end
                if (c_f7 !== e7) begin $display("FAIL: msg %0d: F7=%0d, expected %0d", tag, c_f7, e7); fail = 1'b1; end
            end
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        // ---- reset ----
        do_reset;
        if (feat_valid) begin
            $display("FAIL: reset: feat_valid asserted out of reset");
            fail = 1'b1;
        end

        // ================= Block A: slot 0 -- the headline reproduction =========
        // QUOTE bid 1000/100 (first event on the slot: baseline vector, ask is
        // still 0 so F0 saturates to 0), then QUOTE ask 1010/50. The ask
        // QUOTE's OWN cycle must yield feat_f0_spread = 10 (1010 - 1000, using
        // this message's own just-applied ask price), registered one cycle
        // later. A stale-book feature_extractor would read the ask price from
        // before this message (still 0) and wrongly saturate F0 to 0 -- that
        // 10-vs-0 is the exact numeric signature of the D23-twin bug.
        fire(QUOTE, SIDE_BID, 32'd1000, 32'd100, 2'd0);
        check(1, 1'b1, 2'd0, 32'd0, 32'd0, 32'd100, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        fire(QUOTE, SIDE_ASK, 32'd1010, 32'd50, 2'd0);
        check(2, 1'b1, 2'd0, 32'd10, 32'd505, 32'd50, 32'd0, 32'd50, 32'd2, 32'd0, 32'd505);
        // A price-changing QUOTE on the now-established slot: F0 must reflect
        // the NEW bid price immediately (1010 - 1005 = 5) while F1/F3/F4 keep
        // using the PRIOR event's prev_* history (F1 = mid 1007 - prev mid
        // 1005 = 2; F3/F4 = 0, quantities unchanged). Confirms the current-
        // event post-update source and the prior-event history source don't
        // get confused with each other in the fix.
        fire(QUOTE, SIDE_BID, 32'd1005, 32'd100, 2'd0);
        check(3, 1'b1, 2'd0, 32'd5, 32'd2, 32'd50, 32'd0, 32'd0, 32'd3, 32'd0, 32'd507);

        // ================= Block B: slot 1 -- the mirror ========================
        // Establish the ask side FIRST (QUOTE ask 1010/50), then complete with
        // QUOTE bid 1000/100 -- same feat_f0_spread = 10 expectation on the
        // bid QUOTE's own cycle.
        do_reset;
        fire(QUOTE, SIDE_ASK, 32'd1010, 32'd50, 2'd1);
        check(4, 1'b1, 2'd1, 32'd1010, 32'd0, -32'd50, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        fire(QUOTE, SIDE_BID, 32'd1000, 32'd100, 2'd1);
        check(5, 1'b1, 2'd1, 32'd10, 32'd500, 32'd50, 32'd100, 32'd0, 32'd2, 32'd0, 32'd500);

        // ============ Block C: multiple symbols interleaved (slots 2 & 0) =======
        // Confirms slot 2's feature vector never picks up slot 0's book state
        // and vice versa -- exercises applied_slot routing end to end through
        // both real modules. Each slot builds its own spread (3000->3010 and
        // 5000->5010, both F0 = 10) with the two slots' messages interleaved.
        do_reset;
        fire(QUOTE, SIDE_BID, 32'd3000, 32'd100, 2'd2);
        check(6, 1'b1, 2'd2, 32'd0, 32'd0, 32'd100, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        fire(QUOTE, SIDE_BID, 32'd5000, 32'd100, 2'd0);
        check(7, 1'b1, 2'd0, 32'd0, 32'd0, 32'd100, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        fire(QUOTE, SIDE_ASK, 32'd3010, 32'd50, 2'd2);
        check(8, 1'b1, 2'd2, 32'd10, 32'd1505, 32'd50, 32'd0, 32'd50, 32'd2, 32'd0, 32'd1505);
        fire(QUOTE, SIDE_ASK, 32'd5010, 32'd25, 2'd0);
        check(9, 1'b1, 2'd0, 32'd10, 32'd2505, 32'd75, 32'd0, 32'd25, 32'd2, 32'd0, 32'd2505);

        // ========== Block D: TRADE + HEARTBEAT between two QUOTEs (slot 3) ======
        // They neither pulse feat_valid themselves (per book gating, which
        // this patch does not touch) nor corrupt the eventual QUOTE-triggered
        // vector, which must still be computed from its own post-update state.
        // F6 = -1 on that vector confirms the intervening TRADE correctly
        // updated last_trade_dir and the window absorbed the two non-book
        // events without shifting F5.
        do_reset;
        fire(QUOTE, SIDE_BID, 32'd2000, 32'd100, 2'd3);
        check(10, 1'b1, 2'd3, 32'd0, 32'd0, 32'd100, 32'd0, 32'd0, 32'd1, 32'd0, 32'd0);
        fire(TRADE, SIDE_ASK, 32'd0, 32'd0, 2'd3);
        check(11, 1'b0, 2'd3, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        fire(HEARTBEAT, SIDE_BID, 32'd0, 32'd0, 2'd3);
        check(12, 1'b0, 2'd3, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        fire(QUOTE, SIDE_ASK, 32'd2010, 32'd50, 2'd3);
        check(13, 1'b1, 2'd3, 32'd10, 32'd1005, 32'd50, 32'd0, 32'd50, 32'd2, -32'd1, 32'd1005);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
