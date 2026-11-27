// ARM9 (ARM946E-S) memory system: CP15, MPU, ITCM/DTCM, I-cache and D-cache
// (docs/arm-pipeline.md, "ARM9 memory system").
//
// Timing follows the core's ports: a fetch address arrives in F and is
// answered in F2; a data/CP15 request arrives in E3 and is answered in WB.
// All RAMs are read in the request cycle (port B, address straight from the
// core) and checked in the answer cycle: tag compare over the four ways read
// in parallel from M10K, MPU region lookup on the registered address. Stores
// and dirty bits are decided in the answer cycle and written two cycles
// later on port A, in a cycle where the ARM9 issues no fetch or data read;
// the one access that may have read the old data in between (the ARM9's
// next) gets the pending bytes merged in.
//
// Anything that needs the bus answers "not ready": the core replays the uop
// while this module does the work and holds the ARM9's fetch (d_wait) until
// it is done. One state machine owns the bus: write-buffer drain first, then
// the pending data request (line fill with dirty eviction, uncached read,
// cache maintenance), then the pending instruction request.
//
// Caches: 4-way, 32-byte lines, round-robin replacement per set, read
// allocate, write-back or write-through per region (c3), as on the
// ARM946E-S. Caching needs the MPU on (c1 bit 0) and the cache enable bit.
module arm9_mem import arm_pkg::*; #(
  parameter logic [31:0] RESET_CTRL = 32'h0000_0078,
  // cache ways (4: the ARM946E-S; 2: cheaper, same sizes with twice the sets;
  // set/way operations map way w, set s onto way w[0] of set {w[1], s}, so a
  // loop over the four ways still reaches every line once)
  parameter int          WAYS = 4,
  parameter int          IWAYS = WAYS,      // the I-cache's ways (2 or 4); WAYS is the D-cache's (track C: Goldenrod's I-fills)
  // 1: a line fill is one request for the whole line (b_n8; the 8 words come
  // back as 8 b_ack beats, in order, while b_req stays up), so a bus that can
  // burst serves it as one transfer (the DS: 46 cycles per line, hwref run 22)
  parameter bit          BURST = 1'b0,
  parameter bit          SLOW = 1'b0,                 // the CPUs at clk_sys (67 MHz): smaller forms
  parameter bit          A9C_RETURN = 1'b0,           // arm9_core consumes only accepted, surviving loads
  // 1: a fill's dirty victim line is copied into an 8-word eviction buffer (an MLAB) and the fill starts at
  // once; the buffer drains behind it, before any later fill, read, fetch or buffered store (the DS charges a
  // dirty eviction nothing extra, hwref run 22; docs/ds-rules.md)
  parameter bit          EVB = 1'b0,
  // 1: the eviction buffer drains as one 8-word block write (b_n8 with b_we; the bus takes the words on b_wnext,
  // one per pulse in order, and answers b_ack once, after the 8th)
  parameter bit          EVBW = 1'b0,
  parameter bit          EARLYD = 1'b0,               // the refused access's fetch hold ends with the fill's last word (see d_wait)
  parameter int          XD = 0,                      // extra set-index bits of the D cache (2^XD times the sets: more capacity, same ways)
  parameter int          XI = 0,                      // the same for the I cache
  parameter int          OPT = 0                      // ARM9 speed options (bit 2: tag row captured early, bit 3: tag write forwarded to the retried fetch)
) (
  input  logic        clk,
  input  logic        rst,

  // fetch: request in F, answer in F2
  input  logic        i_req,
  input  logic        i_priv,
  input  logic [31:0] i_addr,
  input  logic [31:0] i_addr_s,         // i_addr is i_rdr ? i_addr_r : i_addr_s: the ITCM match is taken from both
  input  logic [31:0] i_addr_r,
  input  logic        i_rdr,
  output logic [31:0] i_rdata,
  input  logic        i_hsel,           // the core's f1_pc[1]: which halfword of the answer i_rhw carries
  output logic [15:0] i_rhw,            // the answer's halfword (i_rdata's, by i_hsel), the way select last (#2566)
  output logic [4:0]  i_rcls,
  output logic [6:0]  i_rtop,           // thumb_top(i_rhw): the expansion's kind and condition, decoded per way (RC13b)           // thumb_class(i_rhw), decoded in each way before the hit select (#2570, #2594)
  output logic        i_ok,
  output logic        i_abort,

  // data and CP15: request in E3, answer in WB
  input  logic        d_req,
  input  logic        d_we,
  input  logic        d_priv,
  input  logic [3:0]  d_be,
  input  logic [31:0] d_addr,
  input  logic [31:0] d_wdata,
  input  logic        d_kill,       // MEM1: the WB uop is squashed (see wq_e)
  input  logic        cp_req,
  input  logic        cp_we,
  input  logic [15:0] cp_op,
  input  logic [31:0] cp_wdata,
  output logic [31:0] d_rdata_f,
  // the load word's sources for arm9_core's formatter, which selects the TCM word last (rc15f #2844 5asR: w_ra ->
  // rd_itcm -> u -> d_rdata_f -> m_ldv's lanes -> e_bw -0.784 ns): d_ls_it ? d_lw_it : d_ls_dt ? d_lw_dt : d_lw_rs is
  // d_rdata_f (SLOW; without SLOW d_lw_rs is d_rdata_f and both selects are 0)
  output logic [31:0] d_lw_it, d_lw_dt, d_lw_rs,
  output logic        d_ls_it, d_ls_dt,
  output logic        d_ok,
  output logic        d_abort,
  output logic        d_wait,
  output logic        hivecs,

  // ARM9 bus: one word per transfer; b_ack ends it (read data with it). b_n8
  // (BURST): this request is a line fill, words k = 0..7 of b_addr's line,
  // one b_ack each; b_addr follows k as it does without BURST
  output logic        b_n8,
  input  logic        b_wnext,    // EVBW: the bus takes the word on b_wdata this clock
  output logic [1:0]  dg_fill,              // {I, D} line fill starts (one clock), for the diagnostics
  output logic        b_req,
  output logic        b_we,
  output logic [31:0] b_addr,
  output logic [31:0] b_wdata,
  output logic [3:0]  b_be,
  output logic [3:0]  b_tmr,      // the request writes ARM9 timer b_addr[3:2] (one-hot): the write buffer's, decoded at its push
  input  logic        b_ack,
  input  logic [31:0] b_rdata
);

  // ---------------------------------------------------------------- CP15
  logic [31:0] ctrl;                        // c1
  logic [7:0]  dcb, wbb; wire [7:0] icb = 8'h0;               // c2 (D, I cacheable), c3 (bufferable)
  wire [31:0] dap = 32'h0, iap = 32'h0;                    // c5 extended access permissions
  logic [19:0] rbase [0:7];                 // region base[31:12] as written (the compare masks it)
  logic [19:0] rmask [0:7];                 // region size mask[31:12]
  logic [7:0]  ren;
  // The D side's region lookup, inside main RAM only (the one cacheable range here, 0x02000000-0x023FFFFF): per region,
  // set at its c6 write, whether it reaches into main RAM (mr_v) and its base and mask in address bits 21:12. The match is
  // matched in WB from the registered address (w_rm, see there); WB then picks the highest match's C/B
  logic [7:0]  mr_v, w_rm;
  logic [9:0]  mr_b [0:7];
  logic [3:0]  mr_cut [0:7];
  function automatic logic [3:0] cut_of(input logic [4:0] size);
    return size <= 5'd11 ? 4'd0 : size >= 5'd21 ? 4'd10 : 4'(size - 5'd11);
  endfunction
  function automatic logic [9:0] mask_of_cut(input logic [3:0] cut);
    for (int i = 0; i < 10; i++) mask_of_cut[i] = cut <= 4'(i);
  endfunction
  logic [19:0] dtcm_base, dtcm_mask, itcm_mask;
  // Registers that are only read back (MRC) keep that value in an MLAB, in
  // {crn, crm, opc2} order: 0-7 c6 regions, 8/9 c9 DTCM/ITCM region, 10/11
  // c9 lockdown D/I, 12 c13. An entry reads 0 until written; the c9 region
  // entries also after a reset (their registers were reset before).
  (* ramstyle = "M10K, no_rw_check" *) logic [31:0] cprb [0:15];   // (read at the request: M10K, not 2 MLAB LABs)
  logic [12:0] cprb_v = 13'h0;
  logic [3:0]  cprb_ra, cprb_wa;
  // the read-back MLAB's address, taken from cp_op with w_cpop (RC3s #2046: w_cpop -> crn/crm compares -> cprb ->
  // cp_rd -> d_rdata -> arm_core e3_c, -0.125 ns; #1850 -0.283): the same function of the same value, a clock's
  // compares off the path
  logic [3:0]  w_cprb_ra;
  function automatic logic [3:0] cprb_ra_of(input logic [15:0] op);
    return (op[10:7] == 4'd6) ? {1'b0, op[5:3]} :
           (op[10:7] == 4'd9) ? {2'b10, op[6:3] != 4'd1, op[0]} : 4'd12;
  endfunction
  logic [31:0] cprb_wd, cprb_q;
  logic        cprb_we;

  // The I-cacheable ranges (pocket-now: no I-side MPU lookup, known difference): main RAM proper, 0x02000000-0x023FFFFF,
  // and the BIOS, 0xFFFF0000-0xFFFF7FFF: the NitroSDK's c2 I-cacheable bits (0x42, regions 1 and 6; HeartGold, track
  // C0) make both cacheable on the DS, where its BIOS calls run from the I-cache. The mirrors of main RAM stay uncached
  // (no SDK region covers them). Address bits 23:22 tell the two apart (00 main RAM, 11 the BIOS), so the I-tag's short
  // compare (bits 23:ISB+5 and the cacheable-line bit) stays exact
`ifdef ARM9_BIOSIC_MUT
  function automatic logic icr(input logic [31:0] a); return a[31:24] == 8'h02; endfunction   // (mutant: the old rule)
`else
  function automatic logic icr(input logic [31:0] a); return a[31:22] == 10'h008 || a[31:15] == 17'h1FFFE; endfunction
`endif
  wire mpu_en  = ctrl[0];
  wire dc_en   = ctrl[2];
  wire ic_en   = ctrl[12];
  wire dtcm_en = ctrl[16];
  wire dtcm_ld = ctrl[17];                  // load mode: reads ignore the DTCM
  wire itcm_en = ctrl[18];
  wire itcm_ld = ctrl[19];
  assign hivecs = ctrl[13];

  // size mask over address bits 31:12 for a region of 2**(n+1) bytes
  function automatic logic [19:0] rmask_of(input logic [4:0] n);
    logic [32:0] sz;
    sz = 33'd2 << n;
    return (n < 5'd11) ? 20'hFFFFF : ~sz[31:12] + 20'd1;
  endfunction
  // TCM virtual size 512 << n bytes
  function automatic logic [19:0] tmask_of(input logic [4:0] n);
    logic [40:0] sz;
    sz = 41'd512 << n;
    return (n < 5'd3) ? 20'hFFFFF : (n >= 5'd23) ? 20'h0 : ~sz[31:12] + 20'd1;
  endfunction

  function automatic logic ap_ok(input logic [3:0] ap, input logic priv, input logic wr);
    case (ap)
      4'd1: return priv;
      4'd2: return priv || !wr;
      4'd3: return 1'b1;
      4'd5: return priv && !wr;
      4'd6: return !wr;
      default: return 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------- RAMs
  // ITCM 32 KB: port B = data reads (E3), port A = fetch reads (F) and
  // data writes (WB, never in the same cycle as an ARM9 fetch)
  logic [12:0] itcm_aa;
  logic [3:0]  itcm_we;
  logic [31:0] itcm_aq, itcm_bq;
  logic        itcm_steal = 1'b0;           // MEM1: last cycle's ITCM write used port A (the fetch read the write's data)
  // DTCM 16 KB: port B = reads (E3), port A = writes (WB)
  logic [3:0]  dtcm_we;
  logic [31:0] dtcm_bq, dtcm_aq;
  // Cache geometry. 4 ways: D 32 sets, I 64 sets; 2 ways: twice as many.
  localparam int WB  = (WAYS == 4) ? 2 : 1;           // way index bits (D)
  localparam int IWB = (IWAYS == 4) ? 2 : 1;          // way index bits (I)
  localparam int VWB = (WB > IWB) ? WB : IWB;         // the victim way, shared by both fills (each side uses its low bits)
  localparam int DSB = 7 - WB + XD, ISB = 8 - IWB + XI;          // set index bits
  localparam int DTW = 27 - DSB, ITW = 27 - ISB;      // tag bits (address 31 down)
  localparam int DLW = DTW + 2, ILW = ITW + 2;        // tag lane: (D) valid, dirty, tag; (I) main, valid, tag
  // D-cache: WAYS ways of 1 KB x 4/WAYS; tags: DSB-bit sets x WAYS+1 lanes (way
  // w: valid, dirty, tag; lane WAYS: round-robin counter), written per lane
  logic [DSB+2:0] dc_aa;
  logic [3:0]  dc_we [0:WAYS-1];
  logic [31:0] dc_ad;
  logic [31:0] dc_aq [0:WAYS-1], dc_bq [0:WAYS-1];
  logic [DSB-1:0] dt_aa;
  logic [WAYS:0]  dt_we;
  logic [(WAYS+1)*DLW-1:0] dt_ad, dt_aq, dt_bq;
  // I-cache: the same with ISB-bit sets and lanes of valid, tag
  logic [ISB+2:0] ic_aa;
  logic [IWAYS-1:0] ic_we;                  // one bit per way (whole word)
  logic [31:0] ic_ad;
  logic [31:0] ic_aq [0:IWAYS-1], ic_bq [0:IWAYS-1];
  logic [ISB-1:0] it_aa;
  logic [IWAYS:0]  it_we;
  logic [(IWAYS+1)*ILW-1:0] it_ad, it_aq, it_bq;
  // way w's D tag lane of a row, as a mux over constant offsets (a select at
  // w*DLW with DLW = 23 became a multiplier, nds-fit #188)
  function automatic logic [DLW-1:0] dlane(input logic [WAYS*DLW-1:0] row, input logic [WB-1:0] w);
    dlane = row[DLW-1:0];
    for (int x = 1; x < WAYS; x++) if (w == x[WB-1:0]) dlane = row[x*DLW +: DLW];
  endfunction
  // a set/way operand's way and set (MCR c7, opc2 2)
  function automatic logic [IWB-1:0] sw_wayi(input logic [31:0] v);
    return v[30 +: IWB];
  endfunction
  function automatic logic [WB-1:0] sw_way(input logic [31:0] v);
    return v[30 +: WB];
  endfunction
  // (the DS's 128 / 256 lines are reached by the operand as before; the 2^XD / 2^XI extra sets are swept by
  // the alias counters swa_d / swa_i: one set/way operation visits every alias, so a clean loop over the DS's
  // ways and sets still reaches every line)
  function automatic logic [DSB-1:0] sw_dset(input logic [31:0] v, input logic [3:0] al);
    logic [DSB-1:0] base;
    base = (WAYS == 4) ? DSB'(v[DSB-XD+4:5]) : DSB'({v[31], v[DSB-XD+3:5]});
    return base | (DSB'(al) << (DSB - XD));
  endfunction
  function automatic logic [ISB-1:0] sw_iset(input logic [31:0] v, input logic [3:0] al);
    logic [ISB-1:0] base;
    base = (IWAYS == 4) ? ISB'(v[ISB-XI+4:5]) : ISB'({v[31], v[ISB-XI+3:5]});
    return base | (ISB'(al) << (ISB - XI));
  endfunction
  logic [3:0] swa_d, swa_i;                 // the alias sets visited so far by the running set/way operation
  wire sw_more_d = XD != 0 && cmo_op[2:0] == 3'd2 && swa_d != 4'((1 << XD) - 1);
  wire sw_more_i = XI != 0 && cmo_op[2:0] == 3'd2 && swa_i != 4'((1 << XI) - 1);

  logic [31:0] w_addr, w_wdata;             // registered data request (WB)
  // w_addr's page bits again, kept for the region match alone (RC8 #2251: w_addr -> w_rm -> C/B -> d_ok -> the core's
  // stall -> temp_base, -0.28 ns; w_addr also feeds the TCM, tag, read-buffer and data selects)
  (* preserve, dont_merge *) logic [9:0] w_pg;
  // and w_addr's bits again for the read data's selects alone (the TCM matches and the read buffer's hit that pick
  // d_rdata): #2403/#2404 w_addr -> rb_hit / TCM match -> d_rdata -> the core's w_wd, -0.243 / -0.126 ns
  (* preserve, dont_merge *) logic [31:2] w_ra;
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (!rst && w_pg !== w_addr[21:12]) $error("arm9_mem: region page %h, w_addr's %h", w_pg, w_addr[21:12]);
  always_ff @(posedge clk) if (!rst && w_ra !== w_addr[31:2]) $error("arm9_mem: read-select address %h, w_addr's %h", w_ra, w_addr[31:2]);
`endif

  // Writes decided in WB, performed two cycles later (pw = the write now
  // performed, qw = the one decided last cycle)
  logic        qw_v, pw_v;                  // any write
  logic [31:0] qw_a, pw_a, qw_d, pw_d;
  logic [3:0]  qw_be, pw_be;
  logic        qw_itcm, pw_itcm, qw_dtcm, pw_dtcm, qw_dc, pw_dc, qw_tag, pw_tag;
  logic [WB-1:0] qw_way, pw_way;
  // the write performed this cycle (port A): pw, or under SLOW the one WB
  // decides now (at 67 MHz the decision reaches the RAMs in the same cycle;
  // the same CPU's next access reads them a cycle later, so nothing to forward)
  logic        xw_itcm, xw_dtcm, xw_dc, xw_tag;
  logic [31:0] xw_a, xw_d;
  logic [3:0]  xw_be;
  logic [WB-1:0] xw_way;

  arm9_ram #(.AW(13)) u_itcm (.clk(clk), .a_addr(itcm_aa), .a_we(itcm_we), .a_d(xw_d),
    .a_q(itcm_aq), .b_addr(d_addr[14:2]), .b_q(itcm_bq));
  arm9_ram #(.AW(12)) u_dtcm (.clk(clk), .a_addr(xw_a[13:2]), .a_we(dtcm_we), .a_d(xw_d),
    .a_q(dtcm_aq), .b_addr(d_addr[13:2]), .b_q(dtcm_bq));
  genvar gw;
  generate for (gw = 0; gw < WAYS; gw = gw + 1) begin : dway
    arm9_ram #(.AW(DSB+3)) u_d (.clk(clk), .a_addr(dc_aa), .a_we(dc_we[gw]), .a_d(dc_ad),
      .a_q(dc_aq[gw]), .b_addr(d_addr[DSB+4:2]), .b_q(dc_bq[gw]));
  end endgenerate
  genvar gi;
  generate for (gi = 0; gi < IWAYS; gi = gi + 1) begin : iway
    arm9_ram #(.AW(ISB+3)) u_i (.clk(clk), .a_addr(ic_aa), .a_we({4{ic_we[gi]}}), .a_d(ic_ad),
      .a_q(ic_aq[gi]), .b_addr(i_addr[ISB+4:2]), .b_q(ic_bq[gi]));
  end endgenerate
  // DTRIM (MEM1, the card's form): a D tag lane stores only {valid, tag bits 21:DSB+5}. The D side caches main RAM's
  // first 4 MiB alone (known difference: `found`, w_addr[31:22] == 0x008, gates every fill), so a valid lane's address
  // bits 31:22 are always 0x008; every read of a lane's tag (the lookup, a by-MVA operation, the eviction address) is
  // gated by its valid bit, so the constant is put back on the read and an invalid lane's dropped bits never matter.
  // The lane's dirty bit is not stored either (MEM1 keeps the dirty bits in their own RAM; S_TAG takes dirt_q, the
  // write paths only clear it). The second way's lane is then one block (a true dual-port M10K is 20 bits wide: 11
  // bits on the card instead of 21): -1 M10K. Simulation: $error on a valid lane written with other high bits
  localparam bit DTRIM = SLOW && (OPT & 524288) != 0;              // (= MEM1, declared below)
  localparam int DSW = DTRIM ? DTW - 9 : DLW;                       // stored D lane
  logic [(WAYS+1)*DSW-1:0] dts_ad, dts_aq, dts_bq;
  generate if (DTRIM) begin : g_dtrim
    always_comb for (int x = 0; x <= WAYS; x++) begin
      if (x == WAYS) begin                                          // the counter lane (WB bits)
        dts_ad[x*DSW +: DSW] = dt_ad[x*DLW +: DSW];
        dt_aq[x*DLW +: DLW] = DLW'(dts_aq[x*DSW +: DSW]);
        dt_bq[x*DLW +: DLW] = DLW'(dts_bq[x*DSW +: DSW]);
      end else begin
        dts_ad[x*DSW +: DSW] = {dt_ad[x*DLW + DTW + 1], dt_ad[x*DLW +: DTW - 10]};
`ifdef ARM9_DTRIM_MUT
        dts_ad[x*DSW] = 1'b0;                                       // deliberate bug: tag bit 12 not kept
`endif
        dt_aq[x*DLW +: DLW] = {dts_aq[x*DSW + DSW - 1], 1'b0, 10'h008, dts_aq[x*DSW +: DTW - 10]};
        dt_bq[x*DLW +: DLW] = {dts_bq[x*DSW + DSW - 1], 1'b0, 10'h008, dts_bq[x*DSW +: DTW - 10]};
      end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
      if (!rst) for (int x = 0; x < WAYS; x++)
        if (dt_we[x] && dt_ad[x*DLW + DTW + 1] && dt_ad[x*DLW + DTW - 10 +: 10] != 10'h008)
          $error("arm9_mem: DTRIM: valid D tag lane %0d written with address bits 31:22 %h, not 008", x, dt_ad[x*DLW + DTW - 10 +: 10]);
`endif
  end else begin : g_dfull
    assign dts_ad = dt_ad;
    assign dt_aq = dts_aq;
    assign dt_bq = dts_bq;
  end endgenerate
  arm9_ram #(.AW(DSB), .LANES(WAYS+1), .LANE_W(DSW), .FOLD(1'b1)) u_dtag (.clk(clk), .a_addr(dt_aa), .a_we(dt_we),
    .a_d(dts_ad), .a_q(dts_aq), .b_addr(d_addr[DSB+4:5]), .b_q(dts_bq));
  // ITRIM (MEM1): an I tag lane stores only {valid, tag bits 23:ISB+5}. The I side fills its two cacheable ranges alone
  // (icr, known difference: main RAM proper, address bits 31:22 0x008, and the BIOS, bits 31:15 0x1FFFE; a demand fill
  // needs ip_cach = f_ic; the prefetch takes the next line inside the demand line's 4 KiB page, inside the same range),
  // so a valid lane's cacheable flag is 1 and its address bits 31:24 follow from bit 23 (0 main RAM: 0x02, 1 the BIOS:
  // 0xFF). Every read of a lane's flag or tag (the lookup, a by-MVA invalidate, the prefetch's presence check) is gated
  // by its valid bit, so they are put back on the read (flag = valid). Ways 1..IWAYS-1's lanes are then one block each
  // (13 bits on the card with 4 ways instead of 22): -3 M10K (lane 0 shares the counter's 32-bit FOLD RAM either way).
  // Simulation: $error on a valid lane written with flag 0 or other high bits
  localparam bit ITRIM = DTRIM;
  localparam int ISW = ITRIM ? ITW - 7 : ILW;                       // stored I lane
  logic [(IWAYS+1)*ISW-1:0] its_ad, its_aq, its_bq;
  function automatic logic [7:0] ihi(input logic b23); return b23 ? 8'hFF : 8'h02; endfunction   // tag bits 31:24
  generate if (ITRIM) begin : g_itrim
    always_comb for (int x = 0; x <= IWAYS; x++) begin
      if (x == IWAYS) begin                                         // the counter lane (IWB bits)
        its_ad[x*ISW +: ISW] = it_ad[x*ILW +: ISW];
        it_aq[x*ILW +: ILW] = ILW'(its_aq[x*ISW +: ISW]);
        it_bq[x*ILW +: ILW] = ILW'(its_bq[x*ISW +: ISW]);
      end else begin
        its_ad[x*ISW +: ISW] = {it_ad[x*ILW + ITW], it_ad[x*ILW +: ITW - 8]};
`ifdef ARM9_ITRIM_MUT
        its_ad[x*ISW + ITW - 9] = 1'b0;                             // deliberate bug: tag bit 23 (the range) not kept
`endif
        it_aq[x*ILW +: ILW] = {{2{its_aq[x*ISW + ISW - 1]}}, ihi(its_aq[x*ISW + ITW - 9]), its_aq[x*ISW +: ITW - 8]};
        it_bq[x*ILW +: ILW] = {{2{its_bq[x*ISW + ISW - 1]}}, ihi(its_bq[x*ISW + ITW - 9]), its_bq[x*ISW +: ITW - 8]};
      end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
      if (!rst) for (int x = 0; x < IWAYS; x++)
        if (it_we[x] && it_ad[x*ILW + ITW] && (!it_ad[x*ILW + ITW + 1] ||
            it_ad[x*ILW + ITW - 8 +: 8] != ihi(it_ad[x*ILW + ITW - 9])))
          $error("arm9_mem: ITRIM: valid I tag lane %0d written with flag %b, address bits 31:23 %h", x,
                 it_ad[x*ILW + ITW + 1], it_ad[x*ILW + ITW - 9 +: 9]);
`endif
  end else begin : g_ifull
    assign its_ad = it_ad;
    assign it_aq = its_aq;
    assign it_bq = its_bq;
  end endgenerate
  arm9_ram #(.AW(ISB), .LANES(IWAYS+1), .LANE_W(ISW), .FOLD(1'b1)) u_itag (.clk(clk), .a_addr(it_aa), .a_we(it_we),
    .a_d(its_ad), .a_q(its_aq), .b_addr(i_addr[ISB+4:5]), .b_q(its_bq));

  // ---------------------------------------------------------------- state machine state
  typedef enum logic [3:0] {
    S_IDLE, S_WDRAIN, S_RD1, S_IRD1, S_TAG, S_EVRD, S_EVWR, S_FILL, S_TAGW,
    S_ITAG, S_IFILL, S_ITAGW, S_INV, S_EVRD2, S_EVDRN, S_PFCHK
  } st_t;
  st_t         st;
  logic        busy_d, busy_i;              // the machine owns the D / I RAMs
  // The cycle after the machine owned the RAMs: a lookup answered now read its
  // tags while the machine could write them on port A (a fill's tag row, an
  // invalidate), and a mixed-port read of a written row is undefined. Such a
  // lookup is refused once and retried, and starts nothing: on the Pocket a
  // fetch kept landing on the I-cache fill's tag write, missed on the stale
  // row and refilled the same line forever (NSMB's cache-flush loop).
  logic        col_d = 1'b0, col_i = 1'b0;
  logic        ev_v;                        // EVB: the eviction buffer holds a line to write back
  // EVY (OPT[6], EVBW = 0): a bus-idle drain (entered from S_IDLE) yields after any word to a pending read or fill
  // of another line (ev_pass) and resumes with the words left (ev_k); a drain a fill is waiting for (entered from
  // S_TAG) runs on
  localparam bit EVY = (OPT & 64) != 0;
  logic [2:0]  ev_k;
  logic [1:0]  vdh, ev_dh;                  // the victim's / the eviction buffer's dirty halves {upper, lower}
  // a write-back skips a clean half's words (no bus write: main RAM keeps what a DMA put there); EVBW writes the
  // whole block. ARM9_HDIRTY_MUT (mutant): every word written, as before
`ifdef ARM9_HDIRTY_MUT
  wire         ev_skip = 1'b0, wr_skip = 1'b0;
`else
  wire         ev_skip = st == S_EVDRN && !EVBW && !ev_dh[k[2]];
  wire         wr_skip = st == S_EVWR && !vdh[k[2]];
`endif
  logic        ev_idle;
  logic [26:0] ev_a;                        // its line address {tag, set}
  // (one write address, so it really is an MLAB: two kept 256 flops, the 8:1 read mux and the write decode)
  (* ramstyle = "M10K, no_rw_check" *) logic [31:0] ev_d [0:7];   // (read a clock ahead: M10K, not 2 MLAB LABs)
  logic [31:0] ev_rd;                       // the drain's word (ev_ra below)
  // write buffer: a FIFO of WBD entries (1: the one-entry buffer; MEM1: 8, so an STM8 to uncached memory does not
  // replay on every word: the replay flushes the pipe and refetches, which hurts most with uncached code)
  localparam int WBD = (SLOW && (OPT & 524288) != 0) ? 8 : 1;
  logic [3:0]  wb_n;                        // entries used
  // (an MLAB with read and write pointers: {address, data, timer one-hot (wb_a is a timer register,
  // 0x04000100-0x0400010F, for the fabric), byte enables})
  (* ramstyle = "M10K, no_rw_check" *) logic [71:0] wb_m [0:WBD-1];   // (head read a clock ahead: M10K, not 4 MLAB LABs)
  logic [2:0]  wb_rp, wb_wp;
  wire         wbuf_v = wb_n != 4'd0;
  wire         wb_full = wb_n == 4'(WBD);
  // the head entry, read a clock ahead (first word fall through): the RAM reads the next head every clock, and a push
  // into the slot that becomes the head is bypassed
  logic [71:0] wb_rd, wb_bd;
  logic        wb_byp;
  wire  [71:0] wb_q = wb_byp ? wb_bd : wb_rd;
  wire  [31:0] wbuf_a = wb_q[71:40], wbuf_d = wb_q[39:8];
  wire  [3:0]  wbuf_tmr = wb_q[7:4], wbuf_be = wb_q[3:0];
  logic        rbuf_v;                      // uncached data read result
  logic [31:0] rbuf_a, rbuf_d;
  logic        ibuf_v;                      // uncached fetch result
  logic [31:0] ibuf_a, ibuf_d;
  logic        dp_v;                        // pending data request
  logic [2:0]  dp_kind;
  logic [31:0] dp_a, dp_val;
  logic        ip_v;                        // pending instruction request
  logic        iline;                       // I-cache line maintenance in progress
  logic        ip_cach;
  logic [31:0] ip_a;
  // OPT[4]: next-line instruction prefetch. When a demand fill of line L ends, the line after it (same 4 KB
  // page, so the same region and permissions) is looked up (S_PFCHK) and, if absent, filled through the
  // demand fill's own states (pf_run: they work on pf_a, leave the fetch free to hit other lines and let
  // a demand miss queue behind it). One line ahead, no chaining.
  localparam bit PF = (OPT & 16) != 0;
  // OPT[22] (ERI) / OPT[23] (ERD): early restart. A demand fill writes the line's words 0..7 in order (k); a fetch
  // (ERI) or load (ERD) of that line takes word j from the cache RAM once j <= k - 2 (j was written at least a
  // clock before the RAM read: port B reads the word port A wrote, never the one it writes), or j <= 6 in the
  // tag-write clock, instead of waiting for the tag write. OPT[28:24] (ERL): a refused load's fetch hold ends once
  // the fill's words have begun and word j is due within ERL beats (its beat + 2 <= k + ERL): the replayed load waits
  // in D (A9_OPT bit 1) and reaches WB ~5 clk after the release. A clock count from the request (tried: ERT) cannot
  // follow the PSRAM's first word, whose time varies with the other masters; too early costs another replay
  localparam bit ERI = (OPT & 4194304) != 0;
  localparam bit ERD = (OPT & 8388608) != 0;
  localparam logic [4:0] ERL = 5'((OPT >> 24) & 31);
  // OPT[29] (HUM): hit under miss. While a D fill writes its line (S_FILL), a load that hits another set is answered
  // as usual: the tag and data reads are port B's at the load's own set; port A writes only the filling set's line
  localparam bit HUM = (OPT & 536870912) != 0;
  // OPT[30] (CWF): critical word first. A demand fill asks for its line from the missed word (the bus and PSRAM
  // wrap the burst at the line's end: nds_psram CWF, BCR wrap 8), so beat k carries word fs + k (fsd / fsi: the
  // missed word of the D / I fill; 0 without CWF and for a prefetch fill); k still counts the beats
  localparam bit CWF = (OPT & 1073741824) != 0;
  wire  [2:0] fsd, fsi, fsd_f;
  // MEM1 (OPT[19], SLOW only): accesses may follow each other every cycle. A store writes the RAMs in its own WB cycle
  // while the next access reads them (port B, same address: undefined, the model inverts it), so that access gets the
  // written bytes merged in (pw); the dirty bits live in flops, since a tag row write would be a read-during-write
  // for any next lookup of the same set.
  localparam bit MEM1 = SLOW && (OPT & 524288) != 0;
  logic        pf_run;
  logic        ier, der;                    // ERI / ERD: the fetch / load is answered from the line being filled
  logic [26:0] pf_a;
  wire  [31:0] ia = pf_run ? {pf_a, 5'b0} : ip_a;
  // EVB: a read or fill of another line (compared as main-RAM mirrors, address bits 21:5) goes ahead of the
  // eviction drain when no store waits: the drain then lands behind it (the DS's dirty eviction costs nothing)
  wire         ev_pass = ev_v && !wbuf_v &&
                         ((dp_v && (dp_kind == DK_FILL || dp_kind == DK_RD1) && dp_a[21:5] != ev_a[16:0]) ||
                          (!dp_v && ip_v && ip_a[21:5] != ev_a[16:0]));
  logic        cmo_done;                    // maintenance op finished (replayed MCR answers ready)
  logic [15:0] cmo_op;
  logic [31:0] cmo_val;

  localparam logic [2:0] DK_FILL = 3'd0, DK_RD1 = 3'd1, DK_INV_D = 3'd2, DK_INV_I = 3'd3,
                         DK_LINE = 3'd4, DK_DRAIN = 3'd5;

  // ---------------------------------------------------------------- F2: fetch answer
  logic        f_req, f_priv;
  logic [31:0] f_addr;
  logic        f_cach;                      // the fetch is cacheable
  logic        f_ic;                        // registered with f_addr: MPU and I-cache on, main RAM (from i_addr; a c1 write
                                            // in WB this cycle is forwarded). #2398: ctrl[12] -> i_rdata -> q_cls, -0.221 ns
  // The fetch's region matches and ITCM match, registered with f_addr: decided from i_addr against
  // the c6/c9 values these registers hold next cycle (an MCR in WB this cycle is forwarded)
  logic [7:0]  f_rm;
  logic        f_tm;
  // synthesis translate_off
  always @(posedge clk)
    if (!rst && f_req && f_ic)
      for (int w = 0; w < IWAYS; w++)
        if ((it_bq[w*ILW + ITW] && it_bq[w*ILW + ITW + 1] && it_bq[w*ILW +: 19 - ISB] == f_addr[23:ISB+5]) !=
            (it_bq[w*ILW + ITW] && it_bq[w*ILW +: ITW] == f_addr[31:ISB+5]))
          $display("arm9_mem: ERROR: the short I-tag compare differs from the full one (way %0d) at %0t", w, $time);
  always_ff @(posedge clk)
    if (!rst && der && wd_thit && wd_rway != vway[WB-1:0])
      $display("arm9_mem: ERROR: load early restart with a tag hit in way %0d, not the fill's way %0d at %0t", wd_rway, vway, $time);
  always_ff @(posedge clk)
    if (!rst && ier && f_ic)
      for (int w = 0; w < IWAYS; w++)
        if (w[IWB-1:0] != vway[IWB-1:0] && it_bq[w*ILW + ITW] && it_bq[w*ILW + ITW + 1] && it_bq[w*ILW +: 19 - ISB] == f_addr[23:ISB+5])
          $display("arm9_mem: ERROR: early restart with a hit in way %0d, not the fill's way %0d at %0t", w, vway, $time);
  // at most one I way hits a cacheable fetch (the fetch answer's one-hot AND-OR relies on it)
  always_ff @(posedge clk)
    if (!rst && f_req && f_ic) begin
      int nh; nh = 0;
      for (int w = 0; w < IWAYS; w++)
        if (it_bq[w*ILW + ITW] && it_bq[w*ILW + ITW + 1] && it_bq[w*ILW +: 19 - ISB] == f_addr[23:ISB+5]) nh++;
      if (nh > 1) $display("arm9_mem: ERROR: %0d I ways hit %h at %0t", nh, f_addr, $time);
    end
  // synthesis translate_on

  always_comb begin
    logic        found, hit, cach, itcm;
    logic [2:0]  idx;
    logic [15:0] ihw [0:IWAYS-1];
    logic [15:0] ohw;
    logic [4:0]  icls [0:IWAYS-1];
    logic [6:0]  itop [0:IWAYS-1];
    logic [IWAYS-1:0] hv;                   // each way's hit (the loop's compare)
    logic [IWAYS-1:0] sel;                  // the way whose word is the answer (one-hot or none)
    logic        ifl;                       // an I fill of the fetch side runs (registers only)
    found = 1'b0; idx = 3'd0;   // pocket-now: no I-side MPU lookup; only main RAM is I-cacheable (known difference)
    cach = f_ic;
    f_cach = cach;
    // the registered match (f_tm, checked against this compare below), also under SLOW (RC6 #2098: f_addr -> the
    // ITCM compare -> i_rdata -> the core's Thumb expansion -> q_w, -0.73 ns)
    itcm = itcm_en && !itcm_ld && f_tm;
    hit = 1'b0; hv = '0;
    for (int w = 0; w < IWAYS; w++)
      // a cacheable line (bit ITW+1, set at the fill: icr, main RAM or the BIOS) and tag bits 23:ISB+5 only (RC11
      // #2436 I-tag -> hit -> i_rdata -> q_cls -2.98 ns, 19-bit compare): this hit counts only for a cacheable fetch
      // (f_ic: icr), for which the full compare is exactly this one (bits 31:24 follow from 23:22 in both ranges)
      if (it_bq[w*ILW + ITW] && it_bq[w*ILW + ITW + 1] && it_bq[w*ILW +: 19 - ISB] == f_addr[23:ISB+5]) begin
        hit = 1'b1; hv[w] = 1'b1;
      end
    i_abort = 1'b0;   // pocket-now: no MPU fetch aborts (known difference)
    // without a hit, the fill's way: the early restart (ier) reads the line being filled, and ier implies no hit in
    // another way (the line missed; checked in simulation); without ier and without a hit i_ok refuses the answer,
    // which design B's queue overwrites. ier is left on i_ok alone, off the data (RC11 #2443: f_addr / ip_a -> ier ->
    // the way -> i_rdata -> Thumb -> q_w -2.44 ns)
    // the fetch answer as a one-hot AND-OR of the ways' hits, without the encoded way, the no-hit test or the last-
    // hit priority (RC12f #2581 / #2584 / #2587: I-tag -> hit -> i_rhw -> u_thumb -> q_w / q_cls, the one cone that
    // recurs, up to -0.735 ns). The no-hit answer comes from early registers only: during an I fill of the fetch
    // side (ifl: S_IFILL / S_ITAGW, no prefetch, no line maintenance) busy_i refuses every hit and the answer is
    // used only on ier, which needs ifl and reads the fill's way (no other way hits then, checked above), so ifl
    // picks the fill's way and drops the hits; outside ifl an answer without a hit is refused (i_ok needs hit or
    // ier) and reads 0. At most one way hits (checked below), so the OR is the loop's last hit. Taken answers are
    // the same as before; refused ones lie beyond the queue's count (design B) and are overwritten
    ifl = (st == S_IFILL || st == S_ITAGW) && !pf_run && !iline;
    for (int w = 0; w < IWAYS; w++)
`ifdef ARM9_OHS_MUT
      sel[w] = !itcm && cach && (ifl ? (w[IWB-1:0] == vway[IWB-1:0]) : (hv[w] && w != 0));   // (mutant: way 0's hit lost)
`else
      sel[w] = !itcm && cach && (ifl ? (w[IWB-1:0] == vway[IWB-1:0]) : hv[w]);
`endif
    i_rdata = (!itcm && cach) ? 32'h0 : itcm ? itcm_aq : ibuf_d;
    for (int w = 0; w < IWAYS; w++) i_rdata = i_rdata | (ic_bq[w] & {32{sel[w]}});
    // the Thumb halfword, selected by i_hsel (an early register) in every way and in the other sources before the
    // way select (RC12c-ns #2566 7asR -0.506 ns); the same function as i_rdata's halfword (checked in arm9_core)
    for (int w = 0; w < IWAYS; w++)
`ifdef ARM9_HSEL_MUT
      ihw[w] = (i_hsel ^ (w == 0)) ? ic_bq[w][31:16] : ic_bq[w][15:0];   // (mutant: way 0's halves swapped)
`else
      ihw[w] = i_hsel ? ic_bq[w][31:16] : ic_bq[w][15:0];
`endif
    ohw = itcm ? (i_hsel ? itcm_aq[31:16] : itcm_aq[15:0]) : (i_hsel ? ibuf_d[31:16] : ibuf_d[15:0]);
    i_rhw = (!itcm && cach) ? 16'h0 : ohw;
    for (int w = 0; w < IWAYS; w++) i_rhw = i_rhw | (ihw[w] & {16{sel[w]}});
    // the Thumb class decoded from each way's halfword in parallel with the tag compare and selected by the same
    // one-hot (ffvshadow #2594 1asR / #2595 7asR: I-tag -> sel -> i_rhw -> thumb_class -> a_cls -> q_cls -0.622 /
    // -0.654 ns); the same function as thumb_class(i_rhw) (checked in arm9_core)
    for (int w = 0; w < IWAYS; w++)
`ifdef ARM9_TCLS_MUT
      icls[w] = thumb_class(w == 0 ? ihw[1] : ihw[w]);   // (mutant: way 0's class from way 1's halfword)
`else
      icls[w] = thumb_class(ihw[w]);
`endif
    i_rcls = (!itcm && cach) ? 5'd0 : thumb_class(ohw);
    for (int w = 0; w < IWAYS; w++) i_rcls = i_rcls | (icls[w] & {5{sel[w]}});
    // and the Thumb expansion's kind and condition field the same way (RC13b #2611 1asR -0.510 ns into q_w's top
    // bits, #2610 7asR -0.230); the same function as u_thumb's kind and arm[31:28] (checked in arm9_core)
    for (int w = 0; w < IWAYS; w++)
`ifdef ARM9_TTOP_MUT
      itop[w] = thumb_top(w == 0 ? ihw[1] : ihw[w]);   // (mutant: way 0's from way 1's halfword)
`else
      itop[w] = thumb_top(ihw[w]);
`endif
    i_rtop = (!itcm && cach) ? 7'd0 : thumb_top(ohw);
    for (int w = 0; w < IWAYS; w++) i_rtop = i_rtop | (itop[w] & {7{sel[w]}});
    if (!f_req || i_abort) i_ok = 1'b1;
    else if (itcm)         i_ok = !(MEM1 && itcm_steal);   // MEM1: a data write to the ITCM took port A in the fetch's cycle: fetch again
    else if (cach)                 i_ok = (hit && !busy_i && !col_i &&
                                   !(pf_run && st == S_IFILL && f_addr[ISB+4:5] == pf_a[ISB-1:0])) || ier;
    else                           i_ok = ibuf_v && ibuf_a[31:2] == f_addr[31:2];
  end

  // ---------------------------------------------------------------- WB: data answer
  logic        w_req, w_we, w_priv, w_cp, w_cpwe;
  // MEM1: the uop in WB is squashed by a redirect out of WB2 (the older access was refused or aborted, or a load
  // into the PC): it must not perform anything here. (Before MEM1 a memory access never followed another by
  // less than two cycles, so the squashed uop was never a memory access.)
  wire         wq_e  = w_req && !d_kill;
  wire         wcp_e = w_cp  && !d_kill;
  logic [3:0]  w_be;
  logic [15:0] w_cpop;

  logic        wd_itcm, wd_dtcm, wd_cach, wd_buf, wd_hit, wd_abort;
  // the D ways' short tag hits (valid, bits 21:DSB+5): the read data's select and, under DTRIM, the full hit
  logic [WAYS-1:0] hsv;
  always_comb for (int w = 0; w < WAYS; w++)
    hsv[w] = dt_bq[w*DLW + DTW + 1] && dt_bq[w*DLW +: 17 - DSB] == w_addr[21:DSB+5];
  logic [31:0] d_rdata;
  logic [WB-1:0] wd_way;
  logic          wd_thit;                   // the tag compare alone (without der)
  logic [WB-1:0] wd_rway;                   // the read data's way: the tag hit's, else the fill's (no der)
  logic        wd_store_cache, wd_push, wd_need;   // need: a request for the machine
  logic        wd_tcmw;                             // store into a TCM
  logic [2:0]  wd_kind;
  logic [31:0] cp_rd;
  logic        cp_write, cp_isop, cp_ok;
  logic [2:0]  cp_kind;

  wire [3:0] w_crn  = w_cpop[10:7];
  wire [3:0] w_crm  = w_cpop[6:3];
  wire [2:0] w_opc2 = w_cpop[2:0];

  always_comb begin
    // each region's permission is decided before the address match, so the
    // priority select (the highest matching region wins) picks single bits
    logic       found, ok, cach, bufr;
    logic [7:0] r_ok;
    for (int n = 0; n < 8; n++) r_ok[n] = ap_ok(dap[n*4 +: 4], w_priv, w_we);
    // cacheable/bufferable only in the 4 MiB of main RAM at 0x02000000 (known difference), as the highest matching
    // region's C and B bits say there (no match: uncached, unbuffered); no permission checks (known difference)
    found = w_addr[31:22] == 10'h008; ok = 1'b1; cach = 1'b0; bufr = 1'b0;
    for (int n = 0; n < 8; n++)
      if (w_rm[n]) begin cach = dcb[n]; bufr = found && wbb[n]; end
    wd_abort = 1'b0;   // pocket-now: no MPU data aborts (known difference)
    wd_itcm  = itcm_en && ((w_addr[31:12] & itcm_mask) == 20'h0) && (w_we || !itcm_ld);
    wd_dtcm  = !wd_itcm && dtcm_en && ((w_addr[31:12] & dtcm_mask) == dtcm_base) && (w_we || !dtcm_ld);
    wd_cach  = mpu_en && dc_en && found && cach;
    wd_buf   = bufr;
    wd_hit = 1'b0; wd_way = '0;
    // (DTRIM: a lane's bits 31:22 read back as 0x008, so the full compare is the short one (hsv, shared with the
    // read data's select) and found)
    for (int w = 0; w < WAYS; w++)
      if (DTRIM ? (hsv[w] && found) : (dt_bq[w*DLW + DTW + 1] && dt_bq[w*DLW +: DTW] == w_addr[31:DSB+5])) begin
        wd_hit = 1'b1; wd_way = w[WB-1:0];
      end
    wd_thit = wd_hit;
    // the read data's way without der (RC11 #2456 7asR: dp_a -> fsd -> der -> the way -> d_rdata -> m_ldv -> e_bw
    // -0.377 ns): der implies no tag hit in another way (the line missed; checked in simulation), and without a hit
    // and without der the read's d_sel_h is 0, so the cache word is not taken
    wd_rway = wd_hit ? wd_way : vway[WB-1:0];
    if (der) begin wd_hit = 1'b1; wd_way = vway[WB-1:0]; end
  end

  // read-back MLAB: written by MCR (the values as MRC returns them), read in WB
  always_comb begin
    cprb_ra = w_cprb_ra;
    cprb_wa = cprb_ra;
    cprb_we = cp_write && (w_crn == 4'd6 || w_crn == 4'd9 || w_crn == 4'd13);
    cprb_wd = w_wdata;
    if (w_crn == 4'd9 && w_crm == 4'd1)
      cprb_wd = w_opc2[0] ? {20'h0, 6'h0, w_wdata[5:1], 1'b0}
                          : {w_wdata[31:12], 6'h0, w_wdata[5:1], 1'b0};
  end
  // read with the request (cp_op's index, as w_cprb_ra), an MCR writing that entry at the same edge bypassed
  logic [31:0] cprb_rd, cprb_bd;
  logic        cprb_byp;
  assign cprb_q = cprb_v[cprb_ra] ? (cprb_byp ? cprb_bd : cprb_rd) : 32'h0;
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && w_cprb_ra !== ((w_crn == 4'd6) ? {1'b0, w_crm[2:0]} : (w_crn == 4'd9) ? {2'b10, w_crm != 4'd1, w_opc2[0]} : 4'd12))
      $error("arm9_mem: registered cprb address %h, w_cpop's %h", w_cprb_ra, w_cpop);
`endif
  always_ff @(posedge clk) begin
    if (cprb_we) cprb[cprb_wa] <= cprb_wd;
    cprb_rd  <= cprb[cprb_ra_of(cp_op)];
    cprb_byp <= cprb_we && cprb_wa == cprb_ra_of(cp_op);
    cprb_bd  <= cprb_wd;
    if (rst)          cprb_v[9:8] <= 2'b00;
    else if (cprb_we) cprb_v[cprb_wa] <= 1'b1;
  end

  // CP15 register reads and the maintenance operations
  always_comb begin
    logic [31:0] ap;
    ap = w_opc2[0] ? iap : dap;
    cp_rd = 32'h0;
    cp_isop = 1'b0;
    cp_kind = DK_DRAIN;
    case (w_crn)
      4'd0: cp_rd = (w_opc2 == 3'd1) ? 32'h0F0D2112 : (w_opc2 == 3'd2) ? 32'h00140180 : 32'h41059461;
      4'd1: cp_rd = ctrl;
      4'd2: cp_rd = {24'h0, w_opc2[0] ? icb : dcb};
      4'd3: cp_rd = {24'h0, wbb};
      4'd5: begin
        if (w_opc2[1]) cp_rd = ap;
        else for (int n = 0; n < 8; n++) cp_rd[n*2 +: 2] = ap[n*4 +: 2];
      end
      4'd6, 4'd9, 4'd13: cp_rd = cprb_q;
      4'd7: begin
        case ({w_crm, w_opc2})
          {4'd5, 3'd0}:  begin cp_isop = 1'b1; cp_kind = DK_INV_I; end
          {4'd6, 3'd0}:  begin cp_isop = 1'b1; cp_kind = DK_INV_D; end
          {4'd5, 3'd1}, {4'd5, 3'd2}, {4'd6, 3'd1}, {4'd6, 3'd2},
          {4'd10, 3'd1}, {4'd10, 3'd2}, {4'd14, 3'd1}, {4'd14, 3'd2}:
                         begin cp_isop = 1'b1; cp_kind = DK_LINE; end
          {4'd10, 3'd4}: begin cp_isop = 1'b1; cp_kind = DK_DRAIN; end
          default: ;     // WFI (the core halts), prefetch: nothing to do
        endcase
      end
      default: ;
    endcase
    cp_write = wcp_e && w_cpwe && !cp_isop;
  end

  wire [19:0] c6_msk = rmask_of(w_wdata[5:1]);   // a c6 write's region mask
  // the data request's region matches inside main RAM, in WB from the registered address (RC6 #2090/#2092: register
  // file / M forward -> address adder -> d_addr -> the compare -> w_rm, -0.56 / -1.17 ns). They are ready before the
  // tag compare that also decides the answer (that one waits for the tag RAM). A c6 write the request's E saw in WB
  // is in mr_* by now. mr_b is stored masked, so (a & m) == b is ((a ^ b) & m) == 0
  always_comb
    for (int n = 0; n < 8; n++)
      w_rm[n] = mr_v[n] && ((w_pg ^ mr_b[n]) & mask_of_cut(mr_cut[n])) == 10'h0;
  always_ff @(posedge clk) begin
    logic       w6, w9i;
    logic [19:0] tm;
    w6  = !rst && cp_write && w_crn == 4'd6;
    w9i = !rst && cp_write && w_crn == 4'd9 && w_crm == 4'd1 && w_opc2[0];
    for (int n = 0; n < 8; n++)
      if (rst)                       f_rm[n] <= 1'b0;
      else if (w6 && w_crm[2:0] == n[2:0])
        f_rm[n] <= w_wdata[0] && ((i_addr[31:12] ^ w_wdata[31:12]) & rmask_of(w_wdata[5:1])) == 20'h0;
      else
        f_rm[n] <= ren[n] && ((i_addr[31:12] ^ rbase[n]) & rmask[n]) == 20'h0;
    tm = rst ? 20'hFFFFF : w9i ? tmask_of(w_wdata[5:1]) : itcm_mask;
    // (the redirect's select is late, a condition's: it picks between two finished compares, RC8p2 #2275 cpsr_s ->
    // condition -> redirect -> i_addr -> f_tm, -0.69 ns)
    f_tm <= i_rdr ? (i_addr_r[31:12] & tm) == 20'h0 : (i_addr_s[31:12] & tm) == 20'h0;
    // the fetch's cacheability, as f_tm: ctrl as it will be next cycle (reset, or a c1 write in WB), the main-RAM
    // compare on both address candidates, the redirect's select last
    begin
      logic [31:0] nc;
`ifdef ARM9_FIC_MUT
      nc = rst ? RESET_CTRL : ctrl;
`else
      nc = rst ? RESET_CTRL : (cp_write && w_crn == 4'd1) ? (w_wdata & 32'h000FF085) | 32'h00000078 : ctrl;
`endif
      f_ic <= nc[0] && nc[12] && (i_rdr ? icr(i_addr_r) : icr(i_addr_s));
    end
  end
`ifndef SYNTHESIS
  // simulation: for a load that is answered, the hit select is the one through the region's C bit
  always_ff @(posedge clk)
    if (!rst && wq_e && !w_we && d_ok && !d_abort && d_sel_h !== (!wcp_e && !wd_itcm && !wd_dtcm && wd_cach && wd_hit))
      $error("arm9_mem: hit select %b without the C bit, %b with it (a=%h)", d_sel_h, !wcp_e && !wd_itcm && !wd_dtcm && wd_cach && wd_hit, w_addr);
`endif
`ifndef SYNTHESIS
  // simulation: w_rm as the compare and forward mux it replaces
  logic [7:0] w_rm_ref;
  always_ff @(posedge clk) begin
    for (int n = 0; n < 8; n++)
      if (rst) w_rm_ref[n] <= 1'b0;
      else if (cp_write && w_crn == 4'd6 && w_crm[2:0] == n[2:0])
        w_rm_ref[n] <= w_wdata[0] && ((w_wdata[31:22] ^ 10'h008) & c6_msk[19:10]) == 10'h0 &&
                       ((d_addr[21:12] ^ w_wdata[21:12]) & c6_msk[9:0]) == 10'h0;
      else
        w_rm_ref[n] <= mr_v[n] && (d_addr[21:12] & mask_of_cut(mr_cut[n])) == mr_b[n];
    if (!rst && w_rm !== w_rm_ref) $error("arm9_mem: data region matches %b, the compare's %b", w_rm, w_rm_ref);
  end
`endif
`ifndef SYNTHESIS
  // simulation: the registered matches are the ones F2 would compute from f_addr
  // (from the first reset on: with CPU_FAST it reaches clk late)
  logic chk_on = 1'b0;
  always_ff @(posedge clk) begin
    if (rst) chk_on <= 1'b1;
    if (!rst && chk_on) begin
      for (int n = 0; n < 8; n++)
        if (f_rm[n] !== (ren[n] && ((f_addr[31:12] ^ rbase[n]) & rmask[n]) == 20'h0))
          $error("arm9_mem: fetch region %0d match %b at %h", n, f_rm[n], f_addr);
      if (!rst && i_req && i_addr !== (i_rdr ? i_addr_r : i_addr_s))
        $error("arm9_mem: fetch address %h, its candidates' %h (redirect %b)", i_addr, i_rdr ? i_addr_r : i_addr_s, i_rdr);
      if (f_tm !== ((f_addr[31:12] & itcm_mask) == 20'h0))
        $error("arm9_mem: fetch ITCM match %b at %h", f_tm, f_addr);
      if (f_ic !== (mpu_en && ic_en && icr(f_addr)))
        $error("arm9_mem: fetch cacheable %b at %h (ctrl %h)", f_ic, f_addr, ctrl);
    end
  end
`endif

  // The read data, selected without the MPU's abort and the busy checks:
  // the core only uses it when the answer is ok and not an abort. Only the
  // cacheable bit, which decides between a cache hit and the uncached read
  // buffer, comes from the MPU, at the last mux (after the forwarding merge
  // below, which is done on both candidates: nds-fit #127's worst path).
  logic [31:0] d_rdata_h;                   // the cache-hit candidate
  wire         rb_hit = rbuf_v && rbuf_a[31:2] == w_ra;           // the uncached read buffer has this word
  // the TCM matches again, from w_ra, for the read data's select (wd_itcm / wd_dtcm still decide everything else)
  wire         rd_itcm = itcm_en && ((w_ra[31:12] & itcm_mask) == 20'h0) && (w_we || !itcm_ld);
  wire         rd_dtcm_r = dtcm_en && ((w_ra[31:12] & dtcm_mask) == dtcm_base) && (w_we || !dtcm_ld);
  wire         rd_dtcm = !rd_itcm && rd_dtcm_r;
  logic        d_sel_h;                     // ... is the answer
  logic        d_hs;                        // a way's short tag hits (below)
  always_comb begin
    if (wcp_e)         d_rdata = cp_rd;
    else if (rd_itcm) d_rdata = itcm_bq;
    else if (rd_dtcm) d_rdata = dtcm_bq;
    else              d_rdata = rbuf_d;
    // the cache word as a one-hot AND-OR of the ways' short tag hits (bits 21:DSB+5 and the valid bit), over the fill's
    // way when none hits, instead of dc_bq[wd_rway] behind the full compare's encoded way (rel15 #2749 block: D-tag ->
    // wd_rway -> d_rdata_h -> e_bw +0.238 ns, 13 endpoints). D lines are filled only from main RAM (wd_cach needs
    // found: bits 31:22 = 0x008), so a valid tag's bits 31:22 are 0x008 and where the word is used (d_sel_h: a full
    // hit, or der with no hit) the short hits are the full ones. Checked below against dc_bq[wd_rway]
    begin
      logic [WAYS-1:0] hs;
      hs = hsv;
      d_hs = |hs;
      d_rdata_h = |hs ? 32'h0 : dc_bq[vway[WB-1:0]];
      for (int w = 0; w < WAYS; w++)
`ifdef ARM9_DSH_MUT
        d_rdata_h = d_rdata_h | (dc_bq[w == 0 ? WAYS - 1 : w] & {32{hs[w]}});   // (mutant: way 0's hit takes the last way's word)
`else
        d_rdata_h = d_rdata_h | (dc_bq[w] & {32{hs[w]}});
`endif
    end
    // (not through wd_cach, the region match and its priority: RC6 #2097, w_addr -> w_rm -> C/B -> d_sel_h -> the
    // data mux -> the core's w_wd, -0.91 ns). The read buffer holds an uncached read's word for the next access that
    // completes, and a CP15 write completing first drops it, so where it hits the access is not cacheable; where the
    // tag hits but the region is not cacheable the access is refused, its data unused
    d_sel_h = !wcp_e && !rd_itcm && !rd_dtcm && wd_hit && !rb_hit;
  end

  // synthesis translate_off
  always @(posedge clk)
    if (!rst && wq_e && !w_we && d_sel_h && d_rdata_h !== dc_bq[wd_rway])
      $display("arm9_mem: ERROR: the cache word %h is not way %0d's %h at %0t", d_rdata_h, wd_rway, dc_bq[wd_rway], $time);
  // synthesis translate_on

  // the answer
  always_comb begin
    d_ok = 1'b1;
    d_abort = 1'b0;
    wd_store_cache = 1'b0;
    wd_push = 1'b0;
    wd_need = 1'b0;
    wd_kind = DK_FILL;
    wd_tcmw = 1'b0;
    cp_ok = 1'b1;
    if (wcp_e) begin
      if (cp_isop) begin
        if (cmo_done && cmo_op == w_cpop && cmo_val == w_wdata) cp_ok = 1'b1;
        else begin
          cp_ok = 1'b0;
          wd_need = 1'b1;
          wd_kind = cp_kind;
        end
      end
      d_ok = cp_ok;
    end else if (wq_e) begin
      if (wd_abort) begin
        d_abort = 1'b1;
      end else if (wd_itcm) begin
        wd_tcmw = w_we;
      end else if (wd_dtcm) begin
        wd_tcmw = w_we;
      end else if (der) begin
                                            // ERD: the word is in the line being filled
      end else if (HUM && st == S_FILL && dp_kind == DK_FILL && !w_we && wd_cach && wd_hit &&
                   w_addr[DSB+4:5] != dp_a[DSB+4:5]) begin
                                            // HUM: a hit in another set while the fill runs (col_d is not asked:
                                            // the states before S_FILL write no tag row, S_TAGW comes after)
      end else if (busy_d || dp_v || col_d) begin
        d_ok = 1'b0;                        // the machine is busy with the D side
      end else if (!w_we) begin
        if (wd_cach && wd_hit) begin
        end else if (!wd_cach && rb_hit) begin    // (rb_hit: the same compare on w_ra, w_addr[31:2]'s copy)
        end else begin
          d_ok = 1'b0;
          wd_need = 1'b1;
          wd_kind = wd_cach ? DK_FILL : DK_RD1;
        end
      end else begin
        // store: a write-back hit stays in the cache; everything else goes
        // through the one-entry write buffer
        if (wd_cach && wd_hit && wd_buf) begin
          wd_store_cache = 1'b1;
        end else if (wb_full) begin
          d_ok = 1'b0;                      // buffer full: try again after the drain
        end else begin
          wd_push = 1'b1;
          wd_store_cache = wd_cach && wd_hit;
        end
      end
    end
  end

  always_comb begin
    if (SLOW) begin
      xw_itcm = wd_tcmw && wd_itcm; xw_dtcm = wd_tcmw && wd_dtcm; xw_dc = wd_store_cache;
      xw_tag = wd_store_cache && wd_buf; xw_a = w_addr; xw_d = w_wdata; xw_be = w_be; xw_way = wd_way;
    end else begin
      xw_itcm = pw_itcm; xw_dtcm = pw_dtcm; xw_dc = pw_dc; xw_tag = pw_tag;
      xw_a = pw_a; xw_d = pw_d; xw_be = pw_be; xw_way = pw_way;
    end
  end

  logic same_chk;                           // (simulation: the merge's condition, for the load-data check)
  logic [31:0] ld_rest;                     // SLOW: the word without a TCM match (d_lw_rs)
  // the access right after a store may have read the RAM before the write
  // (not under SLOW: the write is in the store's own WB)
  always_comb begin
    logic same;
    logic [31:0] h, u;
    same = (!SLOW || MEM1) && pw_v && (pw_a[31:2] == w_addr[31:2]) &&
           ((pw_itcm && wd_itcm) || (pw_dtcm && wd_dtcm) || (pw_dc && !wd_itcm && !wd_dtcm));
    same_chk = same;
    h = d_rdata_h;
    ld_rest = 32'h0;
    if (SLOW) begin
      // SLOW: select first, merge once. The TCM matches (rd_itcm / rd_dtcm: the 20-bit region compares from w_ra)
      // select last, over a word chosen without them (CP15, the cache hit, the read buffer), instead of through
      // d_sel_h and d_rdata (rel15-ram #2732 7asR: w_ra -> rd_itcm -> d_sel_h -> d_rdata_f -> e_bw / w_wd -0.941 ns).
      // The same function as d_sel_h ? d_rdata_h : d_rdata: d_sel_h is the rest's hit select without a TCM match,
      // d_rdata's TCM words come after CP15 (checked below)
      logic [31:0] rest;
      logic use_cache;
      // the cache word's select from the short tag hits (or der), not wd_hit's full compare (rel15f #2785: D-tag -> hs ->
      // wd_hit -> rest -> d_rdata_f -> e_bw -0.262 ns): where a load completes from the cache (a full hit, or der) the
      // short hits are the full ones (main-RAM lines, above); a short hit without a full one and without the read
      // buffer is not answered (no d_ok), so its word is not used. Checked below on every answered load
      // arm9_core only consumes an accepted load. With no read-buffer
      // hit, the completion logic already proves the cache/fill word is
      // usable. Keep der on that completion path, outside the data mux.
      use_cache = !rb_hit && (A9C_RETURN || d_hs || der);
`ifdef ARM9_RBUF_OWNER_MUT
      if (A9C_RETURN) use_cache = 1'b1;   // mutant: ignore a matching buffered read
`endif
      rest = wcp_e ? cp_rd : use_cache ? d_rdata_h : rbuf_d;
      ld_rest = rest;
`ifdef ARM9_LDSEL_MUT
      u = (!wcp_e && rd_itcm) ? itcm_bq : (!wcp_e && rd_dtcm) ? itcm_bq : rest;   // (mutant: the DTCM read gives the ITCM word)
`else
      u = (!wcp_e && rd_itcm) ? itcm_bq : (!wcp_e && rd_dtcm) ? dtcm_bq : rest;
`endif
    end else
      u = d_rdata;
    // SLOW (a9c): no merge. arm9_core never requests a load in the clock after a store it does not kill (its
    // h_sl interlock: a load in D waits while E holds a store; proven unreachable for every input sequence,
    // sim/formal/a9_stld, ABC PDR), so `same` never meets a load here; checked below. (rel15 #2731/#2732: the
    // byte-merge muxes sat on the failing w_ra / w_addr -> d_rdata_f -> e_bw / w_wd paths)
    if (same && !wcp_e && !SLOW)
      for (int b = 0; b < 4; b++)
        if (pw_be[b]) begin
          h[b*8 +: 8] = pw_d[b*8 +: 8];
          u[b*8 +: 8] = pw_d[b*8 +: 8];
        end
    d_rdata_f = (d_sel_h && !SLOW) ? h : u;
  end
  assign d_lw_it = itcm_bq;
  assign d_lw_dt = dtcm_bq;
  assign d_lw_rs = SLOW ? ld_rest : d_rdata_f;
  assign d_ls_it = SLOW && !wcp_e && rd_itcm;
  assign d_ls_dt = SLOW && !wcp_e && rd_dtcm_r;   // (rd_itcm's priority is the formatter's select order)

  // synthesis translate_off
  always @(posedge clk)
    if (SLOW && A9C_RETURN && !rst && d_ok && !d_abort &&
        ((wcp_e && !w_cpwe) || (wq_e && !w_we)))
      if (d_rdata_f !== (wcp_e ? cp_rd : rd_itcm ? itcm_bq : rd_dtcm ? dtcm_bq :
                        ((d_hs || der) && !rb_hit) ? d_rdata_h : rbuf_d))
        $error("arm9_mem: accepted return owner differs (address %h, CP %b, buffer %b)", w_addr, wcp_e, rb_hit);
  always @(posedge clk)
    if (SLOW && !rst && wq_e && !w_we && d_ok && !(same_chk && !wcp_e) && d_rdata_f !== (d_sel_h ? d_rdata_h : d_rdata))
      $display("arm9_mem: ERROR: the load data %h is not the select's %h at %0t", d_rdata_f, d_sel_h ? d_rdata_h : d_rdata, $time);
  always @(posedge clk)
    if (SLOW && !rst && same_chk && !wcp_e && wq_e && !w_we)
      $display("arm9_mem: ERROR: a load in WB right after a store to its word (the removed SLOW merge) at %0t", $time);
  // synthesis translate_on
  // EARLYD: the fetch hold of a refused access ends while the fill's last word is on its way, so the replay's
  // refetch reaches the memory stage about when the line is there (the DS stalls in place and continues at once;
  // the core refuses, flushes and refetches after the fill: ~12 clk exposed per fill). Too early only costs another replay.
  // EARLYD, an uncached read's S_RD1: the replayed load waits in D (A9_OPT bit 1) and reaches WB ~5 clk after the
  // release. Outside main RAM (I/O, palette, OAM, VRAM: the fabric answers in ~3 clk) the hold ends as the request goes
  // out; for main RAM with the answer, a clock before dp_v clears. Too early only costs another replay.
  assign d_wait = (dp_v || busy_d) && !(EARLYD && st == S_FILL && k == 3'd7 && dp_kind == DK_FILL) &&
                  !(ERD && st == S_FILL && dp_kind == DK_FILL && (k != 3'd0 || b_ack) &&
                    {2'b0, 3'(dp_a[4:2] - fsd_f)} + 5'd2 <= {2'b0, k} + ERL) &&
                  !(EARLYD && st == S_RD1 && (dp_a[27:24] != 4'h2 || b_ack));

  // Port A address and write muxes
  always_comb begin
    itcm_aa = xw_itcm ? xw_a[14:2] : i_addr[14:2];
    itcm_we = xw_itcm ? xw_be : 4'h0;
    dtcm_we = xw_dtcm ? xw_be : 4'h0;
  end

  // ---------------------------------------------------------------- state machine
  logic [2:0]  k;                           // word in the line
  logic [VWB-1:0] vway;                     // victim way (D uses bits WB-1:0, I bits IWB-1:0)
  // (f_ic is mpu_en && ic_en && icr(f_addr), checked above; main RAM and the BIOS differ in bits 23:22, so bits 23:5
  // name the line)
  assign ier = ERI && f_req && f_ic && !pf_run && !iline && f_addr[23:5] == ip_a[23:5] &&
               ((st == S_IFILL && {1'b0, 3'(f_addr[4:2] - fsi)} + 4'd2 <= {1'b0, k}) || (st == S_ITAGW && f_addr[4:2] != 3'(fsi - 3'd1)));
  // der and d_wait's ERD term ask dp_kind == DK_FILL themselves, so their missed word is dp_a[4:2] without fsd's
  // kind select (RC11 #2485 7asR: dp_kind -> fsd -> the word compare -> der -> wd_hit -> d_sel_h -> e_bw -0.832 ns)
`ifdef ARM9_FSDF_MUT
  assign fsd_f = 3'd0;                      // (mutant: the fill's first word as if without CWF)
`else
  assign fsd_f = CWF ? dp_a[4:2] : 3'd0;
`endif
  assign der = ERD && wq_e && !w_we && dp_v && dp_kind == DK_FILL && w_addr[31:22] == 10'h008 && w_addr[21:5] == dp_a[21:5] &&
               ((st == S_FILL && {1'b0, 3'(w_addr[4:2] - fsd_f)} + 4'd2 <= {1'b0, k}) || (st == S_TAGW && w_addr[4:2] != 3'(fsd_f - 3'd1)));
  assign fsd = CWF && dp_kind == DK_FILL ? dp_a[4:2] : 3'd0;
  // (a BIOS line, ip_a[31] set, fills from word 0: only main RAM's burst wraps at the line's end; the fabric reads
  // other targets word by word up to word 7, so a BIOS fill from its missed word lost the words before it: hgnl-run2
  // hung at the release with CWF on, which tb_arm's bus, wrapping everywhere, cannot show)
`ifdef ARM9_BIOSIC_MUT3
  assign fsi = CWF && !pf_run ? ip_a[4:2] : 3'd0;                 // (mutant: a BIOS fill from its missed word)
`else
  assign fsi = CWF && !pf_run && !ip_a[31] ? ip_a[4:2] : 3'd0;
`endif
  logic [DLW-1:0] tlane;                    // the chosen way's lane (ev_lane)
  logic [WB-1:0] tlru;                      // the set's round-robin counter (D)
  logic [IWB-1:0] ilru;                     // (I)
  // the chosen way's lane, registered in S_TAG from the lane S_TAG selects (lw) instead of the whole
  // row (nds-fit #123 registered the row so the lane select left the compare cycle; lw already makes
  // that select there): the eviction's address (#689) and S_TAGW's write take it
  logic [DLW-1:0] ev_lane;
  assign tlane = ev_lane;
  logic [IWAYS-1:0] imask;                  // I line op: the ways to invalidate
  logic [11:0] inv_n;
  // the D set the machine works on: the line's, or a set/way operand's
  wire logic [DSB-1:0] dset = (dp_kind == DK_LINE && cmo_op[2:0] == 3'd2) ? sw_dset(dp_val, swa_d)
                                                                          : dp_a[DSB+4:5];
  // MEM1: the dirty bit per set and way, in one M10K (a lane a way; as flops they were 512 registers, a 256:1 read mux and
  // the write decode, and Quartus makes no RAM of a 256-deep array read without a clock). It reads with the tag row, at
  // dt_aa, for dt_aq's clock; a write in the read's clock is taken from a register for the ways it writes, and the
  // other ways' bits are the old word's (OLD_DATA: with DONT_CARE the chip returns the whole word undefined in that
  // clock, so a store hit to one way of a set could make another way's dirty line read clean and lose its write-back)
  // Two dirty bits a line, one per half-line (words 0-3, 4-7), as the ARM946E-S: a store hit sets its half's bit and
  // a write-back (eviction or clean) writes only the dirty halves, so a store into one half never writes the other
  // half's stale copy over main RAM that a DMA has filled since (Dawn of Sorrow: a heap header store in the line's
  // lower half, the card DMA into its upper half; docs/game-faults.md). Lane 2w + h holds way w's half h.
  logic [WAYS-1:0] dirt_q;                  // the way's line is dirty (either half)
  logic [2*WAYS-1:0] dirt_h;                // per way {upper, lower} half dirty
  wire  dirt_s = MEM1 && wd_store_cache && wd_buf;                   // a store hit sets its way's half's bit
  wire  dirt_c = MEM1 && st == S_TAGW;                               // a new line clears both
  wire  [DSB-1:0] dirt_wa = dirt_s ? w_addr[DSB+4:5] : dset;
  logic [2*WAYS-1:0] dirt_we;
  always_comb for (int g = 0; g < 2*WAYS; g++)
    dirt_we[g] = (dirt_s && wd_way == $clog2(WAYS)'(g / 2) && w_addr[4] == 1'(g % 2)) ||
                 (!dirt_s && dirt_c && vway[WB-1:0] == $clog2(WAYS)'(g / 2));
  logic [2*WAYS-1:0] dirt_bv, dirt_rq;
  logic            dirt_bd;
  always_ff @(posedge clk) begin
    dirt_bv <= dirt_we & {2*WAYS{dirt_wa == dt_aa}};
    dirt_bd <= dirt_s;
  end
  assign dirt_h = (dirt_bv & {2*WAYS{dirt_bd}}) | (~dirt_bv & dirt_rq);
  always_comb for (int g = 0; g < WAYS; g++) dirt_q[g] = dirt_h[2*g] | dirt_h[2*g + 1];
  generate if (MEM1) begin : g_dirt
`ifdef ALTERA_RESERVED_QIS
    logic [16*WAYS-1:0] d_in, d_out;
    always_comb begin
      d_in = '0;
      for (int g = 0; g < 2*WAYS; g++) d_in[8*g] = dirt_s;
    end
    altsyncram #(
      .operation_mode("DUAL_PORT"), .width_a(16*WAYS), .widthad_a(DSB), .numwords_a(1 << DSB), .width_byteena_a(2*WAYS),
      .byte_size(8), .width_b(16*WAYS), .widthad_b(DSB), .numwords_b(1 << DSB), .address_reg_b("CLOCK0"),
      .outdata_reg_b("UNREGISTERED"), .read_during_write_mode_mixed_ports("OLD_DATA"), .power_up_uninitialized("FALSE"),
      .ram_block_type("M10K"), .intended_device_family("Cyclone V"), .lpm_type("altsyncram")
    ) u_ram (.clock0(clk), .address_a(dirt_wa), .data_a(d_in), .wren_a(|dirt_we), .byteena_a(dirt_we),
             .address_b(dt_aa), .q_b(d_out));
    always_comb for (int g = 0; g < 2*WAYS; g++) dirt_rq[g] = d_out[8*g];
`else
    logic [2*WAYS-1:0] m [0:(1<<DSB)-1];
    initial for (int i = 0; i < (1<<DSB); i++) m[i] = '0;
    always_ff @(posedge clk) begin
      for (int g = 0; g < 2*WAYS; g++) if (dirt_we[g]) m[dirt_wa][g] <= dirt_s;
      dirt_rq <= m[dt_aa];
    end
`endif
  end else begin : g_nodirt
    assign dirt_rq = '0;
  end endgenerate
`ifndef SYNTHESIS
  // synthesis translate_off
  // the flops the M10K replaced, as a check: the bits S_TAG takes must be theirs (dt_aa a clock ahead of dset)
  logic [2*WAYS-1:0] dirt_sh [0:(1<<DSB)-1];
  initial for (int i = 0; i < (1<<DSB); i++) dirt_sh[i] = '0;
  always_ff @(posedge clk) begin
    for (int g = 0; g < 2*WAYS; g++)
      if (dirt_s && wd_way == $clog2(WAYS)'(g / 2) && w_addr[4] == 1'(g % 2)) dirt_sh[w_addr[DSB+4:5]][g] <= 1'b1;
      else if (dirt_c && vway[WB-1:0] == $clog2(WAYS)'(g / 2)) dirt_sh[dset][g] <= 1'b0;
    if (MEM1 && !rst && st == S_TAG && k != 3'd0 && dirt_h !== dirt_sh[dset]) $error("arm9_mem: dirty bits %b, not %b, at set %0d", dirt_h, dirt_sh[dset], dset);
  end
  // synthesis translate_on
  // synthesis translate_off
  always_ff @(posedge clk) if (!rst && dirt_s && dirt_c) $error("arm9_mem: a store hit's dirty bit in a new line's clear clock");
  // synthesis translate_on
`endif
  logic        dline;                       // line op: 1 = D cache, 0 = I cache

  always_comb begin
    // port A defaults: the delayed store writes
    dc_aa = xw_a[DSB+4:2];
    dc_ad = xw_d;
    for (int w = 0; w < WAYS; w++) dc_we[w] = (xw_dc && xw_way == w[WB-1:0]) ? xw_be : 4'h0;
    // a write-back store hit sets its way's dirty bit (the tag is its own)
    dt_aa = xw_a[DSB+4:5];
    dt_ad = {{(DLW-WB){1'b0}}, tlru + 1'b1, {WAYS{1'b1, 1'b1, xw_a[31:DSB+5]}}};
    dt_we = (xw_tag && !MEM1) ? ((WAYS+1)'(1) << xw_way) : '0;
    ic_aa = ip_a[ISB+4:2];
    ic_ad = b_rdata;
    ic_we = '0;
    it_aa = ip_a[ISB+4:5];
`ifdef ARM9_BIOSIC_MUT2
    it_ad = {{(ILW-IWB){1'b0}}, ilru + 1'b1, {IWAYS{ia[31:24] == 8'h02, 1'b1, ia[31:ISB+5]}}};   // (mutant: a BIOS line not marked)
`else
    it_ad = {{(ILW-IWB){1'b0}}, ilru + 1'b1, {IWAYS{icr(ia), 1'b1, ia[31:ISB+5]}}};
`endif
    it_we = '0;
    busy_d = 1'b0;
    busy_i = 1'b0;
    case (st)
      S_TAG, S_EVRD, S_EVRD2, S_EVWR, S_FILL, S_TAGW: begin
        busy_d = 1'b1;
        dc_aa = {dset, st == S_FILL ? 3'(k + fsd) : k};
        dt_aa = dset;
        for (int w = 0; w < WAYS; w++) dc_we[w] = 4'h0;
        dt_we = '0;
        dc_ad = b_rdata;
        if (st == S_FILL && b_ack) dc_we[vway[WB-1:0]] = 4'hF;
        if (st == S_TAGW) begin
          if (dp_kind == DK_LINE) begin
            logic [DLW-1:0] t;
            t = tlane;
            t[DTW] = 1'b0;                                           // clean
            if (cmo_op[6:3] != 4'd10) t[DTW+1] = 1'b0;               // invalidate
            dt_ad[WAYS*DLW-1:0] = {WAYS{t}};
            dt_we = (WAYS+1)'(1) << vway[WB-1:0];
          end else begin
            dt_ad[WAYS*DLW-1:0] = {WAYS{1'b1, 1'b0, dp_a[31:DSB+5]}};   // the new line
            dt_we = ((WAYS+1)'(1) << vway[WB-1:0]) | ((WAYS+1)'(1) << WAYS);  // and the counter
          end
        end
      end
      S_PFCHK: begin
        it_aa = ia[ISB+4:5];
      end
      S_ITAG, S_IFILL, S_ITAGW: begin
        busy_i = !(pf_run && st != S_ITAGW);
        if (iline) busy_d = 1'b1;
        ic_aa = {ia[ISB+4:5], 3'(k + fsi)};
        it_aa = !iline ? ia[ISB+4:5] : (cmo_op[2:0] == 3'd2) ? sw_iset(dp_val, swa_i) : dp_val[ISB+4:5];
        if (st == S_IFILL && b_ack) ic_we[vway[IWB-1:0]] = 1'b1;
        if (st == S_ITAGW) begin
          if (iline) begin
            it_ad[IWAYS*ILW-1:0] = '0;
            it_we = {1'b0, imask};
          end else it_we = ((IWAYS+1)'(1) << vway[IWB-1:0]) | ((IWAYS+1)'(1) << IWAYS);  // new line, counter
        end
      end
      S_INV: begin
        if (dline) begin
          busy_d = 1'b1;
          dt_aa = inv_n[DSB-1:0];
          dt_ad = '0;
          dt_we = '1;
          for (int w = 0; w < WAYS; w++) dc_we[w] = 4'h0;
        end else begin
          busy_i = 1'b1;
          it_aa = inv_n[ISB-1:0];
          it_ad = '0;
          it_we = '1;
        end
      end
      default: ;
    endcase
  end

  // bus
  always_comb begin
    b_req = 1'b0;
    b_we = 1'b0;
    b_tmr = 4'd0;
    b_addr = 32'h0;
    b_wdata = wbuf_d;
    b_be = 4'hF;
    b_n8 = (BURST && (st == S_FILL || st == S_IFILL)) || (EVBW && st == S_EVDRN);
    case (st)
      S_WDRAIN: begin b_req = 1'b1; b_we = 1'b1; b_addr = wbuf_a; b_be = wbuf_be; b_tmr = wbuf_tmr; end
      S_EVDRN:  begin b_req = !ev_skip; b_we = 1'b1; b_addr = EVBW ? {ev_a, 5'b0} : {ev_a, k[2:0], 2'b00}; b_wdata = ev_rd; end
      S_RD1:    begin b_req = 1'b1; b_addr = {dp_a[31:2], 2'b00}; end
      S_IRD1:   begin b_req = 1'b1; b_addr = {ip_a[31:2], 2'b00}; end
      S_EVWR:   begin b_req = !wr_skip; b_we = 1'b1; b_wdata = dc_aq[vway[WB-1:0]];
                      b_addr = {ev_lane[DTW-1:0], dset, k, 2'b00}; end
      S_FILL:   begin b_req = 1'b1; b_addr = {dp_a[31:5], 3'(k + fsd), 2'b00}; end
      S_IFILL:  begin b_req = 1'b1; b_addr = {ia[31:5], 3'(k + fsi), 2'b00}; end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    // request registers
    f_req   <= i_req;
    f_priv  <= i_priv;
    f_addr  <= i_addr;
    w_req   <= d_req;
    w_we    <= d_we;
    w_priv  <= d_priv;
    w_be    <= d_be;
    w_addr  <= d_addr;
    w_pg    <= d_addr[21:12];
`ifdef ARM9_WRA_MUT
    w_ra    <= {d_addr[31:5], ~d_addr[4], d_addr[3:2]};
`else
    w_ra    <= d_addr[31:2];
`endif
    w_wdata <= cp_req ? cp_wdata : d_wdata;
    w_cp    <= cp_req;
    w_cpwe  <= cp_we;
    w_cpop  <= cp_op;
    w_cprb_ra <= cprb_ra_of(cp_op);

    if (rst) begin
      ctrl <= RESET_CTRL;
      dcb <= 8'h0; wbb <= 8'h0;
      
      ren <= 8'h0;
      mr_v <= 8'h0;
      dtcm_base <= 20'h0; dtcm_mask <= 20'hFFFFF; itcm_mask <= 20'hFFFFF;
      st <= S_IDLE;
      wb_n <= 4'd0; wb_rp <= 3'd0; wb_wp <= 3'd0; rbuf_v <= 1'b0; ibuf_v <= 1'b0; ev_v <= 1'b0;
      dp_v <= 1'b0; ip_v <= 1'b0; pf_run <= 1'b0; cmo_done <= 1'b0;
      qw_v <= 1'b0; qw_itcm <= 1'b0; qw_dtcm <= 1'b0; qw_dc <= 1'b0; qw_tag <= 1'b0;
      pw_v <= 1'b0; pw_itcm <= 1'b0; pw_dtcm <= 1'b0; pw_dc <= 1'b0; pw_tag <= 1'b0;
    end else begin
      // ---- CP15 register writes (MCR in WB)
      if (cp_write) begin
        case (w_crn)
          4'd1: ctrl <= (w_wdata & 32'h000FF085) | 32'h00000078;
          4'd2: if (!w_opc2[0]) dcb <= w_wdata[7:0];
          4'd3: wbb <= w_wdata[7:0];
          4'd5: begin
            logic [31:0] ap;
            if (w_opc2[1]) ap = w_wdata;
            else begin
              ap = 32'h0;
              for (int n = 0; n < 8; n++) ap[n*4 +: 2] = w_wdata[n*2 +: 2];
            end
            
          end
          4'd6: begin
            rbase[w_crm[2:0]] <= w_wdata[31:12];
            rmask[w_crm[2:0]] <= rmask_of(w_wdata[5:1]);
            ren[w_crm[2:0]] <= w_wdata[0];
            mr_v[w_crm[2:0]] <= w_wdata[0] && ((w_wdata[31:22] ^ 10'h008) & c6_msk[19:10]) == 10'h0;
            mr_b[w_crm[2:0]] <= w_wdata[21:12] & c6_msk[9:0];
            mr_cut[w_crm[2:0]] <= cut_of(w_wdata[5:1]);
          end
          4'd9: begin
            if (w_crm == 4'd1) begin
              if (w_opc2[0]) begin
                itcm_mask <= tmask_of(w_wdata[5:1]);
              end else begin
                dtcm_base <= w_wdata[31:12] & tmask_of(w_wdata[5:1]);
                dtcm_mask <= tmask_of(w_wdata[5:1]);
              end
            end else begin
            end
          end
          default: ;
        endcase
      end
      if (wcp_e && cp_isop && cp_ok) cmo_done <= 1'b0;

      // ---- store writes: decided now (qw), performed next cycle but one (pw)
      itcm_steal <= wd_tcmw && wd_itcm;
      qw_v    <= wd_tcmw || wd_store_cache;
      qw_a    <= w_addr;
      qw_d    <= w_wdata;
      qw_be   <= w_be;
      qw_itcm <= wd_tcmw && wd_itcm;
      qw_dtcm <= wd_tcmw && wd_dtcm;
      qw_dc   <= wd_store_cache;
      qw_way  <= wd_way;
      qw_tag  <= wd_store_cache && wd_buf;
      pw_v    <= qw_v;
      pw_a    <= qw_a;
      pw_d    <= qw_d;
      pw_be   <= qw_be;
      pw_itcm <= qw_itcm;
      pw_dtcm <= qw_dtcm;
      pw_dc   <= qw_dc;
      pw_way  <= qw_way;
      pw_tag  <= qw_tag;
      if (SLOW) begin                       // SLOW: the write happens in its own WB cycle; pw = the one last cycle
        pw_v    <= wd_tcmw || wd_store_cache;
        pw_a    <= w_addr;
        pw_d    <= w_wdata;
        pw_be   <= w_be;
        pw_itcm <= wd_tcmw && wd_itcm;
        pw_dtcm <= wd_tcmw && wd_dtcm;
        pw_dc   <= wd_store_cache;
        pw_way  <= wd_way;
        pw_tag  <= wd_store_cache && wd_buf;
      end

      // ---- requests from the answers
      begin
        logic wpop;
        wpop = (st == S_WDRAIN) && b_ack;
        if (wpop) wb_rp <= wb_rp + 3'd1;
        if (wd_push) begin
          wb_wp <= wb_wp + 3'd1;
        end
        wb_n <= wb_n + (wd_push ? 4'd1 : 4'd0) - (wpop ? 4'd1 : 4'd0);
      end
      // an uncached read result serves only the next completed access (the
      // replayed load); anything else completing first drops it
      if ((wq_e || wcp_e) && d_ok) rbuf_v <= 1'b0;
      // The request registers load whenever no request is pending, so their
      // enables do not wait for the MPU and the tag compare; only the valid
      // bits do. A finished maintenance operation's op and value stay for its
      // replay to match (cmo_done).
      if (wd_need && !dp_v && !busy_d) begin
        dp_v <= 1'b1;
        dp_kind <= wd_kind;
      end
      if (!dp_v && !busy_d) begin
        dp_a <= wcp_e ? w_wdata : w_addr;
        dp_val <= w_wdata;
      end
      if (wcp_e && cp_isop && !dp_v && !busy_d) begin
        cmo_op <= w_cpop;
        cmo_val <= w_wdata;
      end
      if (f_req && !i_abort && !i_ok && !ip_v && !busy_i && !col_i) begin
        logic itcm;
        itcm = itcm_en && !itcm_ld && (SLOW ? (f_addr[31:12] & itcm_mask) == 20'h0 : f_tm);
        if (!itcm) ip_v <= 1'b1;
      end
      if (!ip_v && !busy_i) ip_a <= f_addr;
      // an uncached fetch result serves fetches from the same word (both
      // Thumb halfwords, and the refetch after a dropped speculative fetch);
      // a completed fetch from another word or any store drops it
      if ((f_req && i_ok && f_addr[31:2] != ibuf_a[31:2]) || (wq_e && w_we)) ibuf_v <= 1'b0;

      // ---- the machine
      case (st)
        S_IDLE: begin
          k <= 3'd0;
          if (EVB && ev_v && !ev_pass) begin st <= S_EVDRN; k <= ev_k; ev_idle <= 1'b1; end
          else if (wbuf_v) st <= S_WDRAIN;
          else if (dp_v) begin
            case (dp_kind)
              DK_RD1:   st <= S_RD1;
              DK_FILL:  st <= S_TAG;
              DK_INV_D: begin st <= S_INV; dline <= 1'b1; inv_n <= 12'd0; end
              DK_INV_I: begin st <= S_INV; dline <= 1'b0; inv_n <= 12'd0; end
              DK_LINE: begin
                swa_d <= 4'd0; swa_i <= 4'd0;
                // I-cache line ops just invalidate the whole I-cache line set
                if (cmo_op[6:3] == 4'd5) begin
                  st <= S_ITAG;
                  iline <= 1'b1;
                end else st <= S_TAG;
              end
              default: begin                // drain: the buffer is already empty
                dp_v <= 1'b0;
                cmo_done <= 1'b1;
              end
            endcase
          end else if (ip_v) begin
            iline <= 1'b0;
            if (ip_cach) st <= S_ITAG;
            else         st <= S_IRD1;
          end
        end
        S_WDRAIN: if (b_ack) begin
          st <= S_IDLE;
        end
        S_RD1: if (b_ack) begin
          rbuf_v <= 1'b1;
          rbuf_a <= dp_a;
          rbuf_d <= b_rdata;
          dp_v <= 1'b0;
          st <= S_IDLE;
        end
        S_IRD1: if (b_ack) begin
          ibuf_v <= 1'b1;
          ibuf_a <= ip_a;
          ibuf_d <= b_rdata;
          ip_v <= 1'b0;
          st <= S_IDLE;
        end
        S_TAG: begin
          // dt_aq holds the set's tag row (read last cycle)
          if (k == 3'd0) begin
            k <= 3'd1;                      // wait one cycle for the read
          end else begin
            logic [WB-1:0] w;
            logic       hit;
            logic [DLW-1:0] lw;
            hit = 1'b0; w = dt_aq[WAYS*DLW +: WB];
            if (dp_kind == DK_LINE) begin
              if (cmo_op[2:0] == 3'd2) begin   // by set/way
                lw = dlane(dt_aq[WAYS*DLW-1:0], sw_way(dp_val));
                hit = lw[DTW+1];
                w = sw_way(dp_val);
              end else begin
                for (int x = 0; x < WAYS; x++)
                  if (dt_aq[x*DLW + DTW + 1] && dt_aq[x*DLW +: DTW] == dp_val[31:DSB+5]) begin
                    hit = 1'b1; w = x[WB-1:0];
                  end
              end
            end
            lw = dlane(dt_aq[WAYS*DLW-1:0], w);
            if (MEM1) lw[DTW] = dirt_q[w];
            vway <= VWB'(w);
            vdh <= MEM1 ? {dirt_h[2*w + 1], dirt_h[2*w]} : {2{lw[DTW]}};
            ev_lane <= lw;
            tlru <= dt_aq[WAYS*DLW +: WB];
            k <= 3'd0;
            if (dp_kind == DK_LINE) begin
              if (hit && lw[DTW] && cmo_op[6:3] != 4'd6) st <= S_EVRD;  // clean
              else st <= S_TAGW;
              if (!hit) begin               // nothing cached: done (or on to the next alias set)
                if (sw_more_d) begin
                  swa_d <= swa_d + 4'd1; st <= S_TAG;
                end else begin
                  st <= S_IDLE;
                  dp_v <= 1'b0;
                  cmo_done <= 1'b1;
                end
              end
            end else begin
              // fill: evict the round-robin victim first if it is dirty
              if (lw[DTW+1] && lw[DTW]) begin st <= (EVB && ev_v) ? S_EVDRN : S_EVRD; ev_idle <= 1'b0; k <= (EVB && ev_v) ? ev_k : 3'd0; end   // (one eviction buffer: it drains first)
              else st <= S_FILL;
            end
          end
        end
        S_EVRD: if (EVB && dp_kind != DK_LINE) begin
          // copy the victim line: word k-1 is on the data port, word k's address is up
          if (k == 3'd7) st <= S_EVRD2;
          else k <= k + 3'd1;
        end else st <= S_EVWR;              // data word k is read this cycle
        S_EVRD2: begin                      // the last word; the fill starts, the buffer drains later
          ev_a <= {ev_lane[DTW-1:0], dset};
          ev_dh <= vdh;
          ev_v <= 1'b1;
          ev_k <= 3'd0;
          k <= 3'd0;
          st <= S_FILL;
        end
        S_EVDRN: if (EVBW) begin
          if (b_wnext) k <= k + 3'd1;
          if (b_ack) begin ev_v <= 1'b0; st <= S_IDLE; end
        end else if (b_ack || ev_skip) begin
          k <= k + 3'd1;
          ev_k <= k + 3'd1;
          if (k == 3'd7) begin ev_v <= 1'b0; ev_k <= 3'd0; st <= S_IDLE; end
          else if (EVY && ev_idle && ev_pass) st <= S_IDLE;    // yield to the pending request; the rest drains later
        end
        S_EVWR: if (b_ack || wr_skip) begin
          k <= k + 3'd1;
          if (k != 3'd7)              st <= S_EVRD;
          else if (dp_kind == DK_LINE) st <= S_TAGW;
          else                        st <= S_FILL;
        end
        S_FILL: if (b_ack) begin
          k <= k + 3'd1;
          if (k == 3'd7) st <= S_TAGW;
        end
        S_TAGW: begin                       // the row is written by port A this cycle
          if (dp_kind == DK_LINE && sw_more_d) begin
            swa_d <= swa_d + 4'd1; k <= 3'd0; st <= S_TAG;
          end else begin
            if (dp_kind == DK_LINE) cmo_done <= 1'b1;
            dp_v <= 1'b0;
            st <= S_IDLE;
          end
        end
        S_ITAG: begin
          if (k == 3'd0) k <= 3'd1;
          else begin
            k <= 3'd0;
            if (iline) begin
              // I-cache line invalidate: clear the matching way
              for (int x = 0; x < IWAYS; x++)
                imask[x] <= it_aq[x*ILW + ITW] && (cmo_op[2:0] == 3'd2 ? (sw_wayi(dp_val) == x[IWB-1:0])
                                                                        : (it_aq[x*ILW +: ITW] == dp_val[31:ISB+5]));
              st <= S_ITAGW;
            end else begin
              vway <= VWB'(it_aq[IWAYS*ILW +: IWB]);
`ifdef ARM9_IWAYS_MUT
              ilru <= ~it_aq[IWAYS*ILW +: IWB];   // (mutant: the I round-robin counter inverted)
`else
              ilru <= it_aq[IWAYS*ILW +: IWB];
`endif
              st <= S_IFILL;
            end
          end
        end
        S_IFILL: if (b_ack) begin
          k <= k + 3'd1;
          if (k == 3'd7) st <= S_ITAGW;
        end
        S_ITAGW: begin
          if (iline && sw_more_i) begin
            swa_i <= swa_i + 4'd1; k <= 3'd0; st <= S_ITAG;
          end else if (iline) begin
            dp_v <= 1'b0;
            cmo_done <= 1'b1;
          end else if (pf_run) begin
            pf_run <= 1'b0;                 // the prefetch fill ends; a demand miss that queued behind it goes on
          end else begin
            ip_v <= 1'b0;
          end
          iline <= 1'b0;
          st <= S_IDLE;
          if (PF && !iline && !pf_run && !dp_v && !wbuf_v && !ev_v && ip_a[11:5] != 7'h7F) begin
            pf_a <= ip_a[31:5] + 27'd1;
            pf_run <= 1'b1;
            k <= 3'd0;
            st <= S_PFCHK;
          end
        end
        S_PFCHK: begin
          if (k == 3'd0) k <= 3'd1;
          else begin
            logic present;
            present = 1'b0;
            for (int x = 0; x < IWAYS; x++)
              if (it_aq[x*ILW + ITW] && it_aq[x*ILW +: ITW] == pf_a[26:ISB]) present = 1'b1;
            k <= 3'd0;
            if (present) begin pf_run <= 1'b0; st <= S_IDLE; end
            else begin iline <= 1'b0; st <= S_ITAG; end
          end
        end
        S_INV: begin
          inv_n <= inv_n + 12'd1;
          if ((dline && inv_n == 12'((1 << DSB) - 1)) || (!dline && inv_n == 12'((1 << ISB) - 1))) begin
            dp_v <= 1'b0;
            cmo_done <= 1'b1;
            st <= S_IDLE;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    col_d <= !rst && busy_d;
    col_i <= !rst && busy_i;
  end

  // whether the pending fetch is cacheable (MPU state at the time of the miss)
  always_ff @(posedge clk)
    if (!ip_v && !busy_i) ip_cach <= f_cach;
  // diagnostics: a line fill starts (the first clock in S_IFILL / S_FILL)
  logic dg_if_q, dg_df_q;
  always_ff @(posedge clk) begin dg_if_q <= (st == S_IFILL); dg_df_q <= (st == S_FILL); end
  assign dg_fill = {st == S_IFILL && !dg_if_q, st == S_FILL && !dg_df_q};


  // the eviction buffer's words: the victim line, word k-1 on the data port in S_EVRD, the last in S_EVRD2 (484d0829 had
  // this in the simulation-only block below: on the chip every dirty eviction wrote unwritten words to main RAM)
  always_ff @(posedge clk)
    if ((st == S_EVRD && EVB && dp_kind != DK_LINE && k != 3'd0) || st == S_EVRD2)
      ev_d[st == S_EVRD2 ? 3'd7 : k - 3'd1] <= dc_aq[vway[WB-1:0]];
  // the drain's word, read a clock ahead with the word the drain asks for next: in S_EVDRN k + 1 after a word is taken,
  // else k; entering it (from S_IDLE or S_TAG) ev_k. The copy writes only before a drain starts (one buffer)
  wire  [2:0]  ev_ra = st != S_EVDRN ? ev_k : (EVBW ? b_wnext : b_ack || ev_skip) ? k + 3'd1 : k;
  always_ff @(posedge clk) ev_rd <= ev_d[ev_ra];
  // the write buffer's RAM: the push at wp, and the next head (rp after this clock's pop) read for the next clock
  wire  [2:0]  wb_rpn = ((st == S_WDRAIN) && b_ack) ? wb_rp + 3'd1 : wb_rp;
  wire  [71:0] wb_new = {w_addr, w_wdata, w_addr[31:12] == 20'h04000 && w_addr[11:4] == 8'h10 ? 4'd1 << w_addr[3:2] : 4'd0, w_be};
  always_ff @(posedge clk) begin
    if (!rst && wd_push) wb_m[wb_wp & 3'(WBD - 1)] <= wb_new;
    wb_rd  <= wb_m[wb_rpn & 3'(WBD - 1)];
    wb_byp <= !rst && wd_push && ((wb_wp ^ wb_rpn) & 3'(WBD - 1)) == 3'd0;
    wb_bd  <= wb_new;
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (!rst && wb_n != 4'd0 && wb_q !== wb_m[wb_rp & 3'(WBD - 1)]) $error("arm9_mem: write buffer head %h, entry %0d %h", wb_q, wb_rp, wb_m[wb_rp & 3'(WBD - 1)]);
`endif
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (!rst && st == S_EVDRN && ev_rd !== ev_d[k[2:0]]) $error("arm9_mem: eviction word %h, buffer word %0d %h", ev_rd, k, ev_d[k[2:0]]);
`endif

`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
  // simulation (+memstat): bus writes (a squashed store pushed twice shows here, not in the retire trace)
  longint ms_wr = 0;
  always_ff @(posedge clk) if (b_req && b_ack && b_we) ms_wr <= ms_wr + 1;
  final if ($test$plusargs("memstat")) $display("memstat: ARM9 bus writes %0d", ms_wr);
  // simulation (+swstat): the distinct (way, set) pairs of the D cache that set/way operations have visited
  bit sws_seen [int];
  always_ff @(posedge clk) if ($test$plusargs("swstat") && st == S_TAG && dp_kind == DK_LINE && cmo_op[2:0] == 3'd2 && cmo_op[6:3] != 4'd5)
    sws_seen[(int'(sw_way(dp_val)) << DSB) | int'(dset)] = 1'b1;
  final if ($test$plusargs("swstat")) $display("swstat: D set/way operations visited %0d distinct (way, set) lines of %0d", sws_seen.num(), WAYS << DSB);
`endif
`endif
`ifndef SYNTHESIS
`ifndef ALTERA_RESERVED_QIS
  // simulation (+dtcmlog): every DTCM write (address, data, byte enables), to compare cores
  always_ff @(posedge clk)
    if (!rst && $test$plusargs("dtcmlog") && xw_dtcm)
      $display("dtcmw %08x %08x %h", xw_a, xw_d, xw_be);
  // simulation (+vecld): the WB answer of every load of a DTCM-range word 0xFFF (the IRQ vector), with its selects
  always_ff @(posedge clk)
    if (!rst && $test$plusargs("vecld") && w_req && !w_we && !w_cp && w_addr[13:2] == 12'hFFF)
      $display("vecld %0t a=%08x wq_e=%b kill=%b itcm=%b dtcm=%b cach=%b hit=%b sel_h=%b dtcm_bq=%08x rd=%08x ok=%b pw_v=%b pw_a=%08x pw_dtcm=%b ctrl=%08x base=%05x mask=%05x",
               $time, w_addr, wq_e, d_kill, wd_itcm, wd_dtcm, wd_cach, wd_hit, d_sel_h, dtcm_bq, d_rdata_f, d_ok, pw_v, pw_a, pw_dtcm, ctrl, dtcm_base, dtcm_mask);
  // simulation (+cplog): every CP15 register write (crn, crm, opc2, value), to compare cores
  always_ff @(posedge clk)
    if (!rst && $test$plusargs("cplog") && cp_write)
      $display("cp15w %0t c%0d c%0d %0d %08x", $time, w_crn, w_crm, w_opc2, w_wdata);
  // simulation (+a9line=HEX): every event on one 32-byte line: the core's loads and stores to it (as answered),
  // bus transfers of it (fills, write-buffer drains, write-backs), the CP15 c7 line operations on it
  logic [31:0] a9l = 32'd0;
  initial void'($value$plusargs("a9line=%h", a9l));
  always_ff @(posedge clk) if (!rst && a9l != 32'd0) begin
    if (wq_e && !w_cp && d_ok && w_addr[31:5] == a9l[31:5])
      $display("[%0t] A9L cpu %s %08x %08x be %h cach %b hit %b", $time, w_we ? "st" : "ld", w_addr,
               w_we ? w_wdata : d_rdata_f, w_be, wd_cach, wd_hit);
    if (b_req && b_ack && b_addr[31:5] == a9l[31:5])
      $display("[%0t] A9L bus %s %08x %08x st %0d", $time, b_we ? "wr" : "rd", b_addr, b_we ? b_wdata : b_rdata, st);
    if (cp_write && w_crn == 4'd7 && w_wdata[31:5] == a9l[31:5])
      $display("[%0t] A9L c7 c%0d %0d %08x", $time, w_crm, w_opc2, w_wdata);
  end
`endif
`endif
endmodule
