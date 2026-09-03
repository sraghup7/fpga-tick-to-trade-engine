`timescale 1 ns/1 ns

// SIMULATION-ONLY behavioral stand-ins for the Xilinx fifo_generator/
// blk_mem_gen IP cores that rtl/vendor/alinx_mac/ depends on
// (udp_tx_data_fifo, udp_checksum_fifo, udp_rx_ram_8_2048,
// icmp_rx_ram_8_256). No real simulation model for these exists locally --
// docs/refs/AX7035/.../eth_test.ip_user_files/ip/<name>/<name>_stub.v is a
// synthesis black-box stub only, not simulatable, and Icarus cannot run
// Xilinx's encrypted SecureIP behavioral models even where they exist.
//
// These implement plain, standard FIFO/dual-port-RAM semantics matching
// the port lists in each core's own .veo instantiation template (verified
// against docs/refs/AX7035/.../ip_user_files/ip/<name>/<name>.veo). They
// exist ONLY to let tb/tb_eth_mac_if.v exercise the vendor MAC's real
// control logic (mac_tx.v, udp_tx.v, mac_rx.v, udp_rx.v -- all plain
// Verilog) in Icarus. They are NEVER referenced by scripts/build.tcl and
// must never be synthesized -- see docs/design_decisions.md D8: the real
// Xilinx IP cores are regenerated via Vivado's IP Status flow before any
// synthesis that touches rtl/vendor/alinx_mac/.
//
// Depths/widths below are inferred from each core's data_count port width
// and its instantiating module's usage, not confirmed against a .xci
// (none is available locally) -- see D8. This does not affect the
// correctness of what's being verified here (eth_mac_if.v's protocol
// timing against the vendor's control logic), only the exact capacity,
// which none of tb_eth_mac_if.v's test payloads come close to exhausting.

module udp_tx_data_fifo (
    input  wire       clk,
    input  wire       srst,
    input  wire [7:0] din,
    input  wire       wr_en,
    input  wire       rd_en,
    output reg  [7:0] dout,
    output wire       full,
    output wire       almost_full,
    output wire       empty,
    output wire [11:0] data_count
);
    localparam DEPTH = 4096;
    localparam ALMOST_FULL_THRESH = DEPTH - 16;

    reg [7:0] mem [0:DEPTH-1];
    reg [11:0] count;
    reg [11:0] wr_ptr, rd_ptr;

    assign full        = (count == DEPTH);
    assign almost_full = (count >= ALMOST_FULL_THRESH);
    assign empty       = (count == 0);
    assign data_count  = count;

    always @(posedge clk) begin
        if (srst) begin
            wr_ptr <= 12'd0;
            rd_ptr <= 12'd0;
            count  <= 12'd0;
            dout   <= 8'd0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_ptr] <= din;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (rd_en && !empty) begin
                dout <= mem[rd_ptr];
                rd_ptr <= rd_ptr + 1'b1;
            end
            case ({wr_en && !full, rd_en && !empty})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule

module udp_checksum_fifo (
    input  wire        clk,
    input  wire        srst,
    input  wire [31:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output reg  [31:0] dout,
    output wire        full,
    output wire        empty,
    output wire [3:0]  data_count
);
    localparam DEPTH = 16;

    reg [31:0] mem [0:DEPTH-1];
    reg [3:0] count;
    reg [3:0] wr_ptr, rd_ptr;

    assign full       = (count == DEPTH);
    assign empty      = (count == 0);
    assign data_count = count;

    always @(posedge clk) begin
        if (srst) begin
            wr_ptr <= 4'd0;
            rd_ptr <= 4'd0;
            count  <= 4'd0;
            dout   <= 32'd0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_ptr] <= din;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (rd_en && !empty) begin
                dout <= mem[rd_ptr];
                rd_ptr <= rd_ptr + 1'b1;
            end
            case ({wr_en && !full, rd_en && !empty})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule

module udp_rx_ram_8_2048 (
    input  wire        clka,
    input  wire        wea,
    input  wire [10:0] addra,
    input  wire [7:0]  dina,
    input  wire        clkb,
    input  wire [10:0] addrb,
    output reg  [7:0]  doutb
);
    reg [7:0] mem [0:2047];

    always @(posedge clka) begin
        if (wea) mem[addra] <= dina;
    end

    always @(posedge clkb) begin
        doutb <= mem[addrb];
    end
endmodule

module icmp_rx_ram_8_256 (
    // Address is 11 bits wide in actual usage (icmp_reply.v), despite the
    // "_256" name -- matched to the real connection, not the name.
    input  wire        clka,
    input  wire        wea,
    input  wire [10:0] addra,
    input  wire [7:0]  dina,
    input  wire        clkb,
    input  wire [10:0] addrb,
    output reg  [7:0]  doutb
);
    reg [7:0] mem [0:2047];

    always @(posedge clka) begin
        if (wea) mem[addra] <= dina;
    end

    always @(posedge clkb) begin
        doutb <= mem[addrb];
    end
endmodule
