// --export-state DIR: the machine state melonDS holds (after --load-state),
// in the form sim/ds/state_import.py turns into a tb_ds start (docs/state-import.md):
//   main.bin swram.bin wram7.bin itcm.bin dtcm.bin palette.bin oam.bin
//   vram_a.bin .. vram_i.bin save.bin       raw memories
//   state.txt                               CPU registers by mode, CP15, timing
//   io9.txt io7.txt                         I/O writes to replay on each CPU, in order
//                                           ("w8|w16|w32 ADDR VALUE", "fifo VALUE": an IPC FIFO push)
// Write-only registers come from melonDS's internal fields, so this file
// reaches into classes' private members (a debug tool on a pinned melonDS).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <array>
#include <memory>
#include <functional>
#include <algorithm>
#include <deque>
#include <optional>
#include <variant>
#include <sstream>
#include <iostream>
#include <fstream>
#include <map>
#include <unordered_map>
#include <list>
#include <mutex>
#include <thread>
#include <atomic>
#include <span>
#include <bitset>
#include <cmath>
#define private public
#define protected public
#include "NDS.h"
#include "GPU.h"
#include "GPU2D.h"
#include "GPU3D.h"
#include "DMA.h"
#include "SPU.h"
#include "NDSCart.h"
#include "ARM.h"
#undef private
#undef protected

using namespace melonDS;

#include "runtime_export.inc"
#include "runtime_history.h"
#include "runtime_history.inc"
#include "runtime_atomic.inc"

static void WriteBin(const std::string& path, const void* p, size_t n)
{
    FILE* f = fopen(path.c_str(), "wb");
    if (!f || fwrite(p, 1, n, f) != n) { fprintf(stderr, "cannot write %s\n", path.c_str()); exit(1); }
    fclose(f);
}

// a CPU's registers, by mode (melonDS keeps the current mode's in R[] and the
// others' in the slots: in mode M, M's slots hold the user values)
static void DumpRegs(FILE* f, const char* n, ARM& a)
{
    u32 cpsr = a.CPSR, mode = cpsr & 0x1F;
    bool thumb = cpsr & 0x20;
    fprintf(f, "%s.cpsr %08x\n%s.pc %08x\n%s.halted %u\n", n, cpsr, n, a.R[15] - (thumb ? 2 : 4), n, a.Halted);
    for (int i = 0; i < 8; i++) fprintf(f, "%s.r%d %08x\n", n, i, a.R[i]);
    // user r8-r14
    for (int i = 8; i < 13; i++) fprintf(f, "%s.usr_r%d %08x\n", n, i, mode == 0x11 ? a.R_FIQ[i - 8] : a.R[i]);
    u32 u13 = a.R[13], u14 = a.R[14];
    if (mode == 0x11) { u13 = a.R_FIQ[5]; u14 = a.R_FIQ[6]; }
    else if (mode == 0x12) { u13 = a.R_IRQ[0]; u14 = a.R_IRQ[1]; }
    else if (mode == 0x13) { u13 = a.R_SVC[0]; u14 = a.R_SVC[1]; }
    else if (mode == 0x17) { u13 = a.R_ABT[0]; u14 = a.R_ABT[1]; }
    else if (mode == 0x1B) { u13 = a.R_UND[0]; u14 = a.R_UND[1]; }
    fprintf(f, "%s.usr_r13 %08x\n%s.usr_r14 %08x\n", n, u13, n, u14);
    for (int i = 8; i < 15; i++) fprintf(f, "%s.fiq_r%d %08x\n", n, i, mode == 0x11 ? a.R[i] : a.R_FIQ[i - 8]);
    struct { const char* m; u32 id; u32* s; } b[] = {{"irq", 0x12, a.R_IRQ}, {"svc", 0x13, a.R_SVC}, {"abt", 0x17, a.R_ABT}, {"und", 0x1B, a.R_UND}};
    for (auto& x : b)
        fprintf(f, "%s.%s_r13 %08x\n%s.%s_r14 %08x\n%s.%s_spsr %08x\n", n, x.m, mode == x.id ? a.R[13] : x.s[0],
                n, x.m, mode == x.id ? a.R[14] : x.s[1], n, x.m, x.s[2]);
    fprintf(f, "%s.fiq_spsr %08x\n", n, a.R_FIQ[7]);
}

void ExportState(NDS* nds, const std::string& dir, int vcount, bool runtime)
{
    std::optional<RuntimeSourceGuard> runtimeGuard;
    if (runtime) runtimeGuard.emplace(*nds);
    // vcount: the line the import releases on; -1 = gpu.VCount (a state between frames). --export-clean
    // exports from the start-of-line hook, before line vcount is processed: melonDS then processes it, the core at
    // the release
    if (system(("mkdir -p '" + dir + "'").c_str()) != 0) exit(1);
    GPU& gpu = nds->GPU;
    WriteBin(dir + "/main.bin", nds->MainRAM, 0x400000);
    WriteBin(dir + "/swram.bin", nds->SharedWRAM, 0x8000);
    WriteBin(dir + "/wram7.bin", nds->ARM7WRAM, 0x10000);
    WriteBin(dir + "/itcm.bin", nds->ARM9.ITCM, ITCMPhysicalSize);
    WriteBin(dir + "/dtcm.bin", nds->ARM9.DTCM, DTCMPhysicalSize);
    WriteBin(dir + "/palette.bin", gpu.Palette, 2048);
    WriteBin(dir + "/oam.bin", gpu.OAM, 2048);
    static const u32 vsz[9] = {128, 128, 128, 128, 64, 16, 16, 32, 16};
    for (int i = 0; i < 9; i++) WriteBin(dir + "/vram_" + char('a' + i) + ".bin", gpu.VRAM[i], vsz[i] << 10);
    if (nds->NDSCartSlot.GetSaveMemory())
        WriteBin(dir + "/save.bin", nds->NDSCartSlot.GetSaveMemory(), nds->NDSCartSlot.GetSaveMemoryLength());

    FILE* f = fopen((dir + "/state.txt").c_str(), "w");
    fprintf(f, "# melonDS state (sim/ds/state_import.py, docs/state-import.md)\n");
    DumpRegs(f, "arm9", nds->ARM9);
    DumpRegs(f, "arm7", nds->ARM7);
    static const u32 cp15[] = {0x100, 0x200, 0x201, 0x300, 0x502, 0x503,
        0x600, 0x610, 0x620, 0x630, 0x640, 0x650, 0x660, 0x670, 0x910, 0x911};
    for (u32 id : cp15) fprintf(f, "cp15.%03x %08x\n", id, nds->ARM9.CP15Read(id));
    fprintf(f, "vcount %u\ndispstat9 %04x\ndispstat7 %04x\n", vcount >= 0 ? (u32)vcount : (u32)gpu.VCount, gpu.DispStat[0], gpu.DispStat[1]);
    fprintf(f, "keyinput %08x\n", nds->KeyInput);
    for (int i = 0; i < 8; i++)
        fprintf(f, "timer%d.counter %08x\ntimer%d.reload %04x\ntimer%d.cnt %04x\n", i, nds->Timers[i].Counter >> 10,
                i, nds->Timers[i].Reload, i, nds->Timers[i].Cnt);
    fprintf(f, "if9 %08x\nif7 %08x\n", nds->IF[0], nds->IF[1]);
    fprintf(f, "ipcfifo9.level %u\nipcfifo7.level %u\n", nds->IPCFIFO9.Level(), nds->IPCFIFO7.Level());
    for (int i = 0; i < 8; i++)
    {
        DMA& dm = nds->DMAs[i];
        fprintf(f, "dma%d.cnt %08x\ndma%d.running %u\ndma%d.inprogress %u\ndma%d.cursrc %08x\ndma%d.curdst %08x\ndma%d.remcount %08x\ndma%d.startmode %u\n",
                i, dm.Cnt, i, dm.Running, i, dm.InProgress, i, dm.CurSrcAddr, i, dm.CurDstAddr, i, dm.RemCount, i, dm.StartMode);
    }
    GPU3D& g3 = gpu.GPU3D;
    fprintf(f, "gx.fifo_level %u\ngx.pipe_level %u\ngx.numcommands %u\ngx.curcommand %08x\ngx.paramcount %u\ngx.totalparams %u\ngx.execparamcount %u\n",
            g3.CmdFIFO.Level(), g3.CmdPIPE.Level(), g3.NumCommands, g3.CurCommand, g3.ParamCount, g3.TotalParams, g3.ExecParamCount);
    // not restored (docs/state-import.md "Not restored", 3D): recorded to tell how far a state is from a clean 3D start
    fprintf(f, "gx.error %u\ngx.flushrequest %u\ngx.numpolygons %u\ngx.numvertices %u\ngx.rendernumpolygons %u\ngx.posstack %d\ngx.projstack %d\ngx.cyclecount %d\n",
            (g3.GXStat >> 15) & 1, g3.FlushRequest, g3.NumPolygons, g3.NumVertices, g3.RenderNumPolygons, g3.PosMatrixStackPointer, g3.ProjMatrixStackPointer, g3.CycleCount);
    fclose(f);

    // ---- I/O writes to replay (docs/state-import.md lists what is not restored)
    for (int cpu = 0; cpu < 2; cpu++)
    {
        FILE* o = fopen((dir + (cpu ? "/io7.txt" : "/io9.txt")).c_str(), "w");
        auto w8 = [&](u32 a, u32 v) { fprintf(o, "w8 %08x %02x\n", a, v & 0xFF); };
        auto w16 = [&](u32 a, u32 v) { fprintf(o, "w16 %08x %04x\n", a, v & 0xFFFF); };
        auto w32 = [&](u32 a, u32 v) { fprintf(o, "w32 %08x %08x\n", a, v); };
        DMA* dmas = cpu ? &nds->DMAs[4] : &nds->DMAs[0];
        if (cpu == 0)
        {
            w16(0x04000304, nds->PowerControl9);
            w16(0x04000204, nds->ExMemCnt[0]);
            w8(0x04000247, nds->WRAMCnt);
            for (int i = 0; i < 7; i++) w8(0x04000240 + i, gpu.VRAMCNT[i]);    // A-G
            w8(0x04000248, gpu.VRAMCNT[7]);     // H, I (0x247 is WRAMCNT)
            w8(0x04000249, gpu.VRAMCNT[8]);
            for (int e = 0; e < 2; e++)
            {
                auto& u = e ? gpu.GPU2D_B : gpu.GPU2D_A;
                u32 b = e ? 0x04001000 : 0x04000000;
                w32(b + 0x00, u.DispCnt);
                for (int i = 0; i < 4; i++) w16(b + 0x08 + 2 * i, u.BGCnt[i]);
                for (int i = 0; i < 4; i++) { w16(b + 0x10 + 4 * i, u.BGXPos[i]); w16(b + 0x12 + 4 * i, u.BGYPos[i]); }
                for (int i = 0; i < 2; i++)
                {
                    u32 r = b + 0x20 + 0x10 * i;
                    w16(r + 0, u.BGRotA[i]); w16(r + 2, u.BGRotB[i]); w16(r + 4, u.BGRotC[i]); w16(r + 6, u.BGRotD[i]);
                    // the value the game wrote (BGxRefReload), not melonDS's stepped BGxRef: a layer disabled at the
                    // frame end keeps a stale BGxRef (melonDS steps and reloads only enabled layers), and written as
                    // the register it became the reload value: KH 358/2 Days' movie (BG3Y_B stepped to 176.0 while
                    // the game's is 0) drew every other picture 176 rows down. A clean export is at line 0, where an
                    // enabled layer's BGxRef equals its reload value
                    w32(r + 8, u.BGXRefReload[i]); w32(r + 12, u.BGYRefReload[i]);
                }
                w16(b + 0x40, u.Win0Coords[0] << 8 | u.Win0Coords[1]);
                w16(b + 0x42, u.Win1Coords[0] << 8 | u.Win1Coords[1]);
                w16(b + 0x44, u.Win0Coords[2] << 8 | u.Win0Coords[3]);
                w16(b + 0x46, u.Win1Coords[2] << 8 | u.Win1Coords[3]);
                w16(b + 0x48, u.WinCnt[0] | u.WinCnt[1] << 8);
                w16(b + 0x4A, u.WinCnt[2] | u.WinCnt[3] << 8);
                w16(b + 0x4C, u.BGMosaicSize[0] | u.BGMosaicSize[1] << 4 | u.OBJMosaicSize[0] << 8 | u.OBJMosaicSize[1] << 12);
                w16(b + 0x50, u.BlendCnt);
                w16(b + 0x52, u.BlendAlpha);
                w16(b + 0x54, u.EVY);
                w16(b + 0x6C, e ? gpu.MasterBrightnessB : gpu.MasterBrightnessA);
            }
            w32(0x04000064, gpu.CaptureCnt);
            w32(0x04000060, nds->ARM9IORead32(0x04000060));   // DISP3DCNT
            // ---- 3D: rendering registers, then the geometry state through the command ports
            GPU3D& g = gpu.GPU3D;
            for (int i = 0; i < 8; i++) w16(0x04000330 + 2 * i, g.EdgeTable[i]);
            w16(0x04000340, g.AlphaRef);
            w32(0x04000350, g.ClearAttr1);
            w32(0x04000354, g.ClearAttr2);
            w32(0x04000358, g.FogColor);
            w16(0x0400035C, g.FogOffset);
            for (int i = 0; i < 32; i++) w8(0x04000360 + i, g.FogDensityTable[i]);
            for (int i = 0; i < 32; i++) w16(0x04000380 + 2 * i, g.ToonTable[i]);
            auto load = [&](const s32* m) { for (int i = 0; i < 16; i++) w32(0x04000458, m[i]); };
            // light vectors with an identity vector matrix: melonDS keeps -(M * dir)
            w32(0x04000440, 2); w32(0x04000454, 0);
            for (int l = 0; l < 4; l++)
            {
                u32 v = 0;
                for (int c = 0; c < 3; c++) v |= (u32(-g.LightDirection[l][c]) & 0x3FF) << (10 * c);
                w32(0x040004C8, v | u32(l) << 30);
                w32(0x040004CC, g.LightColor[l][0] | g.LightColor[l][1] << 5 | g.LightColor[l][2] << 10 | u32(l) << 30);
            }
            w32(0x040004C0, g.MatDiffuse[0] | g.MatDiffuse[1] << 5 | g.MatDiffuse[2] << 10 |
                            (g.MatAmbient[0] | g.MatAmbient[1] << 5 | g.MatAmbient[2] << 10) << 16);
            w32(0x040004C4, g.MatSpecular[0] | g.MatSpecular[1] << 5 | g.MatSpecular[2] << 10 | (g.UseShininessTable ? 0x8000 : 0) |
                            (g.MatEmission[0] | g.MatEmission[1] << 5 | g.MatEmission[2] << 10) << 16);
            for (int i = 0; i < 32; i++)
                w32(0x040004D0, g.ShininessTable[4 * i] | g.ShininessTable[4 * i + 1] << 8 | g.ShininessTable[4 * i + 2] << 16 | u32(g.ShininessTable[4 * i + 3]) << 24);
            // the stacks: pointers first (pushes), then every entry by index. The position stack first: its
            // pointer is 6 bits and its 32nd entry (index 31) the overflow slot (NSMB's state has the pointer at
            // 32); storing index 31 sets GXSTAT's error flag, which is then acknowledged unless melonDS has it set.
            // The acknowledge zeroes the projection and texture pointers, so those come after it.
            w32(0x04000440, 2);
            for (int i = 0; i < g.PosMatrixStackPointer; i++) w32(0x04000444, 0);
            for (int i = 0; i < 32; i++)
            {
                w32(0x04000440, 2); load(g.VecMatrixStack[i]);      // (sets both)
                w32(0x04000440, 1); load(g.PosMatrixStack[i]);
                w32(0x0400044C, i);                                  // stores both
            }
            if (!(g.GXStat & 0x8000)) w32(0x04000600, (g.GXStat & 0xC0000000) | 0x8000);
            w32(0x04000440, 0);
            if (g.ProjMatrixStackPointer) w32(0x04000444, 0);
            load(g.ProjMatrixStack); w32(0x0400044C, 0);
            w32(0x04000440, 3);
            if (g.TexMatrixStackPointer) w32(0x04000444, 0);
            load(g.TexMatrixStack); w32(0x0400044C, 0);
            // the current matrices and mode
            w32(0x04000440, 0); load(g.ProjMatrix);
            w32(0x04000440, 2); load(g.VecMatrix);
            w32(0x04000440, 1); load(g.PosMatrix);
            w32(0x04000440, 3); load(g.TexMatrix);
            w32(0x04000440, g.MatrixMode);
            w32(0x04000580, g.Viewport[0] | (191 - g.Viewport[1]) << 8 | g.Viewport[2] << 16 | u32(191 - g.Viewport[3]) << 24);
            w32(0x040004A4, g.PolygonAttr);
            w32(0x040004A8, g.TexParam);
            w32(0x040004AC, g.TexPalette);
            w32(0x04000480, g.VertexColor[0] | g.VertexColor[1] << 5 | g.VertexColor[2] << 10);
            w32(0x04000600, g.GXStat & 0xC0000000);       // GXSTAT: the GX FIFO IRQ condition
            for (int i = 0; i < 4; i++) w32(0x040000E0 + 4 * i, nds->DMA9Fill[i]);
            w16(0x04000280, nds->DivCnt);
            w32(0x04000290, nds->DivNumerator[0]); w32(0x04000294, nds->DivNumerator[1]);
            w32(0x04000298, nds->DivDenominator[0]); w32(0x0400029C, nds->DivDenominator[1]);
            w16(0x040002B0, nds->SqrtCnt);
            w32(0x040002B8, nds->SqrtVal[0]); w32(0x040002BC, nds->SqrtVal[1]);
            w8(0x04000300, nds->PostFlag9);
        }
        else
        {
            w16(0x04000304, nds->PowerControl7);
            w16(0x04000206, nds->WifiWaitCnt);
            w16(0x04000134, nds->RCnt);
            w8(0x04000300, nds->PostFlag7);
            w16(0x04000308, nds->ARM7BIOSProt);
            SPU& spu = nds->SPU;
            w16(0x04000500, spu.Cnt);
            w16(0x04000504, spu.Bias);
            for (int c = 0; c < 16; c++)
            {
                SPUChannel& ch = spu.Channels[c];
                u32 b = 0x04000400 + 16 * c;
                w32(b + 4, ch.SrcAddr); w16(b + 8, ch.TimerReload); w16(b + 10, ch.LoopPos >> 2); w32(b + 12, ch.Length >> 2);   // (melonDS keeps them in bytes; the registers count words)
                w32(b + 0, ch.Cnt);    // a running channel restarts from its start (docs/state-import.md)
            }
            for (int c = 0; c < 2; c++)
            {
                SPUCaptureUnit& cp = spu.Capture[c];
                w32(0x04000510 + 8 * c, cp.DstAddr); w16(0x04000514 + 8 * c, cp.Length >> 2);   // (bytes in melonDS, words in SNDCAPxLEN)
                w8(0x04000508 + c, cp.Cnt);
            }
        }
        // the cart's registers on the CPU that owns the slot (EXMEMCNT bit 11)
        if (cpu == ((nds->ExMemCnt[0] >> 11) & 1))
        {
            w16(0x040001A0, nds->NDSCartSlot.ReadSPICnt(cpu));
            w32(0x040001A4, nds->NDSCartSlot.ReadROMCnt(cpu) & 0x7FFFFFFF);   // (no transfer in flight)
        }
        // both CPUs: timers (the counters restart from their reloads), DMA, IPC, IRQ, keys
        for (int t = 0; t < 4; t++)
        {
            Timer& tm = nds->Timers[cpu * 4 + t];
            w16(0x04000100 + 4 * t, tm.Reload);
            w16(0x04000102 + 4 * t, tm.Cnt);
        }
        for (int d = 0; d < 4; d++)
        {
            DMA& dm = dmas[d];
            w32(0x040000B0 + 12 * d, dm.SrcAddr);
            w32(0x040000B4 + 12 * d, dm.DstAddr);
            // an immediate DMA in flight is not restarted
            u32 cnt = dm.Cnt;
            if ((cnt & 0x80000000) && ((cnt >> 27) & (cpu ? 3 : 7)) == 0) cnt &= 0x7FFFFFFF;
            w32(0x040000B8 + 12 * d, cnt);
        }
        w16(0x04000180, (cpu ? nds->IPCSync7 : nds->IPCSync9) & 0x4F00);
        u16 fcnt = cpu ? nds->IPCFIFOCnt7 : nds->IPCFIFOCnt9;
        w16(0x04000184, (fcnt & 0x8404) | 0x0008);    // enable + IRQ enables, send FIFO cleared
        auto& fifo = cpu ? nds->IPCFIFO7 : nds->IPCFIFO9;
        for (u32 i = 0; i < fifo.Level(); i++) fprintf(o, "fifo %08x\n", fifo.Peek(i));
        w16(0x04000004, gpu.DispStat[cpu] & 0xFF38);    // IRQ enables, VCOUNT match line
        w16(0x04000132, nds->KeyCnt[cpu]);
        w32(0x04000210, nds->IE[cpu]);
        w32(0x04000208, nds->IME[cpu]);
        fclose(o);
    }
    if (runtime) { ExportRuntime(*nds, dir, vcount); ExportRuntimeHistory(*nds, dir, vcount); ExportRuntimeAtomic(*nds,dir,vcount); runtimeGuard->verify(); }
    fprintf(stderr, "export-state: %s (vcount %u)\n", dir.c_str(), vcount >= 0 ? (u32)vcount : (u32)gpu.VCount);
}
