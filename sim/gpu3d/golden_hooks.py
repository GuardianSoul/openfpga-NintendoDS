#!/usr/bin/env python3
"""Simulation-only hooks in the golden's copy of melonDS's GPU3D_Soft.cpp
(applied after tools/melonds-census/ds-rules.patch; the census build does
not get them). All are off by default.

  g3d_sim_nolower: no second (lower) layer, as gpu3d_raster FEAT_LOWER = 0.
    The lower layer holds the clear entry everywhere and every write to it
    is discarded: it is set from the clear values at frame start and each
    line's lower layer is restored after every polygon scanline (a polygon
    never reads back its own writes on a line). AA, shadows and translucent
    edges then blend and test against the clear plane.
"""
import sys
p = sys.argv[1]
s = open(p).read()
a = "void SoftRenderer3D::RenderScanline(s32 y, int npolys)\n{"
assert s.count(a) == 1
s = s.replace(a, """bool g3d_sim_nolower = false;
static u32 g3d_low_c, g3d_low_z, g3d_low_a;

""" + a)
call = "                RenderPolygonScanline(rp, y);\n"
assert s.count(call) == 1
# after the whole if/else (the branches have no braces)
s = s.replace(call, call + """            if (g3d_sim_nolower)
                for (int x = 0; x < 256; x++)
                {
                    u32 a = FirstPixelOffset + (y*ScanlineWidth) + x + BufferSize;
                    ColorBuffer[a] = g3d_low_c; DepthBuffer[a] = g3d_low_z; AttrBuffer[a] = g3d_low_a;
                }
""")
# ClearBuffers: seed the lower layer
a = "void SoftRenderer3D::ClearBuffers()\n{\n"
i = s.index(a); j = s.index("\n}\n", i)
body_end = j
seed = """
    if (g3d_sim_nolower)
    {
        u32 r = (GPU3D.RenderClearAttr1 << 1) & 0x3E; if (r) r++;
        u32 g = (GPU3D.RenderClearAttr1 >> 4) & 0x3E; if (g) g++;
        u32 b = (GPU3D.RenderClearAttr1 >> 9) & 0x3E; if (b) b++;
        g3d_low_c = r | (g << 8) | (b << 16) | (((GPU3D.RenderClearAttr1 >> 16) & 0x1F) << 24);
        g3d_low_z = ((GPU3D.RenderClearAttr2 & 0x7FFF) * 0x200) + 0x1FF;
        g3d_low_a = (GPU3D.RenderClearAttr1 & 0x3F000000) | (GPU3D.RenderClearAttr1 & 0x8000);
        for (int y = 0; y < 192; y++)
            for (int x = 0; x < 256; x++)
            {
                u32 a = FirstPixelOffset + (y*ScanlineWidth) + x + BufferSize;
                ColorBuffer[a] = g3d_low_c; DepthBuffer[a] = g3d_low_z; AttrBuffer[a] = g3d_low_a;
            }
    }"""
s = s[:body_end] + seed + s[body_end:]
open(p, "w").write(s)
