`timescale 1ns / 1ps

// rtl/signal_engine.v
//
// Deterministic spread+imbalance decision rule (master spec S3.1 [H], S3.2
// "signal path (fast)", FR-35..40; contract docs/contracts/signal_engine.md).
// After each book-modifying update it decides whether the book currently
// justifies a buy or sell order intent, using only comparisons, subtraction,
// and shifts (FR-39 -- no multiplier, no DSP on this path).
//
// The decision reads the tob_engine.v state buses (POST-update state of the
// applied slot) and is gated on book_upd_valid (FR-40: evaluated only on
// book-modifying messages, not on a timer):
//
//   buy_ok  = bid_valid & ask_valid & ~crossed
//             & (ask_price - bid_price) >= cfg_min_spread
//             & bid_qty > (ask_qty << cfg_imb_shift)     -- wide, S2.4
//   sell_ok = bid_valid & ask_valid & ~crossed
//             & (ask_price - bid_price) >= cfg_min_spread
//             & ask_qty > (bid_qty << cfg_imb_shift)     -- wide, S2.4
//
// Both are computed combinationally each cycle; the intent is registered one
// cycle after book_upd_valid (S2.3): a buy is signalled at the ask price,
// a sell at the bid price, qty = cfg_order_qty in both cases. sig_side
// reuses the wire-format SIDE_BID(0x00)/SIDE_ASK(0x01) encoding so intent
// records match sim/golden_model.py's OrderRecord.side.
//
// Three deliberate, related design points (each is a real footgun this file
// exists to get right):
//
//  * D15 (docs/design_decisions.md): the imbalance shifts are computed in a
//    35-bit intermediate -- zero-extending each qty by cfg_imb_shift's full
//    3-bit range BEFORE shifting -- never as a plain 32-bit
//    `qty << cfg_imb_shift`. Python (sim/golden_model.py) never overflows,
//    so a 32-bit RTL shift that silently drops the top bits can make
//    `bid_qty > (ask_qty << 1)` AND `ask_qty > (bid_qty << 1)` BOTH read
//    true (e.g. bid_qty = ask_qty = 0x80000000, imb_shift = 1), a spurious
//    conflict the golden model would never produce. 35 bits is enough
//    headroom that a 32-bit quantity shifted left by up to 3 bits can never
//    lose a bit off the top; under that arithmetic buy_ok & sell_ok really
//    are mutually exclusive for every legal input, matching the reference.
//
//  * crossed is read directly from tob_engine.v's output and ANDed in as its
//    own independent term (FR-35/36 list "not crossed" as a required input,
//    not something to re-derive): `ask_price - bid_price`, done as a plain
//    unsigned 32-bit subtraction, UNDERFLOWS to a huge positive value on a
//    crossed book (bid_price >= ask_price), so a crossed book would look
//    like an enormous spread to anything relying only on the subtraction.
//    `~crossed` zeroes the whole AND term regardless of what the wrapped
//    spread value would otherwise say, so the subtraction needs no "fix".
//
//  * err_signal_conflict (FR-37) fires on book_upd_valid & buy_ok & sell_ok
//    instead of any intent. Once the wide-precision arithmetic above is in
//    place it is mathematically unreachable through honest 32-bit inputs --
//    the check is cheap, spec-required, defensive logic kept in deliberately
//    (docs/contracts/signal_engine.md S2.5); its testbench exercises it by
//    force/release on the internal buy_ok/sell_ok wires, the only way to
//    reach that state.
//
// cfg_min_spread / cfg_imb_shift / cfg_order_qty are direct ports (S9 CSR
// map: MIN_SPREAD @0x1C default 2, IMB_SHIFT @0x20 default 1 range 0-3,
// ORDER_QTY @0x24 default 100), standing in for csr_block.v, which does not
// exist yet -- the same pattern as every S3 module's cfg_* ports.
//
// This is the deterministic signal path only; it does not read the ML path
// (feature_extractor.v/feature_normalizer.v) at all, and the order intent is
// NOT a guaranteed order (the S7 risk gates and S8 order_builder.v own that).
//
// Verilog-2001 only.

module signal_engine #(
    parameter integer NUM_SYMBOLS = 4   // matches tob_engine.v
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from tob_engine.v -- post-update state of the applied slot
    // (docs/contracts/tob_engine.md), gated on book_upd_valid (FR-40)
    input  wire                       book_upd_valid,
    input  wire [1:0]                 applied_slot,
    input  wire [NUM_SYMBOLS*32-1:0]  bid_price,
    input  wire [NUM_SYMBOLS*32-1:0]  bid_qty,
    input  wire [NUM_SYMBOLS-1:0]     bid_valid,
    input  wire [NUM_SYMBOLS*32-1:0]  ask_price,
    input  wire [NUM_SYMBOLS*32-1:0]  ask_qty,
    input  wire [NUM_SYMBOLS-1:0]     ask_valid,
    input  wire [NUM_SYMBOLS-1:0]     crossed,

    // config (S9 CSR map), direct ports standing in for csr_block.v
    input  wire [31:0] cfg_min_spread,
    input  wire [1:0]  cfg_imb_shift,   // 0-3, matches the CSR field's range
    input  wire [31:0] cfg_order_qty,

    // order intent, registered one cycle after book_upd_valid (S2.3)
    output reg         sig_valid,
    output reg  [1:0]  sig_slot,
    output reg  [7:0]  sig_side,
    output reg  [31:0] sig_price,
    output reg  [31:0] sig_qty,

    // status: one-cycle pulse, combinational with book_upd_valid (FR-37)
    output wire        err_signal_conflict
);

    localparam [7:0] SIDE_BID = 8'h00;   // buy at the ask (wire format)
    localparam [7:0] SIDE_ASK = 8'h01;   // sell at the bid

    // ---- applied slot's post-update state ----
    wire [31:0] s_bp = bid_price [applied_slot*32 +: 32];
    wire [31:0] s_bq = bid_qty   [applied_slot*32 +: 32];
    wire        s_bv = bid_valid [applied_slot];
    wire [31:0] s_ap = ask_price [applied_slot*32 +: 32];
    wire [31:0] s_aq = ask_qty   [applied_slot*32 +: 32];
    wire        s_av = ask_valid [applied_slot];
    wire        s_cr = crossed   [applied_slot];

    // ---- D15 (S2.4): wide-precision imbalance shift. Zero-extend each qty
    //      by cfg_imb_shift's maximum width (3 bits -- IMB_SHIFT is 0-3)
    //      BEFORE shifting, and compare at that 35-bit width, so a shifted
    //      quantity can never lose a bit off the top. A plain 32-bit
    //      `qty << cfg_imb_shift` is the bug this guards against. ----
    wire [34:0] ask_shifted = {3'b0, s_aq} << cfg_imb_shift;
    wire [34:0] bid_shifted = {3'b0, s_bq} << cfg_imb_shift;
    wire        buy_qty_ok  = ({3'b0, s_bq} > ask_shifted);
    wire        sell_qty_ok = ({3'b0, s_aq} > bid_shifted);

    // ---- FR-35/36. crossed is an independent AND term: when the book is
    //      crossed (s_bp >= s_ap) the plain unsigned subtraction below
    //      underflows to a huge value, and only ~s_cr keeps that wrapped
    //      spread from reading as "enormous but tradeable". ----
    wire spread_ok = ((s_ap - s_bp) >= cfg_min_spread);

    wire base_ok = s_bv & s_av & ~s_cr & spread_ok;
    wire buy_ok  = base_ok & buy_qty_ok;
    wire sell_ok = base_ok & sell_qty_ok;

    // ---- FR-37: defensive, provably unreachable via honest inputs once the
    //      wide-precision shift above is in place (see file header). On a
    //      conflict no intent is emitted -- only the pulse. ----
    wire conflict = book_upd_valid & buy_ok & sell_ok;
    assign err_signal_conflict = conflict;

    // ---- registered order intent, one cycle after book_upd_valid ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sig_valid <= 1'b0;
            sig_slot  <= 2'd0;
            sig_side  <= 8'd0;
            sig_price <= 32'd0;
            sig_qty   <= 32'd0;
        end else if (book_upd_valid) begin
            sig_slot <= applied_slot;
            if (conflict) begin
                sig_valid <= 1'b0;      // FR-37: pulse replaces any intent
                sig_side  <= 8'd0;
                sig_price <= 32'd0;
                sig_qty   <= 32'd0;
            end else if (buy_ok) begin
                sig_valid <= 1'b1;
                sig_side  <= SIDE_BID;
                sig_price <= s_ap;      // buy at the ask
                sig_qty   <= cfg_order_qty;
            end else if (sell_ok) begin
                sig_valid <= 1'b1;
                sig_side  <= SIDE_ASK;
                sig_price <= s_bp;      // sell at the bid
                sig_qty   <= cfg_order_qty;
            end else begin
                sig_valid <= 1'b0;      // slot/side/price/qty are don't-care
            end
        end else begin
            sig_valid <= 1'b0;
        end
    end

endmodule
