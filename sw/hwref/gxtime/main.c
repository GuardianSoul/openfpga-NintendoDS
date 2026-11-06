// GX (3D geometry) timing reference. docs/hw-reference.md "gxtime".
//
// Per test: a setup written directly (and drained), then SWAP_BUFFERS at
// VCOUNT 16 with prefix + n copies of the body queued behind it. The engine
// waits for VBlank with the FIFO full of queued commands, then drains it on
// its own, so the drain time doesn't depend on how fast the CPU writes.
// D(n) = idle time - first FIFO-level drop; cycles per body =
// (D(n2) - D(n1)) / (n2 - n1). Every GXSTAT change goes to the events file.
#include "gxtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define E 0xFFFFFFFFu   // end of a command list
#define VERSION "gxtime 8"

static const u8 s_np[256] = {
	[0x10] = 1, [0x11] = 0, [0x12] = 1, [0x13] = 1, [0x14] = 1, [0x15] = 0,
	[0x16] = 16, [0x17] = 12, [0x18] = 16, [0x19] = 12, [0x1A] = 9,
	[0x1B] = 3, [0x1C] = 3, [0x20] = 1, [0x21] = 1, [0x22] = 1, [0x23] = 2,
	[0x24] = 1, [0x25] = 1, [0x26] = 1, [0x27] = 1, [0x28] = 1, [0x29] = 1,
	[0x2A] = 1, [0x2B] = 1, [0x30] = 1, [0x31] = 1, [0x32] = 1, [0x33] = 1,
	[0x34] = 32, [0x40] = 1, [0x41] = 0, [0x50] = 1, [0x60] = 1,
	[0x70] = 3, [0x71] = 2, [0x72] = 1,
};

// Fixed point helpers. 1.0 = 0x1000 (matrices, VTX_16), 10-bit packers.
#define XY(x, y) (((u32)(x) & 0xFFFF) | ((u32)(y) << 16))
#define P10(x, y, z) (((u32)(x) & 0x3FF) | (((u32)(y) & 0x3FF) << 10) | (((u32)(z) & 0x3FF) << 20))
#define ID44 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0, 0x1000
#define ID43 0x1000, 0, 0, 0, 0x1000, 0, 0, 0, 0x1000, 0, 0, 0
#define ID33 0x1000, 0, 0, 0, 0x1000, 0, 0, 0, 0x1000
#define Q 0x400   // 0.25
#define V16(x, y, z) 0x23, XY(x, y), (u32)(z)
#define TRI V16(0, 0, 0), V16(Q, 0, 0), V16(0, Q, 0)
#define TRI_R V16(0, 0, 0), V16(0, Q, 0), V16(Q, 0, 0)
#define NRM 0x21, P10(0, 0, -511)

// Everything a test may have changed, reset before each setup.
static const u32 S0[] = {
	0x41, 0x10, 0, 0x15, 0x10, 3, 0x15, 0x10, 2, 0x15,
	0x60, 0 | (0 << 8) | (255 << 16) | (191u << 24),
	0x29, 0x001F00C0, 0x2A, 0, 0x2B, 0, 0x20, 0x7FFF,
	0x30, 0x7FFF | (0x2108u << 16), 0x31, 0,
	0x32, P10(0, 0, -511) | (0u << 30), 0x32, P10(0, -511, 0) | (1u << 30),
	0x32, P10(-511, 0, 0) | (2u << 30), 0x32, P10(300, 300, -300) | (3u << 30),
	0x33, 0x7FFF | (0u << 30), 0x33, 0x001F | (1u << 30),
	0x33, 0x03E0 | (2u << 30), 0x33, 0x7C00 | (3u << 30),
	E,
};

typedef struct {
	const char* name;
	const u32* setup;   // written directly, after S0
	const u32* prefix;  // queued once behind the SWAP
	const u32* body;    // queued n times
	u32 swap;           // SWAP_BUFFERS parameter
} GxTest;

#define L(...) (const u32[]){ __VA_ARGS__, E }
#define NONE NULL
#define BEGIN(t) L(0x40, t)

static const GxTest s_tests[] = {
	// matrix
	{ "mtx_mode",      NONE, NONE, L(0x10, 2) },
	{ "push_pop_m2",   NONE, NONE, L(0x11, 0x12, 1) },
	{ "push_pop_m0",   L(0x10, 0), NONE, L(0x11, 0x12, 1) },
	{ "store_m2",      NONE, NONE, L(0x13, 1) },
	{ "restore_m2",    NONE, NONE, L(0x14, 1) },
	{ "identity_m0",   L(0x10, 0), NONE, L(0x15) },
	{ "identity_m1",   L(0x10, 1), NONE, L(0x15) },
	{ "identity_m2",   NONE, NONE, L(0x15) },
	{ "load44_m0",     L(0x10, 0), NONE, L(0x16, ID44) },
	{ "load44_m1",     L(0x10, 1), NONE, L(0x16, ID44) },
	{ "load44_m2",     NONE, NONE, L(0x16, ID44) },
	{ "load43_m2",     NONE, NONE, L(0x17, ID43) },
	{ "mult44_m0",     L(0x10, 0), NONE, L(0x18, ID44) },
	{ "mult44_m1",     L(0x10, 1), NONE, L(0x18, ID44) },
	{ "mult44_m2",     NONE, NONE, L(0x18, ID44) },
	{ "mult44_m3",     L(0x10, 3), NONE, L(0x18, ID44) },
	{ "mult43_m1",     L(0x10, 1), NONE, L(0x19, ID43) },
	{ "mult43_m2",     NONE, NONE, L(0x19, ID43) },
	{ "mult33_m1",     L(0x10, 1), NONE, L(0x1A, ID33) },
	{ "mult33_m2",     NONE, NONE, L(0x1A, ID33) },
	{ "scale_m1",      L(0x10, 1), NONE, L(0x1B, 0x1000, 0x1000, 0x1000) },
	{ "scale_m2",      NONE, NONE, L(0x1B, 0x1000, 0x1000, 0x1000) },
	{ "trans_m1",      L(0x10, 1), NONE, L(0x1C, 0, 0, 0) },
	{ "trans_m2",      NONE, NONE, L(0x1C, 0, 0, 0) },
	// vertex lists (both faces drawn unless noted)
	{ "tri_v16",       NONE, BEGIN(0), L(TRI) },
	{ "tri_v16_front_a", L(0x29, 0x001F0080), BEGIN(0), L(TRI) },
	{ "tri_v16_front_b", L(0x29, 0x001F0080), BEGIN(0), L(TRI_R) },
	{ "tri_v16_off",   NONE, BEGIN(0), L(V16(0x2000, 0, 0), V16(0x2400, 0, 0), V16(0x2000, Q, 0)) },
	{ "tri_v16_xclip", NONE, BEGIN(0), L(V16(0xE00, 0, 0), V16(0x1400, 0, 0), V16(0xE00, Q, 0)) },
	{ "tri_v16_zclip", NONE, BEGIN(0), L(V16(0, 0, -0x1800), V16(Q, 0, 0), V16(0, Q, 0)) },
	{ "tri_v16_2clip", NONE, BEGIN(0), L(V16(0xE00, 0xE00, 0), V16(0x1400, 0xE00, 0), V16(0xE00, 0x1400, 0)) },
	{ "quad_v16",      NONE, BEGIN(1), L(V16(0, 0, 0), V16(Q, 0, 0), V16(Q, Q, 0), V16(0, Q, 0)) },
	{ "tristrip_v16",  NONE, BEGIN(2), L(V16(0, 0, 0), V16(0, Q, 0), V16(Q, 0, 0), V16(Q, Q, 0)) },
	{ "tri_v10",       NONE, BEGIN(0), L(0x24, P10(0, 0, 0), 0x24, P10(16, 0, 0), 0x24, P10(0, 16, 0)) },
	{ "tri_vxy",       NONE, BEGIN(0), L(0x25, XY(0, 0), 0x25, XY(Q, 0), 0x25, XY(0, Q)) },
	{ "tri_vxz",       L(0x17, 0x1000, 0, 0, 0, 0, 0x1000, 0, 0x1000, 0, 0, 0, 0), BEGIN(0),
	                   L(0x26, XY(0, 0), 0x26, XY(Q, 0), 0x26, XY(0, Q)) },
	{ "tri_vyz",       L(0x17, 0, 0, 0x1000, 0, 0x1000, 0, 0x1000, 0, 0, 0, 0, 0), BEGIN(0),
	                   L(0x27, XY(0, 0), 0x27, XY(0, Q), 0x27, XY(Q, 0)) },
	{ "tri_vdiff",     NONE, BEGIN(0),
	                   L(0x28, P10(256, 0, 0), 0x28, P10(-256, 256, 0), 0x28, P10(0, -256, 0)) },
	{ "tri_color_v16", NONE, BEGIN(0), L(0x20, 0x001F, V16(0, 0, 0), 0x20, 0x03E0, V16(Q, 0, 0), 0x20, 0x7C00, V16(0, Q, 0)) },
	{ "tri_tc_v16_tg0", NONE, BEGIN(0), L(0x22, 0, V16(0, 0, 0), 0x22, XY(16 << 4, 0), V16(Q, 0, 0), 0x22, XY(0, 16 << 4), V16(0, Q, 0)) },
	{ "tri_tc_v16_tg1", L(0x2A, 1u << 30), BEGIN(0), L(0x22, 0, V16(0, 0, 0), 0x22, XY(16 << 4, 0), V16(Q, 0, 0), 0x22, XY(0, 16 << 4), V16(0, Q, 0)) },
	{ "tri_nrm_v16_tg2", L(0x2A, 2u << 30), BEGIN(0), L(NRM, V16(0, 0, 0), NRM, V16(Q, 0, 0), NRM, V16(0, Q, 0)) },
	{ "tri_tc_v16_tg3", L(0x2A, 3u << 30), BEGIN(0), L(0x22, 0, V16(0, 0, 0), 0x22, XY(16 << 4, 0), V16(Q, 0, 0), 0x22, XY(0, 16 << 4), V16(0, Q, 0)) },
	{ "tri_nrm_v16_l0", NONE, BEGIN(0), L(NRM, V16(0, 0, 0), NRM, V16(Q, 0, 0), NRM, V16(0, Q, 0)) },
	{ "tri_nrm_v16_l1", L(0x29, 0x001F00C1), BEGIN(0), L(NRM, V16(0, 0, 0), NRM, V16(Q, 0, 0), NRM, V16(0, Q, 0)) },
	{ "tri_nrm_v16_l2", L(0x29, 0x001F00C3), BEGIN(0), L(NRM, V16(0, 0, 0), NRM, V16(Q, 0, 0), NRM, V16(0, Q, 0)) },
	{ "tri_nrm_v16_l3", L(0x29, 0x001F00C7), BEGIN(0), L(NRM, V16(0, 0, 0), NRM, V16(Q, 0, 0), NRM, V16(0, Q, 0)) },
	{ "tri_nrm_v16_l4", L(0x29, 0x001F00CF), BEGIN(0), L(NRM, V16(0, 0, 0), NRM, V16(Q, 0, 0), NRM, V16(0, Q, 0)) },
	{ "mult44_tri",    NONE, BEGIN(0), L(0x18, ID44, TRI) },
	// single commands (lighting state from BEGIN in the prefix)
	{ "normal_l0",     NONE, BEGIN(0), L(NRM) },
	{ "normal_l1",     L(0x29, 0x001F00C1), BEGIN(0), L(NRM) },
	{ "normal_l2",     L(0x29, 0x001F00C3), BEGIN(0), L(NRM) },
	{ "normal_l3",     L(0x29, 0x001F00C7), BEGIN(0), L(NRM) },
	{ "normal_l4",     L(0x29, 0x001F00CF), BEGIN(0), L(NRM) },
	{ "normal_l4_shin", L(0x29, 0x001F00CF, 0x31, 0x8000), BEGIN(0), L(NRM) },
	{ "color",         NONE, NONE, L(0x20, 0x1234) },
	{ "texcoord",      NONE, NONE, L(0x22, 0) },
	{ "polygon_attr",  NONE, NONE, L(0x29, 0x001F00C0) },
	{ "teximage_param", NONE, NONE, L(0x2A, 0) },
	{ "pltt_base",     NONE, NONE, L(0x2B, 0) },
	{ "dif_amb",       NONE, NONE, L(0x30, 0x7FFF | (0x2108u << 16)) },
	{ "spe_emi",       NONE, NONE, L(0x31, 0) },
	{ "light_vector",  NONE, NONE, L(0x32, P10(0, 0, -511)) },
	{ "light_color",   NONE, NONE, L(0x33, 0x7FFF) },
	{ "shininess",     NONE, NONE, L(0x34, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) },
	{ "begin_end",     NONE, NONE, L(0x40, 0, 0x41) },
	{ "viewport",      NONE, NONE, L(0x60, 0 | (255 << 16) | (191u << 24)) },
	{ "box_test",      NONE, NONE, L(0x70, XY(0, 0), XY(0, Q), XY(Q, Q)) },
	{ "box_test_out",  NONE, NONE, L(0x70, XY(0x3000, 0), XY(0, Q), XY(Q, Q)) },
	{ "pos_test",      NONE, NONE, L(0x71, XY(0, 0), 0) },
	{ "vec_test",      NONE, NONE, L(0x72, P10(0, 0, -511)) },
	// W-buffered SWAP (the parameter shouldn't change geometry timing)
	{ "tri_v16_wbuf",  NONE, BEGIN(0), L(TRI), 3 },
	// command right after each vertex (pipeline waits after VTX)
#define VX(...) L(V16(0, 0, 0), __VA_ARGS__, V16(Q, 0, 0), __VA_ARGS__, V16(0, Q, 0), __VA_ARGS__)
	{ "vtx_then_color",    NONE, BEGIN(0), VX(0x20, 0x7FFF) },
	{ "vtx_then_texcoord", NONE, BEGIN(0), VX(0x22, 0) },
	{ "vtx_then_normal",   NONE, BEGIN(0), VX(NRM) },
	{ "vtx_then_normal_l4", L(0x29, 0x001F00CF), BEGIN(0), VX(NRM) },
	{ "vtx_then_polyattr", NONE, BEGIN(0), VX(0x29, 0x001F00C0) },
	{ "vtx_then_teximage", NONE, BEGIN(0), VX(0x2A, 0) },
	{ "vtx_then_identity", NONE, BEGIN(0), VX(0x15) },
	{ "vtx_then_push_pop", NONE, BEGIN(0), VX(0x11, 0x12, 1) },
	{ "vtx_then_mult44",   NONE, BEGIN(0), VX(0x18, ID44) },
	{ "vtx_then_dif_amb",  NONE, BEGIN(0), VX(0x30, 0x7FFF) },
	// polygon-pipeline stalls: after a completed polygon vs after other commands
	{ "tri_then_begin",    NONE, BEGIN(0), L(TRI, 0x40, 0) },
	{ "color_then_begin",  NONE, NONE, L(0x20, 0x7FFF, 0x40, 0) },
	{ "tri_then_lightvec", NONE, BEGIN(0), L(TRI, 0x32, P10(0, 0, -511)) },
	{ "tri_then_box_test", NONE, BEGIN(0), L(TRI, 0x70, XY(0, 0), XY(0, Q), XY(Q, Q)) },
	{ "tri_then_pos_test", NONE, BEGIN(0), L(TRI, 0x71, XY(0, 0), 0) },
	{ "quad_v16_culled",   L(0x29, 0x001F0040), BEGIN(1), L(V16(0, 0, 0), V16(Q, 0, 0), V16(Q, Q, 0), V16(0, Q, 0)) },
	{ "quad_v16_off",      NONE, BEGIN(1), L(V16(0x2000, 0, 0), V16(0x2400, 0, 0), V16(0x2400, Q, 0), V16(0x2000, Q, 0)) },
	{ "quad_v16_xclip",    NONE, BEGIN(1), L(V16(0xE00, 0, 0), V16(0x1400, 0, 0), V16(0x1400, Q, 0), V16(0xE00, Q, 0)) },
	// v8, geometry session's clip probes (identity projection: planes at |x|,|y|,|z| = w = 1.0 = 0x1000)
#define XT1 V16(0xE00, 0, 0), V16(0x1400, 0, 0), V16(0xE00, Q, 0)          // one vertex out (x)
#define XT2 V16(0xE00, 0, 0), V16(0x1400, 0, 0), V16(0x1400, Q, 0)         // two out
	{ "xclip1_tri",        NONE, BEGIN(0), L(XT1) },
	{ "xclip2_tri",        NONE, BEGIN(0), L(XT2) },
	{ "xclip1_then_begin", NONE, BEGIN(0), L(XT1, 0x40, 0) },
	{ "xclip1_then_lightvec", NONE, BEGIN(0), L(XT1, 0x32, P10(0, 0, -511)) },
	{ "xclip1_then_push_pop", NONE, BEGIN(0), L(XT1, 0x11, 0x12, 1) },
	{ "xclip1_then_color", NONE, BEGIN(0), L(XT1, 0x20, 0x7FFF) },
	{ "xclip1_then_tri",   NONE, BEGIN(0), L(XT1, TRI) },
	{ "tristrip_xclip",    NONE, BEGIN(2), L(V16(0xE00, 0, 0), V16(0xE00, Q, 0), V16(0x1400, 0, 0), V16(0x1400, Q, 0)) },
	{ "quad_xclip1",       NONE, BEGIN(1), L(V16(0xE00, 0, 0), V16(0x1400, 0, 0), V16(0xF00, Q, 0), V16(0xE00, Q, 0)) },
	{ "quad_xclip2",       NONE, BEGIN(1), L(V16(0xE00, 0, 0), V16(0x1400, 0, 0), V16(0x1400, Q, 0), V16(0xE00, Q, 0)) },
	{ "quad_xclip3",       NONE, BEGIN(1), L(V16(0xE00, 0, 0), V16(0x1400, 0, 0), V16(0x1400, Q, 0), V16(0x1200, Q, 0)) },
	{ "tri_farclip_on",    L(0x29, 0x001F10C0), BEGIN(0), L(V16(0, 0, 0), V16(Q, 0, 0x1400), V16(0, Q, 0)) },
	{ "tri_farclip_off",   NONE, BEGIN(0), L(V16(0, 0, 0), V16(Q, 0, 0x1400), V16(0, Q, 0)) },
	{ "tri_out_top_cross_x", NONE, BEGIN(0), L(V16(0xE00, 0x1400, 0), V16(0x1400, 0x1400, 0), V16(0xE00, 0x1800, 0)) },
	{ "box_test_partial",  NONE, NONE, L(0x70, XY(0xE00, 0), XY(0, 0x400), XY(Q, Q)) },
	{ "tri_end_box_test2", NONE, NONE, L(0x40, 0, TRI, 0x41, 0x70, XY(0, 0), XY(0, Q), XY(Q, Q)) },
	{ "xclip1_end_box_test", NONE, NONE, L(0x40, 0, XT1, 0x41, 0x70, XY(0, 0), XY(0, Q), XY(Q, Q)) },
	// Last: on the DS (v2/v3) the engine stayed busy with an empty FIFO
	// after this test. Variant b: a strip that moves on instead of folding
	// back (x steps of 1/16, then rewinds 2 units every 16 vertices pairs).
	{ "quadstrip_v16", NONE, L(0x40, 3, V16(0, 0, 0), V16(0, Q, 0)), L(V16(Q, 0, 0), V16(Q, Q, 0), V16(0, 0, 0), V16(0, Q, 0)) },
	{ "quadstrip_v16_b", NONE, L(0x40, 3, V16(0, 0, 0), V16(0, Q, 0)), L(V16(Q, 0, 0), V16(Q, Q, 0), V16(2 * Q, 0, 0), V16(2 * Q, Q, 0)) },
	// Unfinished primitives (v4 on the DS hung hard at tri_vdiff, whose setup
	// was BEGIN, one vertex, END).
	{ "end_after_1vtx",  NONE, NONE, L(0x40, 0, V16(0, 0, 0), 0x41) },
	{ "begin_after_1vtx", NONE, NONE, L(0x40, 0, V16(0, 0, 0)) },
	{ "end_after_2vtx_qstrip", NONE, NONE, L(0x40, 3, V16(0, 0, 0), V16(0, Q, 0), 0x41) },
	{ "tri_end_box_test", NONE, BEGIN(0), L(TRI, 0x41, 0x70, XY(0, 0), XY(0, Q), XY(Q, Q), 0x40, 0) },
	{ "tri_vdiff_setupvtx", L(0x40, 0, V16(0, 0, 0), 0x41), BEGIN(0),
	                   L(0x28, P10(256, 0, 0), 0x28, P10(-256, 256, 0), 0x28, P10(0, -256, 0)) },
};
#define NTESTS (int)(sizeof s_tests / sizeof s_tests[0])

static Wr s_run[300] DTCM_BSS;
static int s_nrun;

static void emit(const u32* l)
{
	while (l && *l != E) {
		u32 cmd = *l++;
		int np = s_np[cmd];
		vu32* port = GXPORT(cmd);
		if (np == 0) s_run[s_nrun++] = (Wr){ port, 0 };
		for (int i = 0; i < np; i++) s_run[s_nrun++] = (Wr){ port, *l++ };
	}
}

static int count_writes(const u32* l)
{
	int n = 0;
	while (l && *l != E) {
		int np = s_np[*l];
		n += np ? np : 1;
		l += 1 + np;
	}
	return n;
}

static void run_direct(const u32* l)
{
	s_nrun = 0;
	emit(l);
	for (int i = 0; i < s_nrun; i++) gx_put(s_run[i].a, s_run[i].v);
	gx_wait(GXSTAT_BUSY);
}

static const char* s_cur = "";
void gx_note_timeout(void)
{
	iprintf("\x1b[12;0HTIMEOUT in %-16s\n gxstat=%08lx resets=%lu fail=%lu ", s_cur,
	        (unsigned long)g_timeout_gxstat, (unsigned long)g_resets, (unsigned long)g_reset_fail);
}

// Progress log on the card, written before and after each test, so a hang
// or crash still shows where it happened and what GXSTAT said.
static void progress(const char* fmt, ...)
{
	char line[160];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	if (!hw_fat_ok) return;
	FILE* f = fopen(HWREF_DIR "/gxtime_progress.txt", "a");
	if (f) { fputs(line, f); fputc('\n', f); fclose(f); }
}

static void setup(const GxTest* t)
{
	run_direct(S0);
	run_direct(t->setup);
	R_GXSTAT = 1u << 15;  // ack matrix stack error
}

// Samples to events: unwrapped times relative to the first sample.
static Buf s_ev;
static u32 s_unw[MAX_SAMPLES];

static void unwrap(int n)
{
	u32 t = 0;
	for (int i = 0; i < n; i++) {
		if (i) t += (u16)(g_samples[i].t - g_samples[i - 1].t);
		s_unw[i] = t;
	}
}

static void log_events(const char* name, int n_body, int rep, int n)
{
	for (int i = 0; i < n; i++)
		buf_printf(&s_ev, "%s,%d,%d,%d,%lu,%08lx\n", name, n_body, rep, i,
		           (unsigned long)s_unw[i], (unsigned long)g_samples[i].s);
}

// D = end - first FIFO-level drop below its maximum.
static u32 drain_time(int n)
{
	u32 maxl = 0;
	int first = -1;
	for (int i = 0; i < n; i++) {
		u32 l = GXSTAT_LEVEL(g_samples[i].s);
		if (l > maxl) maxl = l;
		else if (l < maxl && first < 0) first = i;
	}
	if (first < 0 || n < 2) return 0;
	return s_unw[n - 1] - s_unw[first];
}

static u32 run_drain_test(const GxTest* t, int nb, int rep)
{
	setup(t);
	s_nrun = 0;
	emit(t->prefix);
	for (int k = 0; k < nb; k++) emit(t->body);
	int n = gx_run_drain(s_run, s_nrun, t->swap, 0, 0, NULL, 0, true);
	unwrap(n);
	if (rep == 0) log_events(t->name, nb, rep, n);
	return drain_time(n);
}

static int cmp_u32(const void* a, const void* b)
{
	u32 x = *(const u32*)a, y = *(const u32*)b;
	return x < y ? -1 : x > y;
}

#define REPS 3
#define ISO_REPS 5
#define FIFO_ENTRIES 240

// Sequences that stalled the DS geometry engine for good (v2-v6) or are
// suspected to: they run last, after all other results are on the card, in
// this order (least suspect first).
static const char* const s_danger[] = {
	"tri_end_box_test", "tri_then_pos_test", "quadstrip_v16_b", "quadstrip_v16",
	"end_after_2vtx_qstrip", "begin_after_1vtx", "end_after_1vtx", "tri_vdiff_setupvtx",
	"tri_then_box_test",
};
#define NDANGER (int)(sizeof s_danger / sizeof s_danger[0])
static int danger_rank(const char* name)
{
	for (int i = 0; i < NDANGER; i++)
		if (!strcmp(name, s_danger[i])) return i;
	return -1;
}

static void run_test(Buf* sum, const GxTest* t, int ti, int nt);

static void timing_tests(Buf* sum, bool danger)
{
	// Isolated-latency calibration: no writes.
	u32 cal[ISO_REPS];
	for (int r = 0; r < ISO_REPS; r++) cal[r] = gx_run_iso(s_run, 0, GXSTAT_BUSY);
	qsort(cal, ISO_REPS, sizeof cal[0], cmp_u32);
	buf_printf(sum, "# iso calibration (no writes): %lu\n", (unsigned long)cal[0]);
	buf_printf(sum, "test,writes_per_body,prefix_writes,n1,n2,d1,d2,cyc_per_body_x100,iso_min,iso_med,iso_bit0_min\n");

	if (danger) {
		for (int k = 0; k < NDANGER; k++)
			for (int ti = 0; ti < NTESTS; ti++)
				if (!strcmp(s_tests[ti].name, s_danger[k])) run_test(sum, &s_tests[ti], k, NDANGER);
	} else {
		int nt = 0;
		for (int ti = 0; ti < NTESTS; ti++) nt += danger_rank(s_tests[ti].name) < 0;
		for (int ti = 0, k = 0; ti < NTESTS; ti++)
			if (danger_rank(s_tests[ti].name) < 0) run_test(sum, &s_tests[ti], k++, nt);
	}
}

static void run_test(Buf* sum, const GxTest* t, int ti, int nt)
{
	{
		iprintf("\x1b[10;0H%2d/%d %-20s", ti + 1, nt, t->name);
		u32 to0 = g_timeouts;
		s_cur = t->name;
		progress("start %s gxstat=%08lx", t->name, (unsigned long)R_GXSTAT);
		int wb = count_writes(t->body), wp = count_writes(t->prefix);
		int n2 = (FIFO_ENTRIES - wp) / wb;
		if (n2 > 64) n2 = 64;
		int n1 = n2 / 4;
		while (n1 * wb + wp < 12) n1++;
		u32 d1 = ~0u, d2 = ~0u;
		for (int r = 0; r < REPS; r++) {
			u32 a = run_drain_test(t, n1, r), b = run_drain_test(t, n2, r);
			if (a < d1) d1 = a;
			if (b < d2) d2 = b;
		}
		u32 iso[ISO_REPS];
		for (int r = 0; r < ISO_REPS; r++) {
			setup(t);
			s_nrun = 0;
			emit(t->prefix);
			int pre = s_nrun;
			for (int i = 0; i < pre; i++) gx_put(s_run[i].a, s_run[i].v);
			s_nrun = 0;
			emit(t->body);
			iso[r] = gx_run_iso(s_run, s_nrun, GXSTAT_BUSY);
		}
		u32 bit0 = ~0u;
		for (int r = 0; r < ISO_REPS; r++) {
			setup(t);
			s_nrun = 0;
			emit(t->prefix);
			for (int i = 0; i < s_nrun; i++) gx_put(s_run[i].a, s_run[i].v);
			s_nrun = 0;
			emit(t->body);
			u32 c = gx_run_iso(s_run, s_nrun, 1);
			if (c < bit0) bit0 = c;
		}
		qsort(iso, ISO_REPS, sizeof iso[0], cmp_u32);
		s32 per = n2 > n1 ? (s32)((s64)((s32)d2 - (s32)d1) * 100 / (n2 - n1)) : 0;
		buf_printf(sum, "%s,%d,%d,%d,%d,%lu,%lu,%ld,%lu,%lu,%lu\n", t->name, wb, wp, n1, n2,
		           (unsigned long)d1, (unsigned long)d2, (long)per,
		           (unsigned long)iso[0], (unsigned long)iso[ISO_REPS / 2], (unsigned long)bit0);
		if (g_timeouts != to0) {
			buf_printf(sum, "# TIMEOUT %s: %lu waits ran out, last gxstat=%08lx, resets %lu (failed %lu)\n", t->name,
			           (unsigned long)(g_timeouts - to0), (unsigned long)g_timeout_gxstat,
			           (unsigned long)g_resets, (unsigned long)g_reset_fail);
			iprintf("\x1b[12;0HTIMEOUT %s\n gxstat=%08lx", t->name, (unsigned long)g_timeout_gxstat);
		}
		progress("done  %s d1=%lu d2=%lu timeouts=%lu last_gxstat=%08lx resets=%lu reset_fail=%lu dropped=%lu", t->name,
		         (unsigned long)d1, (unsigned long)d2, (unsigned long)(g_timeouts - to0),
		         (unsigned long)g_timeout_gxstat, (unsigned long)g_resets, (unsigned long)g_reset_fail,
		         (unsigned long)g_dropped);
	}
}

// Packed GXFIFO stream for DMA: each command in its own header word.
static u32* pack(u32* o, const u32* l)
{
	while (l && *l != E) {
		u32 cmd = *l++;
		int np = s_np[cmd];
		*o++ = cmd;
		for (int i = 0; i < np; i++) *o++ = *l++;
		if (np == 0) *o++ = 0;
	}
	return o;
}

static u32 s_dma[2048] __attribute__((aligned(32)));

static void dma_irq_tests(void)
{
	struct { const char* name; const u32* prefix; const u32* body; int n; bool stall; } d[] = {
		{ "dma_mult44_stalled", NONE, L(0x18, ID44), 40, true },
		{ "dma_mult44_free",    NONE, L(0x18, ID44), 40, false },
		{ "dma_tri_stalled",    BEGIN(0), L(0x20, 0x7FFF, TRI), 60, true },
		{ "dma_tri_free",       BEGIN(0), L(0x20, 0x7FFF, TRI), 60, false },
	};
	for (unsigned k = 0; k < sizeof d / sizeof d[0]; k++) {
		u32* o = pack(s_dma, d[k].prefix);
		for (int i = 0; i < d[k].n; i++) o = pack(o, d[k].body);
		u32 words = o - s_dma;
		armDCacheFlush(s_dma, sizeof s_dma);
		iprintf("\x1b[10;0H%-26s", d[k].name);
		for (int r = 0; r < REPS; r++) {
			run_direct(S0);
			int n = gx_run_drain(s_run, 0, 0, 1, 0, s_dma, words, d[k].stall);
			unwrap(n);
			log_events(d[k].name, words, r, n);
		}
	}
	// FIFO IRQ: 15 MULT_4x4 (240 entries) queued, then mode 1 (less than
	// half full) or 2 (empty). The IF bit is sampled with IRQs masked.
	for (u32 mode = 1; mode <= 2; mode++) {
		const char* name = mode == 1 ? "irq_half" : "irq_empty";
		iprintf("\x1b[10;0H%-26s", name);
		for (int r = 0; r < REPS; r++) {
			run_direct(S0);
			s_nrun = 0;
			for (int i = 0; i < 15; i++) emit(L(0x18, ID44));
			int n = gx_run_drain(s_run, s_nrun, 0, 1, mode, NULL, 0, true);
			unwrap(n);
			log_events(name, 15, r, n);
		}
	}
}

static void stall_tests(Buf* b)
{
	buf_printf(b, "test,i,t\n");
	struct { const char* name; u8 cmd; u32 v; } s[] = {
		{ "stall_identity", 0x15, 0 },
		{ "stall_color", 0x20, 0x7FFF },
	};
	for (unsigned k = 0; k < 2; k++) {
		iprintf("\x1b[10;0H%-26s", s[k].name);
		run_direct(S0);
		gx_run_stall(GXPORT(s[k].cmd), s[k].v, MAX_STALL);
		for (int i = 0; i <= MAX_STALL; i++)
			buf_printf(b, "%s,%d,%lu\n", s[k].name, i, (unsigned long)(g_stall[i] - g_stall[0]));
	}
}

static void swap_tests(Buf* b)
{
	static const int lines[] = { 0, 64, 128, 190, 191, 192, 193, 200, 230, 261, 262 };
	buf_printf(b, "line,param,rep,cycles,vcount_end\n");
	iprintf("\x1b[10;0H%-26s", "swap_buffers");
	for (unsigned k = 0; k < sizeof lines / sizeof lines[0]; k++)
		for (u32 p = 0; p < 2; p++)
			for (int r = 0; r < REPS; r++) {
				u16 vc;
				u32 c = gx_run_swap(lines[k], p, &vc);
				buf_printf(b, "%d,%lu,%d,%lu,%u\n", lines[k], (unsigned long)p, r, (unsigned long)c, vc);
			}
	// SWAP at line 150 with N triangles in polygon RAM (submitted from line 0).
	buf_printf(b, "# swap with polygons: polys,rep,cycles,vcount_end\n");
	static const int npoly[] = { 0, 1, 500, 1000, 2000 };
	for (unsigned k = 0; k < sizeof npoly / sizeof npoly[0]; k++)
		for (int r = 0; r < REPS; r++) {
			run_direct(S0);
			gx_run_swap(192, 0, &(u16){0});   // fresh lists
			wait_vcount(0);
			gx_put(GXPORT(0x40), 0);
			for (int i = 0; i < npoly[k]; i++) {
				u32 x = (i & 31) * 0x40, y = ((i >> 5) & 31) * 0x40;
				gx_put(GXPORT(0x23), XY(x, y)); gx_put(GXPORT(0x23), 0);
				gx_put(GXPORT(0x23), XY(x + 0x40, y)); gx_put(GXPORT(0x23), 0);
				gx_put(GXPORT(0x23), XY(x, y + 0x40)); gx_put(GXPORT(0x23), 0);
			}
			gx_wait(GXSTAT_BUSY);
			u16 vc0 = R_VCOUNT, vc;
			u32 c = gx_run_swap(150, 0, &vc);
			buf_printf(b, "swap_poly,%d,%d,%lu,%u,start_vcount=%u\n", npoly[k], r, (unsigned long)c, vc, vc0);
		}
}

int main(void)
{
	hw_init(VERSION " - GX timing");
	if (hw_fat_ok) remove(HWREF_DIR "/gxtime_progress.txt");
	progress("%s start", VERSION);
	videoSetMode(MODE_0_3D);
	R_DISP3DCNT = 0;
	R_GXSTAT = 1u << 15;

	Buf info = {0}, sum = {0}, stall = {0}, swp = {0};
	buf_printf(&info, "%s\nbuilt %s %s\n", VERSION, __DATE__, __TIME__);
	buf_printf(&info, "clock: TM0+TM1 cascade, 33513982 Hz (1 tick = 1 system cycle = 2 ARM9 cycles)\n");

	hw_status("timing tests (%d)", NTESTS);
	u32 t0 = now32();
	timing_tests(&sum, false);
	buf_printf(&info, "timing_tests_cycles %lu\n", (unsigned long)(now32() - t0));
	// Loop speed: last run's iterations over its duration.
	buf_printf(&info, "last_run_iters %lu\n", (unsigned long)g_iters);

	progress("dma/irq");
	hw_status("\n\nDMA and IRQ tests");
	dma_irq_tests();
	progress("stall/swap");
	hw_status("\n\nstall + swap tests");
	stall_tests(&stall);
	swap_tests(&swp);

	// Sample-loop period: a 20000-cycle-ish busy window (SWAP from line 16
	// is far longer) - iterations over the whole sampled time.
	run_direct(S0);
	int n = gx_run_drain(s_run, 0, 0, 0, 0, NULL, 0, true);
	unwrap(n);
	buf_printf(&info, "loop_calib cycles %lu iters %lu\n", (unsigned long)(n ? s_unw[n - 1] : 0), (unsigned long)g_iters);
	run_direct(S0);
	n = gx_run_drain(s_run, 0, 0, 1, 0, NULL, 0, true);
	unwrap(n);
	buf_printf(&info, "loop_calib_ext cycles %lu iters %lu\n", (unsigned long)(n ? s_unw[n - 1] : 0), (unsigned long)g_iters);

	buf_printf(&info, "timeouts %lu last_gxstat %08lx\n", (unsigned long)g_timeouts, (unsigned long)g_timeout_gxstat);
	progress("writing files, timeouts=%lu", (unsigned long)g_timeouts);
	iprintf("\x1b[14;0Hwriting files...\n");
	buf_write(&sum, "gxtime_summary.csv");
	buf_write(&s_ev, "gxtime_events.csv");
	buf_write(&stall, "gxtime_stall.csv");
	buf_write(&swp, "gxtime_swap.csv");
	buf_write(&info, "gxtime_info.txt");

	// Last: the sequences that hung the DS. Everything above is already on
	// the card; if this phase hangs, gxtime_progress.txt shows where.
	if (hw_chain) hw_done();   // the combined hwref.nds never runs the hang suspects
	iprintf("\x1b[14;0Hlast phase: hang suspects   \n(if it stops here, results\n are already saved)\n");
	progress("danger phase");
	Buf dsum = {0};
	timing_tests(&dsum, true);
	buf_printf(&dsum, "# timeouts %lu resets %lu reset_fail %lu dropped %lu\n", (unsigned long)g_timeouts,
	           (unsigned long)g_resets, (unsigned long)g_reset_fail, (unsigned long)g_dropped);
	buf_write(&dsum, "gxtime_danger.csv");
	buf_write(&s_ev, "gxtime_danger_events.csv");
	progress("danger phase done");
	hw_done();
}
