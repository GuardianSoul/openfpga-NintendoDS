// NEW-ONLY PROBE. Reuses load2d's main-engine capture/BG configuration.
// No OBJ count/cycle budget or DISPCNT bit23 polarity is assumed.
#include "../common/hwref.h"
#include <stdio.h>
#include <string.h>

#define LIMIT 3351398u
#define OBJ_BASE 0x06400000u
#define OBJ_PAL 0x05000200u
#define OAM_BASE 0x07000000u
static u16 image[256*192] __attribute__((aligned(32)));
static u16 bg_snapshot[32768] __attribute__((aligned(32)));
static u16 obj_snapshot[4096] __attribute__((aligned(32)));
static u16 palette_snapshot[512] __attribute__((aligned(32)));
static u16 oam[128][4], actual_oam[128][4];

static bool vblank(void)
{
    u32 t=now32();
    while(R_VCOUNT==192)if(now32()-t>LIMIT)return false;
    while(R_VCOUNT!=192)if(now32()-t>LIMIT)return false;
    return true;
}
static unsigned code(unsigned x,unsigned y)
{
    // Two adjacent rows identify all64 columns using nonzero4bpp texels.
    return 1+((y&1) ? x/15 : x%15);
}
static void tile_block(unsigned base,bool marker)
{
    // 2D OBJ mapping: row stride32 tiles. Three8x8-tile blocks at0/8/16
    // occupy disjoint columns; no marker texel aliases ballast storage.
    for(unsigned y=0;y<64;y++)for(unsigned x=0;x<64;x+=4){
        u16 pixels=0;
        for(unsigned j=0;j<4;j++)pixels|=(marker ? code(x+j,y) : 1)<<(j*4);
        unsigned tile=base+(y/8)*32+x/8;
        REG16(OBJ_BASE+tile*32+(y&7)*4+(x&7)/2)=pixels;
    }
}
static void setup(void)
{
    R_VRAMCNT(0)=0x81;R_VRAMCNT(1)=0x82;R_VRAMCNT(2)=0x84;R_VRAMCNT(3)=0x80;
    // VRAM H/I are offsets8/9; offset7 is WRAMCNT, not a VRAM bank.
    for(int i=4;i<7;i++)R_VRAMCNT(i)=0;
    R_VRAMCNT(8)=R_VRAMCNT(9)=0;
    REG32(0x04000000)=0x10080;
    REG32(0x04001000)=0x10080; // engine B forced blank: no extra2D stress
    for(unsigned i=0;i<32768;i++)REG16(0x06000000+i*2)=0;
    for(unsigned i=0;i<256;i++)REG16(0x05000000+i*2)=(i&31)|(((i>>3)&31)<<5)|(((i>>1)&31)<<10);
    for(unsigned i=0;i<8192;i++)REG16(0x06000000+i*2)=((i%255)+1)|(((i*7%255)+1)<<8);
    for(unsigned bg=0;bg<4;bg++){
        REG16(0x04000008+bg*2)=(1<<7)|((28+bg)<<8)|bg;
        REG16(0x04000010+bg*4)=bg*13;REG16(0x04000012+bg*4)=bg*7;
        for(unsigned i=0;i<1024;i++)REG16(0x06000000+(28+bg)*0x800+i*2)=(i+bg*23)&255;
    }
    REG16(0x04000050)=0x0241;REG16(0x04000052)=0x0808;
    REG16(0x0400004c)=0;REG16(0x0400006c)=0;
    for(unsigned i=0;i<256;i++)REG16(OBJ_PAL+i*2)=0;
    REG16(OBJ_PAL+2)=0x001f;
    for(unsigned i=1;i<16;i++){
        REG16(OBJ_PAL+(16+i)*2)=i|(31<<5);
        REG16(OBJ_PAL+(32+i)*2)=i|(31<<10);
    }
    for(unsigned i=0;i<4096;i++)REG16(OBJ_BASE+i*2)=0;
    tile_block(0,false);tile_block(8,true);tile_block(16,true);
    for(unsigned i=0;i<32768;i++)bg_snapshot[i]=REG16(0x06000000+i*2);
    for(unsigned i=0;i<4096;i++)obj_snapshot[i]=REG16(OBJ_BASE+i*2);
    for(unsigned i=0;i<256;i++){
        palette_snapshot[i]=REG16(0x05000000+i*2);
        palette_snapshot[256+i]=REG16(OBJ_PAL+i*2);
    }
    hw_write("objlimit_v2_bg.bin",bg_snapshot,sizeof bg_snapshot);
    hw_write("objlimit_v2_obj.bin",obj_snapshot,sizeof obj_snapshot);
    hw_write("objlimit_v2_pal.bin",palette_snapshot,sizeof palette_snapshot);
}
static void configure(unsigned count,unsigned width,unsigned first,unsigned m0,unsigned m1)
{
    memset(oam,0,sizeof oam);
    for(unsigned i=0;i<128;i++)oam[i][0]=0x0200; // disabled, non-affine
    for(unsigned i=0;i<count;i++){
        oam[first+i][0]=96|0x0400; // semitransparent4bpp, normal square
        oam[first+i][1]=(width==64 ? 3u : 0u)<<14; // all ballast overlaps x0..63
    }
    oam[m0][0]=oam[m1][0]=96; // opaque markers, priority0
    oam[m0][1]=0xc000|128;oam[m1][1]=0xc000|192;
    oam[m0][2]=(1<<12)|8;oam[m1][2]=(2<<12)|16;
    for(unsigned i=0;i<128;i++)for(unsigned j=0;j<4;j++)REG16(OAM_BASE+i*8+j*2)=oam[i][j];
    // Same bit23=0 as the measured load2d condition; no polarity inference.
    REG32(0x04000000)=0x11f00;
}
static void run(unsigned kind)
{
    // 0 control;1/2 narrow/wide late;3/4 late order swapped;5 wide early.
    unsigned count=kind ? 32 : 0,width=(kind==2||kind>=4) ? 64 : 8;
    unsigned first=kind==5 ? 2 : 0;
    unsigned m0=kind==5 ? 0 : (kind==3||kind==4) ? 33 : 32;
    unsigned m1=kind==5 ? 1 : (kind==3||kind==4) ? 32 : 33;
    char key[48];snprintf(key,sizeof key,"k%u",kind);
    if(!hw_step_begin("objlimit_v2_progress.txt",key))return;
    bool timeout=!vblank();
    configure(count,width,first,m0,m1);
    if(!vblank())timeout=true; // settle a whole visible frame before capture
    u32 dispcnt=REG32(0x04000000),start=R_VCOUNT,t=now32();
    if(!timeout){
        R_DISPCAP=DCAP_ENABLE|DCAP_MODE(DCAP_MODE_A)|DCAP_SRC_A(DCAP_SRC_A_COMPOSITED)|
            DCAP_SIZE(DCAP_SIZE_256x192)|DCAP_BANK(3);
        while(R_DISPCAP&DCAP_ENABLE)if(now32()-t>LIMIT){timeout=true;break;}
    }
    u32 ticks=now32()-t,end=R_VCOUNT,cap=R_DISPCAP;
    R_DISPCAP=0;
    for(unsigned i=0;i<256*192;i++)image[i]=REG16(0x06860000+i*2);
    for(unsigned i=0;i<128;i++)for(unsigned j=0;j<4;j++)actual_oam[i][j]=REG16(OAM_BASE+i*8+j*2);
    bool same=!memcmp(oam,actual_oam,sizeof oam),saved=true;
    char name[80];snprintf(name,sizeof name,"objlimit_v2_k%u.bin",kind);
    saved=hw_write(name,image,sizeof image)&&saved;
    snprintf(name,sizeof name,"objlimit_v2_k%u_oam.bin",kind);
    saved=hw_write(name,actual_oam,sizeof actual_oam)&&saved;
    Buf regs={0};buf_printf(&regs,"field,value_hex\ndispcnt,%08lx\n",(unsigned long)dispcnt);
    for(unsigned i=0;i<4;i++){
        buf_printf(&regs,"bg%u_cnt,%04x\nbg%u_hofs,%04x\nbg%u_vofs,%04x\n",i,
            REG16(0x04000008+i*2),i,REG16(0x04000010+i*4),i,REG16(0x04000012+i*4));
    }
    for(unsigned i=0;i<9;i++)buf_printf(&regs,"vramcnt%u,%02x\n",i,R_VRAMCNT(i<7 ? i : i+1));
    buf_printf(&regs,"wramcnt,%02x\n",REG8(0x04000247));
    buf_printf(&regs,"dispcnt_b,%08lx\npowcnt1,%04x\n",(unsigned long)REG32(0x04001000),R_POWCNT1);
    buf_printf(&regs,"bldcnt,%04x\nbldalpha,%04x\nmosaic,%04x\nmaster_bright,%04x\n",
        REG16(0x04000050),REG16(0x04000052),REG16(0x0400004c),REG16(0x0400006c));
    snprintf(name,sizeof name,"objlimit_v2_k%u_regs.csv",kind);saved=buf_write(&regs,name)&&saved;
    Buf row={0};buf_printf(&row,"%u,%u,%u,%u,%u,%u,%u,%lu,%lu,%lu,%u,%08lx,%u\n",
        kind,count,width,first,count+2,m0,m1,(unsigned long)start,(unsigned long)end,
        (unsigned long)ticks,timeout,(unsigned long)cap,same);
    saved=buf_append(&row,"objlimit_v2.csv")&&saved;
    if(saved&&!timeout)hw_step_done("objlimit_v2_progress.txt",key);
}
int main(void)
{
    hw_init("objlimit v2 - source staged, not a DS timing rule");
    hw_csv_header("objlimit_v2.csv","kind,count,ballast_width,ballast_first,eligible,marker0_index,marker1_index,start_line,end_line,capture_ticks,timeout,capture_control_after,oam_readback_match\n");
    setup();
    for(unsigned kind=0;kind<6;kind++)run(kind);
    consoleDemoInit();
    Buf info={0};buf_printf(&info,"objlimit v2; built " __DATE__ " " __TIME__ "\nSix captures, bit23=0: marker-only;32 overlapping8x8/64x64 ballast before markers; same pair with marker OAM order swapped;64x64 ballast after markers. Normal4bpp semitransparent ballast atx0/y96. Opaque64x64 markers atx128/192/y96, palette1/2,2D tile bases8/16; late indices32/33 (swapped33/32), early0/1. Ballast starts0 or2; unusedOAM disabled. Compare only common lines96..103. Nonzero per-column codes repeat in row pairs. Four BG alpha state reusesload2d; engineB forcedblank, no DMA/CPU stress. Capture256x192 raw16, exact BG/OBJ/palette/OAM/readback registers. Timing is capture polling, not OBJ render work. No count cap, pixel charge or bit23polarity assumed. Controls must qualify marker colours before interpreting loss. Software/FAT resume can skip an interrupted START, leaving it unmeasured. No new hardware result or physical deployment implied.\n");
    buf_write(&info,"objlimit_v2_info.txt");hw_done();
}
