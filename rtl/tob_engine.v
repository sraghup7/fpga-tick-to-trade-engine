`timescale 1ns / 1ps

// rtl/tob_engine.v
//
// Top-of-book state block (master spec S3.1 [G], FR-13..19). Holds the
// current best bid/ask price+quantity for each of the 4 watched-symbol
// slots and applies incoming QUOTE/CLEAR/TRADE/HEARTBEAT messages to that
// state. slot i occupies bits [i*32 +: 32] of each 32-bit-wide flattened
// bus (bit i of the 1-bit buses) -- the Verilog-2001 idiom for a runtime-
// indexed, fixed-shape table, consumed by feature_extractor.v
// (docs/contracts/feature_extractor.md).
//
// This module is where symbol_filter.v's and seq_monitor.v's verdicts get
// combined (docs/contracts/symbol_filter.md S1, seq_monitor.md S1): those
// two are parallel siblings off md_parser.v, and a message is applied iff
//
//     msg_applied = filt_valid AND NOT err_seq_dup
//
// i.e. it is on a watched symbol AND not a duplicate/reorder (FR-11: drop,
// no book modification). Deliberately NOT part of the gate: seq_monitor's
// sticky seq_gap. FR-10 says a gap sets a sticky flag and increments a
// counter but does NOT block the book update -- book state keeps updating
// through a gap; the sticky bit only matters later to risk_engine.v's gate
// 0x06 (S7). Gating msg_applied on seq_gap would be a real behavioral bug.
// The gate applies uniformly to all four msg_type values -- a duplicate or
// unwatched TRADE/HEARTBEAT must not increment cnt_trades/cnt_heartbeats
// either, matching sim/golden_model.py's process_message, whose `if is_dup:
// return` sits before the msg_type dispatch.
//
// Per-message semantics (matching sim/golden_model.py's MSG_* branches
// exactly, and D14's fix to FR-15):
//   QUOTE (0x01): the addressed side is bid iff msg_side==0, else ask (any
//     nonzero value selects ask -- no validation, docs/contracts/md_parser.md).
//     qty and valid are written unconditionally (valid = qty != 0); PRICE is
//     written only when qty != 0 -- a qty=0 quote clears the side's validity
//     WITHOUT altering the stored price (FR-15, D14: the regression in
//     sim/test_golden_model_handcase.py messages 24-25). Other side untouched.
//   CLEAR (0x03): both valid bits -> 0. Prices/quantities left unchanged
//     (FR-16; golden model only touches the two valid bits).
//   TRADE (0x02) / HEARTBEAT (0xFF): no book field changes at all (FR-19).
//
// crossed[i] is combinational, continuously: bid_valid & ask_valid &
// (bid_price >= ask_price) (FR-17). cnt_crossed_pulse is re-evaluated on
// EVERY applied message -- including TRADE/HEARTBEAT, which change nothing
// -- against the slot's crossed state AFTER this cycle's update, exactly
// like golden_model's unconditional `if book.crossed: cnt_crossed++` after
// the msg_type dispatch. The post-update state is computed combinationally
// (nb_* below) so the pulse is valid on the message's own cycle; that same
// nb_* feeds the sequential latch, giving one source of truth for the
// update rule.
//
// clk/rst_n are truly used here (book state is registered). On reset all
// state clears, so every slot reads invalid with no stale value (FR-18).
//
// Verilog-2001 only.

module tob_engine #(
    parameter integer NUM_SYMBOLS = 4   // matches symbol_filter.v's 4 slots
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from md_parser.v -- meaningful only when msg_applied (derived below)
    // is high for this cycle
    input  wire [7:0]  msg_type,
    input  wire [7:0]  msg_side,
    input  wire [31:0] msg_price,
    input  wire [31:0] msg_quantity,

    // from symbol_filter.v
    input  wire        filt_valid,
    input  wire [1:0]  filt_slot,

    // from seq_monitor.v
    input  wire        err_seq_dup,

    // status: msg_applied = filt_valid & !err_seq_dup, pulses for every
    // message type once it clears the FR-11 dup gate. Exposed directly
    // because feature_extractor.v needs it for TRADE/HEARTBEAT triggers.
    output wire        msg_applied,
    output wire [1:0]  applied_slot,   // valid when msg_applied=1

    // book_upd_valid = msg_applied & (QUOTE | CLEAR): the "book was
    // modified" pulse feature_extractor.v's FR-20 trigger needs.
    output wire        book_upd_valid,

    // status pulses for a later CSR/counters block (S10) -- raw,
    // un-accumulated, same pattern as every other module's err_*/cnt_*
    // outputs in this repo
    output wire        cnt_book_clear_pulse,   // msg_applied & CLEAR
    output wire        cnt_trades_pulse,       // msg_applied & TRADE
    output wire        cnt_heartbeats_pulse,   // msg_applied & HEARTBEAT
    output wire        cnt_crossed_pulse,      // msg_applied & crossed[applied_slot]
                                                // (post-update), re-evaluated on
                                                // EVERY applied message (S2.4)

    // per-slot committed book state (flattened buses, slot i at
    // [i*32 +: 32] / bit i)
    output wire [NUM_SYMBOLS*32-1:0] bid_price,
    output wire [NUM_SYMBOLS*32-1:0] bid_qty,
    output wire [NUM_SYMBOLS-1:0]    bid_valid,
    output wire [NUM_SYMBOLS*32-1:0] ask_price,
    output wire [NUM_SYMBOLS*32-1:0] ask_qty,
    output wire [NUM_SYMBOLS-1:0]    ask_valid,
    output wire [NUM_SYMBOLS-1:0]    crossed,

    // post-update ("next") state of the APPLIED slot -- combinational,
    // valid on the message's own cycle whenever msg_applied is high, i.e.
    // the state the committed buses will read on the NEXT cycle (D23:
    // consumers gated on book_upd_valid must read these, NOT the registered
    // buses below, which only reflect the book as it stood before the
    // triggering message's own effect). For TRADE/HEARTBEAT, where nothing
    // changes, these equal the current committed state by construction; a
    // consumer should gate on book_upd_valid (or msg_applied) before reading
    // them, exactly as it already gates on the committed buses.
    output wire [31:0] next_bid_price,
    output wire [31:0] next_bid_qty,
    output wire         next_bid_valid,
    output wire [31:0] next_ask_price,
    output wire [31:0] next_ask_qty,
    output wire         next_ask_valid,
    output wire         next_crossed
);

    localparam [7:0] MSG_QUOTE     = 8'h01;
    localparam [7:0] MSG_TRADE     = 8'h02;
    localparam [7:0] MSG_CLEAR     = 8'h03;
    localparam [7:0] MSG_HEARTBEAT = 8'hFF;

    reg [NUM_SYMBOLS*32-1:0] bid_price_r, bid_qty_r;
    reg [NUM_SYMBOLS-1:0]    bid_valid_r;
    reg [NUM_SYMBOLS*32-1:0] ask_price_r, ask_qty_r;
    reg [NUM_SYMBOLS-1:0]    ask_valid_r;

    assign bid_price  = bid_price_r;
    assign bid_qty    = bid_qty_r;
    assign bid_valid  = bid_valid_r;
    assign ask_price  = ask_price_r;
    assign ask_qty    = ask_qty_r;
    assign ask_valid  = ask_valid_r;

    // FR-11 gate; applied_slot is filt_slot (meaningful only when applied).
    assign msg_applied = filt_valid & ~err_seq_dup;
    assign applied_slot = filt_slot;

    // Book-modifying types narrow msg_applied into book_upd_valid, and the
    // per-type counters (all gated on msg_applied identically, per S1).
    wire is_quote = (msg_type == MSG_QUOTE);
    wire is_clear = (msg_type == MSG_CLEAR);
    assign book_upd_valid        = msg_applied & (is_quote | is_clear);
    assign cnt_book_clear_pulse  = msg_applied & is_clear;
    assign cnt_trades_pulse      = msg_applied & (msg_type == MSG_TRADE);
    assign cnt_heartbeats_pulse  = msg_applied & (msg_type == MSG_HEARTBEAT);

    // FR-17: crossed[i] continuous, strictly combinational off state.
    genvar g;
    generate
        for (g = 0; g < NUM_SYMBOLS; g = g + 1) begin : crossed_gen
            assign crossed[g] = bid_valid_r[g] & ask_valid_r[g] &
                                (bid_price_r[g*32 +: 32] >= ask_price_r[g*32 +: 32]);
        end
    endgenerate

    // ---- post-update ("next") state of the APPLIED slot, combinational.
    //      nb_* is what this message leaves the slot at; it both feeds the
    //      sequential latch below and the crossed re-check, so the update
    //      rule has exactly one source of truth. When msg_applied is low the
    //      nb_* values mirror current state and nothing latches. ----
    wire [31:0] s_bp = bid_price_r[applied_slot*32 +: 32];
    wire [31:0] s_bq = bid_qty_r  [applied_slot*32 +: 32];
    wire        s_bv = bid_valid_r[applied_slot];
    wire [31:0] s_ap = ask_price_r[applied_slot*32 +: 32];
    wire [31:0] s_aq = ask_qty_r  [applied_slot*32 +: 32];
    wire        s_av = ask_valid_r[applied_slot];

    wire quote_bid = msg_applied & is_quote & (msg_side == 8'h00);
    wire quote_ask = msg_applied & is_quote & (msg_side != 8'h00);
    wire qty_nz    = (msg_quantity != 32'd0);

    // bid side next state (QUOTE-bid updates it, CLEAR clears its validity,
    // anything else leaves it untouched)
    wire [31:0] nb_bp = (quote_bid & qty_nz) ? msg_price : s_bp;
    wire [31:0] nb_bq = quote_bid            ? msg_quantity : s_bq;
    wire        nb_bv = quote_bid            ? qty_nz      :
                        is_clear             ? 1'b0        : s_bv;

    // ask side next state (symmetric)
    wire [31:0] nb_ap = (quote_ask & qty_nz) ? msg_price : s_ap;
    wire [31:0] nb_aq = quote_ask            ? msg_quantity : s_aq;
    wire        nb_av = quote_ask            ? qty_nz      :
                        is_clear             ? 1'b0        : s_av;

    // S2.4: crossed AFTER this message's update for the applied slot --
    // TRADE/HEARTBEAT leave nb_* == s_*, so an already-crossed slot keeps
    // re-firing cnt_crossed_pulse on every applied message for it; a CLEAR
    // or qty=0 side forces it to 0. Combinational, valid on the message's
    // own cycle, race-free (equals the post-update state on both sides of
    // the clock edge).
    wire addr_crossed_next = nb_bv & nb_av & (nb_bp >= nb_ap);
    assign cnt_crossed_pulse = msg_applied & addr_crossed_next;

    // D23: expose the applied slot's post-update state to cycle-gated
    // consumers (signal_engine.v) -- plain assigns of the wires already
    // computed above, zero new logic.
    assign next_bid_price = nb_bp;
    assign next_bid_qty   = nb_bq;
    assign next_bid_valid = nb_bv;
    assign next_ask_price = nb_ap;
    assign next_ask_qty   = nb_aq;
    assign next_ask_valid = nb_av;
    assign next_crossed   = addr_crossed_next;

    // ---- committed state latch ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bid_price_r  <= {NUM_SYMBOLS*32{1'b0}};
            bid_qty_r    <= {NUM_SYMBOLS*32{1'b0}};
            bid_valid_r  <= {NUM_SYMBOLS{1'b0}};
            ask_price_r  <= {NUM_SYMBOLS*32{1'b0}};
            ask_qty_r    <= {NUM_SYMBOLS*32{1'b0}};
            ask_valid_r  <= {NUM_SYMBOLS{1'b0}};
        end else if (msg_applied) begin
            bid_price_r[applied_slot*32 +: 32] <= nb_bp;
            bid_qty_r  [applied_slot*32 +: 32] <= nb_bq;
            bid_valid_r[applied_slot]           <= nb_bv;
            ask_price_r[applied_slot*32 +: 32] <= nb_ap;
            ask_qty_r  [applied_slot*32 +: 32] <= nb_aq;
            ask_valid_r[applied_slot]           <= nb_av;
        end
        // msg_applied low: no slot changes (registers hold)
    end

endmodule
