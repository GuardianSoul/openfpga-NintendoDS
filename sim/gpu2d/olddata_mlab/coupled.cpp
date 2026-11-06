// Paired pre-change/current complete 2D engines. Reuses the native testbench
// port driver and queued VRAM model; no emulator/golden renderer is linked.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <deque>
#include <map>
#include <string>
#include <vector>
#include "Vtb_od_2d.h"
#include "verilated.h"
#include "state2d.h"


using namespace g2d;

namespace g2d { std::vector<Segment> builtin_scenes(); }

static const u32 ENG_LINE = 2130;      // clocks per engine-line at 67.03 MHz

struct Rtl
{
    VerilatedContext ctx;
    Vtb_od_2d* m;
    bool oam_pending=false;unsigned oam_addr=0;
    u64 cyc = 0;
    Mem* vm = nullptr;                  // the RTL's own memory image
    const LineState* cur = nullptr;
    int lat = 13, dcyc = 16, maxq = 2;
    // --jitter N: each block waits a further 0..N clocks, and 1 in 16 blocks
    // 30..45 more (refresh, other clients: bursts of 40-60 clocks per block)
    int jitter = 0;
    u32 jrng = 12345;
    u32 jnext() { jrng ^= jrng << 13; jrng ^= jrng >> 17; jrng ^= jrng << 5; return jrng; }
    // VRAM block model: accepted blocks with their beat times
    struct VReq { u32 blk; u64 beat[4]; int next = 0; };
    std::deque<VReq> vq;
    u64 vend = 0;                       // end of the last scheduled block's data
    int vstate = 0;                     // for the timeout message: blocks in flight
    u64 fills = 0;
    // loaded copies
    std::vector<u8> pal, oam;
    u32 stw[2][22];
    u32 glob[2];
    bool loaded = false;
    // outputs of the current line
    u32 px[2][256];
    bool got[2][256];
    std::vector<CapWrite> cap;
    u64 bg_stall = 0, obj_stall = 0;

    Rtl() : pal(2048), oam(2048)
    {
        ctx.threads(1);m=new Vtb_od_2d{&ctx};
        m->clk = 0; m->rst = 1; m->eval();
        for (int i = 0; i < 4; i++) tick();
        m->rst = 0;
        memset(stw, 0, sizeof(stw));
    }
    ~Rtl() { m->final(); delete m; }

    const u8* vptr(u32 blk)
    {
        u32 sp = blk >> 15, e = (blk >> 14) & 1, off = (blk & 0x3FFF) << 5;
        switch (sp)
        {
        case 0: return e ? &vm->bbg[off & 0x1FFFF] : &vm->abg[off & 0x7FFFF];
        case 1: return e ? &vm->bobj[off & 0x1FFFF] : &vm->aobj[off & 0x3FFFF];
        case 2: return e ? &vm->bbgext[off & 0x7FFF] : &vm->abgext[off & 0x7FFF];
        case 3: return e ? &vm->bobjext[off & 0x1FFF] : &vm->aobjext[off & 0x1FFF];
        default: return &vm->lcdc[(off >> 17) & 3][off & 0x1FFFF];
        }
    }

    void tick()
    {
        if(!oam_pending&&cyc%29==0)oam_pending=true;
        m->oam_cre=oam_pending;m->oam_cra=oam_addr;
        ctx.timeInc(1);m->clk = 0; m->eval();
        // inputs for this cycle
        m->vr_ack = m->vr_req && (int)vq.size() < maxq;
        bool beat = !vq.empty() && vq.front().beat[vq.front().next] == cyc;
        m->vr_rvalid = beat;
        if (beat) { u64 w; memcpy(&w, vptr(vq.front().blk) + vq.front().next * 8, 8); m->vr_rdata = w; }
        m->cap_ready = cyc%9!=0;
        m->eval();
        // sample at the edge
        bool acc = m->vr_req && m->vr_ack;
        u32 blk = m->vr_blk;
        if (m->out_valid)
        {
            px[m->out_eng][m->out_x] = (m->out_rgb & 0x3F) | (((m->out_rgb >> 6) & 0x3F) << 8) | (((m->out_rgb >> 12) & 0x3F) << 16);
            got[m->out_eng][m->out_x] = true;
        }
        if (m->cap_we && m->cap_ready)
        {
            u32 a = m->cap_addr;
            cap.push_back({a, (u16)m->cap_data});
            memcpy(&vm->lcdc[a >> 16][(a & 0xFFFF) * 2], &m->cap_data, 2);
        }
        bg_stall += m->stat_bg_stall;
        obj_stall += m->stat_obj_stall;
        u32 l3a = m->l3d_raddr, ffa = m->fifo_raddr;
        bool cpu_gnt=m->oam_cgnt;
        ctx.timeInc(1);m->clk = 1; m->eval();
        if(cpu_gnt){oam_pending=false;oam_addr=(oam_addr+17)&511;}
        cyc++;
        m->l3d_rdata = cur ? cur->l3d[l3a] : 0;
        m->fifo_rdata = cur ? cur->fifo[ffa] : 0;
        // VRAM model state
        if (beat && ++vq.front().next == 4) vq.pop_front();
        if (acc)
        {
            VReq r; r.blk = blk;
            u64 extra = 0;
            if (jitter) { extra = jnext() % (jitter + 1); if (jnext() % 16 == 0) extra += 30 + jnext() % 16; }
            u64 st = std::max<u64>(cyc + lat + extra, vend);
            for (int k = 0; k < 4; k++) r.beat[k] = st + (u64)(k + 1) * dcyc / 4;   // dcyc >= 4
            vend = st + dcyc;
            vq.push_back(r);
            fills++;
        }
        vstate = vq.size();
    }

    static void words(const EngState& e, u32* w)
    {
        w[0] = e.dispcnt;
        w[1] = e.bgcnt[0] | (u32)e.bgcnt[1] << 16;
        w[2] = e.bgcnt[2] | (u32)e.bgcnt[3] << 16;
        for (int i = 0; i < 4; i++) w[3 + i] = e.bgxpos[i] | (u32)e.bgypos[i] << 16;
        w[7] = e.xref[0]; w[8] = e.yref[0]; w[9] = e.xref[1]; w[10] = e.yref[1];
        w[11] = (u16)e.rota[0] | (u32)(u16)e.rotc[0] << 16;
        w[12] = (u16)e.rota[1] | (u32)(u16)e.rotc[1] << 16;
        memcpy(&w[13], e.win0, 4); memcpy(&w[14], e.win1, 4); memcpy(&w[15], e.wincnt, 4);
        w[16] = (e.enabled & 1) | (e.forced_blank & 1) << 1 | (e.obj_enable & 1) << 2 | (e.layer_enable & 0x1F) << 3
              | (e.win0_active & 3) << 8 | (e.win1_active & 3) << 10 | (e.bg_mosaic[0] & 15) << 12 | (e.obj_mosaic[0] & 15) << 16;
        w[17] = (e.bg_mosaic_line & 0x1FF) | (e.obj_mosaic_line & 0xFF) << 16;
        w[18] = (e.blendcnt & 0x3FFF) | (u32)(e.eva & 31) << 16 | (u32)(e.evb & 31) << 24;
        w[19] = (e.evy & 31) | (u32)e.master_bright << 16;
        w[20] = w[21] = 0;
    }

    void wstate(int eng, int a, u32 d)
    {
        m->st_we = 1; m->st_eng = eng; m->st_addr = a; m->st_data = d;
        tick();
        m->st_we = 0;
    }

    // Load memory and state for a line (both units idle).
    void load(const LineState& s)
    {
        cur = &s;
        for (int i = 0; i < 512; i++)
        {
            if (loaded && !memcmp(&pal[i * 4], &vm->palette[i * 4], 4)) continue;
            memcpy(&pal[i * 4], &vm->palette[i * 4], 4);
            u32 w; memcpy(&w, &pal[i * 4], 4);
            m->pal_we = 1; m->pal_waddr = i; m->pal_wdata = w; m->pal_be = 0xF; tick(); m->pal_we = 0;
        }
        for (int i = 0; i < 512; i++)
        {
            if (loaded && !memcmp(&oam[i * 4], &vm->oam[i * 4], 4)) continue;
            memcpy(&oam[i * 4], &vm->oam[i * 4], 4);
            u32 w; memcpy(&w, &oam[i * 4], 4);
            m->oam_we = 1; m->oam_waddr = i; m->oam_wdata = w; m->oam_be = 0xF; tick(); m->oam_we = 0;
        }
        for (int e = 0; e < 2; e++)
        {
            u32 w[22]; words(s.e[e], w);
            for (int a = 0; a < 20; a++)
                if (!loaded || w[a] != stw[e][a]) { wstate(e, a, w[a]); stw[e][a] = w[a]; }
        }
        u32 g[2] = {s.capcnt, (u32)(s.lcdc & 15) | (u32)(s.cap_enable & 1) << 4};
        for (int a = 0; a < 2; a++)
            if (!loaded || g[a] != glob[a]) { wstate(0, 20 + a, g[a]); glob[a] = g[a]; }
        loaded = true;
    }

    // Run OBJ jobs (eng 0 then 1) for `objline` and, if bgline >= 0, BG jobs for
    // bgline beside them. Returns the clocks of each unit.
    void run(int bgline, int objline, u32& bgc, u32& objc)
    {
        int bgq = bgline >= 0 ? 0 : 2, objq = objline >= 0 ? 0 : 2;
        bool bgrun = false, objrun = false;
        u64 t0 = cyc, bgend = cyc, objend = cyc;
        memset(got, 0, sizeof(got));
        cap.clear();
        u64 limit = cyc + 200000;
        while ((bgq < 2 || bgrun || objq < 2 || objrun) && cyc < limit)
        {
            m->bg_start = 0; m->obj_start = 0;
            if (!bgrun && bgq < 2)
            {
                m->bg_start = 1; m->bg_eng = bgq; m->bg_line = bgline; m->bg_slot = bgline & 1;
                bgrun = true; bgq++;
            }
            if (!objrun && objq < 2)
            {
                m->obj_start = 1; m->obj_eng = objq; m->obj_line = objline; m->obj_slot = objline & 1;
                objrun = true; objq++;
            }
            tick();
            m->bg_start = 0; m->obj_start = 0;
            if (bgrun && m->bg_done) { bgrun = false; bgend = cyc; }
            if (objrun && m->obj_done) { objrun = false; objend = cyc; }
        }
        if (cyc >= limit)
        {
            fprintf(stderr, "timeout at cycle %llu: bg busy %d (line %d) obj busy %d (line %d) vr_req %d vstate %d stalls bg %d obj %d\n",
                    (unsigned long long)cyc, m->bg_busy, bgline, m->obj_busy, objline, m->vr_req, vstate,
                    m->stat_bg_stall, m->stat_obj_stall);
            exit(3);
        }
        bgc = bgend - t0; objc = objend - t0;
    }
};
#include <filesystem>
#include <stdexcept>
int main(int argc,char**argv){
    auto mem=std::make_unique<Mem>();memset(mem.get(),0,sizeof(Mem));
    uint32_t rng=0xa37d26e9;auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    for(size_t i=0;i<sizeof(Mem);++i)reinterpret_cast<uint8_t*>(mem.get())[i]=uint8_t(random());
    Rtl rtl;rtl.ctx.commandArgs(argc,argv);rtl.vm=mem.get();LineState st{};
    uint64_t pixels=0,captures=0;uint32_t maxbg=0,maxobj=0,latebg=0,lateobj=0;
    auto put16=[&](unsigned off,uint16_t v){memcpy(mem->oam+off,&v,2);};
    for(unsigned scene=0;scene<48;++scene){
        st.line=scene;st.frame=0;st.capcnt=scene%4==0?(1u<<31)|(3u<<20):0;st.cap_enable=scene%4==0;st.lcdc=15;
        for(unsigned x=0;x<256;++x){st.l3d[x]=(random()&0x1f3f3f3f);st.fifo[x]=uint16_t(random());}
        for(unsigned e=0;e<2;++e){auto&g=st.e[e];memset(&g,0,sizeof(g));g.enabled=1;g.obj_enable=1;g.layer_enable=31;
            g.dispcnt=(1u<<16)|(15u<<8)|(1u<<12)|(1u<<4)|(scene%6);
            for(unsigned k=0;k<4;++k){g.bgcnt[k]=uint16_t((k&3)|((k*2)<<2)|(1u<<7)|((16+3*k)<<8)|((scene%4)<<14));g.bgxpos[k]=scene*7+k;g.bgypos[k]=scene;}
            for(unsigned k=0;k<2;++k){g.rota[k]=0x100+(scene&3);g.rotc[k]=(scene&1)?7:0;g.xref[k]=scene*71;g.yref[k]=scene*256;}
            g.eva=8;g.evb=8;g.evy=scene%17;g.blendcnt=(scene%3)?0x3f40:0;g.master_bright=(scene%9==0)?0x4008:0;
            g.bg_mosaic[0]=g.obj_mosaic[0]=scene%4;g.bg_mosaic[1]=g.obj_mosaic[1]=scene%3;g.bg_mosaic_line=scene;g.obj_mosaic_line=scene;
            for(unsigned i=0;i<128;++i){bool active=scene%4==0||i<16+scene%5*16;bool aff=scene%4==2&&i%3==0;
                uint16_t a0=uint16_t((scene%5==1&&i%3==0?192:0)|(1u<<13)|(active?(aff?0x100:0):0x200)|((scene&1)?0x1000:0));
                uint16_t a1=uint16_t((scene%4==0?0:(i*17+scene*3)&511)|(3u<<14)|(aff?((i%32)<<9):0));
                uint16_t a2=uint16_t(((i*64)&1023)|((i%4)<<10)|((i%16)<<12));
                put16(e*1024+i*8,a0);put16(e*1024+i*8+2,a1);put16(e*1024+i*8+4,a2);put16(e*1024+i*8+6,0);
            }
            for(unsigned i=0;i<32;++i){put16(e*1024+i*32+6,0x100);put16(e*1024+i*32+14,0);put16(e*1024+i*32+22,0);put16(e*1024+i*32+30,0x100);}
        }
        rtl.m->vram_wr=1;rtl.tick();rtl.m->vram_wr=0;rtl.load(st);rtl.jitter=scene%3?9:0;
        uint32_t bgc,objc;if(scene==0)rtl.run(-1,0,bgc,objc);
        rtl.run(scene,scene+1,bgc,objc);maxbg=std::max(maxbg,bgc);maxobj=std::max(maxobj,objc);latebg+=bgc>2*ENG_LINE;lateobj+=objc>2*ENG_LINE;
        for(unsigned e=0;e<2;++e)for(unsigned x=0;x<256;++x)pixels+=rtl.got[e][x];captures+=rtl.cap.size();
    }
    for(unsigned n=0;n<256;++n)rtl.tick();
    unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    auto*d=rtl.m;std::printf("PASS coupled2D clocks=%llu jobs=48*2eng pixels=%llu capture=%llu fills=%llu maxBG=%u maxOBJ=%u lateBG=%u lateOBJ=%u forward=%u/%u/%u/%u PFQfull=%u singleton=%u held=%u scrub=%u OLB=%u tasks=%u\n",(unsigned long long)rtl.cyc,(unsigned long long)pixels,(unsigned long long)captures,(unsigned long long)rtl.fills,maxbg,maxobj,latebg,lateobj,d->fwd_mc,d->fwd_bt,d->fwd_ot,d->fwd_pf,d->pf_full,d->pf_replace,d->held,d->scrub_writes,d->olb_writes,tasks);
    if(tasks!=1||!pixels||!rtl.fills||!d->fwd_mc||!d->fwd_bt||!d->fwd_ot||!d->fwd_pf||!d->pf_full||!d->held||!d->olb_writes)throw std::runtime_error("coupled2D coverage");
}
