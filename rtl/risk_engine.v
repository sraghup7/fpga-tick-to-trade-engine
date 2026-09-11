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
//   0x04 band      |sig_price - mid| > band    0x09 ML       adverse[sig_slot] & ~ml_action
//   0x05 stale     arrival gap > cfg_max_age
//
// Gate 0x09 is per-symbol (D47): it reads only THIS message's own slot's
// adverse_risk bit (adverse_risk[sig_slot]), not a single register shared
// across every watched feed -- an unrelated symbol's ML verdict must not
// gate this symbol's order (docs/contracts/ml_policy_per_symbol.md).
//
// Reject-reason priority is lowest gate number wins (FR-43), but EVERY gate
// that fired gets its own gate_*_fired pulse (registered TWO cycles after
// sig_valid -- see D34 below -- same timing as the order decision) so a
// later CSR/counters block can increment all of them. This is the last
// stage of the fast path; it must never be slower, disableable, or bypassable
// (FR-41).
//
// Three deliberate design points this file exists to get right:
//
//  * D17 + D28 (docs/design_decisions.md): gate 0x05 compares the PRE-update
//    per-slot timestamp, and gates 0x04/0x07 compare the book state, all AS
//    OF THE SPECIFIC MESSAGE that produced this order intent. tob_engine's
//    msg_applied fires on the triggering message's own cycle (call it T);
//    last_update_cycle is refreshed on EVERY msg_applied (any msg_type,
//    FR-19), and pend_prev_cycle/pend_msg_cycle capture the OLD timestamp
//    and the arrival cycle at that same T edge. D17's capture mechanism is
//    therefore guaranteed correct for message T on exactly the RAW
//    sig_valid cycle (T+1 -- signal_engine.v registers its intent one cycle
//    after the book update, unconditionally), because nothing else can have
//    touched pend_prev_cycle/pend_msg_cycle or the per-slot book registers
//    between T and T+1. That was the design's original one-cycle pipeline
//    alignment, "automatic by construction".
//
//    S6 (docs/contracts/ml_integration.md) then inserted ALIGN_DEPTH cycles
//    of delay between signal_engine and this module (the top level retargets
//    this module's sig_valid/sig_slot ports to the aligned bus), and the
//    automatic-by-construction claim silently stopped being true: gates
//    0x04/0x05/0x07 re-read the live book registers / pend pair at the
//    aligned arrival cycle, by which time intervening messages (any slot,
//    any type) had overwritten them -- D28. The fix (this file, D28): a
//    snapshot of {bid,ask,crossed,pend_prev,pend_msg} for the triggering
//    message is captured on the RAW sig_valid cycle -- via the
//    sig_valid_raw/sig_slot_raw ports, keyed on signal_engine's raw output
//    -- and carried forward ALIGN_DEPTH cycles by an internal delay_line
//    instance, so it lands already correctly time-referenced on the cycle
//    the ALIGNED sig_valid arrives to evaluate the gates. cfg_max_age /
//    cfg_price_band (the CONFIGURATION being compared) stay live at the
//    gate's own cycle; only the timestamp/book DATA needed the time fix.
//    This is correct for any ALIGN_DEPTH by construction; the top level
//    passes the same ALIGN_DEPTH it uses for its own u_align instance.
//
//  * D34 (docs/design_decisions.md): the nine gates are still all evaluated
//    together in a single combinational stage (stage 1, on the aligned
//    sig_valid cycle -- FR-42's "single cycle" spirit), but the accept/
//    reject decision is now computed one cycle later from a REGISTERED copy
//    of the nine gate booleans (r1_gate_*, stage 2). D28's u_gate_align
//    output feeds deep arithmetic (gate 0x04's midsum/band-diff, gates
//    0x05/0x07 compares); leaving the nine-way priority mux + accept on that
//    same cycle made the post-route critical path run straight through it
//    (u_gate_align -> reject_reason mux -> position_r, WNS -2.282 ns).
//    Registering the gate vector breaks that cone: stage 2 is only a shallow
//    mux + equality on registered bits.
//
//    TRADEOFF (deliberate, do not engineer around): order_valid (and the
//    position-ledger write that commits an accepted order) now land TWO
//    cycles after sig_valid instead of one. Gate 0x03 reads position_r live
//    in stage 1, so a second ALIGNED intent on the SAME slot must arrive at
//    least 2 cycles after the first for its gate 0x03 check to see the
//    first's position update; at 1-cycle spacing it will miss it (the ledger
//    write from the stale prospective then wins, exactly as D28 documented
//    for NFR-5's "one message per cycle" claim -- true architecturally,
//    false under maximally dense same-slot traffic, fine in practice at
//    NFR-4's 16-cycle nominal spacing). accepted_c fundamentally needs all
//    nine gates' results, so the write cannot be pulled earlier without
//    producing a wrong answer; there is no version of this fix that avoids
//    widening this window.
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
    parameter integer NUM_SYMBOLS = 4,  // matches every other S3/S5 module
    parameter integer ALIGN_DEPTH = 1   // MUST equal the top level's own
                                        // ALIGN_DEPTH (tob_top.v) -- the
                                        // number of cycles sig_valid/sig_slot
                                        // are delayed between signal_engine
                                        // and this module (D28). See header.
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from signal_engine.v -- one order intent per pulse. sig_valid/sig_slot
    // (below) carry the ALIGNED intent (delayed ALIGN_DEPTH cycles at the
    // top level so the ML verdict's registered value reflects the SAME
    // triggering event, S6). They are what actually gate the order decision.
    input  wire        sig_valid,
    input  wire [1:0]  sig_slot,
    input  wire [7:0]  sig_side,     // SIDE_BID(0x00)/SIDE_ASK(0x01)
    input  wire [31:0] sig_price,
    input  wire [31:0] sig_qty,

    // D28 (NEW): signal_engine's RAW (pre-alignment) sig_valid/sig_slot --
    // fires exactly one cycle after this message's own book_upd_valid /
    // msg_applied (signal_engine.v's always block). Used ONLY to time the
    // internal snapshot below (S1/S2 of docs/contracts/risk_engine_align_fix
    // .md); never used to gate the order decision.
    input  wire        sig_valid_raw,
    input  wire [1:0]  sig_slot_raw,

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

    // ML verdict, external -- ml_policy.v. D47
    // (docs/design_decisions.md D47): a NUM_SYMBOLS-wide vector, one
    // hysteresis bit per watched symbol; this message's own slot's bit is
    // the one that gates it (gate_ml_fired_c / reduced_qty_c index
    // adverse_risk[sig_slot] below).
    input  wire [NUM_SYMBOLS-1:0] adverse_risk,

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

    // order decision, registered TWO cycles after sig_valid (D34)
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
    // BEFORE this message's refresh and the arrival cycle -- correct for
    // this message exactly one cycle later, on the RAW sig_valid cycle,
    // where D28's snapshot (u_gate_align below) captures them.
    reg [NUM_SYMBOLS*32-1:0] last_update_cycle;
    reg [31:0] pend_prev_cycle;
    reg [31:0] pend_msg_cycle;

    // ---- free-running token bucket (S2.3) ----
    // D54: refill_ctr_p1 stores (the old refill_ctr's value) + 1 as a
    // maintained invariant, instead of storing refill_ctr and adding 1 to
    // it every time refill_tick needs to be checked. This keeps the "+1"
    // off risk_engine's own critical path (u_risk/refill_ctr_reg[1]/C ->
    // u_risk/token_bucket_reg[31]/D, -0.752ns pre-fix) -- refill_tick
    // becomes a direct 32-bit compare against a register, with no
    // incrementer in front of it. The "+1" still happens, just on
    // refill_ctr_p1's OWN next-state path (a separate register-to-register
    // path, not the one that was violated) instead of on the forward path
    // into token_bucket. Provably equivalent: refill_ctr_p1 == (what
    // refill_ctr would have held) + 1, maintained from reset (refill_ctr
    // started at 0, so refill_ctr_p1 starts at 1) through every update.
    // Nothing outside this module ever reads refill_ctr by name (grepped
    // tb/, sim/, docs/ before renaming) -- token_bucket keeps its name
    // unchanged, since tb/tb_risk_engine.v:224 hierarchically probes it.
    reg [31:0] refill_ctr_p1;
    reg [31:0] token_bucket;
    // D38: token_bucket's async reset target (cfg_token_max) is a live CSR
    // value, not a compile-time constant. Xilinx 7-series flip-flop
    // primitives (FDCE/FDPE) only support async set/clear to a hardwired
    // constant (0 or 1) -- an async reset to a runtime value forces Vivado
    // to decompose each bit into a set-FF/clear-FF pair muxed through an
    // LDCE latch (confirmed: `token_bucket <= cfg_token_max;` in the reset
    // branch triggers Synth 8-7137 "has both Set and reset with same
    // priority", reproduced+fixed in isolation before touching this file --
    // see docs/design_decisions.md D38). boot_done keeps the reset itself a
    // plain constant-0 clear (cheap FDCE) and substitutes cfg_token_max
    // combinationally as the effective bucket value until the first real
    // clock edge loads it for real -- token_bucket_eff is provably equal to
    // the old (cfg_token_max-reset) value on every cycle, reset or not.
    reg        boot_done;

    // ---- per-slot position ledger (FR-45): signed two's complement ----
    reg [NUM_SYMBOLS*32-1:0] position_r;
    assign position = position_r;

    // ---- D34: stage-2 pipeline registers. All nine gates are still
    //      evaluated together, at sig_valid's own cycle (FR-42's "single
    //      cycle" spirit preserved -- this is still one message's gate
    //      vector, computed together; it now takes two clock cycles to reach
    //      a decision, the same tradeoff D26/D27 already made for
    //      feature_extractor.v's F0-F7). Registering the nine booleans here,
    //      instead of continuing straight into the priority mux, is what
    //      actually fixes D34 -- the mux and the accept decision move to
    //      stage 2, cheap and shallow (docs/design_decisions.md D34). ----
    reg        r1_valid;
    reg [1:0]  r1_slot;
    reg [7:0]  r1_side;
    reg [31:0] r1_price;
    reg [31:0] r1_qty;           // UNREDUCED sig_qty (D18 reject-path reporting)
    reg [31:0] r1_reduced_qty;
    reg [31:0] r1_next_pos;      // prospective post-order position (D16)
    reg        r1_gate_kill, r1_gate_size, r1_gate_position, r1_gate_band,
               r1_gate_stale, r1_gate_seqgap, r1_gate_crossed, r1_gate_throttle,
               r1_gate_ml;

    // ================= D28: book-state snapshot + alignment (see header) ===
    // The RAW sig_valid cycle (one cycle after the triggering message's own
    // msg_applied/book_upd_valid edge) is the single cycle where D17's
    // pend_prev_cycle/pend_msg_cycle capture and the per-slot book registers
    // are known-correct for THIS message specifically. Snapshot them there
    // and carry the snapshot forward ALIGN_DEPTH cycles so the values land
    // already correctly time-referenced when the ALIGNED sig_valid arrives
    // to actually evaluate gates 0x04/0x05/0x07. Config (cfg_max_age /
    // cfg_price_band) stays LIVE at the gate's own cycle -- only the DATA
    // being compared needed the time fix (docs/design_decisions.md D28).
    wire [31:0] snap_bp      = bid_price[sig_slot_raw*32 +: 32];
    wire [31:0] snap_ap      = ask_price[sig_slot_raw*32 +: 32];
    wire        snap_crossed = crossed[sig_slot_raw];
    // pend_prev_cycle/pend_msg_cycle are read combinationally here; they are
    // correct for THIS message exactly while sig_valid_raw is high (S1).

    wire [128:0] gate_snap_in = {snap_bp, snap_ap, snap_crossed,
                                 pend_prev_cycle, pend_msg_cycle};
    wire [128:0] gate_snap_out;
    wire         gate_snap_out_valid;

    delay_line #(
        .WIDTH (129),
        .DEPTH (ALIGN_DEPTH)
    ) u_gate_align (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (sig_valid_raw),
        .in_data   (gate_snap_in),
        .out_valid (gate_snap_out_valid),
        .out_data  (gate_snap_out)
    );

    // gate_snap_out_valid MUST coincide with sig_valid on every cycle: both
    // are sig_valid_raw delayed by the same ALIGN_DEPTH (this instance vs.
    // the top level's u_align). tb/tb_risk_engine.v asserts this directly so
    // a future ALIGN_DEPTH drift is caught in simulation, not a third audit.
    wire [31:0] a_bp        = gate_snap_out[128:97];
    wire [31:0] a_ap        = gate_snap_out[96:65];
    wire        a_crossed   = gate_snap_out[64];
    wire [31:0] a_pend_prev = gate_snap_out[63:32];
    wire [31:0] a_pend_msg  = gate_snap_out[31:0];

    // ================= combinational logic =================

    // free-running refill (see sequential block below for state update)
    // D54: direct compare, no incrementer -- refill_ctr_p1 already holds
    // (old refill_ctr)+1.
    wire refill_tick = (refill_ctr_p1 >= cfg_token_refill_cycles);
    // D54: refill_ctr_p1_next maintains the "+1" invariant: it must equal
    // (what the old refill_ctr_next would have been) + 1. Derivation:
    //   old refill_ctr_next = refill_tick ? (refill_ctr+1-cfg) : (refill_ctr+1)
    //                        = refill_tick ? (refill_ctr_p1-cfg) : refill_ctr_p1
    //   new refill_ctr_p1_next = old refill_ctr_next + 1
    //                          = refill_tick ? (refill_ctr_p1-cfg+1) : (refill_ctr_p1+1)
    // This add/subtract now lives entirely on refill_ctr_p1's own
    // register-to-register path, decoupled from token_bucket's path below.
    wire [31:0] refill_ctr_p1_next = refill_tick
        ? (refill_ctr_p1 - cfg_token_refill_cycles + 32'd1)
        : (refill_ctr_p1 + 32'd1);
    // D38: substitute cfg_token_max for token_bucket until the reset-time
    // synchronous load actually lands (see boot_done's declaration above).
    wire [31:0] token_bucket_eff = boot_done ? token_bucket : cfg_token_max;
    // D54: inc replaces "refill_tick && (token_bucket_eff < cfg_token_max)"
    // -- same expression, named so the merged token_bucket_next below reads
    // clearly.
    wire inc = refill_tick && (token_bucket_eff < cfg_token_max);

    // ---- the nine gates, all combinational on the sig_valid cycle ----
    // D28: gates 0x04/0x05/0x07 read the snapshot taken on the RAW sig_valid
    // cycle (delivered here via u_gate_align), NOT the live book/timestamp
    // registers -- those have been overwritten by intervening messages by
    // the time the ALIGNED sig_valid arrives.
    wire [31:0] s_bp = a_bp;
    wire [31:0] s_ap = a_ap;

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

    wire gate_stale_fired_c    = (a_pend_msg - a_pend_prev) > cfg_max_age; // D17+D28
    wire gate_seqgap_fired_c   = seq_gap;
    wire gate_crossed_fired_c  = a_crossed;                               // D28
    // D54: token_after_refill == 0 iff (!inc && token_bucket_eff == 0) --
    // proof: when inc is true, token_bucket_eff < cfg_token_max is
    // required, so token_bucket_eff+1 <= cfg_token_max <= 32'hFFFFFFFF,
    // meaning it can only be 0 by wrapping, which would require
    // token_bucket_eff == 32'hFFFFFFFF -- impossible given
    // token_bucket_eff < cfg_token_max already holds. So inc==1 implies
    // token_after_refill != 0 always; when inc==0, token_after_refill ==
    // token_bucket_eff unchanged, so it's 0 exactly when
    // token_bucket_eff is. This lets gate_throttle_fired_c be computed
    // directly with no dependency on a materialized token_after_refill
    // signal.
    wire gate_throttle_fired_c = (!inc && (token_bucket_eff == 32'd0));
    // D47 (ml_policy_per_symbol.md S2): gate 0x09 reads THIS message's own
    // slot's adverse bit (sig_slot = the aligned intent's slot, the same
    // index gate 0x03/0x07 already use), never some other slot's.
    wire gate_ml_fired_c       = adverse_risk[sig_slot] & ~cfg_ml_action;

    // ---- D34 (stage 2): reject_reason/accepted_c are now computed from the
    //      REGISTERED gate vector (r1_gate_*), one cycle after the gates
    //      themselves. This is the only place reject_reason_c/accepted_c are
    //      computed -- the stage-1 versions that read gate_*_fired_c directly
    //      are gone. Splitting the nine-gate evaluation (stage 1, deep: the
    //      u_gate_align-fed band-diff / compare cones) from the priority mux
    //      + accept decision (stage 2, cheap and shallow) is the D34 fix --
    //      the mux no longer has to sit on the same cycle as the slow gate
    //      arithmetic (docs/design_decisions.md D34). ----
    wire [7:0] reject_reason_c =
        r1_gate_kill     ? 8'd1 :
        r1_gate_size     ? 8'd2 :
        r1_gate_position ? 8'd3 :
        r1_gate_band     ? 8'd4 :
        r1_gate_stale    ? 8'd5 :
        r1_gate_seqgap   ? 8'd6 :
        r1_gate_crossed  ? 8'd7 :
        r1_gate_throttle ? 8'd8 :
        r1_gate_ml       ? 8'd9 : 8'd0;
    wire accepted_c = r1_valid & (reject_reason_c == 8'd0);

    // ---- ML reduce (D16): max(1, sig_qty >> shift) when reducing ----
    // D47: reduce only when THIS message's own slot is adverse.
    wire [31:0] reduced_qty_c = (adverse_risk[sig_slot] & cfg_ml_action)
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

    // ---- D34: register stage 1 -> stage 2. Unconditional every cycle (not
    //      gated on sig_valid) so r1_valid tracks sig_valid exactly one
    //      cycle later and no intent can be lost between the two stages. ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1_valid <= 1'b0;
            r1_slot  <= 2'd0;
            r1_side  <= 8'd0;
            r1_price <= 32'd0;
            r1_qty   <= 32'd0;
            r1_reduced_qty <= 32'd0;
            r1_next_pos    <= 32'd0;
            r1_gate_kill <= 1'b0; r1_gate_size <= 1'b0; r1_gate_position <= 1'b0;
            r1_gate_band <= 1'b0; r1_gate_stale <= 1'b0; r1_gate_seqgap <= 1'b0;
            r1_gate_crossed <= 1'b0; r1_gate_throttle <= 1'b0; r1_gate_ml <= 1'b0;
        end else begin
            r1_valid <= sig_valid;
            r1_slot  <= sig_slot;
            r1_side  <= sig_side;
            r1_price <= sig_price;
            r1_qty   <= sig_qty;
            r1_reduced_qty <= reduced_qty_c;
            r1_next_pos    <= next_pos[31:0];
            r1_gate_kill     <= gate_kill_fired_c;
            r1_gate_size     <= gate_size_fired_c;
            r1_gate_position <= gate_position_fired_c;
            r1_gate_band     <= gate_band_fired_c;
            r1_gate_stale    <= gate_stale_fired_c;
            r1_gate_seqgap   <= gate_seqgap_fired_c;
            r1_gate_crossed  <= gate_crossed_fired_c;
            r1_gate_throttle <= gate_throttle_fired_c;
            r1_gate_ml       <= gate_ml_fired_c;
        end
    end

    // D54: token_bucket_next replaces the old "compute token_after_refill,
    // then conditionally subtract 1 from it" chain (two SERIAL 32-bit
    // carry chains) with a single mux over 4 independently-computable
    // candidates (each needs at most ONE 32-bit add or subtract, not two
    // chained). Case-by-case equivalence to the original expressions:
    //   (inc=1, accepted_c=1): old = (eff+1), then clamp-check sees
    //     eff+1 != 0 (proven above), so subtracts 1 back: eff+1-1 = eff.
    //   (inc=1, accepted_c=0): old = eff+1, no subtract.
    //   (inc=0, accepted_c=1): old = eff unchanged, then clamp-check:
    //     eff==0 ? 0 : eff-1.
    //   (inc=0, accepted_c=0): old = eff unchanged, no subtract.
    // Every branch below matches one of these four cases exactly.
    wire [31:0] token_bucket_next =
        inc ? (accepted_c ? token_bucket_eff : (token_bucket_eff + 32'd1))
            : (accepted_c ? ((token_bucket_eff == 32'd0) ? 32'd0 : (token_bucket_eff - 32'd1))
                          : token_bucket_eff);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refill_ctr_p1 <= 32'd1;   // D54: represents (old refill_ctr=0)+1
            token_bucket  <= 32'd0;   // D38: constant reset value -- boot_done
                                       // substitutes cfg_token_max until loaded
            boot_done     <= 1'b0;
        end else begin
            refill_ctr_p1 <= refill_ctr_p1_next;
            boot_done     <= 1'b1;
            // D45: the clamp-at-0 behavior (never wrap to 32'hFFFFFFFF) is
            // folded into token_bucket_next's (inc=0, accepted_c=1) branch
            // above -- same guard, same reasoning (gate_throttle_fired_c
            // samples token_bucket one cycle before this commits, so
            // back-to-back aligned intents can still both pass the gate;
            // without the clamp gate 0x08 would silently disable itself
            // permanently, FR-41). D45's own separately-deferred
            // over-admission-on-a-burst issue is unchanged by this task.
            token_bucket <= token_bucket_next;
        end
    end

    // D34: the position write now consumes the stage-2 (registered) slot and
    // prospective value, gated by the stage-2 accepted_c -- so gate 0x03's
    // read of position_r (stage 1) sees a given accepted order's update only
    // when the NEXT same-slot intent is at least 2 aligned cycles later.
    // Two same-slot intents 1 cycle apart: the second's gate 0x03 check runs
    // before the first's position write commits, so it misses the update
    // (deliberate, documented in the header / docs/design_decisions.md D34).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            position_r <= {NUM_SYMBOLS*32{1'b0}};
        end else if (accepted_c) begin
            position_r[r1_slot*32 +: 32] <= r1_next_pos;
        end
    end

    // ---- registered order decision + one pulse per fired gate, keyed on
    //      the stage-2 r1_valid and sourced from the stage-2 registers
    //      (D34). order_valid now pulses TWO cycles after sig_valid (was
    //      one); the gate pulses carry the same timing as the decision. ----
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
        end else if (r1_valid) begin
            order_valid   <= accepted_c;
            order_slot    <= r1_slot;
            order_side    <= r1_side;
            order_price   <= r1_price;
            // D18: r1_reduced_qty only reflects what was actually ORDERED
            // when the order is accepted; a rejected intent reports the
            // unreduced r1_qty (matching sim/golden_model.py's reject-path
            // OrderRecord, which uses order_qty not reduced_qty -- gate
            // 0x03's own check in stage 1 already used the unreduced qty
            // too, for the same FR-48 reason).
            order_qty     <= accepted_c ? r1_reduced_qty : r1_qty;
            reject_reason <= reject_reason_c;
            gate_kill_fired     <= r1_gate_kill;
            gate_size_fired     <= r1_gate_size;
            gate_position_fired <= r1_gate_position;
            gate_band_fired     <= r1_gate_band;
            gate_stale_fired    <= r1_gate_stale;
            gate_seqgap_fired   <= r1_gate_seqgap;
            gate_crossed_fired  <= r1_gate_crossed;
            gate_throttle_fired <= r1_gate_throttle;
            gate_ml_fired       <= r1_gate_ml;
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
