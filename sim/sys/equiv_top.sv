// Equivalence harness (sim/sys/equiv.sh): the working-tree nds_sys and a
// copy from an earlier revision (modules renamed old_*) on the same inputs.
// `diff` is set in any cycle where an output differs.
module sys_equiv #(
    parameter bit PUMP = 0,             // the new side's nds_sys PUMP (clk2: 2 x clk, phase 0)
    parameter bit FAST = 0              // both sides' DMA_FAST
) (
    input  logic        clk, clk2, rst, tick,
    input  logic        io_req, io_cpu, io_we,
    input  logic [3:0]  io_be,
    input  logic [20:2] io_addr,
    input  logic [31:0] io_wdata,
    input  logic [7:1]  dma_trig9, dma_stop9,
    input  logic        dma_gx_low,
    input  logic [3:1]  dma_trig7,
    input  logic        m_ack,
    input  logic [31:0] m_rdata,
    input  logic [31:0] irq_ext9, irq_ext7,
    output logic [9:0]  diff,
    output logic [31:0] new_rdata, old_rdata
);
    // the fabric's timer decode, as nds_sys's own (the harness's requests come one cycle each)
    wire [7:0] tmr_oh = (io_req && io_we && io_addr[20:12] == 9'd0 && io_addr[11:4] == 8'h10) ? 8'd1 << {io_cpu, io_addr[3:2]} : 8'd0;
    logic        n_hit, o_hit, n_mreq, o_mreq, n_mwe, o_mwe, n_mcpu, o_mcpu, n_m32, o_m32;
    logic [31:0] n_maddr, o_maddr, n_mwd, o_mwd, n_mdst, o_mdst;
    logic        n_munit, o_munit, n_more, o_more;
    logic [1:0]  n_busy, o_busy;
    logic        n_i9, o_i9, n_i7, o_i7, n_w7, o_w7;
    nds_sys #(.PUMP(PUMP), .DMA_FAST(FAST)) u_new (.clk, .clk2, .rst, .tick, .io_req, .tmr_oh(tmr_oh), .io_cpu, .io_we, .io_be, .io_addr, .io_wdata,
        .io_rdata(new_rdata), .io_hit(n_hit), .dma_trig9, .dma_gx_low, .dma_stop9, .dma_trig7,
        .m_req(n_mreq), .m_we(n_mwe), .m_cpu(n_mcpu), .m_size32(n_m32), .m_addr(n_maddr),
        .m_wdata(n_mwd), .m_unit(n_munit), .m_dst(n_mdst), .m_more(n_more), .m_ack, .m_rdata, .dma_busy(n_busy), .irq_ext9, .irq_ext7,
        .irq9(n_i9), .irq7(n_i7), .wake7(n_w7), .math_late(), .dbg_dma_run(), .dma_lat_lost());
    old_nds_sys #(.DMA_FAST(FAST)) u_old (.clk, .rst, .tick, .io_req, .tmr_oh(tmr_oh), .io_cpu, .io_we, .io_be, .io_addr, .io_wdata,
        .io_rdata(old_rdata), .io_hit(o_hit), .dma_trig9, .dma_gx_low, .dma_stop9, .dma_trig7,
        .m_req(o_mreq), .m_we(o_mwe), .m_cpu(o_mcpu), .m_size32(o_m32), .m_addr(o_maddr),
        .m_wdata(o_mwd), .m_unit(o_munit), .m_dst(o_mdst), .m_more(o_more), .m_ack, .m_rdata, .dma_busy(o_busy), .irq_ext9, .irq_ext7,
        .irq9(o_i9), .irq7(o_i7), .wake7(o_w7), .math_late(), .dbg_dma_run(), .dma_lat_lost());
    assign diff = {new_rdata != old_rdata, n_hit != o_hit, n_mreq != o_mreq,
                   n_mreq && (n_mwe != o_mwe || n_mcpu != o_mcpu || n_m32 != o_m32 || n_munit != o_munit ||
                              (n_munit && (n_mdst[27:0] != o_mdst[27:0] || n_more != o_more))),
                   n_mreq && n_maddr[27:0] != o_maddr[27:0], n_mreq && n_mwe && n_mwd != o_mwd,
                   n_busy != o_busy, n_i9 != o_i9, n_i7 != o_i7, n_w7 != o_w7};   // bit 0: wake7
endmodule
