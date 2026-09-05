`timescale 1ns / 1ps

// Self-checking testbench for rtl/order_builder.v (master spec S3.1 [J],
// S4.5, FR-49..52; contract docs/contracts/order_builder.md S3).
//
// Icarus:
//   iverilog -g2001 -Wall -o order_builder_tb.vvp rtl/order_builder.v tb/tb_order_builder.v
//   vvp order_builder_tb.vvp
//
// order_builder takes risk_engine.v's accept/reject decision, encodes it into
// the 16-byte order-record wire format, and drives it through eth_mac_if.v's
// fixed TX interface -- queueing up to two records (q0/q1) while the MAC is
// busy. The two bits of per-message identity the rest of the pipeline drops
// (symbol_id, trigger_seq) are recovered here: symbol_id via a combinational
// slot->cfg_symbol_* lookup, trigger_seq via an UNCONDITIONAL two-stage shift
// register off msg_seq_num whose alignment is automatic by construction
// (signal_engine+risk_engine add exactly two registered cycles between a
// msg_valid and the matching order_valid/reject_reason, contract S2.2).
//
// To drive the DUT we stand in for md_parser/risk_engine with a small
// cycle-accurate model of that same contract:
//   * a message with seq S is "received" by driving msg_seq_num = S on the
//     cycle that is ITS msg_valid cycle;
//   * its risk decision (order_valid / reject_reason) is driven EXACTLY two
//     cycles later.  The DUT itself never sees these two signals tied
//     together; it aligns them via its own shift register, so if the DUT's
//     pipeline depth were wrong the tb's expected trigger_seq (taken from
//     the message two cycles back) would disagree with the payload.
//
// tx_busy is a behavioral stand-in for eth_mac_if.v's TX side that models
// the documented ONE-CYCLE LAG (eth_mac_if.v's FSM samples tx_start on a
// clock edge and only then leaves TX_IDLE): tx_busy reads 0 on the exact
// cycle a tx_start pulse is high and only asserts the cycle after. A
// force_busy override plus a per-pulse busy_hold length let each test
// script queue build-up and drain pacing. This lag is what makes the
// ~tx_start self-gating in the DUT observable -- an idealized same-cycle
// tx_busy model would hide the double-issue bug this testbench exists to
// catch (contract S3's "single most important case").
//
// The tb keeps a per-cycle history (cc_of = cur_cycle value that cycle,
// seq_of = msg_seq_num driven that cycle) and an expected-record FIFO
// mirroring every accepted push. Each observed tx_start pulse is checked
// against the FIFO head: full 128-bit payload, symbol_id via the cfg lookup,
// and latency_cyc computed as (cur_cycle at the pop cycle) - (cur_cycle at
// the triggering message's cycle) -- i.e. exactly what the DUT must compute
// at pop time, which is how the queueing case proves latency is not frozen
// at push time.
//
// Cases (contract S3):
//   T1    single accepted order, no backpressure: correct 16-byte payload,
//         one tx_start pulse, latency = actual elapsed cycles
//   T2    rejected intent, cfg_reject_report=1: 0x11 frame, reason byte
//   T3    rejected intent, cfg_reject_report=0 (FR-44 default): nothing
//         pushed/transmitted, q_count never increments
//   T4    queueing behind a long TX busy: two records both transmit, in
//         order (FR-51), each latency_cyc reflecting its own actual wait
//   T5    overflow: third decision with both slots occupied fires
//         cnt_order_overflow_pulse and is dropped; first two still drain
//   T6    simultaneous push+pop: a decision on the exact cycle a pop
//         completes is accepted, NOT overflow (count_after_pop, S2.4)
//   T7    the ~tx_start self-gating footgun directly (S2.5): with the
//         lagging tx_busy stand-in, exactly one tx_start pulse per queued
//         record -- never two back-to-back (pulse spacing >= 2 cycles)
//   T8    trigger_seq/symbol_id/latency alignment across interleaved
//         messages with distinct seq_nums, some silent -- each record's
//         trigger_seq is its own message's, not a neighbor's
//
// On any mismatch a FAIL line names the record and expected vs actual; a
// final PASS/FAIL line summarizes. Verilog-2001 only.

module tb_order_builder;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    // ---- free-running cycle counter for cur_cycle ----
    reg [31:0] cyc = 32'd0;
    always @(posedge clk) cyc <= cyc + 32'd1;
    wire [31:0] cur_cycle;
    assign cur_cycle = cyc;

    // ---- DUT inputs ----
    reg        rst_n = 1'b0;
    reg [31:0] msg_seq_num = 32'd0;
    reg        order_valid = 1'b0;
    reg [1:0]  order_slot = 2'd0;
    reg [7:0]  order_side = 8'd0;
    reg [31:0] order_price = 32'd0;
    reg [31:0] order_qty = 32'd0;
    reg [7:0]  reject_reason = 8'd0;
    reg [7:0]  cfg_symbol_0 = 8'h11;
    reg [7:0]  cfg_symbol_1 = 8'h22;
    reg [7:0]  cfg_symbol_2 = 8'h33;
    reg [7:0]  cfg_symbol_3 = 8'h44;
    reg        cfg_reject_report = 1'b0;

    // -----------------------------------------------------------------
    // tx_busy behavioral stand-in (models eth_mac_if.v's one-cycle lag).
    // Declared before the DUT instance so its net exists at the port.
    //   * force_busy: test control to hold TX busy indefinitely (queue
    //     build-up without draining).
    //   * When not forced, a tx_start pulse observed high for a cycle makes
    //     tx_busy assert the FOLLOWING cycle (never the pulse's own cycle --
    //     that is the documented lag, contract S1.3/S2.5) and stay high for
    //     busy_hold cycles.
    // -----------------------------------------------------------------
    reg        force_busy = 1'b0;
    reg [15:0] busy_hold  = 16'd1;
    reg        lag_busy;
    reg [15:0] busy_rem;
    wire tx_busy;
    assign tx_busy = force_busy | lag_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lag_busy <= 1'b0;
            busy_rem <= 16'd0;
        end else if (lag_busy) begin
            if (busy_rem == 16'd0) lag_busy <= 1'b0;
            else                   busy_rem <= busy_rem - 16'd1;
        end else if (tx_start) begin
            lag_busy <= 1'b1;
            busy_rem <= busy_hold - 16'd1;
        end
    end

    // ---- DUT outputs ----
    wire [127:0] tx_payload;
    wire         tx_start;
    wire         cnt_order_overflow_pulse;

    order_builder dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .msg_seq_num          (msg_seq_num),
        .order_valid          (order_valid),
        .order_slot           (order_slot),
        .order_side           (order_side),
        .order_price          (order_price),
        .order_qty            (order_qty),
        .reject_reason        (reject_reason),
        .cur_cycle            (cur_cycle),
        .cfg_symbol_0         (cfg_symbol_0),
        .cfg_symbol_1         (cfg_symbol_1),
        .cfg_symbol_2         (cfg_symbol_2),
        .cfg_symbol_3         (cfg_symbol_3),
        .cfg_reject_report    (cfg_reject_report),
        .tx_payload           (tx_payload),
        .tx_start             (tx_start),
        .tx_busy              (tx_busy),
        .cnt_order_overflow_pulse (cnt_order_overflow_pulse)
    );

    localparam [7:0] SIDE_BID = 8'h00;
    localparam [7:0] SIDE_ASK = 8'h01;

    // ---- per-cycle history and expected-record FIFO ----
    integer w;                  // current cycle index, restarted per test
    reg  [31:0] cc_of  [0:127]; // cur_cycle value during that cycle
    reg  [15:0] seq_of [0:127]; // msg_seq_num driven during that cycle

    reg  [7:0]  x_type  [0:15]; // expected pushed records, FIFO
    reg  [7:0]  x_sym   [0:15];
    reg  [7:0]  x_side  [0:15];
    reg  [7:0]  x_rej   [0:15];
    reg  [31:0] x_price [0:15];
    reg  [31:0] x_qty   [0:15];
    reg  [15:0] x_seq   [0:15];
    reg  [31:0] x_msgcc [0:15]; // cur_cycle value at the triggering msg
    integer x_n;                // records pushed into the model
    integer x_head;             // next expected record to transmit

    integer ntx;                // tx_start pulses observed
    integer ovf_seen;           // cnt_order_overflow_pulse cycles observed
    integer pw [0:15];          // window index each pulse's pop occurred in
    reg    ovf_here;
    reg    fail = 1'b0;

    // ---- symbol for a slot: the same cfg registers the DUT reads ----
    function [7:0] sym_of_slot;
        input [1:0] slot;
        begin
            case (slot)
                2'd0:   sym_of_slot = cfg_symbol_0;
                2'd1:   sym_of_slot = cfg_symbol_1;
                2'd2:   sym_of_slot = cfg_symbol_2;
                default: sym_of_slot = cfg_symbol_3;
            endcase
        end
    endfunction

    // ---- assert + release reset, clear bookkeeping ----
    task reset_test;
        begin
            @(negedge clk);
            order_valid     = 1'b0;
            reject_reason   = 8'd0;
            msg_seq_num     = 32'd0;
            order_slot      = 2'd0;
            order_side      = 8'd0;
            order_price     = 32'd0;
            order_qty       = 32'd0;
            cfg_reject_report = 1'b0;
            force_busy      = 1'b0;
            rst_n           = 1'b0;
            repeat (3) @(negedge clk);
            rst_n           = 1'b1;
            w       = 0;
            ntx     = 0;
            x_n     = 0;
            x_head  = 0;
            ovf_seen = 0;
            @(posedge clk);
            #1;
        end
    endtask

    // ---- drive one cycle, then observe ----
    // Inputs are set from the negedge so they are stable for the whole
    // cycle and sampled at its closing posedge. cnt_order_overflow_pulse is
    // combinational and is read pre-posedge; tx_start/tx_payload are
    // registered outputs and are read post-posedge, so a tx_start high here
    // means a record was popped during this cycle (payload already valid).
    task step(
        input [31:0] seq,
        input        ov,
        input [1:0]  slot,
        input [7:0]  side,
        input [31:0] price,
        input [31:0] qty,
        input [7:0]  rej
    );
        integer idx;
        reg [31:0] diff;
        reg [127:0] exp;
        reg [15:0] lat;
        begin
            @(negedge clk);
            cc_of[w]  = cyc;
            seq_of[w] = seq[15:0];
            msg_seq_num   = seq;
            order_valid   = ov;
            order_slot    = slot;
            order_side    = side;
            order_price   = price;
            order_qty     = qty;
            reject_reason = rej;
            #1;
            ovf_here = cnt_order_overflow_pulse;
            if (ovf_here) ovf_seen = ovf_seen + 1;

            // Expected-model push: mirrors the DUT's want_push/overflow
            // decision for THIS cycle. The triggering message is the one
            // whose seq/cycle was driven two cycles ago (contract S2.2).
            if (w >= 2) begin
                if (ov || (cfg_reject_report && (rej != 8'd0))) begin
                    if (!ovf_here) begin
                        if (x_n > 15) begin
                            $display("FAIL: expected-record table overflow");
                            fail = 1'b1;
                        end else begin
                            x_type[x_n]  = ov ? 8'h10 : 8'h11;
                            x_sym[x_n]   = sym_of_slot(slot);
                            x_side[x_n]  = side;
                            x_rej[x_n]   = rej;
                            x_price[x_n] = price;
                            x_qty[x_n]   = qty;
                            x_seq[x_n]   = seq_of[w-2];
                            x_msgcc[x_n] = cc_of[w-2];
                            x_n = x_n + 1;
                        end
                    end
                end
            end

            @(posedge clk);
            #1;
            if (tx_start) begin
                pw[ntx] = w;
                if (x_head >= x_n) begin
                    $display("FAIL: unexpected tx_start at window %0d (no expected record pending)", w);
                    fail = 1'b1;
                end else begin
                    idx  = x_head;
                    diff = cc_of[w] - x_msgcc[idx];
                    lat  = diff[15:0];
                    exp  = {x_type[idx], x_sym[idx], x_side[idx], x_rej[idx],
                            x_price[idx], x_qty[idx], x_seq[idx], lat};
                    if (tx_payload !== exp) begin
                        $display("FAIL: TX payload mismatch at window %0d (record %0d)", w, ntx);
                        $display("  expected: type=%02x sym=%02x side=%02x rej=%02x price=%0d qty=%0d trig_seq=%04x latency=%0d",
                                 x_type[idx], x_sym[idx], x_side[idx], x_rej[idx],
                                 x_price[idx], x_qty[idx], x_seq[idx], lat);
                        $display("  actual  : type=%02x sym=%02x side=%02x rej=%02x price=%0d qty=%0d trig_seq=%04x latency=%0d",
                                 tx_payload[127:120], tx_payload[119:112],
                                 tx_payload[111:104], tx_payload[103:96],
                                 tx_payload[95:64], tx_payload[63:32],
                                 tx_payload[31:16], tx_payload[15:0]);
                        fail = 1'b1;
                    end
                    x_head = x_head + 1;
                end
                ntx = ntx + 1;
            end
            w = w + 1;
        end
    endtask

    // ---- n idle cycles (no decisions) ----
    task idlec;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                step(32'd0, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);
        end
    endtask

    // ---- let everything drain, then check totals ----
    task drain_and_check;
        input integer n;
        begin
            idlec(n);
            if (ntx !== x_n) begin
                $display("FAIL: %0d tx_start pulses observed, expected %0d", ntx, x_n);
                fail = 1'b1;
            end
            if (x_head !== x_n) begin
                $display("FAIL: %0d expected records consumed, expected %0d", x_head, x_n);
                fail = 1'b1;
            end
            if (dut.q_count !== 2'd0) begin
                $display("FAIL: queue not empty after drain (q_count=%0d)", dut.q_count);
                fail = 1'b1;
            end
        end
    endtask

    // =================================================================
    // Testbench driver
    // =================================================================
    integer i;

    initial begin
        // ============ T1: single accepted order, no backpressure ============
        reset_test;
        // w0: message A received (seq 0x1111). w2: its accepted decision.
        step(32'h0000_1111, 1'b0, 2'd0, 8'd0,       32'd0,   32'd0,  8'd0);
        step(32'd0,         1'b0, 2'd0, 8'd0,       32'd0,   32'd0,  8'd0);
        step(32'd0,         1'b1, 2'd0, SIDE_BID,   32'd1250, 32'd100, 8'd0);
        drain_and_check(12);
        if (x_n !== 1) begin $display("FAIL: T1 expected 1 record, got %0d", x_n); fail = 1'b1; end
        if (ovf_seen !== 0) begin $display("FAIL: T1 unexpected overflow"); fail = 1'b1; end
        // latency for the immediate case must equal the actual 3-cycle gap
        // (msg at w0, pop at w3) -- checked inline via cc_of, restated here:
        if (pw[0] !== 3) begin
            $display("FAIL: T1 pop window %0d, expected 3 (immediate drain)", pw[0]);
            fail = 1'b1;
        end

        // ============ T2: rejected intent, cfg_reject_report=1 ============
        reset_test;
        cfg_reject_report = 1'b1;
        step(32'h0000_2222, 1'b0, 2'd0, 8'd0,       32'd0,    32'd0,  8'd0);  // w0 msg
        step(32'd0,         1'b0, 2'd0, 8'd0,       32'd0,    32'd0,  8'd0);
        step(32'd0,         1'b0, 2'd1, SIDE_ASK,   32'd70000, 32'd250, 8'd4); // w2 reject
        drain_and_check(12);
        if (x_n !== 1) begin $display("FAIL: T2 expected 1 record, got %0d", x_n); fail = 1'b1; end
        if (x_type[0] !== 8'h11) begin $display("FAIL: T2 msg_type=%02x, expected 11", x_type[0]); fail = 1'b1; end
        if (x_rej[0]  !== 8'd4)  begin $display("FAIL: T2 reject_reason=%0d, expected 4", x_rej[0]); fail = 1'b1; end
        if (ovf_seen !== 0) begin $display("FAIL: T2 unexpected overflow"); fail = 1'b1; end

        // ============ T3: rejected intent, cfg_reject_report=0 (default) ============
        reset_test;   // cfg_reject_report defaults to 0 (FR-44)
        step(32'h0000_3333, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);   // w0 msg
        step(32'd0,         1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);
        step(32'd0,         1'b0, 2'd2, SIDE_ASK, 32'd500, 32'd10, 8'd6); // w2 reject (report off)
        idlec(8);
        if (ntx !== 0) begin $display("FAIL: T3 %0d transmissions with reject reporting off", ntx); fail = 1'b1; end
        if (x_n !== 0) begin $display("FAIL: T3 expected 0 records, got %0d", x_n); fail = 1'b1; end
        if (ovf_seen !== 0) begin $display("FAIL: T3 unexpected overflow"); fail = 1'b1; end
        if (dut.q_count !== 2'd0) begin $display("FAIL: T3 queue incremented with reporting off"); fail = 1'b1; end

        // ============ T4: queueing behind a busy TX; latency at pop time ============
        reset_test;
        force_busy = 1'b1;          // hold TX busy so pushes queue, not drain
        busy_hold  = 16'd2;
        step(32'h0000_B2B2, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);   // w0: B message
        step(32'h0000_C3C3, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);   // w1: C message
        step(32'd0,         1'b1, 2'd1, SIDE_ASK, 32'd2000, 32'd60, 8'd0); // w2: push B
        step(32'd0,         1'b1, 2'd2, SIDE_BID, 32'd3000, 32'd70, 8'd0); // w3: push C
        if (dut.q_count !== 2'd2) begin $display("FAIL: T4 q_count=%0d after two queued pushes", dut.q_count); fail = 1'b1; end
        force_busy = 1'b0;          // release: B pops w4, C waits for B's own TX
        drain_and_check(16);
        if (x_n !== 2) begin $display("FAIL: T4 expected 2 records, got %0d", x_n); fail = 1'b1; end
        if (ovf_seen !== 0) begin $display("FAIL: T4 unexpected overflow"); fail = 1'b1; end
        // Each record's latency must reflect its OWN wait from msg to pop
        // (w0->w4 for B, w1->w8 for C with busy_hold=2), NOT a push-time
        // value -- the inline payload check already enforced this, restated:
        if (pw[1] - pw[0] < 2) begin $display("FAIL: T4 pulses too close together"); fail = 1'b1; end

        // ============ T5: overflow -- third decision with both slots full ============
        reset_test;
        force_busy = 1'b1;
        busy_hold  = 16'd1;
        step(32'h0000_B2B2, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);   // w0: B message
        step(32'h0000_C3C3, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);   // w1: C message
        step(32'd0,         1'b1, 2'd1, SIDE_ASK, 32'd2000, 32'd60, 8'd0); // w2: push B
        step(32'd0,         1'b1, 2'd2, SIDE_BID, 32'd3000, 32'd70, 8'd0); // w3: push C  (full)
        if (dut.q_count !== 2'd2) begin $display("FAIL: T5 q_count=%0d before overflow", dut.q_count); fail = 1'b1; end
        step(32'h0000_D4D4, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);   // w4: D message
        step(32'd0,         1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);   // w5
        step(32'd0,         1'b1, 2'd3, SIDE_ASK, 32'd4000, 32'd80, 8'd0); // w6: D decision -> OVERFLOW, dropped
        if (ovf_seen !== 1) begin $display("FAIL: T5 overflow pulses=%0d, expected 1", ovf_seen); fail = 1'b1; end
        force_busy = 1'b0;
        drain_and_check(16);
        if (x_n !== 2) begin $display("FAIL: T5 expected 2 records (overflowed one dropped), got %0d", x_n); fail = 1'b1; end

        // ============ T6: simultaneous push + pop at full queue ============
        reset_test;
        force_busy = 1'b1;
        busy_hold  = 16'd1;
        step(32'h0000_B2B2, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);   // w0: B message
        step(32'h0000_C3C3, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);   // w1: C message
        step(32'h0000_E5E5, 1'b1, 2'd1, SIDE_ASK, 32'd2000, 32'd60, 8'd0); // w2: push B (E message rides same cycle)
        step(32'd0,         1'b1, 2'd2, SIDE_BID, 32'd3000, 32'd70, 8'd0); // w3: push C  (full)
        if (dut.q_count !== 2'd2) begin $display("FAIL: T6 q_count=%0d before release", dut.q_count); fail = 1'b1; end
        force_busy = 1'b0;          // release AND decide E on the same cycle B pops:
        step(32'd0,         1'b1, 2'd3, SIDE_ASK, 32'd5000, 32'd90, 8'd0); // w4: E push accepted, B pops
        if (ovf_seen !== 0) begin $display("FAIL: T6 overflow on simultaneous push+pop (must be accepted)"); fail = 1'b1; end
        drain_and_check(20);
        if (x_n !== 3) begin $display("FAIL: T6 expected 3 records, got %0d", x_n); fail = 1'b1; end

        // ============ T7: ~tx_start self-gating footgun (S2.5) ============
        reset_test;
        force_busy = 1'b1;          // load two records behind busy...
        busy_hold  = 16'd1;         // ...then drain with minimal per-pulse occupancy
        step(32'h0000_B2B2, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);
        step(32'h0000_C3C3, 1'b0, 2'd0, 8'd0,    32'd0,  32'd0, 8'd0);
        step(32'd0,         1'b1, 2'd1, SIDE_ASK, 32'd2000, 32'd60, 8'd0); // w2: push B
        step(32'd0,         1'b1, 2'd2, SIDE_BID, 32'd3000, 32'd70, 8'd0); // w3: push C
        force_busy = 1'b0;
        drain_and_check(14);
        if (ntx !== 2) begin $display("FAIL: T7 %0d tx_start pulses for 2 records (double-issue?)", ntx); fail = 1'b1; end
        if (ntx >= 2) begin
            if (pw[1] - pw[0] < 2) begin
                $display("FAIL: T7 back-to-back tx_start pulses (windows %0d, %0d) -- ~tx_start self-gating missing", pw[0], pw[1]);
                fail = 1'b1;
            end
        end
        if (ovf_seen !== 0) begin $display("FAIL: T7 unexpected overflow"); fail = 1'b1; end

        // ============ T8: trigger_seq alignment across interleaved messages ============
        reset_test;
        cfg_reject_report = 1'b1;
        // Every cycle carries a message with a distinct seq; each message's
        // decision slot lands exactly two cycles later. Some fire, some are
        // silent.  Pushes: A@w2, C@w4, D@w5(reject), E@w6.
        step(32'h0000_6001, 1'b0, 2'd0, 8'd0,         32'd0, 32'd0, 8'd0); // w0: msg A
        step(32'h0000_7002, 1'b0, 2'd0, 8'd0,         32'd0, 32'd0, 8'd0); // w1: msg B (silent)
        step(32'h0000_8003, 1'b1, 2'd0, SIDE_BID,     32'd1250, 32'd100, 8'd0); // w2: msg C + A's decision
        step(32'h0000_9004, 1'b0, 2'd0, 8'd0,         32'd0,   32'd0,  8'd0);   // w3: msg D (B silent)
        step(32'h0000_A005, 1'b1, 2'd1, SIDE_ASK,     32'd2000, 32'd60,  8'd0); // w4: msg E + C's decision
        step(32'h0000_B006, 1'b0, 2'd2, SIDE_BID,     32'd3000, 32'd70,  8'd5); // w5: msg F + D's reject decision
        step(32'h0000_C007, 1'b1, 2'd3, SIDE_BID,     32'd4000, 32'd80,  8'd0); // w6: msg G + E's decision
        step(32'h0000_D008, 1'b0, 2'd0, 8'd0,         32'd0,   32'd0,  8'd0);   // w7: msg H (F silent)
        drain_and_check(16);
        if (x_n !== 4) begin $display("FAIL: T8 expected 4 records, got %0d", x_n); fail = 1'b1; end
        // Per-record trigger_seq is checked inline; restate the key mapping:
        if (x_seq[0] !== 16'h6001) begin $display("FAIL: T8 record0 trigger_seq=%04x, expected 6001", x_seq[0]); fail = 1'b1; end
        if (x_seq[1] !== 16'h8003) begin $display("FAIL: T8 record1 trigger_seq=%04x, expected 8003", x_seq[1]); fail = 1'b1; end
        if (x_seq[2] !== 16'h9004) begin $display("FAIL: T8 record2 trigger_seq=%04x, expected 9004", x_seq[2]); fail = 1'b1; end
        if (x_seq[3] !== 16'hA005) begin $display("FAIL: T8 record3 trigger_seq=%04x, expected A005", x_seq[3]); fail = 1'b1; end
        if (x_type[2] !== 8'h11) begin $display("FAIL: T8 record2 type=%02x, expected 11 (reject)", x_type[2]); fail = 1'b1; end
        if (ovf_seen !== 0) begin $display("FAIL: T8 unexpected overflow"); fail = 1'b1; end

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
