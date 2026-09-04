`timescale 1ns / 1ps

// Self-checking testbench for rtl/signal_engine.v (master spec S3.1 [H],
// S3.2 "signal path (fast)", FR-35..40; contract docs/contracts/signal_engine.md).
//
// Icarus:
//   iverilog -g2001 -Wall -o signal_engine_tb.vvp rtl/signal_engine.v tb/tb_signal_engine.v
//   vvp signal_engine_tb.vvp
//
// signal_engine evaluates buy_ok/sell_ok combinationally from the current
// cycle's book-state inputs whenever book_upd_valid is high and registers the
// order intent (sig_*) one cycle later (S2.3). err_signal_conflict is a
// one-cycle combinational pulse, valid on the book_upd_valid cycle itself.
// Book-state buses are driven directly to the slot's post-update values --
// the same convention tb_feature_extractor.v uses: this module only reads the
// buses it is given and never reconstructs tob_engine.v's update.
//
// Clocking (same shape as tb_feature_extractor.v's `ev`): each `cycle` drives
// the book inputs from a negedge for exactly one clock, drops book_upd_valid
// on the next negedge, and returns after the following posedge, when the c_*
// capture regs (pre-edge samples at that posedge) hold that cycle's verdict:
//   * sig_* is registered at the posedge INSIDE the driven cycle, so the c_*
//     sample taken at the idle posedge after it is that event's intent;
//   * err_signal_conflict is combinational, so it is captured separately,
//     right after the driven cycle's posedge (c_err), while book_upd_valid is
//     still high.
//
// Cases (contract S3):
//   reset     outputs quiet out of reset even with fire-worthy inputs present
//   A1-A3     T13-style exact spread threshold for buy (== fires, -1 does not,
//             +1 fires), everything else held constant
//   B1-B3     T14-style exact spread threshold for sell (mirror)
//   C1-C4     strict-inequality imbalance boundary on both sides: == must not
//             fire, +1 must (the rule is >, not >=)
//   D1-D2     crossed book blocks both regardless of qty ratio -- including the
//             S2.2/D15 trap where a crossed book's wrapped spread subtraction
//             looks enormous to a naive implementation; also NOT a conflict
//   E1-E2     either side invalid blocks both
//   F         D15 overflow-safety regression: bid_qty = ask_qty = 0x80000000,
//             imb_shift = 1 -> neither qty condition may read true (a plain
//             32-bit shift would wrap both to 0 and fire a spurious conflict)
//   G         FR-37 defensive conflict logic, exercised via force/release on
//             the DUT's internal buy_ok/sell_ok wires -- see the comment there
//   H1-H2     book_upd_valid = 0 with otherwise signal-worthy inputs: no
//             sig_valid that cycle or the next
//   I1-I3     independent slots: interleaved buy/sell-worthy events on
//             different slots, sig_slot/sig_side follow the right slot
//
// On any mismatch a FAIL line prints expected vs actual; a final PASS/FAIL
// line summarizes. Verilog-2001 only.

module tb_signal_engine;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    // ---- DUT inputs ----
    reg        rst_n = 1'b0;
    reg        book_upd_valid = 1'b0;
    reg [1:0]  applied_slot = 2'd0;
    reg [127:0] b_bid_price, b_bid_qty, b_ask_price, b_ask_qty;
    reg [3:0]  b_bid_valid, b_ask_valid, b_crossed;
    reg [31:0] cfg_min_spread = 32'd2;   // S9 CSR defaults
    reg [1:0]  cfg_imb_shift  = 2'd1;
    reg [31:0] cfg_order_qty  = 32'd100;

    // ---- DUT outputs ----
    wire        sig_valid;
    wire [1:0]  sig_slot;
    wire [7:0]  sig_side;
    wire [31:0] sig_price;
    wire [31:0] sig_qty;
    wire        err_signal_conflict;

    localparam [7:0] SIDE_BID = 8'h00;   // buy at the ask
    localparam [7:0] SIDE_ASK = 8'h01;   // sell at the bid

    signal_engine dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .book_upd_valid     (book_upd_valid),
        .applied_slot       (applied_slot),
        .bid_price          (b_bid_price),
        .bid_qty            (b_bid_qty),
        .bid_valid          (b_bid_valid),
        .ask_price          (b_ask_price),
        .ask_qty            (b_ask_qty),
        .ask_valid          (b_ask_valid),
        .crossed            (b_crossed),
        .cfg_min_spread     (cfg_min_spread),
        .cfg_imb_shift      (cfg_imb_shift),
        .cfg_order_qty      (cfg_order_qty),
        .sig_valid          (sig_valid),
        .sig_slot           (sig_slot),
        .sig_side           (sig_side),
        .sig_price          (sig_price),
        .sig_qty            (sig_qty),
        .err_signal_conflict (err_signal_conflict)
    );

    // ---- per-slot book model (what we drive onto the buses) ----
    reg [31:0] mbp [0:3];
    reg [31:0] mbq [0:3];
    reg [31:0] map [0:3];
    reg [31:0] maq [0:3];
    reg        m_bv [0:3];
    reg        m_av [0:3];
    reg        m_cr [0:3];
    integer k;

    task drive_bus;
        begin
            b_bid_price = {mbp[3], mbp[2], mbp[1], mbp[0]};
            b_bid_qty   = {mbq[3], mbq[2], mbq[1], mbq[0]};
            b_ask_price = {map[3], map[2], map[1], map[0]};
            b_ask_qty   = {maq[3], maq[2], maq[1], maq[0]};
            b_bid_valid = {m_bv[3], m_bv[2], m_bv[1], m_bv[0]};
            b_ask_valid = {m_av[3], m_av[2], m_av[1], m_av[0]};
            b_crossed   = {m_cr[3], m_cr[2], m_cr[1], m_cr[0]};
        end
    endtask

    // Capture the registered sig_* at each posedge (pre-edge), so the sample
    // taken at the idle posedge after a driven cycle holds that cycle's
    // intent. err_signal_conflict is captured separately (c_err), inside the
    // cycle task, because it is a combinational pulse gated on book_upd_valid
    // and has already deasserted by the idle posedge.
    reg        c_valid;
    reg [1:0]  c_slot;
    reg [7:0]  c_side;
    reg [31:0] c_price;
    reg [31:0] c_qty;
    reg        c_err = 1'b0;
    always @(posedge clk) begin
        c_valid = sig_valid;
        c_slot  = sig_slot;
        c_side  = sig_side;
        c_price = sig_price;
        c_qty   = sig_qty;
    end

    // Assert + release reset, clear the book model, restore config defaults,
    // align to a clean edge.
    task do_reset;
        begin
            @(negedge clk);
            book_upd_valid = 1'b0;
            rst_n = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            for (k = 0; k < 4; k = k + 1) begin
                mbp[k] = 32'd0; mbq[k] = 32'd0;
                map[k] = 32'd0; maq[k] = 32'd0;
                m_bv[k] = 1'b0; m_av[k] = 1'b0; m_cr[k] = 1'b0;
            end
            drive_bus;
            cfg_min_spread = 32'd2;
            cfg_imb_shift  = 2'd1;
            cfg_order_qty  = 32'd100;
            @(posedge clk);
            #1;
        end
    endtask

    // Drive one book_upd_valid cycle for `slot` with the given post-update
    // slot state (buv selects whether it is a book-modifying cycle at all).
    // On return, c_* holds the registered verdict of that cycle (sampled at
    // the idle posedge) and c_err holds that cycle's combinational conflict.
    task cycle;
        input [1:0]  slot;
        input        buv;
        input [31:0] bp, bq;
        input        bv;
        input [31:0] ap, aq;
        input        av, cr;
        begin
            mbp[slot] = bp; mbq[slot] = bq;
            map[slot] = ap; maq[slot] = aq;
            m_bv[slot] = bv; m_av[slot] = av; m_cr[slot] = cr;
            drive_bus;
            @(negedge clk);             // N0: present the event
            book_upd_valid = buv;
            applied_slot   = slot;
            @(posedge clk);             // P1: intent registered here
            #1;
            c_err = err_signal_conflict;
            @(negedge clk);             // N1: deassert
            book_upd_valid = 1'b0;
            @(posedge clk);             // P2: c_* captures the event verdict
            #1;
        end
    endtask

    // Compare the last driven cycle's verdict. slot/side/price/qty are only
    // meaningful while e_valid is expected high.
    task check;
        input integer  tag;
        input          e_valid;
        input [1:0]    e_slot;
        input [7:0]    e_side;
        input [31:0]   e_price;
        input [31:0]   e_qty;
        input          e_err;
        begin
            if (c_valid !== e_valid) begin
                $display("FAIL: T%0d: sig_valid=%b, expected %b", tag, c_valid, e_valid);
                fail = 1'b1;
            end
            if (c_err !== e_err) begin
                $display("FAIL: T%0d: err_signal_conflict=%b, expected %b", tag, c_err, e_err);
                fail = 1'b1;
            end
            if (e_valid) begin
                if (c_slot  !== e_slot)  begin $display("FAIL: T%0d: sig_slot=%0d, expected %0d",  tag, c_slot,  e_slot);  fail = 1'b1; end
                if (c_side  !== e_side)  begin $display("FAIL: T%0d: sig_side=%0d, expected %0d",  tag, c_side,  e_side);  fail = 1'b1; end
                if (c_price !== e_price) begin $display("FAIL: T%0d: sig_price=%0d, expected %0d", tag, c_price, e_price); fail = 1'b1; end
                if (c_qty   !== e_qty)   begin $display("FAIL: T%0d: sig_qty=%0d, expected %0d",   tag, c_qty,   e_qty);   fail = 1'b1; end
            end
        end
    endtask

    reg fail = 1'b0;

    initial begin
        // ---- reset: force a would-be buy during reset, then check the
        //      outputs are quiet after release (no stale intent). ----
        @(negedge clk);
        book_upd_valid = 1'b1;
        applied_slot   = 2'd0;
        mbp[0] = 32'd100; mbq[0] = 32'd100; m_bv[0] = 1'b1;
        map[0] = 32'd102; maq[0] = 32'd1;   m_av[0] = 1'b1; m_cr[0] = 1'b0;
        drive_bus;
        repeat (2) @(posedge clk);      // reset still low: nothing may latch
        @(negedge clk);
        book_upd_valid = 1'b0;          // benign inputs before release
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        for (k = 0; k < 4; k = k + 1) begin
            mbp[k] = 32'd0; mbq[k] = 32'd0;
            map[k] = 32'd0; maq[k] = 32'd0;
            m_bv[k] = 1'b0; m_av[k] = 1'b0; m_cr[k] = 1'b0;
        end
        drive_bus;
        @(posedge clk);
        #1;
        if (sig_valid || err_signal_conflict) begin
            $display("FAIL: reset: sig_valid/err_signal_conflict asserted out of reset");
            fail = 1'b1;
        end

        // ---- A: buy-side exact spread threshold (min_spread=2). ----
        //      bid 100 / 100, ask qty 1 (1<<1 = 2, so bid comfortably wins).
        cycle(2'd0, 1'b1, 32'd100, 32'd100, 1'b1, 32'd102, 32'd1, 1'b1, 1'b0);   // spread == 2
        check(1, 1'b1, 2'd0, SIDE_BID, 32'd102, 32'd100, 1'b0);
        cycle(2'd0, 1'b1, 32'd100, 32'd100, 1'b1, 32'd101, 32'd1, 1'b1, 1'b0);   // spread == 1
        check(2, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 1'b0);
        cycle(2'd0, 1'b1, 32'd100, 32'd100, 1'b1, 32'd103, 32'd1, 1'b1, 1'b0);   // spread == 3
        check(3, 1'b1, 2'd0, SIDE_BID, 32'd103, 32'd100, 1'b0);

        // ---- B: sell-side exact spread threshold (mirror of A). ----
        //      ask 100 qty, bid qty 1 (bid<<1 = 2, so ask comfortably wins).
        cycle(2'd1, 1'b1, 32'd100, 32'd1, 1'b1, 32'd102, 32'd100, 1'b1, 1'b0);   // spread == 2
        check(4, 1'b1, 2'd1, SIDE_ASK, 32'd100, 32'd100, 1'b0);
        cycle(2'd1, 1'b1, 32'd100, 32'd1, 1'b1, 32'd101, 32'd100, 1'b1, 1'b0);   // spread == 1
        check(5, 1'b0, 2'd1, SIDE_ASK, 32'd0, 32'd0, 1'b0);
        cycle(2'd1, 1'b1, 32'd100, 32'd1, 1'b1, 32'd103, 32'd100, 1'b1, 1'b0);   // spread == 3
        check(6, 1'b1, 2'd1, SIDE_ASK, 32'd100, 32'd100, 1'b0);

        // ---- C: strict-inequality imbalance boundary, both sides. ----
        //      imb_shift=1: boundary is (winner_qty == loser_qty << 1).
        cycle(2'd0, 1'b1, 32'd100, 32'd2,  1'b1, 32'd102, 32'd1, 1'b1, 1'b0);   // buy: 2 == 1<<1 -> NOT >
        check(7, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 1'b0);
        cycle(2'd0, 1'b1, 32'd100, 32'd3,  1'b1, 32'd102, 32'd1, 1'b1, 1'b0);   // buy: 3 == (1<<1)+1 -> fires
        check(8, 1'b1, 2'd0, SIDE_BID, 32'd102, 32'd100, 1'b0);
        cycle(2'd1, 1'b1, 32'd100, 32'd1,  1'b1, 32'd102, 32'd2, 1'b1, 1'b0);   // sell: 2 == 1<<1 -> NOT >
        check(9, 1'b0, 2'd1, SIDE_ASK, 32'd0, 32'd0, 1'b0);
        cycle(2'd1, 1'b1, 32'd100, 32'd1,  1'b1, 32'd102, 32'd3, 1'b1, 1'b0);   // sell: 3 == (1<<1)+1 -> fires
        check(10, 1'b1, 2'd1, SIDE_ASK, 32'd100, 32'd100, 1'b0);

        // ---- D: crossed book blocks both regardless of qty ratio. ----
        //      bid 101 > ask 100 (crossed). bid qty overwhelmingly favors a
        //      buy; a naive spread-only implementation would mis-fire here
        //      because the wrapped 32-bit spread subtraction (100 - 101)
        //      underflows to an enormous value (S2.2). Expect no signal AND
        //      no conflict.
        cycle(2'd0, 1'b1, 32'd101, 32'd100, 1'b1, 32'd100, 32'd1, 1'b1, 1'b1);
        check(11, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 1'b0);
        //      same crossed book, ask qty now overwhelmingly favors a sell.
        cycle(2'd0, 1'b1, 32'd101, 32'd1, 1'b1, 32'd100, 32'd100, 1'b1, 1'b1);
        check(12, 1'b0, 2'd0, SIDE_ASK, 32'd0, 32'd0, 1'b0);

        // ---- E: either side invalid blocks both. ----
        cycle(2'd0, 1'b1, 32'd100, 32'd100, 1'b0, 32'd102, 32'd1, 1'b1, 1'b0);  // bid invalid
        check(13, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 1'b0);
        cycle(2'd0, 1'b1, 32'd100, 32'd100, 1'b1, 32'd102, 32'd1, 1'b0, 1'b0);  // ask invalid
        check(14, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 1'b0);

        // ---- F: D15 overflow-safety regression. bid_qty = ask_qty =
        //      0x80000000, imb_shift=1: a plain 32-bit shift wraps BOTH
        //      quantities to 0, so both qty conditions would read true and
        //      fire a spurious conflict. The wide-precision fix must produce
        //      no signal and no conflict. ----
        cycle(2'd0, 1'b1, 32'd100, 32'h80000000, 1'b1, 32'd102, 32'h80000000, 1'b1, 1'b0);
        check(15, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 1'b0);

        // ---- G: FR-37 defensive conflict logic, exercised via force. ----
        //      Once S2.4's wide-precision arithmetic is in place, buy_ok AND
        //      sell_ok is mathematically impossible for any honest 32-bit
        //      bid_qty/ask_qty combination -- so this branch cannot be
        //      reached through ordinary stimulus, and forcing the DUT's
        //      internal wires is the ONLY way to exercise it. This tests the
        //      defensive logic in isolation; it is not a realistic stimulus.
        @(negedge clk);
        mbp[0] = 32'd100; mbq[0] = 32'd100; m_bv[0] = 1'b1;
        map[0] = 32'd102; maq[0] = 32'd1;   m_av[0] = 1'b1; m_cr[0] = 1'b0;
        drive_bus;
        @(negedge clk);
        book_upd_valid = 1'b1;
        applied_slot   = 2'd0;
        force dut.buy_ok  = 1'b1;   // make the (provably unreachable) both-true
        force dut.sell_ok = 1'b1;   // state happen anyway
        @(posedge clk);
        #1;
        c_err = err_signal_conflict;
        @(negedge clk);
        book_upd_valid = 1'b0;
        release dut.buy_ok;
        release dut.sell_ok;
        @(posedge clk);
        #1;
        check(16, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 1'b1);   // conflict pulses, intent suppressed
        cycle(2'd0, 1'b1, 32'd100, 32'd100, 1'b1, 32'd102, 32'd1, 1'b1, 1'b0);  // back to normal after release
        check(17, 1'b1, 2'd0, SIDE_BID, 32'd102, 32'd100, 1'b0);

        // ---- H: book_upd_valid=0 with otherwise signal-worthy inputs: no
        //      sig_valid that cycle (H1) or the one after (H2). ----
        cycle(2'd0, 1'b0, 32'd100, 32'd100, 1'b1, 32'd102, 32'd1, 1'b1, 1'b0);
        check(18, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 1'b0);
        cycle(2'd0, 1'b0, 32'd100, 32'd100, 1'b1, 32'd102, 32'd1, 1'b1, 1'b0);
        check(19, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 1'b0);

        // ---- I: independent slots, interleaved buy/sell events. ----
        cycle(2'd2, 1'b1, 32'd200, 32'd60, 1'b1, 32'd205, 32'd1, 1'b1, 1'b0);   // buy on slot 2
        check(20, 1'b1, 2'd2, SIDE_BID, 32'd205, 32'd100, 1'b0);
        cycle(2'd3, 1'b1, 32'd300, 32'd1, 1'b1, 32'd302, 32'd40, 1'b1, 1'b0);   // sell on slot 3
        check(21, 1'b1, 2'd3, SIDE_ASK, 32'd300, 32'd100, 1'b0);
        cycle(2'd2, 1'b1, 32'd200, 32'd1, 1'b1, 32'd205, 32'd40, 1'b1, 1'b0);   // sell on slot 2
        check(22, 1'b1, 2'd2, SIDE_ASK, 32'd200, 32'd100, 1'b0);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
