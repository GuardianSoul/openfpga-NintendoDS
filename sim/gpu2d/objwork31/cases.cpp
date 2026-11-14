// Stable input replay only; the DS raw16 frame is an independent oracle.
#include "golden2d.h"
#include <fstream>
#include <stdexcept>
namespace g2d {
std::vector<Segment> run38_scenes();
static void read(const std::string& path, void* dst, size_t bytes) {
    std::ifstream f(path, std::ios::binary);
    if (!f.read((char*)dst, bytes) || f.peek()!=EOF)
        throw std::runtime_error("input length: "+path);
}
static Segment probe(const std::string& root, int run, int k) {
    const std::string prefix=run==39?"objlimit_v2":"objwork_v1";
    const std::string base=root+"/run"+std::to_string(run)+"/"+prefix;
    Segment seg; seg.name="run"+std::to_string(run)+"-k"+std::to_string(k);
    seg.mem0=std::make_shared<Mem>(); memset(seg.mem0.get(),0,sizeof(Mem));
    Mem& m=*seg.mem0;
    read(base+"_pal.bin",m.palette,1024);
    read(base+"_bg.bin",m.abg,65536);
    read(base+"_obj.bin",m.aobj,run==39?8192:24576);
    read(base+"_k"+std::to_string(k)+"_oam.bin",m.oam,1024);
    Sequencer seq;
    seq.write32(0,0,0x11f00); seq.write32(1,0,0x10080);
    for (int b=0;b<4;b++) {
        seq.write16(0,8+b*2,0x80|((28+b)<<8)|b);
        // Write-only offsets are the pinned producer values, not readbacks.
        seq.write16(0,0x10+b*4,b*13); seq.write16(0,0x12+b*4,b*7);
    }
    seq.write16(0,0x50,0x241);seq.write16(0,0x52,0x808);
    for (u32 y=256;y<262;y++){LineState warm{};seq.line(y,warm,{});}
    seq.vblank_end();
    for (u32 y=0;y<192;y++) {
        Step sp{};sp.st.capcnt=0x80330000;sp.st.cap_enable=1;sp.st.lcdc=8;
        seq.line(y,sp.st,{});seg.steps.push_back(sp);
    }
    return seg;
}
std::vector<Segment> builtin_scenes() {
    const char* env=getenv("OBJWORK_INPUTS");
    if (!env) throw std::runtime_error("OBJWORK_INPUTS required");
    auto out=run38_scenes();
    for(int run:{39,40})for(int k=0;k<(run==39?6:8);k++)out.push_back(probe(env,run,k));
    return out;
}
}
