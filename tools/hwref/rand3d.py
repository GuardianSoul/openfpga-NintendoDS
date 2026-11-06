#!/usr/bin/env python3
"""rand3d corpus tools (docs/hw-reference.md "rand3d").

  rand3d.py compare DS_DIR MEL_DIR [--out DIR] [--names ds,melonds]
      Unpacks both runs' rand3d_*.bin captures, diffs every scene both have,
      checks the polygon and vertex counts (rand3d_scenes.csv), and
      correlates mismatching scenes with scene features (which feature bits
      the mismatching scenes use more often). Writes report.md, PNGs of the
      worst scenes, and per-scene diff counts (scenes.csv).
  rand3d.py gxbin OUT FIRST COUNT [--counts rand3d_scenes.csv]
      The same scenes as a census GX trace, for gx2scene / the RTL.
  rand3d.py unpack DIR OUT
      One 256x192 u16 LE capture per scene (rand3d_NNNNN_3d.bin).
"""
import argparse
import csv
import glob
import io
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import png, to_rgb, W, H  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TOOL = os.path.join(ROOT, "build", "hwref", "host", "rand3d_gx")


def host_tool():
    srcs = [os.path.join(ROOT, "tools", "hwref", "rand3d_gx.c"), os.path.join(ROOT, "sw", "hwref", "rand3d", "gen.c")]
    deps = srcs + [os.path.join(ROOT, "sw", "hwref", "rand3d", "gen.h")]
    if not os.path.exists(TOOL) or any(os.path.getmtime(s) > os.path.getmtime(TOOL) for s in deps):
        os.makedirs(os.path.dirname(TOOL), exist_ok=True)
        subprocess.check_call(["cc", "-O2", "-Wall", "-o", TOOL] + srcs)
    return TOOL


def rle_decode(d):
    out, i = [], 0
    while i < len(d):
        t = d[i]
        if t & 0x8000:
            out.extend([d[i + 1]] * ((t & 0x7FFF) + 1))
            i += 2
        else:
            out.extend(d[i + 1:i + 2 + t])
            i += t + 2
    if len(out) != W * H:
        raise ValueError(f"scene decodes to {len(out)} pixels")
    return out


def unpack(d):
    scenes = {}
    for f in sorted(glob.glob(os.path.join(d, "rand3d_[0-9][0-9][0-9].bin"))):
        b = open(f, "rb").read()
        i = 0
        while i + 12 <= len(b):
            magic, idx, n = struct.unpack_from("<4sII", b, i)
            if magic != b"R3DC":
                raise ValueError(f"{f}: bad record at {i}")
            scenes[idx] = rle_decode(struct.unpack_from(f"<{n // 2}H", b, i + 12))
            i += 12 + n
    return scenes


def read_counts(d):
    p = os.path.join(d, "rand3d_scenes.csv")
    if not os.path.exists(p):
        return {}
    return {int(r["scene"]): (int(r["polys"]), int(r["verts"])) for r in csv.DictReader(open(p))}


FEATURES = [
    ("dispcnt", ["texture", "highlight", "alpha_test", "blend", "aa", "edge", "fog_alpha_only", "fog"]),
    ("flushattr", ["manual_sort", "wbuffer"]),
    ("modes", ["modulate", "decal", "toon", "shadow"]),
    ("formats", ["no_texture", "a3i5", "pal4", "pal16", "pal256", "tex4x4", "a5i3", "direct"]),
    ("texgen", ["texgen_none", "texgen_texcoord", "texgen_normal", "texgen_vertex"]),
    ("prims", ["tris", "quads", "tristrips"]),
    ("vtxcmds", ["vtx16", "vtx10", "vtxxy", "vtxxz", "vtxyz", "vtxdiff"]),
]
ATTRBITS = {11: "transl_depth_update", 12: "far_plane", 13: "one_dot", 14: "depth_equal", 15: "poly_fog"}


def feature_sets(first, count):
    out = subprocess.check_output([host_tool(), "--features", str(first), str(count)], text=True)
    fs = {}
    for r in csv.DictReader(io.StringIO(out)):
        s = set()
        for col, names in FEATURES:
            v = int(r[col])
            s |= {n for b, n in enumerate(names) if v >> b & 1}
        a = int(r["attrbits"])
        s |= {n for b, n in ATTRBITS.items() if a >> b & 1}
        if int(r["translucent"]):
            s.add("translucent")
        if int(r["wireframe"]):
            s.add("wireframe")
        fs[int(r["scene"])] = s
    return fs


def cmd_compare(o):
    names = o.names.split(",")
    a, b = unpack(o.a), unpack(o.b)
    ca, cb = read_counts(o.a), read_counts(o.b)
    common = sorted(set(a) & set(b))
    os.makedirs(os.path.join(o.out, "png"), exist_ok=True)
    rows = []
    for s in common:
        pa, pb = a[s], b[s]
        diff = [i for i in range(W * H) if pa[i] != pb[i]]
        rows.append((s, len(diff), sum(1 for i in diff if (pa[i] ^ pb[i]) == 0x8000)))
    bad = [r for r in rows if r[1]]
    cnt_bad = [s for s in common if s in ca and s in cb and ca[s] != cb[s]]
    rep = [f"# rand3d: {names[0]} = `{o.a}`, {names[1]} = `{o.b}`\n",
           f"- scenes: {names[0]} {len(a)}, {names[1]} {len(b)}, compared {len(common)}",
           f"- identical: {len(common) - len(bad)}; differing: {len(bad)}",
           f"- polygon/vertex count mismatches: {len(cnt_bad)}"
           + (f" (first: {', '.join(map(str, cnt_bad[:10]))})" if cnt_bad else ""), ""]
    if common:
        hist = [(0, 0), (1, 9), (10, 99), (100, 999), (1000, 9999), (10000, W * H)]
        rep += ["| differing pixels | scenes |", "| --- | ---: |"]
        rep += [f"| {lo}-{hi} | {sum(1 for r in rows if lo <= r[1] <= hi)} |" for lo, hi in hist]
        rep.append("")
        fs = feature_sets(common[0], common[-1] - common[0] + 1)
        nbad = len(bad) or 1
        badset = {r[0] for r in bad}
        stats = []
        for name in sorted({n for s in fs.values() for n in s}):
            with_ = [s for s in common if name in fs[s]]
            wb = sum(1 for s in with_ if s in badset)
            wo = [s for s in common if name not in fs[s]]
            wob = sum(1 for s in wo if s in badset)
            stats.append((wb / len(with_) if with_ else 0, wob / len(wo) if wo else 0, name, len(with_), wb, len(wo), wob))
        stats.sort(key=lambda t: t[0] - t[1], reverse=True)
        rep += ["## Features against mismatches", "",
                "Share of scenes that differ, among scenes using the feature and among scenes without it.", "",
                "| feature | with: scenes | with: differ | without: scenes | without: differ |",
                "| --- | ---: | ---: | ---: | ---: |"]
        rep += [f"| {n} | {w} | {wb} ({100 * r1:.0f}%) | {wo} | {wob} ({100 * r0:.0f}%) |"
                for r1, r0, n, w, wb, wo, wob in stats]
        rep.append("")
        rep += ["## Worst scenes", "", "| scene | differing pixels | bit 15 only |", "| --- | ---: | ---: |"]
        for s, n, aonly in sorted(bad, key=lambda r: -r[1])[:o.png]:
            rep.append(f"| {s} | {n} | {aonly} |")
            ra = to_rgb(a[s])
            png(os.path.join(o.out, "png", f"{s:05d}_a.png"), ra)
            png(os.path.join(o.out, "png", f"{s:05d}_b.png"), to_rgb(b[s]))
            dimg = bytearray(x // 3 for x in ra)
            for i in range(W * H):
                if a[s][i] != b[s][i]:
                    dimg[i * 3:i * 3 + 3] = b"\xff\x00\xff"
            png(os.path.join(o.out, "png", f"{s:05d}_diff.png"), dimg)
    with open(os.path.join(o.out, "scenes.csv"), "w") as f:
        f.write("scene,differing,bit15_only\n" + "".join(f"{s},{n},{x}\n" for s, n, x in rows))
    with open(os.path.join(o.out, "report.md"), "w") as f:
        f.write("\n".join(rep) + "\n")
    print(f"{len(common)} scenes, {len(bad)} differ, {len(cnt_bad)} count mismatches; report {o.out}/report.md")
    return 1 if bad or cnt_bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare")
    c.add_argument("a")
    c.add_argument("b")
    c.add_argument("--out", default="build/hwref/rand3d-compare")
    c.add_argument("--names", default="ds,melonds")
    c.add_argument("--png", type=int, default=12, help="worst scenes to draw")
    g = sub.add_parser("gxbin")
    g.add_argument("out")
    g.add_argument("first", type=int)
    g.add_argument("count", type=int)
    g.add_argument("--counts")
    u = sub.add_parser("unpack")
    u.add_argument("dir")
    u.add_argument("out")
    o = ap.parse_args()
    if o.cmd == "compare":
        return cmd_compare(o)
    if o.cmd == "gxbin":
        return subprocess.call([host_tool(), o.out, str(o.first), str(o.count)] + ([o.counts] if o.counts else []))
    os.makedirs(o.out, exist_ok=True)
    for s, px in unpack(o.dir).items():
        with open(os.path.join(o.out, f"rand3d_{s:05d}_3d.bin"), "wb") as f:
            f.write(struct.pack(f"<{W * H}H", *px))
    return 0


if __name__ == "__main__":
    sys.exit(main())
