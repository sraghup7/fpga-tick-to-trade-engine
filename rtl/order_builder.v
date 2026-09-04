`timescale 1ns / 1ps

// rtl/order_builder.v
//
// Egress order encoder + 2-deep TX queue (master spec S3.1 [J], S4.5,
// FR-49..52; contract docs/contracts/order_builder.md). Takes risk_engine.v's
// accept/reject decision, encodes it into the 16-byte order-record wire
// format, and drives it through eth_mac_if.v's fixed TX interface
// (tx_payload/tx_start/tx_busy, rtl/eth_mac_if.v S1.3) -- queueing up to two
// records while the MAC drains a previous frame, matching sim/golden_model.py's
// two-deep TX-slot invariant.
//
// The gap this module exists to close (contract S1.2): no upstream module
// carries a triggering message's seq_num or raw symbol_id past md_parser.v.
//   * symbol_id is recovered from order_slot via the same cfg_symbol_0..3
//     registers symbol_filter.v reads -- a combinational config lookup
//     (S2.3), no pipelining.
//   * trigger_seq rides an UNCONDITIONAL two-stage shift register off
//     msg_seq_num (S2.2). msg_seq_num is a held register between updates,
//     and the total registered latency from md_parser's msg_valid to the
//     matching order_valid/reject_reason is exactly two cycles
//     (signal_engine + risk_engine register once each; everything between is
//     combinational), so after two cycles seq_d1 holds exactly the seq of the
//     message now producing the decision -- alignment automatic by
//     construction. A second stage of the same shape (ingress_d1) captures
//     cur_cycle at the message's arrival for latency_cyc.
//
// Queueing (S2.4): a record is never transmitted the instant a decision
// fires -- eth_mac_if may still be draining a previous frame. Two explicit
// 144-bit record registers (q0 oldest / q1 newest, fixed spec depth, not a
// parameter) hold pending records; a decision that finds both occupied is
// dropped with a one-cycle cnt_order_overflow_pulse. Overflow is judged
// against the occupancy AFTER any same-cycle pop, and push/pop combine into
// one coherent next-state expression per register (risk_engine.v S2.3
// discipline) so a pop that frees a slot lets a simultaneous push use it.
//
// tx_start is a one-shot pulse, never double-issued per record (S2.5): the
// pop term is gated on ~tx_start in addition to ~tx_busy because
// eth_mac_if's tx_busy lags tx_start by one cycle (its FSM samples tx_start
// on a clock edge and only then leaves TX_IDLE). Without the ~tx_start term
// a naive "pop while !tx_busy" would fire again on the exact cycle the
// previous pulse is still high.
//
// latency_cyc is computed at POP time -- cur_cycle minus the record's stored
// ingress_cycle, low 16 bits -- never frozen at push time (S2.3), so a
// record that waited in the queue behind a transmission reports its real
// tick-to-egress wait. Wire encoding per S4.5 / sim/golden_model.py's
// OrderRecord.encode() (>BBBBIIHH); tx_payload's byte-0-in-MSBs convention
// means a plain concatenation of full-width fields is already big-endian.
//
// Verilog-2001 only.

module order_builder (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from md_parser.v -- source for the trigger_seq/ingress pipelines.
    // msg_seq_num is a stable, held register between updates, so the shift
    // stages below run unconditionally (no msg_valid gating needed).
    input  wire [31:0] msg_seq_num,

    // from risk_engine.v -- one decision per evaluated intent
    input  wire        order_valid,
    input  wire [1:0]  order_slot,
    input  wire [7:0]  order_side,
    input  wire [31:0] order_price,
    input  wire [31:0] order_qty,
    input  wire [7:0]  reject_reason,  // nonzero iff order_valid=0 & a gate fired

    // free-running cycle counter -- the SAME one risk_engine.v takes, for
    // latency_cyc (S2.3)
    input  wire [31:0] cur_cycle,

    // config: slot -> symbol_id lookup (S9 SYMBOL_0..3), the same four
    // registers symbol_filter.v reads
    input  wire [7:0]  cfg_symbol_0,
    input  wire [7:0]  cfg_symbol_1,
    input  wire [7:0]  cfg_symbol_2,
    input  wire [7:0]  cfg_symbol_3,

    // config: FR-44/D7 -- 0x11 reject frames are opt-in, off by default
    input  wire        cfg_reject_report,

    // to eth_mac_if.v (S1.3, fixed interface)
    output reg  [127:0] tx_payload,  // byte 0 in [127:120] ... byte 15 in [7:0]
    output reg           tx_start,   // one-shot pulse; ignored while tx_busy
    input  wire           tx_busy,

    // status: one-cycle pulse per record dropped because both queue slots
    // were already occupied (S2.4)
    output wire         cnt_order_overflow_pulse
);

    // ---- S2.2: unconditional two-stage seq / ingress pipelines ----
    // seq_d1 and ingress_d1 lag msg_seq_num/cur_cycle by exactly the two
    // registered cycles between md_parser's msg_valid and the matching
    // order_valid/reject_reason, so on any decision cycle they hold the
    // triggering message's low seq and arrival cycle.
    reg [15:0] seq_d0, seq_d1;
    reg [31:0] ingress_d0, ingress_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq_d0     <= 16'd0;
            seq_d1     <= 16'd0;
            ingress_d0 <= 32'd0;
            ingress_d1 <= 32'd0;
        end else begin
            seq_d0     <= msg_seq_num[15:0];
            seq_d1     <= seq_d0;
            ingress_d0 <= cur_cycle;
            ingress_d1 <= ingress_d0;
        end
    end

    // ---- S2.3: combinational slot -> symbol_id config lookup ----
    wire [7:0] sym_id_c =
        (order_slot == 2'd0) ? cfg_symbol_0 :
        (order_slot == 2'd1) ? cfg_symbol_1 :
        (order_slot == 2'd2) ? cfg_symbol_2 : cfg_symbol_3;

    // ---- S2.4: push decision ----
    // order_valid and a nonzero reject_reason are mutually exclusive the same
    // cycle (risk_engine's accepted_c construction guarantees this), so the
    // msg-type selection is unambiguous.
    wire want_push   = order_valid |
                       (cfg_reject_report & (reject_reason != 8'd0));
    wire [7:0] push_msg_type = order_valid ? 8'h10 : 8'h11;  // NEW : REJECT

    // ---- 2-deep record queue (fixed spec depth, S2.4) ----
    // {msg_type, symbol_id, side, reject_reason, price, qty, trigger_seq,
    //  ingress_cycle} = 8+8+8+8+32+32+16+32 = 144 bits. q0 is always the
    // OLDEST (next to transmit); q1 the newer one.
    reg [143:0] q0, q1;
    reg [1:0]   q_count;    // 0, 1, or 2 occupied

    // ---- S2.5: pop, and S2.4: overflow vs. occupancy AFTER a same-cycle pop
    // The ~tx_start term is not optional: eth_mac_if's tx_busy lags tx_start
    // by one cycle (S1.3), so during the cycle tx_start is high tx_busy still
    // reads 0. Gating on ~tx_start as well closes the double-issue a naive
    // "pop while !tx_busy" would create on that exact cycle.
    wire pop_this_cycle = (q_count != 2'd0) & ~tx_busy & ~tx_start;
    wire [1:0] count_after_pop = q_count - (pop_this_cycle ? 2'd1 : 2'd0);
    wire overflow = want_push & (count_after_pop >= 2'd2);
    assign cnt_order_overflow_pulse = overflow;
    wire push_ok = want_push & ~overflow;

    // New record assembled from this cycle's decision plus the aligned
    // pipelines. Same field order as the stored 144-bit layout.
    wire [143:0] new_rec =
        { push_msg_type, sym_id_c,  order_side, reject_reason,
          order_price,   order_qty, seq_d1,     ingress_d1 };

    // Single next-state expression per register -- never two separate NBA
    // writes to the same reg (risk_engine.v S2.3 discipline). A same-cycle
    // pop + push combine into one coherent update:
    //   * pop vacates q0; q1 (if q_count was 2) shifts down into q0;
    //   * the pushed record fills the freed slot -- q1 when a shift
    //     happened, otherwise q0 (empty, or freed-by-pop single record).
    wire [143:0] q0_next =
        pop_this_cycle
            ? ((q_count == 2'd2) ? q1
                                 : (push_ok ? new_rec : 144'd0))
            : (push_ok & (q_count == 2'd0) ? new_rec : q0);

    wire [143:0] q1_next =
        pop_this_cycle
            ? ((q_count == 2'd2) ? (push_ok ? new_rec : 144'd0)
                                 : 144'd0)
            : (push_ok & (q_count == 2'd1) ? new_rec : q1);

    wire [1:0] q_count_next = count_after_pop + (push_ok ? 2'd1 : 2'd0);

    // ---- S2.5: drain into eth_mac_if.v ----
    // latency_cyc is computed live at the pop using the record's stored
    // ingress_cycle, so a record that waited in the queue reports its real
    // wait (FR-53/54's ingress->egress definition).
    wire [31:0] lat_diff = cur_cycle - q0[31:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q0         <= 144'd0;
            q1         <= 144'd0;
            q_count    <= 2'd0;
            tx_payload <= 128'd0;
            tx_start   <= 1'b0;
        end else begin
            tx_payload <= 128'd0;
            tx_start   <= 1'b0;      // one-shot: 0 unless a pop fires below
            if (pop_this_cycle) begin
                // S2.6: byte 0 (msg_type) in the MSBs; a plain concat of the
                // full-width fields is already the big-endian wire order.
                tx_payload <= { q0[143:136],   // msg_type
                                q0[135:128],   // symbol_id
                                q0[127:120],   // side
                                q0[119:112],   // reject_reason
                                q0[111:80],    // price
                                q0[79:48],     // quantity
                                q0[47:32],     // trigger_seq
                                lat_diff[15:0] };   // latency_cyc
                tx_start   <= 1'b1;
            end
            q0      <= q0_next;
            q1      <= q1_next;
            q_count <= q_count_next;
        end
    end

endmodule
