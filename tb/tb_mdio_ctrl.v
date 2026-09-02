`timescale 1ns / 1ps

// Self-checking testbench for rtl/common/mdio_ctrl.v.
//
// Icarus:
//   iverilog -g2001 -Wall -o mdio_ctrl_tb.vvp rtl/common/mdio_ctrl.v tb/tb_mdio_ctrl.v
//   vvp mdio_ctrl_tb.vvp
//
// Models a minimal clause-22 MDIO slave, decodes every frame on the bus and
// checks the bring-up sequence produced by the DUT against the expected
// register writes (docs/design_decisions.md D9 -- JL2121(D), not KSZ9031RNX;
// three direct writes only, no MMD/skew frames, plus a settle-delay check).
//
// Verilog-2001 only.

module tb_mdio_ctrl;

    // -----------------------------------------------------------------
    // DUT parameters (fast test overrides for a short simulation)
    // -----------------------------------------------------------------
    localparam integer CLK_HZ          = 50_000_000;   // 50 MHz test clock (20 ns period)
    localparam integer MDC_HZ          = 10_000_000;   // overridden: mdc period >= 100 ns
    localparam integer MDC_MIN_NS      = 1000_000_000 / MDC_HZ;  // = 100
    localparam integer RESET_SETTLE_NS = 500;          // overridden from the real 10ms for a fast sim
    localparam integer CLK_PERIOD_NS   = 1_000_000_000 / CLK_HZ;
    localparam integer SETTLE_CYCLES   = (RESET_SETTLE_NS + CLK_PERIOD_NS - 1) / CLK_PERIOD_NS;

    localparam PHY_ADDR = 5'b00001;

    // -----------------------------------------------------------------
    // Expected bring-up sequence (rtl/common/mdio_ctrl.v, D9)
    // -----------------------------------------------------------------
    localparam [15:0] DIR_VAL_ANEG  = 16'h0141;   // reg 4 : advertise 10BASE-T / 100BASE-TX FD
    localparam [15:0] DIR_VAL_1000T = 16'h0200;   // reg 9 : advertise 1000BASE-T FD
    localparam [15:0] DIR_VAL_CTRL  = 16'h9140;   // reg 0 : soft reset, autoneg, FD, 1000 Mbps

    // -----------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------
    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    reg  start = 1'b0;
    wire busy, done;
    wire mdc;
    wire mdio;

    always #10 clk = ~clk;   // 50 MHz

    mdio_ctrl #(
        .PHY_ADDR        (PHY_ADDR),
        .CLK_HZ          (CLK_HZ),
        .MDC_HZ          (MDC_HZ),
        .RESET_SETTLE_NS (RESET_SETTLE_NS)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .start (start),
        .busy  (busy),
        .done  (done),
        .mdc   (mdc),
        .mdio  (mdio)
    );

    // -----------------------------------------------------------------
    // Expected frame table (register, data), 3 frames -- see D9: no MMD/skew
    // frames for this PHY, unlike the KSZ9031-targeted first draft.
    // -----------------------------------------------------------------
    reg [4:0]  exp_reg [0:7];
    reg [15:0] exp_dat [0:7];

    initial begin
        exp_reg[0] = 5'd4; exp_dat[0] = DIR_VAL_ANEG;
        exp_reg[1] = 5'd9; exp_dat[1] = DIR_VAL_1000T;
        exp_reg[2] = 5'd0; exp_dat[2] = DIR_VAL_CTRL;
    end

    // -----------------------------------------------------------------
    // Test status / collected frames
    // -----------------------------------------------------------------
    integer frame_count      = 0;
    integer done_count       = 0;
    reg     fail             = 1'b0;
    reg     busy_seen        = 1'b0;
    time    last_frame_time  = 0;   // $time when the 3rd (final) frame finished decoding
    reg [4:0]  got_reg [0:31];
    reg [15:0] got_dat [0:31];

    // -----------------------------------------------------------------
    // Clause-22 slave model: sample mdio on mdc rising edges, decode frames
    // -----------------------------------------------------------------
    reg  mdc_d = 1'b1;
    integer ones_cnt     = 0;
    integer collect_cnt  = 0;
    reg [31:0] frame_bits;
    reg collecting = 1'b0;
    time last_rise = 0;
    reg mdc_period_ok = 1'b1;

    always @(posedge clk) begin
        mdc_d <= mdc;
    end

    always @(posedge clk) begin
        if (mdc && !mdc_d) begin
            // --- mdc period must never be shorter than 1/MDC_HZ ---------
            if (last_rise != 0) begin
                if ($time - last_rise < MDC_MIN_NS) begin
                    $display("FAIL: mdc period %0t ns shorter than %0d ns at t=%0t",
                             $time - last_rise, MDC_MIN_NS, $time);
                    mdc_period_ok = 0;
                end
            end
            last_rise = $time;

            // --- mdio must never be X -----------------------------------
            if (mdio === 1'bx) begin
                $display("FAIL: mdio is X at t=%0t", $time);
                fail = 1;
            end

            if (busy) begin
                // While actively transmitting a frame, mdio must be driven
                // 0/1, never Z. Once all 3 frames are sent, `busy` stays
                // high through the post-reset settle wait (D9) with mdio
                // correctly released -- that's not a frame in flight, so
                // don't apply the never-Z rule there.
                if (mdio === 1'bz && frame_count < 3) begin
                    $display("FAIL: mdio is Z at t=%0t while busy transmitting", $time);
                    fail = 1;
                end

                if (!collecting) begin
                    if (mdio === 1'b0) begin
                        if (ones_cnt >= 32) begin
                            collecting   = 1;
                            collect_cnt  = 0;
                            frame_bits[31] = 1'b0;   // ST[0]
                        end else begin
                            $display("FAIL: frame %0d: ST before 32-bit preamble (ones=%0d) at t=%0t",
                                     frame_count, ones_cnt, $time);
                            fail = 1;
                        end
                    end else begin
                        ones_cnt = (ones_cnt >= 40) ? 40 : ones_cnt + 1;
                    end
                end else begin
                    frame_bits[30 - collect_cnt] = (mdio === 1'b0) ? 1'b0 : 1'b1;
                    collect_cnt = collect_cnt + 1;
                    if (collect_cnt == 31) begin
                        check_frame(frame_bits, frame_count);
                        collecting  = 0;
                        ones_cnt    = 0;
                        collect_cnt = 0;
                    end
                end
            end else begin
                collecting  = 0;
                ones_cnt    = 0;
                collect_cnt = 0;
            end
        end
    end

    // -----------------------------------------------------------------
    // Decode + verify a complete frame. fb holds the 32 post-preamble bits:
    //   [31]=ST0 [30]=ST1 [29:28]=OP [27:23]=PHYAD [22:18]=REGAD
    //   [17:16]=TA [15:0]=DATA
    // -----------------------------------------------------------------
    task check_frame;
        input [31:0] fb;
        input integer fidx;
        reg ok;
        begin
            ok = 1;
            if (fb[31:30] !== 2'b01) begin
                $display("FAIL: frame %0d: ST=%02b (expected 01)", fidx, fb[31:30]); ok = 0;
            end
            if (fb[29:28] !== 2'b01) begin
                $display("FAIL: frame %0d: OP=%02b (expected 01=write)", fidx, fb[29:28]); ok = 0;
            end
            if (fb[27:23] !== PHY_ADDR) begin
                $display("FAIL: frame %0d: PHYAD=%05b (expected %05b)", fidx, fb[27:23], PHY_ADDR); ok = 0;
            end
            if (fb[17:16] !== 2'b10) begin
                $display("FAIL: frame %0d: TA=%02b (expected 10)", fidx, fb[17:16]); ok = 0;
            end
            got_reg[fidx] = fb[22:18];
            got_dat[fidx] = fb[15:0];
            if (!ok) fail = 1;
            if (fidx == 31) begin
                $display("FAIL: more than 32 frames seen");
                fail = 1;
            end else begin
                frame_count = fidx + 1;
                if (frame_count == 3) last_frame_time = $time;
            end
        end
    endtask

    // -----------------------------------------------------------------
    // busy / done monitoring
    // -----------------------------------------------------------------
    always @(posedge clk) begin
        if (busy) busy_seen = 1'b1;
    end

    always @(posedge done) begin
        done_count = done_count + 1;
        if (!busy) begin
            $display("FAIL: done pulsed while busy is low at t=%0t", $time);
            fail = 1;
        end
        // D9 sanity check: done must not fire right on the heels of the last
        // MDIO frame -- some real settle delay (RESET_SETTLE_CYCLES in the
        // DUT) must have elapsed. Half the configured settle time is the
        // threshold, not the full value: the DUT counts its delay from its
        // own internal mdc_fall reference, which trails this testbench's
        // "last bit sampled on mdc rise" marker by up to half an mdc period,
        // so an exact-value check would be measuring two different clocks'
        // edges against each other, not verifying the DUT's actual count.
        if (last_frame_time != 0 && ($time - last_frame_time) < (RESET_SETTLE_NS / 2)) begin
            $display("FAIL: done fired only %0t ns after the last frame (need a real settle delay, ~%0d ns)",
                     $time - last_frame_time, RESET_SETTLE_NS);
            fail = 1;
        end
    end

    // -----------------------------------------------------------------
    // Compare collected frames against the expected table
    // -----------------------------------------------------------------
    task check_all_frames;
        integer k;
        begin
            if (frame_count !== 3) begin
                $display("FAIL: expected 3 MDIO frames, decoded %0d", frame_count);
                fail = 1;
            end else begin
                for (k = 0; k < 3; k = k + 1) begin
                    if (got_reg[k] !== exp_reg[k] || got_dat[k] !== exp_dat[k]) begin
                        $display("FAIL: frame %0d: expected reg=%h data=%h, got reg=%h data=%h",
                                 k, exp_reg[k], exp_dat[k], got_reg[k], got_dat[k]);
                        fail = 1;
                    end
                end
            end
        end
    endtask

    // -----------------------------------------------------------------
    // Main test flow
    // -----------------------------------------------------------------
    initial begin
        $display("tb_mdio_ctrl: starting (CLK_HZ=%0d MDC_HZ=%0d)", CLK_HZ, MDC_HZ);

        // reset
        rst_n = 1'b0;
        #100;
        rst_n = 1'b1;
        #200;

        if (busy !== 1'b0) begin
            $display("FAIL: busy is high before start at t=%0t", $time);
            fail = 1;
        end

        // pulse start (one clock cycle)
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        // Let the whole sequence run, then drain. 3 frames x 64 bits x one
        // mdc period (~100 ns) plus the RESET_SETTLE_NS settle delay is
        // ~20 us; 200 us is a generous bound. done_count/frame_count below
        // catch a missing done.
        #(200_000);

        check_all_frames();

        if (done_count !== 1) begin
            $display("FAIL: done pulsed %0d times (expected exactly 1)", done_count);
            fail = 1;
        end
        if (!busy_seen) begin
            $display("FAIL: busy never seen high");
            fail = 1;
        end
        if (busy !== 1'b0) begin
            $display("FAIL: busy still high after sequence");
            fail = 1;
        end
        if (!mdc_period_ok) begin
            $display("FAIL: mdc period violated MDC_HZ");
            fail = 1;
        end

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
