#!/usr/bin/env python3
# Make the two renderer copies for the budget-3D study (docs/budget-3d.md)
# from melonDS's GPU3D_Soft.{h,cpp}:
#   E: unmodified apart from public members (the tool reads AttrBuffer)
#   A: class SoftRenderer3DA with the approximations of architecture 3,
#      switched at run time by apx_flags / apx_prec (approx.h)
import sys, re
src, out = sys.argv[1], sys.argv[2]
h = open(f"{src}/GPU3D_Soft.h").read()
c = open(f"{src}/GPU3D_Soft.cpp").read()
hE = h.replace("private:", "public:")
open(f"{out}/GPU3D_SoftE.h", "w").write(hE)
open(f"{out}/GPU3D_SoftE.cpp", "w").write(c.replace('#include "GPU3D_Soft.h"', '#include "GPU3D_SoftE.h"'))

hA = hE.replace("SoftRenderer3D", "SoftRenderer3DA")
hA = re.sub(r"#ifndef (\w+)\n#define \1", r"#ifndef \1_A\n#define \1_A", hA, count=1)
def rep(s, a, b):
    assert s.count(a) == 1, a[:60]
    return s.replace(a, b)
hA = rep(hA, "namespace melonDS\n{", '#include "approx.h"\nnamespace melonDS\n{')
# A1: the perspective factor by a reciprocal of limited precision
hA = rep(hA, """                if (den == 0) yfactor = 0;
                else          yfactor = num / den;""",
"""                if (den == 0) yfactor = 0;
                else          yfactor = (apx_flags & APX_FACTOR) ? apx_div(num, den) : num / den;""")
# A2: linear interpolation by the (1<<22)/xdiff reciprocal, no division
hA = rep(hA, """                if (y0 < y1)
                    return y0 + (s64)(y1-y0) * x / xdiff;
                else
                    return y1 + (s64)(y0-y1) * (xdiff - x) / xdiff;""",
"""                if (apx_flags & APX_LINX)
                {
                    if (y0 < y1) return y0 + (s32)apx_lindiv((s64)(y1-y0) * x, xdiff);
                    else         return y1 + (s32)apx_lindiv((s64)(y0-y1) * (xdiff - x), xdiff);
                }
                if (apx_flags & APX_LINEAR)
                {
                    if (y0 < y1) return y0 + (s32)(((s64)(y1-y0) * x * xrecip_z) >> 22);
                    else         return y1 + (s32)(((s64)(y0-y1) * (xdiff - x) * xrecip_z) >> 22);
                }
                if (y0 < y1)
                    return y0 + (s64)(y1-y0) * x / xdiff;
                else
                    return y1 + (s64)(y0-y1) * (xdiff - x) / xdiff;""")
# A3: Z along Y in one wide multiply, without the normalising shifts
hA = rep(hA, """                    int shift = 0;
                    while (disp > 0x3FF)""",
"""                    if (apx_flags & APX_ZNORM)
                        return base + (s32)(((s64)disp * factor * xrecip_z) >> 22);
                    int shift = 0;
                    while (disp > 0x3FF)""")
# hardware-matching experiments: the factor's precision and rounding
hA = rep(hA, """                this->shift = 9;
            }""", """                this->shift = 9;
                if (apx_flags & APX_SHIFT) this->shift = apx_yshift;
            }""")
hA = rep(hA, """                this->shift = 8;
            }""", """                this->shift = 8;
                if (apx_flags & APX_SHIFT) this->shift = apx_xshift;
            }""")
hA = rep(hA, """                u32 num = (x * w0n) << shift;
                u32 den = (x * w0d) + ((xdiff-x) * w1d);""", """                u32 num = (x * w0n) << shift;
                u32 den = (x * w0d) + ((xdiff-x) * w1d);
                if (apx_flags & APX_SHIFT)
                {
                    u64 n64 = (u64)(x * w0n) << shift;
                    yfactor = den ? (s32)(n64 / den) : 0;
                    return;
                }""")
hA = rep(hA, """                if (y0 < y1)
                    return y0 + (((y1-y0) * yfactor) >> shift);
                else
                    return y1 + (((y0-y1) * ((1<<shift)-yfactor)) >> shift);""", """                if (apx_flags & (APX_SHIFT | APX_ROUND))
                {
                    s64 h = (apx_flags & APX_ROUND) ? ((s64)1 << (shift - 1)) : 0;
                    if (y0 < y1) return y0 + (s32)((((s64)(y1-y0) * yfactor) + h) >> shift);
                    else         return y1 + (s32)((((s64)(y0-y1) * (((s64)1<<shift)-yfactor)) + h) >> shift);
                }
                if (y0 < y1)
                    return y0 + (((y1-y0) * yfactor) >> shift);
                else
                    return y1 + (((y0-y1) * ((1<<shift)-yfactor)) >> shift);""")
open(f"{out}/GPU3D_SoftA.h", "w").write(hA)
c2 = c.replace("u32 color = RenderPixel(polygon, vr>>3, vg>>3, vb>>3, s, t);",
               "apx_toonidx = (vr > 15 ? vr - 15 : 0) >> 4;\n        u32 color = RenderPixel(polygon, vr>>3, vg>>3, vb>>3, s, t);")
assert c2.count("apx_toonidx = ") == 3
c2 = c2.replace("GPU3D.RenderToonTable[vr >> 1]", "GPU3D.RenderToonTable[(apx_flags & APX_TOON) ? apx_toonidx : (vr >> 1)]")
assert c2.count("APX_TOON") == 2
_i = c2.index("void SoftRenderer3D::RenderPolygonScanline")
c2 = c2[:_i] + c2[_i:].replace("""    if (xstart > xend)
    {
        vlcur = polygon->Vertices[rp->CurVR];""", """    if ((apx_flags & 512) && y >= 139 && y <= 146 && polygon->NumVertices <= 4)
        fprintf(stderr, "y %d XL %d XR %d xs %d xe %d incL %d incR %d negL %d negR %d xmL %d xmR %d nv %d\\n", y, rp->XL, rp->XR, xstart, xend,
                rp->SlopeL.Increment, rp->SlopeR.Increment, rp->SlopeL.Negative, rp->SlopeR.Negative, rp->SlopeL.XMajor, rp->SlopeR.XMajor, polygon->NumVertices);
    if (xstart > xend)
    {
        vlcur = polygon->Vertices[rp->CurVR];""", 1)
_i = c2.index("void SoftRenderer3D::RenderPolygonScanline")
c2 = c2[:_i] + c2[_i:].replace("""    // interpolate attributes along Y
""", """    if ((apx_flags & 512) && y >= 139 && y <= 146 && polygon->NumVertices <= 4 && xstart < 20)
        fprintf(stderr, "y %d aa %d lcov %08x rcov %08x llen %d rlen %d lfill %d rfill %d\\n", y, (GPU3D.RenderDispCnt >> 4) & 1, l_edgecov, r_edgecov, l_edgelen, r_edgelen, l_filledge, r_filledge);
    // interpolate attributes along Y
""", 1)
c2 = c2.replace("""            if (coverage == 0)
            {
                ColorBuffer[pixeladdr] = ColorBuffer[pixeladdr+BufferSize];
                continue;
            }""", """            if (coverage == 0 && (!(apx_flags & APX_AACOV0) || (ColorBuffer[pixeladdr+BufferSize] >> 24) & 0x1F))
            {
                ColorBuffer[pixeladdr] = ColorBuffer[pixeladdr+BufferSize];
                continue;
            }""", 1)
cA = c2.replace('#include "GPU3D_Soft.h"', '#include "GPU3D_SoftA.h"').replace("SoftRenderer3D", "SoftRenderer3DA").replace("DepthTest_", "DepthTestA_")
open(f"{out}/GPU3D_SoftA.cpp", "w").write(cA)
