#!/usr/bin/env python3
"""Equivalence check of rtl/arm against an earlier revision (make arm-equiv).

The reference revision's RTL and testbench are built with Verilator, every
test in run_tests.py is run with retire traces (+trace0/+trace1), and the
current build then replays each test in lockstep against those traces
(+ref0/+ref1). Any difference in retired PC, CPSR or r0-r14 fails.

usage: equiv.py VERILATOR CURRENT_SIM BUILD ASSETS REF
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
import run_tests  # noqa: E402

VFLAGS = ["--binary", "-j", "0", "-O3", "--x-assign", "fast", "--x-initial", "fast",
          "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-Wno-UNUSEDSIGNAL",
          "--top-module", "tb_arm"]
RTL = ["arm_pkg.sv", "arm_regfile.sv", "arm_mul.sv", "arm_thumb.sv", "arm_core.sv",
       "arm9_ram.sv", "arm9_mem.sv", "arm_cpu.sv"]


def main():
    verilator, cur, build, assets, ref = sys.argv[1:6]
    d = os.path.join(build, "equiv")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    rev = subprocess.run(["git", "rev-parse", "--short", ref], capture_output=True,
                         text=True, check=True).stdout.strip()
    rtl = []
    for f in RTL:
        r = subprocess.run(["git", "show", f"{rev}:rtl/arm/{f}"], capture_output=True, text=True)
        if r.returncode == 0:                # files the revision does not have are skipped
            open(os.path.join(d, f), "w").write(r.stdout)
            rtl.append(f)
    tb = subprocess.run(["git", "show", f"{rev}:sim/arm/tb_arm.sv"], capture_output=True,
                        text=True, check=True).stdout
    open(os.path.join(d, "tb_arm.sv"), "w").write(tb)
    r = subprocess.run([verilator, *VFLAGS, "-Mdir", os.path.join(d, "obj"),
                        *[os.path.join(d, f) for f in rtl], os.path.join(d, "tb_arm.sv")],
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-2000:], r.stderr[-2000:])
        sys.exit(f"reference {rev} did not build")
    refsim = os.path.join(d, "obj", "Vtb_arm")
    failed = 0
    for name, args, _ in run_tests.tests(build, assets):
        if "+rwait=30" in args:
            continue
        t0, t1 = os.path.join(d, f"{name}.0.csv"), os.path.join(d, f"{name}.1.csv")
        a = subprocess.run([refsim, *args, f"+trace0={t0}", f"+trace1={t1}"],
                           capture_output=True, text=True)
        if "TEST PASSED" not in a.stdout:
            print(f"new   {name:14s} (does not pass at {rev}: not compared)")
            continue
        b = subprocess.run([cur, *args, f"+ref0={t0}", f"+ref1={t1}"],
                           capture_output=True, text=True)
        n = sum(1 for _ in open(t0)) + sum(1 for _ in open(t1))
        # and again with 30% random memory waits (replays), without the
        # test's cycle limit. Not for exc_dual: where its IRQs land depends on
        # the timing, so its trace legitimately differs with waits (since
        # f3b525c holds IRQs back while a replay is pending).
        wargs = [x for x in args if not x.startswith("+maxcycles=")]
        if name.startswith("exc"):
            c = None
        else:
            c = subprocess.run([cur, *wargs, f"+ref0={t0}", f"+ref1={t1}", "+rwait=30"],
                               capture_output=True, text=True)
        if c is None or ("TEST PASSED" in c.stdout and "MISMATCH" not in c.stdout):
            pass
        else:
            print(f"DIFF  {name:14s} vs {rev} with +rwait=30")
            failed += 1
            continue
        if "TEST PASSED" in b.stdout and "MISMATCH" not in b.stdout:
            print(f"same  {name:14s} {n} retired instructions match {rev} (also with waits)")
        else:
            print(f"DIFF  {name:14s} vs {rev}")
            for line in b.stdout.splitlines():
                if "MISMATCH" in line or line.startswith("  r") or "FAIL" in line:
                    print("      " + line)
            failed += 1
    if failed:
        sys.exit(1)
    print(f"equivalent to {rev} on all tests")


if __name__ == "__main__":
    main()
