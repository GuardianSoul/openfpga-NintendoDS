#!/usr/bin/env python3
"""Deliberate bugs in nds_g3d_cache's use of nds_lcache (M3) that
sim/ds/g3dcache_eq.sh (against the cache before M3) must catch.
  g3dcache_eq_mutate.py VERILATOR BUILD_DIR REF"""
import os
import shutil
import subprocess
import sys

MUTATIONS = [
    ("a fill a flush met kept valid", ".f_ok(!stale)", ".f_ok(1'b1)"),
    ("flushes not passed on", ".inv_all(flush)", ".inv_all(1'b0)"),
    ("the lookup's valid read before the fill's last write",
     ".l_v(), .l_vn(vld_q)", ".l_v(vld_q), .l_vn()"),
]


def main():
    verilator, build, ref = sys.argv[1], sys.argv[2], sys.argv[3]
    survived = 0
    for i, (name, old, new) in enumerate(MUTATIONS):
        d = os.path.join(build, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        for f in ("nds_gpu3d.sv", "nds_lcache.sv"):
            shutil.copy(os.path.join("rtl/ds", f), d)
        p = os.path.join(d, "nds_gpu3d.sv")
        src = open(p).read()
        if src.count(old) != 1:
            print(f"ERROR     {name}: pattern found {src.count(old)} times")
            survived += 1
            continue
        open(p, "w").write(src.replace(old, new))
        r = subprocess.run(["sim/ds/g3dcache_eq.sh", verilator, os.path.join(d, "eq"), ref, d],
                           capture_output=True, text=True, env=dict(os.environ, EQ_CYCLES="200000"))
        print(f"{'caught   ' if r.returncode else 'SURVIVED '} {name}")
        survived += r.returncode == 0
    shutil.rmtree(build, ignore_errors=True)
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
