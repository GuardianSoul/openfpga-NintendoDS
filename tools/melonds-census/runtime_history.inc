// Exact bounded physical write observation. This frontend subclass uses only
// NDS's existing virtual methods and has no data members. The immutable core
// and its ABI remain unchanged; each override calls its qualified base once.
namespace {
struct HistoryIntent {
    u64 id=0, time=0; int cpu=-1, source=-1, dma=-1; u32 address=0,value=0,bytes=0,pc_r15=0,cpsr=0;
};
struct HistoryRecord {
    u64 order=0,time=0,sys=0,domain_raw=0,intent=0; int cpu=-1,source=-1,dma=-1;
    u32 address=0,value=0,bytes=0,pc_r15=0,cpsr=0; const char* kind="";const char* region="";
    u32 offset=0;std::vector<u8> old_bytes,new_bytes;
};
static u64 historyUntil=0, historyStart=0, historyOrder=0, historyBegan=0, historyInitialSPU=0;
static u32 historyWindow=0;static bool historyOn=false,historyExported=false;
static HistoryIntent historyIntent[2],historyCapture;
static std::vector<HistoryRecord> historyRecords;
static u64 historyChecked=0;
struct PendingTCM { size_t index;const u8* memory; };
static std::vector<PendingTCM> historyPendingTCM;
static u64 DomainTime(const NDS& n,int cpu) { return cpu==0 ? n.ARM9Timestamp>>n.ARM9ClockShift : n.ARM7Timestamp; }
static bool HistoryInWindow(u64 t) { return historyOn && t>=historyStart && t<=historyUntil; }
static void HistoryPush(HistoryRecord r) {
    if(!HistoryInWindow(r.time))return;
    if(historyRecords.size()>=8192){fprintf(stderr,"RUNTIME_HISTORY overflow\n");exit(1);}
    r.order=++historyOrder;historyRecords.push_back(std::move(r));
}
static u8* HistoryRAM(NDS& n,int cpu,u32 a,const char*& region,u32& offset) {
    if((a&0xFF000000)==0x02000000){region="main";offset=a&n.MainRAMMask;return n.MainRAM+offset;}
    if((a&0xFF800000)==0x03000000){
        auto& map=cpu==0?n.SWRAM_ARM9:n.SWRAM_ARM7;
        if(map.Mem){region="swram";offset=u32(map.Mem-n.SharedWRAM)+(a&map.Mask);return map.Mem+(a&map.Mask);}
        if(cpu==1){region="wram7";offset=a&(n.ARM7WRAMSize-1);return n.ARM7WRAM+offset;}
    }
    if(cpu==1&&(a&0xFF800000)==0x03800000){region="wram7";offset=a&(n.ARM7WRAMSize-1);return n.ARM7WRAM+offset;}
    if(cpu==0&&(a&0xFF000000)==0x05000000){region="palette";offset=a&0x7FF;return n.GPU.Palette+offset;}
    if(cpu==0&&(a&0xFF000000)==0x07000000){region="oam";offset=a&0x7FF;return n.GPU.OAM+offset;}
    return nullptr;
}
static bool HistoryMMIOByte(const NDS& n,int cpu,u32 a,u8& result) {
    const auto& s=n.SPU;u32 value=0,base=0;
    if(a>=0x040000B0&&a<0x040000E0){
        const auto& d=n.DMAs[cpu*4+(a-0x040000B0)/12];base=a&~3u;
        switch((base-0x040000B0)%12){case 0:value=d.SrcAddr;break;case 4:value=d.DstAddr;break;case 8:value=d.Cnt;break;}
    }else if(cpu==1&&a>=0x04000400&&a<0x04000500){
        const auto& c=s.Channels[(a>>4)&15];base=a&~3u;
        switch((a>>2)&3){case 0:value=c.Cnt;break;case 1:value=c.SrcAddr;break;case 2:value=c.TimerReload|((c.LoopPos>>2)<<16);break;case 3:value=c.Length>>2;break;}
    }else if(cpu==1&&a>=0x04000500&&a<0x04000520){
        base=a&~3u;switch(base&0x1F){case 0:value=s.Cnt;break;case 4:value=s.Bias;break;case 8:value=s.Capture[0].Cnt|(u32(s.Capture[1].Cnt)<<8);break;
        case 0x10:value=s.Capture[0].DstAddr;break;case 0x14:value=s.Capture[0].Length>>2;break;case 0x18:value=s.Capture[1].DstAddr;break;case 0x1C:value=s.Capture[1].Length>>2;break;default:return false;}
    }else if(cpu==1&&(a==0x04000304||a==0x04000305)){base=0x04000304;value=n.PowerControl7;}
    else return false;
    result=u8(value>>((a-base)*8));return true;
}
static HistoryRecord HistoryPhysicalBefore(NDS& n,int cpu,u32 address,u32 value,u32 bytes) {
    HistoryRecord r;r.cpu=cpu;r.time=DomainTime(n,cpu);r.sys=n.SysTimestamp;r.domain_raw=cpu?n.ARM7Timestamp:n.ARM9Timestamp;
    r.address=address&~(bytes-1);r.value=value;r.bytes=bytes;r.kind="physical_write";
    const auto& cap=historyCapture;
    const auto& intent=historyIntent[cpu];
    if(cap.id && cap.address==r.address && cap.value==value && bytes==4){r.source=2;r.intent=cap.id;r.time=cap.time;historyCapture.id=0;}
    else if(intent.id && (intent.address&~(bytes-1))==r.address && intent.value==value && intent.bytes==bytes && intent.time==r.time){
        r.source=intent.source;r.dma=intent.dma;r.intent=intent.id;r.pc_r15=intent.pc_r15;r.cpsr=intent.cpsr;
    }
    if(!HistoryInWindow(r.time))return r;
    RuntimeSourceGuard beforeGuard(n);
    const char* region="unmapped";u32 offset=0;u8* memory=HistoryRAM(n,cpu,r.address,region,offset);
    r.region=region;r.offset=offset;
    if(memory)r.old_bytes.assign(memory,memory+bytes);
    else {for(u32 k=0;k<bytes;k++){u8 v;if(!HistoryMMIOByte(n,cpu,r.address+k,v)){r.old_bytes.clear();break;}r.old_bytes.push_back(v);}if(!r.old_bytes.empty()){r.region=r.address<0x04000400&&r.address!=0x04000304?"dma_mmio":"sound_mmio";r.offset=r.address-0x04000000;}}
    beforeGuard.verify();historyChecked++;
    return r;
}
static void HistoryPhysicalAfter(NDS& n,HistoryRecord r) {
    if(!HistoryInWindow(r.time))return;
    RuntimeSourceGuard guard(n);
    const char* region="";u32 offset=0;u8* memory=HistoryRAM(n,r.cpu,r.address,region,offset);
    if(memory)r.new_bytes.assign(memory,memory+r.bytes);
    else if(r.region==std::string("sound_mmio")||r.region==std::string("dma_mmio")){for(u32 k=0;k<r.bytes;k++){u8 v;if(!HistoryMMIOByte(n,r.cpu,r.address+k,v)){r.new_bytes.clear();break;}r.new_bytes.push_back(v);}}
    HistoryPush(std::move(r));
    guard.verify();historyChecked++;
}
class RuntimeHistoryNDS final : public NDS {
public:
    using NDS::NDS;
#define WRITE(cpu,bits,type) void ARM##cpu##Write##bits(u32 a,type v) override { \
    const int c=cpu==9?0:1; auto record=HistoryPhysicalBefore(*this,c,a,v,bits/8); \
    NDS::ARM##cpu##Write##bits(a,v); HistoryPhysicalAfter(*this,std::move(record)); }
    WRITE(9,8,u8) WRITE(9,16,u16) WRITE(9,32,u32)
    WRITE(7,8,u8) WRITE(7,16,u16) WRITE(7,32,u32)
#undef WRITE
};
static_assert(sizeof(RuntimeHistoryNDS)==sizeof(NDS),"history adds no device data/layout");
} // namespace

NDS* CreateRuntimeHistoryNDS(NDSArgs&& args){return new RuntimeHistoryNDS(std::move(args));}
void ConfigureRuntimeHistory(u64 until,u32 window){
    if(window!=1024||until<window){fprintf(stderr,"runtime history requires1024SYS and a bound epoch\n");exit(1);}
    historyUntil=until;historyWindow=window;historyStart=until-window;
}
void BeginRuntimeHistory(const NDS& n){
    historyBegan=n.SysTimestamp;historyInitialSPU=n.SchedList[Event_SPU].Timestamp;if(historyBegan>historyStart){fprintf(stderr,"runtime history begins after requested window\n");exit(1);}
    historyRecords.clear();historyOrder=0;historyOn=true;historyExported=false;
}
void RuntimeHistoryIntent(const NDS& n,int cpu,u32 src,u32 addr,u32 value,u32 bytes){
    RuntimeHistoryCompleteTCM(n);
    const auto time=DomainTime(n,cpu);if(!HistoryInWindow(time))return;
    RuntimeSourceGuard guard(n);HistoryIntent i;i.id=++historyOrder;i.time=time;i.cpu=cpu;i.source=src;i.address=addr;i.value=value;i.bytes=bytes;
    i.pc_r15=cpu?n.ARM7.R[15]:n.ARM9.R[15];i.cpsr=cpu?n.ARM7.CPSR:n.ARM9.CPSR;
    if(src==1)for(int k=0;k<4;k++)if(n.DMAs[cpu*4+k].Executing && n.DMAs[cpu*4+k].CurDstAddr==(addr&~(bytes-1)))i.dma=cpu*4+k;
    historyIntent[cpu]=i;HistoryRecord r;r.kind="intent_pre_permission";r.time=time;r.sys=n.SysTimestamp;r.domain_raw=cpu?n.ARM7Timestamp:n.ARM9Timestamp;r.cpu=cpu;r.source=src;r.dma=i.dma;r.intent=i.id;r.address=addr;r.value=value;r.bytes=bytes;r.pc_r15=i.pc_r15;r.cpsr=i.cpsr;HistoryPush(std::move(r));
    // These qualified direct stores bypass NDS's physical bus virtuals.
    // Reserve commit order now; verify actual bytes after the real instruction
    // or before its next write. No read API or device update is invoked.
    if(cpu==0 && src==0 && (n.ARM9.PU_Map[addr>>12]&2)) {
        const u32 a=addr&~(bytes-1);const u8* memory=nullptr;const char* region="";u32 offset=0;
        if(a<n.ARM9.ITCMSize){region="itcm";offset=a&(ITCMPhysicalSize-1);memory=n.ARM9.ITCM+offset;}
        else if((a&n.ARM9.DTCMMask)==n.ARM9.DTCMBase){region="dtcm";offset=a&(DTCMPhysicalSize-1);memory=n.ARM9.DTCM+offset;}
        if(memory){HistoryRecord c;c.kind="direct_tcm_write";c.time=time;c.sys=n.SysTimestamp;c.domain_raw=n.ARM9Timestamp;c.cpu=0;c.source=0;c.intent=i.id;c.address=a;c.value=value;c.bytes=bytes;c.pc_r15=i.pc_r15;c.cpsr=i.cpsr;c.region=region;c.offset=offset;c.old_bytes.assign(memory,memory+bytes);HistoryPush(std::move(c));historyPendingTCM.push_back({historyRecords.size()-1,memory});}
    }
    guard.verify();historyChecked++;
}
void RuntimeHistoryCompleteTCM(const NDS& n){
    if(historyPendingTCM.empty())return;RuntimeSourceGuard guard(n);
    for(const auto& pending:historyPendingTCM){auto& r=historyRecords[pending.index];r.new_bytes.assign(pending.memory,pending.memory+r.bytes);for(u32 k=0;k<r.bytes;k++)if(r.new_bytes[k]!=u8(r.value>>(k*8))){fprintf(stderr,"RUNTIME_HISTORY direct TCM store did not commit\n");exit(1);}}
    historyPendingTCM.clear();guard.verify();historyChecked++;
}
void RuntimeHistoryCapture(const NDS& n,u32 addr,u32 value){
    const auto t=n.SchedList[Event_SPU].Timestamp;if(!HistoryInWindow(t))return;
    RuntimeSourceGuard guard(n);historyCapture={};historyCapture.id=++historyOrder;historyCapture.time=t;historyCapture.address=addr;historyCapture.value=value;
    HistoryRecord r;r.kind="capture_intent";r.time=t;r.sys=n.SysTimestamp;r.cpu=1;r.source=2;r.intent=historyCapture.id;r.address=addr;r.value=value;r.bytes=4;HistoryPush(std::move(r));guard.verify();historyChecked++;
}
void RuntimeHistoryMix(const NDS& n,bool end){
    const auto t=n.SchedList[Event_SPU].Timestamp;
    if(!HistoryInWindow(t))return;RuntimeSourceGuard guard(n);HistoryRecord r;r.kind=end?"mix_end":"mix_begin";r.time=t;r.sys=n.SysTimestamp;HistoryPush(std::move(r));guard.verify();historyChecked++;
}
void ExportRuntimeHistory(const NDS& n,const std::string& dir,int cleanLine){
    if(!historyWindow)return;
    RuntimeHistoryCompleteTCM(n);
    if(historyExported||n.SysTimestamp!=historyUntil){fprintf(stderr,"runtime history clean epoch differs\n");exit(1);}
    RuntimeSourceGuard guard(n);FILE* f=fopen((dir+"/runtime-history.json").c_str(),"wb");if(!f)exit(1);RuntimeJson j(f);
    j.object();j.number("schema_version",1);j.number("start_SYS_inclusive",historyStart);j.number("clean_SYS_inclusive",historyUntil);j.number("recording_began_SYS",historyBegan);j.number("initial_next_SPU_SYS",historyInitialSPU);j.number("clean_line_before_processing",cleanLine);j.number("source_observation_checks",historyChecked);j.array("events");
    for(const auto& r:historyRecords){j.object();
#define F(field) j.number(#field,r.field)
        F(order);F(time);F(sys);F(domain_raw);F(intent);F(cpu);F(source);F(dma);F(address);F(value);F(bytes);F(pc_r15);F(cpsr);F(offset);
#undef F
        // These labels are constant literals, never user-provided JSON text.
        fprintf(f,",\"kind\":\"%s\",\"region\":\"%s\"",r.kind,r.region);j.values("old_bytes",r.old_bytes);j.values("new_bytes",r.new_bytes);j.endObject();
    }
    j.endArray();j.endObject();fputc('\n',f);if(fclose(f))exit(1);guard.verify();historyExported=true;historyOn=false;
}
