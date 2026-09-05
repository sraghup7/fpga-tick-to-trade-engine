`timescale 1ns / 1ps

// Self-checking testbench for rtl/order_builder.v's TRIGGER_DELAY
// parameterization (D25, contract docs/contracts/order_builder_trigger_
// delay_patch.md S2.3). tb_order_builder.v already proves the DEFAULT
// (TRIGGER_DELAY=2) behavior byte-for-byte; this file proves the
// parameterization itself at non-default depths -- the real value tob_top.v
// uses (5 = 2 + ALIGN_DEPTH) and the minimum (1).
//
// Icarus:
//   iverilog -g2001 -Wall -o order_builder_delay_tb.vvp rtl/order_builder.v rtl/common/delay_line.v tb/tb_order_builder_delay.v
//   vvp order_builder_delay_tb.vvp
//
// Model: each `step` drives one window. A decision presented during window d
// (order_valid=1) pushes at the end of window d; its triggering message is
// the one driven TRIGGER_DELAY cycles before the decision (window d-DEPTH).
// Per-DUT expected-record FIFOs mirror every push and are drained on each
// tx_start pulse (same pattern as tb_order_builder.v), so the check is
// independent of the pop scheduling -- which the ~tx_start self-gating spaces
// out by >=2 cycles for back-to-back decisions. tx_busy is tied low.
//
// Two DUTs share the same stimulus at depths 5 and 1; each pop is checked
// against its own depth's expectation.
//
// Verilog-2001 only.

module tb_order_builder_delay;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    // ---- free-running cycle counter ----
    reg [31:0] cyc = 32'd0;
    always @(posedge clk) cyc <= cyc + 32'd1;
    wire [31:0] cur_cycle;
    assign cur_cycle = cyc;

    // ---- shared stimulus ----
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

    // ---- DUT5 (the value tob_top.v actually uses) ----
    wire [127:0] tx_payload5;
    wire         tx_start5;
    order_builder #(.TRIGGER_DELAY(5)) dut5 (
        .clk(clk), .rst_n(rst_n),
        .msg_seq_num(msg_seq_num),
        .order_valid(order_valid), .order_slot(order_slot), .order_side(order_side),
        .order_price(order_price), .order_qty(order_qty), .reject_reason(reject_reason),
        .cur_cycle(cur_cycle),
        .cfg_symbol_0(cfg_symbol_0), .cfg_symbol_1(cfg_symbol_1),
        .cfg_symbol_2(cfg_symbol_2), .cfg_symbol_3(cfg_symbol_3),
        .cfg_reject_report(cfg_reject_report),
        .tx_payload(tx_payload5), .tx_start(tx_start5), .tx_busy(1'b0),
        .cnt_order_overflow_pulse()
    );

    // ---- DUT1 (minimum depth) ----
    wire [127:0] tx_payload1;
    wire         tx_start1;
    order_builder #(.TRIGGER_DELAY(1)) dut1 (
        .clk(clk), .rst_n(rst_n),
        .msg_seq_num(msg_seq_num),
        .order_valid(order_valid), .order_slot(order_slot), .order_side(order_side),
        .order_price(order_price), .order_qty(order_qty), .reject_reason(reject_reason),
        .cur_cycle(cur_cycle),
        .cfg_symbol_0(cfg_symbol_0), .cfg_symbol_1(cfg_symbol_1),
        .cfg_symbol_2(cfg_symbol_2), .cfg_symbol_3(cfg_symbol_3),
        .cfg_reject_report(cfg_reject_report),
        .tx_payload(tx_payload1), .tx_start(tx_start1), .tx_busy(1'b0),
        .cnt_order_overflow_pulse()
    );

    // ---- per-cycle history ----
    integer w;
    reg [31:0] cc_of  [0:127];
    reg [15:0] seq_of [0:127];

    // ---- expected-record FIFOs (per DUT): trigger_seq + message cycle ----
    reg [15:0] x_seq5 [0:15];
    reg [31:0] x_cc5  [0:15];
    integer    n5, h5;
    reg [15:0] x_seq1 [0:15];
    reg [31:0] x_cc1  [0:15];
    integer    n1, h1;

    reg     fail = 1'b0;

    task reset_test;
        begin
            @(negedge clk);
            order_valid   = 1'b0;
            reject_reason = 8'd0;
            msg_seq_num   = 32'd0;
            order_slot    = 2'd0;
            order_side    = 8'd0;
            order_price   = 32'd0;
            order_qty     = 32'd0;
            rst_n         = 1'b0;
            repeat (3) @(negedge clk);
            rst_n         = 1'b1;
            w  = 0;
            n5 = 0; h5 = 0;
            n1 = 0; h1 = 0;
            @(posedge clk);
            #1;
        end
    endtask

    // Present one window and check any pop inline. The triggering message for
    // a decision at window w is at window w-DEPTH (recorded at push time), so
    // the check is correct regardless of when the pop is scheduled.
    task step(
        input [31:0] seq,
        input        ov,
        input [1:0]  slot,
        input [7:0]  side,
        input [31:0] price,
        input [31:0] qty,
        input [7:0]  rej
    );
        integer d5, d1;
        reg [31:0] e5, e1;
        begin
            @(negedge clk);
            cc_of[w]  = cyc;
            seq_of[w] = seq[15:0];
            msg_seq_num = seq;
            order_valid = ov;
            order_slot  = slot;
            order_side  = side;
            order_price = price;
            order_qty   = qty;
            reject_reason = rej;

            // Expected-model push (accepted + reject-report records only; this
            // tb never overflows). A decision here is triggered by the message
            // driven DEPTH windows earlier.
            if (ov) begin
                d5 = w - 5;
                d1 = w - 1;
                if (d5 >= 0) begin x_seq5[n5] = seq_of[d5]; x_cc5[n5] = cc_of[d5]; n5 = n5 + 1; end
                if (d1 >= 0) begin x_seq1[n1] = seq_of[d1]; x_cc1[n1] = cc_of[d1]; n1 = n1 + 1; end
            end

            @(posedge clk);
            #1;
            if (tx_start5) begin
                if (h5 >= n5) begin
                    $display("FAIL: dut5 unexpected tx_start at window %0d", w);
                    fail = 1'b1;
                end else begin
                    if (tx_payload5[31:16] !== x_seq5[h5]) begin
                        $display("FAIL: dut5 trigger_seq=%04x, expected %04x (window %0d)",
                                 tx_payload5[31:16], x_seq5[h5], w);
                        fail = 1'b1;
                    end
                    e5 = cc_of[w] - x_cc5[h5];
                    if (tx_payload5[15:0] !== e5[15:0]) begin
                        $display("FAIL: dut5 latency_cyc=%0d, expected %0d (window %0d)",
                                 tx_payload5[15:0], e5[15:0], w);
                        fail = 1'b1;
                    end
                    h5 = h5 + 1;
                end
            end
            if (tx_start1) begin
                if (h1 >= n1) begin
                    $display("FAIL: dut1 unexpected tx_start at window %0d", w);
                    fail = 1'b1;
                end else begin
                    if (tx_payload1[31:16] !== x_seq1[h1]) begin
                        $display("FAIL: dut1 trigger_seq=%04x, expected %04x (window %0d)",
                                 tx_payload1[31:16], x_seq1[h1], w);
                        fail = 1'b1;
                    end
                    e1 = cc_of[w] - x_cc1[h1];
                    if (tx_payload1[15:0] !== e1[15:0]) begin
                        $display("FAIL: dut1 latency_cyc=%0d, expected %0d (window %0d)",
                                 tx_payload1[15:0], e1[15:0], w);
                        fail = 1'b1;
                    end
                    h1 = h1 + 1;
                end
            end
            w = w + 1;
        end
    endtask

    task idlec;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                step(32'd0, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);
        end
    endtask

    initial begin
        // ============ Block A: direct regression at DEPTH=5 ============
        // Drive five distinct seq values at windows 0..4, then a decision at
        // window 5. dut5's trigger_seq must be seq_of[0] (5 cycles earlier),
        // NOT seq_of[3] (the 2-cycles-earlier value a fixed-2-cycle DUT would
        // misattribute) -- the exact numeric signature of D25. The same
        // decision also exercises dut1 (DEPTH=1 -> seq_of[4]).
        reset_test;
        step(32'h0000_1111, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w0
        step(32'h0000_2222, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w1
        step(32'h0000_3333, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w2
        step(32'h0000_4444, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w3
        step(32'h0000_5555, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w4
        step(32'd0,        1'b1, 2'd0, 8'h00, 32'd1250, 32'd100, 8'd0);  // w5 decision
        idlec(6);
        if (h5 !== n5) begin $display("FAIL: Block A dut5 %0d pops vs %0d pushes", h5, n5); fail = 1'b1; end
        if (h1 !== n1) begin $display("FAIL: Block A dut1 %0d pops vs %0d pushes", h1, n1); fail = 1'b1; end

        // ============ Block B: two decisions close together at DEPTH=5 ======
        // Each decision tracks its OWN triggering message (not a neighbor's)
        // despite the ~tx_start self-gating spacing the two pops apart.
        // Message A@w0 (0xAAAA), B@w1 (0xBBBB); decision A@w5, decision B@w6.
        reset_test;
        step(32'h0000_AAAA, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w0 msg A
        step(32'h0000_BBBB, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w1 msg B
        step(32'h0000_CCCC, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w2
        step(32'h0000_DDDD, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w3
        step(32'h0000_EEEE, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w4
        step(32'd0,        1'b1, 2'd0, 8'h00, 32'd1250, 32'd100, 8'd0);  // w5 decision A
        step(32'd0,        1'b1, 2'd1, 8'h01, 32'd1300, 32'd50,  8'd0);  // w6 decision B
        idlec(8);
        if (h5 !== n5) begin $display("FAIL: Block B dut5 %0d pops vs %0d pushes", h5, n5); fail = 1'b1; end
        if (n5 !== 2)  begin $display("FAIL: Block B expected 2 dut5 pushes, got %0d", n5); fail = 1'b1; end
        if (x_seq5[0] !== 16'hAAAA) begin $display("FAIL: Block B record0 trigger_seq=%04x exp AAAA", x_seq5[0]); fail = 1'b1; end
        if (x_seq5[1] !== 16'hBBBB) begin $display("FAIL: Block B record1 trigger_seq=%04x exp BBBB", x_seq5[1]); fail = 1'b1; end

        // ============ Block C: minimum depth (DEPTH=1), explicit ============
        // dut1's boundary case, with enough history for BOTH depths so the
        // shared decision is well-formed: message @w0, decision @w5. dut1's
        // trigger_seq must be seq_of[4] (1 cycle earlier), dut5's seq_of[0].
        reset_test;
        step(32'h0000_7000, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w0
        step(32'h0000_7100, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w1
        step(32'h0000_7200, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w2
        step(32'h0000_7300, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w3
        step(32'h0000_7400, 1'b0, 2'd0, 8'd0, 32'd0, 32'd0, 8'd0);   // w4
        step(32'd0,        1'b1, 2'd2, 8'h00, 32'd2000, 32'd70, 8'd0);   // w5 decision
        idlec(6);
        if (h1 !== n1) begin $display("FAIL: Block C dut1 %0d pops vs %0d pushes", h1, n1); fail = 1'b1; end
        if (n1 !== 1)  begin $display("FAIL: Block C expected 1 dut1 push, got %0d", n1); fail = 1'b1; end
        if (x_seq1[0] !== 16'h7400) begin $display("FAIL: Block C dut1 trigger_seq=%04x exp 7400 (1 cycle earlier)", x_seq1[0]); fail = 1'b1; end

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
