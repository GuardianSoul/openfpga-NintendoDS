// Staged DS31 follow-up: signed odd channel-source levels and 8/16-bit
// quantization, both capture units. No hardware result exists yet.
// Procedure adapted from sndq v3 (cache-line-safe buffers, bounded polling).
#include "../common/hwref.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "capsrc odd 1"
#define CAP_TIMER 512
#define SENTINEL 0x5A5A5A5Au
#define NLEV 160
#define LEVN 32
#define VOL(v7, div) ((div) == 0 ? (v7) << 4 : (div) == 1 ? (v7) << 3 : (div) == 2 ? (v7) << 2 : (v7))   // calico's 11-bit volume

static u32 s_zero[8] __attribute__((aligned(32)));

typedef struct { u8 ch, pan; u16 vol, timer; const void* data; u16 pnt, len; } V;   // pnt/len in words

static void progress(const char* fmt, ...)
{
	if (!hw_fat_ok) return;
	char line[128];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	FILE* f = fopen(HWREF_DIR "/capsrc_progress.txt", "a");
	if (f) { fputs(line, f); fputc('\n', f); fclose(f); }
}

static void busy_wait(u32 cycles) { u32 t0 = now32(); while (now32() - t0 < cycles) {} }

// v2: resumable. capsrc_progress.txt gets "start <seg>" and "done <seg>"; a
// start that finds the file without "all done" skips every segment that
// ended and the one that began without ending (a hang inside calico's sound
// calls, which can't be bounded from here), and appends to capsrc_index.csv.
#define MAXSKIP 64
static char s_skip[MAXSKIP][24];
static int s_nskip;
static bool s_resume;
static bool skipped(const char* name)
{
	for (int i = 0; i < s_nskip; i++) if (!strcmp(s_skip[i], name)) return true;
	return false;
}
static void load_progress(void)
{
	FILE* f = fopen(HWREF_DIR "/capsrc_progress.txt", "r");
	if (!f) return;
	char line[96], open_seg[24] = "";
	bool all = false, ours = false;
	while (fgets(line, sizeof line, f)) {
		char nm[24];
		if (!strncmp(line, "V " VERSION, 2 + strlen(VERSION))) ours = true;   // another version's file starts afresh
		if (!strncmp(line, "all done", 8)) all = true;
		else if (sscanf(line, "start %23s", nm) == 1) strcpy(open_seg, nm);
		else if (sscanf(line, "done %23s", nm) == 1) {
			if (s_nskip < MAXSKIP) strcpy(s_skip[s_nskip++], nm);
			open_seg[0] = 0;
		}
	}
	fclose(f);
	if (all || !ours) { s_nskip = 0; return; }
	s_resume = true;
	if (open_seg[0] && s_nskip < MAXSKIP) strcpy(s_skip[s_nskip++], open_seg);
}

static void seg(const char* name, const V* v, int nv, int fmt0, int src0, u32 nsamp, Buf* idx)
{
	if (skipped(name)) return;
	progress("start %s", name);
	u32 bytes[2] = { fmt0 ? nsamp : nsamp * 2, nsamp * 2 };
	u32* cap[2];
	for (int u = 0; u < 2; u++) {
		// whole cache lines: the end-of-capture check invalidates the line of
		// the last word, which must not hold anything else (run 31: a buffer
		// ending mid-line lost the heap's dirty data and hung the DS)
		cap[u] = aligned_alloc(32, (bytes[u] + 31) & ~31u);
		if (!cap[u]) { buf_printf(idx, "%s,%d,out of memory\n", name, u); return; }
		for (u32 i = 0; i < bytes[u] / 4; i++) cap[u][i] = SENTINEL;
		armDCacheFlush(cap[u], bytes[u]);
	}
	soundStop(0x3FFFF);
	soundSetMixerVolume(127);
	u32 used = 0;
	for (int i = 0; i < nv; i++) used |= 1u << v[i].ch;
	for (int c = 0; c < 4; c++)
		if (!(used & (1u << c)))
			soundPreparePcm(c, 0, 64, CAP_TIMER, SoundMode_Repeat, SoundFmt_Pcm16, s_zero, 0, 4);
	for (int i = 0; i < nv; i++)
		soundPreparePcm(v[i].ch, v[i].vol, v[i].pan, v[i].timer, SoundMode_Repeat, SoundFmt_Pcm16, v[i].data,
		                v[i].pnt, v[i].len);
	soundPrepareCap(0, SoundCapDst_ChBNormal, (src0 & 1) ? SoundCapSrc_ChA : SoundCapSrc_Mixer, false,
	                fmt0 ? SoundCapFmt_Pcm8 : SoundCapFmt_Pcm16, cap[0], bytes[0] / 4);
	soundPrepareCap(1, SoundCapDst_ChBNormal, (src0 & 2) ? SoundCapSrc_ChA : SoundCapSrc_Mixer, false, SoundCapFmt_Pcm16, cap[1], bytes[1] / 4);
	u32 limit = nsamp * CAP_TIMER * 2 + 16756991u;
	u32 t0 = now32();
	soundStart(used | 0xF | (3u << 16));
	bool timeout = true;
	for (;;) {
		armDCacheInvalidate((void*)((u32)&cap[0][bytes[0] / 4 - 1] & ~31u), 32);
		armDCacheInvalidate((void*)((u32)&cap[1][bytes[1] / 4 - 1] & ~31u), 32);
		if (cap[0][bytes[0] / 4 - 1] != SENTINEL && cap[1][bytes[1] / 4 - 1] != SENTINEL) { timeout = false; break; }
		if (now32() - t0 > limit) break;
		busy_wait(33514);
	}
	soundStop(0x3FFFF);
	busy_wait(33514 * 2);
	for (int u = 0; u < 2; u++) {
		armDCacheInvalidate(cap[u], bytes[u]);
		u32 un = 0;
		for (int i = bytes[u] / 4 - 1; i >= 0 && cap[u][i] == SENTINEL; i--) un++;
		char fn[48];
		snprintf(fn, sizeof fn, "capsrc_%s_%c.bin", name, u ? 'R' : 'L');
		hw_write(fn, cap[u], bytes[u]);
		buf_printf(idx, "%s,%d,%s,%lu,%lu,%d\n", name, u, u == 0 && fmt0 ? "s8" : "s16", (unsigned long)nsamp,
		           (unsigned long)un, timeout);
		free(cap[u]);
	}
	progress("done %s", name);
	if (hw_fat_ok && idx->len) {   // append this segment's index rows now
		FILE* f = fopen(HWREF_DIR "/capsrc_index.csv", "a");
		if (f) { fwrite(idx->p, 1, idx->len, f); fclose(f); }
		free(idx->p);
		idx->p = NULL;
		idx->len = idx->cap = 0;
	}
	iprintf("%-16s%s\n", name, timeout ? " TIMEOUT" : "");
}


static s16 odd_dc[8] __attribute__((aligned(32)));
static s16 bystander[8] __attribute__((aligned(32)));
int main(void)
{
    hw_init(VERSION " - unmeasured capture-source rounding");
    if(hw_fat_ok)load_progress();
    if(hw_fat_ok && !s_resume){remove(HWREF_DIR "/capsrc_progress.txt");progress("V " VERSION);}
    soundInit();soundPowerOn();soundSetMixerConfig(SoundOutSrc_Mixer,SoundOutSrc_Mixer,false,false);soundSetMixerVolume(127);
    busy_wait(33514*20);for(int i=0;i<8;i++)bystander[i]=0x1234;
    armDCacheFlush(bystander,sizeof bystander);armDCacheFlush(s_zero,sizeof s_zero);
    Buf idx={0};if(!s_resume){buf_printf(&idx,"segment,unit,format,samples,unwritten_words,timeout\n");buf_write(&idx,"capsrc_index.csv");}
    const int level[]={1,3,255,257,-1,-3,-255,-257};
    const struct {u8 vol,div;} scale[]={{127,0},{64,0},{65,2}};
    // 48 PCM16 segments, within the inherited64-entry resume table.
    for(unsigned k=0;k<8;k++)for(unsigned v=0;v<3;v++)for(unsigned unit=0;unit<2;unit++){
        for(int i=0;i<8;i++)odd_dc[i]=(s16)level[k];armDCacheFlush(odd_dc,sizeof odd_dc);
        int pan=(k+v)&1?127:0;
        V voice[2]={{unit*2,pan,VOL(scale[v].vol,scale[v].div),CAP_TIMER,odd_dc,0,4},
                    {unit*2+1,64,VOL(127,0),CAP_TIMER,bystander,0,4}};
        char name[24];snprintf(name,sizeof name,"o%dv%dd%du%u",level[k],scale[v].vol,scale[v].div,unit);
        seg(name,voice,2,0,1u<<unit,256,&idx);
    }
    // 16 more segments: the same DC feedsch0/ch2, both pre-pan source taps.
    // Capture0 is8-bit, capture1 is16-bit, with no fitted phase or expected law.
    for(unsigned k=0;k<8;k++)for(unsigned v=0;v<2;v++){
        for(int i=0;i<8;i++)odd_dc[i]=(s16)level[k];armDCacheFlush(odd_dc,sizeof odd_dc);
        V voice[2]={{0,0,VOL(scale[v].vol,0),CAP_TIMER,odd_dc,0,4},{2,127,VOL(scale[v].vol,0),CAP_TIMER,odd_dc,0,4}};
        char name[24];snprintf(name,sizeof name,"b%dv%d",level[k],scale[v].vol);seg(name,voice,2,1,3,256,&idx);
    }
    soundStop(0x3FFFF);Buf info={0};
    buf_printf(&info,"%s\nbuilt %s %s\n64segments:48 signed-odd PCM16 source/volume/divider/pan cases;16 paired8/16 source captures. No odd rounding law assumed.\n",VERSION,__DATE__,__TIME__);
    buf_write(&info,"capsrc_info.txt");progress("all done");hw_done();
}
