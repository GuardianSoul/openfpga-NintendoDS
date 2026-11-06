// Run-time switches for the approximate renderer copy (budget-3D study).
#pragma once
#include <cstdint>
enum { APX_FACTOR = 1, APX_LINEAR = 2, APX_ZNORM = 4, APX_FIX = 8, APX_LINX = 16, APX_SHIFT = 32, APX_ROUND = 64, APX_TOON = 128, APX_AACOV0 = 1024 };
extern int apx_toonidx;   // APX_TOON: the toon index from the 9-bit red without the fill bits
extern int apx_xshift, apx_yshift;   // APX_SHIFT: factor precision along X / Y (melonDS 8 / 9)
extern int apx_flags;
extern int apx_prec;   // significant bits of the reciprocal
extern long apx_fixsteps, apx_divs;
extern int apx_fixmax, apx_fixmin;
// num / den by a reciprocal with apx_prec significant bits (a table, or a
// table plus one Newton step), as the hardware would form it
static inline uint32_t apx_div(uint32_t num, uint32_t den)
{
    int s = 31 - __builtin_clz(den);                 // den in [2^s, 2^(s+1))
    int drop = s > apx_prec ? s - apx_prec : 0;       // denominator bits kept: apx_prec+1
    uint64_t dt = den >> drop;
    uint64_t r = (uint64_t(1) << (2 * apx_prec + 2)) / dt;
    uint32_t q = uint32_t((uint64_t(num) * r) >> (2 * apx_prec + 2 + drop));
    if (apx_flags & APX_FIX)
    {
        // one correction step: q is low by at most a few with the truncated
        // reciprocal; step up while (q+1)*den <= num (the RTL would compare once
        // or twice: count the steps)
        int st = 0;
        while (uint64_t(q + 1) * den <= num) { q++; st++; }
        while (uint64_t(q) * den > num) { q--; st--; }
        apx_fixsteps += st != 0;
        if (st > apx_fixmax) apx_fixmax = st;
        if (st < apx_fixmin) apx_fixmin = st;
        apx_divs++;
    }
    return q;
}
// d*x/xdiff by a reciprocal ceil(2^40/xdiff): exact for d*x < 2^30, xdiff < 2^10
static inline int64_t apx_lindiv(int64_t dx, int32_t xdiff)
{
    uint64_t r = ((uint64_t(1) << 40) + uint64_t(xdiff) - 1) / uint64_t(xdiff);
    return int64_t((unsigned __int128)(uint64_t)dx * r >> 40);
}
