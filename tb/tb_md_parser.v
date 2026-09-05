`timescale 1ns / 1ps

// Self-checking testbench for rtl/md_parser.v.
//
// Icarus:
//   iverilog -g2001 -Wall -o md_parser_tb.vvp rtl/md_parser.v tb/tb_md_parser.v
//   vvp md_parser_tb.vvp
//
// Directed tests (master spec S11.4), fed as a continuous, already
// 16-byte-aligned stream (i.e. post frame_classifier.v -- this module has
// no frame-boundary awareness of its own, see rtl/md_parser.v's header):
//   T01 (FR-1,4)  one message decodes to exactly its wire fields
//   T02 (FR-4,6)  88 back-to-back messages (all four msg_types exercised)
//                 decode in order with no err_* pulses
//   T06 (FR-8,9)  an undefined msg_type and a reserved-flags message are
//                 each dropped (err_msg_type / err_flags, no msg_valid),
//                 and normal messages immediately before/after still
//                 decode correctly (parser stays byte-aligned)
//   plus a type-before-flags priority case: a message that is invalid in
//   BOTH ways (undefined msg_type AND a reserved flags bit) must fire
//   err_msg_type only -- matching sim/golden_model.py's process_message,
//   which returns at the msg_type check and never reaches the flags check.
//
// Verilog-2001 only.

module tb_md_parser;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg [7:0]  in_data = 8'd0;
    reg        in_valid = 1'b0;

    wire        msg_valid;
    wire [7:0]  msg_type;
    wire [7:0]  msg_symbol_id;
    wire [7:0]  msg_side;
    wire [7:0]  msg_flags;
    wire [31:0] msg_price;
    wire [31:0] msg_quantity;
    wire [31:0] msg_seq_num;
    wire        err_msg_type;
    wire        err_flags;

    md_parser dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .in_data       (in_data),
        .in_valid      (in_valid),
        .msg_valid     (msg_valid),
        .msg_type      (msg_type),
        .msg_symbol_id (msg_symbol_id),
        .msg_side      (msg_side),
        .msg_flags     (msg_flags),
        .msg_price     (msg_price),
        .msg_quantity  (msg_quantity),
        .msg_seq_num   (msg_seq_num),
        .err_msg_type  (err_msg_type),
        .err_flags     (err_flags)
    );

    reg fail = 1'b0;

    // ---- decoded-message collector (up to 128 messages per test) ----
    reg [7:0]  got_type   [0:127];
    reg [7:0]  got_sym    [0:127];
    reg [7:0]  got_side   [0:127];
    reg [7:0]  got_flags  [0:127];
    reg [31:0] got_price  [0:127];
    reg [31:0] got_qty    [0:127];
    reg [31:0] got_seq    [0:127];
    integer    got_cnt;
    integer    err_type_pulses;
    integer    err_flags_pulses;

    always @(posedge clk) begin
        if (msg_valid) begin
            got_type  [got_cnt] = msg_type;
            got_sym   [got_cnt] = msg_symbol_id;
            got_side  [got_cnt] = msg_side;
            got_flags [got_cnt] = msg_flags;
            got_price [got_cnt] = msg_price;
            got_qty   [got_cnt] = msg_quantity;
            got_seq   [got_cnt] = msg_seq_num;
            got_cnt = got_cnt + 1;
        end
        if (err_msg_type) err_type_pulses  = err_type_pulses  + 1;
        if (err_flags)    err_flags_pulses = err_flags_pulses + 1;
    end

    // Streams one 16-byte big-endian message onto in_data/in_valid.
    task send_msg;
        input [7:0]  m_type;
        input [7:0]  m_sym;
        input [7:0]  m_side;
        input [7:0]  m_flags;
        input [31:0] m_price;
        input [31:0] m_qty;
        input [31:0] m_seq;
        reg [127:0] frame;
        integer i;
        begin
            frame = {m_type, m_sym, m_side, m_flags, m_price, m_qty, m_seq};
            for (i = 0; i < 16; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_data  = frame[127 - 8*i -: 8];
            end
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    // Compares decoded message got_idx against the 7 fields it was sent as.
    task check_msg;
        input integer idx;
        input [7:0]  e_type;
        input [7:0]  e_sym;
        input [7:0]  e_side;
        input [7:0]  e_flags;
        input [31:0] e_price;
        input [31:0] e_qty;
        input [31:0] e_seq;
        begin
            if (got_type[idx]  !== e_type)  begin $display("FAIL: msg %0d type=%h expected %h",    idx, got_type[idx],  e_type);  fail = 1'b1; end
            if (got_sym[idx]   !== e_sym)   begin $display("FAIL: msg %0d sym=%h expected %h",     idx, got_sym[idx],   e_sym);   fail = 1'b1; end
            if (got_side[idx]  !== e_side)  begin $display("FAIL: msg %0d side=%h expected %h",    idx, got_side[idx],  e_side);  fail = 1'b1; end
            if (got_flags[idx] !== e_flags) begin $display("FAIL: msg %0d flags=%h expected %h",   idx, got_flags[idx], e_flags); fail = 1'b1; end
            if (got_price[idx] !== e_price) begin $display("FAIL: msg %0d price=%h expected %h",   idx, got_price[idx], e_price); fail = 1'b1; end
            if (got_qty[idx]   !== e_qty)   begin $display("FAIL: msg %0d qty=%h expected %h",     idx, got_qty[idx],   e_qty);   fail = 1'b1; end
            if (got_seq[idx]   !== e_seq)   begin $display("FAIL: msg %0d seq=%h expected %h",     idx, got_seq[idx],   e_seq);   fail = 1'b1; end
        end
    endtask

    integer k;

    initial begin
        rst_n = 1'b0;
        #20;
        rst_n = 1'b1;
        #20;

        // ---- T01: one QUOTE message, decodes exactly ----
        got_cnt = 0; err_type_pulses = 0; err_flags_pulses = 0;
        send_msg(8'h01, 8'h02, 8'h00, 8'h00, 32'h0000_1234, 32'h0000_0064, 32'h0000_0001);
        @(posedge clk); #1;   // let the final byte's registers settle

        if (got_cnt !== 1) begin
            $display("FAIL: T01 got_cnt=%0d, expected 1", got_cnt);
            fail = 1'b1;
        end else begin
            check_msg(0, 8'h01, 8'h02, 8'h00, 8'h00, 32'h0000_1234, 32'h0000_0064, 32'h0000_0001);
        end
        if (err_type_pulses !== 0 || err_flags_pulses !== 0) begin
            $display("FAIL: T01 spurious err pulses (type=%0d flags=%0d)", err_type_pulses, err_flags_pulses);
            fail = 1'b1;
        end

        // ---- T02: 88 back-to-back messages, all four msg_types cycled ----
        got_cnt = 0; err_type_pulses = 0; err_flags_pulses = 0;
        for (k = 0; k < 88; k = k + 1) begin
            case (k % 4)
                0: send_msg(8'h01, k[7:0], 8'h00, 8'h00, k, k+1, k+2);       // QUOTE
                1: send_msg(8'h02, k[7:0], 8'h01, 8'h00, k, k+1, k+2);       // TRADE
                2: send_msg(8'h03, k[7:0], 8'h00, 8'h00, k, k+1, k+2);       // CLEAR
                3: send_msg(8'hFF, k[7:0], 8'h00, 8'h00, k, k+1, k+2);       // HEARTBEAT
            endcase
        end
        @(posedge clk); #1;

        if (got_cnt !== 88) begin
            $display("FAIL: T02 got_cnt=%0d, expected 88", got_cnt);
            fail = 1'b1;
        end else begin
            for (k = 0; k < 88; k = k + 1) begin
                case (k % 4)
                    0: check_msg(k, 8'h01, k[7:0], 8'h00, 8'h00, k, k+1, k+2);
                    1: check_msg(k, 8'h02, k[7:0], 8'h01, 8'h00, k, k+1, k+2);
                    2: check_msg(k, 8'h03, k[7:0], 8'h00, 8'h00, k, k+1, k+2);
                    3: check_msg(k, 8'hFF, k[7:0], 8'h00, 8'h00, k, k+1, k+2);
                endcase
            end
        end
        if (err_type_pulses !== 0 || err_flags_pulses !== 0) begin
            $display("FAIL: T02 spurious err pulses (type=%0d flags=%0d)", err_type_pulses, err_flags_pulses);
            fail = 1'b1;
        end

        // ---- T06: undefined msg_type dropped, good messages around it OK ----
        got_cnt = 0; err_type_pulses = 0; err_flags_pulses = 0;
        send_msg(8'h01, 8'h05, 8'h00, 8'h00, 32'd10, 32'd20, 32'd30);   // good (before)
        send_msg(8'h07, 8'h05, 8'h00, 8'h00, 32'd11, 32'd21, 32'd31);   // undefined type -- dropped
        send_msg(8'h02, 8'h05, 8'h01, 8'h00, 32'd12, 32'd22, 32'd32);   // good (after)
        @(posedge clk); #1;

        if (got_cnt !== 2) begin
            $display("FAIL: T06 (bad type) got_cnt=%0d, expected 2", got_cnt);
            fail = 1'b1;
        end
        if (err_type_pulses !== 1) begin
            $display("FAIL: T06 (bad type) err_msg_type pulsed %0d times, expected 1", err_type_pulses);
            fail = 1'b1;
        end
        if (err_flags_pulses !== 0) begin
            $display("FAIL: T06 (bad type) err_flags pulsed %0d times, expected 0", err_flags_pulses);
            fail = 1'b1;
        end
        if (got_cnt >= 2) begin
            check_msg(0, 8'h01, 8'h05, 8'h00, 8'h00, 32'd10, 32'd20, 32'd30);
            check_msg(1, 8'h02, 8'h05, 8'h01, 8'h00, 32'd12, 32'd22, 32'd32);
        end

        // ---- T06: reserved flags bit set, dropped ----
        got_cnt = 0; err_type_pulses = 0; err_flags_pulses = 0;
        send_msg(8'h01, 8'h06, 8'h00, 8'h00, 32'd40, 32'd50, 32'd60);        // good (before)
        send_msg(8'h01, 8'h06, 8'h00, 8'b0000_0100, 32'd41, 32'd51, 32'd61); // bit2 reserved -- dropped
        send_msg(8'h01, 8'h06, 8'h01, 8'h00, 32'd42, 32'd52, 32'd62);        // good (after)
        @(posedge clk); #1;

        if (got_cnt !== 2) begin
            $display("FAIL: T06 (bad flags) got_cnt=%0d, expected 2", got_cnt);
            fail = 1'b1;
        end
        if (err_flags_pulses !== 1) begin
            $display("FAIL: T06 (bad flags) err_flags pulsed %0d times, expected 1", err_flags_pulses);
            fail = 1'b1;
        end
        if (err_type_pulses !== 0) begin
            $display("FAIL: T06 (bad flags) err_msg_type pulsed %0d times, expected 0", err_type_pulses);
            fail = 1'b1;
        end
        if (got_cnt >= 2) begin
            check_msg(0, 8'h01, 8'h06, 8'h00, 8'h00, 32'd40, 32'd50, 32'd60);
            check_msg(1, 8'h01, 8'h06, 8'h01, 8'h00, 32'd42, 32'd52, 32'd62);
        end

        // ---- T06 priority: bad type AND bad flags -> err_msg_type only ----
        got_cnt = 0; err_type_pulses = 0; err_flags_pulses = 0;
        send_msg(8'h01, 8'h07, 8'h00, 8'h00, 32'd70, 32'd80, 32'd90);        // good (before)
        send_msg(8'h07, 8'h07, 8'h00, 8'b0000_0100, 32'd71, 32'd81, 32'd91); // bad type + reserved flag
        send_msg(8'h03, 8'h07, 8'h00, 8'h00, 32'd72, 32'd82, 32'd92);        // good (after)
        @(posedge clk); #1;

        if (got_cnt !== 2) begin
            $display("FAIL: T06 (both bad) got_cnt=%0d, expected 2", got_cnt);
            fail = 1'b1;
        end
        if (err_type_pulses !== 1) begin
            $display("FAIL: T06 (both bad) err_msg_type pulsed %0d times, expected 1", err_type_pulses);
            fail = 1'b1;
        end
        if (err_flags_pulses !== 0) begin
            $display("FAIL: T06 (both bad) err_flags pulsed %0d times, expected 0 (type checked first, FR-8 before FR-9)",
                     err_flags_pulses);
            fail = 1'b1;
        end
        if (got_cnt >= 2) begin
            check_msg(0, 8'h01, 8'h07, 8'h00, 8'h00, 32'd70, 32'd80, 32'd90);
            check_msg(1, 8'h03, 8'h07, 8'h00, 8'h00, 32'd72, 32'd82, 32'd92);
        end

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
