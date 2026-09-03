`timescale 1ns / 1ps

// rtl/frame_classifier.v
//
// Frame-level accept/reject gate between eth_mac_if.v and md_parser.v
// (master spec S3.1 [C], FR-4/FR-5).
//
// Per docs/design_decisions.md D1: for LINK_MODE=1 (UDP, the only mode
// implemented so far -- D3), the vendored MAC's udp_rx.v has already
// verified EtherType/IPv4/UDP framing and the IPv4 header checksum before
// eth_mac_if.v ever asserts anything -- FR-2/FR-3's EtherType/IHL/port
// checks are therefore not re-implemented here. This module's only job is
// FR-5: reject a payload whose length is not a whole, in-range number of
// 16-byte messages (S4.4), *before* forwarding a single byte of it, so a
// bad frame is discarded whole rather than partially parsed.
//
// This needs no internal buffering because eth_mac_if.v's `frame_start`/
// `rx_len` (docs/design_decisions.md D11) tell us the frame's declared
// length one cycle before its first byte (if any) would arrive, and hold
// it stable for the frame's entire duration -- so the whole gate is
// combinational, no FSM, no FIFO (satisfies NFR-11/NFR-12 by construction
// rather than by discipline). `err_frame_len` is a one-cycle pulse on
// `frame_start` for a rejected frame -- frame_start itself only ever
// pulses once per frame, so no counter or state is needed to keep it to a
// single pulse even when the bad frame streams many bytes behind it.
//
// LINK_MODE=0 (raw Ethernet, EtherType 0x88B5) is deferred per D3 and not
// implemented here; adding it means this module gaining its own
// EtherType/length-field parse ahead of udp_rx.v's simplification.
//
// Verilog-2001 only.

module frame_classifier #(
    parameter integer MAX_FRAME_BYTES = 1408   // 88 * 16, FR-4's message-count limit
) (
    input  wire        clk,
    input  wire        rst_n,   // active-low, async-assert/sync-deassert

    // from eth_mac_if.v
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire        frame_start,
    input  wire [15:0] rx_len,

    // to md_parser.v
    output wire [7:0]  out_data,
    output wire        out_valid,

    // status (FR-5) -- one-cycle pulse per discarded frame, incl. zero-length
    output wire        err_frame_len
);

    // FR-4/FR-5: length must be nonzero, a whole multiple of 16 bytes, and
    // no more than 88 messages' worth.
    wire frame_ok = (rx_len != 16'd0) &&
                    (rx_len[3:0] == 4'b0000) &&
                    (rx_len <= MAX_FRAME_BYTES[15:0]);

    // rx_len is guaranteed stable for the frame's whole duration (D11), so
    // gating every cycle straight off it is safe -- recomputing the
    // already-made decision is identical to latching it, minus the state.
    assign out_data      = rx_data;
    assign out_valid     = rx_valid & frame_ok;
    assign err_frame_len = frame_start & ~frame_ok;

endmodule
