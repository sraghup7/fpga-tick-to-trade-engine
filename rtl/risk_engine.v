`timescale 1ns / 1ps

// rtl/risk_engine.v
//
// Pre-trade risk block (master spec S3.1 [I], S8, FR-41..48; contract
// docs/contracts/risk_engine.md). Every order intent from signal_engine.v
// passes through nine independent gates, all evaluated in parallel in a
// single cycle (FR-42), before it can become an accepted order:
//
//   0x01 kill      kill_latched                0x06 seq gap  seq_gap (input)
//   0x02 size      sig_qty > cfg_max_order_qty 0x07 crossed  crossed[sig_slot]
//   0x03 position  |pos +- sig_qty| > max      0x08 throttle token bucket empty
//   0x04 band      |sig_price - mid| > band    0x09 ML       adverse & ~ml_action
//   0x05 stale     arrival gap > cfg_max_age
//
// Reject-reason priority is lowest gate number wins (FR-43), but EVERY gate
// that fired gets its own gate_*_fired pulse (registered one cycle after
// sig_valid, same timing as the order decision) so a later CSR/counters
// block can increment all of them. This is the last stage of the fast path;
// it must never be slower, disableable, or bypassable (FR-41).
//
// Three deliberate design points this file exists to get right:
//
//  * D17 (docs/design_decisions.md): gate 0x05 compares the PRE-update
//    per-slot timestamp. tob_engine's msg_applied for a triggering message
//    arrives one cycle before signal_engine's matching sig_valid, so a naive
//    "refresh last_update_cycle then read it at the sig_valid cycle" would
//    always read ~0 (the message's own touch) and gate 0x05 would be
//    unreachable -- exactly the bug D17 fixed in sim/golden_model.py. Here
//    the per-slot last_update_cycle is refreshed on EVERY msg_applied (any
//    msg_type, FR-19) and pend_prev_cycle/pend_msg_cycle capture the OLD
//    value and the arrival cycle at that same edge; the gate compares the
//    captured pair one cycle later, when sig_valid reads them. Because
//    book_upd_valid (hence sig_valid) can only follow a msg_applied cycle,
//    the one-cycle pipeline alignment is automatic by construction.
//
//  * D16 (docs/design_decisions.md): gate 0x03's admission check uses the
//    UNREDUCED sig_qty (FR-48 -- gates 0x01-0x08 evaluate the order as
//    originally sized; the ML reduction is gate 0x09's own action), but the
//    position ledger and reported order_qty use the REDUCED quantity, so
//    the engine's exposure tracking agrees with what it actually emitted.
//
//  * FR-41/FR-45 signed position: position is stored per slot as 32-bit
//    two's complement and is SIGN-EXTENDED when read back into the 33-bit
//    signed arithmetic of gate 0x03 / the ledger update. (The contract's
//    literal `$signed({1'b0, position[...]})` would zero-extend a stored
//    short into ~2^32 and break every gate after the first short sale; the
//    golden model treats position as signed, so sign extension is the
//    bit-exact reading. Position magnitudes are bounded by cfg_max_position,
//    so the 33-bit intermediates never overflow in practice.)
//
// cfg_* / kill_sw_n / cur_cycle / adverse_risk / seq_gap are direct ports
// (standing in for csr_block.v, ml_policy.v, the free-running cycle
// counter, and seq_monitor.v's feed-wide sticky bit respectively). Only the
// raw one-cycle gate pulses and the order decision/reject_reason are
// produced here -- counters/CSR accumulation and the physical kill-switch
// LED live elsewhere. No TX-slot pacing (order_builder.v/eth_mac_if.v, S8).
//
// Verilog-2001 only.

module risk_engine #(
    parameter integer NUM_SYMBOLS = 4   // matches every other S3/S5 module
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from signal_engine.v -- one order intent per pulse
    input  wire        sig_valid,
    input  wire [1:0]  sig_slot,
    input  wire [7:0]  sig_side,     // SIDE_BID(0x00)/SIDE_ASK(0x01)
    input  wire [31:0] sig_price,
    input  wire [31:0] sig_qty,

    // from tob_engine.v -- msg_applied/applied_slot fire on EVERY accepted
    // message (any msg_type), one cycle before a matching sig_valid. Also
    // feeds gate 0x07 (crossed) and gate 0x04's mid-price.
    input  wire                       msg_applied,
    input  wire [1:0]                 applied_slot,
    input  wire [NUM_SYMBOLS*32-1:0]  bid_price,
    input  wire [NUM_SYMBOLS*32-1:0]  ask_price,
    input  wire [NUM_SYMBOLS-1:0]     crossed,

    // from seq_monitor.v -- feed-wide sticky bit (gate 0x06)
    input  wire         seq_gap,

    // ML verdict, external -- ml_policy.v does not exist yet (S6)
    input  wire         adverse_risk,

    // free-running cycle counter, external (must be monotonically
    // incrementing; only subtracted differences are used)
    input  wire [31:0] cur_cycle,

    // kill switch, ALREADY 2FF-synchronized -- active-low (D6)
    input  wire        kill_sw_n,

    // config (S9 CSR map), direct ports standing in for csr_block.v
    input  wire [31:0] cfg_max_order_qty,       // 0x28, default 500
    input  wire [31:0] cfg_max_position,        // 0x2C, default 1000
    input  wire [31:0] cfg_price_band,          // 0x30, default 50
    input  wire [31:0] cfg_max_age,             // 0x34, default 1250000
    input  wire [31:0] cfg_token_max,           // 0x38, default 8
    input  wire [31:0] cfg_token_refill_cycles, // 0x3C, default 12500
    input  wire        cfg_ml_action,           // ML_CTRL bit0: 0 block / 1 reduce
    input  wire [3:0]  cfg_ml_reduce_shift,     // ML_CTRL bits 4:1, 0-15
    input  wire        cfg_kill_clear,          // CTRL bit1, one-cycle pulse

    // order decision, registered one cycle after sig_valid
    output reg         order_valid,
    output reg  [1:0]  order_slot,
    output reg  [7:0]  order_side,
    output reg  [31:0] order_price,
    output reg  [31:0] order_qty,   // D16: reduced when ML reduce applies
    output reg  [7:0]  reject_reason,   // 0x00 = accepted; else lowest gate ID

    // one pulse per gate per evaluated intent, registered (FR-43)
    output reg         gate_kill_fired,
    output reg         gate_size_fired,
    output reg         gate_position_fired,
    output reg         gate_band_fired,
    output reg         gate_stale_fired,
    output reg         gate_seqgap_fired,
    output reg         gate_crossed_fired,
    output reg         gate_throttle_fired,
    output reg         gate_ml_fired,

    // status: kill_latched level for STATUS/LED; signed position per slot
    output wire        kill_latched,
    output wire [NUM_SYMBOLS*32-1:0] position
);

    localparam [7:0] SIDE_BID = 8'h00;

    // ================= state registers =================

    // ---- kill latch (FR-46/47): assert wins over a simultaneous clear ----
    reg kill_latched_r;
    assign kill_latched = kill_latched_r;

    // ---- staleness timestamps (S2.4 / D17) ----
    // last_update_cycle[s] refreshes on EVERY msg_applied of ANY msg_type.
    // pend_prev_cycle/pend_msg_cycle capture, at that same edge, the value
    // BEFORE this message's refresh and the arrival cycle -- the values gate
    // 0x05 compares against one cycle later, on the sig_valid cycle.
    reg [NUM_SYMBOLS*32-1:0] last_update_cycle;
    reg [31:0] pend_prev_cycle;
    reg [31:0] pend_msg_cycle;

    // ---- free-running token bucket (S2.3) ----
    reg [31:0] refill_ctr;
    reg [31:0] token_bucket;

    // ---- per-slot position ledger (FR-45): signed two's complement ----
    reg [NUM_SYMBOLS*32-1:0] position_r;
    assign position = position_r;

    // ================= combinational logic =================

    // free-running refill (see sequential block below for state update)
    wire refill_tick = (refill_ctr + 32'd1) >= cfg_token_refill_cycles;
    wire [31:0] refill_ctr_next = refill_tick
        ? (refill_ctr + 32'd1 - cfg_token_refill_cycles)
        : (refill_ctr + 32'd1);
    wire [31:0] token_after_refill = (refill_tick && (token_bucket < cfg_token_max))
        ? (token_bucket + 32'd1)
        : token_bucket;

    // ---- the nine gates, all combinational on the sig_valid cycle ----
    wire [31:0] s_bp = bid_price[sig_slot*32 +: 32];
    wire [31:0] s_ap = ask_price[sig_slot*32 +: 32];

    wire gate_kill_fired_c     = kill_latched_r;
    wire gate_size_fired_c     = (sig_qty > cfg_max_order_qty);

    // gate 0x03 uses the UNREDUCED sig_qty (FR-48). signed 33-bit
    // arithmetic; position slice is SIGN-EXTENDED (FR-45 signed position).
    wire signed [32:0] signed_qty  = (sig_side == SIDE_BID) ? {1'b0, sig_qty}
                                                            : -{1'b0, sig_qty};
    wire signed [32:0] prospective = signed_qty
                                     + $signed(position_r[sig_slot*32 +: 32]);
    wire [32:0] abs_prospective = prospective[32] ? -prospective : prospective;
    wire gate_position_fired_c = (abs_prospective > {1'b0, cfg_max_position});

    // gate 0x04: mid = (bid+ask)>>1 on the full 33-bit sum (feature_extractor
    // precedent); the band difference is computed SIGNED so a price below mid
    // does not underflow the unsigned subtraction.
    wire [32:0] midsum = {1'b0, s_bp} + {1'b0, s_ap};
    wire [31:0] mid    = midsum[32:1];
    wire signed [32:0] band_diff = $signed({1'b0, sig_price}) - $signed({1'b0, mid});
    wire [32:0] abs_band = band_diff[32] ? -band_diff : band_diff;
    wire gate_band_fired_c = (abs_band > {1'b0, cfg_price_band});

    wire gate_stale_fired_c    = (pend_msg_cycle - pend_prev_cycle) > cfg_max_age; // S2.4/D17
    wire gate_seqgap_fired_c   = seq_gap;
    wire gate_crossed_fired_c  = crossed[sig_slot];
    wire gate_throttle_fired_c = (token_after_refill == 32'd0);
    wire gate_ml_fired_c       = adverse_risk & ~cfg_ml_action;

    // ---- reject reason: lowest gate number wins (FR-43) ----
    wire [7:0] reject_reason_c =
        gate_kill_fired_c     ? 8'd1 :
        gate_size_fired_c     ? 8'd2 :
        gate_position_fired_c ? 8'd3 :
        gate_band_fired_c     ? 8'd4 :
        gate_stale_fired_c    ? 8'd5 :
        gate_seqgap_fired_c   ? 8'd6 :
        gate_crossed_fired_c  ? 8'd7 :
        gate_throttle_fired_c ? 8'd8 :
        gate_ml_fired_c       ? 8'd9 : 8'd0;
    wire accepted_c = sig_valid & (reject_reason_c == 8'd0);

    // ---- ML reduce (D16): max(1, sig_qty >> shift) when reducing ----
    wire [31:0] reduced_qty_c = (adverse_risk & cfg_ml_action)
        ? ((sig_qty >> cfg_ml_reduce_shift) == 32'd0
               ? 32'd1
               : (sig_qty >> cfg_ml_reduce_shift))
        : sig_qty;

    // ledger update uses the REDUCED signed qty (D16); gate 0x03 above
    // deliberately used the unreduced one
    wire signed [32:0] final_signed_qty = (sig_side == SIDE_BID)
        ? {1'b0, reduced_qty_c}
        : -{1'b0, reduced_qty_c};
    wire signed [32:0] next_pos = $signed(position_r[sig_slot*32 +: 32])
                                  + final_signed_qty;

    // ================= sequential logic =================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            kill_latched_r <= 1'b0;
        else if (~kill_sw_n)   kill_latched_r <= 1'b1;
        else if (cfg_kill_clear) kill_latched_r <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_update_cycle <= {NUM_SYMBOLS*32{1'b0}};
            pend_prev_cycle   <= 32'd0;
            pend_msg_cycle    <= 32'd0;
        end else if (msg_applied) begin
            pend_prev_cycle <= last_update_cycle[applied_slot*32 +: 32]; // OLD
            pend_msg_cycle  <= cur_cycle;
            last_update_cycle[applied_slot*32 +: 32] <= cur_cycle;       // refresh
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refill_ctr   <= 32'd0;
            token_bucket <= cfg_token_max;
        end else begin
            refill_ctr <= refill_ctr_next;
            // single next-state expression: refill combined with any
            // same-cycle consumption -- never two separate NBA writes
            if (accepted_c) token_bucket <= token_after_refill - 32'd1;
            else            token_bucket <= token_after_refill;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            position_r <= {NUM_SYMBOLS*32{1'b0}};
        end else if (accepted_c) begin
            position_r[sig_slot*32 +: 32] <= next_pos[31:0];
        end
    end

    // ---- registered order decision + one pulse per fired gate (S2.7) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            order_valid   <= 1'b0;
            order_slot    <= 2'd0;
            order_side    <= 8'd0;
            order_price   <= 32'd0;
            order_qty     <= 32'd0;
            reject_reason <= 8'd0;
            gate_kill_fired     <= 1'b0;
            gate_size_fired     <= 1'b0;
            gate_position_fired <= 1'b0;
            gate_band_fired     <= 1'b0;
            gate_stale_fired    <= 1'b0;
            gate_seqgap_fired   <= 1'b0;
            gate_crossed_fired  <= 1'b0;
            gate_throttle_fired <= 1'b0;
            gate_ml_fired       <= 1'b0;
        end else if (sig_valid) begin
            order_valid   <= accepted_c;
            order_slot    <= sig_slot;
            order_side    <= sig_side;
            order_price   <= sig_price;
            order_qty     <= reduced_qty_c;
            reject_reason <= reject_reason_c;
            gate_kill_fired     <= gate_kill_fired_c;
            gate_size_fired     <= gate_size_fired_c;
            gate_position_fired <= gate_position_fired_c;
            gate_band_fired     <= gate_band_fired_c;
            gate_stale_fired    <= gate_stale_fired_c;
            gate_seqgap_fired   <= gate_seqgap_fired_c;
            gate_crossed_fired  <= gate_crossed_fired_c;
            gate_throttle_fired <= gate_throttle_fired_c;
            gate_ml_fired       <= gate_ml_fired_c;
        end else begin
            order_valid   <= 1'b0;
            reject_reason <= 8'd0;
            gate_kill_fired     <= 1'b0;
            gate_size_fired     <= 1'b0;
            gate_position_fired <= 1'b0;
            gate_band_fired     <= 1'b0;
            gate_stale_fired    <= 1'b0;
            gate_seqgap_fired   <= 1'b0;
            gate_crossed_fired  <= 1'b0;
            gate_throttle_fired <= 1'b0;
            gate_ml_fired       <= 1'b0;
        end
    end

endmodule
