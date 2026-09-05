`timescale 1ns / 1ps

// Self-checking connectivity/smoke testbench for rtl/tob_top.v (contract
// docs/contracts/tob_top.md S3). NOT a re-run of every module's own
// behavior -- each wired module already has its own exhaustive testbench.
// This file catches WIRING mistakes: a swapped port, a missing connection,
// an inverted polarity, a wrong arbiter priority.
//
// Architecture: the real rtl/tob_top.v is instantiated as DUT, but the two
// vendor leaf modules it instantiates (mac_top.v and util_gmii_to_rgmii.v)
// are provided by tb/sim_models/tob_top_sim_leaves.v -- behavioral
// stand-ins bound by name, compiled IN PLACE of the vendor RTL (which needs
// Xilinx primitives / real ethernet frames to simulate). The testbench
// therefore drives at mac_top.v's own UDP boundary -- udp_rec_data_valid/
// udp_rec_data_length/udp_rec_ram_rdata in, ram_wr_data/udp_tx_req/
// mac_send_end out -- the same boundary tb/tb_eth_mac_if_rx.v and
// tb_eth_mac_if_tx.v exercise, via force/release on the stand-in's scalar
// test hooks (the "mocked RAM boundary" pattern, contract S3).
//
// Engine clocks: gmii_rx_clk is derived inside tob_top from the rgmii_rxc
// input (this tb drives it as a free-running 125 MHz clock); sys_clk is the
// 50 MHz board oscillator. The engine stays in reset until tob_top's
// internal PHY-reset hold elapses (~500,000 sys_clk cycles), so every
// scenario starts by waiting for dut.engine_rst_n.
//
// Cases (contract S3):
//   T1    one message end-to-end: a bid QUOTE then an ask QUOTE on a
//         watched symbol produce a 0x10 NEW order on the TX boundary with
//         the expected fields (whole chain wired end to end)
//   T2    CSR write/read round trip through the shared tap: write
//         MAX_ORDER_QTY, probe the cfg_max_order_qty net, read it back via
//         a 0x21/0x22 round trip through the TX arbiter
//   T3    TX arbiter priority: force order_builder and csr_block to want
//         the same cycle; the order's 0x10 frame goes out, the CSR response
//         is held off (resp_busy), and a later genuine read is uncorrupted
//   T4    err_fcs/err_ip wiring: force the mac stand-in's mac_rec_error /
//         udp_checksum_error and confirm csr_block's err_fcs / err_ip
//         counters increment (D5/S1.5)
//   T5    kill switch + reset sanity: kill_sw via key_in[0] asserts
//         kill_latched which shows on led[1]
//   T6    ML gate 0x09 block mode: a tradeable-book quote whose z crosses
//         ML_TH_HIGH emits a 0x11 reject frame with reject_reason = 0x09
//   T7    ML gate 0x09 reduce mode (ML_CTRL action=reduce, shift=1): the
//         same setup emits a 0x10 NEW order with qty reduced 100 >> 1 = 50
//
// The mdio_ctrl.v CLK_HZ override (D22 point 2) is a static source-level
// check, verified by inspection/grep, not this testbench.
//
// On any mismatch a FAIL line names the check and expected vs actual; a
// final PASS/FAIL line summarizes. Verilog-2001 only.

module tb_tob_top;

    // ---- clocks: sys_clk 50 MHz, rgmii_rxc 125 MHz ----
    reg sys_clk = 1'b0;
    always #10 sys_clk = ~sys_clk;      // 50 MHz
    reg rgmii_rxc = 1'b0;
    always #4 rgmii_rxc = ~rgmii_rxc;   // 125 MHz

    reg rst_n = 1'b0;
    reg [3:0] key_in = 4'b1111;         // none pressed
    wire [3:0] led;

    wire [3:0] rgmii_txd, rgmii_rxd;
    wire rgmii_tx_ctl, rgmii_txc, rgmii_rx_ctl;
    wire mdc;
    wire mdio;
    wire phy_reset_n;
    wire engine_clk = rgmii_rxc;

    assign rgmii_rxd = 4'd0;
    assign rgmii_rx_ctl = 1'b0;

    tob_top #(
        .PHY_RESET_HOLD_CYCLES(16)   // shorten the 10 ms board-reset hold for
                                     // simulation; production default 500_000
    ) dut (
        .sys_clk     (sys_clk),
        .rst_n       (rst_n),
        .key_in      (key_in),
        .led         (led),
        .rgmii_txd   (rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_txc   (rgmii_txc),
        .rgmii_rxd   (rgmii_rxd),
        .rgmii_rx_ctl(rgmii_rx_ctl),
        .rgmii_rxc   (rgmii_rxc),
        .mdc         (mdc),
        .mdio        (mdio),
        .phy_reset_n (phy_reset_n)
    );

    // pull MDIO idle-high so mdio_ctrl's reads see a defined level
    pullup (mdio);

    reg fail = 1'b0;

    task chk;
        input integer tag;
        input [31:0] got;
        input [31:0] exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: got %08x, expected %08x", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    // ---- cycle pacing on the engine clock ----
    task adv;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge rgmii_rxc);
                #1;
            end
        end
    endtask

    // ---- board reset + wait for the engine to come out of reset ----
    task bring_up;
        integer tries;
        begin
            key_in = 4'b1111;
            rst_n = 1'b0;
            repeat (5) @(negedge sys_clk);
            rst_n = 1'b1;
            // engine_rst_n rises after the (shortened) PHY-reset hold has
            // elapsed and the 2-FF sync in the gmii domain has propagated
            tries = 0;
            while (dut.engine_rst_n !== 1'b1 && tries < 2000) begin
                @(posedge sys_clk);
                tries = tries + 1;
            end
            if (dut.engine_rst_n !== 1'b1) begin
                $display("FAIL: engine never left reset");
                fail = 1'b1;
            end
            adv(300);   // generous settle on the gmii side before any frame
        end
    endtask

    // ---- inject one 16-byte UDP payload frame at mac_top's RX boundary ----
    task rx_frame;
        input [127:0] payload;
        begin
            @(negedge rgmii_rxc);
            force dut.u_mac.sim_rx_frame       = payload;
            force dut.u_mac.udp_rec_data_length = 16'd16;
            force dut.u_mac.udp_rec_data_valid  = 1'b1;
            @(negedge rgmii_rxc);
            force dut.u_mac.udp_rec_data_valid  = 1'b0;
            adv(4);
        end
    endtask

    // Pack a 16-byte big-endian market-data message.
    function [127:0] msg_frame;
        input [7:0]  mt;
        input [7:0]  sym;
        input [7:0]  side;
        input [7:0]  flags;
        input [31:0] price;
        input [31:0] qty;
        input [31:0] seq;
        begin
            msg_frame = {mt, sym, side, flags, price, qty, seq};
        end
    endfunction

    // Pack a 16-byte big-endian CSR frame.
    function [127:0] csr_frame_pack;
        input [7:0]  mt;
        input [15:0] addr;
        input [31:0] data;
        begin
            csr_frame_pack = {mt, 8'h00, addr, data, 64'd0};
        end
    endfunction

    // Write a CSR register (0x20) and let it settle.
    task csr_write;
        input [15:0] addr;
        input [31:0] data;
        begin
            rx_frame(csr_frame_pack(8'h20, addr, data));
            adv(60);
        end
    endtask

    // ---- wait until the mac stand-in has captured one more TX frame ----
    task wait_tx_after;
        input integer prev;
        output integer ok;
        integer tries;
        begin
            ok = 0;
            tries = 0;
            while (dut.u_mac.tx_frame_cnt == prev && tries < 30000) begin
                @(posedge rgmii_rxc);
                #1;
                tries = tries + 1;
            end
            if (dut.u_mac.tx_frame_cnt != prev) ok = 1;
        end
    endtask

    // ---- read the most recent captured TX frame's 16 bytes ----
    task get_tx_frame;
        output [127:0] frame;
        integer k;
        begin
            for (k = 0; k < 16; k = k + 1)
                frame[127 - 8*k -: 8] = dut.u_mac.tx_ram[k];
        end
    endtask

    // ---- send a 0x21 read request and return the response's data field ----
    task csr_read_value;
        input [15:0] addr;
        output reg [31:0] val;
        output reg rd_ok;
        integer prev;
        reg [127:0] frame;
        begin
            prev = dut.u_mac.tx_frame_cnt;
            rx_frame(csr_frame_pack(8'h21, addr, 32'd0));
            adv(30);
            wait_tx_after(prev, rd_ok);
            if (rd_ok) begin
                get_tx_frame(frame);
                if (frame[127:120] !== 8'h22) begin
                    $display("FAIL: csr read %04x: response type %02x, expected 22", addr, frame[127:120]);
                    fail = 1'b1;
                end
                if (frame[111:96] !== addr) begin
                    $display("FAIL: csr read %04x: addr echo %04x", addr, frame[111:96]);
                    fail = 1'b1;
                end
                val = frame[95:64];
            end else begin
                $display("FAIL: no TX response for csr read of %04x", addr);
                val = 32'hFFFF_FFFF;
            end
        end
    endtask

    integer prev, ok;
    reg [127:0] frame;
    reg [31:0] val;
    reg rd_ok;

    initial begin
        bring_up;

        // ================= T1: one order end-to-end =================
        // The ML gate is now live (S6) with default thresholds (th_high=0)
        // that would block this order; neutralize them first so T1 exercises
        // the order path, not the ML gate (T6/T7 cover the ML gate).
        csr_write(16'h0048, 32'h7FFFFFFF);   // ML_TH_HIGH -> never adverse by z
        csr_write(16'h004C, 32'h7FFFFFFE);   // ML_TH_LOW
        // Build a tradeable book with two QUOTEs on symbol 1 -- a bid, then
        // an ask that itself completes the tradeable condition. Post-D23,
        // signal_engine reads tob_engine's next_* (post-update) outputs for
        // the applied slot, so the ask QUOTE's OWN cycle already sees the
        // book as it will read after this update -- no third re-quote
        // needed to "wait for the registered bus to catch up" (that was the
        // pre-fix workaround; docs/contracts/tob_engine_signal_patch.md).
        // Buy fires when bid_qty > ask_qty<<imb_shift (defaults: imb_shift=1)
        // and spread >= min_spread (default 2): bid 1000/100, ask 1005/1.
        rx_frame(msg_frame(8'h01, 8'h01, 8'h00, 8'h00, 32'd1000, 32'd100, 32'd1));
        adv(60);
        prev = dut.u_mac.tx_frame_cnt;
        rx_frame(msg_frame(8'h01, 8'h01, 8'h01, 8'h00, 32'd1005, 32'd1, 32'd2));
        adv(60);
        wait_tx_after(prev, ok);
        if (!ok) begin
            $display("FAIL: T1 no order transmitted within timeout");
            fail = 1'b1;
        end else begin
            get_tx_frame(frame);
            $display("T1 tx frame: %032x", frame);
            chk(1000, {frame[127:96]}, {8'h10, 8'h01, 8'h00, 8'h00});
            chk(1001, frame[95:64], 32'd1005);   // buy at the ask
            chk(1002, frame[63:32], 32'd100);    // qty = cfg_order_qty default
        end

        // ================= T2: CSR write/read via the shared tap =================
        // Write MAX_ORDER_QTY (0x28) = 1234; probe the cfg net, read back.
        rx_frame(csr_frame_pack(8'h20, 16'h0028, 32'h0000_04D2));
        adv(60);
        chk(2000, dut.cfg_max_order_qty, 32'h0000_04D2);   // net actually changed
        prev = dut.u_mac.tx_frame_cnt;
        rx_frame(csr_frame_pack(8'h21, 16'h0028, 32'd0));
        adv(30);
        wait_tx_after(prev, ok);
        if (!ok) begin $display("FAIL: T2 no CSR response transmitted"); fail = 1'b1; end
        else begin
            get_tx_frame(frame);
            $display("T2 tx frame: %032x", frame);
            if (frame[127:120] !== 8'h22) begin $display("FAIL: T2 response type=%02x exp 22", frame[127:120]); fail = 1'b1; end
            chk(2001, frame[111:96], 16'h0028);   // addr echo
            chk(2002, frame[95:64], 32'h0000_04D2);
        end

        // ================= T3: TX arbiter priority =================
        // First prove resp_busy reflects the shared path's real busy:
        @(negedge rgmii_rxc);
        force dut.eth_tx_busy = 1'b1;
        #1;
        if (dut.csr_resp_busy !== 1'b1) begin
            $display("FAIL: T3 csr_resp_busy not set by eth_tx_busy");
            fail = 1'b1;
        end
        @(negedge rgmii_rxc);
        release dut.eth_tx_busy;
        // Now make order_builder and csr_block want the SAME cycle:
        prev = dut.u_mac.tx_frame_cnt;
        @(negedge rgmii_rxc);
        force dut.ob_tx_start    = 1'b1;
        force dut.ob_tx_payload  = {8'h10, 8'h01, 8'h00, 8'h00, 32'd1005, 32'd100, 16'd2, 16'd3};
        force dut.csr_resp_start = 1'b1;
        force dut.csr_resp_payload = {8'h22, 8'h00, 16'h0028, 32'hDEAD_BEEF, 64'd0};
        #1;
        if (dut.eth_tx_start !== 1'b1) begin $display("FAIL: T3 eth_tx_start not asserted"); fail = 1'b1; end
        if (dut.eth_tx_payload !== dut.ob_tx_payload) begin
            $display("FAIL: T3 arbiter passed the CSR payload, not the order (order must win)");
            fail = 1'b1;
        end
        if (dut.csr_resp_busy !== 1'b1) begin
            $display("FAIL: T3 csr_resp_busy not set by ob_tx_start");
            fail = 1'b1;
        end
        @(negedge rgmii_rxc);
        release dut.ob_tx_start;
        release dut.ob_tx_payload;
        release dut.csr_resp_start;
        release dut.csr_resp_payload;
        adv(40);
        wait_tx_after(prev, ok);
        if (!ok) begin $display("FAIL: T3 no TX from the priority cycle"); fail = 1'b1; end
        else begin
            get_tx_frame(frame);
            if (frame[127:120] !== 8'h10) begin
                $display("FAIL: T3 arbiter emitted type %02x (expected 10 -- order wins, CSR response dropped)", frame[127:120]);
                fail = 1'b1;
            end
        end
        // the dropped (forced) CSR response must not corrupt a later real read
        csr_read_value(16'h0028, val, rd_ok);
        chk(3000, val, 32'h0000_04D2);

        // ================= T4: err_fcs / err_ip wiring (D5/S1.5) =================
        @(negedge rgmii_rxc);
        force dut.u_mac.mac_rec_error = 1'b1;
        @(posedge rgmii_rxc);
        #1;
        force dut.u_mac.mac_rec_error = 1'b0;
        adv(20);
        csr_read_value(16'h00B0, val, rd_ok);   // err_fcs
        chk(4000, val, 32'd1);

        @(negedge rgmii_rxc);
        force dut.u_mac.udp_checksum_error = 1'b1;
        @(posedge rgmii_rxc);
        #1;
        force dut.u_mac.udp_checksum_error = 1'b0;
        adv(20);
        csr_read_value(16'h00B8, val, rd_ok);   // err_ip
        chk(4001, val, 32'd1);

        // ================= T5: kill switch via key_in[0] =================
        @(negedge rgmii_rxc);
        key_in[0] = 1'b0;   // KEY1 pressed (active low)
        adv(20);
        if (led[1] !== 1'b1) begin
            $display("FAIL: T5 kill_latched LED not set after key_in[0] pressed");
            fail = 1'b1;
        end
        @(negedge rgmii_rxc);
        key_in[0] = 1'b1;
        adv(20);
        if (led[1] !== 1'b1) begin
            $display("FAIL: T5 kill_latched LED dropped without a kill-clear (must stay latched)");
            fail = 1'b1;
        end

        // ================= T6: ML gate 0x09 blocks (block mode) =================
        // Clear the T5 kill latch (CTRL bit1) and turn on reject reporting
        // (CTRL bit4) so the blocked order emits a 0x11 diagnostic frame. Then
        // set ML thresholds so a completing quote's z crosses T_high.
        csr_write(16'h0000, 32'h12);         // kill-clear (bit1) + reject report (bit4)
        csr_write(16'h0048, 32'd100);        // ML_TH_HIGH = 100
        csr_write(16'h004C, 32'hFFFFFF9C);   // ML_TH_LOW  = -100
        csr_write(16'h0050, 32'd0);          // ML_CTRL: action=block, shift=0
        // symbol 2 (slot 1), fresh book: bid 100/10 then ask 110/4. The ask
        // completes a tradeable book (bid_qty 10 > ask_qty<<1 = 8 -> buy) AND
        // its features sum to z = 10+55+6+0+4+2+0+55 = 132 >= 100 -> adverse.
        // The SAME event fires the signal and the ML verdict; gate 0x09 blocks.
        rx_frame(msg_frame(8'h01, 8'h02, 8'h00, 8'h00, 32'd100, 32'd10, 32'd3));
        adv(60);
        prev = dut.u_mac.tx_frame_cnt;
        rx_frame(msg_frame(8'h01, 8'h02, 8'h01, 8'h00, 32'd110, 32'd4, 32'd4));
        adv(60);
        wait_tx_after(prev, ok);
        if (!ok) begin
            $display("FAIL: T6 no reject frame transmitted");
            fail = 1'b1;
        end else begin
            get_tx_frame(frame);
            $display("T6 tx frame: %032x", frame);
            if (frame[127:120] !== 8'h11) begin
                $display("FAIL: T6 frame type %02x, expected 11 (reject)", frame[127:120]);
                fail = 1'b1;
            end
            chk(6000, frame[103:96], 8'h09);   // reject_reason = 0x09 (ML)
        end

        // ================= T7: ML gate 0x09 reduces (reduce mode) =================
        // action=reduce (bit0) + reduce_shift=1 (bits 4:1 -> 1) => ML_CTRL=0x3.
        // Same tradeable-book setup on a fresh symbol (slot 2 = symbol 3), so
        // z=132 again. Gate 0x09 now reduces (100 >> 1 = 50) instead of blocking.
        csr_write(16'h0050, 32'd3);
        rx_frame(msg_frame(8'h01, 8'h03, 8'h00, 8'h00, 32'd100, 32'd10, 32'd5));
        adv(60);
        prev = dut.u_mac.tx_frame_cnt;
        rx_frame(msg_frame(8'h01, 8'h03, 8'h01, 8'h00, 32'd110, 32'd4, 32'd6));
        adv(60);
        wait_tx_after(prev, ok);
        if (!ok) begin
            $display("FAIL: T7 no order transmitted");
            fail = 1'b1;
        end else begin
            get_tx_frame(frame);
            $display("T7 tx frame: %032x", frame);
            chk(7000, frame[127:120], 8'h10);   // still a NEW order
            chk(7001, frame[63:32], 32'd50);    // qty reduced: 100 >> 1
        end

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
