`timescale 1ns / 1ps

// Self-checking testbench for eth_mac_if.v's TX side, against the REAL
// vendored rtl/vendor/alinx_mac/mac_top.v (not a hand-modeled mock) --
// this is where the actual protocol-timing risk lives: udp_tx.v computes
// the UDP checksum live off ram_wr_data/ram_wr_en at exact cycle offsets
// from udp_tx_req, and getting that wrong silently corrupts every
// outgoing order's checksum. See rtl/eth_mac_if.v's header comment and
// docs/design_decisions.md for the derivation this checks.
//
// Captures the actual transmitted wire bytes (mac_tx_data, gated by
// mac_data_valid) and checks:
//   - frame length matches preamble(8) + L2 header(14) + IPv4 header(20)
//     + UDP header(8) + payload(16) = 66 bytes (mac_tx.v appends the CRC
//     separately after mac_data_valid drops -- not checked here, that's
//     entirely mac_tx.v's own crc.v engine, nothing this adapter touches)
//   - the payload bytes at the expected offset match tx_payload exactly
//   - the UDP checksum bytes at the expected offset match an
//     independently-computed RFC 768 checksum over the same
//     pseudo-header + UDP header + payload
//
// Requires tb/sim_models/xilinx_ip_sim_models.v (no real IP simulation
// model is available locally -- see that file's header comment).
//
// Verilog-2001 only.

module tb_eth_mac_if_tx;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg rst_n = 1'b0;

    // ---- fixed frame configuration for this test ----
    localparam [47:0] SRC_MAC   = 48'h00_0a_35_01_02_03;
    localparam [7:0]  TTL       = 8'd64;
    localparam [31:0] SRC_IP    = {8'd192, 8'd168, 8'd1, 8'd10};
    localparam [31:0] DST_IP    = {8'd192, 8'd168, 8'd1, 8'd100};
    localparam [15:0] SRC_PORT  = 16'd60000;
    localparam [15:0] DST_PORT  = 16'd60000;
    localparam integer PAYLOAD_BYTES = 16;

    // ---- eth_mac_if <-> mac_top wiring ----
    wire [7:0]  ram_wr_data;
    wire        ram_wr_en;
    wire        udp_ram_data_req;
    wire [15:0] udp_send_data_length;
    wire        udp_tx_end;
    wire        almost_full;
    wire        udp_tx_req;
    wire        mac_data_valid;
    wire        mac_send_end;
    wire [7:0]  mac_tx_data;

    wire [7:0]  rx_data_unused;
    wire        rx_valid_unused, rx_last_unused;
    wire        tx_busy;

    reg  [8*PAYLOAD_BYTES-1:0] tx_payload;
    reg                        tx_start;

    eth_mac_if #(.PAYLOAD_BYTES(PAYLOAD_BYTES)) dut_if (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .rx_data               (rx_data_unused),
        .rx_valid              (rx_valid_unused),
        .rx_last               (rx_last_unused),
        .tx_payload            (tx_payload),
        .tx_start              (tx_start),
        .tx_busy               (tx_busy),
        .udp_rec_ram_rdata     (8'd0),
        .udp_rec_ram_read_addr (),
        .udp_rec_data_length   (16'd0),
        .udp_rec_data_valid    (1'b0),
        .ram_wr_data           (ram_wr_data),
        .ram_wr_en             (ram_wr_en),
        .almost_full           (almost_full),
        .udp_send_data_length  (udp_send_data_length),
        .udp_tx_req            (udp_tx_req),
        .mac_send_end          (mac_send_end)
    );

    mac_top dut_mac (
        .gmii_tx_clk                (clk),
        .gmii_rx_clk                (clk),
        .rst_n                      (rst_n),

        .source_mac_addr            (SRC_MAC),
        .TTL                        (TTL),
        .source_ip_addr             (SRC_IP),
        .destination_ip_addr        (DST_IP),
        .udp_send_source_port       (SRC_PORT),
        .udp_send_destination_port  (DST_PORT),

        .ram_wr_data                (ram_wr_data),
        .ram_wr_en                  (ram_wr_en),
        .udp_ram_data_req           (udp_ram_data_req),
        .udp_send_data_length       (udp_send_data_length),
        .udp_tx_end                 (udp_tx_end),
        .almost_full                (almost_full),

        .udp_tx_req                 (udp_tx_req),
        .arp_request_req            (1'b0),
        .mac_data_valid             (mac_data_valid),
        .mac_send_end               (mac_send_end),
        .mac_tx_data                (mac_tx_data),

        .rx_dv                      (1'b0),
        .mac_rx_datain              (8'd0),
        .udp_rec_ram_rdata          (),
        .udp_rec_ram_read_addr      (11'd0),
        .udp_rec_data_length        (),
        .udp_rec_data_valid         (),

        .arp_found                  (),
        .mac_not_exist              (),
        .mac_rec_error              (),
        .udp_checksum_error         ()
    );

    reg fail = 1'b0;

    // -----------------------------------------------------------------
    // Capture the wire stream
    // -----------------------------------------------------------------
    reg [7:0] wire_bytes [0:255];
    integer   wire_cnt;

    always @(posedge clk) begin
        if (mac_data_valid) begin
            wire_bytes[wire_cnt] <= mac_tx_data;
            wire_cnt <= wire_cnt + 1;
        end
    end

    // -----------------------------------------------------------------
    // Independent RFC 768 UDP checksum over the pseudo-header + UDP
    // header + payload, computed from the same fixed config above plus
    // whatever payload the test loads -- entirely independent of
    // rtl/eth_mac_if.v and rtl/vendor/alinx_mac/tx/udp_tx.v.
    // -----------------------------------------------------------------
    function [15:0] fold_carries;
        input [31:0] sum32;
        reg   [31:0] s;
        begin
            s = sum32;
            while (s[31:16] != 16'd0)
                s = s[15:0] + s[31:16];
            fold_carries = s[15:0];
        end
    endfunction

    // payload_packed: byte 0 in the MSBs, same convention as tx_payload.
    function [15:0] expected_udp_checksum;
        input [8*PAYLOAD_BYTES-1:0] payload_packed;
        reg [31:0] sum;
        integer    i;
        reg [15:0] udp_len;
        reg [7:0]  byte_i, byte_i1;
        begin
            udp_len = 16'd8 + PAYLOAD_BYTES;
            sum = 32'd0;
            sum = sum + SRC_IP[31:16] + SRC_IP[15:0];
            sum = sum + DST_IP[31:16] + DST_IP[15:0];
            sum = sum + 16'd17;              // protocol = UDP
            sum = sum + udp_len;             // UDP length (pseudo-header copy)
            sum = sum + SRC_PORT;
            sum = sum + DST_PORT;
            sum = sum + udp_len;             // UDP length (real header field)
            sum = sum + 16'd0;               // checksum field itself = 0 while computing
            for (i = 0; i < PAYLOAD_BYTES; i = i + 2) begin
                byte_i  = payload_packed[8*(PAYLOAD_BYTES-i)-1 -: 8];
                byte_i1 = payload_packed[8*(PAYLOAD_BYTES-i-1)-1 -: 8];
                sum = sum + {byte_i, byte_i1};
            end
            expected_udp_checksum = ~fold_carries(sum);
        end
    endfunction

    // -----------------------------------------------------------------
    // Test
    // -----------------------------------------------------------------
    localparam integer PREAMBLE_LEN = 8;
    localparam integer L2_HDR_LEN   = 14;
    localparam integer IP_HDR_LEN   = 20;
    localparam integer UDP_HDR_LEN  = 8;
    localparam integer PAYLOAD_OFFSET = PREAMBLE_LEN + L2_HDR_LEN + IP_HDR_LEN + UDP_HDR_LEN;
    localparam integer CHECKSUM_OFFSET = PAYLOAD_OFFSET - 2;
    // rtl/vendor/alinx_mac/tx/udp_tx.v pads UDP content below 26 bytes up
    // to 26 (Ethernet minimum-frame-size padding -- standard and benign;
    // the UDP header's own length field still correctly says 8+PAYLOAD_BYTES,
    // so a real receiver never sees the padding). Found by this testbench
    // failing on frame length alone -- the checksum/payload position
    // checks below are unaffected since padding trails the payload.
    localparam integer UDP_CONTENT_LEN = UDP_HDR_LEN + PAYLOAD_BYTES;
    localparam integer PADDED_UDP_LEN  = (UDP_CONTENT_LEN < 26) ? 26 : UDP_CONTENT_LEN;
    localparam integer EXPECTED_FRAME_LEN =
        PREAMBLE_LEN + L2_HDR_LEN + IP_HDR_LEN + PADDED_UDP_LEN;

    reg [7:0] payload_arr [0:PAYLOAD_BYTES-1];
    reg [15:0] exp_csum;
    reg [15:0] got_csum;
    integer i;
    integer timeout;

    task run_one_test;
        input [7:0] fill_base;
        begin
            for (i = 0; i < PAYLOAD_BYTES; i = i + 1)
                payload_arr[i] = fill_base + i[7:0];

            tx_payload = 0;
            for (i = 0; i < PAYLOAD_BYTES; i = i + 1)
                tx_payload = tx_payload | ({120'd0, payload_arr[i]} << (8*(PAYLOAD_BYTES-1-i)));

            wire_cnt = 0;
            @(posedge clk); #1;
            tx_start = 1'b1;
            @(posedge clk); #1;
            tx_start = 1'b0;

            timeout = 0;
            while (tx_busy && timeout < 5000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (tx_busy) begin
                $display("FAIL: tx_busy never dropped (timeout)");
                fail = 1'b1;
            end
            // let mac_data_valid finish draining (CRC bytes etc.)
            repeat (20) @(posedge clk);

            if (wire_cnt !== EXPECTED_FRAME_LEN + 4) begin
                // + 4 CRC bytes, appended after the payload
                $display("FAIL: captured %0d wire bytes, expected %0d (payload+headers) + 4 (CRC)",
                          wire_cnt, EXPECTED_FRAME_LEN + 4);
                fail = 1'b1;
            end

            for (i = 0; i < PAYLOAD_BYTES; i = i + 1) begin
                if (wire_bytes[PAYLOAD_OFFSET + i] !== payload_arr[i]) begin
                    $display("FAIL: payload byte %0d on wire = %h, expected %h",
                              i, wire_bytes[PAYLOAD_OFFSET + i], payload_arr[i]);
                    fail = 1'b1;
                end
            end

            got_csum = {wire_bytes[CHECKSUM_OFFSET], wire_bytes[CHECKSUM_OFFSET+1]};
            exp_csum = expected_udp_checksum(tx_payload);
            if (got_csum !== exp_csum) begin
                $display("FAIL: UDP checksum on wire = %h, independently computed expected = %h",
                          got_csum, exp_csum);
                fail = 1'b1;
            end else begin
                $display("checksum OK for fill_base=%h: %h", fill_base, got_csum);
            end
        end
    endtask

    initial begin
        rst_n    = 1'b0;
        tx_start = 1'b0;
        #40;
        rst_n = 1'b1;
        #40;

        run_one_test(8'h00);

        // second frame back to back, different payload -- also exercises
        // tx_busy correctly dropping and the adapter being ready again
        run_one_test(8'h40);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
