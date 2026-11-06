#include "con.h"

extern const unsigned char font8x8[64][8];

/* engine A: VRAM bank A as BG (VRAMCNT_A = 0x81): map at 0x06000000,
   tiles at 0x06004000. engine B: bank C as BG B (VRAMCNT_C = 0x84):
   map at 0x06200000, tiles at 0x06204000. */
#define MAP(scr)   ((volatile u16 *)((scr) ? 0x06200000 : 0x06000000))
#define TILES(scr) ((volatile u32 *)((scr) ? 0x06204000 : 0x06004000))
#define BGPAL(scr) ((volatile u16 *)((scr) ? 0x05000400 : 0x05000000))

void con_clear(int scr)
{
    volatile u32 *m = (volatile u32 *)MAP(scr);
    for (int i = 0; i < 32 * 32 / 2; i++)
        m[i] = 0;
}

void con_init(void)
{
    POWCNT1 = 0x8203;            /* LCDs, 2D A, 2D B, engine A on top */
    VRAMCNT(0) = 0x81;           /* A -> engine A BG 0x06000000 */
    VRAMCNT(2) = 0x84;           /* C -> engine B BG 0x06200000 */
    for (int scr = 0; scr < 2; scr++) {
        volatile u32 *t = TILES(scr);
        for (int c = 0; c < 64; c++)
            for (int y = 0; y < 8; y++) {
                u32 b = font8x8[c][y], row = 0;
                for (int x = 0; x < 8; x++)
                    if (b & (0x80 >> x))
                        row |= 1u << (4 * x);
                t[c * 8 + y] = row;
            }
        volatile u16 *p = BGPAL(scr);
        p[0] = 0x2800;           /* backdrop: dark blue */
        p[1] = 0x7FFF;           /* bank 0: white */
        p[16 + 1] = 0x03E0;      /* bank 1: green */
        p[32 + 1] = 0x001F;      /* bank 2: red */
        p[48 + 1] = 0x03FF;      /* bank 3: yellow */
        con_clear(scr);
    }
    /* BG0: 4bpp text, 32x32, char base 1 (0x4000), screen base 0 */
    BG0CNT_A = 1 << 2;
    BG0CNT_B = 1 << 2;
    DISPCNT_A = 0x00010100;      /* graphics display, mode 0, BG0 on */
    DISPCNT_B = 0x00010100;
}

void con_puts(int scr, int x, int y, int pal, const char *s)
{
    volatile u16 *m = MAP(scr);
    for (; *s && x < 32; s++, x++) {
        int c = (u8)*s;
        if (c >= 'a' && c <= 'z')
            c -= 32;
        if (c < 0x20 || c >= 0x60)
            c = '?';
        m[y * 32 + x] = (u16)((c - 0x20) | (pal << 12));
    }
}

static char *put_num(char *o, u32 v, int base, int width, char pad, int neg)
{
    char buf[12];
    int n = 0;
    do {
        u32 d = base == 16 ? (v & 15) : v % 10;
        buf[n++] = (char)(d < 10 ? '0' + d : 'A' + d - 10);
        v = base == 16 ? v >> 4 : v / 10;
    } while (v);
    if (neg)
        buf[n++] = '-';
    while (n < width)
        buf[n++] = pad;
    while (n)
        *o++ = buf[--n];
    return o;
}

/* printf-lite: %s %c %d %u %x %X with optional 0 and width */
int fmt_str(char *out, const char *f, __builtin_va_list ap)
{
    char *o = out;
    for (; *f; f++) {
        if (*f != '%') { *o++ = *f; continue; }
        f++;
        char pad = ' ';
        int w = 0;
        if (*f == '0') { pad = '0'; f++; }
        while (*f >= '0' && *f <= '9')
            w = w * 10 + (*f++ - '0');
        switch (*f) {
        case 's': { const char *s = __builtin_va_arg(ap, const char *);
                    int l = 0; while (s[l]) l++;
                    while (l < w) { *o++ = ' '; w--; }
                    while (*s) *o++ = *s++; break; }
        case 'c': *o++ = (char)__builtin_va_arg(ap, int); break;
        case 'd': { s32 v = __builtin_va_arg(ap, s32);
                    o = put_num(o, v < 0 ? (u32)-v : (u32)v, 10, w, pad, v < 0); break; }
        case 'u': o = put_num(o, __builtin_va_arg(ap, u32), 10, w, pad, 0); break;
        case 'x': case 'X': o = put_num(o, __builtin_va_arg(ap, u32), 16, w, pad, 0); break;
        case '%': *o++ = '%'; break;
        default: *o++ = '?'; break;
        }
    }
    *o = 0;
    return (int)(o - out);
}

void con_printf(int scr, int x, int y, int pal, const char *fmt, ...)
{
    char buf[64];
    __builtin_va_list ap;
    __builtin_va_start(ap, fmt);
    fmt_str(buf, fmt, ap);
    __builtin_va_end(ap);
    con_puts(scr, x, y, pal, buf);
}

void wait_vblank(void)
{
    while (VCOUNT == 192)
        ;
    while (VCOUNT != 192)
        ;
}
