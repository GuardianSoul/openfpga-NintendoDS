// sim/ds/disp_eq.sh: nds_disp (with its 2D engine) as one Verilated model,
// built twice (the version at REF and the working tree) and run in lockstep
// by sim/ds/tb_disp_eq.cpp. Every output is compared every clock, and the
// state-copy stream into gpu2d (st_eng/st_addr/st_data) whenever st_we.
module tb_disp_eq_top
    import gpu2d_pkg::*;
#(
    parameter bit AR_RAM = 1, parameter bit WST_RF = 1, parameter int TEX_IDXW = 6,
    parameter bit MOSAIC = 1, parameter bit OAM_CPU = 0, parameter bit TAG_MLAB = 0,
    parameter int HURRY_AT = 0
) (
    input  logic        clk, rst, vram_wr,
    output logic        l3d_go,
    output logic [7:0]  l3d_line, l3d_raddr,
    input  logic [31:0] l3d_rdata,
    input  logic        io_req, io_cpu, io_we,
    input  logic [3:0]  io_be,
    input  logic [12:2] io_addr,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,
    input  logic [15:0] powcnt1,
    input  logic [3:0]  lcdc_ab,
    output logic [8:0]  vcount,
    output logic        line_start,
    output logic [1:0]  irq_vblank, irq_hblank, irq_vcount,
    output logic        dma_vblank, dma_hblank, dma_dstart, dma_dstop, dma_mmstop, frame_start,
    output logic        vr_req,
    output logic [17:0] vr_blk,
    input  logic        vr_ack, vr_rvalid,
    input  logic [63:0] vr_rdata,
    output logic        cap_we,
    output logic [17:0] cap_addr,
    output logic [15:0] cap_data,
    input  logic        cap_ready,
    input  logic        pal_we, oam_we,
    input  logic [8:0]  po_waddr,
    input  logic [31:0] po_wdata,
    input  logic [3:0]  po_be,
    output logic [31:0] pal_cq,
    input  logic        oam_cre,
    output logic        oam_cgnt,
    output logic [31:0] oam_cq,
    output logic        px_valid, px_eng,
    output logic [7:0]  px_line, px_x,
    output logic [17:0] px_rgb,
    output logic        stat_late, hurry2d,
    output logic [4:0]  diag_d_ev,
    output logic [15:0] diag_d_bgmax,
    output logic        diag_v_start, diag_v_stop, diag_l2d_v,
    output logic [8:0]  diag_l2d_line,
    output logic        st_we, st_eng,
    output logic [4:0]  st_addr,
    output logic [31:0] st_data,
    output logic [3:0]  q_state          // {Q_PRE copy step running, q}
);
    blk_t blk;
    assign vr_blk = blk;
    nds_disp #(.AR_RAM(AR_RAM), .WST_RF(WST_RF), .TEX_IDXW(TEX_IDXW), .MOSAIC(MOSAIC), .OAM_CPU(OAM_CPU),
               .TAG_MLAB(TAG_MLAB), .HURRY_AT(HURRY_AT)) u (
        .vram_wr, .l3d_go, .l3d_line, .l3d_raddr, .l3d_rdata, .clk, .rst,
        .io_req, .io_cpu, .io_we, .io_be, .io_addr, .io_wdata, .io_rdata, .powcnt1, .lcdc_ab,
        .vcount, .line_start, .irq_vblank, .irq_hblank, .irq_vcount,
        .dma_vblank, .dma_hblank, .dma_dstart, .dma_dstop, .dma_mmstop, .frame_start,
        .vr_req, .vr_blk(blk), .vr_ack, .vr_rvalid, .vr_rdata,
        .cap_we, .cap_addr, .cap_data, .cap_ready,
        .pal_we, .oam_we, .po_waddr, .po_wdata, .po_be, .pal_cq, .oam_cre, .oam_cgnt, .oam_cq,
        .px_valid, .px_eng, .px_line, .px_x, .px_rgb, .stat_late, .hurry2d,
        .diag_d_ev, .diag_d_bgmax, .diag_v_start, .diag_v_stop, .diag_l2d_v, .diag_l2d_line);
    assign st_we   = u.st_we;
    assign st_eng  = u.st_eng;
    assign st_addr = u.st_addr;
    assign st_data = u.st_data;
    assign q_state = {u.pc != 4'd0, 3'(u.q)};
endmodule
