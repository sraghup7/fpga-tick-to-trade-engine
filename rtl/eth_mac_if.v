`timescale 1ns / 1ps

// Adapts rtl/vendor/alinx_mac/mac_top.v's boundary -- a byte-push TX FIFO
// and a whole-frame-buffered RX RAM, neither AXI4-Stream nor GMII -- to a
// plain byte-stream on our side. See docs/design_decisions.md D1.
//
// RX: mac_top.v pulses udp_rec_data_valid once a complete, CRC/checksum-
// verified UDP payload is sitting in its internal RAM, and holds it high
// until the *next* frame's reception reaches its own tail end (comfortably
// longer than the read below takes). This module walks the RAM's read
// address on the rising edge of that pulse and re-presents the bytes as a
// one-cycle-registered stream (rx_data/rx_valid/rx_last) toward
// frame_classifier/md_parser.
//
// TX: mac_top.v's TX side does NOT accept a simple byte stream. Pushing a
// byte on ram_wr_data/ram_wr_en also feeds a live UDP-checksum computation
// inside udp_tx.v that is keyed to exact cycle offsets from when udp_tx_req
// is asserted -- get that timing wrong and every outgoing order carries a
// corrupt UDP checksum, silently dropped by the host's network stack. To
// keep that timing-criticality from leaking into order_builder.v, this
// module buffers one fixed-size payload (tx_payload, all bits presented at
// once) and paces it out on ram_wr_data/ram_wr_en/udp_tx_req itself, at the
// exact offset this module was verified against the real vendored
// mac_top.v/udp_tx.v for (see tb/tb_eth_mac_if.v) -- TX_HEADER_DELAY below.
// order_builder only ever sees tx_payload/tx_start/tx_busy: present the
// payload, pulse tx_start, wait for tx_busy to drop.
//
// Verilog-2001 only.

module eth_mac_if #(
    parameter PAYLOAD_BYTES = 16   // fixed order-record size, master spec §4.5
) (
    input  wire clk,    // gmii_rx_clk domain -- the engine's single system clock (D2)
    input  wire rst_n,

    // ---------------------------------------------------------------
    // RX: byte stream out, toward frame_classifier/md_parser
    // ---------------------------------------------------------------
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    output reg        rx_last,   // high on the cycle rx_data carries the final byte

    // ---------------------------------------------------------------
    // TX: fixed-size payload in, from order_builder
    // ---------------------------------------------------------------
    input  wire [8*PAYLOAD_BYTES-1:0] tx_payload,  // byte 0 in the MSBs, byte N-1 in the LSBs
    input  wire                       tx_start,    // one-shot pulse; ignored while tx_busy
    output wire                       tx_busy,      // high from tx_start until mac_send_end

    // ---------------------------------------------------------------
    // mac_top.v RX boundary
    // ---------------------------------------------------------------
    input  wire [7:0]  udp_rec_ram_rdata,
    output reg  [10:0] udp_rec_ram_read_addr,
    input  wire [15:0] udp_rec_data_length,
    input  wire        udp_rec_data_valid,

    // ---------------------------------------------------------------
    // mac_top.v TX boundary
    // ---------------------------------------------------------------
    output reg  [7:0]  ram_wr_data,
    output reg         ram_wr_en,
    input  wire        almost_full,
    output reg  [15:0] udp_send_data_length,
    output reg         udp_tx_req,
    input  wire        mac_send_end
);

    // -----------------------------------------------------------------
    // RX: walk udp_rec_ram_read_addr once udp_rec_data_valid rises.
    //
    // Two-stage pipeline, kept as genuinely separate registers rather than
    // folded into one "issued this address, so output next cycle" flag
    // (a same-cycle version of that got the final byte's timing wrong --
    // caught by tb_eth_mac_if_rx.v):
    //   stage 1 (address): addr_valid/udp_rec_ram_read_addr -- this cycle's
    //     address is being held on the RAM's read port.
    //   stage 2 (data): data_valid_d/addr_val_d -- unconditionally latches
    //     stage 1 one cycle later, which is exactly when the RAM's
    //     registered read (udp_rec_ram_rdata) reflects that address.
    // Stage 2 runs every cycle regardless of stage 1's branching, so the
    // final byte still drains correctly even though rx_reading itself
    // drops one cycle before that drain completes.
    // -----------------------------------------------------------------
    reg        valid_d;
    wire       valid_rise = udp_rec_data_valid & ~valid_d;

    reg [15:0] rx_len;
    reg        rx_reading;    // still have addresses left to present
    reg        addr_valid;    // stage 1: this cycle's address is meaningful
    reg        data_valid_d;  // stage 2: last cycle's address, data ready now
    reg [10:0] addr_val_d;    // stage 2: which address that was

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_d               <= 1'b0;
            rx_len                <= 16'd0;
            rx_reading            <= 1'b0;
            addr_valid            <= 1'b0;
            data_valid_d          <= 1'b0;
            addr_val_d            <= 11'd0;
            udp_rec_ram_read_addr <= 11'd0;
            rx_data               <= 8'd0;
            rx_valid              <= 1'b0;
            rx_last               <= 1'b0;
        end else begin
            valid_d <= udp_rec_data_valid;

            // Stage 2 (unconditional): mirrors stage 1 from last cycle.
            data_valid_d <= addr_valid;
            addr_val_d   <= udp_rec_ram_read_addr;
            rx_valid     <= data_valid_d;
            rx_data      <= udp_rec_ram_rdata;
            rx_last      <= data_valid_d && (addr_val_d == rx_len[10:0] - 11'd1);

            // Stage 1: address generation.
            if (valid_rise && !rx_reading && udp_rec_data_length != 16'd0) begin
                rx_len                <= udp_rec_data_length;
                rx_reading            <= 1'b1;
                udp_rec_ram_read_addr <= 11'd0;
                addr_valid            <= 1'b1;
            end else if (rx_reading) begin
                if (addr_valid && udp_rec_ram_read_addr == rx_len[10:0] - 11'd1) begin
                    // Just presented the final address -- nothing more to
                    // issue. Stage 2 above still drains it next cycle.
                    addr_valid <= 1'b0;
                end else if (!addr_valid) begin
                    // Final address's drain has happened; done.
                    rx_reading <= 1'b0;
                end else begin
                    udp_rec_ram_read_addr <= udp_rec_ram_read_addr + 11'd1;
                    addr_valid            <= 1'b1;
                end
            end else begin
                addr_valid <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------
    // TX: latch the payload, then pace it onto ram_wr_data/ram_wr_en in
    // lockstep with udp_tx_req per the timing derived from udp_tx.v's
    // checksum engine (verified against the real vendored RTL in
    // tb/tb_eth_mac_if.v, not just this derivation):
    //
    //   cycle T0     : udp_tx_req asserted (one cycle)
    //   cycle T0+1..T0+8 : idle (HEADER_CHECKSUM consumes these internally)
    //   cycle T0+9   : byte 0 on ram_wr_data, ram_wr_en high
    //   cycle T0+10..T0+9+PAYLOAD_BYTES-1 : byte 1..N-1, back to back
    //
    // Payload length is fixed (PAYLOAD_BYTES, always even) so only the
    // even-length GEN_CHECKSUM path in udp_tx.v is ever exercised.
    // -----------------------------------------------------------------
    localparam integer TX_HEADER_DELAY = 9;

    localparam [2:0] TX_IDLE  = 3'd0,
                      TX_REQ   = 3'd1,
                      TX_WAIT  = 3'd2,
                      TX_PUSH  = 3'd3,
                      TX_DRAIN = 3'd4;

    reg [2:0]  tx_state;
    reg [7:0]  payload_buf [0:PAYLOAD_BYTES-1];
    reg [3:0]  wait_cnt;
    reg [4:0]  push_idx;
    integer    k;

    assign tx_busy = (tx_state != TX_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state             <= TX_IDLE;
            udp_tx_req           <= 1'b0;
            udp_send_data_length <= 16'd0;
            ram_wr_data          <= 8'd0;
            ram_wr_en            <= 1'b0;
            wait_cnt             <= 4'd0;
            push_idx             <= 5'd0;
            for (k = 0; k < PAYLOAD_BYTES; k = k + 1)
                payload_buf[k] <= 8'd0;
        end else begin
            udp_tx_req <= 1'b0;
            ram_wr_en  <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    if (tx_start && !almost_full) begin
                        for (k = 0; k < PAYLOAD_BYTES; k = k + 1)
                            payload_buf[k] <= tx_payload[8*(PAYLOAD_BYTES-k)-1 -: 8];
                        udp_send_data_length <= PAYLOAD_BYTES[15:0];
                        udp_tx_req           <= 1'b1;
                        tx_state             <= TX_REQ;
                    end
                end
                TX_REQ: begin
                    wait_cnt <= 4'd1;
                    tx_state <= TX_WAIT;
                end
                TX_WAIT: begin
                    if (wait_cnt == TX_HEADER_DELAY - 1) begin
                        push_idx    <= 5'd0;
                        ram_wr_data <= payload_buf[0];
                        ram_wr_en   <= 1'b1;
                        tx_state    <= TX_PUSH;
                    end else begin
                        wait_cnt <= wait_cnt + 1'b1;
                    end
                end
                TX_PUSH: begin
                    if (push_idx == PAYLOAD_BYTES - 1) begin
                        tx_state <= TX_DRAIN;
                    end else begin
                        push_idx    <= push_idx + 1'b1;
                        ram_wr_data <= payload_buf[push_idx + 1'b1];
                        ram_wr_en   <= 1'b1;
                    end
                end
                TX_DRAIN: begin
                    if (mac_send_end)
                        tx_state <= TX_IDLE;
                end
                default: tx_state <= TX_IDLE;
            endcase
        end
    end

endmodule
