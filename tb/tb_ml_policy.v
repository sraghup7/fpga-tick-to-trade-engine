`timescale 1ns / 1ps

// Self-checking testbench for rtl/ml_policy.v (contract
// docs/contracts/ml_integration.md S4.4). Re-worked for the D28-class
// fail-safe snapshot fix (docs/design_decisions.md D28; contract
// docs/contracts/ml_policy_align_fix.md S4.1): the DUT is now exercised
// THROUGH its internal book-update snapshot + delay line, exactly like the
// real chain, not with ml_valid driven in isolation.
//
// Icarus:
//   iverilog -g2001 -Wall -o tb_ml_policy.vvp rtl/ml_policy.v \
//       rtl/common/delay_line.v tb/tb_ml_policy.v
//   vvp tb_ml_policy.vvp
//   # and for the depth-independence pass (real depth, D53: was 4, now 5):
//   iverilog -g2001 -DTB_SNAPSHOT_DEPTH=5 -o tb_ml_policy5.vvp \
//       rtl/ml_policy.v rtl/common/delay_line.v tb/tb_ml_policy.v
//
// Why the DUT is driven through its own snapshot pipeline: since the fix,
// ml_policy keys its per-slot fail-safe inputs (bid_valid/ask_valid/crossed)
// to the triggering message's OWN book_upd_valid, snapshotted one cycle later
// (T+1) and carried forward SNAPSHOT_DEPTH cycles. Every directed test
// therefore drives:
//   * book_upd_valid/applied_slot (the triggering event) with the book buses
//     holding the state to be CAPTURED, then
//   * ml_valid/ml_slot/z exactly SNAPSHOT_DEPTH+1 cycles after book_upd_valid
//     -- the cycle the internal snapshot arrives (the "+1" is the T+1 capture
//     offset; ml_valid is driven through a tb-side register so its edges align
//     with the DUT's fs_snap_out_valid, mirroring ml_classifier_wrap.v).
//
// SNAPSHOT_DEPTH is `TB_SNAPSHOT_DEPTH (default 3), deliberately independent
// of -- and numerically different from -- tob_top.v's ALIGN_DEPTH (currently
// 5, per D53: was 4 before ml_classifier_wrap.v gained a second pipeline
// stage): the whole point of the fix is that these two parameters are NOT
// coupled, and a tb that instantiated this module at a depth equal to
// ALIGN_DEPTH could let a "SNAPSHOT_DEPTH reuses ALIGN_DEPTH" wiring bug pass
// by coincidence. Run with -DTB_SNAPSHOT_DEPTH=<N> to confirm any depth.
//
// New D28-class regression coverage (P1-P3, tags 200+): a triggering message
// whose own book state is healthy must NOT be fail-safe forced even if a
// same-slot message poisons the live book BEFORE ml_valid arrives (P1); a
// triggering message whose own book state is bad MUST still be forced even if
// the book is healed before ml_valid (P2); seq_gap (deliberately NOT
// snapshotted -- feed-wide sticky state) still forces when asserted during
// the window (P3). An always-on check asserts u_dut.fs_snap_out_valid
// coincides with ml_valid on every cycle (S2.3 consistency note).
//
// New D47 per-symbol regression (P4, tags 230+, docs/design_decisions.md
// D47 / docs/contracts/ml_policy_per_symbol.md S6): adverse_risk is now a
// NUM_SYMBOLS-wide vector indexed by ml_slot, NOT a single scalar shared
// across every watched symbol. The existing scalar-era checks (which fire
// only slot 0, or one slot at a time) still pass because single-slot
// behavior is a special case of per-slot behavior -- but a test that only
// ever drives one slot cannot catch the shared-scalar bug this fix removes.
// P4 drives the actual cross-slot scenario from the contract's S0: a genuine
// adverse event on slot 0, then a SEPARATE hold-band event on a fresh
// slot 1 (which must NOT inherit slot 0's adverse bit), then a hold-band
// event back on slot 0 (whose OWN prior adverse bit must persist).
//
// Thresholds cfg_ml_th_high=20 / cfg_ml_th_low=-20 throughout; every
// expected verdict below is hand-derived from the hysteresis + fail-safe
// rules, not copied from a run.
//
// Verilog-2001 only.

`ifndef TB_SNAPSHOT_DEPTH
`define TB_SNAPSHOT_DEPTH 3
`endif

module tb_ml_policy;

    localparam integer SNAPSHOT_DEPTH = `TB_SNAPSHOT_DEPTH;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;

    // triggering-message inputs (NEW -- see header)
    reg        book_upd_valid = 1'b0;
    reg [1:0]  applied_slot = 2'd0;

    // ml_valid/ml_slot/z are driven through a tb-side register so their edges
    // align with the DUT's fs_snap_out_valid (mirrors ml_classifier_wrap.v's
    // registered output); *_next holds the value one cycle ahead.
    reg        ml_valid = 1'b0;
    reg        ml_valid_next = 1'b0;
    reg [1:0]  ml_slot = 2'd0;
    reg [1:0]  ml_slot_next = 2'd0;
    reg signed [31:0] z = 32'sd0;
    reg signed [31:0] z_next = 32'sd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ml_valid <= 1'b0;
            ml_slot  <= 2'd0;
            z        <= 32'sd0;
        end else begin
            ml_valid <= ml_valid_next;
            if (ml_valid_next) begin
                ml_slot <= ml_slot_next;
                z       <= z_next;
            end
        end
    end

    reg [3:0]  bid_valid = 4'd0;
    reg [3:0]  ask_valid = 4'd0;
    reg [3:0]  crossed   = 4'd0;
    reg        seq_gap   = 1'b0;

    reg signed [31:0] cfg_ml_th_high = 32'sd20;
    reg signed [31:0] cfg_ml_th_low  = -32'sd20;
    reg [31:0] cfg_ml_score_offset = 32'd0;
    reg [31:0] cfg_ml_score_shift  = 32'd0;

    wire [3:0]  adverse_risk;   // D47: per-symbol vector, one bit per slot
    wire signed [31:0] score_raw;
    wire [7:0]  risk_level;
    wire        ml_event_valid, ml_adverse_pulse, ml_benign_pulse, ml_safe_forced_pulse;

    ml_policy #(
        .NUM_SYMBOLS    (4),
        .SNAPSHOT_DEPTH (SNAPSHOT_DEPTH)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .book_upd_valid(book_upd_valid), .applied_slot(applied_slot),
        .ml_valid(ml_valid), .ml_slot(ml_slot), .z(z),
        .bid_valid(bid_valid), .ask_valid(ask_valid), .crossed(crossed), .seq_gap(seq_gap),
        .cfg_ml_th_high(cfg_ml_th_high), .cfg_ml_th_low(cfg_ml_th_low),
        .cfg_ml_score_offset(cfg_ml_score_offset), .cfg_ml_score_shift(cfg_ml_score_shift),
        .adverse_risk(adverse_risk), .score_raw(score_raw), .risk_level(risk_level),
        .ml_event_valid(ml_event_valid), .ml_adverse_pulse(ml_adverse_pulse),
        .ml_benign_pulse(ml_benign_pulse), .ml_safe_forced_pulse(ml_safe_forced_pulse)
    );

    reg     fail = 1'b0;

    // S2.3 consistency note: u_fs_align's out_valid must coincide with
    // ml_valid on every cycle (both trace back to the same triggering event's
    // book_upd_valid -- this module's internal raw_d1 + delay line vs the
    // real upstream pipeline). A future latency change anywhere in the
    // feature_extractor -> feature_normalizer -> ml_classifier_wrap chain
    // that drifts ml_valid relative to this module's SNAPSHOT_DEPTH is caught
    // by simulation, not discovered on a later audit.
    always @(posedge clk) begin
        #1;
        if (rst_n && (u_dut.fs_snap_out_valid !== u_dut.ml_valid)) begin
            $display("FAIL: SNAPSHOT drift: fs_snap_out_valid=%b vs ml_valid=%b",
                     u_dut.fs_snap_out_valid, u_dut.ml_valid);
            fail = 1'b1;
        end
    end

    task chk;
        input integer tag;
        input        got;
        input        exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: got %b, expected %b", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    task chk8;
        input integer tag;
        input [7:0]  got;
        input [7:0]  exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: got %0d, expected %0d", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    // D47: whole-vector compare for the per-symbol adverse_risk output.
    task chk4;
        input integer tag;
        input [3:0]  got;
        input [3:0]  exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: adverse_risk=%b, expected %b", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    // Pulse book_upd_valid/applied_slot for one cycle (the triggering event)
    // and advance until the book state has been captured into u_fs_align's
    // first stage. On entry the caller must have set the book buses
    // (bid_valid/ask_valid/crossed) and seq_gap to the state this triggering
    // message should CAPTURE; that state must stay stable until this task
    // returns. On return the snapshot is latched and the buses may be
    // changed freely (poisoned) without affecting this event.
    task pulse_book;
        input [1:0] slot;
        begin
            @(negedge clk);
            book_upd_valid = 1'b1;
            applied_slot   = slot;
            @(posedge clk);      // raw_d1 captures book_upd_valid/applied_slot
            #1;
            @(negedge clk);
            book_upd_valid = 1'b0;   // one-cycle pulse
            @(posedge clk);      // delay_line stage 0 latches the snapshot
            #1;
        end
    endtask

    // Register ml_valid high for exactly the cycle the DUT's fs_snap_out_valid
    // is high (SNAPSHOT_DEPTH-1 posedges after the snapshot latch), so the
    // DUT's always block samples ml_valid one cycle later with the snapshot
    // already aligned. On return the DUT's registered outputs (adverse_risk/
    // pulses) reflect this event; ml_valid is still high, so the caller can
    // inspect the one-cycle pulses before settle() clears them.
    task fire_ml;
        input [1:0]  slot;
        input signed [31:0] zin;
        integer j;
        begin
            for (j = 0; j < SNAPSHOT_DEPTH-2; j = j + 1) begin
                @(posedge clk);
                #1;
            end
            @(negedge clk);
            ml_valid_next = 1'b1;
            ml_slot_next  = slot;
            z_next        = zin;
            @(posedge clk);      // ml_valid rises; fs_snap_out_valid rises
            #1;
            ml_valid_next = 1'b0;
            @(posedge clk);      // DUT commits (ml_valid + snapshot aligned)
            #1;
        end
    endtask

    // Full event: pulse the triggering book update then fire the matching
    // ml_valid SNAPSHOT_DEPTH+1 cycles after it. Book buses must already hold
    // the triggering message's own state (see pulse_book). Caller checks the
    // registered verdicts after this, then calls settle().
    task fire;
        input [1:0]  slot;
        input signed [31:0] zin;
        begin
            pulse_book(slot);
            fire_ml(slot, zin);
        end
    endtask

    // Deassert ml_valid and advance one cycle: one-cycle pulses clear,
    // adverse_risk/score_raw/risk_level hold, and ml_valid falls (the tb
    // register captures ml_valid_next=0).
    task settle;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            book_upd_valid = 1'b0; applied_slot = 2'd0;
            ml_valid_next = 1'b0; ml_slot_next = 2'd0; z_next = 32'sd0;
            bid_valid = 4'd0; ask_valid = 4'd0; crossed = 4'd0; seq_gap = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        if (SNAPSHOT_DEPTH < 3) begin
            $display("FAIL: tb_ml_policy requires TB_SNAPSHOT_DEPTH >= 3 (got %0d); real depth is 5 (D53)", SNAPSHOT_DEPTH);
            $finish;
        end
        do_reset;
        // healthy baseline: all four slots valid, not crossed, no gap
        bid_valid = 4'b1111;
        ask_valid = 4'b1111;
        crossed   = 4'b0000;
        seq_gap   = 1'b0;
        chk4(0, adverse_risk, 4'b0000);   // D47: all slots benign out of reset
        chk(1, ml_event_valid, 1'b0);

        // ---- rising through T_high: z=25 -> adverse (slot 0) ----
        fire(2'd0, 32'sd25);
        chk(10, adverse_risk[0], 1'b1);   // D47: per-slot bit
        chk(11, ml_adverse_pulse, 1'b1);
        chk(12, ml_benign_pulse, 1'b0);
        chk(13, ml_safe_forced_pulse, 1'b0);
        settle;

        // ---- falling through T_low: z=-25 -> benign (slot 0) ----
        fire(2'd0, -32'sd25);
        chk(14, adverse_risk[0], 1'b0);
        chk(15, ml_benign_pulse, 1'b1);
        chk(16, ml_adverse_pulse, 1'b0);
        settle;

        // ---- hold zone (from adverse): z=0 in (-20,20) -> holds 1 ----
        fire(2'd0, 32'sd25);
        settle;                              // adverse_risk[0] now 1
        fire(2'd0, 32'sd0);
        chk(20, adverse_risk[0], 1'b1);      // held
        chk(21, ml_adverse_pulse, 1'b1);     // pulse follows held state
        chk(22, ml_benign_pulse, 1'b0);
        settle;

        // ---- hold zone (from benign): z=0 -> holds 0 ----
        fire(2'd0, -32'sd25);
        settle;                              // adverse_risk[0] now 0
        fire(2'd0, 32'sd0);
        chk(23, adverse_risk[0], 1'b0);      // held
        chk(24, ml_benign_pulse, 1'b1);
        chk(25, ml_adverse_pulse, 1'b0);
        settle;

        // ---- fail-safe forcing overrides a benign z (each cause alone) ----
        // crossed[slot]
        crossed[0] = 1'b1;
        fire(2'd0, -32'sd25);
        chk(30, adverse_risk[0], 1'b1);
        chk(31, ml_safe_forced_pulse, 1'b1);
        chk(32, ml_adverse_pulse, 1'b1);
        settle;
        crossed[0] = 1'b0;

        // ~bid_valid[slot]
        bid_valid[0] = 1'b0;
        fire(2'd0, -32'sd25);
        chk(33, adverse_risk[0], 1'b1);
        chk(34, ml_safe_forced_pulse, 1'b1);
        settle;
        bid_valid[0] = 1'b1;

        // ~ask_valid[slot]
        ask_valid[0] = 1'b0;
        fire(2'd0, -32'sd25);
        chk(35, adverse_risk[0], 1'b1);
        chk(36, ml_safe_forced_pulse, 1'b1);
        settle;
        ask_valid[0] = 1'b1;

        // seq_gap
        seq_gap = 1'b1;
        fire(2'd0, -32'sd25);
        chk(37, adverse_risk[0], 1'b1);
        chk(38, ml_safe_forced_pulse, 1'b1);
        settle;
        seq_gap = 1'b0;

        // ---- applied_slot indexing: the snapshot is taken at the triggering
        //      message's applied_slot, not slot 0 ----
        // slot 2 crossed, slot 0 healthy: benign z on slot 0 -> benign; on
        // slot 2 -> forced adverse.
        fire(2'd0, -32'sd25);   // restore benign baseline on slot 0
        settle;
        crossed[2] = 1'b1;
        fire(2'd2, -32'sd25);   // same benign z, addressed slot crossed
        chk(40, adverse_risk[2], 1'b1);   // D47: this event was on slot 2
        chk(41, ml_safe_forced_pulse, 1'b1);
        settle;
        fire(2'd0, -32'sd25);   // slot 0 still healthy
        chk(42, adverse_risk[0], 1'b0);   // D47: slot 0's own bit is benign
        settle;
        crossed[2] = 1'b0;

        // ---- D28-class poison-message regression (ml_policy_align_fix.md
        //      S4.1) ----
        // P1: a triggering message whose OWN book state is healthy (so the
        // fail-safe should NOT fire for it), with the live book poisoned to
        // ask-invalid on the SAME slot during the SNAPSHOT_DEPTH-cycle gap
        // before ml_valid arrives. The verdict must reflect the triggering
        // message's snapshot, not the poison.
        fire(2'd0, -32'sd25);   // leave adverse_risk[0] benign (0) first
        settle;
        pulse_book(2'd0);                       // capture: slot 0 healthy
        ask_valid[0] = 1'b0;                    // poison slot 0 after capture
        fire_ml(2'd0, -32'sd25);                // benign z: NOT forced
        chk(200, adverse_risk[0], 1'b0);
        chk(201, ml_safe_forced_pulse, 1'b0);
        chk(202, ml_benign_pulse, 1'b1);
        settle;
        ask_valid[0] = 1'b1;                    // restore

        // P2 (mirror): a triggering message whose OWN book state is bad (ask
        // invalid), healed back to healthy during the gap before ml_valid.
        // The fail-safe must STILL fire -- the fix is not "read whatever the
        // book looks like at ml_valid".
        ask_valid[0] = 1'b0;
        pulse_book(2'd0);                       // capture: ask invalid
        ask_valid[0] = 1'b1;                    // heal slot 0 after capture
        fire_ml(2'd0, -32'sd25);                // benign z, forced on snapshot
        chk(210, adverse_risk[0], 1'b1);
        chk(211, ml_safe_forced_pulse, 1'b1);
        chk(212, ml_adverse_pulse, 1'b1);
        settle;

        // P3: seq_gap is deliberately NOT snapshotted (feed-wide sticky
        // state, read live at the decision's own cycle) -- asserting it
        // DURING the window must still force, even over a healthy captured
        // book.
        pulse_book(2'd0);                       // capture: slot 0 healthy
        seq_gap = 1'b1;                         // gap asserted after capture
        fire_ml(2'd0, -32'sd25);
        chk(220, adverse_risk[0], 1'b1);
        chk(221, ml_safe_forced_pulse, 1'b1);
        settle;
        seq_gap = 1'b0;

        // ---- D47 per-symbol adverse_risk regression (ml_policy_per_symbol
        //      .md S6). The minimum case that distinguishes per-symbol-correct
        //      from shared-scalar-bug: three events across TWO slots. Slot 1
        //      has never had an event before this block, so its held value is
        //      the reset 0; slot 0 (and slot 2, adversed by the tag-40
        //      applied-slot block above) are restored to a benign baseline
        //      first. A shared-scalar design would let slot 0's adverse
        //      verdict bleed into slot 1's hold-band event (that event would
        //      read the shared register = 1, hold it, and pulse adverse) --
        //      which is exactly the S0 cross-contamination this regression
        //      exists to catch. Book is healthy for every slot throughout
        //      (bid/ask all valid, nothing crossed, seq_gap cleared above).
        fire(2'd2, -32'sd25);   // clear slot 2's tag-40 adverse, benign baseline
        chk(229, adverse_risk[2], 1'b0);
        settle;
        fire(2'd0, -32'sd25);   // slot 0 benign baseline
        chk4(230, adverse_risk, 4'b0000);   // all four slots benign now
        settle;

        // A: genuine adverse on slot 0 (z >= cfg_ml_th_high, healthy book)
        fire(2'd0, 32'sd25);
        chk(231, adverse_risk[0], 1'b1);   // slot 0 now adverse
        chk4(232, adverse_risk, 4'b0001);  // and only slot 0 is
        settle;

        // B: SEPARATE hold-band event on slot 1 (z = 0 in (-20,20), healthy
        //    book). Slot 1's OWN prior value is the reset 0 -- it must NOT
        //    inherit slot 0's just-set adverse bit.
        fire(2'd1, 32'sd0);
        chk(233, adverse_risk[1], 1'b0);   // slot 1 stays benign -- the crux
        chk(234, adverse_risk[0], 1'b1);   // slot 0's bit untouched by slot 1's event
        chk(235, ml_benign_pulse, 1'b1);   // pulse follows slot 1's OWN bit
        chk(236, ml_adverse_pulse, 1'b0);
        chk4(237, adverse_risk, 4'b0001);  // still only slot 0 adverse
        settle;

        // C: hold-band event back on slot 0: slot 0's OWN prior adverse must
        //    persist (its own hold reads its own bit).
        fire(2'd0, 32'sd0);
        chk(238, adverse_risk[0], 1'b1);   // slot 0 holds ITS OWN verdict
        chk(239, ml_adverse_pulse, 1'b1);  // pulse follows slot 0's held 1
        chk4(240, adverse_risk, 4'b0001);
        settle;

        // ---- risk_level saturation (FR-33 / S5.4) ----
        cfg_ml_score_offset = 32'd0;
        cfg_ml_score_shift  = 32'd0;
        fire(2'd0, 32'sd300);
        chk8(50, risk_level, 8'd255);   // saturates, does not wrap to 44
        settle;
        fire(2'd0, -32'sd50);
        chk8(51, risk_level, 8'd0);
        settle;
        // mid-range with a nonzero shift: (100 >> 2) = 25
        cfg_ml_score_shift = 32'd2;
        fire(2'd0, 32'sd100);
        chk8(52, risk_level, 8'd25);
        settle;
        cfg_ml_score_shift = 32'd0;

        // ---- no ml_valid: outputs hold, no pulse ----
        fire(2'd0, 32'sd25);
        settle;
        chk(60, ml_event_valid, 1'b0);
        chk(61, ml_adverse_pulse, 1'b0);
        chk(62, ml_benign_pulse, 1'b0);
        chk(63, ml_safe_forced_pulse, 1'b0);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
