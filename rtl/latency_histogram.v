`timescale 1ns / 1ps

// rtl/latency_histogram.v
//
// Latency instrumentation (master spec S3.1 [L], FR-53..55, NFR-1/2;
// contract docs/contracts/latency_histogram.md). Buckets each transmitted
// accepted order's already-computed latency_cyc into a 64-entry BRAM
// histogram for later CSR readout. This is the mechanism behind NFR-2's
// claim -- a single occupied bucket for the accepting path, max == min --
// so bucket resolution is deliberately EXACT (D21 point 2): one latency
// cycle per bucket 0-62, bucket 63 the >=63 catch-all. A coarser bucket
// would silently hide the single-cycle jitter NFR-2 exists to catch.
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
//     BRAM read -- not wired into csr_block.v's CSR mux by this contract
//     (S10 integration; see D21's two deferred csr_block.v patches).
//
// The write port is a saturating increment (same idiom as every counter in
// this project -- a bucket that reaches all-ones holds there rather than
// wrapping). cfg_counter_clear and reset both sweep all 64 entries to zero
// in one cycle. The read port is deliberately NOT reset: it is the
// standard two-always dual-port BRAM inference shape (one registered read
// port, no unconditional reset on the memory read register).
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

    // standalone readout (D21 point 3): registered BRAM read
    input  wire [5:0]   hist_rd_addr,
    output reg  [31:0]  hist_rd_data
);

    // ---- S2.2: derive lat_valid/lat_value (purely combinational; ob_tx_start
    // is already a one-cycle pulse, so lat_valid inherits that shape) ----
    assign lat_valid = ob_tx_start & (ob_tx_payload[127:120] == 8'h10);
    assign lat_value = ob_tx_payload[15:0];

    // ---- S2.3: bucket index -- exact 0..62, >=63 saturates to bucket 63 ----
    wire [5:0] bucket_idx = (lat_value > 16'd63) ? 6'd63 : lat_value[5:0];

    // ---- S2.4: the 64-entry BRAM ----
    reg [BUCKET_W-1:0] hist_mem [0:63];
    integer i;

    // write port: saturating increment on lat_valid, cleared on
    // cfg_counter_clear / reset (full 64-entry sweep in one cycle)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 64; i = i + 1)
                hist_mem[i] <= {BUCKET_W{1'b0}};
        end else if (cfg_counter_clear) begin
            for (i = 0; i < 64; i = i + 1)
                hist_mem[i] <= {BUCKET_W{1'b0}};
        end else if (lat_valid) begin
            hist_mem[bucket_idx] <= (hist_mem[bucket_idx] == {BUCKET_W{1'b1}})
                                        ? hist_mem[bucket_idx]
                                        : hist_mem[bucket_idx] + 1'b1;
        end
    end

    // read port: registered, one cycle of latency, standard BRAM shape.
    // No reset -- an unconditional reset on the memory read register can
    // defeat block-RAM inference on some toolchains. hist_rd_data settles
    // within one cycle of any hist_rd_addr change. A narrower BUCKET_W
    // zero-extends to the 32-bit read port.
    always @(posedge clk) begin
        hist_rd_data <= hist_mem[hist_rd_addr];
    end

endmodule
