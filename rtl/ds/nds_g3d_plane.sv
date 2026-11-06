// The 3D layer of the 3D-off core (GPU3D=0): with no polygons, what
// melonDS's renderer leaves in its colour buffer is the clear plane, so the
// stub shows that instead of nothing (docs/compat.md, Layton):
//   - DISP3DCNT bit 14 clear: CLEAR_COLOR's colour and alpha everywhere
//   - bit 14 set: the rear-plane bitmap, texture slot 2 (VRAM texture view
//     0x40000), a 256x256 image of 15-bit colours with alpha in bit 15,
//     shown from CLRIMAGE_OFFSET's (x, y), both wrapping at 256
// and engine A's BG0HOFS scrolls the layer (SoftRenderer3D::GetLine).
// Fog, edge marking and anti-aliasing need polygons or fog, and are not
// applied (fog on the rear plane would need slot 3 and the fog table).
//
// Timing follows melonDS: the registers (CLEAR_COLOR, CLEAR_DEPTH/OFFSET,
// DISP3DCNT) are taken at VBlank while geometry and rendering are on, and
// rendered at line 215, so a frame shows what was latched before it. The
// bitmap itself is read during display: line y's row is fetched at the start
// of display line y (16 blocks through the VRAM block port, behind the 2D
// engine) into one of two line buffers, and engine A's BG job reads it after
// that line's HBlank.
module nds_g3d_plane
    import gpu2d_pkg::*;
(
    input  logic        clk,
    input  logic        rst,
    input  logic [3:2]  powcnt1,        // [3] geometry, [2] rendering
    input  logic [15:0] disp3dcnt,
    // ARM9 I/O writes (snooped)
    input  logic        io_req,
    input  logic        io_cpu,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [23:2] io_addr,
    input  logic [31:0] io_wdata,
    // display
    input  logic        line_start,
    input  logic [8:0]  vcount,
    // VRAM block port
    output logic        t_req,
    output blk_t        t_blk,
    input  logic        t_ack,
    input  logic        t_rvalid,
    input  logic [63:0] t_rdata,
    // the 2D engine's 3D layer reads
    input  logic        l3d_go,
    input  logic [7:0]  l3d_line,
    input  logic [7:0]  l3d_raddr,
    output logic [31:0] l3d_rdata
);
    // ---------------------------------------------------------------- registers
    wire       wr9 = io_req && io_we && !io_cpu && io_addr[23:14] == 10'd0;
    wire [11:0] wa = io_addr[13:2];
    logic [31:0] clr1, clr2;            // ClearAttr1/2 as written (melonDS reset values)
    logic [8:0]  xpos;                  // RenderXPos (BG0HOFS of engine A)
    logic        r_bmp;                 // RenderDispCnt bit 14
    logic [31:0] r_clr1, r_clr2;        // latched at VBlank
    logic        d_bmp;                 // rendered at line 215: what the display shows
    logic [31:0] d_clr1, d_clr2;
    always_ff @(posedge clk) begin
        if (rst) begin
            clr1 <= 32'h3F000000; clr2 <= 32'h00007FFF; xpos <= 9'd0;
            r_bmp <= 1'b0; r_clr1 <= 32'h3F000000; r_clr2 <= 32'h00007FFF;
            d_bmp <= 1'b0; d_clr1 <= 32'h3F000000; d_clr2 <= 32'h00007FFF;
        end else begin
            // halfword and word writes only (melonDS has no byte form), while rendering is on
            if (wr9 && powcnt1[2] && (wa == 12'h0D4 || wa == 12'h0D5)) begin
                if (io_be[1:0] == 2'b11) begin
                    if (wa[0]) clr2[15:0] <= io_wdata[15:0]; else clr1[15:0] <= io_wdata[15:0];
                end
                if (io_be[3:2] == 2'b11) begin
                    if (wa[0]) clr2[31:16] <= io_wdata[31:16]; else clr1[31:16] <= io_wdata[31:16];
                end
            end
            if (wr9 && powcnt1[2] && wa == 12'h004) begin
                if (io_be[0]) xpos[7:0] <= io_wdata[7:0];
                if (io_be[1]) xpos[8] <= io_wdata[8];
            end
            if (!powcnt1[2]) begin
                // ResetRenderingState (what is shown stays until the next render)
                r_bmp <= 1'b0; r_clr1 <= 32'h3F000000; r_clr2 <= 32'h00007FFF;
            end else if (line_start && vcount == 9'd192 && powcnt1[3]) begin
                r_bmp <= disp3dcnt[14]; r_clr1 <= clr1; r_clr2 <= clr2;
            end
            if (line_start && vcount == 9'd215 && powcnt1[2]) begin
                d_bmp <= r_bmp; d_clr1 <= r_clr1; d_clr2 <= r_clr2;
            end
        end
    end

    // ---------------------------------------------------------------- row fetch
    // line buffers: {line parity, x[7:2]}, four pixels a word
    logic        f_v, f_inflt;
    logic        f_par;
    logic [7:0]  f_row;
    logic [3:0]  f_blk;                 // next block to request
    logic [3:0]  f_rb;                  // block whose beats come next
    logic [1:0]  f_beat;
    wire         f_last_beat = t_rvalid && f_beat == 2'd3;
    always_ff @(posedge clk) begin
        if (rst) begin f_v <= 1'b0; f_inflt <= 1'b0; f_beat <= 2'd0; end
        else begin
            if (line_start && vcount < 9'd192 && d_bmp) begin
                f_v <= 1'b1; f_par <= vcount[0]; f_row <= d_clr2[31:24] + vcount[7:0];
                f_blk <= 4'd0; f_rb <= 4'd0;
            end else if (t_ack) begin
                f_inflt <= 1'b1;
                if (f_blk == 4'd15) f_v <= 1'b0;
                f_blk <= f_blk + 4'd1;
            end
            if (t_rvalid) begin
                f_beat <= f_beat + 2'd1;
                if (f_beat == 2'd3) begin f_inflt <= 1'b0; f_rb <= f_rb + 4'd1; end
            end
        end
    end
    // one block in flight: texture view byte 0x40000 + row * 512 + block * 32
    assign t_req = f_v && !f_inflt;
    assign t_blk = {SP_TEX, 1'b0, 14'(14'h2000 + {f_row, f_blk})};

    logic [6:0]  lb_ra;
    logic [63:0] lb_q;
    gpu2d_ram #(.W(64), .AW(7)) u_lb (.clk, .we(t_rvalid), .waddr({f_par, f_rb, f_beat}), .wdata(t_rdata),
        .raddr(lb_ra), .rdata(lb_q));

    // ---------------------------------------------------------------- 3D layer reads
    // screen x -> layer x (X scroll, transparent outside), -> bitmap x (+ xoff)
    logic [9:0] sx;
    logic       in_q;
    logic [1:0] hw_q;
    logic [7:0] bx;
    always_comb begin
        sx = {2'd0, l3d_raddr} + {1'b0, xpos};
        bx = sx[7:0] + d_clr2[23:16];
        lb_ra = {l3d_line[0], bx[7:2]};
    end
    always_ff @(posedge clk) begin
        in_q <= xpos[8] ? sx[9] : !sx[8];
        hw_q <= bx[1:0];
    end
    function automatic logic [5:0] c6(input logic [4:0] v);
        return {v, 1'b0} + {5'd0, v != 5'd0};
    endfunction
    logic [15:0] px;
    logic [4:0]  pa;
    always_comb begin
        if (d_bmp) begin px = lb_q[hw_q*16 +: 16]; pa = px[15] ? 5'd31 : 5'd0; end
        else begin px = d_clr1[15:0]; pa = d_clr1[20:16]; end
        // {a[28:24], b[21:16], g[13:8], r[5:0]}, as melonDS's colour buffer
        l3d_rdata = in_q ? {3'd0, pa, 2'd0, c6(px[14:10]), 2'd0, c6(px[9:5]), 2'd0, c6(px[4:0])} : 32'd0;
    end
endmodule
