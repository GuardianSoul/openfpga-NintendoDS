#include "Vtb_cull_products.h"
#include "verilated.h"
#include "addresses.h"
#include <bit>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>

int main(int argc,char**argv) {
    VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);Vtb_cull_products d{&ctx};
    uint32_t rng=0x2d7a931b,mesh[4][3]={};uint64_t clocks=0,early=0,normal=0,replaced=0,resets=0,completed=0;
    auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    auto tick=[&](bool reset_between=false){
        d.eval();ctx.timeInc(1);d.clk2=1;d.eval();ctx.timeInc(1);d.clk2=0;d.eval();
        if(reset_between){d.rst=1;d.observe=0;++resets;d.eval();}
        ctx.timeInc(1);d.clk=1;d.clk2=1;d.eval();ctx.timeInc(1);d.clk=0;d.clk2=0;d.eval();++clocks;
    };
    auto reset=[&](bool between=false){
        d.rf_we=d.xsnap=d.pu_step=d.observe=0;if(!between){d.rst=1;++resets;}tick(between);tick();d.rst=0;
    };
    auto write=[&](unsigned g,unsigned c,uint32_t v){
        d.rf_we=1;d.rf_wa=0x200+16*g+(c==2?3:c);d.rf_wd=v;tick();d.rf_we=0;mesh[g][c]=v;
    };
    auto mul=[](uint32_t a,uint32_t b){return uint64_t(int64_t(int32_t(a))*int64_t(int32_t(b)));};
    auto expected=[&](uint32_t attr){
        unsigned a=d.pre[0],b=d.pre[1],c=d.pre[2];uint32_t u[3],v[3];
        for(unsigned k=0;k<3;++k){u[k]=mesh[a][k]-mesh[b][k];v[k]=mesh[c][k]-mesh[b][k];}
        uint64_t n[3]={mul(u[1],v[2])-mul(u[2],v[1]),mul(u[2],v[0])-mul(u[0],v[2]),mul(u[0],v[1])-mul(u[1],v[0])};
        uint32_t t=0;for(uint64_t x:n)t|=uint32_t((x^(x>>63?~0ULL:0ULL))>>31);
        unsigned shift=0;for(unsigned k=0;k<8;++k)if((t>>(4*k))&15)shift=4*(k+1);
        uint64_t dot=0;for(unsigned k=0;k<3;++k)dot+=mul(mesh[b][k],uint32_t(std::bit_cast<int64_t>(n[k])>>shift));
        bool neg=dot>>63, face=!dot||neg, reject=dot&&(neg?!(attr&128):!(attr&64));
        return unsigned(face)|(unsigned(reject)<<1);
    };
    d.clk=d.clk2=0;d.pu_done=1;d.xs_slot=1;reset();
    const uint32_t extremes[]={0,1,0xffffffff,0x80000000,0x7fffffff,0x40000000,0xc0000000,0x00010000};
    for(unsigned job=0;job<4096;++job){
        d.observe=0;d.rf_we=d.xsnap=d.pu_step=0;
        for(unsigned g=0;g<4;++g)for(unsigned c=0;c<3;++c)write(g,c,job%3?random():extremes[(job+g*3+c)%8]);
        uint32_t attr=random();d.rf_we=1;d.rf_wd=attr;d.rf_wa=LU_CATTR;tick();d.rf_we=0;
        for(unsigned k=0;k<4;++k)d.pre[k]=(job>>(2*k))&3;
        d.dc_pend=random()&1;d.pu_triv=job%7==0;d.observe=1;
        uint64_t start=0;bool is_early=job&1;
        auto start_early=[&](){
            d.xs_g=d.pre[2];for(unsigned k=0;k<4;++k)d.xs_c[k]=random();
            d.xsnap=1;tick();d.xsnap=0;start=clocks;
            mesh[d.xs_g][0]=d.xs_c[0];mesh[d.xs_g][1]=d.xs_c[1];mesh[d.xs_g][2]=d.xs_c[3];
            d.pu_step=1;tick();d.pu_step=0;
        };
        if(is_early){++early;start_early();}
        else {
            ++normal;d.pu_step=1;tick();d.pu_step=0;start=clocks;
            // The step's late W and preceding X reach the real snoop ports before stage3.
            write(d.pre[2],2,random());write(d.pre[2],0,random());
        }
        bool aborted=false, did_replace=false;
        for(unsigned wait=0;d.stage!=8;++wait){
            if(wait>30)throw std::runtime_error("cull valid-edge timeout");
            if(job%17==0&&d.stage==4){reset(true);aborted=true;break;}
            if(job%11==0&&!did_replace&&d.stage==5){
                for(unsigned k=0;k<4;++k)d.pre[k]=random()%4;
                start_early();did_replace=true;is_early=true;++replaced;continue;
            }
            unsigned free=0;while(free<4&&(free==d.pre[0]||free==d.pre[1]||free==d.pre[2]))++free;
            if(free>=4)throw std::runtime_error("no unused cull group");
            d.dc_pend=random()&1;write(free,wait%3,random());
        }
        if(aborted)continue;
        if(clocks-start!=(is_early?5:7))throw std::runtime_error("cull E4/stage8 edge changed");
        unsigned result=expected(attr);
        auto check=[&](){if((unsigned(d.face)|(unsigned(d.reject)<<1))!=result||bool(d.crej)!=bool(d.pu_triv||(result&2))||bool(d.busy)!=bool(d.dc_pend))throw std::runtime_error("independent signed64 cull result mismatch");};
        check();++completed;
        for(unsigned hold=0;hold<3;++hold){d.dc_pend=hold&1;d.pu_triv=hold==2;tick();check();}
        if(job%31==0)reset();
    }
    unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    std::printf("PASS newcull clocks=%llu jobs=4096 completed=%llu early=%llu normal=%llu replaced=%llu resets=%llu cp64=%u normal32=%u cd64=%u result=%u M=%u E=%u dotM=%u tasks=%u\n",(unsigned long long)clocks,(unsigned long long)completed,(unsigned long long)early,(unsigned long long)normal,(unsigned long long)replaced,(unsigned long long)resets,d.cp_checks,d.normal_checks,d.cd_checks,d.result_checks,d.phase_m,d.phase_e,d.dot_m,tasks);
    if(tasks!=1||!completed||!replaced||!resets||!d.cp_checks||!d.normal_checks||!d.cd_checks||!d.result_checks||!d.phase_m||!d.phase_e||!d.dot_m)throw std::runtime_error("new cull coverage");
    d.final();
}
