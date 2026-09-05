`timescale 1ns / 1ps

// Self-checking testbench for rtl/seq_monitor.v (master spec S3.1 [F],
// FR-10/FR-11/FR-12; contract docs/contracts/seq_monitor.md S3).
//
// Icarus:
//   iverilog -g2001 -Wall -o seq_monitor_tb.vvp rtl/seq_monitor.v tb/tb_seq_monitor.v
//   vvp seq_monitor_tb.vvp
//
// seq_monitor reacts to md_parser's three per-message pulses (msg_valid /
// err_msg_type / err_flags -- exactly one fires per completed message) and
// advances a registered expected_seq / seen_first / sticky seq_gap. The
// testbench therefore samples in two halves, matching how the module's
// outputs are actually produced:
//   * the one-cycle verdicts (err_seq_dup, seq_gap_pulse, seq_gap_amount)
//     are combinational for the message's own cycle -- captured at the
//     posedge that ends that cycle (c_* regs below), pre-state-update;
//   * the sticky seq_gap level is registered -- read straight off the net
//     one delta after that posedge.
// Each message is driven for exactly one cycle and followed by one idle
// cycle (end_msg), which also proves no verdict pulse ever lingers.
//
// Directed cases (contract S3), run as one continuous stream so expected_seq
// carries across cases the way it would on a real feed:
//   A  first message ever (arbitrary seq 100): no dup/gap, sticky 0;
//      then a clean run 101..103
//   B  gap via err_msg_type (msg_valid=0): seq jumps +2 -> pulse, amount 2,
//      sticky 1, and the NEXT message (correct next seq) is in-sequence,
//      proving expected_seq tracked the type-invalid message; sticky then
//      persists across further clean messages
//   C  cfg_seq_gap_clear clears the sticky bit with no message activity
//   D  gap via err_flags: same shape, proves the trigger is not msg_valid
//   E  flags.snapshot=1 message clears the sticky bit (in-sequence message)
//   F  gap of 5: seq_gap_amount reports exactly 5, not clamped/off-by-one
//   G  exact-repeat duplicate: err_seq_dup pulses once, expected_seq does
//      not move (next message uses the original next-expected value)
//   H  reorder (older seq, not an exact repeat) is also err_seq_dup
//
// Drives msg_valid/err_msg_type/err_flags/msg_seq_num/msg_flags directly --
// the md_parser-shaped boundary this module's contract is written against.
//
// Verilog-2001 only.

module tb_seq_monitor;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    reg        rst_n = 1'b0;
    reg        msg_valid = 1'b0;
    reg        err_msg_type = 1'b0;
    reg        err_flags = 1'b0;
    reg [31:0] msg_seq_num = 32'd0;
    reg [7:0]  msg_flags = 8'd0;
    reg        cfg_seq_gap_clear = 1'b0;

    wire       err_seq_dup;
    wire [31:0] seq_gap_amount;
    wire       seq_gap_pulse;
    wire       seq_gap;

    seq_monitor dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .msg_valid        (msg_valid),
        .err_msg_type     (err_msg_type),
        .err_flags        (err_flags),
        .msg_seq_num      (msg_seq_num),
        .msg_flags        (msg_flags),
        .cfg_seq_gap_clear(cfg_seq_gap_clear),
        .err_seq_dup      (err_seq_dup),
        .seq_gap_amount   (seq_gap_amount),
        .seq_gap_pulse    (seq_gap_pulse),
        .seq_gap          (seq_gap)
    );

    reg     fail = 1'b0;
    integer tc = 0;             // case counter, for $display context

    // Capture the combinational one-cycle verdicts at the posedge that ends
    // each cycle. Blocking reads at the edge see the pre-update state, so
    // c_* holds the verdict of the cycle that just ended (the same way
    // tb_md_parser's collector counts msg_valid/err_* at posedge).
    reg        c_dup;
    reg        c_gap;
    reg [31:0] c_amount;
    always @(posedge clk) begin
        c_dup    = err_seq_dup;
        c_gap    = seq_gap_pulse;
        c_amount = seq_gap_amount;
    end

    // Drive one message pulse for exactly one clock cycle. State registers
    // update at the posedge inside; on return (posedge + 1ns) the sticky
    // seq_gap net already reflects the post-message state and c_* holds the
    // message's own verdict.
    task fire;
        input [31:0] seq;
        input        v;    // msg_valid
        input        te;   // err_msg_type
        input        fe;   // err_flags
        input [7:0]  fl;   // msg_flags
        begin
            @(negedge clk);
            msg_valid    = v;
            err_msg_type = te;
            err_flags    = fe;
            msg_seq_num  = seq;
            msg_flags    = fl;
            @(posedge clk);
            #1;
        end
    endtask

    // One idle cycle: deassert the message inputs and require every
    // one-cycle verdict to be quiet (proves the pulses don't linger).
    task end_msg;
        begin
            @(negedge clk);
            msg_valid    = 1'b0;
            err_msg_type = 1'b0;
            err_flags    = 1'b0;
            @(posedge clk);
            #1;
            if (c_dup !== 1'b0 || c_gap !== 1'b0 || c_amount !== 32'd0) begin
                $display("FAIL: verdict lingered into idle cycle: c_dup=%b c_gap=%b c_amount=%0d",
                         c_dup, c_gap, c_amount);
                fail = 1'b1;
            end
        end
    endtask

    // Compare the last-fired message's verdicts + post-message sticky level
    // against expectations. On any mismatch, say what was expected vs. what
    // happened, then flag the run.
    task expect;
        input        e_dup;
        input        e_gap;
        input [31:0] e_amount;
        input        e_sticky;
        begin
            tc = tc + 1;
            if (c_dup !== e_dup) begin
                $display("FAIL: case %0d: err_seq_dup=%b, expected %b", tc, c_dup, e_dup);
                fail = 1'b1;
            end
            if (c_gap !== e_gap) begin
                $display("FAIL: case %0d: seq_gap_pulse=%b, expected %b", tc, c_gap, e_gap);
                fail = 1'b1;
            end
            if (c_amount !== e_amount) begin
                $display("FAIL: case %0d: seq_gap_amount=%0d, expected %0d", tc, c_amount, e_amount);
                fail = 1'b1;
            end
            if (seq_gap !== e_sticky) begin
                $display("FAIL: case %0d: seq_gap=%b, expected %b", tc, seq_gap, e_sticky);
                fail = 1'b1;
            end
        end
    endtask

    initial begin
        #20;
        rst_n = 1'b1;
        #20;

        // ---- A: first message ever (no prior expectation -> no dup/gap),
        //      then a clean run. seq=100 with a from-reset expected of 0
        //      would trip a bogus gap in an implementation with no
        //      seen_first guard. ----
        fire(32'd100, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b0);   // first: nothing fires, sticky 0
        end_msg;
        fire(32'd101, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b0);
        end_msg;
        fire(32'd102, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b0);
        end_msg;
        fire(32'd103, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b0);
        end_msg;

        // ---- B: gap via err_msg_type (msg_valid=0). expected=104, seq=106
        //      -> gap of 2. The invalid message still consumes a seq slot:
        //      the next real message at 107 must be in-sequence. Sticky then
        //      persists across 3 more clean messages. ----
        fire(32'd106, 1'b0, 1'b1, 1'b0, 8'd0);
        expect(1'b0, 1'b1, 32'd2, 1'b1);   // pulse, amount 2, sticky set
        end_msg;
        fire(32'd107, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b1);   // in-sequence again (no gap)
        end_msg;
        fire(32'd108, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b1);   // sticky persists
        end_msg;
        fire(32'd109, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b1);   // sticky persists
        end_msg;

        // ---- C: cfg_seq_gap_clear clears the sticky bit independently of
        //      message traffic. ----
        @(negedge clk);
        cfg_seq_gap_clear = 1'b1;
        @(posedge clk);
        #1;
        cfg_seq_gap_clear = 1'b0;
        tc = tc + 1;
        if (seq_gap !== 1'b0) begin
            $display("FAIL: case %0d: cfg clear: seq_gap=%b, expected 0", tc, seq_gap);
            fail = 1'b1;
        end
        end_msg;

        // ---- D: gap via err_flags (msg_valid=0 again). expected=110,
        //      seq=112 -> gap of 2 via the flags path. ----
        fire(32'd112, 1'b0, 1'b0, 1'b1, 8'd0);
        expect(1'b0, 1'b1, 32'd2, 1'b1);
        end_msg;
        fire(32'd113, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b1);   // expected tracked through it
        end_msg;

        // ---- E: flags.snapshot=1 (in-sequence) clears the sticky bit. ----
        fire(32'd114, 1'b1, 1'b0, 1'b0, 8'h02);
        expect(1'b0, 1'b0, 32'd0, 1'b0);   // eq + snapshot -> sticky clears
        end_msg;
        fire(32'd115, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b0);   // and stays clear
        end_msg;

        // ---- F: gap of exactly 5 (well-formed message). expected=116,
        //      seq=121 -> amount must be 5, not clamped and not 4. ----
        fire(32'd121, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b1, 32'd5, 1'b1);
        end_msg;
        fire(32'd122, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b1);
        end_msg;

        // ---- G: exact-repeat duplicate. expected=123, resend 123 ->
        //      err_seq_dup pulses once, expected does not advance (123 still
        //      matches at 124 next). ----
        fire(32'd123, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b1);
        end_msg;
        fire(32'd123, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b1, 1'b0, 32'd0, 1'b1);   // dup pulse, sticky untouched
        end_msg;
        fire(32'd124, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b1);   // original next-expected still right
        end_msg;

        // ---- H: reorder -- an older seq (122) that is NOT an exact repeat
        //      is also err_seq_dup. expected is 125 now. ----
        fire(32'd122, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b1, 1'b0, 32'd0, 1'b1);
        end_msg;
        fire(32'd125, 1'b1, 1'b0, 1'b0, 8'd0);
        expect(1'b0, 1'b0, 32'd0, 1'b1);
        end_msg;

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
