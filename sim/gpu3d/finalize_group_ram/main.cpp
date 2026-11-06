#include "Vtb_finram.h"
#include "verilated.h"
#include "addresses.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <stdexcept>
#include <string>

int main(int argc,char**argv) {
    const bool fault=argc>1&&std::string(argv[1])=="--consumer-fault";
    VerilatedContext ctx;ctx.threads(1);ctx.commandArgs(argc,argv);
    Vtb_finram d{&ctx};
    if(argc>1&&std::string(argv[1]).starts_with("--collision-")){
        d.rst=1;d.bad_write=1;d.eval();ctx.timeInc(1);
        if(std::string(argv[1])=="--collision-A-first"){
            d.clk=1;d.eval();d.clk2=1;d.eval();
        }else{
            d.clk2=1;d.eval();d.clk=1;d.eval();
        }
        throw std::runtime_error("collision guard missed illegal mixed-clock write");
    }
    uint32_t rng=0x7642e95a,orrng=0x1e849d37;
    auto random=[&](){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;};
    auto orandom=[&](){orrng^=orrng<<13;orrng^=orrng>>17;orrng^=orrng<<5;return orrng;};
    uint64_t cycles=0,acks=0,headers=0,vertices=0,starts=0,oracle_checks=0,oracle_writes=0;
    uint64_t reset_writes=0,pending_resets=0,after_m_resets=0,rfwrites=0,overlap=0,triple=0;
    uint64_t holdcw=0,holdpv=0,reuse=0,new_results=0,zskips=0,sorts=0,public_pending=0;
    std::array<uint64_t,4> collisions{},active_collisions{},oracle_collisions{};
    std::array<uint64_t,11> lengths{};std::array<uint64_t,4> prefix{},wcases{};
    std::array<uint32_t,512> memory{};std::array<uint32_t,4> expected{};
    std::array<uint8_t,512> read_mask{},write_seen{};
    bool expected_valid=false,previous_write=false,previous_rst=false,hold_output=false,arm_publication=false;
    int release_after=0,block_writes=0;
    auto tick=[&](bool external=false,bool reset_after_m=false) {
        d.clk=0;d.wfree=!external&&block_writes==0&&(random()%4!=0);
        d.ofree=(!hold_output||(d.pv&&!d.ptype))&&(random()%4!=0);d.sct=random();
        d.eval();
        if(!external){d.we=d.cw&&d.wfree;d.wa=d.cwa;d.wd=d.cwd;}
        d.oracle_we=cycles<8192||cycles%8!=7;
        d.oracle_wa=cycles&511;
        const uint32_t special[]={0,0xffffffff,0x80000000,0x7fffffff,0x55555555,0xaaaaaaaa,1,0x10000};
        d.oracle_wd=cycles%16<8?special[cycles%8]:orandom();
        for(unsigned k=0;k<4;++k)d.oracle_ra[k]=(cycles*(2*k+1)+109*k)&511;
        // Individual and all-port collisions, including every consecutive
        // write in the startup stream. Expected reads precede the write.
        d.oracle_ra[cycles%4]=d.oracle_wa;
        if(cycles%13==0)for(unsigned k=0;k<4;++k)d.oracle_ra[k]=d.oracle_wa;
        d.eval();
        if(d.rst&&!previous_rst&&previous_write)++pending_resets;
        // M commits the preceding E's write and holds that E's B read.
        ctx.timeInc(1);d.clk2=1;d.eval();
        ctx.timeInc(1);d.clk2=0;d.eval();
        if(expected_valid&&!fault)for(unsigned k=0;k<4;++k){
            if(d.oracle_q[k]!=expected[k]){
                std::fprintf(stderr,"independent oracle cycle=%llu port=%u expected=%08x actual=%08x\n",
                  (unsigned long long)cycles,k,expected[k],d.oracle_q[k]);
                throw std::runtime_error("independent 4R/1W oracle");
            }
            ++oracle_checks;
        }
        if(reset_after_m){d.rst=1;++after_m_resets;d.eval();}
        if(d.fin_mid)throw std::runtime_error("phase did not return to E");
        bool was_q=d.q_active;
        if(!d.rst){
            acks+=d.cw&&d.wfree;headers+=d.pv&&d.ofree&&!d.ptype;vertices+=d.pv&&d.ofree&&d.ptype;
            holdcw+=d.cw&&!d.wfree;holdpv+=d.pv&&!d.ofree;
            overlap+=d.q_active&&(d.hgo||(d.run&&(d.xarg==0||d.xarg==3)&&d.ready));
            triple+=d.cw&&d.pv&&d.ptype&&d.result_write;
            reuse+=d.stage_read&&d.reused;new_results+=d.new_result;zskips+=d.z_skip;
            sorts+=d.sort_op;public_pending+=d.publish_pending;
        }
        if(d.we&&(d.wa&0x600)==0x200){
            ++rfwrites;reset_writes+=d.rst;
            for(unsigned k=0;k<4;++k)if((d.wa&511)==d.read_addr[k]){
                ++collisions[k];active_collisions[k]+=!d.rst&&d.stage_read&&!d.reused;
            }
        }
        for(unsigned k=0;k<4;++k){
            const unsigned addr=d.oracle_ra[k];expected[k]=memory[addr];read_mask[addr]|=1<<k;
            oracle_collisions[k]+=d.oracle_we&&addr==d.oracle_wa;
        }
        if(d.oracle_we){memory[d.oracle_wa]=d.oracle_wd;write_seen[d.oracle_wa]=1;++oracle_writes;}
        previous_rst=d.rst;previous_write=d.we&&(d.wa&0x600)==0x200;
        expected_valid=true;
        ctx.timeInc(1);d.clk=1;d.clk2=1;d.eval();
        ctx.timeInc(1);d.clk=0;d.clk2=0;d.eval();++cycles;
        if(arm_publication&&!was_q&&d.q_active){hold_output=true;arm_publication=false;release_after=0;}
        else if(release_after>0&&--release_after==0)hold_output=false;
        if(block_writes>0)--block_writes;
    };
    auto reset=[&](bool after_m=false){
        // A write from the preceding E must survive assertion before M.
        d.run=0;d.hgo=0;d.we=1;d.wa=0x200+d.read_addr[1];d.wd=random();
        if(!after_m)d.rst=1;
        tick(true,after_m);
        // Both reset E edges still accept RF writes, independently of rst.
        d.we=1;d.wd=random();tick(true);d.we=0;d.rst=0;
        hold_output=false;arm_publication=false;release_after=0;block_writes=0;
    };
    auto write=[&](unsigned addr,uint32_t value){d.we=1;d.wa=addr;d.wd=value;tick(true);d.we=0;};
    auto wait_ready=[&](){for(unsigned n=0;!d.ready;++n){if(n>10000)throw std::runtime_error("ready timeout");tick();}};
    auto run_op=[&](unsigned xarg){
        d.run=1;d.xarg=xarg;tick();
        for(unsigned n=0;d.cond;++n){
            if(n>10000)throw std::runtime_error("FRUN timeout");
            // Interleave full-width live RF writes on actual ordinary read
            // addresses; external writes suppress background CW acceptance.
            if(n%7==0&&d.rd)write(0x200+d.read_addr[(n/7)%4],random());else tick();
        }
        d.run=0;
    };
    reset();
    // Warm the independent oracle through all addresses and bit patterns.
    // Fin's memories remain unreset; the software oracle is never cleared.
    d.rst=1;
    for(unsigned n=0;n<8192;++n)tick();
    d.rst=0;
    for(unsigned a=0x200;a<0x400;++a)write(a,random());
    for(unsigned test=0;test<330;++test){
        wait_ready();
        const bool fast=test%3!=0,manual=!fast&&test%2==0;
        const unsigned ln=fast?3+test%2:(test/3)%11;
        const unsigned cs=fast?(test%4==0?2:0):std::min(ln,(test/3)%4);
        const bool wbuf=test&1;
        ++lengths[ln];++prefix[cs];++wcases[(wbuf?2:0)+(fast?1:0)];
        d.np=test*29;
        write(FU_A_LN,ln);write(FU_A_CS,cs);write(FU_A_FATTR,wbuf?2:0);
        write(FU_A_TEXPAL,random());write(FU_A_FACING,random());
        write(FU_A_TRT,random());write(FU_A_TRA,random());write(LU_A_CATTR,random());write(FU_A_TEXP,random());
        for(unsigned k=0;k<6;++k){
            // Viewport zero/unit/full-width and random multipliers/offsets.
            uint32_t v=test%5==0?0:test%5==1?1:test%5==2?0xffffffff:random();
            write(FU_A_VP+k,v);
        }
        for(unsigned i=0;i<ln;++i){
            const unsigned group=fast?(test+i)%6:6+i;
            write(FU_A_LA+i,0x200+16*group);
            if(i<4)d.h_la[i]=0x200+16*group;
            for(unsigned k=0;k<16;++k){
                uint32_t v=random();
                if(k==3){const uint32_t ws[]={0,1,0xffff,0x10000,0xffffff,0x123456};v=ws[(test+i)%6];}
                write(0x200+16*group+k,v);
            }
        }
        release_after=120;arm_publication=!manual;block_writes=150;
        if(fast){
            d.h_ln=ln;d.h_cs=cs;d.h_face=test&1;d.h_wb=(test/2)&1;
            if(test%11==0){d.h_la[2]=d.h_la[0];if(ln==4)d.h_la[3]=d.h_la[1];}
            d.hgo=1;d.we=1;d.wa=d.h_la[0]+test%16;d.wd=random();tick(true);d.hgo=0;++starts;
            for(unsigned w=0;w<16;++w)write(d.h_la[0]+w,random());
            for(unsigned w=0;w<4;++w)write(d.h_la[0]+w,random());
            if(test<310&&test%23==1){reset(test&1);d.hgo=1;tick();d.hgo=0;++starts;}
            for(unsigned n=0;!d.ready;++n){
                if(n>10000)throw std::runtime_error("fast timeout");
                if(n%3==0)write(0x200+(random()%96),random());else tick();
            }
        }else{
            ++starts;
            if(manual){run_op(0);run_op(1);}else run_op(3);
        }
        if(test%19==18){
            write(0x200+d.read_addr[1],random());
            reset((test/19)&1);
        }
    }
    hold_output=false;arm_publication=false;release_after=0;block_writes=0;
    for(unsigned n=0;d.busy;++n){if(n>10000)throw std::runtime_error("drain timeout");tick();}
    // Flush the final E write and qualify its four original read results.
    tick();
    unsigned tasks=0;for(auto const&e:std::filesystem::directory_iterator("/proc/self/task")){(void)e;++tasks;}
    std::printf("cycles=%llu starts=%llu CW=%llu headers=%llu vertices=%llu RFwrites=%llu tasks=%u\n",
        (unsigned long long)cycles,(unsigned long long)starts,(unsigned long long)acks,
        (unsigned long long)headers,(unsigned long long)vertices,(unsigned long long)rfwrites,tasks);
    std::printf("oracle_checks=%llu oracle_writes=%llu reset_writes=%llu pending_resets=%llu after_M_resets=%llu\n",
        (unsigned long long)oracle_checks,(unsigned long long)oracle_writes,(unsigned long long)reset_writes,
        (unsigned long long)pending_resets,(unsigned long long)after_m_resets);
    std::printf("overlap=%llu triple=%llu reused=%llu new=%llu zskips=%llu holdCW=%llu holdPV=%llu published_pending=%llu sort=%llu\n",
        (unsigned long long)overlap,(unsigned long long)triple,(unsigned long long)reuse,(unsigned long long)new_results,
        (unsigned long long)zskips,(unsigned long long)holdcw,(unsigned long long)holdpv,
        (unsigned long long)public_pending,(unsigned long long)sorts);
    for(unsigned k=0;k<4;++k)std::printf("port%u: RFcollisions=%llu active_new_collisions=%llu oracle_collisions=%llu\n",k,
        (unsigned long long)collisions[k],(unsigned long long)active_collisions[k],(unsigned long long)oracle_collisions[k]);
    std::printf("lengths:");for(auto n:lengths)std::printf(" %llu",(unsigned long long)n);
    std::printf("\nprefix:");for(auto n:prefix)std::printf(" %llu",(unsigned long long)n);
    std::printf("\nprofile/wbuf:");for(auto n:wcases)std::printf(" %llu",(unsigned long long)n);std::puts("");
    std::fflush(stdout);
    for(unsigned a=0;a<512;++a)if(read_mask[a]!=15||!write_seen[a])throw std::runtime_error("address coverage");
    for(unsigned k=0;k<4;++k)if(!collisions[k]||!active_collisions[k]||!oracle_collisions[k])throw std::runtime_error("collision coverage");
    for(auto n:lengths)if(!n)throw std::runtime_error("entry-count coverage");
    for(auto n:prefix)if(!n)throw std::runtime_error("prefix coverage");
    for(auto n:wcases)if(!n)throw std::runtime_error("profile coverage");
    if(tasks!=1||oracle_checks<32768||!reset_writes||!pending_resets||!after_m_resets||!overlap||!triple||!reuse||!new_results||!zskips||!holdcw||!holdpv||!public_pending||!sorts)
        throw std::runtime_error("coverage guard");
    std::puts("PASS full finalize output/state/service + independent 4R1W OLD_DATA/reset oracle");
}
