`timescale 1ns / 1ps

// Self-checking testbench for rtl/csr_block.v (master spec S3.1 [M], S9,
// S10, FR-56..58; contract docs/contracts/csr_block.md).
//
// Icarus:
//   iverilog -g2001 -Wall -o csr_block_tb.vvp rtl/csr_block.v tb/tb_csr_block.v
//   vvp csr_block_tb.vvp
//
// csr_block.v is the control plane: it byte-serial decodes the same
// in_data/in_valid stream md_parser.v consumes, recognizing 0x20 (write)
// and 0x21 (read-request) CSR frames; it is the single source of truth for
// every cfg_* register and the single accumulator for every pulse counter.
// A 0x22 read-response is emitted on its own resp_payload/resp_start/
// resp_busy interface (not eth_mac_if's -- D19 point 2), gated so a read
// arriving while resp_busy is silently dropped.
//
// Driving model (mirrors tb_md_parser.v's byte-serial send task + the
// order_builder tb's cycle discipline): each 16-byte frame is pushed on
// in_data/in_valid back-to-back; the module's csr_complete_d/csr_write_valid/
// csr_read_valid pulse lands exactly one cycle after byte 15 (cycle "F"),
// so a write's register effect and a read's response are both observable
// one posedge after the frame's last byte. The resp_busy stand-in models
// eth_mac_if.v's documented one-cycle lag (the same shape tb_order_builder.v
// used for tx_busy) so reads issued on the cycle right after a response
// would be seen as "while busy" and dropped.
//
// Cases (contract S3):
//   C1    T24 round-trip: write/read every writable register in S2.3's
//         table, confirm CSR read-back AND the cfg_* output actually
//         changed; defaults read back correctly after reset; field masking
//         (narrow regs) and CTRL read-back (self-clearing bits read 0)
//   C2    CTRL self-clearing: bit1/2/3 each pulse exactly one cycle and
//         never read back 1; plain bit0/bit4 persist
//   C3    counter accumulation + no cross-talk: pulse each of the 35
//         counters' triggers once against a reference tally, read all 35
//         back and compare
//   C4    counter saturation at 0xFFFFFFFF (force near the top)
//   C5    counter_clear: counters -> 0 and STATUS bits 1-4 -> 0, EXCEPT
//         lat_min/lat_max which reset to their identity extremes (not 0)
//   C6    cnt_orders_tx counts 0x10 frames only, never 0x11 rejects
//   C7    STATUS bit0 live-mirrors kill_latched; bits 1-4 sticky until
//         counter_clear_pulse; bits 7:5 always 0
//   C8    a read issued while resp_busy is dropped silently (no resp_start,
//         no state corruption); a later read still works
//   C9    market-data-shaped traffic (0x01/0x02/0x03/0xFF) on the shared
//         stream never fires a CSR write/read and changes nothing
//   C10   genuinely unmapped address (0x200): write is a silent no-op, read
//         returns 0, nothing else disturbed (the 0x138 histogram base now
//         reads bucket data, see C13/C15)
//   C11   STATUS bit2 re-latches while `crossed` is held (D20)
//
// D21/D22 patch cases (docs/contracts/csr_block_patch.md), tested against a
// behavioral stand-in for latency_histogram.v's registered read port (the
// real latency_histogram.v is NOT instantiated here):
//   C12   counter_clear_pulse is a real output port, one-cycle, matching C2
//   C13   CSR reads of 0x138-0x234 return the histogram bucket the address
//         maps to (hist_rd_addr translation + hist_rd_data wiring together)
//   C14   two back-to-back histogram reads at different addresses each
//         return their own bucket (catches hist_rd_addr gated on
//         csr_read_valid instead of driven continuously); a market-data
//         frame interleaved between the reads does not corrupt the second
//   C15   boundary addresses: 0x134 (lat_last, below the range) unchanged,
//         0x238 (above the range) still reads 0 via the default arm
//
// On any mismatch a FAIL line names the register/address and expected vs
// actual; a final PASS/FAIL line summarizes. Verilog-2001 only.

module tb_csr_block;

    reg clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz

    // ===================== DUT inputs =====================
    reg        rst_n = 1'b0;

    // CSR ingress byte stream
    reg [7:0]  in_data  = 8'd0;
    reg        in_valid = 1'b0;

    // CSR egress backpressure (stand-in models one-cycle lag)
    reg        resp_force_busy = 1'b0;
    reg [15:0] resp_busy_hold  = 16'd1;
    reg        resp_lag_busy;
    reg [15:0] resp_busy_rem;
    wire       resp_busy = resp_force_busy | resp_lag_busy;

    // STATUS-feeding level inputs
    reg        kill_latched = 1'b0;
    reg        seq_gap      = 1'b0;
    reg [3:0]  crossed      = 4'd0;

    // pulse inputs (each of the below is high for exactly the cycles the
    // test drives it)
    reg        frame_start;
    reg        err_frame_len;
    reg        md_msg_valid;
    reg        err_msg_type;
    reg        err_flags;
    reg        err_fcs;
    reg        err_ethertype;
    reg        err_ip;
    reg        err_udp_port;
    reg        filt_valid;
    reg        filt_dropped;
    reg        err_seq_dup;
    reg        seq_gap_pulse;
    reg        cnt_book_clear_pulse;
    reg        cnt_trades_pulse;
    reg        cnt_heartbeats_pulse;
    reg        cnt_crossed_pulse;
    reg        sig_valid;
    reg [7:0]  sig_side;
    reg        err_signal_conflict;
    reg        ml_event_valid;
    reg        ml_adverse_pulse;
    reg        ml_benign_pulse;
    reg        ml_safe_forced_pulse;
    reg        gate_kill_fired;
    reg        gate_size_fired;
    reg        gate_position_fired;
    reg        gate_band_fired;
    reg        gate_stale_fired;
    reg        gate_seqgap_fired;
    reg        gate_crossed_fired;
    reg        gate_throttle_fired;
    reg        gate_ml_fired;
    reg        ob_tx_start;
    reg [127:0] ob_tx_payload;
    reg        cnt_order_overflow_pulse;
    reg        lat_valid;
    reg [15:0] lat_value;

    // ===================== DUT outputs =====================
    wire [127:0] resp_payload;
    wire         resp_start;
    wire [7:0]   cfg_symbol_0, cfg_symbol_1, cfg_symbol_2, cfg_symbol_3;
    wire [3:0]   cfg_symbol_en;
    wire [31:0]  cfg_min_spread;
    wire [1:0]   cfg_imb_shift;
    wire [31:0]  cfg_order_qty;
    wire [31:0]  cfg_max_order_qty;
    wire [31:0]  cfg_max_position;
    wire [31:0]  cfg_price_band;
    wire [31:0]  cfg_max_age;
    wire [31:0]  cfg_token_max;
    wire [31:0]  cfg_token_refill_cycles;
    wire         cfg_ml_action;
    wire [3:0]   cfg_ml_reduce_shift;
    wire         cfg_kill_clear;
    wire         cfg_reject_report;
    wire         cfg_seq_gap_clear;
    wire         ml_bypass;
    wire [31:0]  cfg_offset_0, cfg_shift_0, cfg_offset_1, cfg_shift_1;
    wire [31:0]  cfg_offset_2, cfg_shift_2, cfg_offset_3, cfg_shift_3;
    wire [31:0]  cfg_offset_4, cfg_shift_4, cfg_offset_5, cfg_shift_5;
    wire [31:0]  cfg_offset_6, cfg_shift_6, cfg_offset_7, cfg_shift_7;
    wire         cfg_enable;
    wire [15:0]  cfg_udp_port;
    wire [31:0]  cfg_stats_period;
    wire signed [31:0] cfg_ml_th_high, cfg_ml_th_low;
    wire [31:0]  cfg_ml_score_offset, cfg_ml_score_shift, cfg_ml_window;
    wire         counter_clear_pulse;
    wire [5:0]   hist_rd_addr;
    reg  [31:0]  hist_rd_data;

    csr_block #(.NUM_SYMBOLS(4)) dut (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .in_data                (in_data),
        .in_valid               (in_valid),
        .resp_payload           (resp_payload),
        .resp_start             (resp_start),
        .resp_busy              (resp_busy),
        .cfg_symbol_0           (cfg_symbol_0),
        .cfg_symbol_1           (cfg_symbol_1),
        .cfg_symbol_2           (cfg_symbol_2),
        .cfg_symbol_3           (cfg_symbol_3),
        .cfg_symbol_en          (cfg_symbol_en),
        .cfg_min_spread         (cfg_min_spread),
        .cfg_imb_shift          (cfg_imb_shift),
        .cfg_order_qty          (cfg_order_qty),
        .cfg_max_order_qty      (cfg_max_order_qty),
        .cfg_max_position       (cfg_max_position),
        .cfg_price_band         (cfg_price_band),
        .cfg_max_age            (cfg_max_age),
        .cfg_token_max          (cfg_token_max),
        .cfg_token_refill_cycles(cfg_token_refill_cycles),
        .cfg_ml_action          (cfg_ml_action),
        .cfg_ml_reduce_shift    (cfg_ml_reduce_shift),
        .cfg_kill_clear         (cfg_kill_clear),
        .cfg_reject_report      (cfg_reject_report),
        .cfg_seq_gap_clear      (cfg_seq_gap_clear),
        .cfg_offset_0           (cfg_offset_0),
        .cfg_shift_0            (cfg_shift_0),
        .cfg_offset_1           (cfg_offset_1),
        .cfg_shift_1            (cfg_shift_1),
        .cfg_offset_2           (cfg_offset_2),
        .cfg_shift_2            (cfg_shift_2),
        .cfg_offset_3           (cfg_offset_3),
        .cfg_shift_3            (cfg_shift_3),
        .cfg_offset_4           (cfg_offset_4),
        .cfg_shift_4            (cfg_shift_4),
        .cfg_offset_5           (cfg_offset_5),
        .cfg_shift_5            (cfg_shift_5),
        .cfg_offset_6           (cfg_offset_6),
        .cfg_shift_6            (cfg_shift_6),
        .cfg_offset_7           (cfg_offset_7),
        .cfg_shift_7            (cfg_shift_7),
        .cfg_enable             (cfg_enable),
        .cfg_udp_port           (cfg_udp_port),
        .cfg_stats_period       (cfg_stats_period),
        .cfg_ml_th_high         (cfg_ml_th_high),
        .cfg_ml_th_low          (cfg_ml_th_low),
        .cfg_ml_score_offset    (cfg_ml_score_offset),
        .cfg_ml_score_shift     (cfg_ml_score_shift),
        .cfg_ml_window          (cfg_ml_window),
        .ml_bypass              (ml_bypass),
        .kill_latched           (kill_latched),
        .seq_gap                (seq_gap),
        .crossed                (crossed),
        .frame_start            (frame_start),
        .err_frame_len          (err_frame_len),
        .md_msg_valid           (md_msg_valid),
        .err_msg_type           (err_msg_type),
        .err_flags              (err_flags),
        .err_fcs                (err_fcs),
        .err_ethertype          (err_ethertype),
        .err_ip                 (err_ip),
        .err_udp_port           (err_udp_port),
        .filt_valid             (filt_valid),
        .filt_dropped           (filt_dropped),
        .err_seq_dup            (err_seq_dup),
        .seq_gap_pulse          (seq_gap_pulse),
        .cnt_book_clear_pulse   (cnt_book_clear_pulse),
        .cnt_trades_pulse       (cnt_trades_pulse),
        .cnt_heartbeats_pulse   (cnt_heartbeats_pulse),
        .cnt_crossed_pulse      (cnt_crossed_pulse),
        .sig_valid              (sig_valid),
        .sig_side               (sig_side),
        .err_signal_conflict    (err_signal_conflict),
        .ml_event_valid         (ml_event_valid),
        .ml_adverse_pulse       (ml_adverse_pulse),
        .ml_benign_pulse        (ml_benign_pulse),
        .ml_safe_forced_pulse   (ml_safe_forced_pulse),
        .gate_kill_fired        (gate_kill_fired),
        .gate_size_fired        (gate_size_fired),
        .gate_position_fired    (gate_position_fired),
        .gate_band_fired        (gate_band_fired),
        .gate_stale_fired       (gate_stale_fired),
        .gate_seqgap_fired      (gate_seqgap_fired),
        .gate_crossed_fired     (gate_crossed_fired),
        .gate_throttle_fired    (gate_throttle_fired),
        .gate_ml_fired          (gate_ml_fired),
        .ob_tx_start            (ob_tx_start),
        .ob_tx_payload          (ob_tx_payload),
        .cnt_order_overflow_pulse (cnt_order_overflow_pulse),
        .lat_valid              (lat_valid),
        .lat_value              (lat_value),
        .counter_clear_pulse    (counter_clear_pulse),
        .hist_rd_addr           (hist_rd_addr),
        .hist_rd_data           (hist_rd_data)
    );

    // ---- behavioral stand-in for latency_histogram.v's registered read
    //      port (one cycle of lag from hist_rd_addr to hist_rd_data -- the
    //      same discipline as the resp_busy stand-in: an idealized
    //      same-cycle model would hide the very timing bug this patch's
    //      continuous hist_rd_addr drive exists to prevent).
    reg [31:0] hist_mem_stub [0:63];
    always @(posedge clk)
        hist_rd_data <= hist_mem_stub[hist_rd_addr];

    // Capture every 0x22 response for the back-to-back read case (C14).
    reg [127:0] resp_queue [0:7];
    integer     resp_n;
    always @(posedge clk) begin
        if (resp_start && resp_n < 8) begin
            resp_queue[resp_n] = resp_payload;
            resp_n = resp_n + 1;
        end
    end

    // ---- resp_busy behavioral stand-in: one-cycle lag after resp_start,
    //      like eth_mac_if.v's tx_busy after tx_start (order_builder S2.5
    //      shape). resp_force_busy holds busy for the drop test.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_lag_busy <= 1'b0;
            resp_busy_rem <= 16'd0;
        end else if (resp_lag_busy) begin
            if (resp_busy_rem == 16'd0) resp_lag_busy <= 1'b0;
            else                        resp_busy_rem <= resp_busy_rem - 16'd1;
        end else if (resp_start) begin
            resp_lag_busy <= 1'b1;
            resp_busy_rem <= resp_busy_hold - 16'd1;
        end
    end

    // ===================== helpers =====================

    reg fail = 1'b0;

    task chk;
        input integer  tag;
        input [31:0]   got;
        input [31:0]   exp;
        begin
            if (got !== exp) begin
                $display("FAIL: %0d: got %08x, expected %08x", tag, got, exp);
                fail = 1'b1;
            end
        end
    endtask

    // Deassert every transient pulse/data input. Level inputs (kill_latched,
    // seq_gap, crossed, force_busy, sig_side, ob_tx_payload) are left alone.
    task all0;
        begin
            in_valid              = 1'b0;
            frame_start           = 1'b0;
            err_frame_len         = 1'b0;
            md_msg_valid          = 1'b0;
            err_msg_type          = 1'b0;
            err_flags             = 1'b0;
            err_fcs               = 1'b0;
            err_ethertype         = 1'b0;
            err_ip                = 1'b0;
            err_udp_port          = 1'b0;
            filt_valid            = 1'b0;
            filt_dropped          = 1'b0;
            err_seq_dup           = 1'b0;
            seq_gap_pulse         = 1'b0;
            cnt_book_clear_pulse  = 1'b0;
            cnt_trades_pulse      = 1'b0;
            cnt_heartbeats_pulse  = 1'b0;
            cnt_crossed_pulse     = 1'b0;
            sig_valid             = 1'b0;
            err_signal_conflict   = 1'b0;
            ml_event_valid        = 1'b0;
            ml_adverse_pulse      = 1'b0;
            ml_benign_pulse       = 1'b0;
            ml_safe_forced_pulse  = 1'b0;
            gate_kill_fired       = 1'b0;
            gate_size_fired       = 1'b0;
            gate_position_fired   = 1'b0;
            gate_band_fired       = 1'b0;
            gate_stale_fired      = 1'b0;
            gate_seqgap_fired     = 1'b0;
            gate_crossed_fired    = 1'b0;
            gate_throttle_fired   = 1'b0;
            gate_ml_fired         = 1'b0;
            ob_tx_start           = 1'b0;
            cnt_order_overflow_pulse = 1'b0;
            lat_valid             = 1'b0;
        end
    endtask

    // Push one 16-byte big-endian CSR frame onto in_data/in_valid.
    // Returns one cycle after byte 15 has been latched (i.e. in the cycle
    // where the module's csr_write_valid/csr_read_valid is high).
    task csr_frame;
        input [7:0]  mt;
        input [15:0] addr;
        input [31:0] data;
        reg [127:0] frame;
        integer i;
        begin
            frame = {mt, 8'h00, addr, data, 64'd0};
            for (i = 0; i < 16; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_data  = frame[127 - 8*i -: 8];
            end
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    // Push one frame's 16 bytes but LEAVE in_valid high, returning right
    // after byte 15 is set -- so the next push16/end_stream call continues
    // the byte stream with NO gap between frames (C14's back-to-back case).
    task push16;
        input [7:0]  mt;
        input [15:0] addr;
        input [31:0] data;
        reg [127:0] frame;
        integer i;
        begin
            frame = {mt, 8'h00, addr, data, 64'd0};
            for (i = 0; i < 16; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_data  = frame[127 - 8*i -: 8];
            end
        end
    endtask

    // Drop in_valid after the final push16 (the last byte still gets one
    // full cycle of in_valid before this runs).
    task end_stream;
        begin
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    // Close the write/read-valid cycle: cfg register writes commit and a
    // read response is presented (resp_start high right after this).
    task settle;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Write a register via a 0x20 frame, then let it take effect.
    task csr_write;
        input [15:0] addr;
        input [31:0] data;
        begin
            csr_frame(8'h20, addr, data);
            settle;
        end
    endtask

    // Read a register via a 0x21/0x22 round trip. Returns the data field.
    // Fails (but returns 0) if no response arrives -- e.g. busy-drop.
    task csr_read;
        input  [15:0] addr;
        output [31:0] rd;
        begin
            csr_frame(8'h21, addr, 32'd0);
            settle;
            if (resp_start !== 1'b1) begin
                $display("FAIL: no 0x22 response for read of %04x", addr);
                fail = 1'b1;
                rd = 32'd0;
            end else begin
                if (resp_payload[127:120] !== 8'h22) begin
                    $display("FAIL: read of %04x: response msg_type=%02x, expected 22", addr, resp_payload[127:120]);
                    fail = 1'b1;
                end
                if (resp_payload[111:96] !== addr) begin
                    $display("FAIL: read of %04x: addr echo=%04x", addr, resp_payload[111:96]);
                    fail = 1'b1;
                end
                rd = resp_payload[95:64];
            end
            @(posedge clk);
            #1;
            if (resp_start !== 1'b0) begin
                $display("FAIL: resp_start not a one-cycle pulse after read of %04x", addr);
                fail = 1'b1;
            end
        end
    endtask

    // Assert + release reset with all transients/levels quiet.
    task reset_dut;
        begin
            @(negedge clk);
            all0;
            kill_latched    = 1'b0;
            seq_gap         = 1'b0;
            crossed         = 4'd0;
            sig_side        = 8'd0;
            ob_tx_payload   = 128'd0;
            resp_force_busy = 1'b0;
            resp_n          = 0;
            rst_n = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    // Deassert reset too (used once before the first test).
    task release_reset;
        begin
            @(negedge clk);
            all0;
            kill_latched    = 1'b0;
            seq_gap         = 1'b0;
            crossed         = 4'd0;
            sig_side        = 8'd0;
            ob_tx_payload   = 128'd0;
            resp_force_busy = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    // ---- the writable config register table (S2.3, addresses 0x08..0x9C;
    //      CTRL 0x00 and STATUS 0x04 are tested separately) ----
    localparam integer N_CFG = 38;
    reg [15:0] ca [0:N_CFG-1];
    reg [31:0] cd [0:N_CFG-1];   // reset defaults
    reg [31:0] cw [0:N_CFG-1];   // test write values

    // Field width mask for a config address (what read-back/zero-extension
    // must produce for a full-width write).
    function [31:0] cfg_mask;
        input [15:0] a;
        begin
            case (a)
                16'h0008, 16'h000C, 16'h0010, 16'h0014: cfg_mask = 32'h000000FF;
                16'h0018:                              cfg_mask = 32'h0000000F;
                16'h0020:                              cfg_mask = 32'h00000003;
                16'h0040:                              cfg_mask = 32'h0000FFFF;
                16'h0050:                              cfg_mask = 32'h000001FF; // ML_CTRL packed
                default:                               cfg_mask = 32'hFFFFFFFF;
            endcase
        end
    endfunction

    // View the module's live cfg_* OUTPUT for an address, right-aligned to
    // the 32-bit read-back format -- so the test checks the actual output
    // ports changed, not just internal storage.
    function [31:0] cfg_view;
        input [15:0] a;
        begin
            case (a)
                16'h0008:  cfg_view = {24'd0, cfg_symbol_0};
                16'h000C:  cfg_view = {24'd0, cfg_symbol_1};
                16'h0010:  cfg_view = {24'd0, cfg_symbol_2};
                16'h0014:  cfg_view = {24'd0, cfg_symbol_3};
                16'h0018:  cfg_view = {28'd0, cfg_symbol_en};
                16'h001C:  cfg_view = cfg_min_spread;
                16'h0020:  cfg_view = {30'd0, cfg_imb_shift};
                16'h0024:  cfg_view = cfg_order_qty;
                16'h0028:  cfg_view = cfg_max_order_qty;
                16'h002C:  cfg_view = cfg_max_position;
                16'h0030:  cfg_view = cfg_price_band;
                16'h0034:  cfg_view = cfg_max_age;
                16'h0038:  cfg_view = cfg_token_max;
                16'h003C:  cfg_view = cfg_token_refill_cycles;
                16'h0040:  cfg_view = {16'd0, cfg_udp_port};
                16'h0044:  cfg_view = cfg_stats_period;
                16'h0048:  cfg_view = cfg_ml_th_high[31:0];
                16'h004C:  cfg_view = cfg_ml_th_low[31:0];
                16'h0050:  cfg_view = {23'd0, ml_bypass, 3'b000, cfg_ml_reduce_shift, cfg_ml_action};
                16'h0054:  cfg_view = cfg_ml_score_offset;
                16'h0058:  cfg_view = cfg_ml_score_shift;
                16'h005C:  cfg_view = cfg_ml_window;
                16'h0060:  cfg_view = cfg_offset_0;
                16'h0064:  cfg_view = cfg_offset_1;
                16'h0068:  cfg_view = cfg_offset_2;
                16'h006C:  cfg_view = cfg_offset_3;
                16'h0070:  cfg_view = cfg_offset_4;
                16'h0074:  cfg_view = cfg_offset_5;
                16'h0078:  cfg_view = cfg_offset_6;
                16'h007C:  cfg_view = cfg_offset_7;
                16'h0080:  cfg_view = cfg_shift_0;
                16'h0084:  cfg_view = cfg_shift_1;
                16'h0088:  cfg_view = cfg_shift_2;
                16'h008C:  cfg_view = cfg_shift_3;
                16'h0090:  cfg_view = cfg_shift_4;
                16'h0094:  cfg_view = cfg_shift_5;
                16'h0098:  cfg_view = cfg_shift_6;
                16'h009C:  cfg_view = cfg_shift_7;
                default:   cfg_view = 32'h0;
            endcase
        end
    endfunction

    // fill the config table once
    task fill_table;
        integer i;
        begin
            ca[0]=16'h0008; cd[0]=32'd1;               cw[0]=32'h0000005A;
            ca[1]=16'h000C; cd[1]=32'd2;               cw[1]=32'h000000A5;
            ca[2]=16'h0010; cd[2]=32'd3;               cw[2]=32'h0000003C;
            ca[3]=16'h0014; cd[3]=32'd4;               cw[3]=32'h000000C3;
            ca[4]=16'h0018; cd[4]=32'hF;               cw[4]=32'h0000000A;
            ca[5]=16'h001C; cd[5]=32'd2;               cw[5]=32'h0000000A;
            ca[6]=16'h0020; cd[6]=32'd1;               cw[6]=32'h00000003;
            ca[7]=16'h0024; cd[7]=32'd100;             cw[7]=32'h00000123;
            ca[8]=16'h0028; cd[8]=32'd500;             cw[8]=32'h00000FA0;
            ca[9]=16'h002C; cd[9]=32'd1000;            cw[9]=32'h00002710;
            ca[10]=16'h0030; cd[10]=32'd50;            cw[10]=32'h000000C8;
            ca[11]=16'h0034; cd[11]=32'd1250000;       cw[11]=32'h00012345;
            ca[12]=16'h0038; cd[12]=32'd8;             cw[12]=32'h0000000F;
            ca[13]=16'h003C; cd[13]=32'd12500;         cw[13]=32'h00000BB8;
            ca[14]=16'h0040; cd[14]=32'd60000;         cw[14]=32'h00009C40;
            ca[15]=16'h0044; cd[15]=32'd12500000;      cw[15]=32'h00BEBE20;
            ca[16]=16'h0048; cd[16]=32'd0;             cw[16]=32'h00001000;
            ca[17]=16'h004C; cd[17]=32'd0;             cw[17]=32'hFFFFF000;
            ca[18]=16'h0050; cd[18]=32'd0;             cw[18]=32'h00000113;
            ca[19]=16'h0054; cd[19]=32'd0;             cw[19]=32'h00000020;
            ca[20]=16'h0058; cd[20]=32'd0;             cw[20]=32'h00000008;
            ca[21]=16'h005C; cd[21]=32'd16;            cw[21]=32'h00000020;
            for (i = 0; i < 8; i = i + 1) begin
                ca[22+i]  = 16'h0060 + (i << 2);   // 0x60,0x64,...,0x7C
                ca[30+i]  = 16'h0080 + (i << 2);   // 0x80,0x84,...,0x9C
                cd[22+i]  = 32'd0;
                cd[30+i]  = 32'd0;
                cw[22+i]  = 32'h00000100 + i;
                cw[30+i]  = 32'h00000011 + i;
            end
        end
    endtask

    // ===================== reference model for the 35 counters =====================
    localparam integer N_CNT = 35;
    localparam integer C_FRAMES_RX=0, C_MSGS_RX=1, C_MSGS_FILTERED=2, C_MSGS_ACCEPTED=3,
                      C_ERR_FCS=4, C_ERR_ETHERTYPE=5, C_ERR_IP=6, C_ERR_UDP=7,
                      C_ERR_FRAME_LEN=8, C_ERR_MSG_TYPE=9, C_ERR_FLAGS=10,
                      C_ERR_SIG_CONF=11, C_SEQ_GAP=12, C_SEQ_DUP=13, C_CROSSED=14,
                      C_BOOK_CLEAR=15, C_TRADES=16, C_HEARTBEATS=17,
                      C_SIG_BUY=18, C_SIG_SELL=19,
                      C_ML_EVENTS=20, C_ML_ADVERSE=21, C_ML_BENIGN=22, C_ML_SAFE=23,
                      C_REJ_KILL=24, C_REJ_SIZE=25, C_REJ_POSITION=26, C_REJ_BAND=27,
                      C_REJ_STALE=28, C_REJ_SEQGAP=29, C_REJ_CROSSED=30,
                      C_REJ_THROTTLE=31, C_REJ_ML=32,
                      C_ORDERS_TX=33, C_ORDER_OVERFLOW=34;
    integer ref [0:N_CNT-1];

    // Raise one counter's trigger for exactly one clock and update ref[].
    // idx follows the S2.5 table order.
    task pulse_one;
        input integer idx;
        begin
            @(negedge clk);
            all0;
            case (idx)
                C_FRAMES_RX:    frame_start = 1'b1;
                C_MSGS_RX:      md_msg_valid = 1'b1;
                C_MSGS_FILTERED: filt_dropped = 1'b1;
                C_MSGS_ACCEPTED: filt_valid = 1'b1;
                C_ERR_FCS:      err_fcs = 1'b1;
                C_ERR_ETHERTYPE: err_ethertype = 1'b1;
                C_ERR_IP:       err_ip = 1'b1;
                C_ERR_UDP:      err_udp_port = 1'b1;
                C_ERR_FRAME_LEN: err_frame_len = 1'b1;
                C_ERR_MSG_TYPE: err_msg_type = 1'b1;
                C_ERR_FLAGS:    err_flags = 1'b1;
                C_ERR_SIG_CONF: err_signal_conflict = 1'b1;
                C_SEQ_GAP:      seq_gap_pulse = 1'b1;
                C_SEQ_DUP:      err_seq_dup = 1'b1;
                C_CROSSED:      cnt_crossed_pulse = 1'b1;
                C_BOOK_CLEAR:   cnt_book_clear_pulse = 1'b1;
                C_TRADES:       cnt_trades_pulse = 1'b1;
                C_HEARTBEATS:   cnt_heartbeats_pulse = 1'b1;
                C_SIG_BUY:      begin sig_valid = 1'b1; sig_side = 8'h00; end
                C_SIG_SELL:     begin sig_valid = 1'b1; sig_side = 8'h01; end
                C_ML_EVENTS:    ml_event_valid = 1'b1;
                C_ML_ADVERSE:   ml_adverse_pulse = 1'b1;
                C_ML_BENIGN:    ml_benign_pulse = 1'b1;
                C_ML_SAFE:      ml_safe_forced_pulse = 1'b1;
                C_REJ_KILL:     gate_kill_fired = 1'b1;
                C_REJ_SIZE:     gate_size_fired = 1'b1;
                C_REJ_POSITION: gate_position_fired = 1'b1;
                C_REJ_BAND:     gate_band_fired = 1'b1;
                C_REJ_STALE:    gate_stale_fired = 1'b1;
                C_REJ_SEQGAP:   gate_seqgap_fired = 1'b1;
                C_REJ_CROSSED:  gate_crossed_fired = 1'b1;
                C_REJ_THROTTLE: gate_throttle_fired = 1'b1;
                C_REJ_ML:       gate_ml_fired = 1'b1;
                C_ORDERS_TX:    begin ob_tx_start = 1'b1;
                                       ob_tx_payload = {8'h10, 120'd0}; end
                C_ORDER_OVERFLOW: cnt_order_overflow_pulse = 1'b1;
                default: $display("FAIL: pulse_one bad idx %0d", idx);
            endcase
            @(posedge clk);
            #1;
            all0;
            ob_tx_payload = 128'd0;
            // reference tally -- which counters this trigger increments
            case (idx)
                C_ERR_MSG_TYPE: begin ref[C_ERR_MSG_TYPE] = ref[C_ERR_MSG_TYPE] + 1;
                                      ref[C_MSGS_RX]      = ref[C_MSGS_RX] + 1; end
                C_ERR_FLAGS:    begin ref[C_ERR_FLAGS] = ref[C_ERR_FLAGS] + 1;
                                      ref[C_MSGS_RX]    = ref[C_MSGS_RX] + 1; end
                default:        ref[idx] = ref[idx] + 1;
            endcase
        end
    endtask

    // Read counter idx over CSR and compare against ref[idx].
    task read_cnt_chk;
        input integer tag;
        input integer idx;
        reg [31:0] v;
        reg [15:0] a;
        begin
            a = 16'h00A0 + (idx << 2);
            csr_read(a, v);
            chk(tag, v, ref[idx][31:0]);
        end
    endtask

    // ===================== driver =====================
    integer i, j, s_i;
    reg [31:0] rv;
    integer any;

    initial begin
        fill_table;
        // initialize the histogram stand-in with a distinct pattern per
        // bucket so a wrong bucket index is immediately visible
        for (s_i = 0; s_i < 64; s_i = s_i + 1)
            hist_mem_stub[s_i] = 32'hCAFE_0000 | s_i[5:0];
        release_reset;

        // ============ C1: T24 register round-trip + defaults + cfg outputs ============
        // reset defaults read back correctly
        reset_dut;
        for (i = 0; i < N_CFG; i = i + 1) begin
            csr_read(ca[i], rv);
            chk(1000 + i, rv, cd[i] & cfg_mask(ca[i]));
        end
        // CTRL reads 0, STATUS reads 0 out of reset
        csr_read(16'h0000, rv);  chk(1100, rv, 32'd0);
        csr_read(16'h0004, rv);  chk(1101, rv, 32'd0);
        // write every writable register, verify read-back AND the cfg_* output
        for (i = 0; i < N_CFG; i = i + 1) begin
            csr_write(ca[i], cw[i]);
            csr_read(ca[i], rv);
            chk(1200 + i, rv, cw[i] & cfg_mask(ca[i]));
            chk(1300 + i, cfg_view(ca[i]), cw[i] & cfg_mask(ca[i]));
        end
        // representative direct port checks (the S3 T24 gate, spelled out)
        if (cfg_max_order_qty !== 32'hFA0) begin $display("FAIL: cfg_max_order_qty=%h exp FA0", cfg_max_order_qty); fail = 1'b1; end
        if (cfg_symbol_0 !== 8'h5A) begin $display("FAIL: cfg_symbol_0=%h exp 5A", cfg_symbol_0); fail = 1'b1; end
        if (cfg_ml_action !== 1'b1) begin $display("FAIL: cfg_ml_action=%b exp 1", cfg_ml_action); fail = 1'b1; end
        if (cfg_ml_reduce_shift !== 4'd9) begin $display("FAIL: cfg_ml_reduce_shift=%d exp 9", cfg_ml_reduce_shift); fail = 1'b1; end
        if (ml_bypass !== 1'b1) begin $display("FAIL: ml_bypass=%b exp 1", ml_bypass); fail = 1'b1; end
        // narrow-field masking: a too-wide write to SYMBOL_0 is truncated
        csr_write(16'h0008, 32'h0000_01FF);
        csr_read(16'h0008, rv);
        chk(1400, rv, 32'h000000FF);
        if (cfg_symbol_0 !== 8'hFF) begin $display("FAIL: cfg_symbol_0=%h exp FF (truncated)", cfg_symbol_0); fail = 1'b1; end

        // ============ C2: CTRL self-clearing bits ============
        reset_dut;
        csr_frame(8'h20, 16'h0000, 32'h0000_001F);   // bits 4,3,2,1,0 all set
        // now in the write-valid cycle (F): all three pulses high for exactly
        // this one cycle
        #1;
        if (cfg_kill_clear    !== 1'b1) begin $display("FAIL: C2 kill_clear not high in F"); fail = 1'b1; end
        if (cfg_seq_gap_clear !== 1'b1) begin $display("FAIL: C2 seq_gap_clear not high in F"); fail = 1'b1; end
        if (dut.counter_clear_pulse !== 1'b1) begin $display("FAIL: C2 counter_clear_pulse not high in F"); fail = 1'b1; end
        settle;
        // pulses are one-shot: gone now
        if (cfg_kill_clear !== 1'b0) begin $display("FAIL: C2 kill_clear still high after settle"); fail = 1'b1; end
        if (cfg_seq_gap_clear !== 1'b0) begin $display("FAIL: C2 seq_gap_clear still high after settle"); fail = 1'b1; end
        if (dut.counter_clear_pulse !== 1'b0) begin $display("FAIL: C2 counter_clear_pulse still high after settle"); fail = 1'b1; end
        // plain level bits persisted; self-clearing bits read back 0
        if (cfg_enable !== 1'b1) begin $display("FAIL: C2 cfg_enable=%b exp 1", cfg_enable); fail = 1'b1; end
        if (cfg_reject_report !== 1'b1) begin $display("FAIL: C2 cfg_reject_report=%b exp 1", cfg_reject_report); fail = 1'b1; end
        csr_read(16'h0000, rv);
        chk(2000, rv, 32'h00000011);
        // a CTRL write WITHOUT the self-clearing bits pulses nothing
        csr_write(16'h0000, 32'h0000_0011);
        csr_read(16'h0000, rv);
        chk(2001, rv, 32'h00000011);

        // ============ C3: counter accumulation, one pulse per trigger ============
        reset_dut;
        for (j = 0; j < N_CNT; j = j + 1) ref[j] = 0;
        for (i = 0; i < N_CNT; i = i + 1) pulse_one(i);
        for (i = 0; i < N_CNT; i = i + 1) read_cnt_chk(3000 + i, i);

        // ============ C4: counter saturation ============
        reset_dut;
        // force one counter just below the top, release, then pulse twice:
        // first reaches 0xFFFFFFFF, second must saturate (never wrap)
        force dut.cnt_frames_rx = 32'hFFFFFFFE;
        #1;
        release dut.cnt_frames_rx;
        #1;
        pulse_one(C_FRAMES_RX);
        pulse_one(C_FRAMES_RX);
        csr_read(16'h00A0, rv);
        chk(4000, rv, 32'hFFFFFFFF);
        // clear back to 0
        csr_write(16'h0000, 32'h0000_0004);
        csr_read(16'h00A0, rv);
        chk(4001, rv, 32'd0);

        // ============ C5: counter_clear + lat identity extremes + STATUS ============
        reset_dut;
        // build up counters, latency trackers and STATUS sticky bits
        pulse_one(C_FRAMES_RX);
        pulse_one(C_MSGS_ACCEPTED);
        pulse_one(C_REJ_KILL);
        pulse_one(C_ORDERS_TX);
        @(negedge clk); seq_gap_pulse = 1'b1; @(posedge clk); #1; all0;
        @(negedge clk); crossed = 4'b0001; @(posedge clk); #1; crossed = 4'd0;
        @(negedge clk); gate_stale_fired = 1'b1; @(posedge clk); #1; all0;
        @(negedge clk); ml_adverse_pulse = 1'b1; @(posedge clk); #1; all0;
        // latency trackers: lat_min/max/last via lat_valid
        @(negedge clk); lat_valid = 1'b1; lat_value = 16'd80; @(posedge clk); #1; all0;
        @(negedge clk); lat_valid = 1'b1; lat_value = 16'd20; @(posedge clk); #1; all0;
        // sanity: counters/status/latency reflect the build-up
        csr_read(16'h0004, rv);
        chk(5000, rv, 32'h0000001E);   // seq_gap+crossed+stale+ml-adverse, no kill
        csr_read(16'h012C, rv); chk(5001, rv, 32'd20);
        csr_read(16'h0130, rv); chk(5002, rv, 32'd80);
        csr_read(16'h0134, rv); chk(5003, rv, 32'd20);
        // CTRL.bit2 = counter clear
        csr_write(16'h0000, 32'h0000_0004);
        csr_read(16'h0004, rv);
        chk(5010, rv, 32'd0);   // status sticky bits 1-4 cleared
        csr_read(16'h012C, rv); chk(5011, rv, 32'hFFFFFFFF);  // lat_min identity extreme
        csr_read(16'h0130, rv); chk(5012, rv, 32'd0);         // lat_max identity extreme
        csr_read(16'h0134, rv); chk(5013, rv, 32'd0);         // lat_last -> 0
        for (i = 0; i < N_CNT; i = i + 1) begin
            csr_read(16'h00A0 + (i << 2), rv);
            chk(5020 + i, rv, 32'd0);
        end

        // ============ C6: cnt_orders_tx counts NEW but never REJECT ============
        reset_dut;
        @(negedge clk); ob_tx_start = 1'b1; ob_tx_payload = {8'h11, 120'd0}; @(posedge clk); #1; all0;
        ob_tx_payload = 128'd0;
        csr_read(16'h0124, rv);
        chk(6000, rv, 32'd0);
        @(negedge clk); ob_tx_start = 1'b1; ob_tx_payload = {8'h10, 120'd0}; @(posedge clk); #1; all0;
        ob_tx_payload = 128'd0;
        csr_read(16'h0124, rv);
        chk(6001, rv, 32'd1);

        // ============ C7: STATUS bit0 live, bits 1-4 sticky, 7:5 zero ============
        reset_dut;
        @(negedge clk); seq_gap_pulse = 1'b1; @(posedge clk); #1; all0;   // bit1 sticky
        @(negedge clk); kill_latched = 1'b1; @(posedge clk); #1;          // bit0 live up
        csr_read(16'h0004, rv);
        chk(7000, rv, 32'h00000003);
        @(negedge clk); kill_latched = 1'b0; @(posedge clk); #1;          // bit0 live down
        csr_read(16'h0004, rv);
        chk(7001, rv, 32'h00000002);   // bit1 still stuck
        // bit0 tracks live again when re-asserted
        @(negedge clk); kill_latched = 1'b1; @(posedge clk); #1;
        csr_read(16'h0004, rv);
        chk(7002, rv, 32'h00000003);
        @(negedge clk); kill_latched = 1'b0; @(posedge clk); #1;
        // bits 7:5 always zero even with everything set
        @(negedge clk); seq_gap_pulse = 1'b1; @(posedge clk); #1; all0;
        csr_read(16'h0004, rv);
        if ((rv & 32'h000000E0) !== 32'h00000000) begin $display("FAIL: C7 STATUS bits 7:5 nonzero: %08x", rv); fail = 1'b1; end
        if ((rv & 32'hFFFFFF00) !== 32'h00000000) begin $display("FAIL: C7 STATUS bits 31:8 nonzero: %08x", rv); fail = 1'b1; end

        // ============ C8: read while resp_busy is dropped silently ============
        reset_dut;
        csr_write(16'h0028, 32'h0000_04D2);   // MAX_ORDER_QTY = 1234
        // hold resp busy, then ask for a read
        resp_force_busy = 1'b1;
        csr_frame(8'h21, 16'h0028, 32'd0);
        settle;
        if (resp_start !== 1'b0) begin $display("FAIL: C8 read while busy produced a response"); fail = 1'b1; end
        resp_force_busy = 1'b0;
        // give the stand-in a moment to drop
        @(posedge clk); #1;
        csr_read(16'h0028, rv);
        chk(8000, rv, 32'h0000_04D2);

        // ============ C9: market-data traffic on the shared stream ============
        reset_dut;
        csr_write(16'h0008, 32'h0000_002A);   // SYMBOL_0 = 0x2A
        // 16-byte market-data-shaped frames whose "addr/data" bytes would
        // corrupt SYMBOL_0 if the module wrongly decoded them
        csr_frame(8'h01, 16'h0008, 32'h0000_00BB);
        #1;
        if (dut.csr_write_valid !== 1'b0 || dut.csr_read_valid !== 1'b0) begin
            $display("FAIL: C9 market frame fired a CSR write/read"); fail = 1'b1;
        end
        settle;
        csr_frame(8'h02, 16'h0008, 32'h0000_00CC);
        settle;
        csr_frame(8'h03, 16'h0008, 32'h0000_00DD);
        settle;
        csr_frame(8'hFF, 16'h0008, 32'h0000_00EE);
        settle;
        csr_read(16'h0008, rv);
        chk(9000, rv, 32'h0000002A);
        if (cfg_symbol_0 !== 8'h2A) begin $display("FAIL: C9 cfg_symbol_0 disturbed: %h", cfg_symbol_0); fail = 1'b1; end
        // stream alignment survives: a normal write/read still works
        csr_write(16'h0008, 32'h0000_0077);
        csr_read(16'h0008, rv);
        chk(9001, rv, 32'h00000077);

        // ============ C10: genuinely unmapped address (0x300, above the
        // histogram range) ============
        // (0x200 used to be "unmapped" only because the whole 0x138-0x234
        // range read 0; the D21/D22 patch wired that range to live histogram
        // buckets, so 0x200 now reads bucket 50 -- a genuinely unmapped
        // address above the range must be used here instead.)
        reset_dut;
        csr_write(16'h0028, 32'h0000_07D0);   // MAX_ORDER_QTY = 2000
        csr_write(16'h0300, 32'hDEAD_BEEF);   // write to unmapped: silent no-op
        csr_read(16'h0300, rv);
        chk(10000, rv, 32'd0);
        csr_read(16'h0028, rv);
        chk(10001, rv, 32'h0000_07D0);
        // 0x138 is no longer "reserved": the D21/D22 patch wired it to
        // histogram bucket 0, so it now reads the stand-in's bucket-0 value
        csr_read(16'h0138, rv);
        chk(10002, rv, hist_mem_stub[0]);

        // ============ C11 (D20): STATUS bit2 re-asserts across a clear when
        // `crossed` is a persisting LEVEL, not just on a fresh 0->1 edge ============
        reset_dut;
        @(negedge clk); crossed = 4'b0001; @(posedge clk); #1;   // crossed asserted, held
        csr_read(16'h0004, rv);
        if (rv[2] !== 1'b1) begin $display("FAIL: C11 STATUS bit2 not set while crossed held: %08x", rv); fail = 1'b1; end
        // clear counters/STATUS while `crossed` is STILL asserted (never dropped)
        csr_write(16'h0000, 32'h0000_0004);
        csr_read(16'h0004, rv);
        if (rv[2] !== 1'b1) begin
            $display("FAIL: C11 (D20) STATUS bit2 did not re-latch after counter_clear while crossed stayed asserted the whole time -- edge-only detection bug: %08x", rv);
            fail = 1'b1;
        end
        // several more cycles, still no edge, must still read 1
        @(posedge clk); @(posedge clk); #1;
        csr_read(16'h0004, rv);
        if (rv[2] !== 1'b1) begin $display("FAIL: C11 STATUS bit2 dropped on its own with crossed still held: %08x", rv); fail = 1'b1; end
        @(negedge clk); crossed = 4'd0; @(posedge clk); #1;

        // ============ C12 (patch): counter_clear_pulse is a real output port ============
        reset_dut;
        csr_frame(8'h20, 16'h0000, 32'h0000_0004);   // CTRL bit2
        #1;                                          // in the write-valid cycle
        if (counter_clear_pulse !== 1'b1) begin
            $display("FAIL: C12 counter_clear_pulse output not high during CTRL.bit2 write");
            fail = 1'b1;
        end
        settle;
        if (counter_clear_pulse !== 1'b0) begin
            $display("FAIL: C12 counter_clear_pulse not a one-cycle pulse (still high after settle)");
            fail = 1'b1;
        end
        @(posedge clk); #1;
        if (counter_clear_pulse !== 1'b0) begin
            $display("FAIL: C12 counter_clear_pulse lingering");
            fail = 1'b1;
        end

        // ============ C13 (patch): histogram readback, exact addresses ============
        reset_dut;
        // scattered bucket indices 0,1,31,63 -> 0x138,0x13C,0x1B4,0x234
        csr_read(16'h0138, rv); chk(13000, rv, hist_mem_stub[0]);
        csr_read(16'h013C, rv); chk(13001, rv, hist_mem_stub[1]);
        csr_read(16'h01B4, rv); chk(13002, rv, hist_mem_stub[31]);
        csr_read(16'h0234, rv); chk(13003, rv, hist_mem_stub[63]);
        // every 4-byte step through the range maps to its own bucket
        for (i = 0; i < 64; i = i + 1) begin
            csr_read(16'h0138 + (i << 2), rv);
            chk(13100 + i, rv, hist_mem_stub[i]);
        end

        // ============ C14 (patch): continuous hist_rd_addr, back-to-back reads ============
        // Two histogram reads at different addresses with NO gap between the
        // frames: the second response must reflect the second address's own
        // bucket, not the first's (catches hist_rd_addr gated on csr_read_valid).
        reset_dut;
        resp_n = 0;
        push16(8'h21, 16'h014C, 32'd0);   // bucket 5
        push16(8'h21, 16'h01D8, 32'd0);   // bucket 40, immediately after
        end_stream;
        repeat (10) @(posedge clk);
        #1;
        if (resp_n !== 2) begin
            $display("FAIL: C14 expected 2 responses, got %0d", resp_n);
            fail = 1'b1;
        end else begin
            chk(14000, resp_queue[0][95:64], hist_mem_stub[5]);
            chk(14001, resp_queue[1][95:64], hist_mem_stub[40]);
        end
        // Same again but with a market-data frame interleaved between the two
        // reads: hist_rd_addr tracking the interleaved frame's address bytes
        // must not corrupt the second histogram read.
        reset_dut;
        resp_n = 0;
        push16(8'h21, 16'h0188, 32'd0);   // bucket 20
        push16(8'h01, 16'hFFFF, 32'hA5A5A5A5);   // market-data-shaped frame
        push16(8'h21, 16'h01D8, 32'd0);   // bucket 40
        end_stream;
        repeat (10) @(posedge clk);
        #1;
        if (resp_n !== 2) begin
            $display("FAIL: C14 (interleaved) expected 2 responses, got %0d", resp_n);
            fail = 1'b1;
        end else begin
            chk(14100, resp_queue[0][95:64], hist_mem_stub[20]);
            chk(14101, resp_queue[1][95:64], hist_mem_stub[40]);
        end

        // ============ C15 (patch): boundary addresses ============
        reset_dut;
        csr_read(16'h0134, rv); chk(15000, rv, 32'd0);   // lat_last, just below range
        csr_read(16'h0238, rv); chk(15001, rv, 32'd0);   // just above range -> default 0
        csr_read(16'h0234, rv); chk(15002, rv, hist_mem_stub[63]);   // last bucket still works

        if (fail) begin
            $display("FAIL");
            $finish;
        end
        $display("PASS");
        $finish;
    end

endmodule
