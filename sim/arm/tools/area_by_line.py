#!/usr/bin/env python3
"""Rough per-section area of one module: Yosys (synth_intel_alm) with the
cells grouped into submodules by source-line range before LUT mapping, so
ABC maps (and stat counts) each section on its own. Cross-section logic
cannot merge, so the sum is a little above a flat run. For finding where
the area is, not for absolute numbers (those come from Quartus fits).

  area_by_line.py --top arm_core --file arm_core.sv \
      --sec F:273 PD:311 D:393 E1:1026 ... [--rtl files...]
Each section runs from its line to the next one's; lines after the last
go to the last. Cells from other files or without a source go to "other".
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", required=True)
    ap.add_argument("--file", required=True, help="basename whose lines are split")
    ap.add_argument("--sec", nargs="+", required=True, help="NAME:LINE ...")
    ap.add_argument("--rtl", nargs="+", required=True)
    ap.add_argument("--define", nargs="*", default=[])
    ap.add_argument("--yosys", default="yosys")
    a = ap.parse_args()
    secs = sorted(((int(s.split(":")[1]), s.split(":")[0]) for s in a.sec))
    tmp = tempfile.mkdtemp()
    pre = os.path.join(tmp, "pre.json")
    defs = " ".join(f"-D {d}" for d in a.define)
    subprocess.run([a.yosys, "-m", "slang", "-q", "-p",
                    f"read_slang {defs} {' '.join(a.rtl)} --top {a.top} --unroll-limit=100000; "
                    f"synth_intel_alm -family cyclonev -top {a.top} -run :map_bram; "
                    f"select ={a.top}; write_json -selected {pre}"], check=True, stdout=subprocess.DEVNULL)
    d = json.load(open(pre))
    mod = d["modules"][a.top]

    def section(src):
        for part in src.split("|"):
            m = re.match(r"(.*?):(\d+)", part)
            if m and os.path.basename(m.group(1)) == a.file:
                ln = int(m.group(2))
                name = "other"
                for start, n in secs:
                    if ln >= start:
                        name = n
                return name
        return "other"

    groups = {}
    for cname, cell in mod["cells"].items():
        groups.setdefault(section(cell.get("attributes", {}).get("src", "")), []).append(cname)
    script = os.path.join(tmp, "split.ys")
    with open(script, "w") as f:
        # the same deterministic run again, so the cell names match
        f.write(f"read_slang {defs} {' '.join(a.rtl)} --top {a.top} --unroll-limit=100000\n")
        f.write(f"synth_intel_alm -family cyclonev -top {a.top} -run :map_bram\n")
        for g, cells in groups.items():
            if g == "other":
                continue
            for i in range(0, len(cells), 200):
                sel = " ".join("c:" + c.replace("\\", "\\\\").replace(" ", "\\ ") for c in cells[i:i + 200])
                f.write(f"setattr -set submod \"{g}\" {sel}\n")
        f.write("submod\n")
        f.write(f"synth_intel_alm -family cyclonev -top {a.top} -run map_bram:\n")
        f.write("stat\n")
    log = os.path.join(tmp, "split.log")
    subprocess.run([a.yosys, "-m", "slang", "-q", "-l", log, "-s", script], check=True,
                   stdout=subprocess.DEVNULL)
    cur = None
    res = {}
    for line in open(log):
        if "design hierarchy" in line:
            cur = None
            continue
        m = re.match(r"=== (\S+) ===", line.strip())
        if m:
            cur = m.group(1)
            res[cur] = [0, 0, 0]
            continue
        m = re.match(r"\s*(\d+)\s+(MISTRAL_\w+)", line)
        if m and cur:
            n, t = int(m.group(1)), m.group(2)
            if t.startswith("MISTRAL_ALUT_ARITH"):
                res[cur][1] += n
            elif t.startswith("MISTRAL_ALUT"):
                res[cur][0] += n
            elif t == "MISTRAL_FF":
                res[cur][2] += n
    print(f"{'section':12s} {'LUTs':>6s} {'arith':>6s} {'FFs':>6s}")
    for k, (l, ar, ff) in sorted(res.items(), key=lambda kv: -kv[1][0]):
        if k == "design hierarchy":
            continue
        print(f"{k:12s} {l:6d} {ar:6d} {ff:6d}")


if __name__ == "__main__":
    main()
