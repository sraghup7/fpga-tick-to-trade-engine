`timescale 1ns / 1ps

// Self-checking testbench for eth_mac_if.v's RX side only. Mocks
// mac_top.v's RX boundary directly (a registered-read RAM + a level
// udp_rec_data_valid that stays high across an inter-frame gap, per
// rtl/vendor/alinx_mac/rx/udp_rx.v's actual behavior) rather than driving
// the whole vendor MAC from raw GMII bytes -- this module's own
// address-walk FSM is what's under test here, not the vendor MAC's
// packet parsing (that's covered by tb_eth_mac_if_tx.v against the real
// vendored RTL, where the protocol-timing risk actually lives).
//
// Verilog-2001 only.

module tb_eth_mac_if_rx;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg rst_n = 1'b0;

    // ---- mocked mac_top.v RX boundary ----
    reg  [7:0]  mock_ram [0:2047];
    reg  [15:0] udp_rec_data_length = 16'd0;
    reg         udp_rec_data_valid  = 1'b0;
    wire [10:0] udp_rec_ram_read_addr;
    reg  [7:0]  udp_rec_ram_rdata;

    always @(posedge clk) udp_rec_ram_rdata <= mock_ram[udp_rec_ram_read_addr];

    // ---- unused TX side, tied off ----
    wire        tx_busy;

    wire [7:0]  rx_data;
    wire        rx_valid;
    wire        rx_last;
    wire        frame_start;
    wire [15:0] rx_len;

    eth_mac_if #(.PAYLOAD_BYTES(16)) dut (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .rx_data               (rx_data),
        .rx_valid              (rx_valid),
        .rx_last               (rx_last),
        .frame_start        (frame_start),
        .rx_len          (rx_len),
        .tx_payload            (128'd0),
        .tx_start              (1'b0),
        .tx_busy               (tx_busy),
        .udp_rec_ram_rdata     (udp_rec_ram_rdata),
        .udp_rec_ram_read_addr (udp_rec_ram_read_addr),
        .udp_rec_data_length   (udp_rec_data_length),
        .udp_rec_data_valid    (udp_rec_data_valid),
        .ram_wr_data           (),
        .ram_wr_en             (),
        .almost_full           (1'b0),
        .udp_send_data_length  (),
        .udp_tx_req            (),
        .mac_send_end          (1'b0)
    );

    reg fail = 1'b0;

    // ---- collector ----
    reg [7:0] got [0:255];
    integer   got_cnt;
    reg       last_seen;

    task collect_frame;
        input integer expect_len;
        integer timeout;
        begin
            got_cnt   = 0;
            last_seen = 0;
            timeout   = 0;
            while (!last_seen && timeout < 200) begin
                @(posedge clk);
                #1;
                if (rx_valid) begin
                    got[got_cnt] = rx_data;
                    got_cnt = got_cnt + 1;
                    if (rx_last) last_seen = 1'b1;
                end
                timeout = timeout + 1;
            end
            if (!last_seen) begin
                $display("FAIL: rx_last never seen within timeout (expected len %0d)", expect_len);
                fail = 1'b1;
            end
            if (got_cnt !== expect_len) begin
                $display("FAIL: got %0d bytes, expected %0d", got_cnt, expect_len);
                fail = 1'b1;
            end
        end
    endtask

    task check_payload;
        input integer len;
        input integer base;   // mock_ram[0] value; payload is base, base+1, ...
        integer i;
        begin
            for (i = 0; i < len; i = i + 1) begin
                if (got[i] !== ((base + i) & 8'hFF)) begin
                    $display("FAIL: byte %0d = %h, expected %h", i, got[i], (base + i) & 8'hFF);
                    fail = 1'b1;
                end
            end
        end
    endtask

    integer i;

    // Latches the most recent frame_start pulse's rx_len, plus a
    // count of how many times it's pulsed, for the checks below.
    reg [15:0] last_frame_len = 16'hFFFF;
    integer    frame_start_cnt = 0;
    always @(posedge clk) begin
        if (frame_start) begin
            last_frame_len  <= rx_len;
            frame_start_cnt <= frame_start_cnt + 1;
        end
    end

    initial begin
        rst_n = 1'b0;
        #20;
        rst_n = 1'b1;
        #20;

        // --- Frame 1: 16 bytes, values 0x00..0x0F ---
        for (i = 0; i < 16; i = i + 1) mock_ram[i] = i[7:0];
        udp_rec_data_length = 16'd16;
        @(posedge clk); #1;
        udp_rec_data_valid = 1'b1;   // rising edge -> starts the read

        collect_frame(16);
        check_payload(16, 0);
        if (frame_start_cnt !== 1 || last_frame_len !== 16'd16) begin
            $display("FAIL: frame 1 frame_start/rx_len: cnt=%0d len=%0d (expected 1/16)",
                     frame_start_cnt, last_frame_len);
            fail = 1'b1;
        end

        // udp_rec_data_valid stays high across the "inter-frame gap" here,
        // exactly like the real udp_rx.v -- must not re-trigger a second
        // read while it's still just sitting high.
        repeat (10) @(posedge clk);
        if (dut.rx_reading !== 1'b0) begin
            $display("FAIL: still reading after frame 1 completed, with valid held high");
            fail = 1'b1;
        end

        // --- Frame 2: drop valid, reload RAM with a different 32-byte
        //     payload, raise valid again (new rising edge) ---
        udp_rec_data_valid = 1'b0;
        @(posedge clk); #1;
        for (i = 0; i < 32; i = i + 1) mock_ram[i] = (8'hA0 + i);
        udp_rec_data_length = 16'd32;
        @(posedge clk); #1;
        udp_rec_data_valid = 1'b1;

        collect_frame(32);
        check_payload(32, 8'hA0);
        if (frame_start_cnt !== 2 || last_frame_len !== 16'd32) begin
            $display("FAIL: frame 2 frame_start/rx_len: cnt=%0d len=%0d (expected 2/32)",
                     frame_start_cnt, last_frame_len);
            fail = 1'b1;
        end

        // --- Frame 3: a genuinely empty (0-byte) UDP payload (T05, FR-5).
        //     No byte stream at all is expected -- rx_valid/rx_last must
        //     never fire -- but frame_start must still pulse with
        //     rx_len=0, since that's the only way md_parser can ever
        //     learn this degenerate frame happened at all. ---
        udp_rec_data_valid = 1'b0;
        @(posedge clk); #1;
        udp_rec_data_length = 16'd0;
        @(posedge clk); #1;
        udp_rec_data_valid = 1'b1;

        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk); #1;
            if (rx_valid || rx_last) begin
                $display("FAIL: rx_valid/rx_last fired for a 0-byte frame at t=%0t", $time);
                fail = 1'b1;
            end
        end
        if (frame_start_cnt !== 3 || last_frame_len !== 16'd0) begin
            $display("FAIL: frame 3 (empty) frame_start/rx_len: cnt=%0d len=%0d (expected 3/0)",
                     frame_start_cnt, last_frame_len);
            fail = 1'b1;
        end

        udp_rec_data_valid = 1'b0;
        @(posedge clk);

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
