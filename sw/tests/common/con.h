/* Text console on both 2D engines (ARM9). Engine A = top screen (POWCNT1
   bit 15 set), engine B = bottom. 32x24 characters of the 8x8 font. */
#ifndef CON_H
#define CON_H
#include "ds.h"

enum { TOP = 0, BOTTOM = 1 };
enum { PAL_WHITE = 0, PAL_GREEN = 1, PAL_RED = 2, PAL_YELLOW = 3 };

void con_init(void);
void con_clear(int scr);
void con_puts(int scr, int x, int y, int pal, const char *s);
void con_printf(int scr, int x, int y, int pal, const char *fmt, ...);
int  fmt_str(char *out, const char *fmt, __builtin_va_list ap);
void wait_vblank(void);       /* polls VCOUNT: returns at the start of line 192 */

#endif
