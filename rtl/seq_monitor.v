`timescale 1ns / 1ps

// rtl/seq_monitor.v
//
// Feed-level sequence gap/duplicate detector (master spec S3.1 [F],
// FR-10/FR-11/FR-12). Tracks one 32-bit expected_seq per feed and reports,
// per completed message, whether the feed's sequence is intact: a jump
// forward is a gap (lost messages), a repeat or backward jump is a
// duplicate/reorder (FR-11: drop, no book modification).
//
// Architecture note (docs/design_decisions.md D12's sibling,
// docs/contracts/seq_monitor.md S1): FR-10 is a "per feed" property -- this
// module must see EVERY message md_parser.v completes, including messages on
// symbols nobody watches and messages md_parser itself dropped for a bad
// msg_type or reserved flags bit. The master spec S3.1 block diagram draws
// `md_parser -> symbol_filter -> seq_monitor -> tob_engine` as a straight
// chain, but that reading is wrong: a type-invalid (or unwatched) message
// still arrived on the wire and still consumed a seq_num slot, so it must
// advance expected_seq -- otherwise the next legitimate message looks like
// it arrived after a phantom gap. symbol_filter.v is therefore this
// module's parallel sibling (both wired straight off md_parser.v), not its
// input, and tob_engine.v combines their verdicts. There is no symbol port
// here on purpose.
//
// md_parser.v's field registers (msg_seq_num and msg_flags included) are
// latched unconditionally on every completed message, valid or not, and its
// three status pulses -- msg_valid / err_msg_type / err_flags -- are one-hot
// over "a message just completed". So "a message completed this cycle"
// (msg_complete below) is the OR of all three, and this module never
// registers an opinion about msg_type/flags validity itself.
//
// State (all reset to 0 on rst_n): expected_seq (next seq_num expected),
// seen_first (a prior message has been seen since reset -- the first message
// establishes the baseline and can never be a gap/dup), and seq_gap_r (the
// sticky FR-10/FR-12 level). Verdicts for the current message are
// combinational off the pre-edge state; state registers update on the
// msg_complete cycle's clock edge. seq_gap_amount is combinational (0 when
// no gap) so the later CSR/counters block can add msg_seq_num - expected_seq
// on the same cycle seq_gap_pulse fires -- a gap counter accumulates the
// magnitude, it does not just increment by 1.
//
// Clears for the sticky bit: a message with flags.snapshot=1 clears it
// unconditionally (FR-12) -- even if that message is itself a duplicate or a
// fresh gap (the contract reads "regardless of whether this particular
// message was itself a gap, a duplicate, or a clean exact match"); the
// explicit cfg_seq_gap_clear (S9 CTRL.bit3) clears it the same way. When a
// fresh gap is detected on the same cycle as either clear, the clear wins.
//
// seq_num wraparound is not modeled (neither sim/golden_model.py nor this
// project handles it) -- comparisons are plain unsigned 32-bit.
//
// Verilog-2001 only.

module seq_monitor (
    input  wire         clk,
    input  wire         rst_n,   // active-low, async-assert/sync-deassert

    // from md_parser.v -- ALL three, see above: exactly one pulses per
    // completed message, and this module reacts to any of the three
    input  wire         msg_valid,
    input  wire         err_msg_type,
    input  wire         err_flags,
    input  wire [31:0]  msg_seq_num,
    input  wire [7:0]   msg_flags,    // only bit 1 (FLAG_SNAPSHOT) is read

    // config: explicit seq-gap clear (S9 CTRL.bit3). Direct port, standing
    // in for csr_block.v, which does not exist yet (same pattern as
    // symbol_filter.v's cfg_symbol_* ports) -- one-cycle pulse clears the
    // sticky seq_gap output below on the next clock edge.
    input  wire         cfg_seq_gap_clear,

    // status: one-cycle pulse, coincides with the message-complete cycle
    // that turned out to be a duplicate/reorder (FR-11). tob_engine.v
    // treats this pulse directly as "do not apply this message to book
    // state" -- no separate "is_dup" signal, this pulse IS that signal.
    output wire         err_seq_dup,

    // FR-10: the gap amount for THIS message (0 if no gap), and a pulse
    // marking that a gap was detected this cycle. The counter that
    // accumulates this into cnt_seq_gap lives in a later CSR/counters
    // block and must add seq_gap_amount, not just increment by 1.
    output wire [31:0]  seq_gap_amount,
    output wire         seq_gap_pulse,

    // FR-10/FR-12: sticky status bit (level, not pulse) -- set on any
    // detected gap, cleared only by a flags.snapshot=1 message or
    // cfg_seq_gap_clear.
    output wire         seq_gap
);

    reg [31:0] expected_seq;
    reg        seen_first;
    reg        seq_gap_r;

    // "A message just completed" -- md_parser's three pulses are one-hot
    // over completed messages, and the field registers are valid this cycle
    // for whichever one fired (docs/contracts/md_parser.md S2.6).
    wire msg_complete = msg_valid | err_msg_type | err_flags;

    // Current-message verdicts, combinational off pre-edge state. Both are
    // suppressed for the very first message ever (no expectation to compare
    // against yet) -- the msg_seq_num value is meaningless as a delta there.
    wire cmp_lt = msg_complete &  seen_first & (msg_seq_num <  expected_seq);
    wire cmp_gt = msg_complete &  seen_first & (msg_seq_num >  expected_seq);

    assign err_seq_dup    = cmp_lt;
    assign seq_gap_pulse  = cmp_gt;
    assign seq_gap_amount = cmp_gt ? (msg_seq_num - expected_seq) : 32'd0;
    assign seq_gap        = seq_gap_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            expected_seq <= 32'd0;
            seen_first   <= 1'b0;
            seq_gap_r    <= 1'b0;
        end else begin
            if (msg_complete) begin
                if (!seen_first) begin
                    // Baseline: the first message can't be a gap or a dup,
                    // whatever its seq_num. Next expected is right after it.
                    seen_first   <= 1'b1;
                    expected_seq <= msg_seq_num + 32'd1;
                end else if (msg_seq_num >= expected_seq) begin
                    // Exact match advances one; a gap also advances PAST the
                    // just-arrived message (the skipped messages are gone,
                    // the next expected is the one right after this one).
                    expected_seq <= msg_seq_num + 32'd1;
                end
                // msg_seq_num < expected_seq: duplicate/reorder, no advance.
            end

            // FR-12 sticky bit. Clears win over a same-cycle fresh gap: the
            // snapshot rule is unconditional ("regardless of whether this
            // message was itself a gap..."), and the CSR-clear-vs-traffic
            // combination is not expected in operation, so either outcome
            // is fine there -- deterministic clear-first is what falls out.
            if (cfg_seq_gap_clear) begin
                seq_gap_r <= 1'b0;
            end else if (msg_complete && msg_flags[1]) begin
                seq_gap_r <= 1'b0;
            end else if (cmp_gt) begin
                seq_gap_r <= 1'b1;
            end
            // otherwise hold
        end
    end

endmodule
