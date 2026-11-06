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
  // 1: a line fill is one request for the whole line (b_n8; the 8 words come
  // back as 8 b_ack beats, in order, while b_req stays up), so a bus that can
  // burst serves it as one transfer (the DS: 46 cycles per line, hwref run 22)
  parameter bit          BURST = 1'b0,
  parameter bit          SLOW = 1'b0,                 // the CPUs at clk_sys (67 MHz): smaller forms
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
  output logic [31:0] i_rdata,
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
  logic [19:0] dtcm_base, dtcm_mask, itcm_mask;
  // Registers that are only read back (MRC) keep that value in an MLAB, in
  // {crn, crm, opc2} order: 0-7 c6 regions, 8/9 c9 DTCM/ITCM region, 10/11
  // c9 lockdown D/I, 12 c13. An entry reads 0 until written; the c9 region
  // entries also after a reset (their registers were reset before).
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] cprb [0:15];
  logic [12:0] cprb_v = 13'h0;
  logic [3:0]  cprb_ra, cprb_wa;
  logic [31:0] cprb_wd, cprb_q;
  logic        cprb_we;

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
  localparam int WB  = (WAYS == 4) ? 2 : 1;           // way index bits
  localparam int DSB = 7 - WB + XD, ISB = 8 - WB + XI;          // set index bits
  localparam int DTW = 27 - DSB, ITW = 27 - ISB;      // tag bits (address 31 down)
  localparam int DLW = DTW + 2, ILW = ITW + 1;        // tag lane: valid, (dirty,) tag
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
  logic [WAYS-1:0] ic_we;                   // one bit per way (whole word)
  logic [31:0] ic_ad;
  logic [31:0] ic_aq [0:WAYS-1], ic_bq [0:WAYS-1];
  logic [ISB-1:0] it_aa;
  logic [WAYS:0]  it_we;
  logic [(WAYS+1)*ILW-1:0] it_ad, it_aq, it_bq;
  // way w's D tag lane of a row, as a mux over constant offsets (a select at
  // w*DLW with DLW = 23 became a multiplier, nds-fit #188)
  function automatic logic [DLW-1:0] dlane(input logic [WAYS*DLW-1:0] row, input logic [WB-1:0] w);
    dlane = row[DLW-1:0];
    for (int x = 1; x < WAYS; x++) if (w == x[WB-1:0]) dlane = row[x*DLW +: DLW];
  endfunction
  // a set/way operand's way and set (MCR c7, opc2 2)
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
    base = (WAYS == 4) ? ISB'(v[ISB-XI+4:5]) : ISB'({v[31], v[ISB-XI+3:5]});
    return base | (ISB'(al) << (ISB - XI));
  endfunction
  logic [3:0] swa_d, swa_i;                 // the alias sets visited so far by the running set/way operation
  wire sw_more_d = XD != 0 && cmo_op[2:0] == 3'd2 && swa_d != 4'((1 << XD) - 1);
  wire sw_more_i = XI != 0 && cmo_op[2:0] == 3'd2 && swa_i != 4'((1 << XI) - 1);

  logic [31:0] w_addr, w_wdata;             // registered data request (WB)

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
    arm9_ram #(.AW(ISB+3)) u_i (.clk(clk), .a_addr(ic_aa), .a_we({4{ic_we[gw]}}), .a_d(ic_ad),
      .a_q(ic_aq[gw]), .b_addr(i_addr[ISB+4:2]), .b_q(ic_bq[gw]));
  end endgenerate
  arm9_ram #(.AW(DSB), .LANES(WAYS+1), .LANE_W(DLW), .FOLD(1'b1)) u_dtag (.clk(clk), .a_addr(dt_aa), .a_we(dt_we),
    .a_d(dt_ad), .a_q(dt_aq), .b_addr(d_addr[DSB+4:5]), .b_q(dt_bq));
  arm9_ram #(.AW(ISB), .LANES(WAYS+1), .LANE_W(ILW), .FOLD(1'b1)) u_itag (.clk(clk), .a_addr(it_aa), .a_we(it_we),
    .a_d(it_ad), .a_q(it_aq), .b_addr(i_addr[ISB+4:5]), .b_q(it_bq));

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
  logic        ev_idle;
  logic [26:0] ev_a;                        // its line address {tag, set}
  // (one write address, so it really is an MLAB: two kept 256 flops, the 8:1 read mux and the write decode)
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] ev_d [0:7];
  // write buffer: a FIFO of WBD entries (1: the one-entry buffer; MEM1: 8, so an STM8 to uncached memory does not
  // replay on every word: the replay flushes the pipe and refetches, which hurts most with uncached code)
  localparam int WBD = (SLOW && (OPT & 524288) != 0) ? 8 : 1;
  logic [3:0]  wb_n;                        // entries used
  // (an MLAB with read and write pointers: {address, data, timer one-hot (wb_a is a timer register,
  // 0x04000100-0x0400010F, for the fabric), byte enables})
  (* ramstyle = "MLAB, no_rw_check" *) logic [71:0] wb_m [0:WBD-1];
  logic [2:0]  wb_rp, wb_wp;
  wire         wbuf_v = wb_n != 4'd0;
  wire         wb_full = wb_n == 4'(WBD);
  wire  [71:0] wb_q = wb_m[wb_rp & 3'(WBD - 1)];
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
  // MEM1 (OPT[19], SLOW only): accesses may follow each other every cycle. A store writes the RAMs in its own WB cycle
  // while the next access reads them (port B, same address: undefined, the model inverts it), so that access gets the
  // written bytes merged in (pw); the dirty bits live in flops, since a tag row write would be a read-during-write
  // for any next lookup of the same set.
  localparam bit MEM1 = SLOW && (OPT & 524288) != 0;
  logic        pf_run;
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
  // The fetch's region matches and ITCM match, registered with f_addr: decided from i_addr against
  // the c6/c9 values these registers hold next cycle (an MCR in WB this cycle is forwarded)
  logic [7:0]  f_rm;
  logic        f_tm;

  always_comb begin
    logic        found, hit, cach, itcm;
    logic [2:0]  idx;
    logic [WB-1:0] way;
    found = 1'b0; idx = 3'd0;   // pocket-now: no I-side MPU lookup; only main RAM is I-cacheable (known difference)
    cach = mpu_en && ic_en && f_addr[31:24] == 8'h02;
    f_cach = cach;
    itcm = itcm_en && !itcm_ld && (SLOW ? (f_addr[31:12] & itcm_mask) == 20'h0 : f_tm);
    hit = 1'b0; way = '0;
    for (int w = 0; w < WAYS; w++)
      if (it_bq[w*ILW + ITW] && it_bq[w*ILW +: ITW] == f_addr[31:ISB+5]) begin
        hit = 1'b1; way = w[WB-1:0];
      end
    i_abort = 1'b0;   // pocket-now: no MPU fetch aborts (known difference)
    i_rdata = itcm ? itcm_aq : cach ? ic_bq[way] : ibuf_d;
    if (!f_req || i_abort) i_ok = 1'b1;
    else if (itcm)         i_ok = !(MEM1 && itcm_steal);   // MEM1: a data write to the ITCM took port A in the fetch's cycle: fetch again
    else if (cach)                 i_ok = hit && !busy_i && !col_i &&
                                   !(pf_run && st == S_IFILL && f_addr[ISB+4:5] == pf_a[ISB-1:0]);
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
  logic [31:0] d_rdata;
  logic [WB-1:0] wd_way;
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
    // pocket-now: no D-side MPU lookup; cacheable/bufferable only in the 4 MiB of main RAM at 0x02000000 (known difference)
    found = w_addr[31:22] == 10'h008; ok = 1'b1; cach = |dcb; bufr = found && |wbb;
    wd_abort = 1'b0;   // pocket-now: no MPU data aborts (known difference)
    wd_itcm  = itcm_en && ((w_addr[31:12] & itcm_mask) == 20'h0) && (w_we || !itcm_ld);
    wd_dtcm  = !wd_itcm && dtcm_en && ((w_addr[31:12] & dtcm_mask) == dtcm_base) && (w_we || !dtcm_ld);
    wd_cach  = mpu_en && dc_en && found && cach;
    wd_buf   = bufr;
    wd_hit = 1'b0; wd_way = '0;
    for (int w = 0; w < WAYS; w++)
      if (dt_bq[w*DLW + DTW + 1] && dt_bq[w*DLW +: DTW] == w_addr[31:DSB+5]) begin
        wd_hit = 1'b1; wd_way = w[WB-1:0];
      end
  end

  // read-back MLAB: written by MCR (the values as MRC returns them), read in WB
  always_comb begin
    cprb_ra = (w_crn == 4'd6) ? {1'b0, w_crm[2:0]} :
              (w_crn == 4'd9) ? {2'b10, w_crm != 4'd1, w_opc2[0]} : 4'd12;
    cprb_wa = cprb_ra;
    cprb_we = cp_write && (w_crn == 4'd6 || w_crn == 4'd9 || w_crn == 4'd13);
    cprb_wd = w_wdata;
    if (w_crn == 4'd9 && w_crm == 4'd1)
      cprb_wd = w_opc2[0] ? {20'h0, 6'h0, w_wdata[5:1], 1'b0}
                          : {w_wdata[31:12], 6'h0, w_wdata[5:1], 1'b0};
  end
  assign cprb_q = cprb_v[cprb_ra] ? cprb[cprb_ra] : 32'h0;
  always_ff @(posedge clk) begin
    if (cprb_we) cprb[cprb_wa] <= cprb_wd;
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
    f_tm <= (i_addr[31:12] & tm) == 20'h0;
  end
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
      if (f_tm !== ((f_addr[31:12] & itcm_mask) == 20'h0))
        $error("arm9_mem: fetch ITCM match %b at %h", f_tm, f_addr);
    end
  end
`endif

  // The read data, selected without the MPU's abort and the busy checks:
  // the core only uses it when the answer is ok and not an abort. Only the
  // cacheable bit, which decides between a cache hit and the uncached read
  // buffer, comes from the MPU, at the last mux (after the forwarding merge
  // below, which is done on both candidates: nds-fit #127's worst path).
  logic [31:0] d_rdata_h;                   // the cache-hit candidate
  logic        d_sel_h;                     // ... is the answer
  always_comb begin
    if (wcp_e)         d_rdata = cp_rd;
    else if (wd_itcm) d_rdata = itcm_bq;
    else if (wd_dtcm) d_rdata = dtcm_bq;
    else              d_rdata = rbuf_d;
    d_rdata_h = dc_bq[wd_way];
    d_sel_h = !wcp_e && !wd_itcm && !wd_dtcm && wd_cach && wd_hit;
  end

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
      end else if (busy_d || dp_v || col_d) begin
        d_ok = 1'b0;                        // the machine is busy with the D side
      end else if (!w_we) begin
        if (wd_cach && wd_hit) begin
        end else if (!wd_cach && rbuf_v && rbuf_a[31:2] == w_addr[31:2]) begin
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

  // the access right after a store may have read the RAM before the write
  // (not under SLOW: the write is in the store's own WB)
  always_comb begin
    logic same;
    logic [31:0] h, u;
    same = (!SLOW || MEM1) && pw_v && (pw_a[31:2] == w_addr[31:2]) &&
           ((pw_itcm && wd_itcm) || (pw_dtcm && wd_dtcm) || (pw_dc && !wd_itcm && !wd_dtcm));
    h = d_rdata_h;
    u = SLOW ? (d_sel_h ? d_rdata_h : d_rdata) : d_rdata;   // SLOW: select first, merge once
    if (same && !wcp_e)
      for (int b = 0; b < 4; b++)
        if (pw_be[b]) begin
          h[b*8 +: 8] = pw_d[b*8 +: 8];
          u[b*8 +: 8] = pw_d[b*8 +: 8];
        end
    d_rdata_f = (d_sel_h && !SLOW) ? h : u;
  end

  // EARLYD: the fetch hold of a refused access ends while the fill's last word is on its way, so the replay's
  // refetch reaches the memory stage about when the line is there (the DS stalls in place and continues at once;
  // the core refuses, flushes and refetches after the fill: ~12 clk exposed per fill). Too early only costs another replay.
  assign d_wait = (dp_v || busy_d) && !(EARLYD && st == S_FILL && k == 3'd7 && dp_kind == DK_FILL);

  // Port A address and write muxes
  always_comb begin
    itcm_aa = xw_itcm ? xw_a[14:2] : i_addr[14:2];
    itcm_we = xw_itcm ? xw_be : 4'h0;
    dtcm_we = xw_dtcm ? xw_be : 4'h0;
  end

  // ---------------------------------------------------------------- state machine
  logic [2:0]  k;                           // word in the line
  logic [WB-1:0] vway;                      // victim way
  logic [DLW-1:0] tlane;                    // the chosen way's lane (ev_lane)
  logic [WB-1:0] tlru, ilru;                // the set's round-robin counter
  // the chosen way's lane, registered in S_TAG from the lane S_TAG selects (lw) instead of the whole
  // row (nds-fit #123 registered the row so the lane select left the compare cycle; lw already makes
  // that select there): the eviction's address (#689) and S_TAGW's write take it
  logic [DLW-1:0] ev_lane;
  assign tlane = ev_lane;
  logic [WAYS-1:0] imask;                   // I line op: the ways to invalidate
  logic [11:0] inv_n;
  // the D set the machine works on: the line's, or a set/way operand's
  wire logic [DSB-1:0] dset = (dp_kind == DK_LINE && cmo_op[2:0] == 3'd2) ? sw_dset(dp_val, swa_d)
                                                                          : dp_a[DSB+4:5];
  // MEM1: the dirty bit per set and way, in one M10K (a lane a way; as flops they were 512 registers, a 256:1 read mux and
  // the write decode, and Quartus makes no RAM of a 256-deep array read without a clock). It reads with the tag row, at
  // dt_aa, for dt_aq's clock; a write in the read's clock is taken from a register for the ways it writes, and the
  // other ways' bits are the old word's (OLD_DATA: with DONT_CARE the chip returns the whole word undefined in that
  // clock, so a store hit to one way of a set could make another way's dirty line read clean and lose its write-back)
  logic [WAYS-1:0] dirt_q;
  wire  dirt_s = MEM1 && wd_store_cache && wd_buf;                   // a store hit sets its way's bit
  wire  dirt_c = MEM1 && st == S_TAGW;                               // a new line clears it
  wire  [DSB-1:0] dirt_wa = dirt_s ? w_addr[DSB+4:5] : dset;
  logic [WAYS-1:0] dirt_we;
  always_comb for (int g = 0; g < WAYS; g++)
    dirt_we[g] = (dirt_s && wd_way == $clog2(WAYS)'(g)) || (!dirt_s && dirt_c && vway == $clog2(WAYS)'(g));
  logic [WAYS-1:0] dirt_bv, dirt_rq;
  logic            dirt_bd;
  always_ff @(posedge clk) begin
    dirt_bv <= dirt_we & {WAYS{dirt_wa == dt_aa}};
    dirt_bd <= dirt_s;
  end
  assign dirt_q = (dirt_bv & {WAYS{dirt_bd}}) | (~dirt_bv & dirt_rq);
  generate if (MEM1) begin : g_dirt
`ifdef ALTERA_RESERVED_QIS
    logic [8*WAYS-1:0] d_in, d_out;
    always_comb begin
      d_in = '0;
      for (int g = 0; g < WAYS; g++) d_in[8*g] = dirt_s;
    end
    altsyncram #(
      .operation_mode("DUAL_PORT"), .width_a(8*WAYS), .widthad_a(DSB), .numwords_a(1 << DSB), .width_byteena_a(WAYS),
      .byte_size(8), .width_b(8*WAYS), .widthad_b(DSB), .numwords_b(1 << DSB), .address_reg_b("CLOCK0"),
      .outdata_reg_b("UNREGISTERED"), .read_during_write_mode_mixed_ports("OLD_DATA"), .power_up_uninitialized("FALSE"),
      .ram_block_type("M10K"), .intended_device_family("Cyclone V"), .lpm_type("altsyncram")
    ) u_ram (.clock0(clk), .address_a(dirt_wa), .data_a(d_in), .wren_a(|dirt_we), .byteena_a(dirt_we),
             .address_b(dt_aa), .q_b(d_out));
    always_comb for (int g = 0; g < WAYS; g++) dirt_rq[g] = d_out[8*g];
`else
    logic [WAYS-1:0] m [0:(1<<DSB)-1];
    initial for (int i = 0; i < (1<<DSB); i++) m[i] = '0;
    always_ff @(posedge clk) begin
      for (int g = 0; g < WAYS; g++) if (dirt_we[g]) m[dirt_wa][g] <= dirt_s;
      dirt_rq <= m[dt_aa];
    end
`endif
  end else begin : g_nodirt
    assign dirt_rq = '0;
  end endgenerate
`ifndef SYNTHESIS
  // synthesis translate_off
  // the flops the M10K replaced, as a check: the bits S_TAG takes must be theirs (dt_aa a clock ahead of dset)
  logic [WAYS-1:0] dirt_sh [0:(1<<DSB)-1];
  initial for (int i = 0; i < (1<<DSB); i++) dirt_sh[i] = '0;
  always_ff @(posedge clk) begin
    for (int g = 0; g < WAYS; g++)
      if (dirt_s && wd_way == $clog2(WAYS)'(g)) dirt_sh[w_addr[DSB+4:5]][g] <= 1'b1;
      else if (dirt_c && vway == $clog2(WAYS)'(g)) dirt_sh[dset][g] <= 1'b0;
    if (MEM1 && !rst && st == S_TAG && k != 3'd0 && dirt_q !== dirt_sh[dset]) $error("arm9_mem: dirty bits %b, not %b, at set %0d", dirt_q, dirt_sh[dset], dset);
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
    it_ad = {{(ILW-WB){1'b0}}, ilru + 1'b1, {WAYS{1'b1, ia[31:ISB+5]}}};
    it_we = '0;
    busy_d = 1'b0;
    busy_i = 1'b0;
    case (st)
      S_TAG, S_EVRD, S_EVRD2, S_EVWR, S_FILL, S_TAGW: begin
        busy_d = 1'b1;
        dc_aa = {dset, k};
        dt_aa = dset;
        for (int w = 0; w < WAYS; w++) dc_we[w] = 4'h0;
        dt_we = '0;
        dc_ad = b_rdata;
        if (st == S_FILL && b_ack) dc_we[vway] = 4'hF;
        if (st == S_TAGW) begin
          if (dp_kind == DK_LINE) begin
            logic [DLW-1:0] t;
            t = tlane;
            t[DTW] = 1'b0;                                           // clean
            if (cmo_op[6:3] != 4'd10) t[DTW+1] = 1'b0;               // invalidate
            dt_ad[WAYS*DLW-1:0] = {WAYS{t}};
            dt_we = (WAYS+1)'(1) << vway;
          end else begin
            dt_ad[WAYS*DLW-1:0] = {WAYS{1'b1, 1'b0, dp_a[31:DSB+5]}};   // the new line
            dt_we = ((WAYS+1)'(1) << vway) | ((WAYS+1)'(1) << WAYS);  // and the counter
          end
        end
      end
      S_PFCHK: begin
        it_aa = ia[ISB+4:5];
      end
      S_ITAG, S_IFILL, S_ITAGW: begin
        busy_i = !(pf_run && st != S_ITAGW);
        if (iline) busy_d = 1'b1;
        ic_aa = {ia[ISB+4:5], k};
        it_aa = !iline ? ia[ISB+4:5] : (cmo_op[2:0] == 3'd2) ? sw_iset(dp_val, swa_i) : dp_val[ISB+4:5];
        if (st == S_IFILL && b_ack) ic_we[vway] = 1'b1;
        if (st == S_ITAGW) begin
          if (iline) begin
            it_ad[WAYS*ILW-1:0] = '0;
            it_we = {1'b0, imask};
          end else it_we = ((WAYS+1)'(1) << vway) | ((WAYS+1)'(1) << WAYS);  // new line, counter
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
      S_EVDRN:  begin b_req = 1'b1; b_we = 1'b1; b_addr = EVBW ? {ev_a, 5'b0} : {ev_a, k[2:0], 2'b00}; b_wdata = ev_d[k[2:0]]; end
      S_RD1:    begin b_req = 1'b1; b_addr = {dp_a[31:2], 2'b00}; end
      S_IRD1:   begin b_req = 1'b1; b_addr = {ip_a[31:2], 2'b00}; end
      S_EVWR:   begin b_req = 1'b1; b_we = 1'b1; b_wdata = dc_aq[vway];
                      b_addr = {ev_lane[DTW-1:0], dset, k, 2'b00}; end
      S_FILL:   begin b_req = 1'b1; b_addr = {dp_a[31:5], k, 2'b00}; end
      S_IFILL:  begin b_req = 1'b1; b_addr = {ia[31:5], k, 2'b00}; end
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
    w_wdata <= cp_req ? cp_wdata : d_wdata;
    w_cp    <= cp_req;
    w_cpwe  <= cp_we;
    w_cpop  <= cp_op;

    if (rst) begin
      ctrl <= RESET_CTRL;
      dcb <= 8'h0; wbb <= 8'h0;
      
      ren <= 8'h0;
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
          wb_m[wb_wp & 3'(WBD - 1)] <= {w_addr, w_wdata,
                                        w_addr[31:12] == 20'h04000 && w_addr[11:4] == 8'h10 ? 4'd1 << w_addr[3:2] : 4'd0, w_be};
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
            vway <= w;
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
          ev_v <= 1'b1;
          ev_k <= 3'd0;
          k <= 3'd0;
          st <= S_FILL;
        end
        S_EVDRN: if (EVBW) begin
          if (b_wnext) k <= k + 3'd1;
          if (b_ack) begin ev_v <= 1'b0; st <= S_IDLE; end
        end else if (b_ack) begin
          k <= k + 3'd1;
          ev_k <= k + 3'd1;
          if (k == 3'd7) begin ev_v <= 1'b0; ev_k <= 3'd0; st <= S_IDLE; end
          else if (EVY && ev_idle && ev_pass) st <= S_IDLE;    // yield to the pending request; the rest drains later
        end
        S_EVWR: if (b_ack) begin
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
              for (int x = 0; x < WAYS; x++)
                imask[x] <= it_aq[x*ILW + ITW] && (cmo_op[2:0] == 3'd2 ? (sw_way(dp_val) == x[WB-1:0])
                                                                        : (it_aq[x*ILW +: ITW] == dp_val[31:ISB+5]));
              st <= S_ITAGW;
            end else begin
              vway <= it_aq[WAYS*ILW +: WB];
              ilru <= it_aq[WAYS*ILW +: WB];
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
            for (int x = 0; x < WAYS; x++)
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
      ev_d[st == S_EVRD2 ? 3'd7 : k - 3'd1] <= dc_aq[vway];

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
endmodule
