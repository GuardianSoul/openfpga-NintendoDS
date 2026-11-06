// Minimal 2D deadline/contended-fetch capture. No assumed rendering time:
// compare each captured pixel/line against the same workload on the DS.
#include "../common/hwref.h"
#include <stdio.h>

#define LIMIT 3351398u
static u16 image[256*192] __attribute__((aligned(32)));
static u32 source[8192] __attribute__((aligned(32)));
static u32 dest[8192] __attribute__((aligned(32)));
static bool at_vblank(void)
{
    u32 t=now32();
    while (R_VCOUNT==192) if (now32()-t>LIMIT) return false;
    while (R_VCOUNT!=192) if (now32()-t>LIMIT) return false;
    return true;
}
static void engine(u32 io, u32 vram, u32 pal, int layers, bool obj)
{
    for (int i=0;i<256;i++) REG16(pal+i*2)=(i&31)|(((i>>3)&31)<<5)|(((i>>1)&31)<<10);
    for (int i=0;i<8192;i++) REG16(vram+i*2)=((i%255)+1)|(((i*7%255)+1)<<8);
    for (int bg=0;bg<4;bg++) {
        REG16(io+8+bg*2)=(1<<7)|((28+bg)<<8)|bg;
        REG16(io+0x10+bg*4)=bg*13;
        REG16(io+0x12+bg*4)=bg*7;
        for (int i=0;i<1024;i++) REG16(vram+(28+bg)*0x800+i*2)=(i+bg*23)&255;
    }
    // BG0 over BG1 alpha forces at least two contributing BG layers.
    REG16(io+0x50)=layers>1 ? 0x0241 : 0;
    REG16(io+0x52)=0x0808;
    REG32(io)=0x10000|(((1u<<layers)-1)<<8)|(obj ? 1<<12 : 0);
}
static void objects(void)
{
    for (int i=0;i<256;i++) REG16(0x05000200+i*2)=0x001f|(i<<5);
    for (int i=0;i<8192;i++) REG16(0x06400000+i*2)=0x1111;
    for (int i=0;i<128;i++) {
        REG16(0x07000000+i*8)=((i%6)*32)|0x0400; // semitransparent 4bpp square
        REG16(0x07000002+i*8)=0xc000|((i*17)&255); // 64x64
        REG16(0x07000004+i*8)=0;
        REG16(0x07000006+i*8)=0;
    }
}
int main(void)
{
    hw_init("load2d 1 - uncaptured 2D deadline probe");
    R_VRAMCNT(0)=0x81; // A BG
    R_VRAMCNT(1)=0x82; // B OBJ
    R_VRAMCNT(2)=0x84; // C sub BG, replacing console after init
    R_VRAMCNT(3)=0x80; // D LCDC capture
    for (int i=0;i<8192;i++) source[i]=i*0x12345u;
    armDCacheFlush(source,sizeof source);
    armDCacheFlush(dest,sizeof dest);
    objects();
    Buf csv={0};
    hw_csv_header("load2d.csv","load,engine_b,stress,rep,start_line,end_line,arm9_system_ticks,timeout,dma_busy\n");
    for (int load=0;load<3;load++) for (int sub=0;sub<2;sub++) for (int stress=0;stress<2;stress++) {
        engine(0x04000000,0x06000000,0x05000000,load ? 4 : 1,load==2);
        engine(0x04001000,0x06200000,0x05000400,4,false);
        if (!sub) REG32(0x04001000)=0x10080; // forced blank
        for (int rep=0;rep<2;rep++) {
            char key[64];
            snprintf(key,sizeof key,"l%d_b%d_s%d_r%d",load,sub,stress,rep);
            if(!hw_step_begin("load2d_progress.txt",key))continue;
            bool timeout=!at_vblank();
            if (timeout) {
                buf_printf(&csv,"%d,%d,%d,%d,0,0,0,1,0\n",load,sub,stress,rep);
                buf_append(&csv,"load2d.csv");
                continue;
            }
            u32 t=now32(), start=R_VCOUNT;
            R_DISPCAP=DCAP_ENABLE|DCAP_MODE(DCAP_MODE_A)|DCAP_SRC_A(DCAP_SRC_A_COMPOSITED)|
                DCAP_SIZE(DCAP_SIZE_256x192)|DCAP_BANK(3);
            if (stress) {
                REG32(0x040000d4)=(u32)source;
                REG32(0x040000d8)=(u32)dest;
                REG32(0x040000dc)=0x84002000; // DMA3 immediate 8192 words
            }
            volatile u32 sink=0;
            while (R_DISPCAP&DCAP_ENABLE) {
                if (stress) for (int i=0;i<64;i++) sink+=REG16(0x06000000+i*2);
                if (now32()-t>LIMIT) { timeout=true; break; }
            }
            (void)sink;
            u32 elapsed=now32()-t, end=R_VCOUNT, dma=REG32(0x040000dc)>>31;
            REG32(0x040000dc)=0;
            R_DISPCAP=0;
            for (int i=0;i<256*192;i++) image[i]=REG16(0x06860000+i*2);
            char fn[64];
            snprintf(fn,sizeof fn,"load2d_%d_%d_%d_f%d.bin",load,sub,stress,rep);
            bool saved=hw_write(fn,image,sizeof image);
            buf_printf(&csv,"%d,%d,%d,%d,%lu,%lu,%lu,%d,%lu\n",load,sub,stress,rep,
                (unsigned long)start,(unsigned long)end,(unsigned long)elapsed,timeout,(unsigned long)dma);
            saved=buf_append(&csv,"load2d.csv") && saved;
            if(saved && !timeout && !dma)hw_step_done("load2d_progress.txt",key);
        }
    }
    consoleDemoInit(); // captures are finished; restore a visible DONE/error console
    Buf info={0};
    buf_printf(&info,"load2d 1; built " __DATE__ " " __TIME__ "\nload 0 one BG; 1 four BG alpha; 2 four BG alpha + 128 semitransparent 64x64 OBJ. Engine B four BG or forced blank; engine A captured only. Stress is one 8192-word DMA main->main at VBlank then CPU VRAM reads while awaiting capture, NOT sustained DMA. Two captures per condition; 256x192 RGB555 u16. Elapsed capture polling is not internal rendering cost.\n");
    buf_write(&info,"load2d_info.txt");
    hw_done();
}
