#!/usr/bin/env python3
"""Deliberate bugs in nds_arm7_port's use of nds_lcache (M3) that
sim/ds/arm7port_eq.sh (against the port before M3) must catch.
  arm7port_eq_mutate.py VERILATOR BUILD_DIR REF"""
import os
import shutil
import subprocess
import sys

MUTATIONS = [
    ("the fetch line being filled not masked", ".f_busy(fl_v && fl_i)", ".f_busy(1'b0)"),
    ("the data line being filled not masked", ".f_busy(fl_v && !fl_i)", ".f_busy(1'b0)"),
    ("a fill a store updated during it kept valid",
     "wire fl_good = !fl_bad && !(!fl_i && su_hit) && !fl_kill;", "wire fl_good = !fl_bad && !fl_kill;"),
    ("a fill a write met on its last edge kept valid",
     "wire fl_good = !fl_bad && !(!fl_i && su_hit) && !fl_kill;", "wire fl_good = !fl_bad && !(!fl_i && su_hit);"),
    ("the fetch check read a cycle late", ".c_idx(cki_ra[IL+3:4])", ".c_idx(cki_a[IL+3:4])"),
    ("the data check clears without its tag compare",
     "wire  dc_inv = ckd_v && dc_cv && dtq2 == ckd_a[17:DL+4];", "wire  dc_inv = ckd_v && dc_cv;"),
]


def main():
    verilator, build, ref = sys.argv[1], sys.argv[2], sys.argv[3]
    survived = 0
    for i, (name, old, new) in enumerate(MUTATIONS):
        d = os.path.join(build, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        for f in ("nds_arm7_port.sv", "nds_lcache.sv"):
            shutil.copy(os.path.join("rtl/ds", f), d)
        p = os.path.join(d, "nds_arm7_port.sv")
        src = open(p).read()
        if src.count(old) != 1:
            print(f"ERROR     {name}: pattern found {src.count(old)} times")
            survived += 1
            continue
        open(p, "w").write(src.replace(old, new))
        r = subprocess.run(["sim/ds/arm7port_eq.sh", verilator, os.path.join(d, "eq"), ref, d],
                           capture_output=True, text=True, env=dict(os.environ, EQ_CYCLES="300000"))
        print(f"{'caught   ' if r.returncode else 'SURVIVED '} {name}")
        survived += r.returncode == 0
    shutil.rmtree(build, ignore_errors=True)
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
