// NDS geometry engine front (docs/geometry-engine.md): the GX FIFO, GXSTAT
// and melonDS's command-timing model (GPU3D::Run/ExecuteCommand/AddCycles,
// references/melonDS/src/GPU3D.cpp), evaluated once per DS system cycle.
//
// Writes: the packed FIFO port (0x400-0x43F, WriteToGXFIFO's unpacking)
// and the command ports (0x440-0x5CB) take 32-bit writes. A write becomes
// up to four entries in a staging buffer; they go into the entry RAM, then
// are counted into melonDS's 4-entry PIPE and 256-entry FIFO in the second
// cycle of a tick, after that cycle's step and before the next tick's Run.
// An entry that does not fit stays staged and holds the bus (melonDS's
// stall queue and CPU stall); it is counted when a refill frees space.
//
// The model: each tick is melonDS's Run() for one system cycle. Step A (the
// tick cycle) decrements CycleCount and executes the PIPE head or runs
// FinishWork; step B (the next cycle) executes a second entry if the first
// left CycleCount <= 0. Every entry costs at least one cycle, so a Run never
// needs a third step. The model only tracks what timing and GXSTAT need;
// the engine (gpu3d_gxeng) runs the same entries behind it, up to `mx`.
//
// One thing flows back from the engine: whether each submitted polygon was
// rejected and whether it became a quad, which sets the polygon pipeline.
// The model counts the cycles since the submission and resolves the
// pipeline when the engine answers. It waits only where melonDS reads the
// pipeline: the next vertex slot, a stalling command, the busy bit.
module gpu3d_gxfront #(
    // 1: GX cheap timing (docs/budget-3d.md, option (a); a DS deviation the maintainer approved): every entry costs a
    // fixed number of cycles by command (cheap_idx/cheap_val), the vertex, normal and polygon pipelines never fill,
    // so no NextVertexSlot / StallPolygonPipeline and no polygon outcomes; the FIFO, PIPE, GXSTAT bits,
    // IRQ/DMA rules and stalls are unchanged. Matches the census melonDS with GX_CHEAP=gx-cheap-table-full.txt.
    // 0: melonDS's timing model, exact
    parameter bit CHEAP = 1'b0,
    // 1: wr_pre carries gpu3d_gxpre(wr_data), registered with the write's data a clock before (a timing
    // path: the packed-word decode does not fit in the accepting clock); 0: decoded here
    parameter bit PRE = 1'b0,
    // 1: the entries beyond the on-chip 512 spill to SDRAM (a ring of 2^SP_AW entries at word SP_BASEW, 8 bytes
    // an entry, 4 to a 32-byte block) and come back in order as the engine frees room: the timing model runs
    // up to 511 + 2^SP_AW entries ahead of the engine instead of 511 (docs/geometry-redesign.md "GX spill").
    // DS-visible timing is the model's either way
    parameter bit SPILL = 1'b0,
    parameter int SP_AW = 12,             // 4,096 entries (32 KiB): the deepest measured, sm64-pipes, ~2,600 (docs/geometry-engine.md)
    parameter logic [23:0] SP_BASEW = 24'h0C0000,  // byte 0x300000 (free SDRAM, docs/phase2-integration.md)
    parameter int SP_ON = 512,         // SPILL: on-chip entries before spilling (tests: fewer)
    parameter bit GATH16 = 1'b0        // SPILL: a 16-entry gather (same MLAB) instead of 8: the writes wait less for a block write behind the ring
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,          // ends a 33.51 MHz system cycle
    input  logic        geom_en,       // POWCNT1 bit 3 (GeometryEnabled)
    input  logic        vblank,        // GPU3D::VBlank
    // writes, word address within 0x4000400..0x40007FF
    input  logic        wr_req,
    input  logic [3:0]  wr_be,
    input  logic [9:2]  wr_addr,
    input  logic [31:0] wr_data,
    input  logic [20:0] wr_pre,        // PRE: gpu3d_gxpre(wr_data)
    output logic        wr_wait,
    // GXSTAT (0x600) without the engine's bits 0/1; DISP_1DOT_DEPTH
    output logic [31:0] gxstat,
    output logic [23:0] zerodot,
    output logic        flush_req,     // FlushRequest
    output logic        irq,           // GX FIFO IRQ condition (GXSTAT 31:30)
    output logic        dma_low,       // FIFO under half full (DMA mode 7)
    output logic        gx_stall,      // staged entries wait for FIFO space (melonDS GXFIFOStall)
    // entry RAM read port for the engine
    input  logic [8:0]  e_addr,
    output logic [39:0] e_data,        // {cmd, param}, the cycle after e_addr
    output logic [8:0]  mx,            // next entry the model executes
    input  logic [8:0]  dp,            // next entry the engine runs
    // polygon outcomes from the engine, in submission order
    input  logic        oc_valid,
    input  logic        oc_rej,
    input  logic        oc_quad,
    output logic        test_exec,     // a BOX/POS/VEC_TEST completed in the model
    // test bench
    output logic        dbg_stall,     // the model waits for an outcome
    output logic        dbg_apply,     // staged entries were counted this cycle
    // diagnostics (docs/diag.md; unconnected in a release build): the DS FIFO full, entries in the
    // entry RAM, the timing model executes an entry
    output logic        dg_full,
    output logic [12:0] dg_used,       // entries written and not popped (SPILL: on chip + spilled)
    output logic        dg_exec,
    // SPILL: the engine may pop (an entry the model executed is on chip), and the SDRAM ports (block writes of 8
    // words, a sp_wack each; 32-byte block reads: sp_rack, then 8 sp_rvalid)
    output logic        e_avail,
    input  logic        e_pop,
    output logic        e_more,
    output logic        sp_wreq,
    output logic [23:0] sp_waddr,
    output logic [31:0] sp_wdata,
    input  logic        sp_wack,
    input  logic        sp_wdrained,   // all chain writes so far are in the SDRAM controller (a block may be read back)
    output logic        sp_rreq,
    output logic [23:0] sp_raddr,
    input  logic        sp_rack,
    input  logic        sp_rvalid,
    input  logic [31:0] sp_rdata
);
    // CmdNumParams
    function automatic [5:0] nparams(input [7:0] c);
        case (c)
            8'h10, 8'h12, 8'h13, 8'h14, 8'h20, 8'h21, 8'h22, 8'h24, 8'h25,
            8'h26, 8'h27, 8'h28, 8'h29, 8'h2A, 8'h2B, 8'h30, 8'h31, 8'h32, 8'h33,
            8'h40, 8'h50, 8'h60, 8'h72: nparams = 6'd1;
            8'h16, 8'h18: nparams = 6'd16;
            8'h17, 8'h19: nparams = 6'd12;
            8'h1A: nparams = 6'd9;
            8'h1B, 8'h1C, 8'h70: nparams = 6'd3;
            8'h23, 8'h71: nparams = 6'd2;
            8'h34: nparams = 6'd32;
            default: nparams = 6'd0;
        endcase
    endfunction

    // GX cheap timing (CHEAP): cycles per entry by key = command * 2 + (ExecParamCount is 0 after the entry),
    // tools/melonds-census/gx-cheap-table-full.txt (gx-cheap-table.txt, the census average, every other key 1).
    // The entry RAM keeps an index into the 16 distinct costs (cheap_idx), and the head reads its cost back
    function automatic [3:0] cheap_idx(input [8:0] key);
        case (key)
            9'd35: cheap_idx = 4'd7;
            9'd37: cheap_idx = 4'd10;
            9'd39: cheap_idx = 4'd7;
            9'd41: cheap_idx = 4'd10;
            9'd43: cheap_idx = 4'd7;
            9'd45: cheap_idx = 4'd7;
            9'd47: cheap_idx = 4'd8;
            9'd51: cheap_idx = 4'd11;
            9'd53: cheap_idx = 4'd12;
            9'd55: cheap_idx = 4'd9;
            9'd57: cheap_idx = 4'd13;
            9'd65: cheap_idx = 4'd1;
            9'd67: cheap_idx = 4'd1;
            9'd70: cheap_idx = 4'd2;
            9'd71: cheap_idx = 4'd4;
            9'd73: cheap_idx = 4'd5;
            9'd75: cheap_idx = 4'd6;
            9'd77: cheap_idx = 4'd6;
            9'd79: cheap_idx = 4'd6;
            9'd81: cheap_idx = 4'd6;
            9'd97: cheap_idx = 4'd3;
            9'd99: cheap_idx = 4'd3;
            9'd101: cheap_idx = 4'd5;
            9'd103: cheap_idx = 4'd1;
            9'd129: cheap_idx = 4'd4;
            9'd131: cheap_idx = 4'd4;
            9'd161: cheap_idx = 4'd15;
            9'd225: cheap_idx = 4'd14;
            default: cheap_idx = 4'd0;
        endcase
    endfunction
    function automatic [8:0] cheap_val(input [3:0] i);
        case (i)
            4'd0: cheap_val = 9'd1;
            4'd1: cheap_val = 9'd2;
            4'd2: cheap_val = 9'd3;
            4'd3: cheap_val = 9'd4;
            4'd4: cheap_val = 9'd5;
            4'd5: cheap_val = 9'd6;
            4'd6: cheap_val = 9'd8;
            4'd7: cheap_val = 9'd17;
            4'd8: cheap_val = 9'd21;
            4'd9: cheap_val = 9'd33;
            4'd10: cheap_val = 9'd36;
            4'd11: cheap_val = 9'd50;
            4'd12: cheap_val = 9'd57;
            4'd13: cheap_val = 9'd62;
            4'd14: cheap_val = 9'd255;
            4'd15: cheap_val = 9'd388;
            default: cheap_val = 9'd1;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // staging: one bus write -> up to four entries (WriteToGXFIFO)
    // ------------------------------------------------------------------
    logic [2:0]  pk_nc;                // NumCommands
    logic [31:0] pk_cur;               // CurCommand
    logic [5:0]  pk_pc, pk_tp;         // ParamCount, TotalParams
    logic [2:0]  st_n, st_w, st_a;     // staged, written to RAM, counted
    logic [7:0]  st_cmd [4];
    // all entries of one write carry its word: wr_data, held by the writer until the write completes (st_done;
    // nds_gpu3d's g_wdata, tb_geom) — sim check below
    wire  [31:0] st_param = wr_data;
    logic        act;                  // a write is being staged
    logic        up;                   // its packed command word is being unpacked
    wire         st_busy = act;

    wire         w_fifo = wr_req && wr_be == 4'hF && !wr_addr[9] && wr_addr[8:2] < 7'h73 && geom_en;
    wire         w_pack = wr_addr[8:6] == 3'b000;          // 0x400-0x43F
    // WriteToGXFIFO's loop, one emitted entry per step: zero bytes (NOPs) are
    // never emitted except for an all-zero word, so a step skips them at once
    // (the old loop took one turn per byte with the same result)
    function automatic [2:0] lzb(input [31:0] v, input [2:0] n);   // leading zero bytes, at most n
        lzb = 3'd0;
        for (int k = 3; k >= 0; k--) if (3'(k) < n && v[8 * k +: 8] != 8'h00) lzb = 3'(k);
        if (n != 3'd0 && v[7:0] == 8'h00 && (n == 3'd1 || v[15:8] == 8'h00) && (n <= 3'd2 || v[23:16] == 8'h00) &&
            (n <= 3'd3 || v[31:24] == 8'h00)) lzb = n;
    endfunction
    // a new packed command word: skip its leading zero bytes
    wire  [2:0]  w_z    = PRE ? wr_pre[2:0] : lzb(wr_data, 3'd4);
    wire  [31:0] w_cur  = wr_data >> {w_z, 3'b000};
    wire  [5:0]  w_tp   = PRE ? wr_pre[9:4] : nparams(w_cur[7:0]);
    wire         w_zero = PRE ? wr_pre[3] : wr_data == 32'd0;   // emits one NOP
    // a packed word whose first command takes parameters stages nothing
    wire         w_none = w_pack && pk_nc == 3'd0 && (PRE ? wr_pre[19] : !w_zero && w_tp != 6'd0);
    // the step: emit the current command, then (its parameters in) move past
    // it and the zero bytes after it; the step ends where parameters are due
    logic [31:0] s_cur;
    logic [2:0]  s_nc;
    logic [5:0]  s_pc, s_tp;
    always_comb begin
        if (!act) begin                // the accepted word itself
            s_cur = pk_nc == 3'd0 ? w_cur : pk_cur;
            s_nc  = pk_nc == 3'd0 ? 3'd4 - w_z : pk_nc;
            s_pc  = pk_nc == 3'd0 ? 6'd0 : pk_pc + 6'd1;
            s_tp  = pk_nc == 3'd0 ? w_tp : pk_tp;
        end else begin
            s_cur = pk_cur; s_nc = pk_nc; s_pc = pk_pc; s_tp = pk_tp;
        end
    end
    wire         i_next = s_pc >= s_tp;
    // a new word's first step comes from wr_pre with PRE
    wire         i_new  = PRE && !act && pk_nc == 3'd0;
    // the command after pk_cur's, shared with pk_upb's step below: with PRE, s_* are pk_* except for a new
    // word (i_new), whose step comes from wr_pre
    wire  [2:0]  sh_z   = lzb(pk_cur >> 8, pk_nc - 3'd1);
    wire  [31:0] sh_cur = pk_cur >> {sh_z + 3'd1, 3'b000};
    wire  [5:0]  sh_tp  = nparams(sh_cur[7:0]);
    wire  [2:0]  i_z    = i_new ? wr_pre[12:10] : PRE ? sh_z : lzb(s_cur >> 8, s_nc - 3'd1);
    wire  [31:0] i_cur  = !i_next ? s_cur : PRE && !i_new ? sh_cur : s_cur >> {i_z + 3'd1, 3'b000};
    wire  [2:0]  i_nc   = i_next ? s_nc - 3'd1 - i_z : s_nc;
    wire  [5:0]  i_tp   = i_next ? (i_new ? wr_pre[18:13] : PRE ? sh_tp : nparams(i_cur[7:0])) : s_tp;
    wire  [5:0]  i_pc   = i_next ? 6'd0 : s_pc;
    // PRE: up after a parameter word continues the packed word in pk_* (the step of !act with pk_nc != 0),
    // from pk_* a clock earlier: they are written at least two clocks before a following word is taken
    // (the write that wrote them completes first; the next is registered in nds_gpu3d)
    logic        pk_upb, pk_wr;
    always_ff @(posedge clk) begin
        logic [5:0] bpc;
        logic       bnx, bend;
        logic [2:0] bz, bnc;
        logic [31:0] bcur;
        logic [5:0] btp, bipc;
        bpc  = pk_pc + 6'd1;
        bnx  = bpc >= pk_tp;
        bz   = sh_z;
        bcur = sh_cur;
        bnc  = bnx ? pk_nc - 3'd1 - bz : pk_nc;
        btp  = bnx ? sh_tp : pk_tp;
        bipc = bnx ? 6'd0 : bpc;
        bend = bnc == 3'd0 || bipc < btp;
        pk_upb <= !bend;
    end
    wire         i_end  = i_nc == 3'd0 || i_pc < i_tp;
    // i_end of an unpacking step (act: s_* = pk_*), with pk_nc only in the last compare (#626: pk_nc -> up
    // -0.736 ns through lzb's count). up is set only with commands left, so pk_nc is 1..4 here: the next
    // command is the first non-zero byte after byte 0 (bz_f; 3: none) if it lies within pk_nc - 1 bytes
    wire  [2:0]  bz_f   = pk_cur[15:8] != 8'h00 ? 3'd0 : pk_cur[23:16] != 8'h00 ? 3'd1 : pk_cur[31:24] != 8'h00 ? 3'd2 : 3'd3;
    wire  [7:0]  b_nx   = bz_f == 3'd0 ? pk_cur[15:8] : bz_f == 3'd1 ? pk_cur[23:16] : pk_cur[31:24];
    wire         up_end = pk_pc < pk_tp || bz_f >= pk_nc - 3'd1 || nparams(b_nx) != 6'd0;
    // a FIFO write completes once its entries are counted (as melonDS's
    // synchronous Write32), so a following GXSTAT read sees it
    wire   st_done = act && !up && st_a == st_n && st_w == st_n;
    assign wr_wait = w_fifo && !st_done && !(!act && w_none);
`ifndef ALTERA_RESERVED_QIS
    // synthesis translate_off
    always_ff @(posedge clk)
        if (!rst && act && up && up_end != i_end) $error("gpu3d_gxfront: up_end %0d != i_end %0d", up_end, i_end);
    always_ff @(posedge clk)
        if (!rst && PRE && !i_new && (s_cur != pk_cur || s_nc != pk_nc || s_tp != pk_tp))
            $error("gpu3d_gxfront: the shared next-command step sees s_* != pk_*");
    logic [31:0] st_word;              // the word as the write was accepted
    always_ff @(posedge clk) begin
        if (w_fifo && !act) st_word <= wr_data;
        if (!rst && act && wr_data != st_word) $error("gpu3d_gxfront: the write's word changed while staged (%08x, accepted %08x)", wr_data, st_word);
    end
    // synthesis translate_on
`endif

    // ------------------------------------------------------------------
    // entry RAM {cmd, param} for the engine, narrow copy for the model
    // ------------------------------------------------------------------
    logic [8:0]  wr;
    logic [8:0]  mx_n;                 // mx next cycle (decoded RAM address)
    wire  [8:0]  used = wr - dp;
    logic        sp_full;              // SPILL: no room for another entry (on chip, the gather, SDRAM)
    logic [12:0] sp_used;              // SPILL: occ + sq, for the diagnostics (used = wr - dp wraps at 512 once entries spill)
    wire         ram_we = st_busy && st_w != st_n && (SPILL ? !sp_full : used != 9'd511);
    // the command byte as the engine dispatches on it (gpu3d_gxu_pkg gx_ecode: {multi-parameter, 0, handler entry})
    wire  [39:0] ram_wd = {gpu3d_gxu_pkg::gx_ecode(st_cmd[st_w[1:0]]), st_param};
`ifndef ALTERA_RESERVED_QIS   // (Quartus rejects $value$plusargs)
    // synthesis translate_off
    // +gxlog=FILE: every entry as it enters the entry RAM, in the census GX trace's record ('C' u8 cmd u32 param,
    // little endian; sim/pocket_ds/w2load_cmp.py compares it with melonDS's --gx-first trace)
    integer gxl_fd = 0;
    initial begin
        string gxl_f;
        if ($value$plusargs("gxlog=%s", gxl_f)) gxl_fd = $fopen(gxl_f, "wb");
    end
    always_ff @(posedge clk) if (gxl_fd != 0 && !rst && ram_we)
        $fwrite(gxl_fd, "C%c%c%c%c%c", st_cmd[st_w[1:0]], st_param[7:0], st_param[15:8], st_param[23:16], st_param[31:24]);
    final if (gxl_fd != 0) $fclose(gxl_fd);
    // synthesis translate_on
`endif
    // CHEAP: no read-during-write logic (#669: -0.385 ns from its write enable through the entry to the
    // control store's address). The engine reads entry e_addr while one is written only when it is the
    // next entry (dp_r + 1 at a pop with one entry left), and with the cheap model takes it a clock later
    // at the earliest, after mx counts it; the simulation returns inverted data at a same-address read
    // and write. Without CHEAP (melonDS's timing, tests only) mx can count an entry in the clock it is
    // written, so the RAM keeps its read-during-write logic there.
    generate if (!SPILL) begin : g_ent
        gpu3d_ram #(.W(40), .AW(9), .STYLE(CHEAP ? "M10K, no_rw_check" : "AUTO")) u_ent (
            .clk, .we(ram_we), .waddr(wr), .wdata(ram_wd), .raddr(e_addr), .rdata(e_data));
        assign e_avail = dp != mx; assign e_more = dp != mx; assign sp_full = 1'b0; assign sp_used = '0;
        assign sp_wreq = 1'b0; assign sp_waddr = '0; assign sp_wdata = '0; assign sp_rreq = 1'b0; assign sp_raddr = '0;
    end else begin : g_spill
        // u_ent holds the engine's next entries in order (slot oc next): an entry written while nothing is
        // spilled and there is room goes straight in; otherwise into the gather (an 8-entry MLAB ring at sw, 16 with GATH16),
        // whose full 4-entry blocks go to SDRAM; refills come back from SDRAM (sr's block written) or straight
        // from the gather. Counters: ul entries the model has executed and the engine not popped (the engine
        // pops only those, as dp != mx did); occ entries in u_ent. The entries written and not popped are occ + sq
        localparam int SPN = 1 << SP_AW;
        localparam int GA = GATH16 ? 4 : 3;    // the gather's address bits (2^GA entries)
        logic [8:0]  oc;
        logic [9:0]  occ;
        logic [SP_AW-1:0] sw, swb, sr;     // gather write, next block to write, refill read (entry indices)
        logic [2:0]  nb;                    // blocks before swb not yet seen drained into SDRAM (swd = swb - 4 nb: swb a clock old,
        logic        adv_q;                 //   taken while drained, as the ring's wsafe); adv_q: swb advanced last clock
        wire  [SP_AW:0] sq = {1'b0, sw - sr};   // spilled entries not yet back on chip (at most SPN - 64: sp_full)
        assign sp_used = 13'(occ) + 13'(sq);
        logic [SP_AW:0] ul;                 // (at most occ + sq < SPN + 512)
        logic [39:0] g_q;
        logic [1:0]  wsec;                  // the block writer: entry 0..3 (two words each)
        logic        wwd, wact;             // word 1 of the entry, a block being written
        logic        ract;                  // a block read outstanding
        logic [2:0]  rw;                    // its next word
        logic [7:0]  rhi;                   // the entry's high byte (its first SDRAM word)
        logic [1:0]  rj0;                   // the first entry of the block that is still wanted
        logic        w1, w2;                // u_ent writes 1 and 2 clocks ago (not yet readable by the engine)
        wire pop = e_pop;
        wire direct = ram_we && sq == '0 && occ < 10'(SP_ON);
        wire push   = ram_we && !direct;
        // refill: from the gather (sr's block not written yet) one entry a clock, or a block read
        // sr in the gather (at or past swb, the oldest unwritten block) or already in SDRAM (behind swb)
        wire [SP_AW-1:0] srb = sr - swb;
        wire inA    = srb < SP_AW'(GATH16 ? 32 : 16);   // (behind swb: srb >= 64, sq <= SPN - 64)
        wire gfill  = sq != '0 && inA && !ract && !wact && occ < 10'd512;   // (the gather's read port: the block writer's first)
        wire rvw    = ract && sp_rvalid && rw[0] && 2'(rw[2:1]) >= rj0;     // a block word completing a wanted entry
        wire ent_we = direct || gfill || rvw;
        wire [39:0] ent_wd = direct ? ram_wd : gfill ? g_q : {rhi, sp_rdata};
        gpu3d_ram #(.W(40), .AW(9), .STYLE(CHEAP ? "M10K, no_rw_check" : "AUTO")) u_ent (
            .clk, .we(ent_we), .waddr(oc), .wdata(ent_wd), .raddr(e_addr), .rdata(e_data));
        gpu3d_lram #(.W(40), .AW(GA)) u_gat (.clk, .we(push), .waddr(sw[GA-1:0]), .wdata(ram_wd),
                                            .raddr(wact ? {swb[GA-1:2], wsec} : sr[GA-1:0]), .rdata(g_q));
        // (no capacity term: occ + sq reaches 511 + SPN - 8 only past the last term's SPN - 64)
        assign sp_full  = (sq != '0 || occ >= 10'(SP_ON)) && (sw - swb) >= SP_AW'(1 << GA) ||
                          !(sq == '0 && occ < 10'(SP_ON)) && sq >= (SP_AW+1)'(SPN - 64);   // (inA's modular window)
        assign e_avail  = ul != '0 && occ > 10'(w1) + 10'(w2);
        assign e_more   = ul != '0;
        // the block writer: swb's block once its 4 entries are in the gather (skipped if the refill took it already)
        wire wskip = !wact && nb != 3'd7 && inA && srb >= SP_AW'(4);
        wire wneed = !wact && nb != 3'd7 && !wskip && (sw - swb) >= SP_AW'(4);
        wire adv   = wskip || wact && sp_wack && wwd && wsec == 2'd3;
        assign sp_wreq  = wact;
        assign sp_waddr = SP_BASEW + 24'({swb[SP_AW-1:2], wsec, wwd});
        assign sp_wdata = wwd ? g_q[31:0] : {24'd0, g_q[39:32]};   // the high byte first
        // the block read: sr's block once written (sr behind swb), with room for its 4 entries
        // (sr behind swd: its block written and drained)
        // (swb - sr > 4 nb: with sr behind swb (!inA), the block count -srb/4 above nb, i.e. no carry out of
        // srb's blocks + nb)
        wire [SP_AW-2:0] rnb = {1'b0, srb[SP_AW-1:2]} + (SP_AW-1)'(nb);
        wire rneed = !ract && sq != '0 && !inA && !rnb[SP_AW-2] && occ <= 10'd508;
        logic rreq_q;
        assign sp_rreq  = rreq_q;
        assign sp_raddr = SP_BASEW + 24'({sr[SP_AW-1:2], 3'd0});
        always_ff @(posedge clk) begin
            w2 <= w1; w1 <= ent_we;
            if (rst) begin
                oc <= '0; occ <= '0; sw <= '0; swb <= '0; nb <= '0; adv_q <= 1'b0; sr <= '0; ul <= '0;
                wact <= 1'b0; wsec <= '0; wwd <= 1'b0; ract <= 1'b0; rreq_q <= 1'b0; rw <= '0; w1 <= 1'b0; w2 <= 1'b0;
            end else begin
                ul <= ul + (SP_AW+1)'(do_exec) - (SP_AW+1)'(pop);
                occ <= occ + 10'(ent_we) - 10'(pop);
                if (ent_we) oc <= oc + 9'd1;
                if (push) sw <= sw + SP_AW'(1);
                if (gfill || rvw) sr <= sr + SP_AW'(1);
                adv_q <= adv;
                nb <= sp_wdrained ? 3'(adv_q) + 3'(adv) : nb + 3'(adv);
                // the block writer
                if (wneed) begin wact <= 1'b1; wsec <= 2'd0; wwd <= 1'b0; end
                else if (wskip) swb <= swb + SP_AW'(4);
                if (wact && sp_wack) begin
                    wwd <= !wwd;
                    if (wwd) begin
                        wsec <= wsec + 2'd1;
                        if (wsec == 2'd3) begin wact <= 1'b0; swb <= swb + SP_AW'(4); end
                    end
                end
                // the block read
                if (rneed) begin ract <= 1'b1; rreq_q <= 1'b1; rw <= '0; rj0 <= sr[1:0]; end
                if (rreq_q && sp_rack) rreq_q <= 1'b0;
                if (ract && sp_rvalid) begin
                    rw <= rw + 3'd1;
                    if (!rw[0]) rhi <= sp_rdata[7:0];
                    if (rw == 3'd7) ract <= 1'b0;
                end
            end
        end
`ifndef SYNTHESIS
        // synthesis translate_off
        // a shadow of every entry written, in order, against what the engine pops
        logic [39:0] shd [0:1048575];
        int shw = 0, shr = 0;
        always_ff @(posedge clk) if (!rst) begin
            if (ram_we) begin shd[shw % 1048576] <= ram_wd; shw <= shw + 1; end
            if (pop) begin
                if (e_data != shd[shr % 1048576])
                    $error("gpu3d_gxfront SPILL: pop %0d got %010x, written %010x (occ %0d sq %0d sw %0d swb %0d sr %0d)",
                           shr, e_data, shd[shr % 1048576], occ, sq, sw, swb, sr);
                shr <= shr + 1;
            end
        end
        logic [8:0] dp_q;
        int ut = 0;
        always_ff @(posedge clk)
            if (!rst && !inA && (SP_AW'(swb - sr) > SP_AW'({nb, 2'b00})) == rnb[SP_AW-2])
                $error("gpu3d_gxfront SPILL: the read test's carry form disagrees (swb %0d sr %0d nb %0d)", swb, sr, nb);
        logic [SP_AW-1:0] swb_q, swd;       // the drain point as first built (swb a clock old, taken while drained)
        always_ff @(posedge clk) begin
            dp_q <= dp; swb_q <= rst ? '0 : swb;
            if (rst) begin ut <= 0; swd <= '0; end
            else begin
                ut <= ut + int'(ram_we) - int'(pop);
                if (sp_wdrained) swd <= swb_q;
                if (SP_AW'(swb - swd) != SP_AW'({nb, 2'b00})) $error("gpu3d_gxfront SPILL: nb %0d, swb %0d swd %0d", nb, swb, swd);
            end
        end
        always_ff @(posedge clk) if (!rst) begin
            if (ut != int'(occ) + int'(sq)) $error("gpu3d_gxfront SPILL: written and not popped %0d != occ %0d + sq %0d", ut, occ, sq);
            if (int'(ul) > ut) $error("gpu3d_gxfront SPILL: ul %0d > written and not popped %0d", ul, ut);
            if (wr - mx > 9'd400) $error("gpu3d_gxfront SPILL: the model trails the writes by %0d entries (u_nar is 512)", wr - mx);
            if (ent_we && occ >= 10'd512) $error("gpu3d_gxfront SPILL: u_ent overflow");
            if ((gfill || rvw) && sq == '0) $error("gpu3d_gxfront SPILL: refill with nothing spilled: gfill %0d rvw %0d rw %0d rj0 %0d sr %0d sw %0d swb %0d", gfill, rvw, rw, rj0, sr, sw, swb);
            if (sq[SP_AW-1:0] != SP_AW'(sw - sr)) $error("gpu3d_gxfront SPILL: sq %0d != sw %0d - sr %0d", sq, sw, sr);
            if ((sw - swb) > SP_AW'(1 << GA) || sq > (SP_AW+1)'(SPN)) $error("gpu3d_gxfront SPILL: invariant: sw %0d swb %0d sr %0d sq %0d wact %0d wsec %0d wwd %0d wneed %0d wskip %0d ract %0d", sw, swb, sr, sq, wact, wsec, wwd, wneed, wskip, ract);
            if (push && (sw - swb) >= SP_AW'(1 << GA)) $error("gpu3d_gxfront SPILL: gather overrun: sw %0d swb %0d sr %0d sq %0d occ %0d full %0d direct %0d wact %0d", sw, swb, sr, sq, occ, sp_full, direct, wact);
            if (pop && occ == '0) $error("gpu3d_gxfront SPILL: a pop with nothing on chip (dp %0d dp_q %0d ul %0d ut %0d sq %0d w1 %0d w2 %0d e_avail %0d)", dp, dp_q, ul, ut, sq, w1, w2, e_avail);
        end
        // synthesis translate_on
`endif
    end endgenerate

    // ------------------------------------------------------------------
    // the entries decoded as they are written (stream order): what
    // ExecuteCommand will do with each, as far as it depends on the entry
    // and on state only entries change (MatrixMode, ExecParamCount, the
    // light enables, PolygonMode, VertexNumInPoly, NumConsecutivePolygons)
    // ------------------------------------------------------------------
    typedef struct packed {
        logic [8:0] k;                 // cycles on top of the formula
        logic [1:0] bsel;              // formula: 0 none, 1 Delayed4 (np + 1), 2 Delayed6, 3 Delayed8
        logic       stall;             // StallPolygonPipeline: with a polygon pipeline, num = k after it
        logic [3:0] delay;             //   and that pipeline + delay cycles
        logic       needpp;            // reads the polygon pipeline (waits for a pending outcome)
        logic       vsc;               // VertexPipelineSubmitCmd: NextVertexSlot, or one cycle
        logic       vp4;               // SubmitVertex: VertexPipeline 4 afterwards
        logic       sub;               // SubmitPolygon
        logic       strip;             //   in a strip mode
        logic [1:0] npm;               // NormalPipeline afterwards: 0 zero, 1 seven, 2 kept
        logic       flush;
        logic       pushpop;
        logic [1:0] ntest;             // test commands completed
        logic [2:0] stk;               // 1 push, 2 pop, 3 store, 4 restore
        logic [1:0] mmode;
        logic [5:0] hp;                // param[5:0]
    } dec_t;
    dec_t        wd, hd;               // decoded entry being written; head entry
    logic [1:0]  ws_mmode, ws_pmode;   // write-side copies of the stream state
    logic [3:0]  ws_pattr, ws_cattr;
    logic [2:0]  ws_vnip;
    logic        ws_ncons;
    logic [5:0]  ws_xpc;
    logic [1:0]  wn_mmode, wn_pmode;
    logic [3:0]  wn_pattr, wn_cattr;
    logic [2:0]  wn_vnip;
    logic        wn_ncons;
    logic [5:0]  wn_xpc;
    generate if (CHEAP) begin : g_narc
        // what the cheap model reads of an entry: 19 bits, one M10K (512 x 20)
        logic [18:0] nq;
        gpu3d_ram #(.W(19), .AW(9)) u_nar (
            .clk, .we(ram_we), .waddr(wr), .wdata({wd.k[3:0], wd.flush, wd.pushpop, wd.ntest, wd.stk, wd.mmode, wd.hp}),
            .raddr(mx_n), .rdata(nq));
        always_comb begin
            hd = '0;
            hd.k = cheap_val(nq[18:15]); hd.flush = nq[14]; hd.pushpop = nq[13]; hd.ntest = nq[12:11];
            hd.stk = nq[10:8]; hd.mmode = nq[7:6]; hd.hp = nq[5:0];
        end
    end else begin : g_nar
        gpu3d_ram #(.W($bits(dec_t)), .AW(9)) u_nar (
            .clk, .we(ram_we), .waddr(wr), .wdata(wd), .raddr(mx_n), .rdata(hd));
    end endgenerate
    always_comb begin
        logic [7:0] c;
        logic [5:0] np_, hp;
        logic [3:0] lights;
        logic       submit;
        c = st_cmd[st_w[1:0]];
        hp = st_param[5:0];
        np_ = nparams(c);
        lights = 4'(ws_cattr[0]) + 4'(ws_cattr[1]) + 4'(ws_cattr[2]) + 4'(ws_cattr[3]);
        wd = '0;
        wd.mmode = ws_mmode; wd.hp = hp;
        wn_mmode = ws_mmode; wn_pmode = ws_pmode; wn_pattr = ws_pattr; wn_cattr = ws_cattr;
        wn_vnip = ws_vnip; wn_ncons = ws_ncons; wn_xpc = ws_xpc;
        submit = 1'b0;
        if (np_ <= 6'd1) begin
            case (c)
                8'h10: begin wd.bsel = 2'd1; wn_mmode = hp[1:0]; end
                8'h11: begin wd.bsel = 2'd1; wd.k = 9'd16; wd.pushpop = 1'b1; wd.stk = 3'd1; end
                8'h12: begin wd.bsel = 2'd1; wd.k = (ws_mmode == 2'd3) ? 9'd17 : 9'd35; wd.pushpop = 1'b1; wd.stk = 3'd2; end
                8'h13: begin wd.bsel = 2'd1; wd.k = 9'd16; wd.stk = 3'd3; end
                8'h14: begin wd.bsel = 2'd1; wd.k = (ws_mmode == 2'd3) ? 9'd17 : 9'd35; wd.stk = 3'd4; end
                8'h15: begin wd.bsel = 2'd1; wd.k = (ws_mmode == 2'd3) ? 9'd0 : 9'd18; end
                8'h20: wd.bsel = 2'd2;
                8'h30, 8'h31: begin wd.bsel = 2'd2; wd.k = 9'd3; end
                8'h72: begin wd.bsel = 2'd2; wd.k = 9'd4; wd.ntest = 2'd1; end
                8'h21: begin wd.bsel = 2'd1; wd.k = (lights == 4'd0) ? 9'd1 : 9'(lights); wd.npm = 2'd1; end   // CalculateLighting
                8'h24, 8'h25, 8'h26, 8'h27, 8'h28: begin wd.needpp = 1'b1; wd.vsc = 1'b1; submit = 1'b1; end
                8'h29: begin wd.bsel = 2'd3; wn_pattr = hp[3:0]; end
                8'h2A, 8'h2B, 8'h41, 8'h60: wd.bsel = 2'd3;
                8'h33: begin wd.bsel = 2'd3; wd.k = 9'd1; end
                8'h32: begin wd.needpp = 1'b1; wd.stall = 1'b1; wd.delay = 4'd9; wd.bsel = 2'd2; wd.k = 9'd5; end
                8'h40: begin
                    wd.needpp = 1'b1; wd.stall = 1'b1; wd.delay = 4'd1; wd.bsel = 2'd3;
                    wn_pmode = hp[1:0]; wn_vnip = 3'd0; wn_ncons = 1'b0; wn_cattr = ws_pattr;
                end
                8'h50: wd.flush = 1'b1;
                default: wd.bsel = 2'd1;
            endcase
        end else begin
            wn_xpc = ws_xpc + 6'd1;
            if (wn_xpc == 6'd1) begin
                case (c)
                    8'h23: begin wd.needpp = 1'b1; wd.vsc = 1'b1; end
                    8'h34, 8'h71: wd.bsel = 2'd3;
                    8'h70: begin wd.needpp = 1'b1; wd.stall = 1'b1; wd.delay = 4'd11; wd.bsel = 2'd3; end
                    default: wd.bsel = 2'd1;
                endcase
            end else begin
                wd.k = 9'd1; wd.npm = 2'd2;
                if (wn_xpc >= np_) begin
                    wn_xpc = 6'd0;
                    case (c)
                        8'h16: wd.k = 9'd1 + ((ws_mmode == 2'd3) ? 9'd10 : 9'd18);
                        8'h17: wd.k = 9'd1 + ((ws_mmode == 2'd3) ? 9'd7  : 9'd18);
                        8'h18: wd.k = 9'd1 + ((ws_mmode == 2'd3) ? 9'd17 : (ws_mmode == 2'd2) ? 9'd49 : 9'd19);
                        8'h19: wd.k = 9'd1 + ((ws_mmode == 2'd3) ? 9'd21 : (ws_mmode == 2'd2) ? 9'd53 : 9'd23);
                        8'h1A: wd.k = 9'd1 + ((ws_mmode == 2'd3) ? 9'd24 : (ws_mmode == 2'd2) ? 9'd56 : 9'd26);
                        8'h1B: wd.k = 9'd1 + ((ws_mmode == 2'd3) ? 9'd30 : 9'd32);
                        8'h1C: wd.k = 9'd1 + ((ws_mmode == 2'd3) ? 9'd30 : (ws_mmode == 2'd2) ? 9'd62 : 9'd32);
                        8'h23: begin submit = 1'b1; wd.npm = 2'd0; end
                        8'h71: begin wd.k = 9'd6; wd.ntest = 2'd2; end
                        8'h70: begin wd.k = 9'd255; wd.ntest = 2'd3; end
                        default: ;
                    endcase
                end
            end
        end
        // SubmitVertex: VertexPipeline = 7, AddCycles(3)
        if (submit) begin
            wd.k = wd.k + 9'd3; wd.vp4 = 1'b1;
            wn_vnip = ws_vnip + 3'd1;
            case (ws_pmode)
                2'd0: if (wn_vnip == 3'd3) begin wn_vnip = 3'd0; wd.sub = 1'b1; end
                2'd1: if (wn_vnip == 3'd4) begin wn_vnip = 3'd0; wd.sub = 1'b1; end
                2'd2: if (ws_ncons || wn_vnip == 3'd3) begin wn_vnip = 3'd2; wd.sub = 1'b1; end
                default: if (wn_vnip == 3'd4) begin wn_vnip = 3'd2; wd.sub = 1'b1; end
            endcase
            if (wd.sub) wn_ncons = ~ws_ncons;
            wd.strip = ws_pmode[1];
        end
        if (CHEAP) begin
            // the cost of the entry by its key (melonDS: ExecParamCount == 0 after it; a single-parameter
            // command leaves a partial command's count as it was); nothing else of the pipelines' timing
            wd.k = 9'(cheap_idx({c, wn_xpc == 6'd0}));     // an index, cheap_val at the head
            wd.bsel = 2'd0; wd.stall = 1'b0; wd.delay = 4'd0; wd.needpp = 1'b0; wd.vsc = 1'b0;
            wd.vp4 = 1'b0; wd.sub = 1'b0; wd.strip = 1'b0; wd.npm = 2'd0;
        end
    end

    // ------------------------------------------------------------------
    // model state
    // ------------------------------------------------------------------
    // CHEAP: CycleCount stays in -1..388 (at most 0 at an execution, which adds k <= 388: sim check below)
    localparam int CW = CHEAP ? 10 : 16;
    typedef struct packed {
        logic signed [CW-1:0] cyc;     // CycleCount
        logic [2:0] vp, np;            // VertexPipeline, NormalPipeline
        logic [5:0] pp;                // PolygonPipeline
        logic [3:0] vsc;               // VertexSlotCounter
        logic [4:0] vsf;               // VertexSlotsFree
        logic       pend;              // a submitted polygon's outcome is unknown
        logic [5:0] pend_e;            //   cycles since (saturating)
    } tm_t;
    tm_t         tm;
    logic        pend_strip;
    logic [1:0]  oc_skip;              // outcomes of polygons a later submission superseded
    logic [8:0]  f;                    // CmdFIFO level
    logic [2:0]  p;                    // CmdPIPE level
    logic        flush;
    logic        busy, b14, b0, b15;
    // GXSTAT bit 0 is b0 | b0s: b0s is "a test command entered the FIFO in the last clock", b0 the rest
    // (held, cleared), so the count's result reaches a flop without the clear logic (#621: p -> b0
    // -0.086 ns); the same bit every clock. Bit 14 likewise: b14 | b14s (pushes)
    logic        b0s, b14s;
    // NumPushPopCommands and NumTestCommands, each one counter of counted-in minus executed (mod 512):
    // only their zero tests matter, and in + d == ex is (in - ex) + d == 0 mod 512, so one difference
    // counter a count replaces the in and ex halves exactly
    logic [8:0]  npush, ntest;         // npush_s = npush + npush_d - npush_x is the count (ntest likewise)
    logic        npush_x;
    logic [1:0]  ntest_x;
    // the pushes and tests counted in the last clock, added to npush/ntest a clock later: the
    // counts are npush_s (ntest_s) at every clock (#483: f -> npush_in). They are
    // the staged entries [st_aq, st_a): st_aq is st_a before the last clock's count, so the window
    // comes from registers, not through the count (#689: st_a -> ntest_d -1.714 ns). Entries below
    // st_w do not change while staged; a new write (st_cmd[0]) restarts both at 0
    logic [2:0]  npush_d, ntest_d;
    logic [2:0]  st_aq;
    logic [5:0]  psp;                  // PosMatrixStackPointer
    logic        jsp, tsp;             // Proj/Tex stack pointers
    logic [1:0]  irqm;
    logic [23:0] zdot;
    logic        phase;                // 1 in the cycle after the tick (step B)
    logic        flush_t;              // flush in the tick cycle (Run's FlushRequest test)
    assign flush_req = flush;
    assign zerodot = zdot;

    // AddCycles(num)
    function automatic tm_t addc(input tm_t s, input [9:0] num);
        tm_t r;
        logic [6:0] v;
        r = s;
        r.cyc = s.cyc + $signed({6'd0, num});
        r.vp = ({7'd0, s.vp} > num) ? s.vp - num[2:0] : 3'd0;
        if (s.pend)
            r.pend_e = ({4'd0, s.pend_e} + num > 10'd63) ? 6'd63 : s.pend_e + num[5:0];
        else if (s.pp != 6'd0) begin
            if ({4'd0, s.pp} > num) begin
                r.pp = s.pp - num[5:0];
                v = {3'd0, s.vsc} + num[6:0];                // <= 44
                if (v > 7'd36)      begin r.vsc = 4'(v - 7'd36); r.vsf = s.vsf >> 4; end
                else if (v > 7'd27) begin r.vsc = 4'(v - 7'd27); r.vsf = s.vsf >> 3; end
                else if (v > 7'd18) begin r.vsc = 4'(v - 7'd18); r.vsf = s.vsf >> 2; end
                else if (v > 7'd9)  begin r.vsc = 4'(v - 7'd9);  r.vsf = s.vsf >> 1; end
                else                      r.vsc = v[3:0];
            end else begin
                r.pp = 6'd0; r.vsc = 4'd0; r.vsf = 5'd1;
            end
        end
        addc = r;
    endfunction

    // NextVertexSlot, closed form: after iteration k the cycles added are
    // num1 + 9(k-1), num1 = 10 - VertexSlotCounter; iteration k expires the
    // pipeline if PolygonPipeline <= that, else takes slot k if it is free.
    function automatic tm_t nvs(input tm_t s);
        tm_t r;
        logic [5:0] t [1:5];
        logic [2:0] k;
        logic       ex;
        logic [5:0] fr;                // VertexSlotsFree, with a zero bit 5 for the expiry-only iteration
        r = s;
        fr = {1'b0, s.vsf};
        for (int i = 1; i <= 5; i++) t[i] = 6'(10 - s.vsc) + 6'(9 * (i - 1));
        k = 3'd5; ex = 1'b1;
        for (int i = 5; i >= 1; i--) begin
            if (s.pp <= t[i])             begin k = 3'(i); ex = 1'b1; end
            else if (fr[i])               begin k = 3'(i); ex = 1'b0; end
        end
        r.cyc = s.cyc + $signed({10'd0, t[k]});
        r.vp = ({3'd0, s.vp} > t[k]) ? s.vp - t[k][2:0] : 3'd0;
        if (ex) begin
            r.pp = 6'd0; r.vsc = 4'd0; r.vsf = 5'd1;
        end else begin
            r.pp = s.pp - t[k];
            r.vsc = 4'd1;
            r.vsf = (s.vsf >> k) & 5'b11110;
        end
        nvs = r;
    endfunction

    // StallPolygonPipeline(delay, nonstalldelay)
    function automatic tm_t stallpp(input tm_t s, input [3:0] delay, input [2:0] nsd);
        tm_t r;
        if (s.pp != 6'd0) begin
            r = s;
            r.cyc = s.cyc + $signed({10'd0, s.pp}) + $signed({12'd0, delay});
            r.vp = 3'd0; r.np = 3'd0; r.pp = 6'd0; r.vsc = 4'd0; r.vsf = 5'd1;
        end else if (s.vp > nsd)
            r = addc(s, {7'd0, s.vp - nsd} + 10'd1);
        else
            r = addc(s, {7'd0, s.np} + 10'd1);
        stallpp = r;
    endfunction



    // ------------------------------------------------------------------
    // one execution of the PIPE head (GPU3D::ExecuteCommand's timing)
    // ------------------------------------------------------------------
    tm_t         s0, s_ex;
    typedef struct packed { logic [5:0] pp; logic [3:0] vsc; logic [4:0] vsf; } pl_t;
    pl_t sh [3];                       // shadow pipelines (below)
    wire         h_needpp = hd.needpp;
    wire         x_sub = hd.sub;
    logic        x_b15;
    logic [5:0]  x_psp;
    logic        x_jsp, x_tsp;
    // The execution is one pre-step (StallPolygonPipeline's pipeline branch,
    // or NextVertexSlot), then one AddCycles of the cycles the command adds
    // in total, which also serves FinishWork. melonDS's successive
    // AddCycles calls combine: AddCycles(a); AddCycles(b) == AddCycles(a + b).
    logic [9:0]  x_num;                // AddCycles of this step
    logic        x_pre_pp;             // stall branch with a polygon pipeline: zero it
    logic        x_nvs;                // NextVertexSlot first
    always_comb begin
        logic [9:0] f4, f6, f8, fv_;
        f4 = {7'd0, s0.np} + 10'd1;                                       // Delayed4
        f6 = (s0.vp > 3'd2) ? {7'd0, s0.vp} - 10'd1 : f4;                 // Delayed6
        f8 = (s0.vp > 3'd0) ? {7'd0, s0.vp} + 10'd1 : f4;                 // Delayed8
        case (hd.bsel)
            2'd1: fv_ = f4;
            2'd2: fv_ = f6;
            2'd3: fv_ = f8;
            default: fv_ = 10'd0;
        endcase
        // the four sums are formed before the selection: the polygon pipeline
        // (pre-step, free slot) can come from an outcome arriving this cycle
        x_pre_pp = hd.stall && s0.pp != 6'd0;
        // VertexPipelineSubmitCmd: the next vertex slot, or AddCycles(1)
        x_nvs = hd.vsc && !s0.vsf[0];
        case ({x_pre_pp, hd.vsc && s0.vsf[0]})
            2'b00: x_num = fv_ + {1'b0, hd.k};
            2'b01: x_num = fv_ + {1'b0, hd.k} + 10'd1;
            2'b10: x_num = {1'b0, hd.k};
            default: x_num = {1'b0, hd.k} + 10'd1;
        endcase
        // matrix stacks: GXSTAT bit 15 and the pointers
        x_b15 = b15; x_psp = psp; x_jsp = jsp; x_tsp = tsp;
        case (hd.stk)
            3'd1: if (hd.mmode == 2'd0)      begin if (jsp) x_b15 = 1'b1; x_jsp = ~jsp; end
                  else if (hd.mmode == 2'd3) begin if (tsp) x_b15 = 1'b1; x_tsp = ~tsp; end
                  else begin if (psp > 6'd30) x_b15 = 1'b1; x_psp = psp + 6'd1; end
            3'd2: if (hd.mmode == 2'd0)      begin if (!jsp) x_b15 = 1'b1; x_jsp = ~jsp; end
                  else if (hd.mmode == 2'd3) begin if (!tsp) x_b15 = 1'b1; x_tsp = ~tsp; end
                  else begin x_psp = psp - hd.hp; if (x_psp > 6'd30) x_b15 = 1'b1; end
            3'd3, 3'd4: if ((hd.mmode == 2'd1 || hd.mmode == 2'd2) && hd.hp[4:0] == 5'd31) x_b15 = 1'b1;
            default: ;
        endcase
    end
    // ------------------------------------------------------------------
    // the step of this cycle
    // ------------------------------------------------------------------
    logic run_skip, do_exec, do_fin;
    logic s0_le0;                      // s0.cyc <= 0, from the register: the decrement's compare off p -> do_exec (#676)
    tm_t  s_fin, s_next;
    always_comb begin
        tm_t t;
        t = tm;
        // the outcome arrives: its shadow pipeline
        if (oc_valid && t.pend && oc_skip == 2'd0) begin
            t.pend = 1'b0;
            t.pp  = oc_rej ? sh[0].pp  : oc_quad ? sh[2].pp  : sh[1].pp;
            t.vsc = oc_rej ? sh[0].vsc : oc_quad ? sh[2].vsc : sh[1].vsc;
            t.vsf = oc_rej ? sh[0].vsf : oc_quad ? sh[2].vsf : sh[1].vsf;
        end
        // melonDS's Run checks FlushRequest once, at its start: step B sees the flush as the tick did
        run_skip = !geom_en || (phase ? flush_t : flush) || (p == 3'd0 && !busy);
        // time stands still while the head waits for an outcome (no debt)
        if (tick && !run_skip && !(t.cyc <= 16'sd1 && p != 3'd0 && h_needpp && t.pend)) begin
            t.cyc = t.cyc - 16'sd1;
            s0_le0 = tm.cyc <= 16'sd1;
        end else
            s0_le0 = tm.cyc <= 16'sd0;
        s0 = t;
    end
    tm_t s_pre, s_add;
    always_comb begin
        logic [9:0] c, n;
        // step A in the tick cycle, step B in the next one
        do_exec = !run_skip && (tick || phase) && s0_le0 && p != 3'd0 &&
                  !(h_needpp && s0.pend);
        do_fin  = !run_skip && (tick || phase) && s0_le0 && p == 3'd0;
        c = 10'(-s0.cyc);                 // FinishWork(-CycleCount), 0..1
        // pre-step
        s_pre = s0;
        if (x_nvs) s_pre = nvs(s0);
        else if (x_pre_pp) begin
            s_pre.cyc = s0.cyc + $signed({10'd0, s0.pp}) + $signed({12'd0, hd.delay});
            s_pre.vp = 3'd0; s_pre.np = 3'd0; s_pre.pp = 6'd0; s_pre.vsc = 4'd0; s_pre.vsf = 5'd1;
        end
        // the one AddCycles
        n = do_exec ? x_num : c;
        s_add = addc(do_exec ? s_pre : s0, n);
        // execution results
        s_ex = s_add;
        s_ex.np = (hd.vsc || x_pre_pp || hd.npm == 2'd0) ? 3'd0 : (hd.npm == 2'd1) ? 3'd7 : s0.np;
        if (hd.vp4) s_ex.vp = 3'd4;
        if (x_sub) begin s_ex.pend = 1'b1; s_ex.pend_e = 6'd3; s_ex.cyc = s_pre.cyc + $signed({6'd0, x_num}); end
        if (hd.flush) begin
            s_ex = s0;
            s_ex.cyc = CHEAP ? s0.cyc + $signed({7'd0, hd.k}) : 16'sd325; s_ex.vp = 3'd0; s_ex.np = 3'd0; s_ex.pp = 6'd0; s_ex.vsc = 4'd0; s_ex.vsf = 5'd1;
        end
        // FinishWork
        s_fin = s_add;
        s_fin.np = (s0.np > c[2:0]) ? s0.np - c[2:0] : 3'd0;
        s_fin.cyc = 16'sd0;
        s_next = do_exec ? s_ex : do_fin ? s_fin : s0;
    end
`ifndef ALTERA_RESERVED_QIS
    // synthesis translate_off
    always_ff @(posedge clk)
        if (!rst && CHEAP && do_exec && (int'(s_pre.cyc) + int'(x_num) >= (1 << (CW - 1)) || int'(s0.cyc) + int'(hd.k) >= (1 << (CW - 1)) || int'(s0.cyc) < -1))
            $error("gpu3d_gxfront: CycleCount %0d + %0d leaves the CHEAP range", s0.cyc, x_num);
    // synthesis translate_on
`endif
    // shadow polygon pipelines while an outcome is pending, one per outcome
    // (rejected, triangle, quad): started where SubmitPolygon would set them
    // (3 cycles in, as resolve() did with pend_e = 3), then advanced by every
    // step like AddCycles; equal to resolve() with the elapsed cycles
    function automatic pl_t pl_adv(input pl_t s, input [9:0] num);
        pl_t r;
        logic [6:0] v;
        r = s;
        if (s.pp != 6'd0) begin
            if ({4'd0, s.pp} > num) begin
                r.pp = s.pp - num[5:0];
                v = {3'd0, s.vsc} + num[6:0];
                if (v > 7'd36)      begin r.vsc = 4'(v - 7'd36); r.vsf = s.vsf >> 4; end
                else if (v > 7'd27) begin r.vsc = 4'(v - 7'd27); r.vsf = s.vsf >> 3; end
                else if (v > 7'd18) begin r.vsc = 4'(v - 7'd18); r.vsf = s.vsf >> 2; end
                else if (v > 7'd9)  begin r.vsc = 4'(v - 7'd9);  r.vsf = s.vsf >> 1; end
                else                      r.vsc = v[3:0];
            end else begin
                r.pp = 6'd0; r.vsc = 4'd0; r.vsf = 5'd1;
            end
        end
        pl_adv = r;
    endfunction
    function automatic pl_t pl_start(input [1:0] k, input strip);   // k: 0 rejected, 1 triangle, 2 quad
        pl_t r;
        r.vsc = 4'd4;
        case (k)
            2'd0:    begin r.pp = 6'd8 - 6'd3;  r.vsf = 5'b11110; end
            2'd2:    begin r.pp = 6'd35 - 6'd3; r.vsf = strip ? 5'b11100 : 5'b11110; end
            default: begin r.pp = 6'd26 - 6'd3; r.vsf = strip ? 5'b01000 : 5'b01110; end
        endcase
        pl_start = r;
    endfunction
    wire [9:0] sh_num = do_exec ? x_num : 10'(-s0.cyc);          // the step's AddCycles (execution or FinishWork)
    always_ff @(posedge clk) if (!CHEAP) begin
        for (int k = 0; k < 3; k++) begin
            if (do_exec && x_sub)                    sh[k] <= pl_start(2'(k), hd.strip);
            else if (s0.pend && (do_exec || do_fin)) sh[k] <= pl_adv(sh[k], sh_num);
        end
    end
    assign mx_n = mx + (do_exec ? 9'd1 : 9'd0);
    assign dbg_stall = !run_skip && (tick || phase) && s0_le0 && p != 3'd0 && h_needpp && s0.pend;
`ifndef ALTERA_RESERVED_QIS
    // synthesis translate_off
    always_ff @(posedge clk)
        if (!rst && s0_le0 != (s0.cyc <= 16'sd0)) $error("gpu3d_gxfront: s0_le0 %0d, s0.cyc %0d", s0_le0, s0.cyc);
    // synthesis translate_on
`endif

    // staged entries counted this cycle: step B, or a refill freed space.
    // CmdFIFOWrite in closed form (into the PIPE while the FIFO is empty, then
    // the FIFO, up to a full FIFO, in order from st_a), for the levels this
    // cycle's execution leaves (one count, below)
    typedef struct packed {
        logic [8:0] f;
        logic [2:0] p, cnt, pushes, tests;
    } cnt_t;
    function automatic cnt_t fifo_count(input [8:0] fv, input [2:0] pv, input en, input [2:0] sa, input [2:0] sw,
                                        input [3:0] ispush, input [3:0] istest);
        cnt_t r;
        logic [2:0] kk, tpp, tff, rest;
        logic [8:0] room;
        kk   = en ? sw - sa : 3'd0;
        tpp  = (fv == 9'd0) ? ((kk < 3'd4 - pv) ? kk : 3'd4 - pv) : 3'd0;
        rest = kk - tpp;
        room = 9'd256 - fv;
        tff  = ({6'd0, rest} > room) ? room[2:0] : rest;
        r.cnt = tpp + tff;
        r.p = pv + tpp;
        r.f = fv + {6'd0, tff};
        r.pushes = 3'd0; r.tests = 3'd0;
        for (int k = 0; k < 4; k++)
            if (3'(k) >= sa && 3'(k) < sa + r.cnt) begin
                r.pushes = r.pushes + 3'(ispush[k]);
                r.tests = r.tests + 3'(istest[k]);
            end
        fifo_count = r;
    endfunction
    // CmdFIFORead: pop, refill to 4 when 2 or fewer are left
    logic [8:0] f_pop;
    logic [2:0] p_pop;
    always_comb begin
        p_pop = p - 3'd1; f_pop = f;
        if (p_pop <= 3'd2 && f != 9'd0) begin
            if (f == 9'd1) begin p_pop = p_pop + 3'd1; f_pop = 9'd0; end
            else begin p_pop = p_pop + 3'd2; f_pop = f - 9'd2; end
        end
    end
    logic [3:0] st_push, st_test;
    always_comb for (int k = 0; k < 4; k++) begin
        st_push[k] = st_cmd[k] == 8'h11 || st_cmd[k] == 8'h12;
        st_test[k] = st_cmd[k] == 8'h70 || st_cmd[k] == 8'h71 || st_cmd[k] == 8'h72;
    end
    always_comb begin
        npush_d = 3'd0; ntest_d = 3'd0;
        for (int k = 0; k < 4; k++)
            if (3'(k) >= st_aq && 3'(k) < st_a) begin
                npush_d = npush_d + 3'(st_push[k]);
                ntest_d = ntest_d + 3'(st_test[k]);
            end
        b0s = ntest_d != 3'd0;
        b14s = npush_d != 3'd0;
    end
    // the counts: the last clock's pushes and tests added, its executed command's (npush_x, ntest_x,
    // registered from do_exec and hd) taken off a clock late, so do_exec and hd reach only those flops
    wire [8:0] npush_s = npush + 9'(npush_d) - 9'(npush_x);
    wire [8:0] ntest_s = ntest + 9'(ntest_d) - 9'(ntest_x);
    wire  cnt_en = st_busy && st_a != st_w;
    // one count, of the FIFO and PIPE levels after this cycle's execution or without it (two counts chosen
    // at the end were for timing, before #676/#689 took do_exec's compare and the pushes/tests window off
    // this path)
    cnt_t cn_1;
    assign cn_1 = fifo_count(do_exec ? f_pop : f, do_exec ? p_pop : p, do_exec ? cnt_en && (phase || f == 9'd256) : cnt_en && phase,
                             st_a, st_w, st_push, st_test);
    logic count_now;
    always_comb count_now = do_exec ? cnt_en && (phase || f == 9'd256) : cnt_en && phase;
    assign dbg_apply = count_now;
`ifndef ALTERA_RESERVED_QIS
    // synthesis translate_off
    // the window [st_aq, st_a) against the count's own pushes and tests of the last clock
    logic [2:0] chk_np, chk_nt;
    logic       chk_v = 1'b0;
    always_ff @(posedge clk) begin
        chk_np <= cn_1.pushes; chk_nt <= cn_1.tests; chk_v <= !rst;
        if (chk_v && !rst && (npush_d != chk_np || ntest_d != chk_nt))
            $error("gpu3d_gxfront: window pushes %0d tests %0d, counted %0d %0d", npush_d, ntest_d, chk_np, chk_nt);
    end
    // the in and ex halves the difference counters replaced, kept beside them: npush == in - ex (ntest likewise)
    logic [8:0] chk_pin = 9'd0, chk_pex = 9'd0, chk_tin = 9'd0, chk_tex = 9'd0;
    always_ff @(posedge clk) begin
        if (rst) begin
            chk_pin <= 9'd0; chk_pex <= 9'd0; chk_tin <= 9'd0; chk_tex <= 9'd0;
        end else begin
            chk_pin <= chk_pin + 9'(npush_d); chk_tin <= chk_tin + 9'(ntest_d);
            if (do_exec && hd.pushpop) chk_pex <= chk_pex + 9'd1;
            if (do_exec) chk_tex <= chk_tex + {7'd0, hd.ntest};
            if (npush - 9'(npush_x) != chk_pin - chk_pex || ntest - 9'(ntest_x) != chk_tin - chk_tex)
                $error("gpu3d_gxfront: difference counters %0d %0d, in - ex %0d %0d", npush - 9'(npush_x), ntest - 9'(ntest_x), chk_pin - chk_pex, chk_tin - chk_tex);
            if ((npush_s == 9'd0) != (chk_pin + 9'(npush_d) == chk_pex) || (ntest_s == 9'd0) != (chk_tin + 9'(ntest_d) == chk_tex))
                $error("gpu3d_gxfront: zero tests differ from in + d == ex");
        end
    end
    // synthesis translate_on
`endif

    always_ff @(posedge clk) begin
        if (rst) begin
            tm <= '0; tm.vsf <= 5'd1;
            pend_strip <= 1'b0; oc_skip <= 2'd0; f <= 9'd0; p <= 3'd0;
            ws_mmode <= 2'd0; ws_pattr <= 4'd0; ws_cattr <= 4'd0; ws_pmode <= 2'd0; ws_vnip <= 3'd0;
            ws_ncons <= 1'b0; ws_xpc <= 6'd0; flush <= 1'b0;
            busy <= 1'b0; b14 <= 1'b0; b0 <= 1'b0; b15 <= 1'b0; npush <= 9'd0; ntest <= 9'd0; npush_x <= 1'b0; ntest_x <= 2'd0; st_aq <= 3'd0;
            psp <= 6'd0; jsp <= 1'b0; tsp <= 1'b0; irqm <= 2'd0; zdot <= 24'hFFFFFF;
            phase <= 1'b0; flush_t <= 1'b0; mx <= 9'd0; wr <= 9'd0;
            pk_nc <= 3'd0; pk_cur <= 32'd0; pk_pc <= 6'd0; pk_tp <= 6'd0;
            st_n <= 3'd0; st_w <= 3'd0; st_a <= 3'd0; act <= 1'b0; up <= 1'b0;
            for (int k = 0; k < 4; k++) st_cmd[k] <= 8'h00;
        end else begin
            cnt_t cn;
            logic bz, c14, c0;
            phase <= tick;
            if (tick) flush_t <= flush;
            tm <= s_next;
            if (CHEAP) begin
                // the pipelines stay empty
                tm.vp <= 3'd0; tm.np <= 3'd0; tm.pp <= 6'd0; tm.vsc <= 4'd0; tm.vsf <= 5'd1; tm.pend <= 1'b0; tm.pend_e <= 6'd0;
            end
            if (CHEAP) oc_skip <= 2'd0;
            else if (do_exec && x_sub && s0.pend) oc_skip <= oc_skip + 2'd1 - ((oc_valid && oc_skip != 2'd0) ? 2'd1 : 2'd0);
            else if (oc_valid && oc_skip != 2'd0) oc_skip <= oc_skip - 2'd1;
            cn = cn_1;
            bz = busy; c14 = b14 || b14s; c0 = b0 || b0s;
            // melonDS clears bits 14/0 before each ExecuteCommand and at the end of Run
            if (do_exec || do_fin) begin
                if (npush_s == 9'd0) c14 = 1'b0;
                if (ntest_s == 9'd0) c0 = 1'b0;
            end
            if (do_exec) begin
                if (hd.flush) flush <= 1'b1;
                b15 <= x_b15; psp <= x_psp; jsp <= x_jsp; tsp <= x_tsp;
                if (x_sub) pend_strip <= hd.strip;
            end
            mx <= mx_n;
            if (do_fin && s_fin.vp == 3'd0 && s_fin.np == 3'd0 && s_fin.pp == 6'd0 && !s_fin.pend)
                bz = 1'b0;
            if (cn.cnt != 3'd0) bz = 1'b1;
            f <= cn.f; p <= cn.p; busy <= bz; b14 <= c14; b0 <= c0;
            npush <= npush_s; npush_x <= do_exec && hd.pushpop;
            ntest <= ntest_s; ntest_x <= do_exec ? hd.ntest : 2'd0;
            st_a <= st_a + cn.cnt; st_aq <= st_a;

            // staging: accept a write when empty, free it when all are counted
            if (!act && w_fifo) begin
                st_n <= 3'd0; st_w <= 3'd0; st_a <= 3'd0; st_aq <= 3'd0;
                if (!w_pack) begin
                    act <= 1'b1; st_n <= 3'd1; st_cmd[0] <= {1'b0, wr_addr[8:2]};
                end else if (pk_nc == 3'd0 && w_zero) begin
                    // an all-zero word: one NOP entry, the word done
                    act <= 1'b1; st_n <= 3'd1; st_cmd[0] <= 8'h00;
                    pk_nc <= 3'd0; pk_cur <= 32'd0; pk_pc <= 6'd0; pk_tp <= 6'd0;
                end else if (w_none) begin
                    pk_nc <= 3'd4 - w_z; pk_cur <= w_cur; pk_pc <= 6'd0; pk_tp <= w_tp;
                end else begin
                    act <= 1'b1; st_n <= 3'd1; st_cmd[0] <= s_cur[7:0];
                    pk_cur <= i_cur; pk_nc <= i_nc; pk_tp <= i_tp; pk_pc <= i_pc;
                    // PRE: a new word's from gxpre, a parameter word's from pk_upb (both registered)
                    up <= PRE ? (pk_nc == 3'd0 ? wr_pre[20] : pk_upb) : !i_end;
                end
            end else if (up) begin
                st_cmd[st_n[1:0]] <= pk_cur[7:0]; st_n <= st_n + 3'd1;
                pk_cur <= i_cur; pk_nc <= i_nc; pk_tp <= i_tp; pk_pc <= i_pc;
                if (up_end) up <= 1'b0;
            end else if (st_done) act <= 1'b0;
            if (ram_we) begin
                st_w <= st_w + 3'd1; wr <= wr + 9'd1;
                ws_mmode <= wn_mmode; ws_pmode <= wn_pmode; ws_pattr <= wn_pattr; ws_cattr <= wn_cattr;
                ws_vnip <= wn_vnip; ws_ncons <= wn_ncons; ws_xpc <= wn_xpc;
            end

            // GXSTAT (0x600) and DISP_1DOT_DEPTH (0x610)
            if (wr_req && geom_en && wr_addr[9] && wr_addr[8:2] == 7'h00) begin
                if (wr_be[1] && wr_data[15]) begin
                    b15 <= 1'b0; jsp <= 1'b0; tsp <= 1'b0;
                end
                if (wr_be[3]) irqm <= wr_data[31:30];
            end
            if (wr_req && geom_en && wr_addr[9] && wr_addr[8:2] == 7'h04 && wr_be[1:0] == 2'b11)
                zdot <= {wr_data[14:0], 9'h1FF};
            if (vblank && geom_en) flush <= 1'b0;
        end
    end

    assign gxstat = {irqm, 2'b00, busy, f == 9'd0, f < 9'd128, f, b15, b14 || b14s, jsp, psp[4:0], 6'd0, 1'b0, b0 || b0s};
    assign irq = (irqm == 2'd1 && f < 9'd128) || (irqm == 2'd2 && f == 9'd0);
    assign dma_low = f < 9'd128;
    assign dg_full = f == 9'd256;
    assign dg_used = SPILL ? sp_used : {4'd0, used};
    assign dg_exec = do_exec;
    assign gx_stall = st_busy && st_a != st_n && (f == 9'd256 || (SPILL ? sp_full : used == 9'd511));
    assign test_exec = do_exec && hd.ntest != 2'd0;
endmodule

// The decode of a new packed command word (gpu3d_gxfront PRE): {up, none, i_tp, i_z, w_tp, w_zero, w_z} of its first
// step, as the front computes them, for a register beside the write's data
module gpu3d_gxpre (
    input  logic [31:0] d,
    output logic [20:0] pre
);
    function automatic [5:0] nparams(input [7:0] c);
        case (c)
            8'h10, 8'h12, 8'h13, 8'h14, 8'h20, 8'h21, 8'h22, 8'h24, 8'h25,
            8'h26, 8'h27, 8'h28, 8'h29, 8'h2A, 8'h2B, 8'h30, 8'h31, 8'h32, 8'h33,
            8'h40, 8'h50, 8'h60, 8'h72: nparams = 6'd1;
            8'h16, 8'h18: nparams = 6'd16;
            8'h17, 8'h19: nparams = 6'd12;
            8'h1A: nparams = 6'd9;
            8'h1B, 8'h1C, 8'h70: nparams = 6'd3;
            8'h23, 8'h71: nparams = 6'd2;
            8'h34: nparams = 6'd32;
            default: nparams = 6'd0;
        endcase
    endfunction
    // Every byte's parameter count and zero flag in parallel, then the
    // choices: z is the lowest non-zero byte (4: none), tp its count; iz the
    // zero bytes between it and the next non-zero one (none after it: up to
    // the top; 7 for a zero word, the serial form's wrap), itp that byte's
    // count (0: none). The same values as shifting the word by z and iz + 1
    // and decoding the low byte, without the shifts in the path (#500).
    always_comb begin
        logic [2:0] z, iz;
        logic [5:0] np [4];
        logic [3:0] nz;
        logic [5:0] tp, itp;
        logic [2:0] inc;
        logic       inx;
        for (int k = 0; k < 4; k++) begin
            np[k] = nparams(d[8 * k +: 8]);
            nz[k] = d[8 * k +: 8] != 8'h00;
        end
        if (nz[0]) begin
            z = 3'd0; tp = np[0];
            if (nz[1])      begin iz = 3'd0; itp = np[1]; end
            else if (nz[2]) begin iz = 3'd1; itp = np[2]; end
            else if (nz[3]) begin iz = 3'd2; itp = np[3]; end
            else            begin iz = 3'd3; itp = 6'd0; end
        end else if (nz[1]) begin
            z = 3'd1; tp = np[1];
            if (nz[2])      begin iz = 3'd0; itp = np[2]; end
            else if (nz[3]) begin iz = 3'd1; itp = np[3]; end
            else            begin iz = 3'd2; itp = 6'd0; end
        end else if (nz[2]) begin
            z = 3'd2; tp = np[2];
            if (nz[3])      begin iz = 3'd0; itp = np[3]; end
            else            begin iz = 3'd1; itp = 6'd0; end
        end else if (nz[3]) begin
            z = 3'd3; tp = np[3]; iz = 3'd0; itp = 6'd0;
        end else begin
            z = 3'd4; tp = 6'd0; iz = 3'd7; itp = 6'd0;
        end
        // the front's first step of the word (s_pc 0, s_tp tp, s_nc 4 - z): up = !i_end
        inx  = tp == 6'd0;
        inc  = inx ? 3'd4 - z - 3'd1 - iz : 3'd4 - z;
        pre  = {!(inc == 3'd0 || 6'd0 < (inx ? itp : tp)), d != 32'd0 && tp != 6'd0, itp, iz, tp, d == 32'd0, z};
    end
endmodule

