// Bounded host-only observation. Fields are read directly; no guest APIs run.
static FILE* soundWindow=nullptr;
static unsigned soundWindowRetires=0,soundWindowAnchor=0;
static bool soundWindowAnchored=false;
static void SoundWindowClock()
{
    const auto x=SoundEpochCapture();
    fprintf(soundWindow,"\"sys\":%llu,\"a9\":%llu,\"a7\":%llu,\"timer_ts\":[%llu,%llu],\"next_mix\":%llu,\"last_mix\":%llu,\"last_mix_serial\":%llu,\"timer_raw\":[",
        (unsigned long long)x.sys,(unsigned long long)x.a9,(unsigned long long)x.a7,
        (unsigned long long)x.timer_ts[0],(unsigned long long)x.timer_ts[1],
        (unsigned long long)x.next_spu,(unsigned long long)soundEpochLastMix.scheduled,
        (unsigned long long)soundEpochLastMix.serial);
    for(unsigned i=0;i<x.timers.size();i++)fprintf(soundWindow,"%s%u",i?",":"",x.timers[i]);
    fprintf(soundWindow,"]");
}
static void SoundWindowBegin(const std::string&dir,u32 command,u32 pc)
{
    if(command!=7684)return;
    soundWindow=fopen((dir+"/window.jsonl").c_str(),"wb");if(!soundWindow)exit(2);
    fprintf(soundWindow,"{\"kind\":\"entry\",\"pc\":%u,",pc);SoundWindowClock();fprintf(soundWindow,"}\n");
}
static void SoundWindowRetire(int cpu,u32 pc,const u32*r,u32 cpsr)
{
    if(!soundWindow || cpu!=1)return;
    // The entry's own retirement is included and identified separately.
    ++soundWindowRetires;
    if(pc==0x037f80dc && !soundWindowAnchored){soundWindowAnchored=true;soundWindowAnchor=soundWindowRetires;}
    fprintf(soundWindow,"{\"kind\":\"retire\",\"index\":%u,\"pc\":%u,\"prefetch_r15\":%u,\"instruction\":%u,\"cpsr\":%u,\"r\":[",
        soundWindowRetires,pc,nds->ARM7.R[15],nds->ARM7.CurInstr,cpsr);
    for(unsigned i=0;i<15;i++)fprintf(soundWindow,"%s%u",i?",":"",r[i]);
    fprintf(soundWindow,"],");SoundWindowClock();fprintf(soundWindow,"}\n");
    if(soundWindowAnchored && soundWindowRetires==soundWindowAnchor+256){
        fprintf(soundWindow,"{\"kind\":\"end\",\"reason\":\"first80dc_plus256\",\"retirements\":%u,\"anchor_index\":%u,",soundWindowRetires,soundWindowAnchor);
        SoundWindowClock();fprintf(soundWindow,"}\n");fclose(soundWindow);soundWindow=nullptr;
    }else if(soundWindowRetires>=4096){fprintf(stderr,"SOUND_WINDOW_ANCHOR_MISSING\n");exit(2);}
}
static void SoundWindowMem(int cpu,u32 kind,u32 addr,u32 bits)
{
    if(!soundWindow || cpu!=1 || addr<0x04000100 || addr>=0x04000110)return;
    fprintf(soundWindow,"{\"kind\":\"timer_access_before\",\"access\":%u,\"address\":%u,\"bits\":%u,\"prefetch_r15\":%u,",kind,addr,bits,nds->ARM7.R[15]);
    SoundWindowClock();fprintf(soundWindow,"}\n");
}
static void SoundWindowWrite(int cpu,u32 src,u32 addr,u32 val,u32 bytes)
{
    if(!soundWindow || cpu!=1)return;
    fprintf(soundWindow,"{\"kind\":\"data_write_before\",\"source\":%u,\"address\":%u,\"value\":%u,\"bytes\":%u,\"prefetch_r15\":%u,",src,addr,val,bytes,nds->ARM7.R[15]);
    SoundWindowClock();fprintf(soundWindow,"}\n");
}
static void SoundWindowMix()
{
    if(!soundWindow)return;
    fprintf(soundWindow,"{\"kind\":\"mix_callback\",\"param\":%u,\"interval\":%u,",soundEpochLastMix.param,soundEpochLastMix.interval);
    SoundWindowClock();fprintf(soundWindow,"}\n");
}
static void SoundWindowSPUWrite(u32 bits,u32 addr,u32 val)
{
    if(!soundWindow)return;
    fprintf(soundWindow,"{\"kind\":\"spu_write_callback\",\"address\":%u,\"value\":%u,\"bits\":%u,",addr,val,bits);
    SoundWindowClock();fprintf(soundWindow,"}\n");
}
