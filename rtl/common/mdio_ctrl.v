`timescale 1ns / 1ps

// rtl/common/mdio_ctrl.v
//
// MDIO (IEEE 802.3 clause 22) one-shot bring-up sequencer for the JLSemi
// JL2121(D) Gigabit PHY on the ALINX AX7035B (docs/design_decisions.md D9 --
// this board's schematic and earlier drafts of this module said KSZ9031RNX,
// which is the wrong chip for the physically populated part).
//
// On `start` it runs three direct clause-22 register writes, waits for the
// chip's required post-reset settle time, then asserts `done`:
//
//   reg 4 = 0x0141  advertise 10BASE-T / 100BASE-TX full duplex
//   reg 9 = 0x0200  advertise 1000BASE-T full duplex
//   reg 0 = 0x9140  soft reset, autoneg on, full duplex, 1000 Mbps
//
// These three values are bit-identical in purpose and layout on both the
// JL2121(D) and the KSZ9031RNX -- registers 0/4/9 are IEEE 802.3 clause 22
// standard registers with the same field layout across vendors -- so no
// change was needed here when D9 corrected the PHY identity.
//
// What *is* JL2121(D)-specific: there is no RGMII pad-skew register write
// here, unlike an earlier KSZ9031-targeted draft of this module. The
// JL2121(D) has no equivalent register -- its RX/TX clock delay is set by
// hardware strap pins (RXDLY/TXDLY), already strapped +2ns on this board
// per docs/refs/AX7035B_pinout_notes.md, not by anything MDIO-writable.
//
// What *is* newly required for this chip: after the register-0 software
// reset, the datasheet calls for a 10ms settle delay before the chip is
// reliable (DS009-JL2121(D), BMCR bit15 description). `busy` stays high
// through that delay; `done` only pulses once it has elapsed.
//
// This is a fire-once bring-up sequencer, not a general MDIO master.
// Verilog-2001 only. One clock domain, no vendor primitives.

module mdio_ctrl #(
    parameter PHY_ADDR        = 5'b00001,    // strapped address on this board (both candidate chips agree)
    parameter CLK_HZ          = 125_000_000,
    parameter MDC_HZ          = 2_500_000,   // must not exceed IEEE 802.3 clause 22 max (2.5 MHz)
    parameter RESET_SETTLE_NS = 10_000_000   // JL2121(D): required settle time after the reg-0 soft reset
) (
    input  wire clk,        // free-running system clock (CLK_HZ)
    input  wire rst_n,      // active-low, synchronous is fine
    input  wire start,      // one-shot pulse: begin the sequence (ignored if already running)
    output reg  busy,       // high from `start` until the whole sequence completes
    output reg  done,       // one-cycle pulse when the whole sequence completes successfully
    output wire mdc,        // MDIO clock output to the PHY
    inout  wire mdio        // MDIO data, bidirectional (drive or release)
);

    // -----------------------------------------------------------------
    // Sequencer contents
    // -----------------------------------------------------------------
    localparam [15:0] REG4_ADVERTISE = 16'h0141;   // reg 4 : advertise 10BASE-T / 100BASE-TX FD
    localparam [15:0] REG9_1000T     = 16'h0200;   // reg 9 : advertise 1000BASE-T FD
    localparam [15:0] REG0_CONTROL   = 16'h9140;   // reg 0 : soft reset, autoneg, FD, 1000 Mbps

    localparam integer N_FRAMES = 3;

    // Cycles to hold `busy` after the last MDIO frame, satisfying the
    // JL2121(D)'s post-software-reset settle requirement.
    localparam integer CLK_PERIOD_NS      = 1_000_000_000 / CLK_HZ;
    localparam integer RESET_SETTLE_CYCLES =
        (RESET_SETTLE_NS + CLK_PERIOD_NS - 1) / CLK_PERIOD_NS;

    // -----------------------------------------------------------------
    // Free-running MDC divider. Period is rounded up so the resulting
    // frequency never exceeds MDC_HZ.
    // -----------------------------------------------------------------
    localparam integer MDC_PERIOD = (CLK_HZ + MDC_HZ - 1) / MDC_HZ;
    localparam integer MDC_HIGH   = (MDC_PERIOD >= 2) ? (MDC_PERIOD / 2) : 1;

    reg [31:0] mdc_cnt;
    reg        mdc_r;
    assign mdc = mdc_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mdc_cnt <= 32'd0;
            mdc_r   <= 1'b1;
        end else if (mdc_cnt == MDC_PERIOD - 1) begin
            mdc_cnt <= 32'd0;
            mdc_r   <= 1'b1;
        end else begin
            mdc_cnt <= mdc_cnt + 1'b1;
            if (mdc_cnt == MDC_HIGH - 1)
                mdc_r <= 1'b0;
        end
    end

    reg mdc_d;
    wire mdc_fall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mdc_d <= 1'b1;
        else        mdc_d <= mdc_r;
    end

    assign mdc_fall = mdc_d & ~mdc_r;

    // -----------------------------------------------------------------
    // Frame assembly helper. A clause-22 write frame is 64 bits, MSB first:
    //   32-bit preamble | ST(01) | OP(01) | PHYAD | REGAD | TA(10) | 16-bit data
    // -----------------------------------------------------------------
    function [63:0] frame_bits_for;
        input [1:0] idx;
        reg [4:0]  regad;
        reg [15:0] data;
        begin
            case (idx)
                2'd0:    begin regad = 5'd4; data = REG4_ADVERTISE; end
                2'd1:    begin regad = 5'd9; data = REG9_1000T;     end
                default: begin regad = 5'd0; data = REG0_CONTROL;   end
            endcase
            frame_bits_for = {32'hFFFFFFFF, 2'b01, 2'b01, PHY_ADDR, regad, 2'b10, data};
        end
    endfunction

    // -----------------------------------------------------------------
    // Sequencer FSM
    // -----------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_TX = 2'd1, S_SETTLE = 2'd2, S_DONE = 2'd3;

    reg [1:0]  state;
    reg [1:0]  frame_idx;
    reg [5:0]  bit_idx;
    reg [63:0] tx_frame;
    reg        mdio_oe;
    reg        mdio_out;
    reg [31:0] settle_cnt;

    assign mdio = mdio_oe ? mdio_out : 1'bz;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            frame_idx  <= 2'd0;
            bit_idx    <= 6'd63;
            tx_frame   <= 64'd0;
            mdio_oe    <= 1'b0;
            mdio_out   <= 1'b1;
            settle_cnt <= 32'd0;
            busy       <= 1'b0;
            done       <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state     <= S_TX;
                        busy      <= 1'b1;
                        frame_idx <= 2'd0;
                        tx_frame  <= frame_bits_for(2'd0);
                        bit_idx   <= 6'd63;
                        mdio_oe   <= 1'b1;
                        mdio_out  <= 1'b1;   // preamble level while waiting for first mdc edge
                    end else begin
                        busy <= 1'b0;
                    end
                end
                S_TX: begin
                    if (mdc_fall) begin
                        if (bit_idx == 6'd0) begin
                            // final bit of this frame is being driven now
                            mdio_out <= tx_frame[0];
                            if (frame_idx == N_FRAMES - 1) begin
                                state      <= S_SETTLE;   // last frame sent; wait for the chip to settle
                                settle_cnt <= 32'd0;
                            end else begin
                                frame_idx <= frame_idx + 1'b1;
                                tx_frame  <= frame_bits_for(frame_idx + 1'b1);
                                bit_idx   <= 6'd63;
                            end
                        end else begin
                            mdio_out <= tx_frame[bit_idx];
                            bit_idx  <= bit_idx - 1'b1;
                        end
                    end
                end
                S_SETTLE: begin
                    if (mdc_fall) begin
                        // let the PHY sample the final data bit, then release the bus
                        mdio_oe  <= 1'b0;
                        mdio_out <= 1'b1;
                    end
                    // JL2121(D) post-software-reset settle time (D9); busy stays
                    // high the whole time, mdio idle, no further MDIO traffic.
                    if (settle_cnt == RESET_SETTLE_CYCLES - 1) begin
                        state <= S_DONE;
                    end else begin
                        settle_cnt <= settle_cnt + 1'b1;
                    end
                end
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;   // busy stays high one more edge, cleared in S_IDLE
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
