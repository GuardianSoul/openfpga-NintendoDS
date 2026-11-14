// Reuse the existing actual-memory/VRAM/job harness. This entry point adds
// complete capture output and terminal memory/loaded-state comparisons.
#define main general_gpu2d_main
#include "../tb_gpu2d.cpp"
#undef main
#include <fstream>
#include <stdexcept>
static void save(const std::string& name,const void* data,size_t size) {
    std::ofstream f(name,std::ios::binary);f.write((const char*)data,size);
    if(!f)throw std::runtime_error("output: "+name);
}
int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    const char* dest=getenv("OBJWORK_OUT");if(!dest)return 2;
    bool failed=false;
    for(const auto& seg:builtin_scenes()) {
        auto gm=std::make_unique<Mem>(*seg.mem0),rm=std::make_unique<Mem>(*seg.mem0);
        Golden gold;gold.set_mem(*gm);Rtl rtl;rtl.vm=rm.get();
        rtl.jitter=getenv("OBJWORK_JITTER")?atoi(getenv("OBJWORK_JITTER")):0;
        std::vector<u16> raw[2]={std::vector<u16>(49152),std::vector<u16>(49152)};
        std::vector<unsigned> seen[2]={std::vector<unsigned>(49152),std::vector<unsigned>(49152)};
        std::vector<u32> display[2]={std::vector<u32>(),std::vector<u32>()};
        u64 pixels=0,bad=0,capbad=0,statebad=0;u32 bgmax=0,objmax=0;
        for(size_t i=0;i<seg.steps.size();i++) {
            const auto& sp=seg.steps[i];const auto& s=sp.st;
            apply(*gm,sp.mem);apply(*rm,sp.mem);rtl.load(s);
            u32 bgc,objc;
            if(!i){gold.sprites(s,s.line);rtl.run(-1,s.line,bgc,objc);}
            LineOut go;gold.scanline(s,go);
            if(s.line<191)gold.sprites(s,s.line+1);
            rtl.run(s.line,s.line<191?int(s.line)+1:-1,bgc,objc);
            bgmax=std::max(bgmax,bgc);objmax=std::max(objmax,objc);
            for(int e=0;e<2;e++)for(int x=0;x<256;x++) {
                pixels++;bad+=!rtl.got[e][x]||rtl.px[e][x]!=go.px[e][x];
                display[0].push_back(rtl.px[e][x]);display[1].push_back(go.px[e][x]);
            }
            bool same=go.cap.size()==rtl.cap.size();
            for(size_t k=0;same&&k<go.cap.size();k++)same=go.cap[k].addr==rtl.cap[k].addr&&go.cap[k].data==rtl.cap[k].data;
            capbad+=!same;
            for(int kind=0;kind<2;kind++)for(auto c:kind?go.cap:rtl.cap) {
                if((c.addr>>16)!=3||(c.addr&65535)>=49152)throw std::runtime_error("capture address");
                raw[kind][c.addr&65535]=c.data;seen[kind][c.addr&65535]++;
            }
            statebad+=rtl.m->bg_busy||rtl.m->obj_busy;
            statebad+=memcmp(rtl.pal.data(),rm->palette,2048)!=0;
            statebad+=memcmp(rtl.oam.data(),rm->oam,2048)!=0;
            for(int e=0;e<2;e++) {
                u32 w[22];Rtl::words(s.e[e],w);
                statebad+=memcmp(w,rtl.stw[e],20*sizeof(u32))!=0;
            }
            statebad+=rtl.glob[0]!=s.capcnt||rtl.glob[1]!=(u32(s.lcdc&15)|u32(s.cap_enable&1)<<4);
        }
        unsigned unique[2]={0,0};for(int k=0;k<2;k++)for(auto n:seen[k])unique[k]+=n==1;
        const bool memory_equal=memcmp(gm.get(),rm.get(),sizeof(Mem))==0;
        printf("OBJWORK %s pixels=%llu rgbdiff=%llu capdiff=%llu statebad=%llu memory_equal=%d unique=%u/%u bgmax=%u objmax=%u\n",
          seg.name.c_str(),(unsigned long long)pixels,(unsigned long long)bad,(unsigned long long)capbad,
          (unsigned long long)statebad,memory_equal,unique[0],unique[1],bgmax,objmax);fflush(stdout);
        const std::string base=std::string(dest)+"/"+seg.name;
        for(int k=0;k<2;k++) {
            save(base+(k?"-gold.bin":"-rtl.bin"),raw[k].data(),raw[k].size()*2);
            save(base+(k?"-gold-rgb.bin":"-rtl-rgb.bin"),display[k].data(),display[k].size()*4);
        }
        failed|=bad||capbad||statebad||!memory_equal||unique[0]!=49152||unique[1]!=49152;
    }
    return failed?1:0;
}
