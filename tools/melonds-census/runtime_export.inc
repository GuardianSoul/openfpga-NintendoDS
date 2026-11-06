// Optional clean-hook observation only: no device Run/Read/DoSavestate calls.
// Explicit semantic fields avoid ABI padding, pointer serialization and the
// renderer synchronization performed by GPU::DoSavestate.
#include <type_traits>
#include <vector>

namespace {
class RuntimeJson {
    FILE* file;
    std::vector<bool> first;
    void prefix(const char* key) {
        if (!first.empty()) { if (!first.back()) fputc(',', file); first.back() = false; }
        if (key) fprintf(file, "\"%s\":", key); // all keys below are fixed identifiers
    }
public:
    explicit RuntimeJson(FILE* f) : file(f) {}
    void object(const char* key = nullptr) { prefix(key); fputc('{', file); first.push_back(true); }
    void array(const char* key) { prefix(key); fputc('[', file); first.push_back(true); }
    void endObject() { fputc('}', file); first.pop_back(); }
    void endArray() { fputc(']', file); first.pop_back(); }
    template<class T> void number(const char* key, T value) {
        prefix(key);
        if constexpr (std::is_signed_v<T>) fprintf(file, "%lld", (long long)value);
        else fprintf(file, "%llu", (unsigned long long)value);
    }
    template<class T> void values(const char* key, const T& values) {
        array(key); for (const auto& v : values) number(nullptr, v); endArray();
    }
};

// Compare the same source objects before and after export, without serializing
// through the device APIs. Byte snapshots are legal object representations;
// padding is compared only within this one paused device instance, never
// between builds. Arrays include the live capture RAM, not only registers.
class RuntimeSourceGuard {
    struct Chunk { const void* source; std::vector<unsigned char> bytes; };
    std::vector<Chunk> chunks;
    void add(const void* source, size_t size) {
        const auto* p = static_cast<const unsigned char*>(source);
        chunks.push_back({source, std::vector<unsigned char>(p, p + size)});
    }
    template<class T> void value(const T& v) { add(&v, sizeof(v)); }
public:
    explicit RuntimeSourceGuard(const NDS& n) {
        value(n.SPU); value(n.Timers); value(n.TimerTimestamp); value(n.TimerCheckMask); value(n.DMAs);
        value(n.IME); value(n.IE); value(n.IF); value(n.IE2); value(n.IF2);
        value(n.IPCFIFO9); value(n.IPCFIFO7); value(n.IPCFIFOCnt9); value(n.IPCFIFOCnt7);
        value(n.IPCSync9); value(n.IPCSync7); value(n.SchedList); value(n.SchedListMask);
        value(n.SysTimestamp); value(n.ARM9Timestamp); value(n.ARM7Timestamp);
        value(n.ARM9Target); value(n.ARM7Target); value(n.FrameStartTimestamp); value(n.LastSysClockCycles);
        value(n.GPU); value(n.GPU.GPU2D_A); value(n.GPU.GPU2D_B); value(n.GPU.GPU3D);
        add(n.MainRAM, 0x400000); add(n.SharedWRAM, 0x8000); add(n.ARM7WRAM, 0x10000);
        add(n.ARM9.ITCM, ITCMPhysicalSize); add(n.ARM9.DTCM, DTCMPhysicalSize);
        add(n.GPU.Palette, 2048); add(n.GPU.OAM, 2048);
        const size_t sizes[9] = {128,128,128,128,64,16,16,32,16};
        for (unsigned i=0;i<9;i++) add(n.GPU.VRAM[i], sizes[i] << 10);
    }
    void verify() const {
        size_t total = 0;
        for (const auto& c : chunks) {
            if (memcmp(c.source, c.bytes.data(), c.bytes.size())) {
                fprintf(stderr, "RUNTIME_EXPORT_SOURCE_CHANGED chunk %zu\n", total); exit(1);
            }
            total += c.bytes.size();
        }
        fprintf(stderr, "RUNTIME_EXPORT_SOURCE_EXACT bytes %zu\n", total);
    }
};

static void ExportRuntime(const NDS& n, const std::string& dir, int cleanLine) {
    const std::string path = dir + "/runtime.json";
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", path.c_str()); exit(1); }
    RuntimeJson j(f);
    j.object(); j.number("schema_version", 1); j.number("clean_line_before_processing", cleanLine);
    j.object("clock");
#define R(field) j.number(#field, n.field)
    R(SysTimestamp); R(ARM9Timestamp); R(ARM7Timestamp); R(ARM9Target); R(ARM7Target);
    R(FrameStartTimestamp); R(LastSysClockCycles); R(SchedListMask); R(CPUStop);
    R(ARM9ClockShift); R(CurCPU);
#undef R
    j.values("TimerTimestamp", n.TimerTimestamp); j.values("TimerCheckMask", n.TimerCheckMask);
    j.array("events");
    for (unsigned i = 0; i < Event_MAX; i++) {
        const auto& e = n.SchedList[i]; j.object(); j.number("index", i);
        j.number("Timestamp", e.Timestamp); j.number("FuncID", e.FuncID); j.number("Param", e.Param);
        j.number("enabled", (n.SchedListMask >> i) & 1); j.endObject();
    }
    j.endArray(); j.endObject();
    j.array("timers");
    for (const auto& t : n.Timers) {
        j.object(); j.number("Reload", t.Reload); j.number("Cnt", t.Cnt);
        j.number("Counter", t.Counter); j.number("CycleShift", t.CycleShift); j.endObject();
    }
    j.endArray();
    j.object("irq_ipc");
#define A(field) j.values(#field, n.field)
    A(IME); A(IE); A(IF);
#undef A
    j.number("IE2", n.IE2); j.number("IF2", n.IF2);
    j.number("IPCSync9", n.IPCSync9); j.number("IPCSync7", n.IPCSync7);
    j.number("IPCFIFOCnt9", n.IPCFIFOCnt9); j.number("IPCFIFOCnt7", n.IPCFIFOCnt7);
    j.array("fifo9"); for (u32 i=0;i<n.IPCFIFO9.Level();i++) j.number(nullptr,n.IPCFIFO9.Peek(i)); j.endArray();
    j.array("fifo7"); for (u32 i=0;i<n.IPCFIFO7.Level();i++) j.number(nullptr,n.IPCFIFO7.Peek(i)); j.endArray();
    j.endObject();
    j.array("dma");
    for (const auto& d : n.DMAs) {
        j.object();
#define D(field) j.number(#field, d.field)
        D(SrcAddr); D(DstAddr); D(Cnt); D(StartMode); D(CurSrcAddr); D(CurDstAddr);
        D(RemCount); D(IterCount); D(SrcAddrInc); D(DstAddrInc); D(CountMask);
        D(Running); D(InProgress); D(Executing); D(Stall); D(IsGXFIFODMA); D(MRAMBurstCount);
#undef D
        j.values("MRAMBurstTable", d.MRAMBurstTable); j.endObject();
    }
    j.endArray();
    const auto& s = n.SPU; j.object("spu");
#define S(field) j.number(#field, s.field)
    S(Cnt); S(MasterVolume); S(Bias); S(MixInterval); S(Mute);
#undef S
    j.values("OutputLastSamples", s.OutputLastSamples); j.array("channels");
    for (const auto& ch : s.Channels) {
        j.object();
#define C(field) j.number(#field, ch.field)
        C(Cnt); C(SrcAddr); C(TimerReload); C(LoopPos); C(Length); C(Volume);
        C(VolumeShift); C(Pan); C(KeyOn); C(Timer); C(Pos); C(CurSample); C(NoiseVal);
        C(ADPCMVal); C(ADPCMIndex); C(ADPCMValLoop); C(ADPCMIndexLoop); C(ADPCMCurByte);
        C(FIFOReadPos); C(FIFOWritePos); C(FIFOReadOffset); C(FIFOLevel);
#undef C
        j.values("PrevSample", ch.PrevSample); j.values("FIFO", ch.FIFO); j.endObject();
    }
    j.endArray(); j.array("capture");
    for (const auto& c : s.Capture) {
        j.object();
#define C(field) j.number(#field, c.field)
        C(Cnt); C(DstAddr); C(TimerReload); C(Length); C(Timer); C(Pos);
        C(FIFOReadPos); C(FIFOWritePos); C(FIFOWriteOffset); C(FIFOLevel);
#undef C
        j.values("FIFO", c.FIFO); j.endObject();
    }
    j.endArray(); j.endObject();
    const auto& g = n.GPU; j.object("display");
#define G(field) j.number(#field, g.field)
    G(VCount); G(NextVCount); G(TotalScanlines); G(VCountOverride); G(CaptureCnt); G(CaptureEnable);
    G(DispFIFOReadPtr); G(DispFIFOWritePtr);
#undef G
    j.values("DispStat", g.DispStat); j.values("VMatch", g.VMatch);
    j.values("DispFIFO", g.DispFIFO); j.values("DispFIFOBuffer", g.DispFIFOBuffer);
    j.array("engines");
    for (const auto* e : {&g.GPU2D_A, &g.GPU2D_B}) {
        j.object(); j.values("BGXPos", e->BGXPos); j.values("BGYPos", e->BGYPos);
        j.values("BGXRefInternal", e->BGXRefInternal); j.values("BGYRefInternal", e->BGYRefInternal);
        j.number("BGMosaicY",e->BGMosaicY); j.number("BGMosaicYMax",e->BGMosaicYMax);
        j.number("BGMosaicLatch",e->BGMosaicLatch); j.number("BGMosaicLine",e->BGMosaicLine); j.endObject();
    }
    j.endArray(); j.endObject(); j.endObject(); fputc('\n',f);
    const bool ok = !ferror(f); if (fclose(f) || !ok) { fprintf(stderr,"runtime export write failed\n"); exit(1); }
}
} // namespace
