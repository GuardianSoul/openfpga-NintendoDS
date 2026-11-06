// SPDX-License-Identifier: MIT
// SDRAM for the Phase 1 shell: openfpga-PlayStation's released controller
// (rtl/mem/psx_sdram_ctrl.sv, unmodified, CAS latency 3) with N clients.
//
// Clocks: clk_mem = 3 x clk_bus from one PLL, edges aligned (the controller's
// clk3x/clk1x contract). DS: clk_bus 33.514 MHz (the DS bus clock), clk_mem
// 100.54 MHz. Clients and the arbiter run on clk_bus.
//
// Client port (packed, client i at bit/field i; lower index wins):
//   c_valid  held until c_ready (one clk_bus pulse, the request is taken)
//   c_write  32-bit write of c_wdata with byte enables c_be (posted)
//   c_quad   read of four words from a 16-byte aligned address (else one word)
//   c_addr   word address (byte address / 4) in the 64 MiB chip
//   r_valid  one pulse per read word, in order, to the client that asked
// One transaction at a time, as the controller serves one access at a time.
// Single reads and writes use the controller's ch2; quad reads its DMA-mode
// ch1 (four words streamed one per clk_bus). ch3 is unused. The bw_* port
// (clk_mem, a first-word-fall-through FIFO's head) feeds the controller's
// DMA write FIFO: it goes ahead of ch1/ch2 and chains up to 32 words per
// row opening, so a stream of writes (the stacked bottom screen's lines)
// costs a few row openings instead of one access per word.
`default_nettype none
module nds_sdram #(
    parameter integer N = 4,
    parameter integer OPEN_ROW = 0,
    parameter [N-1:0] OCT = 0               // clients whose quad reads are 32 bytes (two quads, one grant)
) (
    input wire clk_bus, clk_mem,
    input wire reset,                       // clk_bus; holds the controller in init
    output reg ready = 0,                   // controller initialised (sticky)
    input wire [N-1:0] c_valid, c_write, c_quad,
    input wire [N*24-1:0] c_addr,
    input wire [N*32-1:0] c_wdata,
    input wire [N*4-1:0] c_be,
    input wire bw_valid,                    // clk_mem: a write is at the head
    input wire [23:0] bw_addr,              //          its word address
    input wire [31:0] bw_data,
    output wire bw_read,                    //          pop it
    output reg [N-1:0] c_ready = 0,
    output reg [N-1:0] r_valid = 0,
    output reg [31:0] r_data = 0,
    // pins
    inout wire [15:0] dram_dq,
    output wire [12:0] dram_a,
    output wire [1:0] dram_ba,
    output wire [1:0] dram_dqm,
    output wire dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n
);
    reg ch1_req = 0, ch2_req = 0, ch2_rnw = 0;
    reg [26:0] ch_addr = 0;
    reg [31:0] ch2_din = 0;
    reg [3:0] ch2_be = 0;
    wire ch1_ready, ch2_ready, dma_wr, dma_rp, ram_idle;
    wire [31:0] ch2_dout, dma_data;
    psx_sdram_ctrl #(.SINGLE_CHIP(1), .CAS_LATENCY(3), .OPEN_ROW(OPEN_ROW)) ctrl (
        .init(reset), .clk(clk_mem), .clk_base(clk_bus), .SDRAM_EN(1'b1),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]),
        .SDRAM_BA(dram_ba), .SDRAM_nCS(), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n),
        .SDRAM_nCAS(dram_cas_n), .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .refreshForce(1'b0), .ram_idle(ram_idle),
        .ch1_addr(ch_addr), .ch1_dout(), .ch1_dout32(), .ch1_din(16'b0), .ch1_req(ch1_req), .ch1_rnw(1'b1),
        .ch1_dma(1'b1), .ch1_cntDMA(2'd3), .ch1_cache(1'b0), .ch1_ready(ch1_ready),
        .cache_wr(), .cache_data(), .cache_addr(),
        .dma_wr(dma_wr), .dma_reqprocessed(dma_rp), .dma_data(dma_data),
        .ch2_addr(ch_addr), .ch2_dout(ch2_dout), .ch2_din(ch2_din), .ch2_req(ch2_req), .ch2_rnw(ch2_rnw),
        .ch2_be(ch2_be), .ch2_ready(ch2_ready),
        .ch3_addr(27'b0), .ch3_dout(), .ch3_din(32'b0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_be(4'b0), .ch3_ready(),
        .dmafifo_adr({1'b0, bw_addr, 2'b00}), .dmafifo_data(bw_data), .dmafifo_empty(!bw_valid), .dmafifo_read(bw_read));

    // lowest valid index
    reg [$clog2(N)-1:0] pick;
    reg any;
    always @* begin
        pick = 0; any = 0;
        for (integer i = N - 1; i >= 0; i = i - 1)
            if (c_valid[i]) begin pick = i[$clog2(N)-1:0]; any = 1; end
    end

    localparam [1:0] IDLE = 0, WRITE = 1, READ1 = 2, QUAD = 3;
    reg [1:0] state = IDLE;
    reg [$clog2(N)-1:0] owner = 0;
    reg [2:0] got = 0;                      // words of a read delivered
    reg oct = 0, half = 0;                  // a 32-byte read; its second quad was asked for
    always @(posedge clk_bus) begin
        ch1_req <= 0; ch2_req <= 0; c_ready <= 0; r_valid <= 0;
        if (ram_idle) ready <= 1;
        if (reset) begin
            state <= IDLE; ready <= 0;
        end else case (state)
            IDLE: if (any && ready && c_ready == 0) begin
                owner <= pick;
                c_ready[pick] <= 1;
                ch_addr <= {1'b0, c_addr[pick*24 +: 24], 2'b00};
                ch2_din <= c_wdata[pick*32 +: 32];
                ch2_be <= c_be[pick*4 +: 4];
                got <= 0; oct <= OCT[pick]; half <= 0;
                if (c_write[pick]) begin ch2_req <= 1; ch2_rnw <= 0; state <= WRITE; end
                else if (c_quad[pick]) begin ch1_req <= 1; state <= QUAD; end
                else begin ch2_req <= 1; ch2_rnw <= 1; state <= READ1; end
            end
            WRITE: if (ch2_ready) state <= IDLE;
            READ1: if (ch2_ready) begin r_valid[owner] <= 1; r_data <= ch2_dout; state <= IDLE; end
            QUAD: if (dma_wr) begin
                r_valid[owner] <= 1; r_data <= dma_data; got <= got + 1'b1;
                // the second half of a 32-byte read goes in without a new grant
                if (got == 3'd0 && oct && !half) begin
                    half <= 1; ch1_req <= 1; ch_addr <= ch_addr + 27'd16;
                end
                if (got == (oct ? 3'd7 : 3'd3)) state <= IDLE;
            end
        endcase
    end
endmodule
`default_nettype wire
