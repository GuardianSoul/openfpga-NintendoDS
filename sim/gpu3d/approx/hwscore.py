#!/usr/bin/env python3
# hwscore.py <scenes-dir> <ds-capture-dir> <approx_cmp> : renders the cap3d
# scenes (docs/hw-reference.md) with the exact model (= melonDS) and the
# approximate variants and scores each against the real DS's 3D-layer captures
import subprocess, sys, os, tempfile
scn, dsdir, tool = sys.argv[1:4]
# optional: variants as "name:flags[:extra args]" after the three paths
extra = sys.argv[4:]
names = ["gouraud", "persp_00", "persp_30", "persp_60", "persp_80", "persp_80_wbuf", "tex_seam", "tex_formats",
         "tex_blend", "depth_z", "depth_w", "aa_opaque", "aa_translucent", "aa_over_2d", "ui_text", "fog",
         "fog_alpha_only", "toon", "highlight", "edge_mark", "edge_mark_aa", "lighting", "clip", "shadow",
         "shadow_cull6", "shadow_cull7", "alpha_test", "trans_sort_y", "trans_sort_manual"]
files = sorted(f for f in os.listdir(scn) if f.endswith(".scn"))[1:]   # the first flush is a warm-up
variants = [("exact (melonDS, RECIP)", 0), ("arch 3 (A1+A2+A3)", 7), ("A1 factor", 1), ("A2 linear", 2), ("A3 Z", 4)]
if extra:
    variants = [(e.split(":")[0], e.split(":")[1:]) for e in extra]
res = {}
for vn, fl in variants:
    args = []
    if isinstance(fl, list):
        args = fl[1].split() if len(fl) > 1 else []
        fl = int(fl[0])
    d = tempfile.mkdtemp()
    subprocess.run([tool, "--flags", str(fl), "--prec", "16", "--raw555", d] + args + [f"{scn}/{f}" for f in files],
                   stdout=subprocess.DEVNULL, check=True)
    for f, n in zip(files, names):
        dsf = f"{dsdir}/cap3d_{n}_3d.bin"
        if not os.path.exists(dsf): continue
        ds = open(dsf, "rb").read(); m = open(f"{d}/{f}.a.bin" if fl else f"{d}/{f}.e.bin", "rb").read()
        diff = 0; mx = 0
        for i in range(0, len(ds), 2):
            a = ds[i] | ds[i+1] << 8; b = m[i] | m[i+1] << 8
            if a != b:
                diff += 1
                mx = max(mx, max(abs(((a >> s) & 31) - ((b >> s) & 31)) for s in (0, 5, 10)))
        res.setdefault(n, {})[vn] = (diff, mx)
print("| scene | " + " | ".join(v for v, _ in variants) + " |")
print("| --- |" + " ---: |" * len(variants))
tot = {v: 0 for v, _ in variants}
for n in names:
    if n not in res: continue
    print(f"| {n} | " + " | ".join(f"{res[n][v][0]} ({res[n][v][1]})" for v, _ in variants) + " |")
    for v, _ in variants: tot[v] += res[n][v][0]
print("| **total px** | " + " | ".join(str(tot[v]) for v, _ in variants) + " |")
