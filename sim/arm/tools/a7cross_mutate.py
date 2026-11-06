#!/usr/bin/env python3
"""Deliberate bugs in rtl/arm/cdc_a7.sv that sim/arm/tools/a7cross_test.sh
must catch.
  a7cross_mutate.py VERILATOR BUILD_DIR"""
import os
import shutil
import subprocess
import sys

MUTATIONS = [
    ("the store gate on for nds_arm7_port_min too (a deadlock)",
     "(STORE_GATE == 0 || !c_x7_stores)", "(!c_x7_stores)"),
    ("no store gate for nds_arm7_port (a fabric store overtakes SRAM stores)",
     "(STORE_GATE == 0 || !c_x7_stores)", "(1'b1)"),
    ("x7_stores raised while a fabric access is on its way (a deadlock)",
     "st_c <= c_x7_stores && !f_go;", "st_c <= c_x7_stores;"),
]


def main():
    verilator, build = sys.argv[1], sys.argv[2]
    survived = 0
    for i, (name, old, new) in enumerate(MUTATIONS):
        d = os.path.join(build, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        src = open("rtl/arm/cdc_a7.sv").read()
        if src.count(old) != 1:
            print(f"ERROR     {name}: pattern found {src.count(old)} times")
            survived += 1
            continue
        open(os.path.join(d, "cdc_a7.sv"), "w").write(src.replace(old, new))
        r = subprocess.run(["sim/arm/tools/a7cross_test.sh", verilator, os.path.join(d, "obj"), d],
                           capture_output=True, text=True)
        print(f"{'caught   ' if r.returncode else 'SURVIVED '} {name}")
        survived += r.returncode == 0
    shutil.rmtree(build, ignore_errors=True)
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
