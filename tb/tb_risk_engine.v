`timescale 1ns / 1ps

// Self-checking testbench for rtl/risk_engine.v (master spec S3.1 [I], S8,
// FR-41..48; contract docs/contracts/risk_engine.md S3).
//
// Icarus:
//   iverilog -g2001 -Wall -o risk_engine_tb.vvp rtl/risk_engine.v tb/tb_risk_engine.v
//   vvp risk_engine_tb.vvp
//
// risk_engine evaluates the nine gates combinationally on each sig_valid
// cycle and registers the order decision / reject_reason / one pulse per
// fired gate one cycle later (S2.7). It also owns kill_latched, the
// free-running token-bucket refill, per-slot staleness timestamps
// (last_update_cycle, refreshed on EVERY msg_applied) plus the D17
// pre-update pend_prev_cycle/pend_msg_cycle capture pair, and the signed
// per-slot position ledger.
//
// Timing convention (same shape as tb_signal_engine.v, extended by one
// cycle for the msg_applied->sig_valid pipeline alignment that S2.4
// depends on): every `intent` drives a message-arrival cycle (msg_applied
// high, book-state buses holding the post-update state), then a sig_valid
// cycle one posedge later, then an idle cycle. The c_* capture regs sample
// the registered outputs at each posedge, so after `intent` returns the
// last sample holds that intent's decision. cur_cycle is driven by a
// free-running counter (`cyc`) that advances one per clock edge, so
// msg-arrival cycle numbers = cur_cycle value at the msg_applied edge;
// only arrival *differences* matter (D17's stale check is a subtraction of
// two captured cycle values).
//
// Cases (contract S3; config is set per block and a do_reset follows, since
// reset samples cfg_token_max into the bucket):
//   reset    outputs quiet / kill_latched=0 / positions=0 out of reset, then
//            a favorable intent is accepted (proves token bucket is full)
//   A        T15 gate 0x02: sig_qty at/below/above cfg_max_order_qty
//   B        T16 gate 0x03: walk position to +/-1000 via accepted orders,
//            gate fires exactly when the next order would cross (both ways)
//   C        T17 gate 0x04: sig_price at band edge and one tick outside it,
//            both above and below mid (signed-subtraction footgun)
//   D        T18 gate 0x05 = port of sim/test_golden_model_handcase.py's
//            n3-n6 (D17 regression): fresh touch, silence > max_age -> stale
//            reject (5), fresh touch again -> accepted
//   E        T19 gate 0x08: drain the token bucket (2 back-to-back accepts),
//            next intent throttled, then idle past the refill period with no
//            message activity and a later intent succeeds (free-running refill)
//   F        T20 gate 0x01: kill asserted blocks everything (reason 1);
//            deassert alone does NOT clear; cfg_kill_clear does; assert wins
//            over a simultaneous clear
//   G        T21 FR-43 multi-gate: kill + oversized qty -> reason 1 (lowest
//            wins) but BOTH gate_kill_fired and gate_size_fired pulse
//   H        gates 0x06/0x07 isolation: seq_gap=1 blocks (6); crossed[slot]=1
//            blocks (7); each alone
//   I        D16 ML reduce path (n1/n2 port): adverse_risk=1, ml_action=1,
//            shift=1 -> order_qty=50 AND position updates by 50, not 100;
//            plus FR-48: gate 0x03's admission still uses the UNREDUCED qty
//   J        ML block path: adverse_risk=1, ml_action=0 -> reject reason 9
//   K        sig_valid=0: order_valid stays low regardless of other inputs
//   L        strong reset: populated kill/position state fully clears
//
// On any mismatch a FAIL line names the case/field and expected vs actual;
// final PASS/FAIL. Verilog-2001 only.

module tb_risk_engine;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    // ---- inputs ----
    reg        rst_n = 1'b0;
    reg        sig_valid = 1'b0;
    reg [1:0]  sig_slot = 2'd0;
    reg [7:0]  sig_side = 8'd0;
    reg [31:0] sig_price = 32'd0;
    reg [31:0] sig_qty = 32'd0;
    reg        msg_applied = 1'b0;
    reg [1:0]  applied_slot = 2'd0;
    reg [127:0] b_bid_price, b_ask_price;
    reg [3:0]  b_crossed;
    reg        seq_gap = 1'b0;
    reg        adverse_risk = 1'b0;
    reg        kill_sw_n = 1'b1;
    reg [31:0] cfg_max_order_qty = 32'd500;
    reg [31:0] cfg_max_position  = 32'd1000;
    reg [31:0] cfg_price_band    = 32'd50;
    reg [31:0] cfg_max_age       = 32'd1250000;
    reg [31:0] cfg_token_max     = 32'd8;
    reg [31:0] cfg_token_refill_cycles = 32'd12500;
    reg        cfg_ml_action = 1'b0;
    reg [3:0]  cfg_ml_reduce_shift = 4'd0;
    reg        cfg_kill_clear = 1'b0;

    // free-running cycle counter for cur_cycle
    reg [31:0] cyc = 32'd0;
    always @(posedge clk) cyc <= cyc + 32'd1;
    wire [31:0] cur_cycle;
    assign cur_cycle = cyc;

    // ---- outputs ----
    wire        order_valid;
    wire [1:0]  order_slot;
    wire [7:0]  order_side;
    wire [31:0] order_price;
    wire [31:0] order_qty;
    wire [7:0]  reject_reason;
    wire        gate_kill_fired;
    wire        gate_size_fired;
    wire        gate_position_fired;
    wire        gate_band_fired;
    wire        gate_stale_fired;
    wire        gate_seqgap_fired;
    wire        gate_crossed_fired;
    wire        gate_throttle_fired;
    wire        gate_ml_fired;
    wire        kill_latched;
    wire [127:0] position;

    localparam [7:0] SIDE_BID = 8'h00;
    localparam [7:0] SIDE_ASK = 8'h01;

    risk_engine dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .sig_valid            (sig_valid),
        .sig_slot             (sig_slot),
        .sig_side             (sig_side),
        .sig_price            (sig_price),
        .sig_qty              (sig_qty),
        .msg_applied          (msg_applied),
        .applied_slot         (applied_slot),
        .bid_price            (b_bid_price),
        .ask_price            (b_ask_price),
        .crossed              (b_crossed),
        .seq_gap              (seq_gap),
        .adverse_risk         (adverse_risk),
        .cur_cycle            (cur_cycle),
        .kill_sw_n            (kill_sw_n),
        .cfg_max_order_qty    (cfg_max_order_qty),
        .cfg_max_position     (cfg_max_position),
        .cfg_price_band       (cfg_price_band),
        .cfg_max_age          (cfg_max_age),
        .cfg_token_max        (cfg_token_max),
        .cfg_token_refill_cycles (cfg_token_refill_cycles),
        .cfg_ml_action        (cfg_ml_action),
        .cfg_ml_reduce_shift  (cfg_ml_reduce_shift),
        .cfg_kill_clear       (cfg_kill_clear),
        .order_valid          (order_valid),
        .order_slot           (order_slot),
        .order_side           (order_side),
        .order_price          (order_price),
        .order_qty            (order_qty),
        .reject_reason        (reject_reason),
        .gate_kill_fired      (gate_kill_fired),
        .gate_size_fired      (gate_size_fired),
        .gate_position_fired  (gate_position_fired),
        .gate_band_fired      (gate_band_fired),
        .gate_stale_fired     (gate_stale_fired),
        .gate_seqgap_fired    (gate_seqgap_fired),
        .gate_crossed_fired   (gate_crossed_fired),
        .gate_throttle_fired  (gate_throttle_fired),
        .gate_ml_fired        (gate_ml_fired),
        .kill_latched         (kill_latched),
        .position             (position)
    );

    // ---- per-slot book model (bid/ask price + crossed; risk reads no qty) ----
    reg [31:0] mbp [0:3];
    reg [31:0] map [0:3];
    reg        m_cr [0:3];
    integer k;

    task drive_bus;
        begin
            b_bid_price = {mbp[3], mbp[2], mbp[1], mbp[0]};
            b_ask_price = {map[3], map[2], map[1], map[0]};
            b_crossed   = {m_cr[3], m_cr[2], m_cr[1], m_cr[0]};
        end
    endtask

    // ---- capture registered outputs at each posedge (pre-edge), so the
    //      sample taken at the idle posedge after an intent holds its
    //      decision. gate vector bit i: 0=kill 1=size 2=position 3=band
    //      4=stale 5=seqgap 6=crossed 7=throttle 8=ml. ----
    reg        c_ov;
    reg [1:0]  c_slot;
    reg [7:0]  c_side;
    reg [31:0] c_price;
    reg [31:0] c_qty;
    reg [7:0]  c_reason;
    reg [8:0]  c_gv;
    always @(posedge clk) begin
        c_ov     = order_valid;
        c_slot   = order_slot;
        c_side   = order_side;
        c_price  = order_price;
        c_qty    = order_qty;
        c_reason = reject_reason;
        c_gv     = {gate_ml_fired, gate_throttle_fired, gate_crossed_fired,
                    gate_seqgap_fired, gate_stale_fired, gate_band_fired,
                    gate_position_fired, gate_size_fired, gate_kill_fired};
    end

    // Assert + release reset with the current cfg_* values; clear the book
    // model and all level inputs.
    task do_reset;
        begin
            @(negedge clk);
            sig_valid = 1'b0; msg_applied = 1'b0;
            seq_gap = 1'b0; adverse_risk = 1'b0;
            kill_sw_n = 1'b1; cfg_kill_clear = 1'b0;
            for (k = 0; k < 4; k = k + 1) begin
                mbp[k] = 32'd0; map[k] = 32'd0; m_cr[k] = 1'b0;
            end
            drive_bus;
            rst_n = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    // One pipeline-aligned message event on `slot`: a msg_applied cycle
    // (book bus held to the post-update bp/ap/cr for that slot), then one
    // sig_valid cycle (sig_on), then an idle cycle. On return, c_* holds the
    // decision registered at the sig cycle. If sig_on is 0 the msg simply
    // refreshes staleness and produces nothing.
    task intent;
        input [1:0]  slot;
        input        msg_on;
        input        sig_on;
        input [31:0] bp, ap;
        input        cr;
        input [7:0]  side;
        input [31:0] oprice;
        input [31:0] oqty;
        input        sg;
        input        adv;
        begin
            mbp[slot] = bp; map[slot] = ap; m_cr[slot] = cr;
            drive_bus;
            @(negedge clk);             // N0: message-arrival cycle
            msg_applied  = msg_on;
            applied_slot = slot;
            sig_valid    = 1'b0;
            sig_slot     = slot;
            sig_side     = side;
            sig_price    = oprice;
            sig_qty      = oqty;
            seq_gap      = sg;
            adverse_risk = adv;
            @(posedge clk);             // P1: arrival (staleness capture)
            #1;
            @(negedge clk);             // N1: signal cycle
            msg_applied  = 1'b0;
            sig_valid    = sig_on;
            @(posedge clk);             // P2: decision registered
            #1;
            @(negedge clk);             // N2: idle
            sig_valid    = 1'b0;
            seq_gap      = 1'b0;
            adverse_risk = 1'b0;
            @(posedge clk);             // P3: c_* samples the decision
            #1;
        end
    endtask

    // Run N clock cycles with everything deasserted (free-running refill
    // advances; used for D17 spacing and T19's quiet refill period).
    task idle_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
            #1;
        end
    endtask

    // ---- assertions ----
    reg fail = 1'b0;

    task ck;
        input integer tag;
        input        e_ov;
        input [1:0]  e_slot;
        input [7:0]  e_side;
        input [31:0] e_price;
        input [31:0] e_qty;
        input [7:0]  e_reason;
        input [8:0]  e_gv;
        begin
            if (c_ov !== e_ov) begin
                $display("FAIL: T%0d: order_valid=%b, expected %b", tag, c_ov, e_ov);
                fail = 1'b1;
            end
            if (c_reason !== e_reason) begin
                $display("FAIL: T%0d: reject_reason=%0d, expected %0d", tag, c_reason, e_reason);
                fail = 1'b1;
            end
            if (c_gv !== e_gv) begin
                $display("FAIL: T%0d: gate vector=%b, expected %b", tag, c_gv, e_gv);
                fail = 1'b1;
            end
            if (e_ov) begin
                if (c_slot  !== e_slot)  begin $display("FAIL: T%0d: order_slot=%0d, expected %0d",  tag, c_slot,  e_slot);  fail = 1'b1; end
                if (c_side  !== e_side)  begin $display("FAIL: T%0d: order_side=%0d, expected %0d",  tag, c_side,  e_side);  fail = 1'b1; end
                if (c_price !== e_price) begin $display("FAIL: T%0d: order_price=%0d, expected %0d", tag, c_price, e_price); fail = 1'b1; end
                if (c_qty   !== e_qty)   begin $display("FAIL: T%0d: order_qty=%0d, expected %0d",   tag, c_qty,   e_qty);   fail = 1'b1; end
            end
        end
    endtask

    // Assert slot s's position equals exp (signed).
    task ck_pos;
        input integer tag;
        input [1:0] s;
        input integer exp;
        begin
            if ($signed(position[s*32 +: 32]) !== exp) begin
                $display("FAIL: T%0d: position[%0d]=%0d, expected %0d", tag, s,
                         $signed(position[s*32 +: 32]), exp);
                fail = 1'b1;
            end
        end
    endtask

    integer i;
    integer tb_pos;

    initial begin
        // ================= reset sanity =================
        do_reset;
        if (kill_latched !== 1'b0) begin $display("FAIL: reset: kill_latched=%b, expected 0", kill_latched); fail = 1'b1; end
        ck_pos(0, 2'd0, 0); ck_pos(0, 2'd1, 0); ck_pos(0, 2'd2, 0); ck_pos(0, 2'd3, 0);
        // a favorable intent right out of reset is accepted (bucket is full)
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(1, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);
        ck_pos(1, 2'd0, 100);

        // ================= A: gate 0x02 size (T15) =================
        cfg_max_order_qty = 32'd500;
        cfg_max_position  = 32'd100000;   // isolate size: accepted orders above
                                          // accumulate position (499+500+...)
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd499, 1'b0, 1'b0);
        ck(2, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd499, 8'd0, 9'b000000000);
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd500, 1'b0, 1'b0);
        ck(3, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd500, 8'd0, 9'b000000000);   // at limit: not >
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd501, 1'b0, 1'b0);
        ck(4, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd501, 8'd2, 9'b000000010);   // above: fires

        // ================= B: gate 0x03 position walk (T16) =================
        cfg_max_position = 32'd1000;
        cfg_token_max    = 32'd100;    // room for the whole walk, no refill
        cfg_token_refill_cycles = 32'd100000;
        do_reset;
        tb_pos = 0;
        // 10 buys from 0: 100..900 accepted; the 1000 one is == limit, accepted
        for (i = 0; i < 10; i = i + 1) begin
            intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
            tb_pos = tb_pos + 100;
            ck(10, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);
            ck_pos(10, 2'd0, tb_pos);
        end
        // next buy would cross +1000 -> reject, position unchanged
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(11, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd3, 9'b000000100);
        ck_pos(11, 2'd0, tb_pos);
        // 20 sells from +1000: reach -1000 exactly (each |prospective|<=1000)
        for (i = 0; i < 20; i = i + 1) begin
            intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_ASK, 32'd1000, 32'd100, 1'b0, 1'b0);
            tb_pos = tb_pos - 100;
            ck(12, 1'b1, 2'd0, SIDE_ASK, 32'd1000, 32'd100, 8'd0, 9'b000000000);
            ck_pos(12, 2'd0, tb_pos);
        end
        // next sell would cross -1000 -> reject
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_ASK, 32'd1000, 32'd100, 1'b0, 1'b0);
        ck(13, 1'b0, 2'd0, SIDE_ASK, 32'd1000, 32'd100, 8'd3, 9'b000000100);
        ck_pos(13, 2'd0, tb_pos);

        // ================= C: gate 0x04 price band (T17) =================
        // book bid=1001/ask=1100 -> mid=(2101)>>1=1050, band=50. Order prices
        // at exactly 50 either side of mid are NOT > band; one tick further fires.
        cfg_price_band = 32'd50;
        cfg_token_max  = 32'd8;
        cfg_token_refill_cycles = 32'd12500;
        cfg_max_position = 32'd1000;
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1001, 32'd1100, 1'b0, SIDE_BID, 32'd1100, 32'd100, 1'b0, 1'b0);
        ck(20, 1'b1, 2'd0, SIDE_BID, 32'd1100, 32'd100, 8'd0, 9'b000000000);   // mid+50 == edge
        intent(2'd0, 1'b1, 1'b1, 32'd1001, 32'd1100, 1'b0, SIDE_BID, 32'd1101, 32'd100, 1'b0, 1'b0);
        ck(21, 1'b0, 2'd0, SIDE_BID, 32'd1101, 32'd100, 8'd4, 9'b000001000);   // above edge
        intent(2'd0, 1'b1, 1'b1, 32'd1001, 32'd1100, 1'b0, SIDE_ASK, 32'd1000, 32'd100, 1'b0, 1'b0);
        ck(22, 1'b1, 2'd0, SIDE_ASK, 32'd1000, 32'd100, 8'd0, 9'b000000000);   // mid-50 == edge
        intent(2'd0, 1'b1, 1'b1, 32'd1001, 32'd1100, 1'b0, SIDE_ASK, 32'd999, 32'd100, 1'b0, 1'b0);
        ck(23, 1'b0, 2'd0, SIDE_ASK, 32'd999, 32'd100, 8'd4, 9'b000001000);    // below edge

        // ================= D: gate 0x05 staleness (T18 / D17) =================
        // Port of test_golden_model_handcase.py's n3-n6: max_age=50, arrival
        // gaps 10 / 980 / 10 (identical differences; absolute cycle numbers
        // are irrelevant since the check is a subtraction of two captures).
        cfg_max_age = 32'd50;
        do_reset;
        intent(2'd0, 1'b1, 1'b0, 32'd1000, 32'd0, 1'b0, SIDE_BID, 32'd0, 32'd0, 1'b0, 1'b0);  // n3: fresh touch, no signal
        ck(30, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 8'd0, 9'b000000000);
        idle_cycles(7);   // total arrival gap to n4 = 3 + 7 = 10
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);  // n4: gap 10 <= 50
        ck(31, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);
        idle_cycles(977);  // total arrival gap to n5 = 3 + 977 = 980
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);  // n5: gap 980 > 50
        ck(32, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd5, 9'b000010000);   // D17: STALE fires
        ck_pos(32, 2'd0, 100);   // n4's accept left position=100; the stale reject changes nothing
        idle_cycles(7);   // gap to n6 = 3 + 7 = 10
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);  // n6: fresh again
        ck(33, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);

        // ================= E: gate 0x08 throttle (T19) =================
        // token_max=2, refill period 100. Two back-to-back accepts drain the
        // bucket (no refill: < 100 cycles have elapsed); the third intent is
        // throttled; ~200 idle cycles guarantee at least one refill boundary
        // regardless of phase, so the next intent succeeds.
        cfg_token_max = 32'd2;
        cfg_token_refill_cycles = 32'd100;
        cfg_max_age = 32'd1250000;
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(40, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(41, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(42, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd8, 9'b010000000);   // throttled
        ck_pos(42, 2'd0, 200);   // no position change on a reject
        idle_cycles(200);
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(43, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);   // refilled, free-running

        // ================= F: gate 0x01 kill (T20) =================
        cfg_token_max = 32'd8;
        cfg_token_refill_cycles = 32'd12500;
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(50, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);
        @(negedge clk); kill_sw_n = 1'b0; @(posedge clk); #1;   // assert kill
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(51, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd1, 9'b000000001);
        @(negedge clk); kill_sw_n = 1'b1; @(posedge clk); #1;   // deassert alone
        if (kill_latched !== 1'b1) begin $display("FAIL: T52: kill_latched=%b after deassert alone, expected 1", kill_latched); fail = 1'b1; end
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(52, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd1, 9'b000000001);   // still blocked
        // assert wins over a simultaneous clear
        @(negedge clk); kill_sw_n = 1'b0; cfg_kill_clear = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); kill_sw_n = 1'b1; cfg_kill_clear = 1'b0;
        @(posedge clk); #1;
        if (kill_latched !== 1'b1) begin $display("FAIL: T53: kill_latched=%b after assert+clear, expected 1 (assert wins)", kill_latched); fail = 1'b1; end
        // explicit clear only
        @(negedge clk); cfg_kill_clear = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); cfg_kill_clear = 1'b0;
        @(posedge clk); #1;
        if (kill_latched !== 1'b0) begin $display("FAIL: T54: kill_latched=%b after cfg_kill_clear, expected 0", kill_latched); fail = 1'b1; end
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(54, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);

        // ================= G: multi-gate FR-43 (T21) =================
        do_reset;
        @(negedge clk); kill_sw_n = 1'b0; @(posedge clk); #1;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd1000, 1'b0, 1'b0);
        // kill (1) AND size (1000 > 500): lowest number wins as the reason,
        // but BOTH gate pulses fire.
        ck(60, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd1000, 8'd1, 9'b000000011);
        @(negedge clk); kill_sw_n = 1'b1; @(posedge clk); #1;
        @(negedge clk); cfg_kill_clear = 1'b1; @(posedge clk); #1;
        @(negedge clk); cfg_kill_clear = 1'b0; @(posedge clk); #1;

        // ================= H: gates 0x06 / 0x07 isolation =================
        cfg_max_age = 32'd1250000;
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b1, 1'b0);
        ck(70, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd6, 9'b000100000);   // seq gap alone
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(71, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);   // seq_gap is an input: off = clear
        // crossed book: bid 1010 >= ask 1000, crossed[slot]=1; band still clean
        intent(2'd0, 1'b1, 1'b1, 32'd1010, 32'd1000, 1'b1, SIDE_BID, 32'd1000, 32'd100, 1'b0, 1'b0);
        ck(72, 1'b0, 2'd0, SIDE_BID, 32'd1000, 32'd100, 8'd7, 9'b001000000);   // crossed alone

        // ================= I: D16 ML reduce (n1/n2 port) =================
        cfg_ml_action = 1'b1;
        cfg_ml_reduce_shift = 4'd1;
        do_reset;
        intent(2'd0, 1'b1, 1'b0, 32'd1000, 32'd0, 1'b0, SIDE_BID, 32'd0, 32'd0, 1'b0, 1'b0);  // n1
        ck(80, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 8'd0, 9'b000000000);
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b1);  // n2 adverse
        ck(81, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd50, 8'd0, 9'b000000000);  // D16: order_qty reduced to 50
        ck_pos(81, 2'd0, 50);   // D16: position updated by 50, not 100

        // FR-48: gate 0x03's admission check still uses the UNREDUCED qty.
        // position=100, max_position=150: unreduced prospective 200 > 150
        // fires, even though the reduced prospective (150) would pass.
        cfg_max_position = 32'd150;
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(82, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);   // non-adverse: position 100
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b1);
        ck(83, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd3, 9'b000000100);   // gate saw 100, not 50

        // ================= J: ML block path =================
        cfg_ml_action = 1'b0;
        cfg_ml_reduce_shift = 4'd1;
        cfg_max_position = 32'd1000;
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b1);
        ck(90, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd9, 9'b100000000);   // ML blocks, no order

        // ================= K: sig_valid=0 =================
        intent(2'd0, 1'b0, 1'b0, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(91, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);   // quiet
        idle_cycles(2);
        if (order_valid !== 1'b0) begin $display("FAIL: T92: order_valid high after idle"); fail = 1'b1; end

        // ================= L: strong reset =================
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(93, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(94, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);
        ck_pos(94, 2'd0, 200);
        @(negedge clk); kill_sw_n = 1'b0; @(posedge clk); #1;
        @(negedge clk); kill_sw_n = 1'b1; @(posedge clk); #1;
        if (kill_latched !== 1'b1) begin $display("FAIL: T95: kill_latched not set pre-reset"); fail = 1'b1; end
        do_reset;
        if (kill_latched !== 1'b0) begin $display("FAIL: T95: kill_latched=%b after reset, expected 0", kill_latched); fail = 1'b1; end
        ck_pos(95, 2'd0, 0); ck_pos(95, 2'd1, 0); ck_pos(95, 2'd2, 0); ck_pos(95, 2'd3, 0);
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(96, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
