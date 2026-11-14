// gxtest (docs/hw-reference.md "gxtest"): the DS's cost of BOX_TEST, POS_TEST and VEC_TEST in context, and of
// the NORMAL pipeline paid by the command after a NORMAL (geometry session, gpu3d_gxfront CHEAP's timing table,
// ds-rules "GX command costs").
//
// Already on the DS (gxtime run 3 / run 8): BOX_TEST inside 257 / outside 103 / one partial box 519, POS_TEST 7.1,
// VEC_TEST 5.3 back to back, MTX_MULT_4x4 34.5-65.4, NORMAL 9.0-12.1 back to back. Open, and asked here:
//   - BOX_TEST by box size (zero, tiny, small, nearly the view volume, enclosing it) and by clip outcome (each
//     side outside, just past a plane, partly visible across one, two or three planes, near and far, and a rotated
//     box near a frustum corner that no single plane rejects, inside and outside);
//   - POS_TEST / VEC_TEST alone (iso: one test from idle), back to back (drain slope), alternating, and interleaved
//     with vertices in an open triangle list (after each vertex, after each triangle);
//   - NORMAL followed by COLOR / TEXCOORD / IDENTITY / POS_TEST / VEC_TEST (1 and 4 lights): melonDS's model
//     charges the NORMAL pipeline (7 cycles) to any next command that is not a vertex.
// Method: gxtime's (sw/hwref/gxtime): SWAP_BUFFERS at VCOUNT 16, prefix + n bodies queued behind it (at most 240
// FIFO entries, so the CPU never stalls on a full FIFO); the engine waits for VBlank, then drains on its own.
// D(n) = idle - first FIFO-level drop (the minimum of 3 repetitions); cycles per body = (D(n2) - D(n1)) / (n2 - n1).
// iso: one body written from idle, cycles until GXSTAT busy (bit 27) or the test bit (bit 0) clears.
// Hang-safe: every wait is bounded (gxtime/run.itcm.c: gx_wait/gx_put recover a stuck engine, never store into a
// full FIFO), each case is appended to gxtest_v1.csv when it ends, gxtest_v1_progress.txt records "start"/"done"
// per case: a rerun after a hang skips the cases that ran and the one that hung (the checker reports it). BOX_TEST
// never runs inside an open vertex list (that locked the DS, run 3); the cases with tests inside a vertex list run
// last, VEC_TEST inside a list (never run on the DS) at the very end.
#include "../gxtime/gxtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VERSION "gxtest 1"
#define PROGRESS "gxtest_v1_progress.txt"
#define CSV "gxtest_v1.csv"
#define EVENTS "gxtest_v1_events.csv"
#define E 0xFFFFFFFFu

static const u8 s_np[256] = {
	[0x10] = 1, [0x11] = 0, [0x12] = 1, [0x13] = 1, [0x14] = 1, [0x15] = 0,
	[0x16] = 16, [0x17] = 12, [0x18] = 16, [0x19] = 12, [0x1A] = 9,
	[0x1B] = 3, [0x1C] = 3, [0x20] = 1, [0x21] = 1, [0x22] = 1, [0x23] = 2,
	[0x24] = 1, [0x25] = 1, [0x26] = 1, [0x27] = 1, [0x28] = 1, [0x29] = 1,
	[0x2A] = 1, [0x2B] = 1, [0x30] = 1, [0x31] = 1, [0x32] = 1, [0x33] = 1,
	[0x34] = 32, [0x40] = 1, [0x41] = 0, [0x50] = 1, [0x60] = 1,
	[0x70] = 3, [0x71] = 2, [0x72] = 1,
};

// 1.0 = 0x1000 (4.12); the identity projection puts the planes at |x|, |y|, |z| = w = 1.0
#define XY(x, y) (((u32)(x) & 0xFFFF) | ((u32)(y) << 16))
#define P10(x, y, z) (((u32)(x) & 0x3FF) | (((u32)(y) & 0x3FF) << 10) | (((u32)(z) & 0x3FF) << 20))
#define Q 0x400
#define V16(x, y, z) 0x23, XY(x, y), (u32)(z)
#define TRI V16(0, 0, 0), V16(Q, 0, 0), V16(0, Q, 0)
#define NRM 0x21, P10(0, 0, -511)
#define BOX(x, y, z, w, h, d) 0x70, XY(x, y), XY(z, w), XY(h, d)
#define POS(x, y, z) 0x71, XY(x, y), (u32)(z)
#define VEC 0x72, P10(0, 0, -511)
// 45 degrees about Z, as MTX_LOAD_4x3 rows (x axis -> (c, s)): cos = sin = 0.7071 = 0xB50
#define ROT45 0x17, 0xB50, 0xB50, 0, (u32)-0xB50, 0xB50, 0, 0, 0, 0x1000, 0, 0, 0
// a box of side 0.4243 (0x6C8) centred on (D, 0, 0) in object space: after ROT45 a diamond |x-c|+|y-c| <= 0.3
// around (c, c), c = D / sqrt 2. c = 1.1 overlaps the view's corner (1, 1); c = 1.2 misses it, with corners
// outside x only and outside y only, so no single plane rejects it.
#define RBOX(x0) BOX(x0, -0x364, -0x364, 0x6C8, 0x6C8, 0x6C8)

// Everything a case may have changed, reset before each setup (gxtime's S0): END, identity matrices (mode 2 last,
// so MTX_MODE is 2), viewport, attributes, material, lights.
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
	const u32* setup;   // written directly after S0 (not timed)
	const u32* prefix;  // queued once behind the SWAP
	const u32* body;    // queued n times
	int box;            // expected BOX_TEST result (GXSTAT bit 1) after the run, -1: no BOX_TEST, 2: open (DS decides)
} Case;

#define L(...) (const u32[]){ __VA_ARGS__, E }
#define NONE NULL
#define LIT1 L(0x29, 0x001F00C1)
#define LIT4 L(0x29, 0x001F00CF)

// In run order: no vertex list first, then tests inside a triangle list (POS_TEST there ran on the DS in run 3),
// VEC_TEST inside a list last.
static const Case s_cases[] = {
	// BOX_TEST by size, inside (controls: box_in_q = run 3's box_test, 257)
	{ "box_in_q",          NONE, NONE, L(BOX(0, 0, 0, Q, Q, Q)), 1 },
	{ "box_in_tiny",       NONE, NONE, L(BOX(0, 0, 0, 1, 1, 1)), 1 },
	{ "box_in_zero",       NONE, NONE, L(BOX(0x100, 0x100, 0x100, 0, 0, 0)), 1 },
	{ "box_in_big",        NONE, NONE, L(BOX(-0xF00, -0xF00, -0xF00, 0x1E00, 0x1E00, 0x1E00)), 1 },
	{ "box_in_edge",       NONE, NONE, L(BOX(0xC00, 0, 0, 0x400, Q, Q)), 1 },      // x 0.75 .. 1.0 exactly
	// outside each plane (control: box_out_right = run 3's box_test_out, 103)
	{ "box_out_right",     NONE, NONE, L(BOX(0x3000, 0, 0, Q, Q, Q)), 0 },
	{ "box_out_left",      NONE, NONE, L(BOX(-0x3000, 0, 0, Q, Q, Q)), 0 },
	{ "box_out_top",       NONE, NONE, L(BOX(0, 0x3000, 0, Q, Q, Q)), 0 },
	{ "box_out_bottom",    NONE, NONE, L(BOX(0, -0x3000, 0, Q, Q, Q)), 0 },
	{ "box_out_near",      NONE, NONE, L(BOX(0, 0, -0x3000, Q, Q, Q)), 0 },
	{ "box_out_far",       NONE, NONE, L(BOX(0, 0, 0x3000, Q, Q, Q)), 0 },
	{ "box_out_just",      NONE, NONE, L(BOX(0x1001, 0, 0, Q, Q, Q)), 0 },        // 1/4096 past x = 1
	// partly visible (control: box_part_x = run 8's box_test_partial, 519)
	{ "box_part_x",        NONE, NONE, L(BOX(0xE00, 0, 0, Q, Q, Q)), 1 },
	{ "box_part_xhalf",    NONE, NONE, L(BOX(0x800, 0, 0, 0x1000, Q, Q)), 1 },
	{ "box_part_xy",       NONE, NONE, L(BOX(0xE00, 0xE00, 0, Q, Q, Q)), 1 },
	{ "box_part_xyz",      NONE, NONE, L(BOX(0xE00, 0xE00, 0xE00, Q, Q, Q)), 1 },
	{ "box_part_near",     NONE, NONE, L(BOX(0, 0, -0x1200, Q, Q, Q)), 1 },
	{ "box_part_far",      NONE, NONE, L(BOX(0, 0, 0xE00, Q, Q, Q)), 1 },
	{ "box_enclose",       NONE, NONE, L(BOX(-0x2000, -0x2000, -0x2000, 0x4000, 0x4000, 0x4000)), 2 },  // melonDS 0 (faces only)
	{ "box_enclose_xy",    NONE, NONE, L(BOX(-0x2000, -0x2000, 0, 0x4000, 0x4000, Q)), 1 },
	// rotated (position matrix ROT45; MTX_MODE 2 from S0)
	{ "box_rot_in",        L(ROT45), NONE, L(BOX(-0x200, -0x200, -0x200, 0x400, 0x400, 0x400)), 1 },
	{ "box_rot_corner_in", L(ROT45), NONE, L(RBOX(0x157F)), 1 },                   // c = 1.1
	{ "box_rot_corner_out", L(ROT45), NONE, L(RBOX(0x17C3)), 0 },                  // c = 1.2
	// POS_TEST / VEC_TEST outside a list (controls: pos_alone 7.1, vec_alone 5.3, run 3)
	{ "pos_alone",         NONE, NONE, L(POS(0, 0, 0)), -1 },
	{ "pos_out",           NONE, NONE, L(POS(0x3000, -0x3000, 0x3000)), -1 },
	{ "vec_alone",         NONE, NONE, L(VEC), -1 },
	{ "pos_vec",           NONE, NONE, L(POS(0, 0, 0), VEC), -1 },
	{ "box_pos",           NONE, NONE, L(BOX(0, 0, 0, Q, Q, Q), POS(0, 0, 0)), 1 },
	// what follows a NORMAL (inside BEGIN without vertices, as gxtime's normal_l*; lights are latched at BEGIN)
	{ "nrm_color_l1",      LIT1, L(0x40, 0), L(NRM, 0x20, 0x7FFF), -1 },
	{ "nrm_color_l4",      LIT4, L(0x40, 0), L(NRM, 0x20, 0x7FFF), -1 },
	{ "nrm_texcoord_l1",   LIT1, L(0x40, 0), L(NRM, 0x22, 0), -1 },
	{ "nrm_identity_l1",   LIT1, L(0x40, 0), L(NRM, 0x15), -1 },
	{ "nrm_pos_l1",        LIT1, L(0x40, 0), L(NRM, POS(0, 0, 0)), -1 },
	{ "nrm_vec_l1",        LIT1, L(0x40, 0), L(NRM, VEC), -1 },
	{ "nrm_vec_l4",        LIT4, L(0x40, 0), L(NRM, VEC), -1 },
	// inside a triangle list (vtx_only and tri_only: controls)
	{ "vtx_only",          NONE, L(0x40, 0), L(TRI), -1 },
	{ "tri_pos",           NONE, L(0x40, 0), L(TRI, POS(0, 0, 0)), -1 },   // run 3's tri_then_pos_test
	{ "vtx_pos",           NONE, L(0x40, 0), L(V16(0, 0, 0), POS(0, 0, 0), V16(Q, 0, 0), POS(0, 0, 0), V16(0, Q, 0), POS(0, 0, 0)), -1 },
	{ "tri_vec",           NONE, L(0x40, 0), L(TRI, VEC), -1 },
	{ "vtx_vec",           NONE, L(0x40, 0), L(V16(0, 0, 0), VEC, V16(Q, 0, 0), VEC, V16(0, Q, 0), VEC), -1 },
};
#define NCASES (int)(sizeof s_cases / sizeof s_cases[0])

static Wr s_run[300] DTCM_BSS;
static int s_nrun;

static void emit(const u32* l)
{
	while (l && *l != E) {
		u32 cmd = *l++;
		int np = s_np[cmd];
		vu32* port = GXPORT(cmd);
		if (s_nrun + (np ? np : 1) > (int)(sizeof s_run / sizeof s_run[0])) { g_dropped++; return; }
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
	iprintf("\x1b[12;0HTIMEOUT in %-18s\n gxstat=%08lx resets=%lu fail=%lu ", s_cur,
	        (unsigned long)g_timeout_gxstat, (unsigned long)g_resets, (unsigned long)g_reset_fail);
}

static void setup(const Case* c)
{
	run_direct(S0);
	run_direct(c->setup);
	R_GXSTAT = 1u << 15;  // ack a matrix stack error
}

static u32 s_unw[MAX_SAMPLES];
static Buf s_ev;

static void unwrap(int n)
{
	u32 t = 0;
	for (int i = 0; i < n; i++) {
		if (i) t += (u16)(g_samples[i].t - g_samples[i - 1].t);
		s_unw[i] = t;
	}
}

// D = end - first FIFO-level drop below its maximum (gxtime's drain_time); 0 if there was no drop.
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

static u32 s_last_stat;
static int s_last_n;

static u32 run_drain(const Case* c, int nb, int rep)
{
	setup(c);
	s_nrun = 0;
	emit(c->prefix);
	for (int k = 0; k < nb; k++) emit(c->body);
	int n = gx_run_drain(s_run, s_nrun, 0, 0, 0, NULL, 0, true);
	unwrap(n);
	s_last_n = n;
	s_last_stat = n ? g_samples[n - 1].s : R_GXSTAT;
	if (rep == 0)
		for (int i = 0; i < n; i++)
			buf_printf(&s_ev, "%s,%d,%d,%lu,%08lx\n", c->name, nb, i, (unsigned long)s_unw[i],
			           (unsigned long)g_samples[i].s);
	return n >= MAX_SAMPLES - 1 ? 0 : drain_time(n);
}

static u32 run_iso(const Case* c, u32 mask)
{
	setup(c);
	s_nrun = 0;
	emit(c->prefix);
	for (int i = 0; i < s_nrun; i++) gx_put(s_run[i].a, s_run[i].v);
	gx_wait(GXSTAT_BUSY);
	s_nrun = 0;
	emit(c->body);
	return gx_run_iso(s_run, s_nrun, mask);
}

static int cmp_u32(const void* a, const void* b)
{
	u32 x = *(const u32*)a, y = *(const u32*)b;
	return x < y ? -1 : x > y;
}

#define REPS 3
#define ISO_REPS 5
#define FIFO_ENTRIES 240

static bool run_case(const Case* c, int k)
{
	char key[48];
	snprintf(key, sizeof key, "gxtest1_%s", c->name);
	if (!hw_step_begin(PROGRESS, key)) return true;   // ran before (or hung there): skipped
	iprintf("\x1b[10;0H%2d/%d %-20s", k + 1, NCASES, c->name);
	s_cur = c->name;
	u32 to0 = g_timeouts, rs0 = g_resets, dr0 = g_dropped;
	int wb = count_writes(c->body), wp = count_writes(c->prefix);
	int n2 = (FIFO_ENTRIES - wp) / wb;
	if (n2 > 64) n2 = 64;
	int n1 = n2 / 4;
	if (n1 < 1) n1 = 1;
	while (n1 * wb + wp < 12) n1++;
	u32 d1 = ~0u, d2 = ~0u, stat1 = 0, stat2 = 0;
	int smax = 0;
	for (int r = 0; r < REPS; r++) {
		u32 a = run_drain(c, n1, r);
		if (!r) stat1 = s_last_stat;
		if (s_last_n > smax) smax = s_last_n;
		u32 b = run_drain(c, n2, r);
		if (!r) stat2 = s_last_stat;
		if (s_last_n > smax) smax = s_last_n;
		if (a < d1) d1 = a;
		if (b < d2) d2 = b;
	}
	// results of the last run (n2 bodies): POS_RESULT and VEC_RESULT, for a state check against melonDS
	u32 pr[4], vr[2];
	for (int i = 0; i < 4; i++) pr[i] = REG32(0x04000620 + 4 * i);
	vr[0] = REG32(0x04000630); vr[1] = REG16(0x04000634);
	u32 iso[ISO_REPS], iso0[ISO_REPS];
	for (int r = 0; r < ISO_REPS; r++) iso[r] = run_iso(c, GXSTAT_BUSY);
	for (int r = 0; r < ISO_REPS; r++) iso0[r] = run_iso(c, 1);
	qsort(iso, ISO_REPS, sizeof iso[0], cmp_u32);
	qsort(iso0, ISO_REPS, sizeof iso0[0], cmp_u32);
	s32 per = n2 > n1 && d1 && d2 ? (s32)((s64)((s32)d2 - (s32)d1) * 100 / (n2 - n1)) : 0;
	Buf row = {0};
	buf_printf(&row, "%s,%d,%d,%d,%d,%lu,%lu,%ld,%lu,%lu,%lu,%d,%lu,%lu,%08lx,%08lx,%08lx,%08lx,%08lx,%08lx,%08lx,%08lx,%d,%lu,%lu,%lu\n",
	           c->name, wb, wp, n1, n2, (unsigned long)d1, (unsigned long)d2, (long)per,
	           (unsigned long)iso[0], (unsigned long)iso[ISO_REPS / 2], (unsigned long)iso0[0],
	           c->box, (unsigned long)((stat1 >> 1) & 1), (unsigned long)((stat2 >> 1) & 1),
	           (unsigned long)stat2, (unsigned long)pr[0], (unsigned long)pr[1], (unsigned long)pr[2],
	           (unsigned long)pr[3], (unsigned long)vr[0], (unsigned long)vr[1], (unsigned long)R_GXSTAT,
	           smax, (unsigned long)(g_timeouts - to0), (unsigned long)(g_resets - rs0), (unsigned long)(g_dropped - dr0));
	bool ok = buf_append(&row, CSV);
	ok = buf_append(&s_ev, EVENTS) && ok;
	ok = hw_step_done(PROGRESS, key) && ok;
	// a timed-out wait leaves the engine in an unknown state: stop, the rest runs on a restart
	return ok && g_timeouts == to0 && g_reset_fail == 0;
}

int main(void)
{
	hw_init(VERSION " - GX tests");
	videoSetMode(MODE_0_3D);
	R_DISP3DCNT = 0;
	R_GXSTAT = 1u << 15;
	hw_csv_header(CSV, "case,writes_per_body,prefix_writes,n1,n2,d1,d2,cyc_per_body_x100,iso_min,iso_med,iso_bit0_min,"
	                   "box_expect,box_n1,box_n2,gxstat_end,pos0,pos1,pos2,pos3,vec01,vec2,gxstat_after,samples_max,"
	                   "timeouts,resets,dropped\n");
	hw_csv_header(EVENTS, "case,n,sample,t,gxstat\n");
	Buf info = {0};
	buf_printf(&info, "%s\nbuilt %s %s\n", VERSION, __DATE__, __TIME__);
	buf_printf(&info, "clock: TM0+TM1 cascade, 33513982 Hz (1 tick = 1 system cycle = 2 ARM9 cycles)\n");
	buf_printf(&info, "cases %d; FIFO entries per run <= %d; reps %d (minimum D), iso reps %d\n", NCASES,
	           FIFO_ENTRIES, REPS, ISO_REPS);
	int k = 0;
	for (; k < NCASES; k++)
		if (!run_case(&s_cases[k], k)) break;
	buf_printf(&info, "%s: stopped after %d of %d cases; timeouts %lu resets %lu failed %lu dropped %lu\n",
	           k == NCASES ? "complete" : "INCOMPLETE", k, NCASES, (unsigned long)g_timeouts,
	           (unsigned long)g_resets, (unsigned long)g_reset_fail, (unsigned long)g_dropped);
	buf_append(&info, "gxtest_v1_info.txt");
	if (k < NCASES) hw_status("stopped at %s: restart to go on", s_cases[k].name);
	hw_done();
}
