`timescale 1ns / 1ps

// rtl/md_parser.v
//
// Byte-serial market-data parser (master spec S4.3, FR-4/FR-8/FR-9).
// Reassembles every 16 bytes of the stream frame_classifier.v forwards
// into one structured message, big-endian per S4.3's field layout
// (byte 0 = msg_type, bytes 4-7 = price MSB-first, ..., bytes 12-15 =
// seq_num), and pulses msg_valid the cycle after the 16th byte has
// actually been latched (docs/contracts/md_parser.md §2.6 -- the field
// registers need one clock edge to capture byte 15 before anything can
// read them, so the pulse is never same-cycle with the last byte).
//
// frame_classifier.v only ever forwards whole multiples of 16 bytes
// (rtl/frame_classifier.v, FR-5) -- so this module needs no frame-boundary
// awareness of its own. A free-running mod-16 byte counter over cycles
// where in_valid is high is always message-aligned as long as that
// contract holds. Deliberately no resync/marker-search logic here: the
// upstream length check already rules misalignment out, and byte_cnt just
// wraps at 15 regardless of what the message turns out to be, so dropping
// a message (bad type/flags) never costs alignment -- the next message's
// byte 0 still lands on byte_cnt == 0.
//
// FR-8/FR-9: a message with an undefined msg_type or a reserved flags bit
// set (bits 7:2, FLAG_RESERVED_MASK) is dropped -- no msg_valid pulse --
// and flagged via err_msg_type/err_flags instead. Checked in the same
// order as sim/golden_model.py's process_message (msg_type before flags;
// golden_model.py returns at the type check, so a message that is bad in
// both ways fires err_msg_type only, never err_flags) for bit-exact
// parity with the reference model, not just bit-exact final results.
//
// Verilog-2001 only.

module md_parser (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from frame_classifier.v
    input  wire [7:0]  in_data,
    input  wire        in_valid,

    // one decoded message per msg_valid pulse (S4.3 field layout)
    output wire        msg_valid,
    output reg  [7:0]  msg_type,
    output reg  [7:0]  msg_symbol_id,
    output reg  [7:0]  msg_side,
    output reg  [7:0]  msg_flags,
    output reg  [31:0] msg_price,
    output reg  [31:0] msg_quantity,
    output reg  [31:0] msg_seq_num,

    // status (FR-8/FR-9) -- one-cycle pulse, coincides with a dropped message
    output wire        err_msg_type,
    output wire        err_flags
);

    localparam [7:0] MSG_QUOTE     = 8'h01;
    localparam [7:0] MSG_TRADE     = 8'h02;
    localparam [7:0] MSG_CLEAR     = 8'h03;
    localparam [7:0] MSG_HEARTBEAT = 8'hFF;
    localparam [7:0] FLAG_RESERVED_MASK = 8'hFC;   // bits 7:2 must be 0 (FR-9)

    reg [3:0] byte_cnt;     // position within the current message, 0..15
    reg       complete_d;   // one-cycle pulse, the cycle after byte 15 lands

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt      <= 4'd0;
            complete_d    <= 1'b0;
            msg_type      <= 8'd0;
            msg_symbol_id <= 8'd0;
            msg_side      <= 8'd0;
            msg_flags     <= 8'd0;
            msg_price     <= 32'd0;
            msg_quantity  <= 32'd0;
            msg_seq_num   <= 32'd0;
        end else begin
            complete_d <= 1'b0;
            if (in_valid) begin
                case (byte_cnt)
                    4'd0:  msg_type            <= in_data;
                    4'd1:  msg_symbol_id       <= in_data;
                    4'd2:  msg_side            <= in_data;
                    4'd3:  msg_flags           <= in_data;
                    4'd4:  msg_price[31:24]    <= in_data;
                    4'd5:  msg_price[23:16]    <= in_data;
                    4'd6:  msg_price[15:8]     <= in_data;
                    4'd7:  msg_price[7:0]      <= in_data;
                    4'd8:  msg_quantity[31:24] <= in_data;
                    4'd9:  msg_quantity[23:16] <= in_data;
                    4'd10: msg_quantity[15:8]  <= in_data;
                    4'd11: msg_quantity[7:0]   <= in_data;
                    4'd12: msg_seq_num[31:24]  <= in_data;
                    4'd13: msg_seq_num[23:16]  <= in_data;
                    4'd14: msg_seq_num[15:8]   <= in_data;
                    4'd15: msg_seq_num[7:0]    <= in_data;
                endcase

                if (byte_cnt == 4'd15) begin
                    byte_cnt   <= 4'd0;
                    complete_d <= 1'b1;
                end else begin
                    byte_cnt <= byte_cnt + 1'b1;
                end
            end
        end
    end

    wire type_ok  = (msg_type == MSG_QUOTE)     ||
                    (msg_type == MSG_TRADE)     ||
                    (msg_type == MSG_CLEAR)     ||
                    (msg_type == MSG_HEARTBEAT);
    wire flags_ok = (msg_flags & FLAG_RESERVED_MASK) == 8'd0;

    // FR-8 checked before FR-9 (golden_model.py order): a message that is
    // invalid in both ways reports err_msg_type and never reaches the
    // flags check, so err_flags is gated on type_ok too.
    assign err_msg_type = complete_d & ~type_ok;
    assign err_flags    = complete_d & type_ok & ~flags_ok;
    assign msg_valid    = complete_d & type_ok & flags_ok;

endmodule
