/* Result block at main RAM 0x023F0000 (physical), written by the ARM9:
     +0x00 u32 magic 'DSTR' (0x52545344)
     +0x04 u32 number of checks N (<= 32)
     +0x08 u32 pass bitmask (bit i = check i passed)
     +0x0C u32 done flag (1 when every check has been recorded)
     +0x10 u32 value[N] (the measured value of each check)
   The same results are drawn as text: the top screen shows the title, the
   mask in hex against the all-pass mask, and checks 0-19; the bottom
   screen shows checks 20-31 from row 4. */
#ifndef RESULTS_H
#define RESULTS_H
#include "ds.h"

#define RESULT_MAGIC 0x52545344u

typedef struct {
    volatile u32 magic, n, mask, done;
    volatile u32 value[32];
} result_t;
#define RESULT ((result_t *)RESULT_ADDR)

void res_begin(const char *title, int n);
int  res_record(int i, const char *name, u32 value, int pass);
int  res_check(int i, const char *name, u32 value, u32 expected);
void res_finish(void);

#endif
