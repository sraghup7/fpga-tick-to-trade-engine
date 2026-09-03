`timescale 1ns / 1ps

// Self-checking testbench for rtl/symbol_filter.v (master spec S3.1 [E],
// FR-7; contract docs/contracts/symbol_filter.md S3).
//
// Icarus:
//   iverilog -g2001 -Wall -o symbol_filter_tb.vvp rtl/symbol_filter.v tb/tb_symbol_filter.v
//   vvp symbol_filter_tb.vvp
//
// symbol_filter is a pure combinational gate over msg_valid/msg_symbol_id
// vs. the four cfg_symbol_*/cfg_symbol_en slots (contract S2.3) -- so this
// tb samples the DUT's verdict in the same cycle it drives a message, never
// a cycle later. Each directed case in the contract S3 is exercised:
//
//   (1) msg_valid=0     outputs stay 0 while msg_symbol_id cycles through
//                       watched and unwatched values (the stale-register
//                       trap: md_parser's msg_symbol_id holds whatever the
//                       last message decoded to)
//   (2) default config  symbols 1,2,3,4 match slots 0,1,2,3; filt_dropped
//                       never pulses (CSR power-on defaults 0x08-0x18)
//   (3) unwatched sym   e.g. 99 -> filt_dropped pulses exactly one cycle,
//                       filt_valid stays 0
//   (4) disabled slot   SYMBOL_EN bit for an otherwise-matching slot cleared
//                       -> treated as unwatched, not matched; re-enabling
//                       restores the match (clean recovery)
//   (5) duplicate cfg   two enabled slots holding the same symbol_id ->
//                       lowest-numbered slot wins
//   (6) back-to-back    >=8 messages, mixed matched/dropped, no gap cycles
//                       between them (proves there is no state or lag)
//
// Drives msg_valid/msg_symbol_id/cfg_* directly -- the md_parser-shaped
// boundary this module's contract is written against -- rather than
// instantiating md_parser.v (docs/contracts/md_parser.md S2.6).
//
// Verilog-2001 only.

module tb_symbol_filter;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg        msg_valid = 1'b0;
    reg [7:0]  msg_symbol_id = 8'd0;

    reg [7:0]  cfg_symbol_0 = 8'd1;
    reg [7:0]  cfg_symbol_1 = 8'd2;
    reg [7:0]  cfg_symbol_2 = 8'd3;
    reg [7:0]  cfg_symbol_3 = 8'd4;
    reg [3:0]  cfg_symbol_en = 4'hF;

    wire       filt_valid;
    wire [1:0] filt_slot;
    wire       filt_dropped;

    symbol_filter dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .msg_valid     (msg_valid),
        .msg_symbol_id (msg_symbol_id),
        .cfg_symbol_0  (cfg_symbol_0),
        .cfg_symbol_1  (cfg_symbol_1),
        .cfg_symbol_2  (cfg_symbol_2),
        .cfg_symbol_3  (cfg_symbol_3),
        .cfg_symbol_en (cfg_symbol_en),
        .filt_valid    (filt_valid),
        .filt_slot     (filt_slot),
        .filt_dropped  (filt_dropped)
    );

    reg     fail = 1'b0;
    integer msg_cnt = 0;

    // Load a fresh config during a low (msg_valid==0) half-cycle.
    task set_cfg;
        input [7:0] s0;
        input [7:0] s1;
        input [7:0] s2;
        input [7:0] s3;
        input [3:0] en;
        begin
            @(negedge clk);
            cfg_symbol_0  = s0;
            cfg_symbol_1  = s1;
            cfg_symbol_2  = s2;
            cfg_symbol_3  = s3;
            cfg_symbol_en = en;
        end
    endtask

    // Drive one message (msg_valid high, symbol `sym`) for exactly one clock
    // cycle and check the combinational verdict sampled in that cycle.
    // Fails the run (with a "what vs. expected" message) on any mismatch.
    task msg_tick;
        input [7:0]  sym;
        input        exp_valid;
        input [1:0]  exp_slot;
        input        exp_dropped;
        begin
            @(negedge clk);
            msg_valid     = 1'b1;
            msg_symbol_id = sym;
            @(posedge clk);
            #1;
            msg_cnt = msg_cnt + 1;
            if (filt_valid !== exp_valid) begin
                $display("FAIL: msg %0d sym=%0d: filt_valid=%b, expected %b",
                         msg_cnt, sym, filt_valid, exp_valid);
                fail = 1'b1;
            end
            if (exp_valid && (filt_slot !== exp_slot)) begin
                $display("FAIL: msg %0d sym=%0d: filt_slot=%0d, expected %0d",
                         msg_cnt, sym, filt_slot, exp_slot);
                fail = 1'b1;
            end
            if (filt_dropped !== exp_dropped) begin
                $display("FAIL: msg %0d sym=%0d: filt_dropped=%b, expected %b",
                         msg_cnt, sym, filt_dropped, exp_dropped);
                fail = 1'b1;
            end
        end
    endtask

    // End the just-driven message's pulse and require the module to forget
    // it: msg_valid low, msg_symbol_id left stale at the sent symbol, and
    // both outputs must be 0 that cycle (proves no stuck state, no lag, and
    // that the match logic is really gated on msg_valid).
    task end_pulse;
        begin
            @(negedge clk);
            msg_valid = 1'b0;
            @(posedge clk);
            #1;
            if (filt_valid !== 1'b0) begin
                $display("FAIL: after sym=%0d pulse ends: filt_valid=%b, expected 0",
                         msg_symbol_id, filt_valid);
                fail = 1'b1;
            end
            if (filt_dropped !== 1'b0) begin
                $display("FAIL: after sym=%0d pulse ends: filt_dropped=%b, expected 0",
                         msg_symbol_id, filt_dropped);
                fail = 1'b1;
            end
        end
    endtask

    initial begin
        // Power-on defaults match the CSR map (S9: SYMBOL_0..3 = 1,2,3,4 @
        // 0x08-0x14, SYMBOL_EN = 0xF @ 0x18); set_cfg refreshes them before
        // every phase so no phase depends on leftovers from a prior one.
        rst_n = 1'b0;
        #20;
        rst_n = 1'b1;
        #20;

        // ---- (1) msg_valid=0: both outputs stay 0 whatever msg_symbol_id
        //      holds (contract S3; md_parser's field registers go stale) ----
        @(negedge clk);
        msg_valid     = 1'b0;
        msg_symbol_id = 8'd1;            // watched (slot 0 under defaults)
        @(posedge clk);
        #1;
        if (filt_valid || filt_dropped) begin
            $display("FAIL: msg_valid=0, watched sym=%0d: filt_valid=%b filt_dropped=%b, expected 0/0",
                     msg_symbol_id, filt_valid, filt_dropped);
            fail = 1'b1;
        end
        @(negedge clk);
        msg_symbol_id = 8'd99;           // unwatched
        @(posedge clk);
        #1;
        if (filt_valid || filt_dropped) begin
            $display("FAIL: msg_valid=0, unwatched sym=%0d: filt_valid=%b filt_dropped=%b, expected 0/0",
                     msg_symbol_id, filt_valid, filt_dropped);
            fail = 1'b1;
        end
        @(negedge clk);
        msg_symbol_id = 8'd3;            // watched (slot 2 under defaults)
        @(posedge clk);
        #1;
        if (filt_valid || filt_dropped) begin
            $display("FAIL: msg_valid=0, watched sym=%0d: filt_valid=%b filt_dropped=%b, expected 0/0",
                     msg_symbol_id, filt_valid, filt_dropped);
            fail = 1'b1;
        end

        // ---- (2) default config: symbols 1,2,3,4 hit slots 0,1,2,3 ----
        set_cfg(8'd1, 8'd2, 8'd3, 8'd4, 4'hF);
        msg_tick(8'd1, 1'b1, 2'd0, 1'b0);
        end_pulse;
        msg_tick(8'd2, 1'b1, 2'd1, 1'b0);
        end_pulse;
        msg_tick(8'd3, 1'b1, 2'd2, 1'b0);
        end_pulse;
        msg_tick(8'd4, 1'b1, 2'd3, 1'b0);
        end_pulse;

        // ---- (3) unwatched symbol: filt_dropped pulses exactly once ----
        msg_tick(8'd99, 1'b0, 2'd0, 1'b1);
        end_pulse;

        // ---- (4) disabled slot: SYMBOL_EN bit cleared beats the ID match.
        //      Slot 2's cfg_symbol_2==3 still equals the incoming symbol, but
        //      with its enable bit low it must be treated as unwatched. ----
        set_cfg(8'd1, 8'd2, 8'd3, 8'd4, 4'b1011);   // slot 2 disabled
        msg_tick(8'd3, 1'b0, 2'd0, 1'b1);
        end_pulse;
        // re-enable: same symbol matches slot 2 again (clean recovery)
        set_cfg(8'd1, 8'd2, 8'd3, 8'd4, 4'hF);
        msg_tick(8'd3, 1'b1, 2'd2, 1'b0);
        end_pulse;

        // ---- (5) duplicate configured ID: lowest-numbered slot wins ----
        set_cfg(8'd7, 8'd2, 8'd7, 8'd4, 4'hF);      // slots 0 and 2 both = 7
        msg_tick(8'd7, 1'b1, 2'd0, 1'b0);           // slot 0, not slot 2
        end_pulse;

        // ---- (6) back-to-back, mixed watched/unwatched, no gap cycles ----
        set_cfg(8'd1, 8'd2, 8'd3, 8'd4, 4'hF);
        msg_tick(8'd1,  1'b1, 2'd0, 1'b0);  // m1  matched, slot 0
        msg_tick(8'd99, 1'b0, 2'd0, 1'b1);  // m2  dropped
        msg_tick(8'd4,  1'b1, 2'd3, 1'b0);  // m3  matched, slot 3
        msg_tick(8'd2,  1'b1, 2'd1, 1'b0);  // m4  matched, slot 1
        msg_tick(8'd77, 1'b0, 2'd0, 1'b1);  // m5  dropped
        msg_tick(8'd3,  1'b1, 2'd2, 1'b0);  // m6  matched, slot 2
        msg_tick(8'd88, 1'b0, 2'd0, 1'b1);  // m7  dropped
        msg_tick(8'd1,  1'b1, 2'd0, 1'b0);  // m8  matched, slot 0 again
        end_pulse;

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
