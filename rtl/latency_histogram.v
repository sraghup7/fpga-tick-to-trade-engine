`timescale 1ns / 1ps

// rtl/latency_histogram.v
//
// Latency instrumentation (master spec S3.1 [L], FR-53..55, NFR-1/2;
// contract docs/contracts/latency_histogram.md). Buckets each transmitted
// accepted order's already-computed latency_cyc into a 64-entry memory
// histogram for later CSR readout. This is the mechanism behind NFR-2's
// claim -- a single occupied bucket for the accepting path, max == min --
// so bucket resolution is deliberately EXACT (D21 point 2): one latency
// cycle per bucket 0-62, bucket 63 the >=63 catch-all. A coarser bucket
// would silently hide the single-cycle jitter NFR-2 exists to catch.
//
// Memory technology note (post-audit finding, see the clear-timing note
// below): FR-54 says "BRAM histogram," but at 64x32 = 2Kb this is small
// enough that Vivado's default inference correctly and deliberately picks
// LUT-based distributed RAM (22 RAM64M primitives) over a full 18Kb/36Kb
// block RAM tile -- using a real BRAM36 for a 2Kb structure would burn one
// of NFR-7's scarce 8-tile budget for very little benefit. This is treated
// as the right resource choice, not a bug: FR-54's literal wording is
// slightly imprecise here, the same class of spec-vs-reality gap already
// recorded for NFR-7 elsewhere (docs/design_decisions.md D32). Force
// `(* ram_style = "block" *)` on `hist_mem` below if a literal BRAM tile is
// ever actually wanted instead.
//
// Three D21 decisions:
//   * Latency source (point 1): this module never timestamps anything. It
//     reads order_builder.v's already-computed latency_cyc off
//     ob_tx_start/ob_tx_payload[15:0], filtered to msg_type==0x10 (NEW)
//     like csr_block.v's cnt_orders_tx -- 0x11 reject-diagnostic frames are
//     excluded (a rejected order was never transmitted at a measured
//     latency).
//   * Bucket boundaries (point 2): exact 1-cycle resolution, bucket index
//     == value for 0-62; >=63 saturates into bucket 63 (a comparator + mux,
//     no shifter).
//   * Readout (point 3): a standalone hist_rd_addr/hist_rd_data registered
//     memory read -- not wired into csr_block.v's CSR mux by this contract
//     (S10 integration; see D21's two deferred csr_block.v patches).
//
// The write port is a saturating increment (same idiom as every counter in
// this project -- a bucket that reaches all-ones holds there rather than
// wrapping). The read port is deliberately NOT reset: it is the standard
// two-always dual-port memory inference shape (one registered read port, no
// unconditional reset on the memory read register).
//
// Clear timing (fixed post-audit, not part of the original D21 contract):
// cfg_counter_clear and reset both used to sweep all 64 entries to zero in
// ONE cycle -- that does not synthesize to any real memory primitive at
// all (RAM or otherwise). A memory has exactly one write address per port
// per cycle; a single-cycle "write zero to all 64 addresses at once"
// always-block forces Vivado to fall back to 3030 raw FDCE/LUT/CARRY4/
// MUXF7/MUXF8 cells with no memory structure recognized whatsoever --
// confirmed by reading the actual synthesized netlist, not assumed. Both
// reset and cfg_counter_clear now trigger a `clearing` FSM that walks
// addresses 0..63 sequentially over 64 cycles, writing zero to exactly one
// address per cycle through the SAME single write port normal increments
// use -- a plain, inferable single-port memory access pattern (confirmed:
// now 22 RAM64M primitives, 310 total cells -- see the memory technology
// note above for why that's distributed RAM, not block RAM, and why that's
// fine). Consequence: clearing is no longer instantaneous, and a lat_valid
// pulse that arrives WHILE `clearing` is high is dropped (not counted)
// rather than queued -- a deliberate, documented tradeoff (this only
// happens in the ~64 cycles right after reset or an operator-issued
// counter-clear, never during normal operation) in exchange for the
// module actually being a real memory structure instead of 3030 loose
// registers.
//
// BUCKET_W defaults to 32 in production; the parameter exists so the
// testbench can instantiate a narrow bucket width where the saturating
// boundary is reachable in a bounded number of pulses (Icarus cannot force
// a memory word). A narrower BUCKET_W is DV-only; the default keeps the
// interface and behaviour identical to the fixed 32-bit spec'd counter.
//
// Verilog-2001 only.

module latency_histogram #(
    parameter integer BUCKET_W = 32   // per-bucket counter width (32 in
                                      // production; narrowed only for DV)
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from order_builder.v -- the same two signals csr_block.v taps
    input  wire         ob_tx_start,
    input  wire [127:0] ob_tx_payload,  // byte 0 = msg_type; bits [15:0] = latency_cyc

    // from csr_block.v (stand-in port, D21 -- CTRL bit2, one-cycle pulse)
    input  wire         cfg_counter_clear,

    // pin-compatible with csr_block.v's lat_valid/lat_value inputs
    output wire         lat_valid,
    output wire [15:0]  lat_value,

    // standalone readout (D21 point 3): registered memory read
    input  wire [5:0]   hist_rd_addr,
    output reg  [31:0]  hist_rd_data
);

    // ---- S2.2: derive lat_valid/lat_value (purely combinational; ob_tx_start
    // is already a one-cycle pulse, so lat_valid inherits that shape) ----
    assign lat_valid = ob_tx_start & (ob_tx_payload[127:120] == 8'h10);
    assign lat_value = ob_tx_payload[15:0];

    // ---- S2.3: bucket index -- exact 0..62, >=63 saturates to bucket 63 ----
    wire [5:0] bucket_idx = (lat_value > 16'd63) ? 6'd63 : lat_value[5:0];

    // ---- S2.4: the 64-entry memory (distributed RAM in practice -- see
    //      the memory technology note in the file header) ----
    reg [BUCKET_W-1:0] hist_mem [0:63];

    // ---- sequential clear FSM: one address per cycle (see file header) ----
    reg        clearing;
    reg [5:0]  clear_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clearing  <= 1'b1;
            clear_idx <= 6'd0;
        end else if (cfg_counter_clear) begin
            clearing  <= 1'b1;
            clear_idx <= 6'd0;
        end else if (clearing) begin
            clear_idx <= clear_idx + 6'd1;
            if (clear_idx == 6'd63) clearing <= 1'b0;
        end
    end

    // write port: exactly one address per cycle, either the clear sweep's
    // current index (zero) or a saturating increment on lat_valid -- never
    // both, and never a multi-address write. lat_valid pulses that land
    // while `clearing` is high are dropped (file header).
    always @(posedge clk) begin
        if (clearing) begin
            hist_mem[clear_idx] <= {BUCKET_W{1'b0}};
        end else if (lat_valid) begin
            hist_mem[bucket_idx] <= (hist_mem[bucket_idx] == {BUCKET_W{1'b1}})
                                        ? hist_mem[bucket_idx]
                                        : hist_mem[bucket_idx] + 1'b1;
        end
    end

    // read port: registered, one cycle of latency, standard memory-inference
    // shape. No reset -- an unconditional reset on the memory read register
    // can defeat memory inference on some toolchains. hist_rd_data settles
    // within one cycle of any hist_rd_addr change. A narrower BUCKET_W
    // zero-extends to the 32-bit read port.
    always @(posedge clk) begin
        hist_rd_data <= hist_mem[hist_rd_addr];
    end

endmodule
