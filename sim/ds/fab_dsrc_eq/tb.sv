// nds_fabric against its version before the dm_src hit test (nds_fabric_ref, 6c8a1bd89), cycle by cycle: every input
// random each clock (DMA addresses in a 256-byte main-RAM window, so the read-ahead lines hit), dm_src = dm_addr on a
// read and random on a write (sys_dma: m_src = e_src = m_addr whenever !m_we), every output compared.
//   sim/ds/fab_dsrc_eq/run.sh  (+cycles=N +seed=N)
`default_nettype none
module tb_fab_dsrc_eq #(parameter integer RA = 1, parameter integer B8 = 1);
    logic clk = 0, rst = 1;
    always #5 clk = !clk;
    logic [1:0] wramcnt;
    logic  pb_busy;
    logic  dm_req;
    logic  dm_we;
    logic  dm_cpu;
    logic  dm_size32;
    logic [31:0] dm_addr;
    logic [31:0] dm_src;
    logic  dm_unit;
    logic  dm_more;
    logic [31:0] dm_dst;
    logic  dx_ready;
    logic  dx_idle;
    logic [31:0] dm_wdata;
    logic  a9_req;
    logic  a9_we;
    logic [31:0] a9_addr;
    logic [3:0] a9_be;
    logic [3:0] a9_tmr;
    logic [31:0] a9_wdata;
    logic  a9_n8;
    logic  a7_req;
    logic  a7_we;
    logic [31:0] a7_addr;
    logic [3:0] a7_be;
    logic [31:0] a7_wdata;
    logic  sn_req;
    logic  sn_we;
    logic [31:0] sn_addr;
    logic [31:0] sn_wdata;
    logic  mr_ack;
    logic  mr_rvalid;
    logic [31:0] mr_rdata;
    logic  mr_wnext;
    logic  fx_done;
    logic [31:0] fx_rdata;
    logic [31:0] boot_q;
    logic  io_ack;
    logic [31:0] io_rdata;
    logic  gxp_done;
    logic [31:0] gxp_rdata;
    logic  vr_ack;
    logic [31:0] vr_rdata;
    logic [31:0] pal_cq;
    logic  oam_cgnt;
    logic [31:0] oam_cq;
    wire  dx_valid_a, dx_valid_b;
    wire  dm_ack_a, dm_ack_b;
    wire [31:0] dm_rdata_a, dm_rdata_b;
    wire  a9_ack_a, a9_ack_b;
    wire [31:0] a9_rdata_a, a9_rdata_b;
    wire  a9_rvalid_a, a9_rvalid_b;
    wire  a9_wnext_a, a9_wnext_b;
    wire  a7_ack_a, a7_ack_b;
    wire [31:0] a7_rdata_a, a7_rdata_b;
    wire  sn_ack_a, sn_ack_b;
    wire [31:0] sn_rdata_a, sn_rdata_b;
    wire  mr_req_a, mr_req_b;
    wire  mr_we_a, mr_we_b;
    wire [21:2] mr_addr_a, mr_addr_b;
    wire [3:0] mr_be_a, mr_be_b;
    wire [31:0] mr_wdata_a, mr_wdata_b;
    wire  mr_n8_a, mr_n8_b;
    wire  fx_req_a, fx_req_b;
    wire  fx_we_a, fx_we_b;
    wire [17:2] fx_addr_a, fx_addr_b;
    wire [3:0] fx_be_a, fx_be_b;
    wire [31:0] fx_wdata_a, fx_wdata_b;
    wire [10:0] boot_addr_a, boot_addr_b;
    wire [31:0] ram_wdata_a, ram_wdata_b;
    wire  io_req_a, io_req_b;
    wire  io_pre_a, io_pre_b;
    wire  io_tmr_a, io_tmr_b;
    wire  io_cpu_a, io_cpu_b;
    wire  io_we_a, io_we_b;
    wire [3:0] io_be_a, io_be_b;
    wire [23:2] io_addr_a, io_addr_b;
    wire [31:0] io_wdata_a, io_wdata_b;
    wire  gx_park_a, gx_park_b;
    wire  vr_req_a, vr_req_b;
    wire  vr_cpu_a, vr_cpu_b;
    wire  vr_dma_a, vr_dma_b;
    wire  vr_we_a, vr_we_b;
    wire [23:2] vr_addr_a, vr_addr_b;
    wire [3:0] vr_be_a, vr_be_b;
    wire [31:0] vr_wdata_a, vr_wdata_b;
    wire  oam_cre_a, oam_cre_b;
    wire  pal_we_a, pal_we_b;
    wire  oam_we_a, oam_we_b;
    wire [8:0] po_waddr_a, po_waddr_b;
    wire [31:0] po_wdata_a, po_wdata_b;
    wire [3:0] po_be_a, po_be_b;
    wire  mon_we_a, mon_we_b;
    wire [1:0] mon_master_a, mon_master_b;
    wire  mon_cpu_a, mon_cpu_b;
    wire [31:0] mon_addr_a, mon_addr_b;
    wire [3:0] mon_be_a, mon_be_b;
    wire [31:0] mon_wdata_a, mon_wdata_b;
    wire [7:0] io_tmr_oh_a, io_tmr_oh_b;
    nds_fabric_ref #(.MR_BLOCK(1), .OAM_SHARE(1), .A7_IO(1), .DMA_FAST(1), .DMA_RA(RA), .DMA_B8(B8), .DMA_PACE(52), .DMA_PACE_GX(34), .DMA_GX(3), .DMA_PW(1), .DMA_IOF(1), .GX_REL(1), .DMA_PMM(36)) u_a (.clk, .rst, .wramcnt, .pb_busy, .dm_req, .dm_we, .dm_cpu, .dm_size32, .dm_addr, .dm_unit, .dm_more, .dm_dst, .dx_ready, .dx_idle, .dm_wdata, .a9_req, .a9_we, .a9_addr, .a9_be, .a9_tmr, .a9_wdata, .a9_n8, .a7_req, .a7_we, .a7_addr, .a7_be, .a7_wdata, .sn_req, .sn_we, .sn_addr, .sn_wdata, .mr_ack, .mr_rvalid, .mr_rdata, .mr_wnext, .fx_done, .fx_rdata, .boot_q, .io_ack, .io_rdata, .gxp_done, .gxp_rdata, .vr_ack, .vr_rdata, .pal_cq, .oam_cgnt, .oam_cq, .dx_valid(dx_valid_a), .dm_ack(dm_ack_a), .dm_rdata(dm_rdata_a), .a9_ack(a9_ack_a), .a9_rdata(a9_rdata_a), .a9_rvalid(a9_rvalid_a), .a9_wnext(a9_wnext_a), .a7_ack(a7_ack_a), .a7_rdata(a7_rdata_a), .sn_ack(sn_ack_a), .sn_rdata(sn_rdata_a), .mr_req(mr_req_a), .mr_we(mr_we_a), .mr_addr(mr_addr_a), .mr_be(mr_be_a), .mr_wdata(mr_wdata_a), .mr_n8(mr_n8_a), .fx_req(fx_req_a), .fx_we(fx_we_a), .fx_addr(fx_addr_a), .fx_be(fx_be_a), .fx_wdata(fx_wdata_a), .boot_addr(boot_addr_a), .ram_wdata(ram_wdata_a), .io_req(io_req_a), .io_pre(io_pre_a), .io_tmr(io_tmr_a), .io_cpu(io_cpu_a), .io_we(io_we_a), .io_be(io_be_a), .io_addr(io_addr_a), .io_wdata(io_wdata_a), .gx_park(gx_park_a), .vr_req(vr_req_a), .vr_cpu(vr_cpu_a), .vr_dma(vr_dma_a), .vr_we(vr_we_a), .vr_addr(vr_addr_a), .vr_be(vr_be_a), .vr_wdata(vr_wdata_a), .oam_cre(oam_cre_a), .pal_we(pal_we_a), .oam_we(oam_we_a), .po_waddr(po_waddr_a), .po_wdata(po_wdata_a), .po_be(po_be_a), .mon_we(mon_we_a), .mon_master(mon_master_a), .mon_cpu(mon_cpu_a), .mon_addr(mon_addr_a), .mon_be(mon_be_a), .mon_wdata(mon_wdata_a), .io_tmr_oh(io_tmr_oh_a));
    nds_fabric #(.MR_BLOCK(1), .OAM_SHARE(1), .A7_IO(1), .DMA_FAST(1), .DMA_RA(RA), .DMA_B8(B8), .DMA_PACE(52), .DMA_PACE_GX(34), .DMA_GX(3), .DMA_PW(1), .DMA_IOF(1), .GX_REL(1), .DMA_PMM(36)) u_b (.clk, .rst, .wramcnt, .pb_busy, .dm_req, .dm_we, .dm_cpu, .dm_size32, .dm_addr, .dm_src, .dm_unit, .dm_more, .dm_dst, .dx_ready, .dx_idle, .dm_wdata, .a9_req, .a9_we, .a9_addr, .a9_be, .a9_tmr, .a9_wdata, .a9_n8, .a7_req, .a7_we, .a7_addr, .a7_be, .a7_wdata, .sn_req, .sn_we, .sn_addr, .sn_wdata, .mr_ack, .mr_rvalid, .mr_rdata, .mr_wnext, .fx_done, .fx_rdata, .boot_q, .io_ack, .io_rdata, .gxp_done, .gxp_rdata, .vr_ack, .vr_rdata, .pal_cq, .oam_cgnt, .oam_cq, .dx_valid(dx_valid_b), .dm_ack(dm_ack_b), .dm_rdata(dm_rdata_b), .a9_ack(a9_ack_b), .a9_rdata(a9_rdata_b), .a9_rvalid(a9_rvalid_b), .a9_wnext(a9_wnext_b), .a7_ack(a7_ack_b), .a7_rdata(a7_rdata_b), .sn_ack(sn_ack_b), .sn_rdata(sn_rdata_b), .mr_req(mr_req_b), .mr_we(mr_we_b), .mr_addr(mr_addr_b), .mr_be(mr_be_b), .mr_wdata(mr_wdata_b), .mr_n8(mr_n8_b), .fx_req(fx_req_b), .fx_we(fx_we_b), .fx_addr(fx_addr_b), .fx_be(fx_be_b), .fx_wdata(fx_wdata_b), .boot_addr(boot_addr_b), .ram_wdata(ram_wdata_b), .io_req(io_req_b), .io_pre(io_pre_b), .io_tmr(io_tmr_b), .io_cpu(io_cpu_b), .io_we(io_we_b), .io_be(io_be_b), .io_addr(io_addr_b), .io_wdata(io_wdata_b), .gx_park(gx_park_b), .vr_req(vr_req_b), .vr_cpu(vr_cpu_b), .vr_dma(vr_dma_b), .vr_we(vr_we_b), .vr_addr(vr_addr_b), .vr_be(vr_be_b), .vr_wdata(vr_wdata_b), .oam_cre(oam_cre_b), .pal_we(pal_we_b), .oam_we(oam_we_b), .po_waddr(po_waddr_b), .po_wdata(po_wdata_b), .po_be(po_be_b), .mon_we(mon_we_b), .mon_master(mon_master_b), .mon_cpu(mon_cpu_b), .mon_addr(mon_addr_b), .mon_be(mon_be_b), .mon_wdata(mon_wdata_b), .io_tmr_oh(io_tmr_oh_b));
    integer cyc = 0, ncyc = 200000, seed = 1, errs = 0, rd_ra = 0;
    function automatic logic [31:0] dmaddr(input logic [31:0] r);
        return (r[3:0] < 4'd12) ? {8'h02, 14'd0, r[9:2], 2'b00} : r;   // mostly a 256-byte main-RAM window
    endfunction
    initial begin
        void'($value$plusargs("cycles=%d", ncyc)); void'($value$plusargs("seed=%d", seed)); void'($urandom(seed));
    end
    always @(negedge clk) begin
        cyc <= cyc + 1; if (cyc == 20) rst <= 0;
        wramcnt <= 2'($urandom);
        pb_busy <= 1'($urandom);
        dm_req <= 1'($urandom);
        dm_we <= 1'($urandom);
        dm_cpu <= 1'($urandom);
        dm_size32 <= 1'($urandom);
        dm_addr <= dmaddr($urandom);
        dm_unit <= 1'($urandom);
        dm_more <= 1'($urandom);
        dm_dst <= dmaddr($urandom);
        dx_ready <= 1'($urandom);
        dx_idle <= 1'($urandom);
        dm_wdata <= 32'($urandom);
        a9_req <= 1'($urandom);
        a9_we <= 1'($urandom);
        a9_addr <= 32'($urandom);
        a9_be <= 4'($urandom);
        a9_tmr <= 4'($urandom);
        a9_wdata <= 32'($urandom);
        a9_n8 <= 1'($urandom);
        a7_req <= 1'($urandom);
        a7_we <= 1'($urandom);
        a7_addr <= 32'($urandom);
        a7_be <= 4'($urandom);
        a7_wdata <= 32'($urandom);
        sn_req <= 1'($urandom);
        sn_we <= 1'($urandom);
        sn_addr <= 32'($urandom);
        sn_wdata <= 32'($urandom);
        mr_ack <= 1'($urandom);
        mr_rvalid <= 1'($urandom);
        mr_rdata <= 32'($urandom);
        mr_wnext <= 1'($urandom);
        fx_done <= 1'($urandom);
        fx_rdata <= 32'($urandom);
        boot_q <= 32'($urandom);
        io_ack <= 1'($urandom);
        io_rdata <= 32'($urandom);
        gxp_done <= 1'($urandom);
        gxp_rdata <= 32'($urandom);
        vr_ack <= 1'($urandom);
        vr_rdata <= 32'($urandom);
        pal_cq <= 32'($urandom);
        oam_cgnt <= 1'($urandom);
        oam_cq <= 32'($urandom);
    end
    logic [31:0] wr_src;
    always @(negedge clk) wr_src <= $urandom;
    assign dm_src = dm_we ? wr_src : dm_addr;
    always @(posedge clk) if (!rst) begin
        if (u_b.ra_busy && dm_req && !dm_we) rd_ra++;
        if (dx_valid_a !== dx_valid_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d dx_valid ref %h new %h", cyc, dx_valid_a, dx_valid_b); end
        if (dm_ack_a !== dm_ack_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d dm_ack ref %h new %h", cyc, dm_ack_a, dm_ack_b); end
        if (dm_rdata_a !== dm_rdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d dm_rdata ref %h new %h", cyc, dm_rdata_a, dm_rdata_b); end
        if (a9_ack_a !== a9_ack_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d a9_ack ref %h new %h", cyc, a9_ack_a, a9_ack_b); end
        if (a9_rdata_a !== a9_rdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d a9_rdata ref %h new %h", cyc, a9_rdata_a, a9_rdata_b); end
        if (a9_rvalid_a !== a9_rvalid_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d a9_rvalid ref %h new %h", cyc, a9_rvalid_a, a9_rvalid_b); end
        if (a9_wnext_a !== a9_wnext_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d a9_wnext ref %h new %h", cyc, a9_wnext_a, a9_wnext_b); end
        if (a7_ack_a !== a7_ack_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d a7_ack ref %h new %h", cyc, a7_ack_a, a7_ack_b); end
        if (a7_rdata_a !== a7_rdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d a7_rdata ref %h new %h", cyc, a7_rdata_a, a7_rdata_b); end
        if (sn_ack_a !== sn_ack_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d sn_ack ref %h new %h", cyc, sn_ack_a, sn_ack_b); end
        if (sn_rdata_a !== sn_rdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d sn_rdata ref %h new %h", cyc, sn_rdata_a, sn_rdata_b); end
        if (mr_req_a !== mr_req_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mr_req ref %h new %h", cyc, mr_req_a, mr_req_b); end
        if (mr_we_a !== mr_we_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mr_we ref %h new %h", cyc, mr_we_a, mr_we_b); end
        if (mr_addr_a !== mr_addr_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mr_addr ref %h new %h", cyc, mr_addr_a, mr_addr_b); end
        if (mr_be_a !== mr_be_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mr_be ref %h new %h", cyc, mr_be_a, mr_be_b); end
        if (mr_wdata_a !== mr_wdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mr_wdata ref %h new %h", cyc, mr_wdata_a, mr_wdata_b); end
        if (mr_n8_a !== mr_n8_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mr_n8 ref %h new %h", cyc, mr_n8_a, mr_n8_b); end
        if (fx_req_a !== fx_req_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d fx_req ref %h new %h", cyc, fx_req_a, fx_req_b); end
        if (fx_we_a !== fx_we_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d fx_we ref %h new %h", cyc, fx_we_a, fx_we_b); end
        if (fx_addr_a !== fx_addr_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d fx_addr ref %h new %h", cyc, fx_addr_a, fx_addr_b); end
        if (fx_be_a !== fx_be_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d fx_be ref %h new %h", cyc, fx_be_a, fx_be_b); end
        if (fx_wdata_a !== fx_wdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d fx_wdata ref %h new %h", cyc, fx_wdata_a, fx_wdata_b); end
        if (boot_addr_a !== boot_addr_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d boot_addr ref %h new %h", cyc, boot_addr_a, boot_addr_b); end
        if (ram_wdata_a !== ram_wdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d ram_wdata ref %h new %h", cyc, ram_wdata_a, ram_wdata_b); end
        if (io_req_a !== io_req_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d io_req ref %h new %h", cyc, io_req_a, io_req_b); end
        if (io_pre_a !== io_pre_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d io_pre ref %h new %h", cyc, io_pre_a, io_pre_b); end
        if (io_tmr_a !== io_tmr_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d io_tmr ref %h new %h", cyc, io_tmr_a, io_tmr_b); end
        if (io_cpu_a !== io_cpu_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d io_cpu ref %h new %h", cyc, io_cpu_a, io_cpu_b); end
        if (io_we_a !== io_we_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d io_we ref %h new %h", cyc, io_we_a, io_we_b); end
        if (io_be_a !== io_be_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d io_be ref %h new %h", cyc, io_be_a, io_be_b); end
        if (io_addr_a !== io_addr_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d io_addr ref %h new %h", cyc, io_addr_a, io_addr_b); end
        if (io_wdata_a !== io_wdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d io_wdata ref %h new %h", cyc, io_wdata_a, io_wdata_b); end
        if (gx_park_a !== gx_park_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d gx_park ref %h new %h", cyc, gx_park_a, gx_park_b); end
        if (vr_req_a !== vr_req_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d vr_req ref %h new %h", cyc, vr_req_a, vr_req_b); end
        if (vr_cpu_a !== vr_cpu_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d vr_cpu ref %h new %h", cyc, vr_cpu_a, vr_cpu_b); end
        if (vr_dma_a !== vr_dma_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d vr_dma ref %h new %h", cyc, vr_dma_a, vr_dma_b); end
        if (vr_we_a !== vr_we_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d vr_we ref %h new %h", cyc, vr_we_a, vr_we_b); end
        if (vr_addr_a !== vr_addr_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d vr_addr ref %h new %h", cyc, vr_addr_a, vr_addr_b); end
        if (vr_be_a !== vr_be_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d vr_be ref %h new %h", cyc, vr_be_a, vr_be_b); end
        if (vr_wdata_a !== vr_wdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d vr_wdata ref %h new %h", cyc, vr_wdata_a, vr_wdata_b); end
        if (oam_cre_a !== oam_cre_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d oam_cre ref %h new %h", cyc, oam_cre_a, oam_cre_b); end
        if (pal_we_a !== pal_we_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d pal_we ref %h new %h", cyc, pal_we_a, pal_we_b); end
        if (oam_we_a !== oam_we_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d oam_we ref %h new %h", cyc, oam_we_a, oam_we_b); end
        if (po_waddr_a !== po_waddr_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d po_waddr ref %h new %h", cyc, po_waddr_a, po_waddr_b); end
        if (po_wdata_a !== po_wdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d po_wdata ref %h new %h", cyc, po_wdata_a, po_wdata_b); end
        if (po_be_a !== po_be_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d po_be ref %h new %h", cyc, po_be_a, po_be_b); end
        if (mon_we_a !== mon_we_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mon_we ref %h new %h", cyc, mon_we_a, mon_we_b); end
        if (mon_master_a !== mon_master_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mon_master ref %h new %h", cyc, mon_master_a, mon_master_b); end
        if (mon_cpu_a !== mon_cpu_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mon_cpu ref %h new %h", cyc, mon_cpu_a, mon_cpu_b); end
        if (mon_addr_a !== mon_addr_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mon_addr ref %h new %h", cyc, mon_addr_a, mon_addr_b); end
        if (mon_be_a !== mon_be_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mon_be ref %h new %h", cyc, mon_be_a, mon_be_b); end
        if (mon_wdata_a !== mon_wdata_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d mon_wdata ref %h new %h", cyc, mon_wdata_a, mon_wdata_b); end
        if (io_tmr_oh_a !== io_tmr_oh_b) begin errs++; if (errs < 10) $display("DIFF cycle %0d io_tmr_oh ref %h new %h", cyc, io_tmr_oh_a, io_tmr_oh_b); end
    end
    always @(posedge clk) if (cyc == ncyc) begin
        $display("fab_dsrc_eq: %0d cycles, %0d DMA reads during a read-ahead, %0d output differences", cyc, rd_ra, errs);
        if (errs == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
