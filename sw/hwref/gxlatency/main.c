// Staged DS measurement: fixed startup cost of the first polygon after a matrix.
// Reuse gxtime's measured ITCM drain sampler; no emulator timing is a target.
#include "read.h"
#include <stdio.h>
#include <stdlib.h>

#define XY(x,y) (((u32)(x) & 0xffff) | ((u32)(y) << 16))
#define P10(x,y,z) (((u32)(x)&1023)|(((u32)(y)&1023)<<10)|(((u32)(z)&1023)<<20))
static Wr queued[256];
static int nq;
static const u32 identity[16] = {0x1000,0,0,0,0,0x1000,0,0,0,0,0x1000,0,0,0,0,0x1000};

// A start record is durable before touching GX. Restarting v4 skips every
// previously started step, including a step that hung, and preserves its data.
static u32 step_number,resume_step;
static bool output_ok=true;
static void append(Buf* b,const char* name)
{
    if (!b->len) return;
    char path[96];snprintf(path,sizeof(path),HWREF_DIR "/%s",name);
    FILE* f=hw_fat_ok ? fopen(path,"ab") : NULL;
    bool ok=f && fwrite(b->p,1,b->len,f)==b->len;
    if (f && fclose(f)!=0) ok=false;
    if (!ok) { output_ok=false;hw_status("append failed %s",name); }
    free(b->p);b->p=NULL;b->len=b->cap=0;
}
static void csv_header(const char* name,const char* header)
{
    char path[96];snprintf(path,sizeof(path),HWREF_DIR "/%s",name);
    FILE* f=hw_fat_ok ? fopen(path,"rb") : NULL;
    long size=0;if(f){fseek(f,0,SEEK_END);size=ftell(f);fclose(f);}
    if (!size) { Buf b={0};buf_printf(&b,"%s",header);append(&b,name); }
}
static void load_progress(void)
{
    FILE* f=hw_fat_ok ? fopen(HWREF_DIR "/gxlatency_v4_progress.txt","rb") : NULL;
    if (f) { char line[160];unsigned long n;
        while (fgets(line,sizeof(line),f)) if (sscanf(line,"START,%lu",&n)==1 && n>resume_step) resume_step=n;
        fclose(f);
    }
    hw_status("resume after step %lu",(unsigned long)resume_step);
}
static bool start_step(const char* family,int a,int b,int c,int rep)
{
    if (++step_number<=resume_step) return false;
    Buf row={0};buf_printf(&row,"START,%lu,%s,%d,%d,%d,%d\n",(unsigned long)step_number,family,a,b,c,rep);
    append(&row,"gxlatency_v4_progress.txt");
    return output_ok;
}
static void done_step(void)
{
    Buf row={0};buf_printf(&row,"DONE,%lu,%lu,%lu,%lu\n",(unsigned long)step_number,
        (unsigned long)g_timeouts,(unsigned long)g_reset_fail,(unsigned long)g_dropped);
    append(&row,"gxlatency_v4_progress.txt");
}

void gx_note_timeout(void) { hw_status("gxlatency timeout: %08lx", (unsigned long)g_timeout_gxstat); }
static void put(unsigned c, u32 v) { gx_put(GXPORT(c), v); }
static void add(unsigned c, u32 v)
{
    if (nq>=256) { g_dropped++;return; }
    queued[nq++] = (Wr){GXPORT(c), v};
}
static void vertex(int x, int y) { put(0x23, XY(x,y)); put(0x23, 0); }
static void add_vertex(int x, int y) { add(0x23, XY(x,y)); add(0x23, 0); }
static void warm(void)
{
    gx_wait(GXSTAT_BUSY);
    put(0x41,0); put(0x10,0); put(0x15,0); put(0x10,3); put(0x15,0); put(0x10,2); put(0x15,0);
    put(0x60, 255u << 16 | 191u << 24); put(0x29,0x001f00c0); put(0x2a,0); put(0x2b,0); put(0x20,0x7fff);
    put(0x40,0); vertex(0,0); vertex(0x400,0); vertex(0,0x400); put(0x41,0);
    gx_wait(GXSTAT_BUSY); // Clip matrix already consumed before the measured queued work.
}
static void packet(int kind, int shape, int count)
{
    nq=0;
    // Keep a visible FIFO drop even for n=0; this fixed prefix cancels in D(n)-D(0).
    for (int i=0;i<8;i++) add(0x20,0x7fff);
    if (kind) {
        add(0x10,kind==4 ? 2 : 1);
        if (kind==1) add(0x15,0);
        else for (int i=0;i<16;i++) add(kind==2 ? 0x16 : 0x18,identity[i]);
    }
    add(0x40,0);
    for (int i=0;i<count;i++) {
        int x=shape==1 ? 0x2000 : shape==2 ? 0xe00 : 0;
        int right=shape==1 ? 0x2400 : shape==2 ? 0x1400 : 0x400;
        add_vertex(x,0); add_vertex(right,0); add_vertex(x,0x400);
    }
    add(0x41,0);
    // Max is 220 entries: below 256, so preloading behind SWAP cannot stall the writer.
}
// Setup bursts in the mixed replay are not covered by the twelve-body DS scorecard.
// Capture their drain slope rather than treating the emulator's setup table as hardware truth.
static void setupcosts(void)
{
    const char* names[]={"difamb","difamb_color","speemi","speemi_table","lightcol","lightvec","shininess","store0_m2","restore0_m2","pushpop_m2"};
    const int counts[]={0,1,2,4,8,16,32,64};
    Buf summary={0},events={0};
    csv_header("gxlatency_v4_setup.csv","body,n,rep,entries,samples,drain_sys,timeouts\n");
    csv_header("gxlatency_v4_setup_events.csv","body,n,sample,gxstat,sys_from_sample0\n");
    for (int kind=0;kind<10;kind++) for (int ni=0;ni<8;ni++) for (int rep=0;rep<3;rep++) {
        int count=counts[ni];
        if (kind==6 && count>4) continue; // 32 parameters per SHININESS, still below FIFO capacity.
        if (!start_step("setup",kind,count,0,rep)) continue;
        u32 old_timeouts=g_timeouts;
        hw_status("setup %s n %d",names[kind],count);
        warm();
        // Avoid assuming the library's initial position-stack depth, or pushing at depth 31.
        if (kind==9) {
            u32 depth=(R_GXSTAT>>8)&31;
            if (depth) { put(0x12,depth); gx_wait(GXSTAT_BUSY); put(0x15,0); gx_wait(GXSTAT_BUSY); }
        }
        // A known stack slot for restore; PUSH/POP uses balanced pairs from depth zero.
        if (kind>=7) { put(0x13,0); gx_wait(GXSTAT_BUSY); }
        nq=0;
        for (int k=0;k<8;k++) add(0x20,0x7fff);
        for (int k=0;k<count;k++) switch (kind) {
            case 0: add(0x30,0x21087fff); break;
            case 1: add(0x30,0x2108ffff); break;
            case 2: add(0x31,0x10884210); break;
            case 3: add(0x31,0x1088c210); break;
            case 4: add(0x33,0x7fff); break;
            case 5: add(0x32,0x1ff00000); break;
            case 6: for (int j=0;j<32;j++) add(0x34,0x03020100u+0x04040404u*j); break;
            case 7: add(0x13,0); break;
            case 8: add(0x14,0); break;
            case 9: add(0x11,0); add(0x12,1); break;
        }
        int n=gx_run_drain(queued,nq,0,0,0,NULL,0,true);
        u32 elapsed=0,first=0,maxlevel=0; int found=0;
        for (int j=0;j<n;j++) {
            if (j) elapsed+=(u16)(g_samples[j].t-g_samples[j-1].t);
            u32 level=GXSTAT_LEVEL(g_samples[j].s);
            if (level>maxlevel) maxlevel=level;
            else if (level<maxlevel && !found) { first=elapsed; found=1; }
            if (!rep) buf_printf(&events,"%s,%d,%d,%08lx,%lu\n",names[kind],count,j,
                                 (unsigned long)g_samples[j].s,(unsigned long)elapsed);
        }
        buf_printf(&summary,"%s,%d,%d,%d,%d,%ld,%lu\n",names[kind],count,rep,nq,n,
                   found && n<MAX_SAMPLES-1 ? (long)(elapsed-first) : -1L,(unsigned long)(g_timeouts-old_timeouts));
        append(&summary,"gxlatency_v4_setup.csv");append(&events,"gxlatency_v4_setup_events.csv");done_step();
        if (!output_ok || g_timeouts!=old_timeouts || g_reset_fail || g_dropped) goto done;
    }
done:
    append(&summary,"gxlatency_v4_setup.csv"); append(&events,"gxlatency_v4_setup_events.csv");
}

// Match unitgx v3's packing and 1200/2400-entry body lengths, recording
// both DMA finish and the subsequent GX idle. This is separate from the
// original run8 SWAP-queued drain protocol, whose timing excludes feeding.
static u32 dma_stream[3200] __attribute__((aligned(32)));
static u32 dma_words,dma_header,dma_slot,dma_params[64],dma_np;
static void pack_command(u32 c,const u32* params,u32 np)
{
    if (!dma_slot) { dma_header=dma_words++;dma_stream[dma_header]=0; }
    dma_stream[dma_header]|=c<<(8*dma_slot);
    for (u32 j=0;j<np;j++) dma_params[dma_np++]=params[j];
    if (++dma_slot==4) {
        for (u32 j=0;j<dma_np;j++) dma_stream[dma_words++]=dma_params[j];
        dma_slot=0;dma_np=0;
    }
}
static void feed_setup(int lit,int triangle)
{
    put(0x41,0);put(0x10,0);put(0x15,0);put(0x10,3);put(0x15,0);put(0x10,2);put(0x15,0);
    put(0x60,255u<<16|191u<<24);put(0x29,0x001f00c0);put(0x2a,0);put(0x2b,0);put(0x20,0x7fff);
    put(0x30,0x21087fff);put(0x31,0);
    put(0x32,P10(0,0,-511));put(0x32,P10(0,-511,0)|(1u<<30));
    put(0x32,P10(-511,0,0)|(2u<<30));put(0x32,P10(300,300,-300)|(3u<<30));
    put(0x33,0x7fff);put(0x33,0x001f|(1u<<30));put(0x33,0x03e0|(2u<<30));put(0x33,0x7c00|(3u<<30));
    if (lit) put(0x29,0x001f00cf);
    if (triangle) put(0x40,0);
}
static void packedcosts(void)
{
    const char* names[]={"LOAD44","TRINRML4","TRIXCLIP"};
    const u32 body_entries[]={16,9,6};
    Buf data={0};
    csv_header("gxlatency_v4_packed.csv","body,n,rep,entries,words,dma_sys,idle_sys,dma_gxstat,idle_gxstat,clip0_after_idle,timeout\n");
    for (int kind=0;kind<3;kind++) for (int length=1;length<=2;length++) for (int rep=0;rep<3;rep++) {
        u32 n=(1200u*length)/body_entries[kind];
        if (!start_step("packed",kind,length,n,rep)) continue;
        dma_words=dma_slot=dma_np=0;
        for (u32 k=0;k<n;k++) {
            if (!kind) pack_command(0x16,identity,16);
            else for (int v=0;v<3;v++) {
                u32 normal=P10(0,0,-511);
                if (kind==1) pack_command(0x21,&normal,1);
                int x=kind==2 ? (v==1 ? 0x1400 : 0xe00) : (v==1 ? 0x400 : 0);
                u32 p[2]={XY(x,v==2 ? 0x400 : 0),0};
                pack_command(0x23,p,2);
            }
        }
        for (u32 j=0;j<dma_np;j++) dma_stream[dma_words++]=dma_params[j];
        DC_FlushRange(dma_stream,4*dma_words);
        hw_status("packed %s n %lu",names[kind],(unsigned long)n);
        if (!gx_wait(GXSTAT_BUSY)) goto done;
        put(0x41,0);put(0x50,0);
        if (!gx_wait(GXSTAT_BUSY)) goto done;
        feed_setup(kind==1,kind!=0); // Deliberately no extra setup-idle fence: unitgx v3 protocol.
        GxDmaTime t;gxlat_dma(dma_stream,dma_words,&t);
        if (t.timeout) { g_timeouts++;g_timeout_gxstat=t.idle_stat; }
        u32 clip0=0;
        if (!t.timeout) clip0=REG32(0x04000640);
        buf_printf(&data,"%s,%lu,%d,%lu,%lu,%lu,%lu,%08lx,%08lx,%08lx,%lu\n",names[kind],
                   (unsigned long)n,rep,(unsigned long)(n*body_entries[kind]),(unsigned long)dma_words,
                   (unsigned long)t.dma_sys,(unsigned long)t.idle_sys,(unsigned long)t.dma_stat,
                   (unsigned long)t.idle_stat,(unsigned long)clip0,(unsigned long)t.timeout);
        append(&data,"gxlatency_v4_packed.csv");done_step();
        if (!output_ok || t.timeout || g_timeouts || g_reset_fail || g_dropped) goto done;
    }
done:
    append(&data,"gxlatency_v4_packed.csv");
}
// Only matrix/mode pairs absent from run3; do not repeat captured DS panels.
// n=0 controls and bounded queued bursts keep CPU/DMA feeding out of timing.
static void matrixcosts(void)
{
    const char* names[]={"pushpop","store","restore","identity","load44","load43","mult44","mult43","mult33","scale","trans"};
    // DS run3, tools/hwref/results/ds-vs-melonds-run3-gxtime-cap3d.md.
    const u8 captured_modes[]={0x5,0x4,0x4,0x7,0x7,0x4,0xf,0x6,0x6,0x6,0x6};
    const int counts[]={0,1,2,4,8};
    const u32 id43[]={0x1000,0,0,0,0x1000,0,0,0,0x1000,0,0,0};
    Buf data={0},events={0};
    csv_header("gxlatency_v4_matrix.csv","body,mode,n,rep,entries,samples,drain_sys,timeouts\n");
    csv_header("gxlatency_v4_matrix_events.csv","body,mode,n,sample,gxstat,sys_from_sample0\n");
    for (int mode=0;mode<4;mode++) for (int kind=0;kind<11;kind++) for (int ni=0;ni<5;ni++) for (int rep=0;rep<3;rep++) {
        if (captured_modes[kind]&(1u<<mode)) continue;
        int count=counts[ni];
        if (!start_step("matrix",mode,kind,count,rep)) continue;
        u32 old_timeouts=g_timeouts;
        hw_status("matrix %s m%d n%d",names[kind],mode,count);
        warm();
        // Balanced PUSH/POP starts from a valid depth; STORE seeds RESTORE.
        u32 depth=(R_GXSTAT>>8)&31;
        if (depth) { put(0x10,2);put(0x12,depth);gx_wait(GXSTAT_BUSY); }
        put(0x10,mode);put(0x15,0);put(0x13,0);gx_wait(GXSTAT_BUSY);
        nq=0;for (int k=0;k<8;k++) add(0x20,0x7fff);
        for (int k=0;k<count;k++) switch (kind) {
            case 0: add(0x11,0);add(0x12,1);break;
            case 1: add(0x13,0);break;
            case 2: add(0x14,0);break;
            case 3: add(0x15,0);break;
            case 4: case 6: for (int j=0;j<16;j++) add(kind==4 ? 0x16 : 0x18,identity[j]);break;
            case 5: case 7: for (int j=0;j<12;j++) add(kind==5 ? 0x17 : 0x19,id43[j]);break;
            case 8: for (int j=0;j<9;j++) add(0x1a,id43[j]);break;
            case 9: for (int j=0;j<3;j++) add(0x1b,0x1000);break;
            case 10: for (int j=0;j<3;j++) add(0x1c,0);break;
        }
        int n=gx_run_drain(queued,nq,0,0,0,NULL,0,true);
        u32 elapsed=0,first=0,maxlevel=0;int found=0;
        for (int j=0;j<n;j++) {
            if (j) elapsed+=(u16)(g_samples[j].t-g_samples[j-1].t);
            u32 level=GXSTAT_LEVEL(g_samples[j].s);
            if (level>maxlevel) maxlevel=level;
            else if (level<maxlevel && !found) { first=elapsed;found=1; }
            if (!rep) buf_printf(&events,"%s,%d,%d,%d,%08lx,%lu\n",names[kind],mode,count,j,
                                 (unsigned long)g_samples[j].s,(unsigned long)elapsed);
        }
        buf_printf(&data,"%s,%d,%d,%d,%d,%d,%ld,%lu\n",names[kind],mode,count,rep,nq,n,
                   found && n<MAX_SAMPLES-1 ? (long)(elapsed-first) : -1L,(unsigned long)(g_timeouts-old_timeouts));
        append(&data,"gxlatency_v4_matrix.csv");append(&events,"gxlatency_v4_matrix_events.csv");done_step();
        if (!output_ok || g_timeouts!=old_timeouts || g_reset_fail || g_dropped) goto done;
    }
done:
    append(&data,"gxlatency_v4_matrix.csv");append(&events,"gxlatency_v4_matrix_events.csv");
}
int main(void)
{
    hw_init("gxlatency 4 - GX timing"); videoSetMode(MODE_0_3D); R_DISP3DCNT=0; R_GXSTAT=1u<<15;
    load_progress();
    const char* names[]={"warm","identity_m1","load44_m1","mult44_m1","mult44_m2"};
    const int counts[]={0,1,2,4,16,32};
    Buf summary={0},events={0},info={0};
    csv_header("gxlatency_v4_summary.csv","prefix,shape,n,rep,entries,samples,drain_sys,timeouts\n");
    csv_header("gxlatency_v4_events.csv","prefix,shape,n,sample,gxstat,sys_from_sample0\n");
    for (int k=0;k<5;k++) for (int shape=0;shape<3;shape++) for (int j=0;j<6;j++) for (int rep=0;rep<3;rep++) {
        if (!start_step("cold",k,shape,counts[j],rep)) continue;
        u32 old_timeouts=g_timeouts;
        hw_status("%s shape %d n %d",names[k],shape,counts[j]); warm(); packet(k,shape,counts[j]);
        int n=gx_run_drain(queued,nq,0,0,0,NULL,0,true);
        u32 elapsed=0,first=0,maxlevel=0; int found=0;
        for (int i=0;i<n;i++) {
            if (i) elapsed+=(u16)(g_samples[i].t-g_samples[i-1].t);
            u32 level=GXSTAT_LEVEL(g_samples[i].s);
            if (level>maxlevel) maxlevel=level;
            else if (level<maxlevel && !found) { first=elapsed; found=1; }
            if (!rep) buf_printf(&events,"%s,%d,%d,%d,%08lx,%lu\n",names[k],shape,counts[j],i,
                                 (unsigned long)g_samples[i].s,(unsigned long)elapsed);
        }
        buf_printf(&summary,"%s,%d,%d,%d,%d,%d,%ld,%lu\n",names[k],shape,counts[j],rep,nq,n,
                   found && n<MAX_SAMPLES-1 ? (long)(elapsed-first) : -1L,(unsigned long)(g_timeouts-old_timeouts));
        // Keep a timeout from generating a long series of questionable measurements.
        append(&summary,"gxlatency_v4_summary.csv");append(&events,"gxlatency_v4_events.csv");done_step();
        if (!output_ok || g_timeouts!=old_timeouts || g_reset_fail || g_dropped) goto done;
    }
done:
    if (output_ok && !g_timeouts && !g_reset_fail && !g_dropped) {
        const int delays[]={0,1,2,4,16,64};
        Buf reads={0};
        csv_header("gxlatency_v4_reads.csv","port,load,delay,rep,gxstat_before,value,gxstat_after,read_sys\n");
        for (int port=0;port<2;port++) for (int load=0;load<2;load++) for (int d=0;d<6;d++) for (int rep=0;rep<3;rep++) {
            if (!start_step("reads",port,load,delays[d],rep)) continue;
            warm();
            GxRead r;
            gxlat_read(load,delays[d],port ? 0x04000680 : 0x04000640,&r);
            buf_printf(&reads,"%s,%d,%d,%d,%08lx,%08lx,%08lx,%lu\n",port ? "vector" : "clip",load,delays[d],rep,
                       (unsigned long)r.before,(unsigned long)r.value,(unsigned long)r.after,(unsigned long)r.elapsed);
            append(&reads,"gxlatency_v4_reads.csv");done_step();
            if (!output_ok || g_timeouts || g_reset_fail || g_dropped) goto read_done;
        }
read_done:
        append(&reads,"gxlatency_v4_reads.csv");
    }
    if (output_ok && !g_timeouts && !g_reset_fail && !g_dropped) setupcosts();
    if (output_ok && !g_timeouts && !g_reset_fail && !g_dropped) packedcosts();
    if (output_ok && !g_timeouts && !g_reset_fail && !g_dropped) matrixcosts();
    buf_printf(&info,"resume skipped %lu started steps; enumerated %lu; output_ok %d\n",(unsigned long)resume_step,(unsigned long)step_number,output_ok);
    buf_printf(&info,"gxlatency 4; system-cycle clock 33513982 Hz\nshapes: 0 drawn, 1 rejected, 2 x-clipped\n");
    buf_printf(&info,"packed: unitgx v3 DMA3 finish and subsequent GX idle, not run8 queued drain.\n");
    buf_printf(&info,"matrix: all four modes; n=0 controls, queued drain excludes feeding; retain raw events.\n");
    buf_printf(&info,"Compare D(1)-D(0) and the n>=4 slope for each prefix; retain raw events.\n");
    buf_printf(&info,"timeouts %lu resets %lu failed %lu dropped %lu\n",(unsigned long)g_timeouts,
               (unsigned long)g_resets,(unsigned long)g_reset_fail,(unsigned long)g_dropped);
    append(&summary,"gxlatency_v4_summary.csv"); append(&events,"gxlatency_v4_events.csv"); buf_write(&info,"gxlatency_v4_info.txt");
    if (!output_ok) hw_status("INCOMPLETE: SD append failed; retain v4 progress and restart");
    hw_done();
}
