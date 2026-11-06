// Supplemental host observation only. No guest API calls or state writes.
#include <array>
struct SoundEpochClock {
    u64 sys,a9,a7,timer_ts[2],frame_start,next_spu;
    u32 shift,mask,spu_func,spu_param,mix_interval;
    std::array<u32,16> timers; // raw Reload,Cnt,Counter,CycleShift for0,1,4,5
    bool operator==(const SoundEpochClock&) const = default;
};
struct SoundEpochMix {
    u64 serial=0,sys=0,a9=0,a7=0,scheduled=0;
    u32 param=0,interval=0;
};
static SoundEpochMix soundEpochPreviousMix,soundEpochLastMix;
static SoundEpochClock soundEpochBefore;
static bool soundEpochPending=false;
static std::string soundEpochPendingDir;
static SoundEpochClock SoundEpochCapture()
{
    SoundEpochClock x{};
    x.sys=nds->SysTimestamp;x.a9=nds->ARM9Timestamp;x.a7=nds->ARM7Timestamp;
    x.timer_ts[0]=nds->TimerTimestamp[0];x.timer_ts[1]=nds->TimerTimestamp[1];
    x.frame_start=nds->FrameStartTimestamp;x.shift=nds->ARM9ClockShift;
    const auto&e=nds->SchedList[Event_SPU];x.next_spu=e.Timestamp;
    x.mask=(nds->SchedListMask>>Event_SPU)&1;x.spu_func=e.FuncID;x.spu_param=e.Param;
    x.mix_interval=nds->SPU.MixInterval;
    unsigned k=0;
    for(unsigned i:{0u,1u,4u,5u}){
        const auto&t=nds->Timers[i];x.timers[k++]=t.Reload;x.timers[k++]=t.Cnt;
        x.timers[k++]=t.Counter;x.timers[k++]=t.CycleShift;
    }
    return x;
}
static void SoundEpochObserveMix(SPU&s)
{
    soundEpochPreviousMix=soundEpochLastMix;
    soundEpochLastMix={soundEpochLastMix.serial+1,nds->SysTimestamp,
        nds->ARM9Timestamp,nds->ARM7Timestamp,nds->SchedList[Event_SPU].Timestamp,
        nds->SchedList[Event_SPU].Param,s.MixInterval};
}
static void SoundEpochBegin(u32 command)
{
    if(command==7684)soundEpochBefore=SoundEpochCapture();
}
static void SoundEpochPrintMix(FILE*f,const char*name,const SoundEpochMix&m)
{
    fprintf(f,"\"%s\":{\"serial\":%llu,\"SysTimestamp\":%llu,\"ARM9Timestamp\":%llu,\"ARM7Timestamp\":%llu,\"scheduled\":%llu,\"param\":%u,\"interval\":%u}",name,
        (unsigned long long)m.serial,(unsigned long long)m.sys,(unsigned long long)m.a9,
        (unsigned long long)m.a7,(unsigned long long)m.scheduled,m.param,m.interval);
}
static void SoundEpochWrite(const std::string&dir,u32 pc)
{
    const auto x=SoundEpochCapture();
    FILE*f=fopen((dir+"/epoch.json").c_str(),"wb");if(!f)exit(2);
    u32 cmd,n;memcpy(&cmd,nds->MainRAM+0x3cc2c4,4);memcpy(&n,nds->MainRAM+0x3cc2c8,4);
    fprintf(f,"{\"schema_version\":1,\"command\":%u,\"stress\":0,\"retired_pc\":%u,\"prefetch_r15\":%u,\"frame\":%u,\"line\":%u,\"out_n\":%u,\"source_unchanged_by_original_export\":true,",cmd,pc,nds->ARM7.R[15],curFrame,nds->GPU.VCount,n);
    fprintf(f,"\"clock\":{\"SysTimestamp\":%llu,\"ARM9Timestamp\":%llu,\"ARM7Timestamp\":%llu,\"TimerTimestamp\":[%llu,%llu],\"FrameStartTimestamp\":%llu,\"ARM9ClockShift\":%u},",
        (unsigned long long)x.sys,(unsigned long long)x.a9,(unsigned long long)x.a7,
        (unsigned long long)x.timer_ts[0],(unsigned long long)x.timer_ts[1],(unsigned long long)x.frame_start,x.shift);
    fprintf(f,"\"spu_event\":{\"index\":%u,\"scheduled\":%llu,\"enabled\":%u,\"func\":%u,\"param\":%u,\"mix_interval\":%u},\"timers\":[",Event_SPU,(unsigned long long)x.next_spu,x.mask,x.spu_func,x.spu_param,x.mix_interval);
    for(unsigned i=0;i<4;i++)fprintf(f,"%s{\"index\":%u,\"Reload\":%u,\"Cnt\":%u,\"Counter\":%u,\"CycleShift\":%u}",i?",":"",i<2?i:i+2,x.timers[i*4],x.timers[i*4+1],x.timers[i*4+2],x.timers[i*4+3]);
    fprintf(f,"],");SoundEpochPrintMix(f,"previous_mix",soundEpochPreviousMix);fprintf(f,",");SoundEpochPrintMix(f,"last_mix",soundEpochLastMix);fprintf(f,"}\n");fclose(f);
}
static void SoundEpochFinish(const std::string&dir,u32 command,u32 pc)
{
    if(command!=7684)return;
    if(!(soundEpochBefore==SoundEpochCapture())){
        fprintf(stderr,"SOUND_EPOCH_ORIGINAL_EXPORT_CHANGED_SOURCE\n");exit(2);
    }
#ifdef SOUND_EPOCH_WRONG_BOUNDARY
    soundEpochPending=true;soundEpochPendingDir=dir;
#else
    SoundEpochWrite(dir,pc);
#endif
}
static void SoundEpochLateRetire(int cpu,u32 pc)
{
#ifdef SOUND_EPOCH_WRONG_BOUNDARY
    if(cpu==1 && soundEpochPending){soundEpochPending=false;SoundEpochWrite(soundEpochPendingDir,pc);}
#endif
}
