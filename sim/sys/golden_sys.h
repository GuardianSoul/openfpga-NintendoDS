// Golden model for the system blocks: melonDS's logic, transcribed from
// references/melonDS/src (NDS.cpp, DMA.cpp, FIFO.h) with the functions
// named after the originals. NDS.cpp drags in the whole emulator, so the
// relevant functions are copied here rather than compiled.
//
// Time: `sys` is melonDS's SysTimestamp (33.51 MHz system cycles). The test
// bench calls at(sys) before each access, which runs timers and due events
// up to that time, the way melonDS does before a CPU access.
#pragma once
#include <cstdint>
#include <cstring>
#include <functional>
#include <map>
#include <vector>

namespace gold {
using u8 = uint8_t; using u16 = uint16_t; using u32 = uint32_t; using u64 = uint64_t;
using s32 = int32_t; using s64 = int64_t;

template <typename T, u32 N> struct FIFO {           // FIFO.h
    T e[N] = {}; u32 n = 0, rp = 0, wp = 0;
    void Clear() { n = rp = wp = 0; e[0] = 0; }
    void Write(T v) { if (IsFull()) return; e[wp] = v; wp = (wp + 1) % N; n++; }
    T Read() { if (IsEmpty()) return e[(rp ? rp : N) - 1]; T r = e[rp]; rp = (rp + 1) % N; n--; return r; }
    T Peek() const { return e[rp]; }
    bool IsEmpty() const { return n == 0; }
    bool IsFull() const { return n >= N; }
};

struct Timer { u16 Reload = 0, Cnt = 0; u32 Counter = 0, CycleShift = 0; };

struct Mem {                                         // the bus the DMA sees
    std::function<u32(u32 cpu, u32 addr, bool w32)> read;
    std::function<void(u32 cpu, u32 addr, u32 val, bool w32)> write;
};

struct Sys;
struct DMA {                                         // DMA.cpp, functional
    Sys* nds = nullptr; u32 CPU = 0, Num = 0;
    u32 SrcAddr = 0, DstAddr = 0, Cnt = 0, StartMode = 0, CurSrcAddr = 0, CurDstAddr = 0;
    u32 RemCount = 0, IterCount = 0; s32 SrcAddrInc = 0, DstAddrInc = 0;
    u32 Running = 0; bool InProgress = false;
    void WriteCnt(u32 val);
    void Start();
    void Run();
    bool IsInMode(u32 m) const { return m == StartMode && (Cnt & 0x80000000); }
    void StartIfNeeded(u32 m) { if (IsInMode(m)) Start(); }
    void StopIfNeeded(u32 m) { if (m == StartMode) Cnt &= ~0x80000000u; }
};

struct Sys {
    u64 sys = 0;
    // IRQ
    u32 IME[2] = {}, IE[2] = {}, IF[2] = {};
    // timers
    Timer Timers[8]; u8 TimerCheckMask[2] = {}; u64 TimerTimestamp[2] = {}; u64 IrqN[8] = {};
    // IPC
    u16 IPCSync9 = 0, IPCSync7 = 0, IPCFIFOCnt9 = 0, IPCFIFOCnt7 = 0;
    FIFO<u32, 16> IPCFIFO9, IPCFIFO7;
    // math
    u16 DivCnt = 0, SqrtCnt = 0; u32 DivNumerator[2] = {}, DivDenominator[2] = {};
    u32 DivQuotient[2] = {}, DivRemainder[2] = {}, SqrtVal[2] = {}, SqrtRes = 0;
    u64 DivEvent = 0, SqrtEvent = 0; bool DivPending = false, SqrtPending = false;
    // DMA
    DMA DMAs[8]; u32 DMA9Fill[4] = {}; Mem mem; bool gx_low = false;

    Sys() { for (u32 i = 0; i < 8; i++) { DMAs[i].nds = this; DMAs[i].CPU = i >> 2; DMAs[i].Num = i & 3; } }

    void SetIRQ(u32 cpu, u32 irq) { IF[cpu] |= 1u << irq; }
    bool IRQLine(u32 cpu) const { return (IME[cpu] & 1) && (IE[cpu] & IF[cpu]); }

    // ---- timers (NDS.cpp RunTimer, RunTimers, HandleTimerOverflow, TimerStart)
    void HandleTimerOverflow(u32 tid) {
        Timer* t = &Timers[tid];
        t->Counter += (t->Reload << 10);
        if (t->Cnt & (1 << 6)) { SetIRQ(tid >> 2, 3 + (tid & 3)); IrqN[tid]++; }
        if ((tid & 3) == 3) return;
        for (;;) {
            tid++; t = &Timers[tid];
            if ((t->Cnt & 0x84) != 0x84) break;
            t->Counter += (1 << 10);
            if (!(t->Counter >> 26)) break;
            t->Counter = t->Reload << 10;
            if (t->Cnt & (1 << 6)) { SetIRQ(tid >> 2, 3 + (tid & 3)); IrqN[tid]++; }
            if ((tid & 3) == 3) break;
        }
    }
    void RunTimer(u32 tid, s32 cycles) {
        // per cycle, so that the overflow IRQ order matches a per-cycle walk
        for (s32 c = 0; c < cycles; c++) {
            Timer* t = &Timers[tid];
            t->Counter += (1u << t->CycleShift);
            while (t->Counter >> 26) { t->Counter -= (1 << 26); HandleTimerOverflow(tid); }
        }
    }
    void RunTimers(u32 cpu) {
        // melonDS runs each timer over the whole span in turn; a cascade
        // target is never in the mask, so stepping cycle by cycle is the same
        u64 n = sys - TimerTimestamp[cpu];
        for (u64 c = 0; c < n; c++)
            for (u32 i = 0; i < 4; i++)
                if (TimerCheckMask[cpu] & (1 << i)) RunTimer((cpu << 2) + i, 1);
        TimerTimestamp[cpu] = sys;
    }
    void TimerStart(u32 id, u16 cnt) {
        static const s32 pre[4] = {0, 6, 8, 10};
        Timer* t = &Timers[id];
        u16 cur = t->Cnt & (1 << 7), nw = cnt & (1 << 7);
        RunTimers(id >> 2);
        t->Cnt = cnt; t->CycleShift = 10 - pre[cnt & 3];
        if (!cur && nw) t->Counter = t->Reload << 10;
#ifndef MELONDS_STOCK
        // DS_RULE_TMRFREE (hwref run 30): the prescaler runs free from reset,
        // so the fraction is the system-cycle count's phase at this prescaler
        // (consistent with a free-running count from then on)
        { s32 p = pre[cnt & 3]; u32 ph = (u32)(TimerTimestamp[id >> 2] & ((1u << p) - 1)) << (10 - p);
          t->Counter = (t->Counter & ~0x3FFu) | ph; }
#endif
        if ((cnt & 0x84) == 0x80) TimerCheckMask[id >> 2] |= 1 << (id & 3);
        else TimerCheckMask[id >> 2] &= ~(1 << (id & 3));
    }
    u16 TimerGetCounter(u32 id) { RunTimers(id >> 2); return Timers[id].Counter >> 10; }

    // ---- divider / square root (NDS.cpp DivDone, StartDiv, SqrtDone, StartSqrt)
    void DivDone() {
        DivCnt &= ~0xC000;
        switch (DivCnt & 3) {
        case 0: {
            s32 num = (s32)DivNumerator[0], den = (s32)DivDenominator[0];
            if (den == 0) { DivQuotient[0] = (num < 0) ? 1 : -1; DivQuotient[1] = (num < 0) ? -1 : 0;
                            s64 r = num; memcpy(DivRemainder, &r, 8); }
            else if (num == INT32_MIN && den == -1) { s64 q = 0x80000000; memcpy(DivQuotient, &q, 8); }
            else { s64 q = (s64)(num / den), r = (s64)(num % den); memcpy(DivQuotient, &q, 8); memcpy(DivRemainder, &r, 8); }
        } break;
        case 1: case 3: {
            s64 num; memcpy(&num, DivNumerator, 8); s32 den = (s32)DivDenominator[0];
            s64 q, r;
            if (den == 0) { q = (num < 0) ? 1 : -1; r = num; }
            else if (num == INT64_MIN && den == -1) { q = INT64_MIN; r = 0; }
            else { q = num / den; r = num % den; }
            memcpy(DivQuotient, &q, 8); memcpy(DivRemainder, &r, 8);
        } break;
        case 2: {
            s64 num, den; memcpy(&num, DivNumerator, 8); memcpy(&den, DivDenominator, 8);
            s64 q, r;
            if (den == 0) { q = (num < 0) ? 1 : -1; r = num; }
            else if (num == INT64_MIN && den == -1) { q = INT64_MIN; r = 0; }
            else { q = num / den; r = num % den; }
            memcpy(DivQuotient, &q, 8); memcpy(DivRemainder, &r, 8);
        } break;
        }
        if ((DivDenominator[0] | DivDenominator[1]) == 0) DivCnt |= 0x4000;
    }
    void StartDiv() { DivCnt |= 0x8000; DivEvent = sys + (((DivCnt & 3) == 0) ? 18 : 34); DivPending = true; }
    void SqrtDone() {
        u64 val; u32 res = 0; u64 rem = 0; u64 prod = 0; u32 nbits, topshift;
        SqrtCnt &= ~0x8000;
        if (SqrtCnt & 1) { memcpy(&val, SqrtVal, 8); nbits = 32; topshift = 62; }
        else { val = SqrtVal[0]; nbits = 16; topshift = 30; }
        for (u32 i = 0; i < nbits; i++) {
            rem = (rem << 2) + ((val >> topshift) & 3); val <<= 2; res <<= 1;
            prod = (u64(res) << 1) + 1;
            if (rem >= prod) { rem -= prod; res++; }
        }
        SqrtRes = res;
    }
    void StartSqrt() { SqrtCnt |= 0x8000; SqrtEvent = sys + 13; SqrtPending = true; }

    // advance to system time t: due events, then timers
    void at(u64 t) {
        sys = t;
        if (DivPending && DivEvent <= sys) { DivPending = false; DivDone(); }
        if (SqrtPending && SqrtEvent <= sys) { SqrtPending = false; SqrtDone(); }
        RunTimers(0); RunTimers(1);
    }

    // ---- DMA events (NDS::CheckDMAs / StopDMAs, GPU3D::CheckFIFODMA)
    void RunDMAs(u32 cpu) {
        for (;;) {
            bool any = false;
            for (u32 i = 0; i < 4; i++) {
                DMA& d = DMAs[cpu * 4 + i];
                if (d.Running) { d.Run(); any = true; break; }
            }
            if (!any) break;
        }
    }
    void CheckDMAs(u32 cpu, u32 mode) { for (u32 i = 0; i < 4; i++) DMAs[cpu * 4 + i].StartIfNeeded(mode); RunDMAs(cpu); }
    void StopDMAs(u32 cpu, u32 mode) { for (u32 i = 0; i < 4; i++) DMAs[cpu * 4 + i].StopIfNeeded(mode); }
    void CheckFIFODMA() { if (gx_low) CheckDMAs(0, 7); }

    // ---- register access, word address offset from 0x04000000, byte enables
    u32 read(u32 cpu, u32 a, u32 be);
    void write(u32 cpu, u32 a, u32 v, u32 be);
};

inline void DMA::WriteCnt(u32 val) {
    u32 oldcnt = Cnt; Cnt = val;
    if (!(oldcnt & 0x80000000) && (val & 0x80000000)) {
        CurSrcAddr = SrcAddr; CurDstAddr = DstAddr;
        switch (Cnt & 0x00600000) { case 0: DstAddrInc = 1; break; case 0x00200000: DstAddrInc = -1; break;
                                    case 0x00400000: DstAddrInc = 0; break; default: DstAddrInc = 1; }
        switch (Cnt & 0x01800000) { case 0: SrcAddrInc = 1; break; case 0x00800000: SrcAddrInc = -1; break;
                                    case 0x01000000: SrcAddrInc = 0; break; default: SrcAddrInc = 1; }
        StartMode = CPU == 0 ? (Cnt >> 27) & 7 : ((Cnt >> 28) & 3) | 0x10;
        if ((StartMode & 7) == 0) { Start(); nds->RunDMAs(CPU); }
        else if (StartMode == 7) nds->CheckFIFODMA();
    }
}
inline void DMA::Start() {
    if (Running) return;
    if (!InProgress) {
        u32 m = CPU == 0 ? 0x001FFFFF : (Num == 3 ? 0x0000FFFF : 0x00003FFF);
        RemCount = Cnt & m; if (!RemCount) RemCount = m + 1;
    }
    IterCount = (StartMode == 7 && RemCount > 112) ? 112 : RemCount;
    if ((Cnt & 0x01800000) == 0x01800000) CurSrcAddr = SrcAddr;
    if ((Cnt & 0x00600000) == 0x00600000) CurDstAddr = DstAddr;
    Running = 2; InProgress = true;
}
inline void DMA::Run() {                             // Run9/Run7 without timing
    Running = 1;
    bool w32 = Cnt & (1 << 26);
    while (IterCount > 0) {
        u32 v = nds->mem.read(CPU, CurSrcAddr, w32);
        nds->mem.write(CPU, CurDstAddr, v, w32);
        CurSrcAddr += SrcAddrInc << (w32 ? 2 : 1);
        CurDstAddr += DstAddrInc << (w32 ? 2 : 1);
        IterCount--; RemCount--;
    }
    if (RemCount) {
        Running = 0;
        if (StartMode == 7) nds->CheckFIFODMA();
        return;
    }
    if (!(Cnt & (1 << 25))) Cnt &= ~(1u << 31);
    if (Cnt & (1 << 30)) nds->SetIRQ(CPU, 8 + Num);
    Running = 0; InProgress = false;
}

inline u32 Sys::read(u32 cpu, u32 a, u32 be) {
    (void)be;
    if (a == 0x100000) {                             // IPCFIFORECV
        u16& cnt = cpu ? IPCFIFOCnt7 : IPCFIFOCnt9; u16& ocnt = cpu ? IPCFIFOCnt9 : IPCFIFOCnt7;
        auto& f = cpu ? IPCFIFO9 : IPCFIFO7;
        if (cnt & 0x8000) {
            if (f.IsEmpty()) { cnt |= 0x4000; return f.Peek(); }
            u32 r = f.Read();
            if (f.IsEmpty() && (ocnt & 0x0004)) SetIRQ(cpu ^ 1, 17);
            return r;
        }
        return f.Peek();
    }
    if (a >= 0xB0 && a < 0xE0) {
        DMA& d = DMAs[cpu * 4 + (a - 0xB0) / 12];
        u32 r = (a - 0xB0) % 12;
        return r == 0 ? d.SrcAddr : r == 4 ? d.DstAddr : d.Cnt;
    }
    if (a >= 0xE0 && a < 0xF0 && !cpu) return DMA9Fill[(a - 0xE0) / 4];
    if (a >= 0x100 && a < 0x110) { u32 t = cpu * 4 + (a - 0x100) / 4; return TimerGetCounter(t) | (Timers[t].Cnt << 16); }
    if (a == 0x180) return cpu ? IPCSync7 : IPCSync9;
    if (a == 0x184) {
        u16 v = cpu ? IPCFIFOCnt7 : IPCFIFOCnt9;
        auto& s = cpu ? IPCFIFO7 : IPCFIFO9; auto& r = cpu ? IPCFIFO9 : IPCFIFO7;
        if (s.IsEmpty()) v |= 1; else if (s.IsFull()) v |= 2;
        if (r.IsEmpty()) v |= 0x100; else if (r.IsFull()) v |= 0x200;
        return v;
    }
    if (a == 0x208) return IME[cpu];
    if (a == 0x210) return IE[cpu];
    if (a == 0x214) return IF[cpu];
    if (!cpu) switch (a) {
        case 0x280: return DivCnt;
        case 0x290: return DivNumerator[0];  case 0x294: return DivNumerator[1];
        case 0x298: return DivDenominator[0]; case 0x29C: return DivDenominator[1];
        case 0x2A0: return DivQuotient[0];   case 0x2A4: return DivQuotient[1];
        case 0x2A8: return DivRemainder[0];  case 0x2AC: return DivRemainder[1];
        case 0x2B0: return SqrtCnt;          case 0x2B4: return SqrtRes;
        case 0x2B8: return SqrtVal[0];       case 0x2BC: return SqrtVal[1];
    }
    return 0;
}

// The test bench uses the access sizes melonDS handles: 32-bit everywhere,
// 16-bit (be 0x3 / 0xC) for CNT halves, timers, IPC, IME/IE/IF and DIVCNT.
inline void Sys::write(u32 cpu, u32 a, u32 v, u32 be) {
    u32 m = (be & 1 ? 0xFFu : 0) | (be & 2 ? 0xFF00u : 0) | (be & 4 ? 0xFF0000u : 0) | (be & 8 ? 0xFF000000u : 0);
    if (a >= 0xB0 && a < 0xE0) {
        DMA& d = DMAs[cpu * 4 + (a - 0xB0) / 12];
        u32 r = (a - 0xB0) % 12;
        if (r == 0) d.SrcAddr = (d.SrcAddr & ~m) | (v & m);
        else if (r == 4) d.DstAddr = (d.DstAddr & ~m) | (v & m);
        else d.WriteCnt((d.Cnt & ~m) | (v & m));
        return;
    }
    if (a >= 0xE0 && a < 0xF0) { if (!cpu) { u32& f = DMA9Fill[(a - 0xE0) / 4]; f = (f & ~m) | (v & m); } return; }
    if (a >= 0x100 && a < 0x110) {
        u32 t = cpu * 4 + (a - 0x100) / 4;
        // melonDS handles 16- and 32-bit timer writes; byte writes are ignored
        if ((be & 3) == 3) Timers[t].Reload = v & 0xFFFF;
#ifndef MELONDS_STOCK
        // DS_RULE_TMRCNT (hwref run 34): TMCNT_H keeps bits 0-2, 6 and 7 (the
        // rest read 0), and a byte write to its low byte takes effect
        if (be & 4) TimerStart(t, (v >> 16) & 0xC7);
#else
        if ((be & 0xC) == 0xC) TimerStart(t, v >> 16);
#endif
        return;
    }
    if (a == 0x180 && (be & 2)) {
        u16& me = cpu ? IPCSync7 : IPCSync9; u16& ot = cpu ? IPCSync9 : IPCSync7;
        ot = (ot & 0xFFF0) | ((v & 0x0F00) >> 8);
        me = (me & 0xB0FF) | (v & 0x4F00);
        if ((v & 0x2000) && (ot & 0x4000)) SetIRQ(cpu ^ 1, 16);
        return;
    }
    if (a == 0x184 && (be & 3) == 3) {
        u16& cnt = cpu ? IPCFIFOCnt7 : IPCFIFOCnt9;
        auto& s = cpu ? IPCFIFO7 : IPCFIFO9; auto& r = cpu ? IPCFIFO9 : IPCFIFO7;
        if (v & 0x0008) s.Clear();
        if ((v & 0x0004) && !(cnt & 0x0004) && s.IsEmpty()) SetIRQ(cpu, 17);
        if ((v & 0x0400) && !(cnt & 0x0400) && !r.IsEmpty()) SetIRQ(cpu, 18);
        if (v & 0x4000) cnt &= ~0x4000;
        cnt = (v & 0x8404) | (cnt & 0x4000);
        return;
    }
    if (a == 0x188) {
        if (be == 3) v = (v & 0xFFFF) | (v << 16);
        u16& cnt = cpu ? IPCFIFOCnt7 : IPCFIFOCnt9; u16& ocnt = cpu ? IPCFIFOCnt9 : IPCFIFOCnt7;
        auto& s = cpu ? IPCFIFO7 : IPCFIFO9;
        if (cnt & 0x8000) {
            if (s.IsFull()) cnt |= 0x4000;
            else { bool was = s.IsEmpty(); s.Write(v); if ((ocnt & 0x0400) && was) SetIRQ(cpu ^ 1, 18); }
        }
        return;
    }
    if (a == 0x208) { if (be & 1) IME[cpu] = v & 1; return; }
    if (a == 0x210) { IE[cpu] = (IE[cpu] & ~m) | (v & m); return; }
    if (a == 0x214) { IF[cpu] &= ~(v & m); return; }
    if (!cpu) {
        if (a == 0x280 && (be & 3) == 3) { DivCnt = v; StartDiv(); return; }
        if (a == 0x2B0 && (be & 3) == 3) { SqrtCnt = v; StartSqrt(); return; }
        if (be != 0xF) return;
        switch (a) {
            case 0x290: DivNumerator[0] = v; StartDiv(); break;
            case 0x294: DivNumerator[1] = v; StartDiv(); break;
            case 0x298: DivDenominator[0] = v; StartDiv(); break;
            case 0x29C: DivDenominator[1] = v; StartDiv(); break;
            case 0x2B8: SqrtVal[0] = v; StartSqrt(); break;
            case 0x2BC: SqrtVal[1] = v; StartSqrt(); break;
        }
    }
}
} // namespace gold
