`timescale 1ns / 1ps

// Self-checking testbench for rtl/tob_engine.v (master spec S3.1 [G],
// FR-13..19, FR-17; contract docs/contracts/tob_engine.md S3).
//
// Icarus:
//   iverilog -g2001 -Wall -o tob_engine_tb.vvp rtl/tob_engine.v tb/tb_tob_engine.v
//   vvp tob_engine_tb.vvp
//
// tob_engine registers per-slot book state at the posedge of each applied
// message cycle (msg_applied = filt_valid & ~err_seq_dup) and drives the
// status pulses combinationally for that same cycle. The testbench samples
// the same way tb_seq_monitor.v does:
//   * one-cycle verdicts (msg_applied, book_upd_valid, cnt_*_pulse) and
//     applied_slot are captured at the posedge ending the message cycle
//     (c_* regs), pre-state-update;
//   * committed book state is read off the buses one delta after that
//     posedge (post-update).
// Each message is driven for exactly one cycle then followed by an idle
// cycle (end_msg), which also proves no status pulse lingers.
//
// Directed cases (contract S3), slot 0 first then slot 2:
//   reset      FR-18: all slots invalid / uncrossed after rst_n, with bogus
//              inputs driven during reset (no stale state observable)
//   M1-M2      FR-14: QUOTE bid then QUOTE ask land independently on slot 0
//   M3         FR-15/D14: qty=0 quote with a deliberately wrong price must
//              clear valid/qty but PRESERVE the stored price
//   M4-M5      FR-17: crossed builds to 1 (bid 110 >= ask 90) and the
//              cross-CREATING quote fires cnt_crossed_pulse (post-update)
//   M6         FR-19 + S2.4: TRADE modifies nothing but still fires
//              cnt_crossed_pulse while the book stays crossed
//   M7         uncrossing requote (ask 120): crossed drops to 0 and the
//              requote cycle does NOT fire cnt_crossed_pulse
//   M8         HEARTBEAT: nothing changes, cnt_heartbeats_pulse fires once
//   M9         FR-16: CLEAR drops both valid bits but preserves prices/qty,
//              cnt_book_clear_pulse fires once
//   M10        requote to crossed (bid 130 / ask 120) for the gating tests
//   M11        FR-11: duplicate (filt_valid=1, err_seq_dup=1) QUOTE applies
//              NOTHING -- no write, no pulse, even though the book is crossed
//   M12        unwatched (filt_valid=0): same nothing-happens result
//   M12a/M12b  duplicate TRADE and unwatched HEARTBEAT: counter pulses are
//              gated by msg_applied too (S1: applies to all four msg_types)
//   M13-M15    independent slot: slot 2 gets its own quotes (incl. an
//              equality cross bid 200 == ask 200, pinning FR-17's >=); slot
//              0's state is untouched, slots 1/3 stay invalid throughout
//   final      whole-book assertion of all four slots
//
// Drives msg_*/filt_*/err_seq_dup directly -- the symbol_filter.v /
// seq_monitor.v / md_parser.v boundary this module combines.
//
// Verilog-2001 only.

module tb_tob_engine;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg [7:0]  msg_type = 8'd0;
    reg [7:0]  msg_side = 8'd0;
    reg [31:0] msg_price = 32'd0;
    reg [31:0] msg_quantity = 32'd0;
    reg        filt_valid = 1'b0;
    reg [1:0]  filt_slot = 2'd0;
    reg        err_seq_dup = 1'b0;

    wire        msg_applied;
    wire [1:0]  applied_slot;
    wire        book_upd_valid;
    wire        cnt_book_clear_pulse;
    wire        cnt_trades_pulse;
    wire        cnt_heartbeats_pulse;
    wire        cnt_crossed_pulse;
    wire [127:0] bid_price, bid_qty, ask_price, ask_qty;  // 4 x 32
    wire [3:0]   bid_valid, ask_valid, crossed;

    localparam [7:0] QUOTE     = 8'h01;
    localparam [7:0] TRADE     = 8'h02;
    localparam [7:0] CLEAR     = 8'h03;
    localparam [7:0] HEARTBEAT = 8'hFF;
    localparam [7:0] SIDE_BID  = 8'h00;
    localparam [7:0] SIDE_ASK  = 8'h01;

    tob_engine dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .msg_type             (msg_type),
        .msg_side             (msg_side),
        .msg_price            (msg_price),
        .msg_quantity         (msg_quantity),
        .filt_valid           (filt_valid),
        .filt_slot            (filt_slot),
        .err_seq_dup          (err_seq_dup),
        .msg_applied          (msg_applied),
        .applied_slot         (applied_slot),
        .book_upd_valid       (book_upd_valid),
        .cnt_book_clear_pulse (cnt_book_clear_pulse),
        .cnt_trades_pulse     (cnt_trades_pulse),
        .cnt_heartbeats_pulse (cnt_heartbeats_pulse),
        .cnt_crossed_pulse    (cnt_crossed_pulse),
        .bid_price            (bid_price),
        .bid_qty              (bid_qty),
        .bid_valid            (bid_valid),
        .ask_price            (ask_price),
        .ask_qty              (ask_qty),
        .ask_valid            (ask_valid),
        .crossed              (crossed)
    );

    reg     fail = 1'b0;
    integer tc = 0;

    // Capture the combinational one-cycle verdicts at the posedge that ends
    // each cycle (blocking read sees pre-state-update values -- the message
    // cycle's own verdicts, same convention as tb_seq_monitor.v).
    reg        c_applied, c_bookupd, c_clear, c_trades, c_hb, c_crossed;
    reg [1:0]  c_slot;
    always @(posedge clk) begin
        c_applied = msg_applied;
        c_bookupd = book_upd_valid;
        c_clear   = cnt_book_clear_pulse;
        c_trades  = cnt_trades_pulse;
        c_hb      = cnt_heartbeats_pulse;
        c_crossed = cnt_crossed_pulse;
        c_slot    = applied_slot;
    end

    // Drive one message for exactly one clock cycle. Book state updates at
    // the posedge inside; on return (posedge + 1ns) the committed state is
    // post-update and c_* holds the message cycle's verdicts.
    task fire;
        input [7:0]  mt;
        input [7:0]  ms;
        input [31:0] mp;
        input [31:0] mq;
        input        fv;
        input [1:0]  fs;
        input        dup;
        begin
            @(negedge clk);
            msg_type    = mt;
            msg_side    = ms;
            msg_price   = mp;
            msg_quantity = mq;
            filt_valid  = fv;
            filt_slot   = fs;
            err_seq_dup = dup;
            @(posedge clk);
            #1;
        end
    endtask

    // One idle cycle: drop the gating inputs and require every status pulse
    // to be quiet (no lingering pulse, no spurious re-apply).
    task end_msg;
        begin
            @(negedge clk);
            filt_valid  = 1'b0;
            err_seq_dup = 1'b0;
            @(posedge clk);
            #1;
            if (c_applied || c_bookupd || c_clear || c_trades || c_hb || c_crossed) begin
                $display("FAIL: status pulse lingered into idle cycle");
                fail = 1'b1;
            end
        end
    endtask

    // Read one slot's committed state into s_*.
    reg [31:0] s_bp, s_bq, s_ap, s_aq;
    reg        s_bv, s_av, s_cr;
    task snap;
        input [1:0] i;
        begin
            s_bp = bid_price [i*32 +: 32];
            s_bq = bid_qty   [i*32 +: 32];
            s_ap = ask_price [i*32 +: 32];
            s_aq = ask_qty   [i*32 +: 32];
            s_bv = bid_valid [i];
            s_av = ask_valid [i];
            s_cr = crossed   [i];
        end
    endtask

    // Compare the last-snapped slot's state against expectations.
    task expect_slot;
        input integer  tag;
        input [31:0]   e_bp, e_bq, e_ap, e_aq;
        input          e_bv, e_av, e_cr;
        begin
            if (s_bp !== e_bp) begin $display("FAIL: M%0d bid_price=%0d, expected %0d", tag, s_bp, e_bp); fail = 1'b1; end
            if (s_bq !== e_bq) begin $display("FAIL: M%0d bid_qty=%0d, expected %0d",   tag, s_bq, e_bq); fail = 1'b1; end
            if (s_ap !== e_ap) begin $display("FAIL: M%0d ask_price=%0d, expected %0d", tag, s_ap, e_ap); fail = 1'b1; end
            if (s_aq !== e_aq) begin $display("FAIL: M%0d ask_qty=%0d, expected %0d",   tag, s_aq, e_aq); fail = 1'b1; end
            if (s_bv !== e_bv) begin $display("FAIL: M%0d bid_valid=%b, expected %b",   tag, s_bv, e_bv); fail = 1'b1; end
            if (s_av !== e_av) begin $display("FAIL: M%0d ask_valid=%b, expected %b",   tag, s_av, e_av); fail = 1'b1; end
            if (s_cr !== e_cr) begin $display("FAIL: M%0d crossed=%b, expected %b",     tag, s_cr, e_cr); fail = 1'b1; end
        end
    endtask

    // Compare the last message cycle's status verdicts. applied_slot is only
    // meaningful when the message was applied.
    task expect_pulses;
        input integer tag;
        input        e_app, e_bu, e_cl, e_tr, e_hb, e_cr;
        input [1:0]  e_slot;
        begin
            if (c_applied !== e_app) begin $display("FAIL: M%0d msg_applied=%b, expected %b", tag, c_applied, e_app); fail = 1'b1; end
            if (c_bookupd !== e_bu)  begin $display("FAIL: M%0d book_upd_valid=%b, expected %b", tag, c_bookupd, e_bu); fail = 1'b1; end
            if (c_clear   !== e_cl)  begin $display("FAIL: M%0d cnt_book_clear_pulse=%b, expected %b", tag, c_clear, e_cl); fail = 1'b1; end
            if (c_trades  !== e_tr)  begin $display("FAIL: M%0d cnt_trades_pulse=%b, expected %b", tag, c_trades, e_tr); fail = 1'b1; end
            if (c_hb      !== e_hb)  begin $display("FAIL: M%0d cnt_heartbeats_pulse=%b, expected %b", tag, c_hb, e_hb); fail = 1'b1; end
            if (c_crossed !== e_cr)  begin $display("FAIL: M%0d cnt_crossed_pulse=%b, expected %b", tag, c_crossed, e_cr); fail = 1'b1; end
            if (e_app && (c_slot !== e_slot)) begin $display("FAIL: M%0d applied_slot=%0d, expected %0d", tag, c_slot, e_slot); fail = 1'b1; end
        end
    endtask

    // Assert a whole slot is in its reset state (all zero / invalid).
    task expect_reset_slot;
        input integer tag;
        input [1:0] i;
        begin
            snap(i);
            if (s_bp !== 32'd0 || s_bq !== 32'd0 || s_ap !== 32'd0 || s_aq !== 32'd0 ||
                s_bv !== 1'b0   || s_av !== 1'b0   || s_cr !== 1'b0) begin
                $display("FAIL: reset state slot %0d: bp=%0d bq=%0d bv=%b ap=%0d aq=%0d av=%b cr=%b, expected all 0",
                         i, s_bp, s_bq, s_bv, s_ap, s_aq, s_av, s_cr);
                fail = 1'b1;
            end
        end
    endtask

    initial begin
        // ---- FR-18: right after rst_n deasserts, every slot reads invalid
        //      with no stale value. Drive an applied-looking QUOTE while
        //      rst_n is still low (nothing may latch), then remove the
        //      gating inputs BEFORE deasserting reset so the release cannot
        //      be followed by a legitimate apply of the bogus quote, and
        //      check every slot reads zero. ----
        msg_type    = QUOTE;
        msg_side    = SIDE_BID;
        msg_price   = 32'hDEADBEEF;
        msg_quantity = 32'd85;
        filt_valid  = 1'b1;
        filt_slot   = 2'd1;
        err_seq_dup = 1'b0;
        repeat (3) @(posedge clk);      // reset held: several edges, no latch
        @(negedge clk);
        filt_valid  = 1'b0;             // benign inputs before reset release
        err_seq_dup = 1'b0;
        rst_n       = 1'b1;
        @(posedge clk);
        #1;
        expect_reset_slot(0, 2'd0);
        expect_reset_slot(0, 2'd1);
        expect_reset_slot(0, 2'd2);
        expect_reset_slot(0, 2'd3);

        // ---- M1: QUOTE bid, slot 0 ----
        fire(QUOTE, SIDE_BID, 32'd100, 32'd10, 1'b1, 2'd0, 1'b0);
        expect_pulses(1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(1, 32'd100, 32'd10, 32'd0, 32'd0, 1'b1, 1'b0, 1'b0);
        end_msg;

        // ---- M2: QUOTE ask, slot 0 (bid side untouched) ----
        fire(QUOTE, SIDE_ASK, 32'd110, 32'd5, 1'b1, 2'd0, 1'b0);
        expect_pulses(2, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(2, 32'd100, 32'd10, 32'd110, 32'd5, 1'b1, 1'b1, 1'b0);
        end_msg;

        // ---- M3: QUOTE bid qty=0 with a wrong price (D14 / FR-15):
        //      clears valid+qty but PRESERVES the stored price 100 ----
        fire(QUOTE, SIDE_BID, 32'd99, 32'd0, 1'b1, 2'd0, 1'b0);
        expect_pulses(3, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(3, 32'd100, 32'd0, 32'd110, 32'd5, 1'b0, 1'b1, 1'b0);
        end_msg;

        // ---- M4: QUOTE ask 90/8 (bid still invalid) ----
        fire(QUOTE, SIDE_ASK, 32'd90, 32'd8, 1'b1, 2'd0, 1'b0);
        expect_pulses(4, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(4, 32'd100, 32'd0, 32'd90, 32'd8, 1'b0, 1'b1, 1'b0);
        end_msg;

        // ---- M5: QUOTE bid 110/10 -- creates bid 110 >= ask 90: crossed
        //      goes to 1 AND the cross-creating quote fires cnt_crossed_pulse
        //      (it is evaluated on post-update state) ----
        fire(QUOTE, SIDE_BID, 32'd110, 32'd10, 1'b1, 2'd0, 1'b0);
        expect_pulses(5, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 2'd0);
        snap(2'd0);
        expect_slot(5, 32'd110, 32'd10, 32'd90, 32'd8, 1'b1, 1'b1, 1'b1);
        end_msg;

        // ---- M6: TRADE modifies nothing, but while the book is crossed it
        //      still fires cnt_crossed_pulse (S2.4's non-obvious case) ----
        fire(TRADE, SIDE_ASK, 32'd0, 32'd0, 1'b1, 2'd0, 1'b0);
        expect_pulses(6, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 2'd0);
        snap(2'd0);
        expect_slot(6, 32'd110, 32'd10, 32'd90, 32'd8, 1'b1, 1'b1, 1'b1);
        end_msg;

        // ---- M7: requote ask 120/5 -- uncrosses (110 < 120); crossed drops
        //      to 0 and this cycle must NOT fire cnt_crossed_pulse ----
        fire(QUOTE, SIDE_ASK, 32'd120, 32'd5, 1'b1, 2'd0, 1'b0);
        expect_pulses(7, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(7, 32'd110, 32'd10, 32'd120, 32'd5, 1'b1, 1'b1, 1'b0);
        end_msg;

        // ---- M8: HEARTBEAT touches nothing, fires its counter once ----
        fire(HEARTBEAT, SIDE_BID, 32'd0, 32'd0, 1'b1, 2'd0, 1'b0);
        expect_pulses(8, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(8, 32'd110, 32'd10, 32'd120, 32'd5, 1'b1, 1'b1, 1'b0);
        end_msg;

        // ---- M9: CLEAR -- both valid bits drop, prices/quantities PRESERVED
        //      (not zeroed), cnt_book_clear_pulse fires once ----
        fire(CLEAR, SIDE_BID, 32'd0, 32'd0, 1'b1, 2'd0, 1'b0);
        expect_pulses(9, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(9, 32'd110, 32'd10, 32'd120, 32'd5, 1'b0, 1'b0, 1'b0);
        end_msg;

        // ---- M10: re-quote to a crossed book (bid 130 / ask 120) so the
        //      gating tests below have a crossed state to (not) react to ----
        fire(QUOTE, SIDE_BID, 32'd130, 32'd7, 1'b1, 2'd0, 1'b0);
        expect_pulses(10, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(10, 32'd130, 32'd7, 32'd120, 32'd5, 1'b1, 1'b0, 1'b0);
        end_msg;
        fire(QUOTE, SIDE_ASK, 32'd120, 32'd4, 1'b1, 2'd0, 1'b0);
        expect_pulses(11, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 2'd0);
        snap(2'd0);
        expect_slot(11, 32'd130, 32'd7, 32'd120, 32'd4, 1'b1, 1'b1, 1'b1);
        end_msg;

        // ---- M11: duplicate (err_seq_dup=1) QUOTE that WOULD alter the
        //      book: nothing changes, and no cnt_crossed_pulse even though
        //      the book is currently crossed (FR-11 gates everything) ----
        fire(QUOTE, SIDE_ASK, 32'd500, 32'd50, 1'b1, 2'd0, 1'b1);
        expect_pulses(12, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(12, 32'd130, 32'd7, 32'd120, 32'd4, 1'b1, 1'b1, 1'b1);
        end_msg;

        // ---- M12: unwatched (filt_valid=0) QUOTE: same nothing-happens ----
        fire(QUOTE, SIDE_BID, 32'd700, 32'd60, 1'b0, 2'd0, 1'b0);
        expect_pulses(13, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(13, 32'd130, 32'd7, 32'd120, 32'd4, 1'b1, 1'b1, 1'b1);
        end_msg;

        // ---- M12a: duplicate TRADE: cnt_trades_pulse must NOT fire ----
        fire(TRADE, SIDE_ASK, 32'd0, 32'd0, 1'b1, 2'd0, 1'b1);
        expect_pulses(14, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(14, 32'd130, 32'd7, 32'd120, 32'd4, 1'b1, 1'b1, 1'b1);
        end_msg;

        // ---- M12b: unwatched HEARTBEAT: cnt_heartbeats_pulse must NOT fire ----
        fire(HEARTBEAT, SIDE_BID, 32'd0, 32'd0, 1'b0, 2'd0, 1'b0);
        expect_pulses(15, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'd0);
        snap(2'd0);
        expect_slot(15, 32'd130, 32'd7, 32'd120, 32'd4, 1'b1, 1'b1, 1'b1);
        end_msg;

        // ---- M13-M15: independent slot 2 (slots 1 and 3 never touched) ----
        fire(QUOTE, SIDE_BID, 32'd200, 32'd20, 1'b1, 2'd2, 1'b0);
        expect_pulses(16, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd2);
        snap(2'd2);
        expect_slot(16, 32'd200, 32'd20, 32'd0, 32'd0, 1'b1, 1'b0, 1'b0);
        snap(2'd0);   // slot 0 untouched by slot 2's traffic
        expect_slot(16, 32'd130, 32'd7, 32'd120, 32'd4, 1'b1, 1'b1, 1'b1);
        end_msg;

        fire(QUOTE, SIDE_ASK, 32'd205, 32'd15, 1'b1, 2'd2, 1'b0);
        expect_pulses(17, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 2'd2);
        snap(2'd2);
        expect_slot(17, 32'd200, 32'd20, 32'd205, 32'd15, 1'b1, 1'b1, 1'b0);
        end_msg;

        // ---- M15: equality cross (bid 200 == ask 200): crossed must read 1
        //      (FR-17's >=, not >) and fire cnt_crossed_pulse ----
        fire(QUOTE, SIDE_ASK, 32'd200, 32'd12, 1'b1, 2'd2, 1'b0);
        expect_pulses(18, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 2'd2);
        snap(2'd2);
        expect_slot(18, 32'd200, 32'd20, 32'd200, 32'd12, 1'b1, 1'b1, 1'b1);
        end_msg;

        // ---- whole-book final assertion ----
        snap(2'd0);
        expect_slot(19, 32'd130, 32'd7, 32'd120, 32'd4, 1'b1, 1'b1, 1'b1);
        snap(2'd1);
        expect_slot(19, 32'd0, 32'd0, 32'd0, 32'd0, 1'b0, 1'b0, 1'b0);
        snap(2'd2);
        expect_slot(19, 32'd200, 32'd20, 32'd200, 32'd12, 1'b1, 1'b1, 1'b1);
        snap(2'd3);
        expect_slot(19, 32'd0, 32'd0, 32'd0, 32'd0, 1'b0, 1'b0, 1'b0);

        // ---- FR-18, strong form: reset must clear populated state. Slots 0
        //      and 2 currently hold valid, crossed books -- assert reset and
        //      confirm nothing stale survives it on any slot. ----
        @(negedge clk);
        rst_n = 1'b0;                   // async assert
        @(negedge clk);
        @(negedge clk);                 // hold reset a couple of cycles
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        expect_reset_slot(20, 2'd0);
        expect_reset_slot(20, 2'd1);
        expect_reset_slot(20, 2'd2);
        expect_reset_slot(20, 2'd3);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
