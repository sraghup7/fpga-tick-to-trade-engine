`timescale 1ns / 1ps

// rtl/frame_classifier.v
//
// Frame-level accept/reject gate between eth_mac_if.v and md_parser.v
// (master spec S3.1 [C], FR-4/FR-5).
//
// Per docs/design_decisions.md D1: for LINK_MODE=1 (UDP, the only mode
// implemented so far -- D3), the vendored MAC's udp_rx.v has already
// verified EtherType/IPv4/UDP framing and the IPv4 header checksum before
// eth_mac_if.v ever asserts anything -- FR-2/FR-3's EtherType/IHL checks
// are therefore not re-implemented here. This module's jobs are FR-5
// (reject a payload whose length is not a whole, in-range number of 16-byte
// messages, S4.4) and FR-3's UDP-port match (reject a frame whose UDP
// destination port != cfg_udp_port), each *before* forwarding a single byte
// of the frame, so a bad frame is discarded whole rather than partially
// parsed. (EtherType mismatch is caught upstream in mac_rx.v, D49 FR-2 --
// a non-0x0800/0x0806 frame never reaches udp_rx at all; only the port
// match, which udp_rx genuinely never checks, lives here.)
//
// This needs no internal buffering because eth_mac_if.v's `frame_start`/
// `rx_len` (docs/design_decisions.md D11) tell us the frame's declared
// length one cycle before its first byte (if any) would arrive, and hold
// it stable for the frame's entire duration -- so the whole gate is
// combinational, no FSM, no FIFO (satisfies NFR-11/NFR-12 by construction
// rather than by discipline). `err_frame_len` / `err_udp_port` are
// one-cycle pulses on `frame_start` for a rejected frame -- frame_start
// itself only ever pulses once per frame, so no counter or state is needed
// to keep either to a single pulse even when the bad frame streams many
// bytes behind it.
//
// The UDP destination port (udp_rec_dest_port, exposed by mac_rx_top.v/
// mac_top.v, D49) is committed at the frame's REC_END -- the same point
// udp_rec_data_length is committed -- so it is stable from frame_start
// through the whole byte stream-out, exactly like rx_len. The compare
// against cfg_udp_port (csr_block.v register 0x40) is therefore safe to
// recompute combinationally every cycle, mirroring frame_ok's use of the
// stable rx_len.
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

    // FR-3: the receiving UDP destination port (from mac_top.v, D49) and
    // the configured port to accept (csr_block.v register 0x40).
    input  wire [15:0] udp_rec_dest_port,
    input  wire [15:0] cfg_udp_port,

    // to md_parser.v
    output wire [7:0]  out_data,
    output wire        out_valid,

    // status -- one-cycle pulse per discarded frame, incl. zero-length:
    // FR-5 length rejection, FR-3 port-mismatch rejection
    output wire        err_frame_len,
    output wire        err_udp_port
);

    // FR-4/FR-5: length must be nonzero, a whole multiple of 16 bytes, and
    // no more than 88 messages' worth.
    wire frame_ok = (rx_len != 16'd0) &&
                    (rx_len[3:0] == 4'b0000) &&
                    (rx_len <= MAX_FRAME_BYTES[15:0]);

    // FR-3: the UDP destination port must match cfg_udp_port. udp_rx.v's
    // dest-port exposure (D49) is stable for the whole frame (committed at
    // REC_END like udp_rec_data_length), so this is safe to recompute every
    // cycle exactly like frame_ok above.
    wire port_ok = (udp_rec_dest_port == cfg_udp_port);

    // rx_len/udp_rec_dest_port are guaranteed stable for the frame's whole
    // duration (D11 / D49), so gating every cycle straight off them is safe
    // -- recomputing the already-made decision is identical to latching it,
    // minus the state.
    assign out_data      = rx_data;
    assign out_valid     = rx_valid & frame_ok & port_ok;
    assign err_frame_len = frame_start & ~frame_ok;
    assign err_udp_port  = frame_start & ~port_ok;

endmodule
