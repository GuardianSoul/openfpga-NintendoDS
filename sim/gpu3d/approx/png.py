#!/usr/bin/env python3
# png.py <rawdir> <outdir>: for each <name>.e.rgba / .a.rgba pair, a PNG with
# melonDS | approximate | difference (white: any change, red: error > 2), 2x scaled
import sys, os
from PIL import Image
raw, out = sys.argv[1], sys.argv[2]
for fn in sorted(os.listdir(raw)):
    if not fn.endswith(".e.rgba"): continue
    name = fn[:-7]
    e = open(f"{raw}/{name}.e.rgba", "rb").read(); a = open(f"{raw}/{name}.a.rgba", "rb").read()
    ie = Image.frombytes("RGBA", (256, 192), e).convert("RGB")
    ia = Image.frombytes("RGBA", (256, 192), a).convert("RGB")
    d = Image.new("RGB", (256, 192))
    pd = d.load(); pe = ie.load(); pa = ia.load()
    for y in range(192):
        for x in range(256):
            ce, ca = pe[x, y], pa[x, y]
            m = max(abs(ce[k] - ca[k]) for k in range(3))
            pd[x, y] = (0, 0, 0) if m == 0 else ((255, 0, 0) if m > 2 * 255 // 63 else (255, 255, 255))
    o = Image.new("RGB", (256 * 3 + 16, 192), (40, 40, 40))
    o.paste(ie, (0, 0)); o.paste(ia, (256 + 8, 0)); o.paste(d, (512 + 16, 0))
    o = o.resize((o.width * 2, o.height * 2), Image.NEAREST)
    o.save(f"{out}/{name.replace('.scn', '')}.png")
    print(f"{out}/{name.replace('.scn', '')}.png")
