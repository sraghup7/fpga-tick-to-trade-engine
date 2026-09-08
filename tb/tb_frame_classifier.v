`timescale 1ns / 1ps

// Self-checking testbench for rtl/frame_classifier.v.
//
// Icarus:
//   iverilog -g2001 -Wall -o frame_classifier_tb.vvp rtl/frame_classifier.v tb/tb_frame_classifier.v
//   vvp frame_classifier_tb.vvp
//
// Directed tests (master spec S11.4):
//   T01 (FR-1,4)  one 16-byte frame passes through untouched
//   T02 (FR-4,6)  one 1408-byte (88-message) frame passes through untouched
//   T05 (FR-5)    payload lengths 17, 15, 0 are each discarded whole, with
//                 err_frame_len pulsing exactly once per bad frame and the
//                 very next good frame still parsing cleanly ("clean
//                 recovery" / "parser returns to idle before next frame")
//   plus an FR-4 upper-bound case: 1424 bytes (89*16, a clean multiple of
//   16 but over the 88-message limit) is also discarded.
//   T-FR3 (FR-3)  a frame whose UDP destination port != cfg_udp_port is
//                 discarded whole (err_udp_port pulses exactly once, no byte
//                 reaches out_data/out_valid), and the next frame on the
//                 CONFIGURED port passes through unchanged (clean recovery).
//                 The port-match gate is combinational off udp_rec_dest_port
//                 (stable for the whole frame, like rx_len), so a mismatched
//                 frame streams zero bytes even though rx_valid carries bytes.
//
// Drives rx_data/rx_valid/frame_start/rx_len/udp_rec_dest_port/cfg_udp_port
// directly -- the same eth_mac_if-shaped boundary tb_eth_mac_if_rx.v mocks,
// plus the FR-3 port inputs -- rather than instantiating eth_mac_if itself,
// since frame_classifier's contract with its producer is exactly these
// signals (docs/design_decisions.md D11; the UDP dest port is carried
// mac_top -> frame_classifier at tob_top, D49 FR-3).
//
// A rejected frame still streams its declared number of bytes on
// rx_valid/rx_data (a frame can be "bad length" and still have real bytes
// behind it); the check is that ZERO of them reach out_data/out_valid and
// err_frame_len / err_udp_port pulse exactly once, timed off frame_start --
// which is also what makes a zero-length frame's rejection observable at all.
//
// Verilog-2001 only.

module tb_frame_classifier;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg [7:0]  rx_data = 8'd0;
    reg        rx_valid = 1'b0;
    reg        frame_start = 1'b0;
    reg [15:0] rx_len = 16'd0;
    reg [15:0] udp_rec_dest_port = 16'd0;   // D49 (FR-3)
    reg [15:0] cfg_udp_port = 16'd0;        // D49 (FR-3)

    wire [7:0] out_data;
    wire       out_valid;
    wire       err_frame_len;
    wire       err_udp_port;

    frame_classifier dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .rx_data           (rx_data),
        .rx_valid          (rx_valid),
        .frame_start       (frame_start),
        .rx_len            (rx_len),
        .udp_rec_dest_port (udp_rec_dest_port),
        .cfg_udp_port      (cfg_udp_port),
        .out_data          (out_data),
        .out_valid         (out_valid),
        .err_frame_len     (err_frame_len),
        .err_udp_port      (err_udp_port)
    );

    reg fail = 1'b0;

    // ---- collectors ----
    reg [7:0] got [0:1599];
    integer   got_cnt;
    integer   err_pulses;
    integer   udp_err_pulses;

    // Count err_frame_len / err_udp_port pulses continuously (independent of
    // the tasks below, so a pulse mid-task is never missed).
    always @(posedge clk) begin
        if (err_frame_len) err_pulses = err_pulses + 1;
        if (err_udp_port)  udp_err_pulses = udp_err_pulses + 1;
    end

    // Present one frame: pulse frame_start/rx_len for one cycle, then (if
    // n_bytes > 0) stream n_bytes back-to-back on rx_valid/rx_data, values
    // base, base+1, base+2, ... wrapping mod 256. Collects whatever
    // out_valid actually produces into `got`/`got_cnt`.
    task send_frame;
        input [15:0] declared_len;   // what rx_len claims (may be a lie, for T05)
        input integer n_bytes;       // how many bytes actually stream
        input [7:0]  base;
        integer i;
        begin
            got_cnt = 0;
            @(negedge clk);
            frame_start = 1'b1;
            rx_len      = declared_len;
            @(posedge clk);
            #1;
            frame_start = 1'b0;
            for (i = 0; i < n_bytes; i = i + 1) begin
                @(negedge clk);
                rx_valid = 1'b1;
                rx_data  = ((base + i) & 8'hFF);
                @(posedge clk);
                #1;
                if (out_valid) begin
                    got[got_cnt] = out_data;
                    got_cnt = got_cnt + 1;
                end
            end
            @(negedge clk);
            rx_valid = 1'b0;
            @(posedge clk);
            #1;
            if (out_valid) begin
                got[got_cnt] = out_data;
                got_cnt = got_cnt + 1;
            end
        end
    endtask

    task check_passthrough;
        input integer expect_len;
        input [7:0] base;
        integer i;
        begin
            if (got_cnt !== expect_len) begin
                $display("FAIL: got_cnt=%0d, expected %0d", got_cnt, expect_len);
                fail = 1'b1;
            end
            for (i = 0; i < expect_len && i < got_cnt; i = i + 1) begin
                if (got[i] !== ((base + i) & 8'hFF)) begin
                    $display("FAIL: byte %0d = %h, expected %h", i, got[i], (base + i) & 8'hFF);
                    fail = 1'b1;
                end
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        #20;
        rst_n = 1'b1;
        #20;
        // FR-3 baseline: configured port 60000, matching every frame below
        // unless a specific case changes udp_rec_dest_port.
        cfg_udp_port = 16'd60000;
        udp_rec_dest_port = 16'd60000;

        // ---- T01: one 16-byte frame, passes through untouched ----
        err_pulses = 0;
        send_frame(16'd16, 16, 8'h00);
        check_passthrough(16, 8'h00);
        if (err_pulses !== 0) begin
            $display("FAIL: T01 err_frame_len pulsed %0d times, expected 0", err_pulses);
            fail = 1'b1;
        end

        // ---- T02: one 1408-byte (88-message) frame, passes through untouched ----
        err_pulses = 0;
        send_frame(16'd1408, 1408, 8'h10);
        check_passthrough(1408, 8'h10);
        if (err_pulses !== 0) begin
            $display("FAIL: T02 err_frame_len pulsed %0d times, expected 0", err_pulses);
            fail = 1'b1;
        end

        // ---- T05: bad length 17 -- entirely discarded ----
        err_pulses = 0;
        send_frame(16'd17, 17, 8'h20);
        if (got_cnt !== 0) begin
            $display("FAIL: len=17 forwarded %0d bytes, expected 0", got_cnt);
            fail = 1'b1;
        end
        if (err_pulses !== 1) begin
            $display("FAIL: len=17 err_frame_len pulsed %0d times, expected 1", err_pulses);
            fail = 1'b1;
        end

        // ---- T05: bad length 15 -- entirely discarded ----
        err_pulses = 0;
        send_frame(16'd15, 15, 8'h40);
        if (got_cnt !== 0) begin
            $display("FAIL: len=15 forwarded %0d bytes, expected 0", got_cnt);
            fail = 1'b1;
        end
        if (err_pulses !== 1) begin
            $display("FAIL: len=15 err_frame_len pulsed %0d times, expected 1", err_pulses);
            fail = 1'b1;
        end

        // ---- T05: bad length 0 -- no bytes ever stream; still counted ----
        err_pulses = 0;
        send_frame(16'd0, 0, 8'h00);
        if (got_cnt !== 0) begin
            $display("FAIL: len=0 forwarded %0d bytes, expected 0", got_cnt);
            fail = 1'b1;
        end
        if (err_pulses !== 1) begin
            $display("FAIL: len=0 err_frame_len pulsed %0d times, expected 1", err_pulses);
            fail = 1'b1;
        end

        // ---- FR-4 upper bound: 1424 = 89*16, a clean multiple of 16 but
        //      one message over the 88-message limit -- also discarded ----
        err_pulses = 0;
        send_frame(16'd1424, 1424, 8'h60);
        if (got_cnt !== 0) begin
            $display("FAIL: len=1424 forwarded %0d bytes, expected 0", got_cnt);
            fail = 1'b1;
        end
        if (err_pulses !== 1) begin
            $display("FAIL: len=1424 err_frame_len pulsed %0d times, expected 1", err_pulses);
            fail = 1'b1;
        end

        // ---- clean recovery: next good frame still parses fine ----
        err_pulses = 0;
        send_frame(16'd16, 16, 8'h80);
        check_passthrough(16, 8'h80);
        if (err_pulses !== 0) begin
            $display("FAIL: post-bad-frame recovery: err_frame_len pulsed %0d times, expected 0", err_pulses);
            fail = 1'b1;
        end

        // ---- T-FR3: UDP port mismatch discards the whole frame ----
        // A 16-byte frame (length OK) on the WRONG UDP port must be discarded
        // entirely: err_udp_port pulses exactly once at frame_start and ZERO
        // bytes reach out_data/out_valid, even though rx_valid carries bytes.
        udp_err_pulses = 0;
        udp_rec_dest_port = 16'd60001;   // wrong port (cfg is 60000)
        send_frame(16'd16, 16, 8'h90);
        if (got_cnt !== 0) begin
            $display("FAIL: FR-3 wrong-port forwarded %0d bytes, expected 0", got_cnt);
            fail = 1'b1;
        end
        if (udp_err_pulses !== 1) begin
            $display("FAIL: FR-3 wrong-port err_udp_port pulsed %0d times, expected 1", udp_err_pulses);
            fail = 1'b1;
        end
        if (err_pulses !== 0) begin
            $display("FAIL: FR-3 wrong-port err_frame_len pulsed %0d times, expected 0 (length was fine)", err_pulses);
            fail = 1'b1;
        end

        // ---- FR-3 clean recovery: next frame on the CONFIGURED port passes ----
        err_pulses = 0; udp_err_pulses = 0;
        udp_rec_dest_port = 16'd60000;   // back to the configured port
        send_frame(16'd16, 16, 8'hA0);
        check_passthrough(16, 8'hA0);
        if (err_pulses !== 0 || udp_err_pulses !== 0) begin
            $display("FAIL: FR-3 recovery: err pulses (len=%0d udp=%0d), expected 0/0",
                     err_pulses, udp_err_pulses);
            fail = 1'b1;
        end

        // ---- FR-3 regression: port match must not mask the FR-5 length
        //      check (a wrong-length frame on the RIGHT port still counts
        //      err_frame_len, not err_udp_port) ----
        err_pulses = 0; udp_err_pulses = 0;
        udp_rec_dest_port = 16'd60000;
        send_frame(16'd17, 17, 8'hB0);   // bad length, right port
        if (got_cnt !== 0) begin
            $display("FAIL: FR-3+FR-5 (bad len, right port) forwarded %0d bytes, expected 0", got_cnt);
            fail = 1'b1;
        end
        if (err_pulses !== 1 || udp_err_pulses !== 0) begin
            $display("FAIL: FR-3+FR-5 (bad len, right port): len=%0d udp=%0d, expected 1/0",
                     err_pulses, udp_err_pulses);
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
