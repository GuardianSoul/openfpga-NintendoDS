// nds_disp lockstep (sim/ds/disp_eq.sh): Vold (the version at REF) and Vnew
// (the working tree), both tb_disp_eq_top, get the same inputs every clock;
// every output is compared every clock (and the state copy into gpu2d while
// st_we). The inputs that answer outputs (VRAM blocks, the 3D layer, OAM
// grants) are computed from Vold's outputs, so they stay identical as long
// as the outputs do.
// Stimulus: CPU accesses of every 2D register at least two clocks apart (the
// bus fabric's rule), with bursts at HBlank and while the line sequencer
// runs (Q_PRE / Q_LOAD / Q_POST); palette and OAM writes; CPU OAM reads;
// VRAM block answers with latency jitter; capture back-pressure; engine
// power changes; resets (no CPU access for 4,000 clocks after one: the CPUs
// stay in reset while nds_top's BIOS loader runs).
//   tb_disp_eq [--cycles N] [--seed S] [--jitter N] [--race P] [--rst N (one reset in N clocks)]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <string>
#include "Vold.h"
#include "Vnew.h"
#include "verilated.h"

typedef uint64_t u64;
typedef uint32_t u32;

static u64 rng_s = 1;
static u32 rnd() { rng_s ^= rng_s << 13; rng_s ^= rng_s >> 7; rng_s ^= rng_s << 17; return (u32)(rng_s >> 11); }
static u32 rn(u32 n) { return rnd() % n; }
static u64 mix(u64 x) { x ^= x >> 33; x *= 0xff51afd7ed558ccdull; x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53ull; x ^= x >> 33; return x; }

struct In {
    u32 rst = 1, vram_wr = 0, l3d_rdata = 0, io_req = 0, io_cpu = 0, io_we = 0, io_be = 0, io_addr = 0, io_wdata = 0;
    u32 powcnt1 = 0x0203, lcdc_ab = 0, vr_ack = 0, vr_rvalid = 0, cap_ready = 1, pal_we = 0, oam_we = 0;
    u32 po_waddr = 0, po_wdata = 0, po_be = 0, oam_cre = 0;
    u64 vr_rdata = 0;
};

template <class M> static void apply(M* m, const In& i)
{
    m->rst = i.rst; m->vram_wr = i.vram_wr; m->l3d_rdata = i.l3d_rdata;
    m->io_req = i.io_req; m->io_cpu = i.io_cpu; m->io_we = i.io_we; m->io_be = i.io_be; m->io_addr = i.io_addr;
    m->io_wdata = i.io_wdata; m->powcnt1 = i.powcnt1; m->lcdc_ab = i.lcdc_ab;
    m->vr_ack = i.vr_ack; m->vr_rvalid = i.vr_rvalid; m->vr_rdata = i.vr_rdata; m->cap_ready = i.cap_ready;
    m->pal_we = i.pal_we; m->oam_we = i.oam_we; m->po_waddr = i.po_waddr; m->po_wdata = i.po_wdata; m->po_be = i.po_be;
    m->oam_cre = i.oam_cre;
}

static u64 cyc = 0, errs = 0, ohash = 0;
static void omix(u64 v) { ohash = (ohash ^ v) * 0x100000001B3ull; ohash ^= ohash >> 29; }

#define CMP(name, cond) do { if ((cond) && (u64)a->name != (u64)b->name) { errs++; \
    if (errs <= 12) printf("cycle %llu: %s old %llx new %llx\n", (unsigned long long)cyc, #name, \
                           (unsigned long long)a->name, (unsigned long long)b->name); } } while (0)

static void compare(Vold* a, Vnew* b)
{
    CMP(l3d_go, 1); CMP(l3d_line, a->l3d_go); CMP(l3d_raddr, 1); CMP(io_rdata, 1); CMP(vcount, 1);
    CMP(line_start, 1); CMP(irq_vblank, 1); CMP(irq_hblank, 1); CMP(irq_vcount, 1);
    CMP(dma_vblank, 1); CMP(dma_hblank, 1); CMP(dma_dstart, 1); CMP(dma_dstop, 1); CMP(dma_mmstop, 1); CMP(frame_start, 1);
    CMP(vr_req, 1); CMP(vr_blk, a->vr_req); CMP(cap_we, 1); CMP(cap_addr, a->cap_we); CMP(cap_data, a->cap_we);
    CMP(pal_cq, 1); CMP(oam_cgnt, 1); CMP(oam_cq, 1);
    CMP(px_valid, 1); CMP(px_eng, a->px_valid); CMP(px_line, a->px_valid); CMP(px_x, a->px_valid); CMP(px_rgb, a->px_valid);
    CMP(stat_late, 1); CMP(hurry2d, 1); CMP(diag_d_ev, 1); CMP(diag_d_bgmax, 1); CMP(diag_v_start, 1); CMP(diag_v_stop, 1);
    CMP(diag_l2d_v, 1); CMP(diag_l2d_line, 1);
    CMP(st_we, 1); CMP(st_eng, a->st_we); CMP(st_addr, a->st_we); CMP(st_data, a->st_we);
    if (a->px_valid) omix(cyc << 26 | (u64)a->px_eng << 25 | (u64)a->px_line << 8 | a->px_x), omix(a->px_rgb);
    if (a->cap_we) omix(cyc << 26 | a->cap_addr), omix(a->cap_data);
    if (a->st_we) omix(cyc << 6 | a->st_eng << 5 | a->st_addr), omix(a->st_data);
    if (a->vr_req && a->vr_ack) omix(cyc << 20 | a->vr_blk);
    omix(a->irq_hblank | a->irq_vblank << 2 | a->stat_late << 4 | (u64)a->io_rdata << 8);
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    Verilated::fatalOnError(false);         // design checks ($error) are counted, not fatal
    u64 cycles = 3000000, seed = 1, rstp = 1000000;
    int jitter = 20, race = 30, lat = 13, dcyc = 16, maxq = 2;
    for (int i = 1; i < argc; i++) {
        std::string s = argv[i];
        if (s == "--cycles" && i + 1 < argc) cycles = strtoull(argv[++i], 0, 0);
        else if (s == "--seed" && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
        else if (s == "--jitter" && i + 1 < argc) jitter = atoi(argv[++i]);
        else if (s == "--race" && i + 1 < argc) race = atoi(argv[++i]);
        else if (s == "--rst" && i + 1 < argc) rstp = strtoull(argv[++i], 0, 0);
    }
    rng_s = mix(seed * 7919 + 1) | 1;
    Vold* a = new Vold;
    Vnew* b = new Vnew;
    In in;
    struct VReq { u32 blk; u64 beat[4]; int next; };
    std::deque<VReq> vq;
    u64 vend = 0, vver = 0;
    u64 rst_until = 6, quiet_until = 4006, next_io = 0, next_po = 0;
    u32 l3a = 0, l3line = 0;
    int burst = 0;
    // a CPU access: io_addr from the clock it is chosen, io_req (and we, cpu, be, wdata) the clock after,
    // as the bus fabric holds addr from S_GO's first clock (nds_disp's WH_RAM reads u_rb then)
    bool pend = false;
    u32 p_we = 0, p_cpu = 0, p_be = 0, p_wdata = 0;
    u64 n_chk = 0, n_wr = 0, n_rd = 0, n_pre = 0, n_px = 0, n_cap = 0, n_late = 0, n_rst = 0, n_st = 0;
    a->clk = 0; b->clk = 0;
    while (cyc < cycles) {
        // ---- inputs for this clock (before the outputs that answer)
        in.rst = cyc < rst_until;
        in.vram_wr = 0; in.io_req = 0; in.io_we = 0; in.pal_we = 0; in.oam_we = 0;
        if (pend && !in.rst) {
            in.io_req = 1; in.io_we = p_we; in.io_cpu = p_cpu; in.io_be = p_be; in.io_wdata = p_wdata;
        }
        pend = false;
        if (!in.rst && cyc >= quiet_until) {
            u32 q = a->q_state;
            bool seq = (q & 7) == 2 || (q & 7) == 3 || (q & 7) == 5;   // Q_PRE, Q_LOAD, Q_POST
            bool hot = burst > 0 || (seq && (int)rn(100) < race);
            if (cyc >= next_io && (hot || rn(24) == 0)) {
                if (burst > 0) burst--;
                pend = true;
                p_we = rn(100) < 88;
                p_cpu = rn(20) == 0;
                u32 w;
                switch (rn(8)) {
                case 0: w = rn(0x1C); break;
                case 1: w = 0x08 + rn(8); break;                       // affine parameters and references
                case 2: w = 0x04 + rn(4); break;                       // scroll
                case 3: w = 0x10 + rn(6); break;                       // windows, WINCNT, mosaic, blending
                case 4: { static const u32 ar[] = {0x00, 0x02, 0x03, 0x12, 0x14, 0x15, 0x1B}; w = ar[rn(7)]; break; }
                case 5: w = rn(2) ? 0x01 : 0x19; break;                 // DISPSTAT/VCOUNT, DISPCAPCNT
                default: w = rn(0x1C); break;
                }
                u32 e = rn(2);
                in.io_addr = e << 10 | w;
                static const u32 bes[] = {0xF, 0xF, 0xF, 0x3, 0xC, 0x1, 0x2, 0x4, 0x8, 0x3, 0xC};
                p_be = bes[rn(11)];
                u32 d = rnd() ^ rnd() << 7;
                if (w == 0x00 && rn(4)) d = (d & ~0x30000u) | 0x10000u;   // mostly display mode 1
                if (w == 0x00 && rn(2)) d &= ~0x80u;                      // mostly no forced blank
                if (w == 0x19 && rn(2)) d &= 0x7FFFFFFFu;                  // capture often
                p_wdata = d;
                if (p_we) n_wr++; else n_rd++;
                if (seq && (q & 8)) n_pre++;
                next_io = cyc + 2 + (rn(4) ? rn(3) : rn(60));
            }
            // palette / OAM: writes, or a CPU OAM read waiting for its grant
            if (in.oam_cre) {
                if (a->oam_cgnt) in.oam_cre = 0;
            } else if (cyc >= next_po) {
                u32 k = rn(10);
                if (k == 0) { in.oam_cre = 1; in.po_waddr = rn(512); }
                else {
                    in.pal_we = k < 5; in.oam_we = k >= 5;
                    in.po_waddr = rn(512); in.po_wdata = rnd() ^ rnd() << 9;
                    static const u32 pbes[] = {0xF, 0xF, 0x3, 0xC, 0x1, 0x8};
                    in.po_be = pbes[rn(6)];
                }
                next_po = cyc + 1 + rn(40);
            }
            if (rn(30000) == 0) { in.vram_wr = 1; vver++; }
            if (rn(500000) == 0) in.lcdc_ab = rn(16);
            if (rn(2000000) == 0) in.powcnt1 ^= rn(2) ? 0x0002 : 0x0200;
            if (rn(rstp) == 0) { rst_until = cyc + 1 + rn(4); quiet_until = rst_until + 4000; n_rst++; }
        }
        if (in.rst) { in.oam_cre = 0; }
        in.cap_ready = rn(10) != 0;
        a->clk = 0; b->clk = 0;
        apply(a, in); apply(b, in);
        a->eval(); b->eval();
        // ---- VRAM blocks (nds_vram's contract: in order, up to maxq)
        in.vr_ack = a->vr_req && (int)vq.size() < maxq;
        bool beat = !vq.empty() && vq.front().beat[vq.front().next] == cyc;
        in.vr_rvalid = beat;
        if (beat) in.vr_rdata = mix((u64)vq.front().blk << 2 | vq.front().next | vver << 24);
        apply(a, in); apply(b, in);
        a->eval(); b->eval();
        compare(a, b);
        if (Verilated::gotError() && !n_chk) { n_chk = cyc; printf("cycle %llu: a design check failed\n", (unsigned long long)cyc); }
        if (a->px_valid) n_px++;
        if (a->cap_we && in.cap_ready) n_cap++;
        if (a->stat_late) n_late++;
        if (a->st_we) n_st++;
        if (a->line_start) {
            // a burst of CPU writes right after this line's HBlank, now and then
            if ((int)rn(100) < race) burst = 2 + rn(12);
        }
        bool acc = a->vr_req && in.vr_ack;
        u32 blk = a->vr_blk;
        l3a = a->l3d_raddr; l3line = a->l3d_line;
        a->clk = 1; b->clk = 1;
        a->eval(); b->eval();
        cyc++;
        in.l3d_rdata = (u32)mix((u64)l3line << 8 | l3a);
        if (beat && ++vq.front().next == 4) vq.pop_front();
        if (in.rst) { vq.clear(); vend = 0; }
        else if (acc) {
            VReq r; r.blk = blk; r.next = 0;
            u64 st = cyc + lat + (jitter ? rn(jitter + 1) : 0);
            if (jitter && rn(16) == 0) st += 30 + rn(16);
            if (st < vend) st = vend;
            for (int k = 0; k < 4; k++) r.beat[k] = st + k * (dcyc / 4);
            vend = st + dcyc;
            vq.push_back(r);
        }
        if (errs > 50) break;
    }
    printf("disp_eq: %llu cycles, %llu CPU writes, %llu reads (%llu in a Q_PRE copy step), %llu state words, %llu pixels, "
           "%llu captures, %llu late lines, %llu resets; hash %016llx: %llu mismatches\n",
           (unsigned long long)cyc, (unsigned long long)n_wr, (unsigned long long)n_rd, (unsigned long long)n_pre,
           (unsigned long long)n_st, (unsigned long long)n_px, (unsigned long long)n_cap, (unsigned long long)n_late,
           (unsigned long long)n_rst, (unsigned long long)ohash, (unsigned long long)errs);
    if (n_chk) printf("(a design check failed at cycle %llu: an $error in a model, see above; not a mismatch)\n", (unsigned long long)n_chk);
    printf(errs ? "FAIL\n" : "PASS\n");
    a->final(); b->final();
    delete a; delete b;
    return errs ? 1 : 0;
}
