// The 3D layer's X scroll for the full core (GPU3D=1): engine A's BG0HOFS
// (melonDS RenderXPos) shifts the rendered 3D line, with transparent pixels
// where the shifted line has none (SoftRenderer3D::GetLine). It sits on the
// 2D engine's 3D-layer read port, so the BG0 3D pass and capture source A
// see the same scrolled line, as in melonDS. Register write as in
// nds_g3d_plane (the 3D-off core's layer, which applies the same scroll).
module nds_l3d_xscroll (
    input  logic        clk,
    input  logic        rst,
    input  logic        rend_en,        // POWCNT1 bit 2
    // ARM9 I/O writes (snooped)
    input  logic        io_req,
    input  logic        io_cpu,
    input  logic        io_we,
    input  logic [3:0]  io_be,
    input  logic [23:2] io_addr,
    input  logic [31:0] io_wdata,
    // the 2D engine's side
    input  logic [7:0]  raddr,
    output logic [31:0] rdata,
    // the 3D line buffer's side
    output logic [7:0]  l3d_raddr,
    input  logic [31:0] l3d_rdata
);
    wire wr9 = io_req && io_we && !io_cpu && io_addr[23:14] == 10'd0;
    logic [8:0] xpos;                   // RenderXPos (BG0HOFS of engine A)
    always_ff @(posedge clk)
        if (rst) xpos <= 9'd0;
        else if (wr9 && rend_en && io_addr[13:2] == 12'h004) begin
            if (io_be[0]) xpos[7:0] <= io_wdata[7:0];
            if (io_be[1]) xpos[8] <= io_wdata[8];
        end

    // screen x -> line x; inside when 0 <= x + xpos (signed) < 256
    logic [9:0] sx;
    logic       in_q;
    assign sx = {2'd0, raddr} + {1'b0, xpos};
    assign l3d_raddr = sx[7:0];
    always_ff @(posedge clk) in_q <= xpos[8] ? sx[9] : !sx[8];
    assign rdata = in_q ? l3d_rdata : 32'd0;
endmodule
