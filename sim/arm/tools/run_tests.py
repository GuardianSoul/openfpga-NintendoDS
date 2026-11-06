#!/usr/bin/env python3
"""Run the ARM pipeline test set (make test / make test-icarus)."""
import argparse
import os
import shlex
import subprocess
import sys
import time


def tests(b, assets):
    hooks = open(os.path.join(b, "armwrestler.hooks")).read().split()
    return [
        # name, plusargs, what it covers
        ("exc_dual", [f"+img0={b}/exc.hex", f"+img1={b}/exc.hex", "+pc0=0", "+pc1=0",
                      "+run=3"], "exceptions/IRQ, both contexts at once"),
        ("hazard_dual", [f"+img0={b}/hazard0.hex", f"+img1={b}/hazard1.hex", "+pc0=02000000",
                         "+pc1=02000000", "+run=3"], "back-to-back dependencies, both contexts"),
        ("rockwrestler", [f"+img0={b}/rockwrestler.hex", "+pc0=02000000", "+run=1"],
         "ARM9 context: rockwrestler ARMv4 + ARMv5 CPU tests"),
        ("jsmolka_arm", [f"+img1={b}/jsmolka_arm.hex", "+pc1=0", "+run=2",
                         "+mode1=jsmolka"], "ARM7 context: jsmolka gba-tests arm"),
        ("jsmolka_thumb", [f"+img1={b}/jsmolka_thumb.hex", "+pc1=0", "+run=2",
                           "+mode1=jsmolka"], "ARM7 context: jsmolka gba-tests thumb"),
        ("armwrestler", [f"+img1={b}/armwrestler.hex", "+pc1=0", "+run=2",
                         "+mode1=armwrestler", *hooks], "ARM7 context: armwrestler ARM + Thumb"),
        ("dual", [f"+img0={b}/rockwrestler.hex", "+pc0=02000000",
                  f"+img1={b}/jsmolka_arm.hex", "+pc1=0", "+run=3", "+mode1=jsmolka"],
         "rockwrestler on ARM9 and jsmolka arm on ARM7, interleaved"),
        # branch prediction and Thumb BL in PD; the cycle limits sit between
        # the cycles with them (13,079 / 15,717) and without either
        # (13,879+ / 16,613+), so they also check that both work
        ("bpred7", [f"+img1={b}/bpred7.hex", "+pc1=02000000", "+run=2", "+maxcycles=13500"],
         "ARM7: branch predictor, Thumb BL pairs in PD (with a cycle limit)"),
        ("bpred9", [f"+img0={b}/bpred9.hex", "+pc0=02000000", "+run=1", "+maxcycles=16150"],
         "ARM9 cached: the same plus BLX both ways (with a cycle limit)"),
        ("halt7", [f"+img1={b}/halt.hex", "+pc1=02000000", "+run=2"],
         "ARM7 HALTCNT: no issue while halted, wake on IE & IF with IRQs masked"),
        # ARM9 memory system: caches, MPU, TCMs, CP15 (cp15.inc map)
        ("cache9", [f"+img0={b}/cache.hex", "+pc0=02000000", "+run=1"],
         "ARM9: write-back/through, clean, invalidate, eviction, SMC, MPU aborts, TCMs, WFI"),
        ("swflush9", [f"+img0={b}/swflush.hex", "+pc0=02000000", "+run=1"],
         "ARM9: DC_FlushAll reaches every dirty line of a cache with extra sets"),
        ("ldruse2_9", [f"+img0={b}/ldruse2.hex", "+pc0=02000000", "+run=1"],
         "ARM9: a use two instructions after an uncached load sees the loaded value"),
        ("evict9", [f"+img0={b}/evict.hex", "+pc0=02000000", "+run=1"],
         "ARM9: 10 KB of distinct words through the write-back cache, every dirty eviction checked via the alias"),
        ("evict9_slowbus", [f"+img0={b}/evict.hex", "+pc0=02000000", "+run=1", "+blat=9"],
         "evict9 with a 10-cycle bus"),
        ("cache9_slowbus", [f"+img0={b}/cache.hex", "+pc0=02000000", "+run=1", "+blat=9"],
         "cache9 with a 10-cycle bus"),
        ("lzcopy9", [f"+img0={b}/lzcopy.hex", "+pc0=02000000", "+run=1"],
         "ARM9: LZ-style backward byte copies in write-back memory vs an uncached reference"),
        ("lzcopy9_slowbus", [f"+img0={b}/lzcopy.hex", "+pc0=02000000", "+run=1", "+blat=9"],
         "lzcopy9 with a 10-cycle bus"),
        ("rockwrestler_c", [f"+img0={b}/rockwrestler_c.hex", "+pc0=02000000", "+run=1"],
         "rockwrestler on the ARM9 with caches, MPU and TCMs on"),
        ("hazard9_c", [f"+img0={b}/hazard_c.hex", "+pc0=02000000", "+run=1"],
         "hazard on the ARM9 with caches on"),
        ("jsmolka_thumb9_c", [f"+img0={b}/jsmolka_thumb9c.hex", "+pc0=0", "+run=1",
                              "+mode0=jsmolka"], "jsmolka thumb on the ARM9 with caches on"),
        ("stress_dual_c", [f"+img0={b}/stress_c.hex", "+pc0=02000000",
                           f"+img1={b}/stress1.hex", "+pc1=02000000", "+run=3"],
         "LDM/STM loops on both contexts at once (ARM9 cached)"),
        ("dual_c", [f"+img0={b}/rockwrestler_c.hex", "+pc0=02000000",
                    f"+img1={b}/jsmolka_arm.hex", "+pc1=0", "+run=3", "+mode1=jsmolka",
                    "+rwait=30"], "cached rockwrestler on ARM9, jsmolka arm on ARM7 with waits"),
        # the same with 30% of fetch and data accesses answered "not ready"
        ("exc_dual_wait", [f"+img0={b}/exc.hex", f"+img1={b}/exc.hex", "+pc0=0", "+pc1=0",
                           "+run=3", "+rwait=30"], "exc_dual, 30% random memory waits (replay)"),
        ("hazard_dual_wait", [f"+img0={b}/hazard0.hex", f"+img1={b}/hazard1.hex", "+pc0=02000000",
                              "+pc1=02000000", "+run=3", "+rwait=30"], "hazard_dual, 30% random waits"),
        ("dual_wait", [f"+img0={b}/rockwrestler.hex", "+pc0=02000000",
                       f"+img1={b}/jsmolka_arm.hex", "+pc1=0", "+run=3", "+mode1=jsmolka",
                       "+rwait=30"], "dual, 30% random waits"),
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--assets", required=True)
    ap.add_argument("--only")
    ap.add_argument("--extra", default="")
    a = ap.parse_args()
    only = set(a.only.split(",")) if a.only else None
    failed = []
    for name, args, desc in tests(a.build, a.assets):
        if only and name not in only:
            continue
        cmd = shlex.split(a.sim) + args + shlex.split(a.extra)
        t0 = time.time()
        p = subprocess.run(cmd, capture_output=True, text=True)
        log = os.path.join(a.build, f"{name}.log")
        open(log, "w").write(p.stdout + p.stderr)
        ok = "TEST PASSED" in p.stdout
        cycles = next((l.split("=")[1] for l in p.stdout.splitlines() if l.startswith("cycles=")), "?")
        print(f"{'PASS' if ok else 'FAIL'}  {name:14s} {desc}  (cycles={cycles}, {time.time()-t0:.1f}s)")
        if not ok:
            failed.append(name)
            for line in p.stdout.splitlines()[-15:]:
                print("      " + line)
    if failed:
        print(f"{len(failed)} failed: {' '.join(failed)}")
        sys.exit(1)
    print("all ARM tests passed")


if __name__ == "__main__":
    main()
