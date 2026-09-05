`timescale 1ns / 1ps

// rtl/symbol_filter.v
//
// 4-entry symbol watch (master spec S3.1 [E], FR-7). Watches up to four
// configured symbol_id slots (SYMBOL_0..3 @ CSR 0x08-0x14, SYMBOL_EN @
// 0x18 -- four scalar cfg_symbol_* ports named after that register map,
// standing in for csr_block.v, which does not exist yet; the register map
// hard-codes exactly 4 slots, so there is deliberately no NUM_SYMBOLS
// parameter) and tells tob_engine.v which slot, if any, a decoded message
// belongs to.
//
// Wiring note (docs/design_decisions.md D12's sibling, docs/contracts/
// symbol_filter.md S1): the master spec S3.1 block diagram draws
// `md_parser -> symbol_filter -> seq_monitor -> tob_engine` as a straight
// chain, but that reading is wrong -- seq_monitor.v's per-feed sequence
// tracking (FR-10) must see EVERY message md_parser.v completes, including
// unwatched symbols, or an unwatched message silently eats a seq_num slot
// and the next watched message looks gapped. So symbol_filter.v and
// seq_monitor.v are parallel siblings wired directly off md_parser.v, and
// tob_engine.v combines their verdicts. This module has no seq_monitor
// port on purpose.
//
// md_parser.v has already validated msg_type/flags (FR-8/FR-9) before this
// module sees anything: msg_valid only pulses for a type-and-flags-clean
// message (docs/contracts/md_parser.md). There is no err_* handling here.
//
// The match decision is a pure function of msg_symbol_id and the cfg_*
// registers, all stable the cycle msg_valid pulses -- so the whole gate is
// combinational (zero added latency, no FSM, no registers), the same
// decision as frame_classifier.v's accept/reject gate
// (rtl/frame_classifier.v, FR-4/FR-5 precedent). clk/rst_n are declared to
// match every other module's port style but carry no state to reset here.
// filt_slot is a lowest-index priority encoder over the four slot matches;
// two enabled slots holding the same symbol_id is a misconfiguration this
// module does not need to detect, and lowest-index-wins is simply what the
// priority encoder naturally produces.
//
// Verilog-2001 only.

module symbol_filter (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from md_parser.v -- only messages it already validated matter here
    input  wire        msg_valid,
    input  wire [7:0]  msg_symbol_id,

    // config (S9 CSR map: SYMBOL_0..3 @ 0x08-0x14, SYMBOL_EN @ 0x18)
    input  wire [7:0]  cfg_symbol_0,
    input  wire [7:0]  cfg_symbol_1,
    input  wire [7:0]  cfg_symbol_2,
    input  wire [7:0]  cfg_symbol_3,
    input  wire [3:0]  cfg_symbol_en,   // bit i enables slot i

    // to tob_engine.v (and anything else that needs "which of the 4
    // watched-symbol slots did this message match")
    output wire        filt_valid,   // msg_valid AND matched an enabled slot
    output wire [1:0]  filt_slot,    // matched slot index 0-3; meaningful
                                      // only when filt_valid=1

    // status: one-cycle pulse per message on an unwatched symbol (FR-7,
    // counted as cnt_msgs_filtered by a later counters block -- this
    // module only emits the raw pulse)
    output wire        filt_dropped
);

    // FR-7 per-slot match: the slot's enable bit AND its configured symbol
    // equal the incoming message's symbol. Comparison is byte-wide; the
    // enable bit is what keeps an enabled-but-equal config from matching.
    wire [3:0] slot_match =
        { (cfg_symbol_en[3] & (cfg_symbol_3 == msg_symbol_id)),
          (cfg_symbol_en[2] & (cfg_symbol_2 == msg_symbol_id)),
          (cfg_symbol_en[1] & (cfg_symbol_1 == msg_symbol_id)),
          (cfg_symbol_en[0] & (cfg_symbol_0 == msg_symbol_id)) };

    wire matched = |slot_match;

    // Everything gated on msg_valid: when it is low the outputs are 0 no
    // matter what msg_symbol_id holds (md_parser's register keeps the last
    // decoded symbol, valid or not).
    assign filt_valid   = msg_valid & matched;
    assign filt_dropped = msg_valid & ~matched;

    // Lowest-numbered matching slot. Full if-else chain (no latch); the
    // final else is reachable only when nothing matched, in which case
    // filt_valid=0 makes filt_slot a don't-care anyway.
    assign filt_slot = slot_match[0] ? 2'd0 :
                       slot_match[1] ? 2'd1 :
                       slot_match[2] ? 2'd2 :
                       2'd3;

endmodule
