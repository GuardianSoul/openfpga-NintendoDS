// sndcap: types shared by the v1 segments (main.c) and v2 (v2.c).
#pragma once
#include "../common/hwref.h"

enum { W_SAW16, W_SAW8, W_ADT, W_ADR, W_PSG };

typedef struct {
	u8 ch, wave, mode, pan, duty;
	u16 vol, timer, pnt;
	u32 len;
} Voice;

typedef struct {
	char name[24];
	u8 nv, mixvol, capsrc, capfmt;   // capsrc 0 = mixer, 1 = ChA; capfmt 0 = 16, 1 = 8
	u16 captimer;
	Voice v[12];
	// results
	u32 done_cycles, unwritten[2];
	bool timeout;
	int peak[2], vmin[2], vmax[2];
	s16* out[2];
} Seg;

// v1's segments (main.c), for v2's index.
extern Seg s_seg[];
extern int s_nseg;

// Runs the v2 segments after main.c has written the v1 files, appends to
// sndcap_info.txt, rewrites sndcap_index.csv with both sets, writes
// sndcap_v2_{L,R}.bin, then sndcap_v3_main.
void sndcap_v2_main(void) __attribute__((noreturn));
void sndcap_v2_release(void* v2state);   // frees v2's state and captures

// v3 (v3.c): frees the v1/v2 captures, runs the DC segments, appends to
// sndcap_index.csv and sndcap_info.txt, writes sndcap_v3_{L,R}.bin, then
// hw_done().
void sndcap_v3_main(void* v2state) __attribute__((noreturn));
