#!/usr/bin/env python3
"""Mutations of the polygon sort in microcode (gpu3d_gxeng USORT, ucode.py
SORT; docs/geometry-engine.md "Sort in microcode"): each must make the
geometry test bench differ from melonDS.
  sim/gpu3d/usort_mutate.py [names...]     (default: all)
Builds build/geom/mut/<name>/ (control store or gxeng mutated), runs
synthetic seeds 1..SEEDS and the HG/KH census traces, JOBS at a time."""
import os, re, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
UC = "tools/gxasm/ucode.py"
ASM = "tools/gxasm/asm.py"
ENG = "rtl/gpu3d/gpu3d_gxeng.sv"
MUTS = {   # name: (file, old, new)
    "sow_pos":   (UC, 'I(op("SUB", "SCT", 1), sm("SOW"))', 'I(op("PASSX", "SCT"), sm("SOW"))'),
    "no_retag":  (UC, 'I(op("SUB", "R", 1), w(SK), sm("WBL"))\n', 'I(op("SUB", "R", 1), w(SK))\n'),
    "man_all":   (UC, 'I(jnc("N", "SMAN"))', 'I()'),
    "no_prefix": (UC, 'I(rb(SUM), op("ADD", "SCT", "QB"), w(SUM), sm("WCT"))', 'I(rb(SUM), op("PASSX", "SCT"), w(SUM), sm("WCT"))'),
    "ret_state": (ASM, "            ret_sites = rs", "            ret_sites = {}"),
    "bl_tag":    (ENG, "wire         bl_ok = bl_q[11] == stag;", "wire         bl_ok = 1'b1;"),
    "ct_tag":    (ENG, "assign s_ct = ct_q[12] == stag ?", "assign s_ct = 1'b1 ?"),
    "nx_end":    (ENG, "assign s_nx = &nx_q ?", "assign s_nx = 1'b0 ?"),
    "no_flip":   (ENG, "else if (s_sd) stag <= !stag;", "else if (1'b0) stag <= !stag;"),
}
SEEDS = int(os.environ.get("SEEDS", 6))
JOBS = int(os.environ.get("JOBS", 3))
TRACES = [f"{root}/build/census/heartgold/gx.bin", f"{root}/build/census/kh358/gx.bin"]


def build(name):
    f, old, new = MUTS[name]
    d = f"{root}/build/geom/mut/{name}"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(f"{d}/rtl/gpu3d", exist_ok=True)
    os.makedirs(f"{d}/build/geom", exist_ok=True)
    src = open(f"{root}/{f}").read()
    assert src.count(old) == 1, f"{name}: pattern found {src.count(old)} times"
    rom = f"{root}/rtl/gpu3d/gpu3d_gxrom_us.sv"
    eng = f"{root}/{ENG}"
    if f.startswith("tools/gxasm/"):
        shutil.copytree(f"{root}/tools/gxasm", f"{d}/tools/gxasm")
        open(f"{d}/{f}", "w").write(src.replace(old, new))
        subprocess.run([sys.executable, f"{d}/{UC}"], env=dict(os.environ, GX_USORT="1"), check=True,
                       stdout=subprocess.DEVNULL)
        rom = f"{d}/rtl/gpu3d/gpu3d_gxrom_us.sv"
    else:
        eng = f"{d}/gpu3d_gxeng.sv"
        open(eng, "w").write(src.replace(old, new))
    rtl = (f"rtl/gpu3d/gpu3d_gxu_pkg.sv rtl/gpu3d/gpu3d_ram.sv rtl/gpu3d/gpu3d_gxrom.sv {rom} rtl/gpu3d/gpu3d_gxdiv.sv "
           f"rtl/gpu3d/gpu3d_gxfront.sv {eng} rtl/gpu3d/gpu3d_gxsort.sv rtl/gpu3d/gpu3d_geom.sv")
    r = subprocess.run(["make", "-C", root, f"build/geom/mut/{name}/obj/Vgpu3d_geom", "GEOM_USORT=1",
                        f"GEOM_OBJ=mut/{name}/obj", f"GEOM_RTL={rtl}"], capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-2000:], r.stderr[-2000:])
        raise SystemExit(f"{name}: build failed")
    return f"{d}/obj/Vgpu3d_geom"


def run(tb, args):
    try:
        r = subprocess.run([tb] + args, capture_output=True, text=True, timeout=1800, cwd=root)
        return r.returncode, (r.stdout + r.stderr).strip().splitlines()[-1:] or [""]
    except subprocess.TimeoutExpired:
        return -1, ["timeout"]


names = sys.argv[1:] or list(MUTS)
survived = []
for n in names:
    tb = build(n)
    jobs = [["--synth", "30", "--seed", str(s)] for s in range(1, SEEDS + 1)] + [["--trace", t] for t in TRACES]
    with ThreadPoolExecutor(JOBS) as ex:
        res = list(ex.map(lambda a: run(tb, a), jobs))
    bad = [(" ".join(a), r) for a, r in zip(jobs, res) if r[0] != 0]
    print(f"{n}: {'caught' if bad else 'SURVIVED'} by {len(bad)} of {len(jobs)} runs" +
          (f" (first: {bad[0][0]}: {bad[0][1][1][0][:100]})" if bad else ""), flush=True)
    if not bad:
        survived.append(n)
sys.exit(1 if survived else 0)
