#!/usr/bin/env python3
"""Apply the bounded DS OBJ rule to the standalone copied Census renderer.

This is a focused reference patch, not a shipping Census rule rollout.
Original dimensions/addressing remain intact when the work frontier clips.
"""
from pathlib import Path
import sys
def patch(path):
    t=path.read_text()
    def replace(a,b):
        nonlocal t
        assert t.count(a)==1,(a,t.count(a));t=t.replace(a,b)
    replace('void SoftRenderer2D::DrawSprites(u32 line)\n{',
      '''// The renderer is serial; this frontier applies only to the immediate
// DrawSprite call. It does not alter dimensions used for texture addressing.
static u32 dsObjWorkPixels;
void SoftRenderer2D::DrawSprites(u32 line)
{
    const bool dsWorkLimit = !(GPU2D.DispCnt & (1u<<23));
    s32 dsWorkLeft = 2124;''')
    replace('''        if (sprtype == 2) // disabled
            continue;''','''        if (dsWorkLimit && dsWorkLeft <= 0) break;
        if (sprtype == 2) // disabled
        {
            if (dsWorkLimit) dsWorkLeft -= 2;
            continue;
        }''')
    replace('''        if (sprtype & 1)
            DoDrawSprite(Rotscale''','''        // Preserve the RTL's existing non-drawing bitmap skip policy.
        const bool bitmap = !iswin && ((attrib[0]>>10)&3)==3;
        const bool bitmapSkip = bitmap && (!(attrib[2]>>12) || ((GPU2D.DispCnt & 0x60)==0x60));
        const s32 workSetup = (sprtype & 1) ? 10 : 0;
        const s32 workPixel = (sprtype & 1) ? 2 : 1;
        dsObjWorkPixels = dsWorkLimit ? std::max(0, std::min(boundwidth, (dsWorkLeft-workSetup)/workPixel)) : boundwidth;
        if (dsWorkLimit && !bitmapSkip) dsWorkLeft -= workSetup + workPixel*boundwidth;
        if (sprtype & 1)
            DoDrawSprite(Rotscale''')
    # Affine uses boundwidth as its loop end after clipping, normal xend.
    replace('''    s16 rotA = (s16)rotparams[0];''','''    boundwidth = std::min(boundwidth, dsObjWorkPixels);
    s16 rotA = (s16)rotparams[0];''')
    replace('''    u32 xend = width;''','''    u32 xend = std::min(width, dsObjWorkPixels);''')
    path.write_text(t)
if __name__=='__main__':patch(Path(sys.argv[1]))
