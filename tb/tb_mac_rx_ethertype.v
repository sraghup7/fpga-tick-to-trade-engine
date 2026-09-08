`timescale 1ns / 1ps

// Self-checking testbench for mac_rx.v's FR-2 err_ethertype pulse
// (docs/contracts/fr3_udp_port_match.md S5 / D49). Drives mac_rx.v directly
// at the GMII byte level and asserts err_ethertype pulses exactly once for a
// frame whose EtherType is neither 0x0800 (IPv4) nor 0x0806 (ARP), and stays
// quiet for an IP frame (which instead asserts ip_rx_req).
//
// mac_rx's frame_type is captured during REC_MAC_HEAD from the 2 bytes after
// the 12-byte MAC addresses (the EtherType field), and the dispatch decision
// is made in REC_IDENTIFY -- the same point ip_rx_req/arp_rx_req are
// generated. err_ethertype is the mirror of those (D49): one cycle high
// when rec_state == REC_IDENTIFY and frame_type is neither 0x0800 nor
// 0x0806. Such frames still go to REC_ERROR (mac_rec_error pulses, the
// frame is dropped) exactly as before -- this test only confirms the new
// pulse fires and the IP path is unaffected.
//
// Verilog-2001 only.

module tb_mac_rx_ethertype;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg        rx_dv = 1'b0;
    reg [7:0]  mac_rx_datain = 8'd0;

    // mac_rx needs a crc_result input; tied to 0 since no valid CRC is
    // required to reach REC_IDENTIFY (the dispatch decision happens before
    // the frame body / CRC are even received).
    reg [31:0] crc_result = 32'd0;
    reg        checksum_err = 1'b0;
    reg        ip_rx_end = 1'b0;
    reg        arp_rx_end = 1'b0;

    wire       ip_rx_req;
    wire       arp_rx_req;
    wire       err_ethertype;
    wire       mac_rec_error;

    mac_rx dut (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .rx_dv                    (rx_dv),
        .mac_rx_datain            (mac_rx_datain),
        .crc_result               (crc_result),
        .crcen                    (),
        .crcre                    (),
        .crc_din                  (),
        .checksum_err             (checksum_err),
        .ip_rx_end                (ip_rx_end),
        .arp_rx_end               (arp_rx_end),
        .ip_rx_req                (ip_rx_req),
        .arp_rx_req               (arp_rx_req),
        .mac_rx_dataout           (),
        .mac_rec_error            (mac_rec_error),
        .mac_rx_destination_mac_addr (),
        .mac_rx_source_mac_addr   (),
        .err_ethertype            (err_ethertype)
    );

    reg fail = 1'b0;
    integer err_ether_pulses;
    integer ip_req_pulses;

    always @(posedge clk) begin
        if (err_ethertype) err_ether_pulses = err_ether_pulses + 1;
        if (ip_rx_req)     ip_req_pulses = ip_req_pulses + 1;
    end

    // Feed a complete MAC header (preamble 8B + dst 6B + src 6B + ethertype
    // 2B), then enough body bytes to reach and pass REC_IDENTIFY.
    task send_header;
        input [15:0] ethertype;
        integer i;
        begin
            @(negedge clk); rx_dv = 1'b1;
            for (i = 0; i < 8; i = i + 1) begin
                mac_rx_datain = (i < 7) ? 8'h55 : 8'hd5;   // preamble + SFD
                @(posedge clk); #1;
            end
            for (i = 0; i < 6; i = i + 1) begin
                mac_rx_datain = 8'h00;                     // dst MAC
                @(posedge clk); #1;
            end
            for (i = 0; i < 6; i = i + 1) begin
                mac_rx_datain = 8'h11;                     // src MAC
                @(posedge clk); #1;
            end
            mac_rx_datain = ethertype[15:8]; @(posedge clk); #1;
            mac_rx_datain = ethertype[7:0];  @(posedge clk); #1;
            // a few body bytes so REC_DATA/REC_ERROR is entered and the
            // REC_IDENTIFY decision (and our pulse) is observed
            for (i = 0; i < 8; i = i + 1) begin
                mac_rx_datain = 8'hAA;
                @(posedge clk); #1;
            end
            @(negedge clk); rx_dv = 1'b0; mac_rx_datain = 8'd0;
            // let the FSM settle back through REC_ERROR/REC_END to IDLE
            repeat (30) @(posedge clk);
            #1;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        #20;
        rst_n = 1'b1;
        #20;

        // ---- bad EtherType 0x88B5: err_ethertype pulses once, no ip/arp req
        err_ether_pulses = 0; ip_req_pulses = 0;
        send_header(16'h88B5);
        if (err_ether_pulses !== 1) begin
            $display("FAIL: 0x88B5 err_ethertype pulsed %0d times, expected 1", err_ether_pulses);
            fail = 1'b1;
        end
        if (ip_req_pulses !== 0) begin
            $display("FAIL: 0x88B5 ip_rx_req pulsed %0d times, expected 0", ip_req_pulses);
            fail = 1'b1;
        end

        // ---- IPv4 0x0800: NO err_ethertype, ip_rx_req pulses ----
        err_ether_pulses = 0; ip_req_pulses = 0;
        send_header(16'h0800);
        if (err_ether_pulses !== 0) begin
            $display("FAIL: 0x0800 err_ethertype pulsed %0d times, expected 0", err_ether_pulses);
            fail = 1'b1;
        end
        if (ip_req_pulses !== 1) begin
            $display("FAIL: 0x0800 ip_rx_req pulsed %0d times, expected 1", ip_req_pulses);
            fail = 1'b1;
        end

        // ---- ARP 0x0806: NO err_ethertype (not counted as a frame error) ----
        err_ether_pulses = 0; ip_req_pulses = 0;
        send_header(16'h0806);
        if (err_ether_pulses !== 0) begin
            $display("FAIL: 0x0806 err_ethertype pulsed %0d times, expected 0", err_ether_pulses);
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
