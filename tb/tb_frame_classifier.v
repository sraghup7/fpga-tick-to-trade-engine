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
//
// Drives rx_data/rx_valid/frame_start/rx_len directly -- the same
// eth_mac_if-shaped boundary tb_eth_mac_if_rx.v mocks -- rather than
// instantiating eth_mac_if itself, since frame_classifier's contract with
// its producer is exactly these four signals (docs/design_decisions.md D11).
//
// A rejected frame still streams its declared number of bytes on
// rx_valid/rx_data (a frame can be "bad length" and still have real bytes
// behind it); the check is that ZERO of them reach out_data/out_valid and
// err_frame_len pulses exactly once, timed off frame_start -- which is also
// what makes a zero-length frame's rejection observable at all.
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

    wire [7:0] out_data;
    wire       out_valid;
    wire       err_frame_len;

    frame_classifier dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .rx_data       (rx_data),
        .rx_valid      (rx_valid),
        .frame_start   (frame_start),
        .rx_len        (rx_len),
        .out_data      (out_data),
        .out_valid     (out_valid),
        .err_frame_len (err_frame_len)
    );

    reg fail = 1'b0;

    // ---- collectors ----
    reg [7:0] got [0:1599];
    integer   got_cnt;
    integer   err_pulses;

    // Count err_frame_len pulses continuously (independent of the tasks
    // below, so a pulse mid-task is never missed).
    always @(posedge clk) if (err_frame_len) err_pulses = err_pulses + 1;

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

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
