`timescale 1ns / 1ps

// Self-checking testbench for rtl/risk_engine.v (master spec S3.1 [I], S8,
// FR-41..48; contract docs/contracts/risk_engine.md S3). Re-worked for D28
// (docs/design_decisions.md, contract docs/contracts/risk_engine_align_fix
// .md S4.1): the DUT is exercised THROUGH an ALIGN_DEPTH pipeline exactly
// like the real top level, not with the raw signal presented directly.
//
// Icarus:
//   iverilog -g2001 -Wall -o risk_engine_tb.vvp rtl/risk_engine.v \
//       rtl/common/delay_line.v tb/tb_risk_engine.v
//   vvp risk_engine_tb.vvp
//   # and for the S5 depth-independence pass:
//   iverilog -g2001 -DTB_ALIGN_DEPTH=3 -o risk_engine_tb3.vvp \
//       rtl/risk_engine.v rtl/common/delay_line.v tb/tb_risk_engine.v
//
// Why the DUT is driven through a delay line: since S6 the top level delays
// signal_engine's order intent by ALIGN_DEPTH cycles (tob_top.v's u_align)
// so it reaches risk_engine on the same cycle the ML verdict's registered
// value reflects the SAME triggering event. This tb mirrors that with its
// own delay_line (u_tb_align, WIDTH 79 = slot+side+price+qty+seq_gap+
// adverse(4, D47 per-symbol vector)), keyed on the tb's sig_valid_raw -- the
// raw signal_engine-style pulse, one cycle after the triggering message's
// msg_applied edge. Every directed test therefore drives:
//   * the message arrival (msg_applied/applied_slot + book state) and
//   * a RAW sig_valid/sig_slot (mimicking signal_engine), then samples the
//     registered decision ALIGN_DEPTH+1 cycles later, when the aligned
//     intent (from u_tb_align) has actually been evaluated by the DUT.
//
// D28 regression coverage: risk_engine gates 0x04 (band), 0x05 (stale) and
// 0x07 (crossed) must evaluate the book/timestamp state AS OF the message
// that triggered the signal, not the live registers as of the aligned
// arrival cycle (intervening messages overwrite them). The new poison-message
// cases (P1-P4, tags 200+) fire additional messages on the same and on a
// different slot between a triggering signal and its aligned evaluation, and
// assert the ORIGINAL message's verdict still wins. An always-on check
// asserts dut.gate_snap_out_valid coincides with the aligned sig_valid on
// every cycle (S2.3 consistency note).
//
// ALIGN_DEPTH is `TB_ALIGN_DEPTH (default 5), deliberately independent of
// whatever tob_top.v's committed value happens to be at any given time (5
// through D26/D27 v2, 4 as of D40) -- the tb proves by construction that
// this fix does not need re-deriving when ALIGN_DEPTH changes again; run
// with -DTB_ALIGN_DEPTH=<N> to confirm any other specific depth still
// passes. Verified with -DTB_ALIGN_DEPTH = 3/4/5/6. ALIGN_DEPTH >= 3
// is required by the tb's sample pipeline (at depth 2 the aligned sig_valid
// pulse of one intent can coincide with the next intent's raw pulse and the
// c_* capture window aliases); real usage (tob_top.v's committed value) has
// been 3, 5, and now 4, all well inside the supported range. The DUT's
// ALIGN_DEPTH parameter must track it.
//
// risk_engine evaluates the nine gates combinationally on each aligned
// sig_valid cycle and registers the order decision / reject_reason / one
// pulse per fired gate one cycle later (S2.7). It also owns kill_latched,
// the free-running token-bucket refill, per-slot staleness timestamps
// (last_update_cycle, refreshed on EVERY msg_applied) plus the D17
// pre-update pend_prev_cycle/pend_msg_cycle capture pair, and the signed
// per-slot position ledger.
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
//   P1-P4    D28 poison-message regression (tags 200+): a triggering signal's
//            gate verdict must reflect ITS OWN book/timestamp snapshot, not
//            the state as of later messages that land inside the ALIGN_DEPTH
//            window (P1 band, P2 stale same-slot, P3 crossed, P4 stale via a
//            different-slot message clobbering the non-per-slot pend pair)
//   T300/301 D34 same-slot spacing regression (docs/design_decisions.md D34
//            S0): with the two-stage gate pipeline, a same-slot position
//            update commits 2 cycles after sig_valid, so the second of two
//            same-slot signals 1 cycle apart MISSES the first's position
//            update in gate 0x03 (accepted anyway, ledger corrupted --
//            deliberate, documented window) while 2 cycles apart SEES it
//            (rejected reason 3).
//   M/T400   D45 token-bucket underflow regression: three aligned intents
//            (different slots) with sig_valid_raw held high for three
//            consecutive posedges, cfg_token_max=2 -- token_bucket must
//            clamp at 0 (never wrap above cfg_token_max), and a fourth
//            intent right after (still no refill) must still be throttled
//            (reason 8), proving gate 0x08 was not permanently disabled.
//   N/T500+  D47 per-symbol adverse_risk (docs/design_decisions.md D47 /
//            contract ml_policy_per_symbol.md S2/S6): gate 0x09 reads
//            adverse_risk[sig_slot] -- THIS message's own slot's bit, not a
//            single register shared across symbols. Block mode: an order on
//            slot 1 with only slot 0's bit set must be ACCEPTED (N1), while
//            an order on slot 0 with the same vector is blocked reason 9;
//            reduce mode: slot 1 order with only slot 0's bit set is NOT
//            reduced (N2); slot 2 order with only slot 0's bit set is
//            accepted (N3).
//
// On any mismatch a FAIL line names the case/field and expected vs actual;
// final PASS/FAIL. Verilog-2001 only.

`ifndef TB_ALIGN_DEPTH
`define TB_ALIGN_DEPTH 5
`endif

module tb_risk_engine;

    localparam integer ALIGN_DEPTH = `TB_ALIGN_DEPTH;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    // ---- inputs ----
    reg        rst_n = 1'b0;
    // RAW intent (mimics signal_engine's unaligned outputs)
    reg        sig_valid_raw = 1'b0;
    reg [1:0]  sig_slot_raw = 2'd0;
    // raw payload captured into u_tb_align when sig_valid_raw fires
    reg [7:0]  d_side = 8'd0;
    reg [31:0] d_price = 32'd0;
    reg [31:0] d_qty = 32'd0;
    reg        d_sg = 1'b0;
    reg [3:0]  d_adv = 4'b0000;   // D47: per-symbol adverse_risk vector
    // message-arrival inputs
    reg        msg_applied = 1'b0;
    reg [1:0]  applied_slot = 2'd0;
    reg [127:0] b_bid_price, b_ask_price;
    reg [3:0]  b_crossed;
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

    // ---- ALIGNED intent into the DUT, from u_tb_align (mirrors the top
    //      level's u_align: sig_valid + payload delayed ALIGN_DEPTH) ----
    wire        w_sig_valid;
    wire [78:0] w_dly;
    wire [1:0]  w_sig_slot  = w_dly[78:77];
    wire [7:0]  w_sig_side  = w_dly[76:69];
    wire [31:0] w_sig_price = w_dly[68:37];
    wire [31:0] w_sig_qty   = w_dly[36:5];
    wire        w_seq_gap   = w_dly[4];
    wire [3:0]  w_adverse   = w_dly[3:0];   // D47: per-symbol vector

    delay_line #(
        .WIDTH (79),   // sig_slot(2) + sig_side(8) + sig_price(32) +
                       // sig_qty(32) + seq_gap(1) + adverse(4, D47)
        .DEPTH (ALIGN_DEPTH)
    ) u_tb_align (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (sig_valid_raw),
        .in_data   ({sig_slot_raw, d_side, d_price, d_qty, d_sg, d_adv}),
        .out_valid (w_sig_valid),
        .out_data  (w_dly)
    );

    // One-cycle echo of the aligned sig_valid, plus a falling-edge detector:
    // sig_prev & ~w_sig_valid is true only at the posedge one full cycle
    // AFTER the aligned pulse's high cycle -- exactly the posedge where the
    // DUT has registered its decision (previous posedge) and c_* (which
    // samples the registered outputs pre-NBA) therefore holds it.
    reg w_sig_prev = 1'b0;
    always @(posedge clk) w_sig_prev <= w_sig_valid;
    wire w_sig_fell = w_sig_prev & ~w_sig_valid;

    // ---- decision counters for the D34 same-slot-spacing tests (S4) ----
    // cnt_orders counts accepted order pulses (order_valid high -- one per
    // accepted intent); cnt_rj3 counts gate-0x03 rejections (reject_reason
    // == 3, registered one cycle per decision). Enabled only while the test
    // is driving its two-message sequence (count_en), and zeroed whenever
    // disabled, so the counters are exact regardless of prior test traffic.
    reg count_en = 1'b0;
    integer cnt_orders = 0;
    integer cnt_rj3    = 0;
    always @(posedge clk) begin
        if (!count_en) begin
            cnt_orders = 0;
            cnt_rj3    = 0;
        end else begin
            if (order_valid)           cnt_orders = cnt_orders + 1;
            if (reject_reason == 8'd3) cnt_rj3    = cnt_rj3 + 1;
        end
    end

    // ---- D45 token-bucket underflow watch: hierarchical (white-box) peek
    //      at dut.token_bucket, same style as the existing D28
    //      dut.gate_snap_out_valid check below. Tracks the max value seen
    //      while enabled so a wrap (token_bucket jumping to something near
    //      32'hFFFFFFFF) is caught even though it self-corrects on the next
    //      accept/refill and might not be visible if only sampled once. ----
    reg        tb_watch_en = 1'b0;
    reg [31:0] tb_max_seen = 32'd0;
    always @(posedge clk) begin
        if (tb_watch_en && dut.token_bucket > tb_max_seen)
            tb_max_seen = dut.token_bucket;
    end


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

    risk_engine #(
        .ALIGN_DEPTH (ALIGN_DEPTH)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .sig_valid            (w_sig_valid),
        .sig_slot             (w_sig_slot),
        .sig_side             (w_sig_side),
        .sig_price            (w_sig_price),
        .sig_qty              (w_sig_qty),
        .sig_valid_raw        (sig_valid_raw),
        .sig_slot_raw         (sig_slot_raw),
        .msg_applied          (msg_applied),
        .applied_slot         (applied_slot),
        .bid_price            (b_bid_price),
        .ask_price            (b_ask_price),
        .crossed              (b_crossed),
        .seq_gap              (w_seq_gap),
        .adverse_risk         (w_adverse),
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

    // ---- D28 S2.3 consistency check: the DUT's internal snapshot delay
    //      line's out_valid must coincide with the (aligned) sig_valid on
    //      every cycle. Both are sig_valid_raw delayed by ALIGN_DEPTH (the
    //      DUT's u_gate_align and this tb's u_tb_align). If that ever stops
    //      being true (a depth drift, a mistyped instance), this fires. ----
    reg fail = 1'b0;
    always @(posedge clk) begin
        if (dut.gate_snap_out_valid !== w_sig_valid) begin
            $display("FAIL: gate_snap_out_valid=%b, aligned sig_valid=%b -- D28 alignment drift", dut.gate_snap_out_valid, w_sig_valid);
            fail = 1'b1;
        end
    end



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

    // ---- capture registered outputs at each posedge (nonblocking: c_* lags
    //      the DUT's registered outputs by one posedge and holds each value
    //      for a full clock cycle). gate vector bit i: 0=kill 1=size
    //      2=position 3=band 4=stale 5=seqgap 6=crossed 7=throttle 8=ml.
    //      A decision registered at posedge D is therefore readable from c_*
    //      for the whole cycle [D+1, D+2), race-free. ----
    reg        c_ov;
    reg [1:0]  c_slot;
    reg [7:0]  c_side;
    reg [31:0] c_price;
    reg [31:0] c_qty;
    reg [7:0]  c_reason;
    reg [8:0]  c_gv;
    always @(posedge clk) begin
        c_ov     <= order_valid;
        c_slot   <= order_slot;
        c_side   <= order_side;
        c_price  <= order_price;
        c_qty    <= order_qty;
        c_reason <= reject_reason;
        c_gv     <= {gate_ml_fired, gate_throttle_fired, gate_crossed_fired,
                     gate_seqgap_fired, gate_stale_fired, gate_band_fired,
                     gate_position_fired, gate_size_fired, gate_kill_fired};
    end

    // Assert + release reset with the current cfg_* values; clear the book
    // model and all level inputs.
    task do_reset;
        begin
            @(negedge clk);
            sig_valid_raw = 1'b0; msg_applied = 1'b0;
            sig_slot_raw = 2'd0; d_side = 8'd0; d_price = 32'd0;
            d_qty = 32'd0; d_sg = 1'b0; d_adv = 4'b0000;   // D47: all slots benign
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

    // Wait until the decision for the most recently launched signal is held
    // in c_*, then return just after that capture posedge. The DUT's order
    // decision registers two posedges after the aligned sig_valid's high
    // cycle's end (D34's two-stage pipeline: stage 1 registers the nine gate
    // booleans on the sig_valid posedge, stage 2 combines them into the
    // accept/reject decision on the next posedge). c_* (nonblocking,
    // one-cycle lag) captures the decision at the following posedge and
    // holds it for a full cycle. w_sig_fell is high on the posedge where
    // stage 2 registers the decision; the extra @(posedge clk) below lands on
    // the posedge where c_* holds it. Always advances at least two posedges,
    // regardless of whether this task is entered before, during, or just
    // after the aligned pulse (a D28 poison fire_msg may end exactly on the
    // decision edge). Poison messages never produce an aligned pulse (their
    // sig_valid_raw stays 0), so the first w_sig_fell high after a
    // start_signal is always this signal's decision.
    task wait_sig_sample;
        reg done;
        begin
            done = 1'b0;
            while (!done) begin
                @(posedge clk);
                if (w_sig_fell) done = 1'b1;
            end
            // D34: one more posedge -- stage 2's decision registers at the
            // w_sig_fell posedge, and c_* samples it on the next one.
            @(posedge clk);
            #1;
        end
    endtask

    // One pipeline-aligned message event on `slot` (uniform duration for all
    // msg_on/sig_on combinations so message-arrival spacing is predictable):
    // a message-arrival edge (book bus held to the post-update bp/ap/cr for
    // that slot), then a RAW sig_valid pulse on the following cycle if
    // sig_on, then a wait to the aligned decision's sample edge. On return,
    // c_* holds the decision registered for this intent (or quiet, if
    // sig_on=0). If sig_on=0 the msg simply refreshes staleness and produces
    // nothing.
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
        input [3:0]  adv;   // D47: full per-symbol adverse_risk vector
        begin
            mbp[slot] = bp; map[slot] = ap; m_cr[slot] = cr;
            drive_bus;
            @(negedge clk);             // N0: message-arrival cycle
            msg_applied  = msg_on;
            applied_slot = slot;
            sig_valid_raw = 1'b0;
            sig_slot_raw  = slot;
            d_side = side; d_price = oprice; d_qty = oqty;
            d_sg = sg; d_adv = adv;
            @(posedge clk);             // P1: arrival (staleness capture)
            #1;
            @(negedge clk);             // N1: RAW signal cycle
            msg_applied = 1'b0;
            sig_valid_raw = sig_on;
            @(posedge clk);             // P2: raw pulse + snapshot captured
            #1;
            @(negedge clk);             // N2
            sig_valid_raw = 1'b0;
            if (sig_on) begin
                // wait until the aligned decision is in c_* (ALIGN_DEPTH+2
                // posedges after P2 for a lone signal under D34's two-stage
                // gate pipeline)
                wait_sig_sample;
            end else begin
                // same-duration drain so message-arrival spacing is uniform
                // regardless of sig_on (keeps D17 gap accounting simple)
                repeat (ALIGN_DEPTH + 2) @(posedge clk);
                #1;
            end
        end
    endtask

    // Start a signal-generating message (for the D28 poison cases, which
    // need to interleave extra messages between the raw pulse and the aligned
    // evaluation, so they cannot use the monolithic intent task). Drives the
    // arrival + RAW pulse, then returns (posedge-state) leaving the aligned
    // evaluation pending. Caller should fire its poison message(s) and then
    // call wait_sig_sample before checking c_*.
    task start_signal;
        input [1:0]  slot;
        input [31:0] bp, ap;
        input        cr;
        input [7:0]  side;
        input [31:0] oprice;
        input [31:0] oqty;
        begin
            mbp[slot] = bp; map[slot] = ap; m_cr[slot] = cr;
            drive_bus;
            @(negedge clk);
            msg_applied  = 1'b1;
            applied_slot = slot;
            sig_valid_raw = 1'b0;
            sig_slot_raw  = slot;
            d_side = side; d_price = oprice; d_qty = oqty;
            d_sg = 1'b0; d_adv = 4'b0000;   // D47: all slots benign
            @(posedge clk);             // arrival
            #1;
            @(negedge clk);
            msg_applied = 1'b0;
            sig_valid_raw = 1'b1;
            @(posedge clk);             // RAW pulse + snapshot captured
            #1;
            @(negedge clk);
            sig_valid_raw = 1'b0;
            @(posedge clk);             // settle to posedge-state
            #1;
        end
    endtask

    // One non-signal message arrival on `slot` (staleness refresh / book
    // update / poison message). Consumes two posedges; enter & exit in
    // posedge-state.
    task fire_msg;
        input [1:0]  slot;
        input        msg_on;
        input [31:0] bp, ap;
        input        cr;
        begin
            @(negedge clk);
            mbp[slot] = bp; map[slot] = ap; m_cr[slot] = cr;
            drive_bus;
            msg_applied = msg_on;
            applied_slot = slot;
            sig_valid_raw = 1'b0;
            @(posedge clk);             // arrival
            #1;
            @(negedge clk);
            msg_applied = 1'b0;
            @(posedge clk);             // settle
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

    // The sample pipeline (w_sig_prev / w_sig_fell) requires the aligned
    // pulse to be cleanly separable from the next intent's raw pulse; at
    // depth < 3 the c_* capture window aliases and tests hang. Fail fast
    // instead.
    initial begin
        if (ALIGN_DEPTH < 3) begin
            $display("FAIL: tb_risk_engine requires TB_ALIGN_DEPTH >= 3 (got %0d); real depths are 3/5", ALIGN_DEPTH);
            $finish;
        end
    end

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
        cfg_max_age       = 32'd1250000;
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
        // Each intent's message-arrival edge is ALIGN_DEPTH+3 cycles after the
        // previous one's (uniform intent length), so the idle count needed to
        // reach a target arrival gap of G is G-(ALIGN_DEPTH+3).
        cfg_max_age = 32'd50;
        cfg_token_max = 32'd8;
        cfg_token_refill_cycles = 32'd12500;
        do_reset;
        intent(2'd0, 1'b1, 1'b0, 32'd1000, 32'd0, 1'b0, SIDE_BID, 32'd0, 32'd0, 1'b0, 1'b0);  // n3: fresh touch, no signal
        ck(30, 1'b0, 2'd0, SIDE_BID, 32'd0, 32'd0, 8'd0, 9'b000000000);
        idle_cycles(10 - (ALIGN_DEPTH + 3));   // total arrival gap to n4 = 10
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);  // n4: gap 10 <= 50
        ck(31, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);
        idle_cycles(980 - (ALIGN_DEPTH + 3));  // total arrival gap to n5 = 980
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);  // n5: gap 980 > 50
        ck(32, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd5, 9'b000010000);   // D17: STALE fires
        ck_pos(32, 2'd0, 100);   // n4's accept left position=100; the stale reject changes nothing
        idle_cycles(10 - (ALIGN_DEPTH + 3));   // total arrival gap to n6 = 10
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
        cfg_max_position = 32'd1000;
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
        cfg_max_position = 32'd1000;
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
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 4'b0001);  // n2 adverse, slot 0 only (D47)
        ck(81, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd50, 8'd0, 9'b000000000);  // D16: order_qty reduced to 50
        ck_pos(81, 2'd0, 50);   // D16: position updated by 50, not 100

        // FR-48: gate 0x03's admission check still uses the UNREDUCED qty.
        // position=100, max_position=150: unreduced prospective 200 > 150
        // fires, even though the reduced prospective (150) would pass.
        cfg_max_position = 32'd150;
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 1'b0);
        ck(82, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);   // non-adverse: position 100
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 4'b0001);   // adverse slot 0 only (D47)
        ck(83, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd3, 9'b000000100);   // gate saw 100, not 50

        // D18 (docs/design_decisions.md): a REJECTED intent must report the
        // UNREDUCED quantity, matching sim/golden_model.py's reject-path
        // OrderRecord (which uses order_qty, not reduced_qty). ck()'s own
        // e_ov-gated qty check (this task, above) only verifies order_qty
        // on an ACCEPTED intent -- that blind spot is exactly how this bug
        // shipped once already; check it directly here on test 83's
        // rejected result (adverse_risk=1, ml_action=1, gate 0x03 fired).
        if (c_qty !== 32'd100) begin
            $display("FAIL: T83b (D18): rejected order_qty=%0d, expected unreduced 100", c_qty);
            fail = 1'b1;
        end

        // ================= J: ML block path =================
        cfg_ml_action = 1'b0;
        cfg_ml_reduce_shift = 4'd1;
        cfg_max_position = 32'd1000;
        do_reset;
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 4'b0001);   // adverse slot 0 only (D47)
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

        // ====================================================================
        // N: D47 per-symbol adverse_risk gate (ml_policy_per_symbol.md S2/S6).
        // risk_engine's gate 0x09 reads adverse_risk[sig_slot] -- THIS
        // message's own slot's bit -- not a single register shared across
        // every watched symbol. These cases drive the FULL 4-bit
        // adverse_risk vector through u_tb_align with a deliberate bit
        // pattern (the slot under test's own bit set/clear vs. the others
        // opposite) so a wrong-index implementation -- always reading bit 0,
        // or reading some other fixed slot -- is caught, not just a
        // scalar-vs-vector wiring slip.
        // ====================================================================

        // ---- N1: block mode, slot 1 order must NOT be gated by slot 0's
        //      adverse bit ----
        cfg_ml_action       = 1'b0;      // block mode
        cfg_ml_reduce_shift = 4'd1;
        cfg_max_position    = 32'd1000;
        do_reset;
        // order on slot 1 with adverse_risk = 4'b0001 (slot 0 only). Gate
        // 0x09 reads adverse_risk[sig_slot=1] = 0 -> the order must pass.
        // A scalar-era or always-bit-0 implementation would wrongly block it.
        intent(2'd1, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 4'b0001);
        ck(500, 1'b1, 2'd1, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);   // slot 1 accepted
        // order on slot 0 with the same vector: slot 0's OWN bit is set, so
        // THIS one must be blocked -- proves the vector is actually live and
        // the indexing is per-slot, not "read whatever slot 1 is".
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 4'b0001);
        ck(501, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd9, 9'b100000000);   // slot 0 blocked (0x09)

        // ---- N2: reduce mode, slot 1 order with slot 0 adverse must NOT be
        //      reduced ----
        cfg_ml_action       = 1'b1;      // reduce mode
        cfg_ml_reduce_shift = 4'd1;
        cfg_max_position    = 32'd1000;
        do_reset;
        intent(2'd1, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 4'b0001);
        ck(510, 1'b1, 2'd1, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);   // full 100, NOT reduced
        ck_pos(510, 2'd1, 100);
        // slot 0 order, same vector, reduce mode: slot 0's own bit IS set ->
        // reduced to 50 (D16), and position reflects 50.
        intent(2'd0, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 4'b0001);
        ck(511, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd50, 8'd0, 9'b000000000);
        ck_pos(511, 2'd0, 50);

        // ---- N3: block mode, cross-check the DELIBERATELY OPPOSITE pattern
        //      (slot under test benign, another slot adverse) is the one that
        //      passes -- a buggy "OR all bits" implementation would block ----
        cfg_ml_action       = 1'b0;
        cfg_max_position    = 32'd1000;
        do_reset;
        intent(2'd2, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100, 1'b0, 4'b0001);
        ck(520, 1'b1, 2'd2, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);   // slot 2 accepted

        // ====================================================================
        // D28 poison-message regression (docs/design_decisions.md D28,
        // contract risk_engine_align_fix.md S4.1). Each case fires a signal-
        // triggering message whose gate verdict depends on its OWN book/
        // timestamp state, then -- BEFORE the aligned intent is evaluated --
        // fires one or more additional messages (same slot and, in P4, a
        // different slot) that change the LIVE book / refresh the live
        // staleness pair to values that would flip gates 0x04/0x05/0x07 if
        // the engine read them in real time. The FIXED engine must still
        // return the ORIGINAL message's verdict.
        // ====================================================================

        // ---- P1: gate 0x04 (band) poisoned by a same-slot price move ----
        // M buys at 1010 against book bid=1000/ask=1010 (mid=1005, |price-mid|
        // =5 <= band 50 -> passes). A poison message 1 cycle later moves the
        // ask to 2000 (live mid=1500 -> |1010-1500|=490 > 50 would fire gate
        // 0x04 if read live). Snapshot must keep mid=1005 -> accept.
        cfg_price_band = 32'd50;
        cfg_max_age    = 32'd1250000;
        cfg_max_position = 32'd1000;
        cfg_token_max  = 32'd8;
        cfg_token_refill_cycles = 32'd12500;
        do_reset;
        fire_msg(2'd0, 1'b1, 32'd1000, 32'd1010, 1'b0);          // fresh touch on slot 0
        start_signal(2'd0, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100);  // M
        fire_msg(2'd0, 1'b1, 32'd1000, 32'd2000, 1'b0);          // poison: shift the ask
        wait_sig_sample;
        ck(200, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);  // band must NOT fire
        ck_pos(200, 2'd0, 100);

        // ---- P2: gate 0x05 (stale) poisoned by a same-slot refresh ----
        // M arrives 60 cycles (> max_age 50) after slot 0's last touch -> truly
        // stale (reject 5). A same-slot poison message 1 cycle later refreshes
        // the live staleness pair to a 2-cycle gap -> live reads would accept.
        cfg_max_age = 32'd50;
        do_reset;
        fire_msg(2'd0, 1'b1, 32'd1000, 32'd1010, 1'b0);          // X0: baseline touch
        idle_cycles(58);                                         // 60-cycle arrival gap to M
        start_signal(2'd0, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100);  // M: stale
        fire_msg(2'd0, 1'b1, 32'd1000, 32'd1010, 1'b0);          // poison: refresh slot 0
        wait_sig_sample;
        ck(201, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd5, 9'b000010000);  // M's own gap still fires stale
        ck_pos(201, 2'd0, 0);

        // ---- P3: gate 0x07 (crossed) poisoned by a same-slot crossed book ----
        // M's own book is uncrossed (accept). A poison message crosses slot 0
        // near the original mid (bid 1006 >= ask 1005; mid still 1005 so the
        // band check is unchanged) -> live reads would fire gate 0x07.
        cfg_max_age = 32'd1250000;
        do_reset;
        fire_msg(2'd0, 1'b1, 32'd1000, 32'd1010, 1'b0);          // fresh touch
        start_signal(2'd0, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100);  // M
        fire_msg(2'd0, 1'b1, 32'd1006, 32'd1005, 1'b1);          // poison: cross the book
        wait_sig_sample;
        ck(202, 1'b1, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd0, 9'b000000000);  // crossed must NOT fire
        ck_pos(202, 2'd0, 100);

        // ---- P4: gate 0x05 (stale) poisoned by a DIFFERENT-slot message ----
        // pend_prev_cycle/pend_msg_cycle are a single non-per-slot register
        // pair clobbered by ANY msg_applied. M on slot 0 is genuinely stale
        // (60-cycle gap). A message on slot 1 (which had a fresh touch 40
        // cycles earlier) lands inside M's ALIGN window and overwrites the
        // pair with a fresh-looking 40-cycle... i.e. < 50 -> a live read would
        // accept. The snapshot must keep M's own 60-cycle gap -> reject 5.
        cfg_max_age = 32'd50;
        do_reset;
        fire_msg(2'd0, 1'b1, 32'd1000, 32'd1010, 1'b0);          // X0: slot 0 baseline touch
        idle_cycles(20);
        fire_msg(2'd1, 1'b1, 32'd500, 32'd510, 1'b0);            // slot 1 recent touch
        idle_cycles(36);                                         // slot 0 gap to M = 60
        start_signal(2'd0, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1010, 32'd100);  // M: stale
        fire_msg(2'd1, 1'b1, 32'd500, 32'd510, 1'b0);            // poison: slot 1 clobbers the pend pair
        wait_sig_sample;
        ck(203, 1'b0, 2'd0, SIDE_BID, 32'd1010, 32'd100, 8'd5, 9'b000010000);  // M's own gap still fires stale
        ck_pos(203, 2'd0, 0);

        // ====================================================================
        // D34 same-slot spacing regression (docs/design_decisions.md D34 S0).
        // risk_engine's sig_valid->position-write latency is now 2 cycles, so
        // gate 0x03's read of position_r (stage 1) sees an accepted order's
        // update only when the next SAME-slot intent is at least 2 aligned
        // cycles away. cfg_max_position=150, each buy = 100: A (position 0
        // -> prospective 100) is always accepted. The discriminator is B.
        //   T300  B 1 cycle after A: gate 0x03 runs BEFORE A's position write
        //         commits -> B sees the stale 0 and is ALSO accepted. Two
        //         orders emitted, but B's write (stale prospective 100)
        //         overwrites A's, leaving position=100 -- the documented,
        //         deliberately-widened window, NOT a bug.
        //   T301  B 2 cycles after A: B's gate 0x03 sees position 100 ->
        //         prospective 200 > 150 -> rejected reason 3; position stays
        //         100 and only A is accepted.
        // ====================================================================

        // ---- T300: two same-slot signals exactly 1 cycle apart ----
        cfg_max_position = 32'd150;
        cfg_max_order_qty = 32'd500;
        cfg_price_band    = 32'd50;
        cfg_max_age       = 32'd1250000;
        cfg_token_max     = 32'd8;
        cfg_token_refill_cycles = 32'd12500;
        do_reset;
        count_en = 1'b1;
        // A arrival at the next posedge (E_A)
        @(negedge clk);
        mbp[0] = 32'd1000; map[0] = 32'd1010; m_cr[0] = 1'b0;
        drive_bus;
        msg_applied = 1'b1; applied_slot = 2'd0;
        sig_valid_raw = 1'b0; sig_slot_raw = 2'd0;
        d_side = SIDE_BID; d_price = 32'd1010; d_qty = 32'd100;
        d_sg = 1'b0; d_adv = 4'b0000;   // D47: all slots benign
        @(posedge clk);            // E_A: A arrival
        #1;
        @(negedge clk);
        sig_valid_raw = 1'b1;      // raw A; msg_applied stays high -> B arrives at E_A+1
        @(posedge clk);            // E_A+1: B arrival AND A raw captured
        #1;
        @(negedge clk);
        msg_applied = 1'b0;
        @(posedge clk);            // E_A+2: B raw captured
        #1;
        @(negedge clk);
        sig_valid_raw = 1'b0;
        @(posedge clk);
        #1;
        idle_cycles(ALIGN_DEPTH + 10);   // both decisions commit well within this
        count_en = 1'b0;
        if (cnt_orders !== 2) begin
            $display("FAIL: T300 (1-apart): accepted=%0d, expected 2 (B MUST be accepted -- its gate 0x03 misses A's not-yet-written position)", cnt_orders);
            fail = 1'b1;
        end
        if (cnt_rj3 !== 0) begin
            $display("FAIL: T300 (1-apart): reason-3 rejects=%0d, expected 0", cnt_rj3);
            fail = 1'b1;
        end
        // Both accepted, but B's stale write leaves the ledger at 100, not 200
        // (A's contribution lost) -- the observable cost of the widened window.
        ck_pos(300, 2'd0, 100);

        // ---- T301: two same-slot signals exactly 2 cycles apart ----
        cfg_max_position = 32'd150;
        cfg_max_order_qty = 32'd500;
        cfg_price_band    = 32'd50;
        cfg_max_age       = 32'd1250000;
        cfg_token_max     = 32'd8;
        cfg_token_refill_cycles = 32'd12500;
        do_reset;
        count_en = 1'b1;
        // A arrival at E_A
        @(negedge clk);
        mbp[0] = 32'd1000; map[0] = 32'd1010; m_cr[0] = 1'b0;
        drive_bus;
        msg_applied = 1'b1; applied_slot = 2'd0;
        sig_valid_raw = 1'b0; sig_slot_raw = 2'd0;
        d_side = SIDE_BID; d_price = 32'd1010; d_qty = 32'd100;
        d_sg = 1'b0; d_adv = 4'b0000;   // D47: all slots benign
        @(posedge clk);            // E_A: A arrival
        #1;
        @(negedge clk);
        msg_applied = 1'b0;
        sig_valid_raw = 1'b1;      // raw A
        @(posedge clk);            // E_A+1: A raw captured
        #1;
        @(negedge clk);
        sig_valid_raw = 1'b0;
        msg_applied = 1'b1;        // schedule B for E_A+2
        @(posedge clk);            // E_A+2: B arrival
        #1;
        @(negedge clk);
        msg_applied = 1'b0;
        sig_valid_raw = 1'b1;      // raw B
        @(posedge clk);            // E_A+3: B raw captured
        #1;
        @(negedge clk);
        sig_valid_raw = 1'b0;
        @(posedge clk);
        #1;
        idle_cycles(ALIGN_DEPTH + 10);
        count_en = 1'b0;
        if (cnt_orders !== 1) begin
            $display("FAIL: T301 (2-apart): accepted=%0d, expected 1 (B must be rejected reason 3)", cnt_orders);
            fail = 1'b1;
        end
        if (cnt_rj3 !== 1) begin
            $display("FAIL: T301 (2-apart): reason-3 rejects=%0d, expected 1", cnt_rj3);
            fail = 1'b1;
        end
        ck_pos(301, 2'd0, 100);

        // ====================================================================
        // D45 token-bucket underflow regression (docs/design_decisions.md
        // D45). gate_throttle_fired_c (stage 1) samples token_bucket one
        // cycle before its own decrement (driven by stage-2 accepted_c)
        // commits, so back-to-back aligned intents on consecutive cycles can
        // each see the SAME not-yet-decremented value. cfg_token_max=2 with
        // three back-to-back accepts (different slots, so gate 0x03/spacing
        // are not the thing under test) drives the decrement below 0 on the
        // pre-fix RTL, wrapping token_bucket to ~32'hFFFFFFFF and latching
        // gate 0x08 off for good. This case does NOT assert how many of the
        // three burst messages were themselves accepted -- that over-
        // admission is a known, separate, deliberately-out-of-scope
        // limitation (D45) -- only that token_bucket never exceeds
        // cfg_token_max (no wrap) and that gate 0x08 is still alive
        // immediately afterward.
        // ====================================================================

        // ---- M / T400: three back-to-back accepts, cfg_token_max=2 ----
        cfg_token_max           = 32'd2;
        cfg_token_refill_cycles = 32'd1000000;   // refill cannot land inside this case
        cfg_max_position        = 32'd1000;
        cfg_max_order_qty       = 32'd500;
        cfg_price_band          = 32'd50;
        cfg_max_age             = 32'd1250000;
        do_reset;
        mbp[0] = 32'd1000; map[0] = 32'd1010; m_cr[0] = 1'b0;
        mbp[1] = 32'd1000; map[1] = 32'd1010; m_cr[1] = 1'b0;
        mbp[2] = 32'd1000; map[2] = 32'd1010; m_cr[2] = 1'b0;
        drive_bus;
        tb_max_seen = 32'd0;
        tb_watch_en = 1'b1;
        // sig_valid_raw held high across three consecutive posedges, no gap
        // -- slot 0, slot 1, slot 2, each at the book's own mid (1005) so no
        // gate but throttle can possibly fire.
        @(negedge clk);
        sig_valid_raw = 1'b1; sig_slot_raw = 2'd0;
        d_side = SIDE_BID; d_price = 32'd1005; d_qty = 32'd100;
        d_sg = 1'b0; d_adv = 4'b0000;   // D47: all slots benign
        @(posedge clk); #1;                    // slot 0 raw captured
        @(negedge clk);
        sig_slot_raw = 2'd1;
        @(posedge clk); #1;                    // slot 1 raw captured
        @(negedge clk);
        sig_slot_raw = 2'd2;
        @(posedge clk); #1;                    // slot 2 raw captured
        @(negedge clk);
        sig_valid_raw = 1'b0;
        @(posedge clk); #1;
        idle_cycles(ALIGN_DEPTH + 10);         // let all three decisions drain
        tb_watch_en = 1'b0;
        if (tb_max_seen > cfg_token_max) begin
            $display("FAIL: T400: token_bucket max observed=%0d (0x%h) during/after a 3-message back-to-back burst, expected <= cfg_token_max=%0d -- underflow wrap", tb_max_seen, tb_max_seen, cfg_token_max);
            fail = 1'b1;
        end
        // Immediately after, still inside the same (huge) refill period: a
        // fourth intent must still be throttled -- gate 0x08 must not have
        // been permanently disabled by a wrapped bucket.
        intent(2'd3, 1'b1, 1'b1, 32'd1000, 32'd1010, 1'b0, SIDE_BID, 32'd1005, 32'd100, 1'b0, 1'b0);
        ck(400, 1'b0, 2'd3, SIDE_BID, 32'd1005, 32'd100, 8'd8, 9'b010000000);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule

