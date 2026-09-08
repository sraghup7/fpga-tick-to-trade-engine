`timescale 1ns / 1ps

// Self-checking testbench for rtl/latency_histogram.v (master spec S3.1
// [L], FR-53..55, NFR-1/2; contract docs/contracts/latency_histogram.md).
//
// Icarus:
//   iverilog -g2001 -Wall -o latency_histogram_tb.vvp rtl/latency_histogram.v tb/tb_latency_histogram.v
//   vvp latency_histogram_tb.vvp
//
// latency_histogram.v buckets each transmitted accepted order's already
// computed latency_cyc (read off order_builder.v's ob_tx_start/
// ob_tx_payload[15:0], 0x10-NEW-only) into a 64-entry saturating BRAM
// histogram: buckets 0-62 are exact 1-cycle latency buckets, bucket 63 is
// the >=63 catch-all (D21). Reads are via a standalone registered
// hist_rd_addr/hist_rd_data port; cfg_counter_clear clears all 64 buckets.
//
// Saturation-boundary note: per-bucket counters are 32-bit in production,
// which makes the 0xFFFFFFFF boundary unreachable by pulsing (4.3e9
// cycles) and unforceable (Icarus cannot force a memory word). Following
// the repo's own precedent (tb_counter_sat.v tests the saturating boundary
// at a narrower parameterized width while the full-width instance gets
// plumbing checks), this TB instantiates the DUT twice: `dut` at the
// production BUCKET_W=32 (all counting/occupancy/clear/readout cases) and
// `dut4` at BUCKET_W=4 (saturation reachable in 16 pulses). The default
// BUCKET_W=32 RTL is behaviourally identical; only the word width differs.
//
// Cases (contract S3):
//   H1    T25's own property: several 0x10 pulses with the SAME latency
//         produce exactly one nonzero bucket; all 64 buckets read back and
//         the other 63 are 0
//   H2    distinct latencies (0,10,11,22) land in their own exact bucket
//   H3    0x11 reject-diagnostic frames change nothing (and never raise
//         lat_valid)
//   H4    saturating catch-all: latencies 63,64,1000,0xFFFF all land in
//         bucket 63; bucket 62 never increments
//   H5    per-bucket saturation (dut4, BUCKET_W=4): 20 pulses into one
//         bucket hold it at 15 (0xF) instead of wrapping
//   H6    cfg_counter_clear resets all 64 buckets to 0 (a sequential
//         64-cycle sweep, one address per cycle -- see rtl/
//         latency_histogram.v's header for why it isn't one cycle anymore)
//   H7    hist_rd_data is a registered read: the previous value persists
//         for one cycle after hist_rd_addr changes
//   H8    lat_valid/lat_value pin-compatibility with csr_block.v's input
//         ports: 1-bit pulse on 0x10 only, 16-bit value = payload[15:0]
//   H9    a lat_valid pulse landing during the clear sweep is dropped, not
//         queued (the sequential-clear fix's documented tradeoff); a pulse
//         after the sweep finishes counts normally again
//
// On any mismatch a FAIL line names the bucket/case and expected vs actual;
// a final PASS/FAIL line summarizes. Verilog-2001 only.

module tb_latency_histogram;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    // ---- shared DUT inputs ----
    reg        rst_n = 1'b0;
    reg        ob_tx_start = 1'b0;
    reg [127:0] ob_tx_payload = 128'd0;
    reg        cfg_counter_clear = 1'b0;

    // ---- DUT (production width) ----
    wire [5:0]  hist_rd_addr;
    wire [31:0] hist_rd_data;
    wire        lat_valid;
    wire [15:0] lat_value;
    reg  [5:0]  hist_rd_addr_d = 6'd0;

    // ---- DUT (narrow width, saturation-reachable) ----
    wire [31:0] hist_rd_data4;
    wire        lat_valid4;
    wire [15:0] lat_value4;
    reg  [5:0]  hist_rd_addr4_d = 6'd0;

    latency_histogram dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .ob_tx_start       (ob_tx_start),
        .ob_tx_payload     (ob_tx_payload),
        .cfg_counter_clear (cfg_counter_clear),
        .lat_valid         (lat_valid),
        .lat_value         (lat_value),
        .hist_rd_addr      (hist_rd_addr_d),
        .hist_rd_data      (hist_rd_data)
    );

    latency_histogram #(.BUCKET_W(4)) dut4 (
        .clk               (clk),
        .rst_n             (rst_n),
        .ob_tx_start       (ob_tx_start),
        .ob_tx_payload     (ob_tx_payload),
        .cfg_counter_clear (cfg_counter_clear),
        .lat_valid         (lat_valid4),
        .lat_value         (lat_value4),
        .hist_rd_addr      (hist_rd_addr4_d),
        .hist_rd_data      (hist_rd_data4)
    );

    reg fail = 1'b0;

    task chk;
        input integer tag;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: got %08x, expected %08x", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    // per-pulse capture of the combinational lat_valid/lat_value
    reg        s_lat_valid;
    reg [15:0] s_lat_value;

    // Assert + release reset, then wait out the sequential clear sweep (64
    // cycles, one address per cycle -- see rtl/latency_histogram.v's header)
    // before returning. A lat_valid pulse fired while the DUT is still
    // clearing is dropped by design, so every test in this file needs the
    // memory to be genuinely all-zero and idle before it starts pulsing.
    task reset_dut;
        begin
            @(negedge clk);
            ob_tx_start      = 1'b0;
            ob_tx_payload    = 128'd0;
            cfg_counter_clear = 1'b0;
            hist_rd_addr_d   = 6'd0;
            hist_rd_addr4_d  = 6'd0;
            rst_n = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            repeat (70) @(posedge clk);   // 64-cycle clear sweep + margin
            #1;
        end
    endtask

    // Drive one accepted (0x10) or rejected (0x11) order TX pulse with the
    // given latency; captures lat_valid/lat_value during the pulse cycle.
    task pulse_ob;
        input [7:0]  mt;
        input [15:0] lat;
        begin
            @(negedge clk);
            ob_tx_start   = 1'b1;
            ob_tx_payload = {mt, 8'h00, 8'h00, 8'h00, 32'd0, 32'd0, 16'd0, lat};
            #1;   // sample the combinational lat_valid/lat_value this cycle
            s_lat_valid = lat_valid;
            s_lat_value = lat_value;
            @(posedge clk);
            #1;
            ob_tx_start   = 1'b0;
            ob_tx_payload = 128'd0;
            #1;   // let the combinational lat_valid settle before reading it
            if (lat_valid !== 1'b0) begin
                $display("FAIL: lat_valid still high after pulse deassert");
                fail = 1'b1;
            end
        end
    endtask

    // One-cycle cfg_counter_clear pulse, then wait out the 64-cycle
    // sequential clear sweep it triggers before returning (same reasoning
    // as reset_dut above).
    task clear_pulse;
        begin
            @(negedge clk);
            cfg_counter_clear = 1'b1;
            @(posedge clk);
            #1;
            cfg_counter_clear = 1'b0;
            repeat (70) @(posedge clk);
            #1;
        end
    endtask

    // Read one bucket of `dut`: registered read, one cycle of latency.
    task rd_bucket;
        input [5:0]  idx;
        output [31:0] v;
        begin
            @(negedge clk);
            hist_rd_addr_d = idx;
            @(posedge clk);
            #1;
            v = hist_rd_data;
        end
    endtask

    // Same for the narrow `dut4`.
    task rd_bucket4;
        input [5:0]  idx;
        output [31:0] v;
        begin
            @(negedge clk);
            hist_rd_addr4_d = idx;
            @(posedge clk);
            #1;
            v = hist_rd_data4;
        end
    endtask

    integer i;
    reg [31:0] v;
    reg [31:0] nz;   // nonzero-bucket count

    initial begin
        // ============ H1: T25 single-occupied-bucket property ============
        reset_dut;
        for (i = 0; i < 5; i = i + 1) pulse_ob(8'h10, 16'd11);
        nz = 0;
        for (i = 0; i < 64; i = i + 1) begin
            rd_bucket(i[5:0], v);
            if (v !== 32'd0) begin
                if (v !== 32'd5) begin
                    $display("FAIL: H1 bucket %0d = %0d, expected 5", i, v);
                    fail = 1'b1;
                end else if (i !== 11) begin
                    $display("FAIL: H1 bucket %0d nonzero (expected only 11)", i);
                    fail = 1'b1;
                end
                nz = nz + 1;
            end
        end
        if (nz !== 1) begin
            $display("FAIL: H1 %0d nonzero buckets, expected exactly 1 (NFR-2)", nz);
            fail = 1'b1;
        end

        // ============ H2: distinct latencies, exact buckets ============
        reset_dut;
        pulse_ob(8'h10, 16'd0);
        pulse_ob(8'h10, 16'd10);
        pulse_ob(8'h10, 16'd11);
        pulse_ob(8'h10, 16'd22);
        rd_bucket(6'd0,  v); chk(2000, v, 32'd1);
        rd_bucket(6'd10, v); chk(2001, v, 32'd1);
        rd_bucket(6'd11, v); chk(2002, v, 32'd1);
        rd_bucket(6'd22, v); chk(2003, v, 32'd1);
        rd_bucket(6'd1,  v); chk(2004, v, 32'd0);   // neighbours stay 0
        rd_bucket(6'd9,  v); chk(2005, v, 32'd0);
        rd_bucket(6'd12, v); chk(2006, v, 32'd0);
        rd_bucket(6'd21, v); chk(2007, v, 32'd0);

        // ============ H3: 0x11 reject frames excluded ============
        reset_dut;
        pulse_ob(8'h11, 16'd55);
        if (s_lat_valid !== 1'b0) begin
            $display("FAIL: H3 lat_valid raised by a 0x11 frame");
            fail = 1'b1;
        end
        rd_bucket(6'd55, v); chk(3000, v, 32'd0);
        rd_bucket(6'd63, v); chk(3001, v, 32'd0);
        // and a 0x10 frame afterwards still counts normally
        pulse_ob(8'h10, 16'd55);
        rd_bucket(6'd55, v); chk(3002, v, 32'd1);

        // ============ H4: saturating catch-all bucket 63 ============
        reset_dut;
        pulse_ob(8'h10, 16'd63);
        pulse_ob(8'h10, 16'd64);
        pulse_ob(8'h10, 16'd1000);
        pulse_ob(8'h10, 16'hFFFF);
        rd_bucket(6'd63, v); chk(4000, v, 32'd4);
        rd_bucket(6'd62, v); chk(4001, v, 32'd0);
        rd_bucket(6'd0,  v); chk(4002, v, 32'd0);
        // boundary: 62 is its own exact bucket
        reset_dut;
        pulse_ob(8'h10, 16'd62);
        rd_bucket(6'd62, v); chk(4003, v, 32'd1);
        rd_bucket(6'd63, v); chk(4004, v, 32'd0);

        // ============ H5: per-bucket saturation (narrow BUCKET_W=4) ============
        reset_dut;
        for (i = 0; i < 20; i = i + 1) pulse_ob(8'h10, 16'd2);
        rd_bucket4(6'd2, v);
        chk(5000, v, 32'd15);      // saturates at 15; a wrap would read 4
        rd_bucket4(6'd0, v); chk(5001, v, 32'd0);
        // full-width instance with the same 20 pulses counts exactly 20
        rd_bucket(6'd2, v); chk(5002, v, 32'd20);

        // ============ H6: cfg_counter_clear zeroes all 64 buckets ============
        reset_dut;
        pulse_ob(8'h10, 16'd5);
        pulse_ob(8'h10, 16'd5);
        pulse_ob(8'h10, 16'd10);
        pulse_ob(8'h10, 16'd63);
        rd_bucket(6'd5,  v); chk(6000, v, 32'd2);
        rd_bucket(6'd63, v); chk(6001, v, 32'd1);
        clear_pulse;
        for (i = 0; i < 64; i = i + 1) begin
            rd_bucket(i[5:0], v);
            if (v !== 32'd0) begin
                $display("FAIL: H6 bucket %0d = %0d after clear, expected 0", i, v);
                fail = 1'b1;
            end
        end

        // ============ H7: registered (not combinational) read ============
        reset_dut;
        pulse_ob(8'h10, 16'd5);   // bucket 5 = 1, others 0
        rd_bucket(6'd5, v);       // now hist_rd_data shows bucket 5
        chk(7000, v, 32'd1);
        // change the address: a registered read must hold the old value for
        // one cycle; a combinational read would change immediately
        @(negedge clk);
        hist_rd_addr_d = 6'd0;
        #1;
        if (hist_rd_data !== 32'd1) begin
            $display("FAIL: H7 hist_rd_data changed same-cycle with address (not registered)");
            fail = 1'b1;
        end
        @(posedge clk);
        #1;
        if (hist_rd_data !== 32'd0) begin
            $display("FAIL: H7 hist_rd_data=%0d one cycle after addr change, expected 0", hist_rd_data);
            fail = 1'b1;
        end

        // ============ H8: lat_valid/lat_value pin-compatibility ============
        reset_dut;
        pulse_ob(8'h10, 16'hABC1);   // both high values >= 63
        if (s_lat_valid !== 1'b1) begin
            $display("FAIL: H8 lat_valid not raised during a 0x10 pulse");
            fail = 1'b1;
        end
        chk(8000, s_lat_value, 32'h0000ABC1);
        pulse_ob(8'h10, 16'hFFFE);
        chk(8001, s_lat_value, 32'h0000FFFE);
        rd_bucket(6'd63, v); chk(8002, v, 32'd2);   // ABC1 and FFFE both >= 63

        // ============ H9: increments during the clear sweep are dropped ============
        // Post-audit fix: the write port can only touch one address per
        // cycle (real BRAM has one write port, one address), so
        // cfg_counter_clear/reset now sweep the 64 entries sequentially
        // instead of all at once. A pulse landing inside that ~64-cycle
        // window is dropped, not queued -- this proves that documented
        // behaviour dynamically instead of leaving it as an unverified
        // comment, and confirms a pulse right after the sweep finishes
        // counts normally again.
        //
        // Timing matters here: the pulse must land AFTER the sweep has
        // already passed bucket 40's turn (clear_idx walks 0..63
        // monotonically and never revisits an address), not merely
        // "sometime during clearing" -- a pulse fired before the sweep
        // reaches bucket 40 would have any wrongly-applied increment
        // silently overwritten when the sweep's own walk gets there later,
        // masking a real drop-during-clear bug instead of catching it.
        reset_dut;
        @(negedge clk);
        cfg_counter_clear = 1'b1;
        @(posedge clk);
        #1;
        cfg_counter_clear = 1'b0;
        repeat (45) @(posedge clk);      // clear_idx is now well past 40
        pulse_ob(8'h10, 16'd40);         // fired mid-sweep, past bucket 40's turn
        repeat (25) @(posedge clk);      // let the rest of the sweep finish
        rd_bucket(6'd40, v); chk(9000, v, 32'd0);   // dropped, not counted
        pulse_ob(8'h10, 16'd40);         // now well past the sweep
        rd_bucket(6'd40, v); chk(9001, v, 32'd1);   // counts normally

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
