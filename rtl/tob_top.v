`timescale 1ns / 1ps

// S0 skeleton (Tier A, fpga_project_flow.md Stage 2): proves part string, clock,
// reset, key/LED I/O, and the build.tcl -> bitstream path. Gets rebuilt into the
// real integration top incrementally as modules land (S2 onward).
module tob_top (
    input  wire       sys_clk,  // 50 MHz board oscillator, PACKAGE_PIN Y18
    input  wire       rst_n,    // active-low pushbutton reset, PACKAGE_PIN F20
    input  wire [3:0] key_in,   // KEY1..KEY4 = M13, K14, K13, L13; active-low
    output wire [3:0] led       // LED0..LED3 = F19, E21, D20, C20
);

    localparam HEARTBEAT_BITS = 25; // ~1.5 Hz blink at 50 MHz

    reg [HEARTBEAT_BITS-1:0] heartbeat_cnt;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)
            heartbeat_cnt <= {HEARTBEAT_BITS{1'b0}};
        else
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
    end

    assign led[0]   = heartbeat_cnt[HEARTBEAT_BITS-1];
    assign led[3:1] = ~key_in[3:1];

endmodule
