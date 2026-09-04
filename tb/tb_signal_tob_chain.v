`timescale 1ns / 1ps

// Self-checking cross-module regression chaining the REAL rtl/tob_engine.v
// and rtl/signal_engine.v together (no tob_top.v, no other module).
//
// Icarus:
//   iverilog -g2001 -Wall -o chain_tb.vvp rtl/tob_engine.v rtl/signal_engine.v tb/tb_signal_tob_chain.v
//   vvp chain_tb.vvp
//
// Why this testbench exists (D23, docs/design_decisions.md; contract
// docs/contracts/tob_engine_signal_patch.md S2.3): every module-level test
// drives its DUT's inputs independently of what the real upstream module
// produces, which is exactly why signal_engine.v reading tob_engine.v's
// book bus one message stale was never caught -- tb_signal_engine.v sets
// the book to "already looks tradeable" and THEN pulses book_upd_valid,
// the shape that makes the stale-read bug invisible. This file drives
// message-shaped stimulus into tob_engine.v's own inputs and checks
// signal_engine.v's sig_* against hand-computed expectations that match
// sim/golden_model.py's post-update semantics.
//
// Expectation semantics: the golden model updates the book and then, in
// the same function call, evaluates buy_ok/sell_ok on the post-update
// state, for book-modifying messages only (FR-40). signal_engine.v reads
// tob_engine.v's new next_* scalar ports (combinational post-update state
// of the applied slot) and registers its intent one cycle after
// book_upd_valid. Each `fire` below drives one message cycle (book
// commits + intent registers at its posedge) followed by one idle cycle;
// on return the c_* capture regs (sampled pre-edge at the idle posedge)
// hold that message's registered intent.
//
// Config mirrors the S9 CSR defaults and tb_signal_engine.v:
// min_spread = 2, imb_shift = 1, order_qty = 100. Wire-format side
// encoding: SIDE_BID=0x00 (buy at the ask), SIDE_ASK=0x01 (sell at the
// bid).
//
// Verilog-2001 only.

module tb_signal_tob_chain;

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

    // ---- signal_engine.v config ----
    reg [31:0] cfg_min_spread = 32'd2;
    reg [1:0]  cfg_imb_shift  = 2'd1;
    reg [31:0] cfg_order_qty  = 32'd100;

    // ---- module boundary wires ----
    wire [127:0] bid_price, bid_qty, ask_price, ask_qty;
    wire [3:0]   bid_valid, ask_valid, crossed;
    wire         book_upd_valid;
    wire [1:0]   applied_slot;
    wire         sig_valid;
    wire [1:0]   sig_slot;
    wire [7:0]   sig_side;
    wire [31:0]  sig_price;
    wire [31:0]  sig_qty;

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
        .applied_slot         (applied_slot),
        .book_upd_valid       (book_upd_valid),
        .cnt_book_clear_pulse (),
        .cnt_trades_pulse     (),
        .cnt_heartbeats_pulse (),
        .cnt_crossed_pulse    (),
        .bid_price            (bid_price),
        .bid_qty              (bid_qty),
        .bid_valid            (bid_valid),
        .ask_price            (ask_price),
        .ask_qty              (ask_qty),
        .ask_valid            (ask_valid),
        .crossed              (crossed)
    );

    signal_engine u_sig (
        .clk                (clk),
        .rst_n              (rst_n),
        .book_upd_valid     (book_upd_valid),
        .applied_slot       (applied_slot),
        .next_bid_price     (u_tob.next_bid_price),
        .next_bid_qty       (u_tob.next_bid_qty),
        .next_bid_valid     (u_tob.next_bid_valid),
        .next_ask_price     (u_tob.next_ask_price),
        .next_ask_qty       (u_tob.next_ask_qty),
        .next_ask_valid     (u_tob.next_ask_valid),
        .next_crossed       (u_tob.next_crossed),
        .cfg_min_spread     (cfg_min_spread),
        .cfg_imb_shift      (cfg_imb_shift),
        .cfg_order_qty      (cfg_order_qty),
        .sig_valid          (sig_valid),
        .sig_slot           (sig_slot),
        .sig_side           (sig_side),
        .sig_price          (sig_price),
        .sig_qty            (sig_qty),
        .err_signal_conflict ()
    );

    // Capture sig_* at each posedge (pre-edge), so the sample taken at the
    // idle posedge after a driven message cycle holds that message's
    // registered intent (same convention as tb_signal_engine.v).
    reg        c_valid;
    reg [1:0]  c_slot;
    reg [7:0]  c_side;
    reg [31:0] c_price;
    reg [31:0] c_qty;
    always @(posedge clk) begin
        c_valid = sig_valid;
        c_slot  = sig_slot;
        c_side  = sig_side;
        c_price = sig_price;
        c_qty   = sig_qty;
    end

    reg     fail = 1'b0;
    integer tc = 0;

    // Drive one message for exactly one cycle (commit + register intent at
    // its posedge), then one idle cycle. On return c_* holds that message's
    // verdict.
    task fire;
        input [7:0]  mt;
        input [7:0]  ms;
        input [31:0] mp;
        input [31:0] mq;
        input [1:0]  fs;
        begin
            @(negedge clk);                     // N0: present the message
            msg_type    = mt;
            msg_side    = ms;
            msg_price   = mp;
            msg_quantity = mq;
            filt_valid  = 1'b1;
            filt_slot   = fs;
            err_seq_dup = 1'b0;
            @(posedge clk);                     // P1: book commits, intent registers
            #1;
            @(negedge clk);                     // N1: deassert
            filt_valid  = 1'b0;
            err_seq_dup = 1'b0;
            @(posedge clk);                     // P2: c_* captures the verdict
            #1;
        end
    endtask

    // Compare the last fired message's verdict against hand-computed
    // expectations. slot/side/price/qty are only meaningful when e_valid is
    // high.
    task check;
        input integer  tag;
        input          e_valid;
        input [1:0]    e_slot;
        input [7:0]    e_side;
        input [31:0]   e_price;
        begin
            if (c_valid !== e_valid) begin
                $display("FAIL: msg %0d: sig_valid=%b, expected %b", tag, c_valid, e_valid);
                fail = 1'b1;
            end
            if (e_valid) begin
                if (c_slot  !== e_slot)  begin $display("FAIL: msg %0d: sig_slot=%0d, expected %0d", tag, c_slot,  e_slot);  fail = 1'b1; end
                if (c_side  !== e_side)  begin $display("FAIL: msg %0d: sig_side=%0d, expected %0d", tag, c_side,  e_side);  fail = 1'b1; end
                if (c_price !== e_price) begin $display("FAIL: msg %0d: sig_price=%0d, expected %0d", tag, c_price, e_price); fail = 1'b1; end
                if (c_qty   !== cfg_order_qty) begin $display("FAIL: msg %0d: sig_qty=%0d, expected %0d", tag, c_qty, cfg_order_qty); fail = 1'b1; end
            end
        end
    endtask

    initial begin
        // ---- reset ----
        @(negedge clk);
        rst_n = 1'b0;
        @(negedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (sig_valid) begin
            $display("FAIL: reset: sig_valid asserted out of reset");
            fail = 1'b1;
        end

        // ---- T1: the exact D23 reproduction, now expected to pass. bid
        //      QUOTE 1000/100 then ask QUOTE 1005/1 jointly satisfy buy_ok
        //      (spread 5 >= 2, bid_qty 100 > 1<<1). sig_valid must fire on
        //      the ask QUOTE's own cycle (registered one cycle later) --
        //      NOT on some third, redundant message as the buggy RTL
        //      required. This is the single most important case in this
        //      file. ----
        fire(QUOTE, SIDE_BID, 32'd1000, 32'd100, 2'd0);
        check(1, 1'b0, 2'd0, SIDE_BID, 32'd0);              // bid alone: no ask yet
        fire(QUOTE, SIDE_ASK, 32'd1005, 32'd1, 2'd0);
        check(2, 1'b1, 2'd0, SIDE_BID, 32'd1005);           // fires on the ask's own cycle
        // An unrelated following message must neither keep sig_valid high
        // nor re-fire it (the bug's signature was needing such a message).
        fire(HEARTBEAT, SIDE_BID, 32'd0, 32'd0, 2'd0);
        check(3, 1'b0, 2'd0, SIDE_BID, 32'd0);

        // ---- T2: mirror -- a QUOTE that completes an already-tradeable
        //      book from the OTHER side (ask first, then bid), sized for a
        //      sell. ask QUOTE 2005/100 then bid QUOTE 2000/1: sell_ok
        //      (spread 5 >= 2, ask_qty 100 > 1<<1), sell at the bid. ----
        fire(QUOTE, SIDE_ASK, 32'd2005, 32'd100, 2'd1);
        check(4, 1'b0, 2'd1, SIDE_ASK, 32'd0);              // ask alone: no bid yet
        fire(QUOTE, SIDE_BID, 32'd2000, 32'd1, 2'd1);
        check(5, 1'b1, 2'd1, SIDE_ASK, 32'd2000);           // sell at the bid

        // ---- T3: CLEAR. Slot 0 currently holds the tradeable T1 book
        //      (bid 1000/100, ask 1005/1) -- a stale-read signal_engine
        //      would see that pre-CLEAR book on the CLEAR's own cycle and
        //      fire a spurious second signal. Post-update next_* must read
        //      both valid bits 0 and fire nothing. ----
        fire(CLEAR, SIDE_BID, 32'd0, 32'd0, 2'd0);
        check(6, 1'b0, 2'd0, SIDE_BID, 32'd0);
        // CLEAR again on the now-empty book: still nothing.
        fire(CLEAR, SIDE_BID, 32'd0, 32'd0, 2'd0);
        check(7, 1'b0, 2'd0, SIDE_BID, 32'd0);

        // ---- T4: multiple symbols interleaved (tob_engine's 4 slots).
        //      Confirms a signal on slot 3 never fires from slot 0's book
        //      state and vice versa -- exercises applied_slot routing end
        //      to end through both real modules. ----
        fire(QUOTE, SIDE_ASK, 32'd4005, 32'd100, 2'd3);     // slot 3 ask alone
        check(8, 1'b0, 2'd3, SIDE_ASK, 32'd0);
        fire(QUOTE, SIDE_BID, 32'd1000, 32'd100, 2'd0);     // slot 0 bid alone
        check(9, 1'b0, 2'd0, SIDE_BID, 32'd0);
        fire(QUOTE, SIDE_BID, 32'd4000, 32'd1, 2'd3);       // completes slot 3 sell
        check(10, 1'b1, 2'd3, SIDE_ASK, 32'd4000);
        fire(QUOTE, SIDE_ASK, 32'd1005, 32'd1, 2'd0);       // completes slot 0 buy
        check(11, 1'b1, 2'd0, SIDE_BID, 32'd1005);

        // ---- T5: TRADE and HEARTBEAT between the two QUOTEs of a
        //      potential signal. They neither fire a signal themselves nor
        //      corrupt the eventual QUOTE-triggered one. Slot 1 still holds
        //      the T2 book -- clear it first so the build starts empty. ----
        fire(CLEAR, SIDE_BID, 32'd0, 32'd0, 2'd1);
        check(12, 1'b0, 2'd1, SIDE_BID, 32'd0);
        fire(QUOTE, SIDE_BID, 32'd5000, 32'd100, 2'd1);
        check(13, 1'b0, 2'd1, SIDE_BID, 32'd0);
        fire(TRADE, SIDE_ASK, 32'd0, 32'd0, 2'd1);
        check(14, 1'b0, 2'd1, SIDE_BID, 32'd0);             // TRADE fires nothing
        fire(HEARTBEAT, SIDE_BID, 32'd0, 32'd0, 2'd1);
        check(15, 1'b0, 2'd1, SIDE_BID, 32'd0);             // HEARTBEAT fires nothing
        fire(QUOTE, SIDE_ASK, 32'd5005, 32'd1, 2'd1);       // eventual QUOTE still fires
        check(16, 1'b1, 2'd1, SIDE_BID, 32'd5005);

        // ---- T6: no spurious signal across several fully-idle cycles. ----
        repeat (3) @(posedge clk);
        #1;
        if (sig_valid) begin
            $display("FAIL: T6: sig_valid asserted during idle cycles");
            fail = 1'b1;
        end

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
