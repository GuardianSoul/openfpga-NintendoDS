// System simulation of rtl/ds/nds_top (docs/phase2-integration.md, "Tests").
// Models the external memories the Pocket shell provides (main RAM, VRAM,
// the boot images, the cartridge ROM behind the ROM cache) with
// configurable latencies, captures the 2D engine's pixels into frames
// (PPM), and writes per-CPU retired-instruction traces in the format of
// tools/ds-trace (68-byte records from the direct-boot entry point on) for
// comparison with melonDS.
//
//   tb_ds --rom F [--bios9 F --bios7 F --firmware F] [--frames N]
//         [--shots DIR --shot-every N] [--trace-dir DIR --trace-insns N]
//         [--mlat N] [--mwlat N] [--mlat8 N] [--mwlat8 N] [--vlat N] [--vwbusy N] [--vpipe] [--vpfirst N] [--vpgap N] [--vmlat F] [--jitter N] [--stall P L] [--jseed S] [--clat N] [--flat N] [--result] [--keys "f0 f1 KEY..."]
//         [--max-cycles N] [--quiet] [--sav F] [--sav-out F BYTES]
// --sav loads a .sav into the save memory (VRAM model 0x100000) as the
// Pocket shell does, with its size and size type (docs/saves.md);
// --sav-out writes the first BYTES of the save memory at the end.
// --vwatch A counts the writes to the VRAM model's word A (physical, e.g.
// 0x9C000 = bank H + 0x4000) per frame and the lines they land on: an HBlank
// DMA that rewrites one row per line should land on 192 lines (docs/compat.md).
#include <map>
#include <algorithm>
#include <random>
#ifndef CPU_FAST
#define CPU_FAST 0
#endif
#ifndef DS_CLK2X
#define DS_CLK2X 0
#endif
#include "Vnds_top.h"
#include "verilated.h"
#include "verilated_save.h"
#include "wifi_model.h"
#ifdef DS_FST
#include "verilated_fst_c.h"
#endif
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <unordered_map>
#include <string>
#include <vector>

typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;

static std::vector<u8> load(const std::string& p, size_t minsize = 0)
{
    std::vector<u8> v;
    FILE* f = fopen(p.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", p.c_str()); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    v.resize(std::max<size_t>(n, minsize));
    if (fread(v.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read %s\n", p.c_str()); exit(2); }
    fclose(f);
    return v;
}
static u32 rd32(const std::vector<u8>& m, u32 a) { u32 v; memcpy(&v, &m[a], 4); return v; }

// One external port: request held until ack; then `words` read words on rvalid.
struct Port
{
    int lat = 10;           // cycles from request to ack
    int state = 0, cnt = 0, k = 0, n = 0;
    u32 addr = 0;
    bool we = false;
};

int main(int argc, char** argv)
{
    std::string rom, bios9 = "roms/bios9.bin", bios7 = "roms/bios7.bin", fw = "roms/firmware.bin", bootrom = "sw/boot/bootrom.bin";
    std::string shots, tracedir, keyscript;
    int frames = 10, shot_every = 1;
    u64 trace_insns = 20000000, max_cycles = 0;
    int mlat = 20, vlat = 20, clat = 30, slat = 30, flat = 5;   // flat: SRAM word read (nds_sram)
    // VRAM writes as the Pocket's nds_sdram_xport takes them: acked the
    // clock after the request, then the port is busy for vwbusy clocks (the
    // crossing and the SDRAM write, ~5.3 clk_sys); vlat is for reads only
    int vwbusy = 5;
    // main RAM per request kind (each defaults to the one before it, so runs
    // without them are unchanged): --mwlat word writes, --mlat8 32-byte
    // block reads (n8), --mwlat8 block writes (before their 8 words). The
    // Pocket's PSRAM port (tb_port_blk, idle, request to the last word or the
    // ack): word write 12.3, 16-byte read 30.5, block read 48.7, block write
    // 54.3 clk_sys, i.e. --mlat 26 --mwlat 12 --mlat8 41 --mwlat8 46
    int mwlat = -1, mlat8 = -1, mwlat8 = -1;
    // latency jitter on the main-RAM, VRAM, boot-ROM and cart ports (not the
    // SRAM): each request waits a further 0..jitter clocks, and one in
    // stall_p a further stall_len (an SDRAM refresh or another client's
    // burst ahead of it). Off by default: no random numbers are drawn.
    int jitter = 0, stall_p = 0, stall_len = 0;
    // --vpipe: VRAM block reads as the Pocket's SDRAM path serves them
    // (measured, docs/phase2-integration.md "Pocket VRAM latency"): acked
    // the clock after the request, so nds_vram can put a second block in
    // flight; a block's 8 words start vpfirst clocks after its request, or
    // vpgap after the previous block's last word, one per clock. Off: one
    // block at a time, vlat then 8 words (more than twice the Pocket's cost
    // for back-to-back blocks). --vmlat F: the same latency histograms as
    // sim/pocket_ds's +vmlat, from frame F.
    bool vpipe = false;
    int vpfirst = 15, vpgap = 5, vmlat_from = -1;
    int rglat = 20;                      // --rglat N: the ring's block read latency
    // --vring N (with --vpipe): N more 32-byte blocks per 4,260-clock line on the
    // SDRAM path (a 3D line ring's writes + reads), taken whenever no block
    // read is queued; the blocks after them wait (budget-3d, "SDRAM ring")
    double vring = 0;
    unsigned jseed = 1;
    bool result = false, quiet = false;
    std::string sav_in, sav_out;
    bool wifi_on = false, wifi_log = false;   // --wifi: model the WiFi block (needs a WIFI=2 build)
    bool wifi_dirty = false;
    bool wifi_check = false;                  // --wifi-check: nds_wifi (WIFI=1) against the C++ model, read by read
    u32 sav_bytes = 0;
    unsigned long long sav_rd = 0, sav_wr = 0;      // save-port accesses (the cart's chip and its blank)
    int sav_first = -1;
    u64 dbg_retire = 0, fst_from = 0, fst_to = 0;
    u32 watch = 0;
    u32 vwatch = ~0u, vw_n = 0, vw_lines = 0, vw_lvc = ~0u;   // --vwatch
    bool iomon_all = false;     // --iomon-all: every 0x04xxxxxx write
    bool iomon = false;         // --iomon: display/VRAMCNT register writes with frame, line and clock in line
    bool force_load = false;    // --force-load: load a checkpoint from another tb_ds compile of the same model
    u64 line_cyc = 0;
    std::vector<u64> mark9;
    u64 dump_at = 0; std::string dump_file;
    u32 dump_pc = 0;        // --dump-mram-pc PC FILE: main RAM when the ARM9 first retires PC
    std::string fstname, wavname;
    // --save-at FRAME FILE / --load FILE: checkpoints (model + memories + bench
    // state) at a frame boundary; a checkpoint only loads into the same build
    int save_at = 0; std::string save_file, load_file;
    // --import-state DIR: start from a melonDS state (docs/state-import.md; DIR from census
    // --export-state and sim/ds/state_import.py); frames, shots and keys count from its release
    std::string import_dir;
    int trace_from = 0;     // --trace-from-frame F: start the traces at frame F (e.g. after --load) instead of the entry
    bool diag = false;      // --diag: count nds_disp's NDSDiag outputs and check them against the tb's own measures (docs/diag.md)
    int line_stats = -1;    // --line-stats FRAME: per DS line VRAM blocks/words, busy cycles and late lines of that frame
    for (int i = 1; i < argc; i++)
    {
        std::string a = argv[i];
        auto nx = [&]() { if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", a.c_str()); exit(2); } return std::string(argv[++i]); };
        if (a == "--rom") rom = nx();
        else if (a == "--bios9") bios9 = nx();
        else if (a == "--bootrom") bootrom = nx();     // nds_top BOOT_SRAM: the boot image port's sel 3
        else if (a == "--bios7") bios7 = nx();
        else if (a == "--firmware") fw = nx();
        else if (a == "--frames") frames = atoi(nx().c_str());
        else if (a == "--shots") shots = nx();
        else if (a == "--shot-every") shot_every = atoi(nx().c_str());
        else if (a == "--trace-dir") tracedir = nx();
        else if (a == "--trace-from-frame") trace_from = atoi(nx().c_str());
        else if (a == "--trace-insns") trace_insns = strtoull(nx().c_str(), 0, 0);
        else if (a == "--mlat") mlat = atoi(nx().c_str());
        else if (a == "--vlat") vlat = atoi(nx().c_str());
        else if (a == "--vwbusy") vwbusy = atoi(nx().c_str());
        else if (a == "--mwlat") mwlat = atoi(nx().c_str());
        else if (a == "--mlat8") mlat8 = atoi(nx().c_str());
        else if (a == "--mwlat8") mwlat8 = atoi(nx().c_str());
        else if (a == "--jitter") jitter = atoi(nx().c_str());
        else if (a == "--stall") { stall_p = atoi(nx().c_str()); stall_len = atoi(nx().c_str()); }
        else if (a == "--jseed") jseed = (unsigned)strtoul(nx().c_str(), nullptr, 0);
        else if (a == "--vpipe") vpipe = true;
        else if (a == "--vpfirst") vpfirst = atoi(nx().c_str());
        else if (a == "--vpgap") vpgap = atoi(nx().c_str());
        else if (a == "--rglat") rglat = atoi(nx().c_str());
        else if (a == "--vring") vring = atof(nx().c_str());
        else if (a == "--vmlat") vmlat_from = atoi(nx().c_str());
        else if (a == "--clat") clat = atoi(nx().c_str());
        else if (a == "--flat") flat = atoi(nx().c_str());
        else if (a == "--max-cycles") max_cycles = strtoull(nx().c_str(), 0, 0);
        else if (a == "--keys") keyscript = nx();
        else if (a == "--result") result = true;
        else if (a == "--quiet") quiet = true;
        else if (a == "--fst") fstname = nx();
        else if (a == "--wav") wavname = nx();
        else if (a == "--dump-mram") { dump_at = strtoull(nx().c_str(), 0, 0); dump_file = nx(); }
        else if (a == "--dump-mram-pc") { dump_pc = strtoul(nx().c_str(), 0, 0); dump_file = nx(); }
        else if (a == "--mark9") mark9.push_back(strtoull(nx().c_str(), 0, 0));
        else if (a == "--watch") watch = strtoul(nx().c_str(), 0, 0) & ~3u;
        else if (a == "--vwatch") vwatch = strtoul(nx().c_str(), 0, 0) & 0x1FFFFC;
        else if (a == "--iomon") iomon = true;
        else if (a == "--iomon-all") iomon = iomon_all = true;
        else if (a == "--force-load") force_load = true;
        else if (a == "--fst-from") fst_from = strtoull(nx().c_str(), 0, 0);
        else if (a == "--fst-to") fst_to = strtoull(nx().c_str(), 0, 0);
        else if (a == "--dbg-retire") dbg_retire = strtoull(nx().c_str(), 0, 0);
        else if (a == "--save-at") { save_at = atoi(nx().c_str()); save_file = nx(); }
        else if (a == "--load") load_file = nx();
        else if (a == "--import-state") import_dir = nx();
        else if (a == "--sav") sav_in = nx();
        else if (a == "--wifi") wifi_on = true;
        else if (a == "--wifi-log") { wifi_on = true; wifi_log = true; }
        else if (a == "--wifi-check") wifi_check = true;
        else if (a == "--wifi-dirty") wifi_dirty = true;   // WIFI=3: the SDRAM behind unwritten WiFi registers not 0, as on the Pocket
        else if (a == "--sav-out") { sav_out = nx(); sav_bytes = strtoul(nx().c_str(), 0, 0); }
        else if (a == "--line-stats") line_stats = atoi(nx().c_str());
        else if (a == "--diag") diag = true;
        else if (a[0] != '+') { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
    }
    if (rom.empty()) { fprintf(stderr, "--rom required\n"); return 2; }
    if (!import_dir.empty() && sav_in.empty())
    {
        FILE* f = fopen((import_dir + "/save.bin").c_str(), "rb");
        if (f) { fclose(f); sav_in = import_dir + "/save.bin"; }
    }
    Verilated::commandArgs(argc, argv);

    std::vector<u8> romd = load(rom);
    u32 romsize = romd.size();
    romd.resize((romsize + 15) & ~15u, 0xFF);
    std::vector<u8> b9 = load(bios9, 4096), b7 = load(bios7, 16384), fwd = load(fw, 512 * 1024), bt = load(bootrom, 8192);
    std::vector<u8> mram(8 << 20, 0), vram(2 << 20, 0), sram(256 << 10, 0);   // main RAM + the 3D polygon store
    if (wifi_dirty) for (u32 i = 0xF0000; i < 0xF4000; i++) vram[i] = (u8)(0xA5 ^ (i >> 3));
    u32 entry[2] = { rd32(romd, 0x24), rd32(romd, 0x34) };

    // the state import: external memories as the state has them, the restore stub
    // overlaid (its bytes kept for the release), then the stubs' ready flags and line
    struct Import { u32 ov = 0, ovn = 0, blk = 0, blkn = 0, ready9 = 0, ready7 = 0, vcount = 0, stubn = 0; int st = -1; u64 t0 = 0; };
    Import imp;
    std::vector<u8> imp_ov, imp_blk;
    if (!import_dir.empty())
    {
        auto get = [&](const char* n, size_t sz) { std::vector<u8> v = load(import_dir + "/" + n); v.resize(sz, 0); return v; };
        std::vector<u8> m = get("main.bin", 4 << 20);
        std::copy(m.begin(), m.end(), mram.begin());
        static const u32 voff[9] = {0x00000, 0x20000, 0x40000, 0x60000, 0x80000, 0x90000, 0x94000, 0x98000, 0xA0000};
        static const u32 vsz[9] = {0x20000, 0x20000, 0x20000, 0x20000, 0x10000, 0x4000, 0x4000, 0x8000, 0x4000};
        for (int i = 0; i < 9; i++)
        {
            std::string n = std::string("vram_") + char('a' + i) + ".bin";
            std::vector<u8> v = get(n.c_str(), vsz[i]);
            std::copy(v.begin(), v.end(), vram.begin() + voff[i]);
        }
        std::vector<u8> w7 = get("wram7.bin", 0x10000), sw = get("swram.bin", 0x8000);
        std::copy(w7.begin(), w7.end(), sram.begin());
        std::copy(sw.begin(), sw.end(), sram.begin() + 0x10000);
        FILE* f = fopen((import_dir + "/import.txt").c_str(), "r");
        if (!f) { fprintf(stderr, "%s/import.txt missing: run sim/ds/state_import.py\n", import_dir.c_str()); return 2; }
        char key[32]; u32 a, b;
        while (fscanf(f, "%31s %x", key, &a) == 2)
        {
            std::string k = key;
            if (k == "overlay" || k == "block") { if (fscanf(f, "%x", &b) != 1) break; (k == "overlay" ? imp.ov : imp.blk) = a; (k == "overlay" ? imp.ovn : imp.blkn) = b; }
            else if (k == "ready9") imp.ready9 = a;
            else if (k == "ready7") imp.ready7 = a;
            else if (k == "vcount") imp.vcount = a;
            else if (k == "stub") imp.stubn = a;     // the ARM9 returns from the stub's own code: its bytes go back once it has left them
        }
        fclose(f);
        std::vector<u8> ov = load(import_dir + "/overlay.bin"), blk = load(import_dir + "/block.bin");
        u32 o = imp.ov & 0x3FFFFF, k = imp.blk & 0x3FFFFF;
        imp_ov.assign(mram.begin() + o, mram.begin() + o + imp.ovn);
        imp_blk.assign(mram.begin() + k, mram.begin() + k + imp.blkn);
        std::copy(ov.begin(), ov.end(), mram.begin() + o);
        std::fill(mram.begin() + k, mram.begin() + k + imp.blkn, 0);
        std::copy(blk.begin(), blk.end(), mram.begin() + k);
        imp.st = 0;
        fprintf(stderr, "import %s: overlay %08x (%u bytes), release at line %u\n", import_dir.c_str(), imp.ov, imp.ovn, imp.vcount);
    }

    // key script: "first last KEY KEY ..." per entry, separated by ';';
    // "TOUCH x y" in an entry holds the pen at screen pixel (x, y)
    struct KeyEv { int f0, f1; u32 mask; int tx, ty; };
    std::vector<KeyEv> kev;
    {
        const char* names[12] = {"A", "B", "SELECT", "START", "RIGHT", "LEFT", "UP", "DOWN", "R", "L", "X", "Y"};
        size_t p = 0;
        while (p < keyscript.size())
        {
            size_t e = keyscript.find(';', p);
            std::string s = keyscript.substr(p, e == std::string::npos ? std::string::npos : e - p);
            p = e == std::string::npos ? keyscript.size() : e + 1;
            KeyEv k{0, 0, 0, -1, -1};
            char buf[32]; int off = 0, used;
            if (sscanf(s.c_str(), "%d %d%n", &k.f0, &k.f1, &used) < 2) continue;
            off = used;
            while (sscanf(s.c_str() + off, "%31s%n", buf, &used) == 1)
            {
                off += used;
                if (!strcmp(buf, "TOUCH") && sscanf(s.c_str() + off, "%d %d%n", &k.tx, &k.ty, &used) == 2) { off += used; continue; }
                for (int b = 0; b < 12; b++) if (!strcmp(buf, names[b])) k.mask |= 1u << b;
            }
            kev.push_back(k);
        }
    }

    Vnds_top* t = new Vnds_top;
    t->clk = 0; t->rst = 1; t->go = 0; t->rom_size = romsize;
    t->mem_dirty = 0;       // the memory models start zeroed, as melonDS's
    t->sv_loaded = 0; t->save_info = 0;
    if (!sav_in.empty())
    {
        std::vector<u8> sv = load(sav_in);
        u32 n = sv.size() > (1u << 20) ? 1u << 20 : sv.size();
        std::copy(sv.begin(), sv.begin() + n, vram.begin() + 0x100000);
        t->sv_loaded = n;
        const u32 sizes[8] = {0, 512, 8192, 65536, 131072, 262144, 524288, 1048576};
        for (u32 k = 1; k < 8; k++) if (sv.size() == sizes[k]) t->save_info = 0x08 | k;
    }
    t->keys = 0; t->pen = 0; t->pen_x = 0; t->pen_y = 0;
    t->rtc_valid = 1; t->rtc_date = 0x20261023; t->rtc_time = 0x00120000;
    t->eval();
#ifdef DS_FST
    VerilatedFstC* fst = nullptr;
    if (!fstname.empty()) { Verilated::traceEverOn(true); fst = new VerilatedFstC; t->trace(fst, 99); fst->open(fstname.c_str()); }
#endif

    FILE* trf[2] = {nullptr, nullptr};
    if (!tracedir.empty())
    {
        std::string c = "mkdir -p " + tracedir; if (system(c.c_str())) {}
        trf[0] = fopen((tracedir + "/arm9.trc").c_str(), "wb");
        trf[1] = fopen((tracedir + "/arm7.trc").c_str(), "wb");
    }
    if (!shots.empty()) { std::string c = "mkdir -p " + shots; if (system(c.c_str())) {} }

    u32 shadow[2][32] = {};
    bool tracing[2] = {false, false};
    u64 traced[2] = {0, 0}, retired[2] = {0, 0}, traced9 = 0;
    u32 lastpc[2] = {0, 0};
    u64 lastret_cyc[2] = {0, 0};
    bool stall_rep[2] = {false, false};
    auto phys = [](int r, u32 mode) -> int {
        mode &= 0x1F;
        if (r >= 8 && r <= 14 && mode == 0x11) return 16 + r - 8;
        if (r == 13 || r == 14)
        {
            switch (mode)
            {
            case 0x12: return r == 13 ? 23 : 24;
            case 0x13: return r == 13 ? 25 : 26;
            case 0x17: return r == 13 ? 27 : 28;
            case 0x1B: return r == 13 ? 29 : 30;
            }
        }
        return r;
    };

    std::vector<int16_t> wav;
    bool aud_prev = false;
    static u32 fb[2][192][256];
    memset(fb, 0, sizeof(fb));
    int frame = 0, shot_n = 0;
    u32 last_vc = 0;
    u64 cyc = 0, late = 0;
    Port pm, pv, ps, pc, pf;
    std::mt19937 jrng(jseed);
    struct VBlk { u32 addr; u64 start, req, ack; };
    std::deque<VBlk> vq;                 // --vpipe: block reads in flight
    int vk = 0;                          // words of vq.front() delivered
    u64 vlast = 0;                       // the last block word's cycle
    bool vack = false;                   // a block read's ack, next clock
    std::unordered_map<u32, u32> rgmem;  // the 3D line ring's SDRAM
    int rg_st = 0, rg_cnt = 0, rg_k = 0; u32 rg_a = 0;
    double vr_cred = 0;                  // --vring: blocks due
    u64 vr_n = 0;
    u64 vh_ack[256] = {}, vh_tail[256] = {}, vh_tot[256] = {}, vh_n = 0;
    auto jit = [&]() -> int {
        int e = 0;
        if (jitter > 0) e += (int)(jrng() % (unsigned)(jitter + 1));
        if (stall_p > 0 && jrng() % (unsigned)stall_p == 0) e += stall_len;
        return e;
    };
    pm.lat = mlat; pv.lat = vlat; ps.lat = slat; pc.lat = clat; pf.lat = flat;

    // everything that carries state from one cycle to the next
    static const char stamp[] = "tb_ds " __DATE__ " " __TIME__;
    if (!load_file.empty())
    {
        VerilatedRestore is;
        is.open(load_file.c_str());
        is >> *t;
        char st[sizeof stamp]; u32 rs;
        is.read(st, sizeof st); is.read(&rs, sizeof rs);
        if ((!force_load && memcmp(st, stamp, sizeof st)) || rs != romsize) { fprintf(stderr, "%s: another build or ROM\n", load_file.c_str()); return 2; }
        is.read(mram.data(), mram.size()); is.read(vram.data(), vram.size()); is.read(sram.data(), sram.size());
        is.read(&pm, sizeof pm); is.read(&pv, sizeof pv); is.read(&ps, sizeof ps); is.read(&pc, sizeof pc); is.read(&pf, sizeof pf);
        is.read(&cyc, sizeof cyc); is.read(&frame, sizeof frame); is.read(&last_vc, sizeof last_vc); is.read(&late, sizeof late);
        is.read(retired, sizeof retired); is.read(lastpc, sizeof lastpc); is.read(lastret_cyc, sizeof lastret_cyc);
        is.read(shadow, sizeof shadow); is.read(fb, sizeof fb);
        is.close();
        pm.lat = mlat; pv.lat = vlat; ps.lat = slat; pc.lat = clat; pf.lat = flat;   // latencies from this run's options
        fprintf(stderr, "loaded %s: frame %d, cycle %llu\n", load_file.c_str(), frame, (unsigned long long)cyc);
    }
    auto write_shot = [&](int n) {
        char name[512];
        snprintf(name, sizeof name, "%s/f%06d.ppm", shots.c_str(), n);
        FILE* f = fopen(name, "wb");
        if (!f) return;
        fprintf(f, "P6\n256 384\n255\n");
        int top = (t->powcnt1 >> 15) & 1 ? 0 : 1;
        for (int s = 0; s < 2; s++)
            for (int y = 0; y < 192; y++)
                for (int x = 0; x < 256; x++)
                {
                    u32 c = fb[s == 0 ? top : 1 - top][y][x];
                    u8 px[3] = { (u8)((c & 63) << 2 | (c & 63) >> 4), (u8)(((c >> 6) & 63) << 2 | ((c >> 6) & 63) >> 4),
                                 (u8)(((c >> 12) & 63) << 2 | ((c >> 12) & 63) >> 4) };
                    fwrite(px, 1, 3, f);
                }
        fclose(f);
    };

    WifiModel wifi;
    wifi.reset(fwd.size() > 0x1D ? fwd[0x1D] : 0xFF);
    wifi.log = wifi_log;
    bool wx_pend = false;
    unsigned long long wifi_mism[2] = {0, 0}, wifi_reads = 0;
    std::map<u32, unsigned long long> wifi_hist;  // --wifi-check: reads per register (pa & 0x7FFE)
    u32 wx_data = 0;
    unsigned long long wx_n = 0;
    // the CPUs' trace outputs, once per CPU clock edge (clk_cpu with CPU_FAST)
    auto observe_dbg = [&]()
    {
        if (t->dbg_wen) shadow[t->dbg_wa >> 5][t->dbg_wa & 31] = t->dbg_wd;
            if (t->dbg_retire)
            {
                int c = t->dbg_tid;
                retired[c]++;
                lastpc[c] = t->dbg_pc;
                // the import: the stub's own bytes (the ARM9's return path) once the ARM9 has left them
                if (c == 0 && imp.st >= 2 && imp.stubn && (t->dbg_pc - imp.ov) >= imp.stubn)
                {
                    std::copy(imp_ov.begin(), imp_ov.begin() + imp.stubn, mram.begin() + (imp.ov & 0x3FFFFF));
                    imp.stubn = 0;
                }
                if (dump_pc && c == 0 && t->dbg_pc == dump_pc)
                {
                    FILE* f = fopen(dump_file.c_str(), "wb"); fwrite(mram.data(), 1, 4 << 20, f); fclose(f);
                    fprintf(stderr, "main RAM dumped at ARM9 pc %08x, cycle %llu\n", dump_pc, (unsigned long long)cyc);
                    dump_pc = 0;
                }
                lastret_cyc[c] = cyc; stall_rep[c] = false;
                if (retired[c] <= dbg_retire)
                    fprintf(stderr, "%llu ARM%d %08x cpsr %08x r0 %08x r1 %08x r2 %08x r3 %08x\n", (unsigned long long)cyc, c ? 7 : 9,
                            t->dbg_pc, t->dbg_cpsr, shadow[c][0], shadow[c][1], shadow[c][2], shadow[c][3]);
                if (!tracing[c] && (trace_from > 0 ? frame >= trace_from : t->dbg_pc == entry[c])) tracing[c] = true;
                if (tracing[c] && c == 0)
                    for (u64 m : mark9) if (traced9 == m) fprintf(stderr, "mark9 %llu at cycle %llu pc %08x\n", (unsigned long long)m, (unsigned long long)cyc, t->dbg_pc);
                if (tracing[c] && c == 0) traced9++;
                if (tracing[c] && trf[c] && traced[c] < trace_insns)
                {
                    u32 rec[17];
                    rec[0] = t->dbg_pc; rec[1] = t->dbg_cpsr;
                    for (int r = 0; r < 15; r++) rec[2 + r] = shadow[c][phys(r, t->dbg_cpsr)];
                    fwrite(rec, 4, 17, trf[c]);
                    traced[c]++;
                }
            }
    };
    for (;;)
    {
        // ---- inputs for the next edge (outputs are those after the last edge)
        // the WiFi block (WIFI_EXT builds): one access per request, answered the cycle after
        t->wx_ack = 0; t->wx_irq = 0;
        if (wifi_on)
        {
            if (wx_pend) { t->wx_ack = 1; t->wx_rdata = wx_data; wx_pend = false; }
            else if (t->wx_req)
            {
                u32 a = 0x04000000 | ((u32)t->wx_addr << 2);
                wx_data = wifi.access(t->wx_we, a, t->wx_be, t->wx_wdata);
                if (wifi_log && wx_n < 20000)
                    printf("wx %llu: %s %08x be %x %08x\n", (unsigned long long)cyc, t->wx_we ? "W" : "R", a, (unsigned)t->wx_be,
                           t->wx_we ? (unsigned)t->wx_wdata : wx_data);
                wx_n++;
                wx_pend = true;
            }
            if (t->wx_power != wifi.enabled) { wifi.enabled = t->wx_power; wifi.update_power_on(); }
            t->wx_irq = wifi.clock(33513982.0 * 2);
        }
        if (wifi_check)
        {
            // the model sees each access as nds_wifi does; reads compared at nds_wifi's answer
            static bool pend = false, pwe = false; static u32 pa = 0, pexp = 0; static u8 pbe = 0;
            if (t->wx_req)
            {
                u32 a = 0x04000000 | ((u32)t->wx_addr << 2);
                pa = a; pwe = t->wx_we; pbe = t->wx_be;
                pexp = wifi.access(t->wx_we, a, t->wx_be, t->wx_wdata);
                pend = true;
            }
            if (pend && t->wx_rtl_ack)
            {
                pend = false;
                u32 got = t->wx_rtl_rdata;
                if (!pwe && got != pexp)
                {
                    u32 r = pa & 0x7FFE;
                    bool timing = (r >= 0xF0 && r <= 0xFE) || r == 0x10 || r == 0x118 || r == 0x11C || r == 0x134 ||
                                  r == 0x10C || r == 0x088 || r == 0x0B0 || r == 0x03C || r == 0x034 || r == 0x214 || r == 0x19C;
                    wifi_mism[timing]++;
                    if (wifi_mism[timing] <= 20)
                        printf("wifi-check %llu: %s R %08x be %x rtl %08x model %08x\n", (unsigned long long)cyc,
                               timing ? "(timing)" : "MISMATCH", pa, (unsigned)pbe, got, pexp);
                }
                wifi_reads += !pwe;
                if (!pwe) wifi_hist[pa & 0x7FFE]++;
            }
            if (t->wx_power != wifi.enabled) { wifi.enabled = t->wx_power; wifi.update_power_on(); }
            wifi.clock(33513982.0 * 2);
        }
        if (cyc == 20) t->rst = 0;
        if (cyc == 40) t->go = 1;
        u32 keys = 0;
        t->pen = 0;
        if (imp.st < 0 || imp.st == 3)
            for (auto& k : kev) if (frame >= k.f0 && frame <= k.f1) {
                keys |= k.mask;
                if (k.tx >= 0) { t->pen = 1; t->pen_x = k.tx; t->pen_y = k.ty; }
            }
        if (imp.st == 2) keys = 0x3FF;      // the import's release: KEYINPUT 0 (sw/boot/import.s)
        t->keys = keys;

        // main RAM
        t->mr_ack = 0; t->mr_rvalid = 0; t->mr_wnext = 0;
        if (pm.state == 0 && t->mr_req)
        {
            {
                int lw = mwlat >= 0 ? mwlat : pm.lat, l8 = mlat8 >= 0 ? mlat8 : pm.lat, lw8 = mwlat8 >= 0 ? mwlat8 : lw;
                pm.cnt = (t->mr_we ? (t->mr_n8 ? lw8 : lw) : (t->mr_n8 ? l8 : pm.lat)) + jit();
            }
            pm.state = 1; pm.addr = t->mr_addr << 2; pm.we = t->mr_we;
            pm.n = t->mr_n8 ? 8 : 4;   // a 32-byte block (nds_fabric MR_BLOCK) or the 16 bytes of a word access
        }
        else if (pm.state == 1 && --pm.cnt <= 0 && pm.n == 8 && pm.we) { pm.state = 3; pm.k = 0; }
        else if (pm.state == 3)
        {
            // a block write: one word per cycle on mr_wnext, the ack with the eighth
            u32 a = (pm.addr & 0x7FFFE0) + pm.k * 4, d = t->mr_wdata;
            t->mr_wnext = 1;
            for (int b = 0; b < 4; b++) mram[a + b] = d >> (8 * b);
            if (++pm.k == 8) { t->mr_ack = 1; pm.state = 0; }
        }
        else if (pm.state == 1 && pm.cnt <= 0)
        {
            t->mr_ack = 1;
            if (pm.we)
            {
                u32 d = t->mr_wdata, a = pm.addr & 0x7FFFFC;
                for (int b = 0; b < 4; b++) if (t->mr_be >> b & 1) mram[a + b] = d >> (8 * b);
                if (watch && ((watch ^ a) & 0x3FFFE0) == 0)
                    fprintf(stderr, "%llu watch: main RAM %06x <= %08x be %x -> %08x\n", (unsigned long long)cyc, a, d,
                            (unsigned)t->mr_be, rd32(mram, a));
                pm.state = 0;
            }
            else { pm.state = 2; pm.k = 0; }
        }
        else if (pm.state == 2)
        {
            t->mr_rvalid = 1; t->mr_rdata = rd32(mram, (pm.addr & (pm.n == 8 ? 0x7FFFE0 : 0x7FFFF0)) + pm.k * 4);
            if (++pm.k == pm.n) pm.state = 0;
        }
        else if (pm.state == 0) {}

        // VRAM
        // the 3D line ring's SDRAM ports (nds_top rg_*, G3D_RING): writes take
        // a word a clock (one in four held a clock), a block read is acked
        // after --rglat clocks and returns 8 words a clock, after the writes
        // before it (no write left in flight when a read is acked)
        t->rg_wack = 0; t->rg_rack = 0; t->rg_rvalid = 0;
        t->rg_wdrained = 1;               // (its writes land at once)
        if (t->rg_wreq && (jrng() & 3) != 0) { rgmem[t->rg_waddr & 0xFFFFFF] = t->rg_wdata; t->rg_wack = 1; }
        if (rg_st == 0 && t->rg_rreq) { rg_st = 1; rg_cnt = rglat; rg_a = t->rg_raddr & 0xFFFFFF; }
        else if (rg_st == 1 && --rg_cnt <= 0) { t->rg_rack = 1; rg_st = 2; rg_k = 0; rg_cnt = 6; }
        else if (rg_st == 2 && --rg_cnt <= 0) {
            t->rg_rvalid = 1; auto it = rgmem.find(rg_a + rg_k); t->rg_rdata = it == rgmem.end() ? 0xDEADBEEF : it->second;
            if (++rg_k == 8) rg_st = 0;
        }
        t->vm_ack = 0; t->vm_rvalid = 0;
        if (vpipe)
        {
            vr_cred += vring / 4260.0;
            if (vr_cred >= 1.0 && vq.empty() && !vack && vlast < cyc)
            {
                vr_cred -= 1.0; vr_n++;
                vlast = cyc + 8 + vpgap;         // the bus carries a ring block
            }
            if (vack) { t->vm_ack = 1; vack = false; vq.back().ack = cyc; }
            else if (pv.state == 0 && t->vm_req && t->vm_blk && !t->vm_we)
            {
                u64 st = std::max<u64>(cyc + vpfirst + jit(), vq.empty() && vlast + vpgap < cyc ? 0 : vlast + vpgap);
                vq.push_back({(t->vm_addr << 2) & 0x1FFFE0, st, cyc, 0});
                vlast = st + 7;
                vack = true;
            }
            if (!vq.empty() && cyc >= vq.front().start && (vk != 0 || vq.front().ack != 0))
            {
                VBlk &b = vq.front();
                t->vm_rvalid = 1; t->vm_rdata = rd32(vram, b.addr + vk * 4);
                if (++vk == 8)
                {
                    if (vmlat_from >= 0 && frame >= vmlat_from)
                    {
                        vh_ack[std::min<u64>(b.ack - b.req, 255)]++; vh_tail[std::min<u64>(cyc - b.ack, 255)]++;
                        vh_tot[std::min<u64>(cyc - b.req, 255)]++; vh_n++;
                    }
                    vq.pop_front(); vk = 0;
                }
            }
        }
        // (with --vpipe, a single read or write starts only with no block in flight)
        if (pv.state == 0 && t->vm_req && !(vpipe && (!vq.empty() || vack || (t->vm_blk && !t->vm_we))))
        {
            pv.state = 1; pv.cnt = t->vm_we ? 1 : pv.lat + jit(); pv.addr = t->vm_addr << 2; pv.we = t->vm_we; pv.n = t->vm_blk ? 8 : 1;
            if (pv.addr >= 0x100000 && pv.addr < 0x200000)
            {
                (pv.we ? sav_wr : sav_rd)++;
                if (sav_first < 0) sav_first = frame;
            }
        }
        else if (pv.state == 1 && --pv.cnt <= 0)
        {
            t->vm_ack = 1;
            if (pv.we)
            {
                u32 d = t->vm_wdata, a = pv.addr & 0x1FFFFC;
                for (int b = 0; b < 4; b++) if (t->vm_be >> b & 1) vram[a + b] = d >> (8 * b);
                if (a == vwatch) { vw_n++; if (t->vcount != vw_lvc) { vw_lines++; vw_lvc = t->vcount; } }
                { int b = vwbusy + jit(); pv.state = b > 0 ? 3 : 0; pv.cnt = b; }
            }
            else { pv.state = 2; pv.k = 0; }
        }
        else if (pv.state == 3) { if (--pv.cnt <= 0) pv.state = 0; }
        else if (pv.state == 2)
        {
            u32 base = pv.n == 8 ? (pv.addr & 0x1FFFE0) : (pv.addr & 0x1FFFFC);
            t->vm_rvalid = 1; t->vm_rdata = rd32(vram, base + pv.k * 4);
            if (++pv.k == pv.n) pv.state = 0;
        }

        // the SRAM (nds_sram): a read word takes flat clocks, a write 3 per
        // 16-bit half it writes; done drops the request the cycle after
        t->fr_done = 0;
        if (pf.state == 0 && t->fr_req)
        {
            pf.state = 1; pf.we = t->fr_we; pf.addr = (t->fr_addr << 2) & 0x3FFFC;
            pf.cnt = pf.we ? 3 * (((t->fr_be & 3) != 0) + ((t->fr_be & 12) != 0)) : pf.lat;
        }
        else if (pf.state == 1 && --pf.cnt <= 0)
        {
            t->fr_done = 1;
            if (pf.we) { u32 d = t->fr_wdata; for (int b = 0; b < 4; b++) if (t->fr_be >> b & 1) sram[pf.addr + b] = d >> (8 * b); }
            else t->fr_rdata = rd32(sram, pf.addr);
            pf.state = 3;
        }
        else if (pf.state == 3) pf.state = 0;

        // boot images
        t->sr_ack = 0;
        if (ps.state == 0 && t->sr_req) { ps.state = 1; ps.cnt = ps.lat + jit(); }
        else if (ps.state == 1 && --ps.cnt <= 0)
        {
            u32 a = (t->sr_addr << 2), sel = t->sr_sel;
            const std::vector<u8>& img = sel == 0 ? b9 : sel == 1 ? b7 : sel == 3 ? bt : fwd;
            t->sr_ack = 1; t->sr_rdata = a + 4 <= img.size() ? rd32(img, a) : 0xFFFFFFFF;
            ps.state = 3;
        }
        else if (ps.state == 3) ps.state = 0;     // the request drops after ack

        // cartridge ROM (the ROM cache's client port)
        t->cr_ack = 0; t->cr_rvalid = 0;
        if (pc.state == 0 && t->cr_req) { pc.state = 1; pc.cnt = pc.lat + jit(); pc.addr = t->cr_addr << 4; }
        else if (pc.state == 1 && --pc.cnt <= 0) { t->cr_ack = 1; pc.state = 2; pc.k = 0; }
        else if (pc.state == 2)
        {
            u32 a = pc.addr + pc.k * 4;
            t->cr_rvalid = 1; t->cr_rdata = a + 4 <= romd.size() ? rd32(romd, a) : 0xFFFFFFFF;
            if (++pc.k == 4) pc.state = 0;
        }

        // ---- edge
#if CPU_FAST
        // clk_cpu = 4/3 clk_sys: in 24 ticks per clk_sys cycle, clk_sys rises
        // at 0 and falls at 12; clk_cpu (period 18) rises at 18k + 5 and falls
        // 9 later. Edges in time order; the CPUs' outputs after each of
        // their rising edges.
        {
            u64 t0 = cyc * 24;
            struct Ev { u64 at; int which; int v; };
            Ev ev[8]; int n = 0;
            ev[n++] = {t0, 0, 1}; ev[n++] = {t0 + 12, 0, 0};
            for (u64 k = (t0 >= 5 ? (t0 - 5) / 18 : 0); 18 * k + 5 < t0 + 24; k++)
            {
                u64 r = 18 * k + 5;
                if (r >= t0) ev[n++] = {r, 1, 1};
                if (r + 9 >= t0 && r + 9 < t0 + 24) ev[n++] = {r + 9, 1, 0};
            }
            std::sort(ev, ev + n, [](const Ev& a, const Ev& b) { return a.at < b.at; });
            for (int i = 0; i < n; i++)
            {
                if (ev[i].which == 0) t->clk = ev[i].v; else t->clk_cpu = ev[i].v;
                t->eval();
#ifdef DS_FST
                if (fst && cyc >= fst_from && cyc < fst_to) fst->dump(ev[i].at);
#endif
                if (ev[i].which == 1 && ev[i].v == 1) observe_dbg();
            }
#ifdef DS_FST
            if (fst && cyc + 1 == fst_to) fst->close();
#endif
        }
#else
#if DS_CLK2X
        // clk_2x (DS_CLK2X=1): two periods per clk_sys period, rising with it
        t->clk = 1; t->clk_2x = 1; t->eval(); t->clk_2x = 0; t->eval();
#else
        t->clk = 1; t->eval();
#endif
#ifdef DS_FST
        if (fst && cyc >= fst_from && cyc < fst_to) fst->dump(cyc * 2);
#endif
#if DS_CLK2X
        t->clk = 0; t->clk_2x = 1; t->eval(); t->clk_2x = 0; t->eval();
#else
        t->clk = 0; t->eval();
#endif
#ifdef DS_FST
        if (fst && cyc >= fst_from && cyc < fst_to) fst->dump(cyc * 2 + 1);
        if (fst && cyc == fst_to) fst->close();
#endif
#endif
        cyc++;

        // ---- observe
        if (t->px_valid) fb[t->px_eng][t->px_line % 192][t->px_x] = t->px_rgb;
        // out_valid lasts one clock-enable period (two clk_sys cycles): one sample per rising edge
        if (t->aud_valid && !aud_prev && !wavname.empty()) { wav.push_back((int16_t)t->aud_l); wav.push_back((int16_t)t->aud_r); }
        aud_prev = t->aud_valid;
        if (t->stat_late) late++;
        if (diag)
        {
            static u64 ev[5], vstart, vstop, l2d, bad; static u32 bgmax_seen = 0;
            for (int b = 0; b < 5; b++) if ((t->diag_d_ev >> b) & 1) ev[b]++;
            if (t->diag_v_start) vstart++;
            if (t->diag_v_stop) vstop++;
            if (t->diag_l2d_v) { l2d++; if (t->diag_l2d_line > 262) bad++; }
            if (((t->diag_d_ev & 1) != 0) != (t->stat_late != 0) || (t->diag_l2d_v != 0) != (t->stat_late != 0)) bad++;
            if (vstop > vstart || vstart > vstop + 2) bad++;         // at most 2 blocks in flight, answered in order
            if (t->diag_d_bgmax > bgmax_seen) bgmax_seen = t->diag_d_bgmax;
            if (t->line_start && t->vcount == 0 && frame >= 1)
                fprintf(stderr, "diag f%d: late %llu (tb %llu), bg stall %llu, obj stall %llu, blocks %llu/%llu, capture lines %llu, bgmax %u, errors %llu%s\n",
                        frame, (unsigned long long)ev[0], (unsigned long long)late, (unsigned long long)ev[1], (unsigned long long)ev[2],
                        (unsigned long long)vstart, (unsigned long long)vstop, (unsigned long long)ev[4], (unsigned)t->diag_d_bgmax,
                        (unsigned long long)bad, bad ? "  ERROR" : "");
        }
        if (frame == line_stats)
        {
            static u32 lb = 0, lw = 0, lbusy = 0, lvc = 999; static bool llate = false;
            u32 v = t->vcount;
            if (v != lvc)
            {
                if (lvc < 263 && (lb || llate)) fprintf(stderr, "line %3u: %3u blocks %3u words, VRAM busy %5u cycles%s\n", lvc, lb, lw, lbusy, llate ? "  LATE" : "");
                lb = lw = lbusy = 0; llate = false; lvc = v;
            }
            if (t->vm_req && pv.state == 0) { if (t->vm_blk) lb++; else lw++; }
            if (pv.state != 0) lbusy++;
            if (t->stat_late) llate = true;
        }
        if (dump_at && cyc == dump_at) { FILE* f = fopen(dump_file.c_str(), "wb"); fwrite(mram.data(), 1, 4 << 20, f); fclose(f); }
        if (iomon && t->mon_we && ((t->mon_addr & 0xFFFFEF80) == 0x04000000 || (t->mon_addr & 0xFFFFFFF0) == 0x04000240 || (iomon_all && (t->mon_addr >> 24) == 4)))
            fprintf(stderr, "io f%d vc %u clk %llu: m%u c%u %08x <= %08x be %x\n", frame, (unsigned)t->vcount,
                    (unsigned long long)(cyc - line_cyc), (unsigned)t->mon_master, (unsigned)t->mon_cpu, t->mon_addr,
                    t->mon_wdata, (unsigned)t->mon_be);
        if (watch && t->mon_we && (t->mon_addr >> 24) == 2 && ((t->mon_addr ^ watch) & 0x3FFFE0) == 0)
            fprintf(stderr, "%llu watch: fabric write master %u cpu %u %08x <= %08x be %x\n", (unsigned long long)cyc,
                    (unsigned)t->mon_master, (unsigned)t->mon_cpu, t->mon_addr, t->mon_wdata, (unsigned)t->mon_be);
#if !CPU_FAST
        observe_dbg();
#endif
        for (int c = 0; c < 2; c++)
            if (t->running && !stall_rep[c] && lastret_cyc[c] && cyc - lastret_cyc[c] > 200000)
            {
                fprintf(stderr, "ARM%d: no instruction retired since cycle %llu (pc %08x)\n", c ? 7 : 9,
                        (unsigned long long)lastret_cyc[c], lastpc[c]);
                stall_rep[c] = true;
            }
        u32 vc = t->vcount;
        // the state import: both stubs done (their ready words), then the state's line
        if (imp.st == 0 && rd32(mram, imp.ready9 & 0x3FFFFF) == 1 && rd32(mram, imp.ready7 & 0x3FFFFF) == 1)
        {
            imp.st = 1; imp.t0 = cyc;
            fprintf(stderr, "import: stubs done at cycle %llu (line %u)\n", (unsigned long long)cyc, vc);
        }
        else if (imp.st == 1 && cyc > imp.t0 + 4000 && vc == imp.vcount && last_vc != vc)
        {
            u32 o = imp.ov & 0x3FFFFF, k = imp.blk & 0x3FFFFF;
            std::copy(imp_ov.begin() + imp.stubn, imp_ov.end(), mram.begin() + o + imp.stubn);
            std::copy(imp_blk.begin(), imp_blk.end(), mram.begin() + k);
            imp.st = 2; imp.t0 = cyc;
        }
        else if (imp.st == 2 && cyc > imp.t0 + 400)
        {
            imp.st = 3; frame = 0;
            fprintf(stderr, "import: released at cycle %llu, line %u (frame 0)\n", (unsigned long long)cyc, vc);
        }
        if (vc == 0 && last_vc != 0)
        {
            frame++;
            if (!quiet) fprintf(stderr, "frame %d at cycle %llu (retired 9:%llu 7:%llu, pc 9:%08x 7:%08x, late lines %llu)\n", frame,
                                (unsigned long long)cyc, (unsigned long long)retired[0], (unsigned long long)retired[1],
                                lastpc[0], lastpc[1], (unsigned long long)late);
            if (vwatch != ~0u) { fprintf(stderr, "vwatch f%d: %u writes to %05x on %u lines\n", frame, vw_n, vwatch, vw_lines); vw_n = vw_lines = 0; vw_lvc = ~0u; }
            if (!shots.empty() && frame % shot_every == 0) write_shot(frame);
            if (save_at && frame == save_at)
            {
                VerilatedSave os;
                os.open(save_file.c_str());
                os << *t;
                os.write(stamp, sizeof stamp); os.write(&romsize, sizeof romsize);
                os.write(mram.data(), mram.size()); os.write(vram.data(), vram.size()); os.write(sram.data(), sram.size());
                os.write(&pm, sizeof pm); os.write(&pv, sizeof pv); os.write(&ps, sizeof ps); os.write(&pc, sizeof pc); os.write(&pf, sizeof pf);
                os.write(&cyc, sizeof cyc); os.write(&frame, sizeof frame); os.write(&vc, sizeof vc); os.write(&late, sizeof late);  // vc: this boundary is already counted
                os.write(retired, sizeof retired); os.write(lastpc, sizeof lastpc); os.write(lastret_cyc, sizeof lastret_cyc);
                os.write(shadow, sizeof shadow); os.write(fb, sizeof fb);
                os.close();
                fprintf(stderr, "saved %s at frame %d\n", save_file.c_str(), frame);
            }
            if (frame >= frames && (imp.st < 0 || imp.st == 3)) break;
        }
        if (vc != last_vc) line_cyc = cyc;
        last_vc = vc;
        if (max_cycles && cyc >= max_cycles) break;
        if (trf[0] && traced[0] >= trace_insns && traced[1] >= trace_insns) break;
    }

    if (!wavname.empty())
    {
        FILE* f = fopen(wavname.c_str(), "wb");
        u32 n = wav.size() * 2, v;
        fwrite("RIFF", 1, 4, f); v = 36 + n; fwrite(&v, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
        u32 fmt[4] = {16, 0x00020001, 32768, 32768 * 4}; fwrite(fmt, 4, 4, f);
        u32 al = 0x00100004; fwrite(&al, 4, 1, f); fwrite("data", 1, 4, f); fwrite(&n, 4, 1, f);
        fwrite(wav.data(), 2, wav.size(), f); fclose(f);
        long nz = 0; for (auto x : wav) nz += x != 0;
        printf("wav: %zu samples, %ld nonzero\n", wav.size() / 2, nz);
    }
    if (wifi_check)
    {
        printf("wifi-check: %llu reads, %llu mismatches, %llu timing-dependent differences\n", wifi_reads, wifi_mism[0], wifi_mism[1]);
        for (auto& h : wifi_hist) printf("wifi-reads %04x %llu\n", h.first, h.second);
    }
    if (!sav_in.empty() || !sav_out.empty())
        printf("save port: %llu reads, %llu writes, first in frame %d\n", sav_rd, sav_wr, sav_first);
    if (!sav_out.empty())
    {
        FILE* f = fopen(sav_out.c_str(), "wb");
        fwrite(vram.data() + 0x100000, 1, sav_bytes, f);
        fclose(f);
    }
    if (result)
    {
        u32 base = 0x3F0000;
        u32 magic = rd32(mram, base), n = rd32(mram, base + 4), mask = rd32(mram, base + 8), done = rd32(mram, base + 12);
        printf("result: magic %08x checks %u mask %08x done %u\n", magic, n, mask, done);
        for (u32 i = 0; i < n && i < 32; i++) printf("  check %2u: %s value %08x\n", i, (mask >> i & 1) ? "ok " : "BAD", rd32(mram, base + 16 + 4 * i));
        bool pass = magic == 0x52545344 && done == 1 && n > 0 && mask == (n >= 32 ? 0xFFFFFFFFu : (1u << n) - 1);
        printf("%s\n", pass ? "PASS" : "FAIL");
        t->final();
        delete t;
        return pass ? 0 : 1;
    }
    for (int c = 0; c < 2; c++) if (trf[c]) fclose(trf[c]);
    if (vmlat_from >= 0)
    {
        fprintf(stderr, "vmlat: %llu block reads from frame %d (clk_sys; value: count)\n", (unsigned long long)vh_n, vmlat_from);
        const char *nm[3] = {"req->ack ", "ack->8th ", "req->8th "};
        u64 *hs[3] = {vh_ack, vh_tail, vh_tot};
        for (int h = 0; h < 3; h++)
        {
            fprintf(stderr, "vmlat %s", nm[h]);
            for (int i = 0; i < 256; i++) if (hs[h][i]) fprintf(stderr, " %d:%llu", i, (unsigned long long)hs[h][i]);
            fprintf(stderr, "\n");
        }
    }
    printf("cycles %llu frames %d retired 9:%llu 7:%llu traced 9:%llu 7:%llu\n", (unsigned long long)cyc, frame,
           (unsigned long long)retired[0], (unsigned long long)retired[1], (unsigned long long)traced[0], (unsigned long long)traced[1]);
    t->final();     // the RTL's final blocks (e.g. G3D_EQ's summary)
    delete t;
    return 0;
}
