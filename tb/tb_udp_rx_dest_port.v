`timescale 1ns / 1ps

// Self-checking testbench for udp_rx.v's FR-3 destination-port exposure
// (docs/contracts/fr3_udp_port_match.md S1 / D49). Drives udp_rx.v directly
// with a hand-encoded UDP datagram and asserts udp_rec_dest_port holds the
// exact destination port at/after udp_rec_data_valid.
//
// Byte-alignment basis (the one thing most likely to be silently wrong, and
// the whole point of this test): the UDP header byte stream is presented one
// byte per udp_rx_cnt step, with UDP header byte N on udp_rx_data when
// udp_rx_cnt == N -- the same alignment udp_rx's OWN checksum accumulator
// relies on ({udp_rx_data_d0, udp_rx_data} at odd udp_rx_cnt forms exactly
// the {src, dst, len, cksum} 16-bit header words, in RFC 768 order). This
// was confirmed against the real mac_rx -> ip_rx -> udp_rx chain (not just
// derived): a frame whose UDP header bytes 2-3 are 0xEA,0x60 (= 60000) makes
// udp_rec_dest_port read 0xEA60 only if the capture indexes byte 2 at
// udp_rx_cnt==2 and byte 3 at udp_rx_cnt==3. A frame with a DIFFERENT known
// dest port (0x6001 = 24577) is used for the value check so a test that
// merely matches whatever port the implementation happens to capture can't
// pass.
//
// The datagram carries a correct UDP checksum (0x8E75 for the pseudo-header
// src 192.168.1.10 / dst 192.168.1.10 / proto 17 / len 12 and the 4-byte
// payload below -- recomputed by hand, not by the model) so the FSM reaches
// VERIFY_CHECKSUM -> REC_END_WAIT -> REC_END and udp_rec_data_valid pulses;
// udp_rec_dest_port is committed at REC_END, exactly like
// udp_rec_data_length, so it is stable when udp_rec_data_valid is sampled.
//
// Verilog-2001 only.

module tb_udp_rx_dest_port;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg rst_n = 1'b0;

    // ---- udp_rx.v inputs (the ip_rx.v-shaped boundary) ----
    reg [7:0]  udp_rx_data = 8'd0;
    reg        udp_rx_req  = 1'b0;
    reg        mac_rec_error = 1'b0;
    reg [7:0]  net_protocol = 8'h11;
    reg [31:0] ip_rec_source_addr = 32'hC0A8010A;       // 192.168.1.10
    reg [31:0] ip_rec_destination_addr = 32'hC0A8010A;  // 192.168.1.10
    reg        ip_checksum_error = 1'b0;
    reg        ip_addr_check_error = 1'b0;
    reg [15:0] upper_layer_data_length = 16'd12;        // UDP header 8 + payload 4

    wire [7:0]  udp_rec_ram_rdata;
    reg  [10:0] udp_rec_ram_read_addr = 11'd0;
    wire [15:0] udp_rec_data_length;
    wire        udp_rec_data_valid;
    wire [15:0] udp_rec_dest_port;
    wire        udp_checksum_error;

    udp_rx dut (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .udp_rx_data              (udp_rx_data),
        .udp_rx_req               (udp_rx_req),
        .mac_rec_error            (mac_rec_error),
        .net_protocol             (net_protocol),
        .ip_rec_source_addr       (ip_rec_source_addr),
        .ip_rec_destination_addr  (ip_rec_destination_addr),
        .ip_checksum_error        (ip_checksum_error),
        .ip_addr_check_error      (ip_addr_check_error),
        .upper_layer_data_length  (upper_layer_data_length),
        .udp_rec_ram_rdata        (udp_rec_ram_rdata),
        .udp_rec_ram_read_addr    (udp_rec_ram_read_addr),
        .udp_rec_data_length      (udp_rec_data_length),
        .udp_rec_data_valid       (udp_rec_data_valid),
        .udp_rec_dest_port        (udp_rec_dest_port),
        .udp_checksum_error       (udp_checksum_error)
    );

    reg fail = 1'b0;

    // ---- drive one UDP datagram: 8 header bytes + 4 payload bytes ----
    // hdr[0..7]: src(2) dst(2) len(2) cksum(2), RFC 768 order.
    task send_datagram;
        input [15:0] dst_port;
        input [15:0] udp_cksum;   // hand-computed for this dst (see below)
        reg [7:0] hdr [0:11];
        integer i;
        begin
            hdr[0] = 8'h12; hdr[1] = 8'h34;                       // src port 0x1234
            hdr[2] = dst_port[15:8]; hdr[3] = dst_port[7:0];      // dst port (test arg)
            hdr[4] = 8'h00; hdr[5] = 8'h0c;                       // udp length = 12
            hdr[6] = udp_cksum[15:8]; hdr[7] = udp_cksum[7:0];    // udp checksum (hand-computed)
            hdr[8] = 8'ha5; hdr[9] = 8'h5a; hdr[10] = 8'ha5; hdr[11] = 8'h5a;  // payload

            // udp_rx_req is high during the cycle the last IP-header byte is
            // on the bus (the ip_rx.v handshake); REC_HEAD / udp_rx_cnt begin
            // the cycle UDP header byte 0 arrives.
            @(negedge clk);
            udp_rx_req = 1'b1;  udp_rx_data = 8'hFF;   // dummy "last IP byte"
            @(posedge clk); #1;
            udp_rx_req = 1'b0;
            for (i = 0; i < 12; i = i + 1) begin
                @(negedge clk);
                udp_rx_data = hdr[i];
                @(posedge clk); #1;
            end
            @(negedge clk);
            udp_rx_data = 8'd0;
        end
    endtask

    // Wait for a udp_rec_data_valid pulse (FSM reached REC_END), then wait
    // for the module to return to IDLE before the caller sends the next
    // datagram (udp_rx_req is only looked at in IDLE).
    task wait_valid;
        integer tries;
        begin
            tries = 0;
            while (!udp_rec_data_valid && tries < 500) begin
                @(posedge clk);
                tries = tries + 1;
            end
            @(posedge clk); #1;   // let the commit settle one more edge
            tries = 0;
            while (dut.state != 8'b0000_0001 && tries < 500) begin  // IDLE
                @(posedge clk);
                tries = tries + 1;
            end
            @(negedge clk);   // deassert so the next send_datagram starts clean
            udp_rx_data = 8'd0;
            udp_rx_req  = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    integer i;

    initial begin
        rst_n = 1'b0;
        #20;
        rst_n = 1'b1;
        #20;

        // ---- Case 1: dest port 60000 (0xEA60) -- the cfg default ----
        // UDP checksum 0x3527 for pseudo-header src=192.168.1.10 /
        // dst=192.168.1.10 / proto 17 / len 12 and payload a5 5a a5 5a,
        // hand-computed independently of the RTL.
        send_datagram(16'd60000, 16'h3527);
        wait_valid;
        if (!udp_rec_data_valid) begin
            $display("FAIL: case 60000: udp_rec_data_valid never pulsed");
            fail = 1'b1;
        end
        if (udp_rec_dest_port !== 16'd60000) begin
            $display("FAIL: case 60000: udp_rec_dest_port=%04x, expected ea60", udp_rec_dest_port);
            fail = 1'b1;
        end

        // ---- Case 2: a DIFFERENT, hand-picked dest port 24577 (0x6001) --
        //      proves the capture is byte-exact and not, say, always
        //      returning 60000 or a swapped/off-by-one version of the bytes.
        //      UDP checksum 0xBF86 recomputed for this dst port (same
        //      pseudo-header/payload as case 1).
        send_datagram(16'd24577, 16'hBF86);
        wait_valid;
        if (!udp_rec_data_valid) begin
            $display("FAIL: case 24577: udp_rec_data_valid never pulsed");
            fail = 1'b1;
        end
        if (udp_rec_dest_port !== 16'd24577) begin
            $display("FAIL: case 24577: udp_rec_dest_port=%04x, expected 6001", udp_rec_dest_port);
            fail = 1'b1;
        end

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
