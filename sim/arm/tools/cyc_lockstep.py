#!/usr/bin/env python3
"""Cycle-exact lockstep of two rtl/arm versions on the ARM test set.

cyc_lockstep.py build NAME REV|work CFG [extra verilator args...]   (REV: git rev; 'work': working tree)
cyc_lockstep.py run NAME                                            (every test; traces + per-retire cycle)
cyc_lockstep.py diff A B                                            (stdout, retire traces and retire cycles)
CFG: def (tb defaults) | rel (release ARM9: SLOW A9_SOLO A9_OPT A7_DS EVB XD2 XI1)
"""
import os, subprocess, sys, filecmp, shutil
from concurrent.futures import ThreadPoolExecutor
W = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, W + "/sim/arm/tools")
import run_tests
B = W + "/build/arm"
OUT = W + "/build/cyc_lockstep"
RTL = "arm_pkg arm_regfile arm_mul arm_thumb arm_core arm7_ds arm9_ram arm9_mem arm_cpu".split()
CFG = {"def": [], "rel": ["-GSLOW=1", "-GA9_SOLO=1", "-GA9_OPT=67101667", "-GA7_DS=1", "-GEVB=1",
                          "-GA9_XD=2", "-GA9_XI=1"]}
V = W + "/tools/verilator-locked"


def build(name, rev, cfg, extra):
    d = os.path.join(OUT, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d + "/src")
    files = []
    for f in RTL + ["tb_arm"]:
        p = f"sim/arm/{f}.sv" if f == "tb_arm" else f"rtl/arm/{f}.sv"
        dst = f"{d}/src/{f}.sv"
        if f in os.environ.get("OVR", "").split(","):
            shutil.copy(os.environ["OVR_DIR"] + f"/{f}.sv", dst)
        elif rev == "work":
            shutil.copy(f"{W}/{p}", dst)
        else:
            open(dst, "wb").write(subprocess.check_output(["git", "-C", W, "show", f"{rev}:{p}"]))
        files.append(dst)
    r = subprocess.run([V, "--binary", "-j", "6", "-O3", "--x-assign", "fast", "--x-initial", "fast",
                        "--assert", "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-Wno-UNUSEDSIGNAL",
                        "--top-module", "tb_arm", "-Mdir", d + "/obj", *CFG[cfg], *extra, *files],
                       capture_output=True, text=True, env=dict(os.environ, OBJCACHE=""))
    open(d + "/build.log", "w").write(r.stdout + r.stderr)
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-3000:]); sys.exit(1)
    print("built", name)


def run(name):
    d = os.path.join(OUT, name)
    sim = d + "/obj/Vtb_arm"
    os.makedirs(d + "/t", exist_ok=True)

    def one(t):
        n, args, _ = t
        tr = [f"+trace0={d}/t/{n}.tr0", f"+trace1={d}/t/{n}.tr1", f"+ops0={d}/t/{n}.op0", f"+ops1={d}/t/{n}.op1"]
        # the traces go through FIFOs into SHA-256 + line counts (they reach GBs): {n}.trX holds "sha lines"
        import hashlib, threading
        fifos = [x.split("=", 1)[1] for x in tr]
        res = {}
        def eat(f):
            h, k = hashlib.sha256(), 0
            with open(f, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk); k += chunk.count(b"\n")
            res[f] = f"{h.hexdigest()} {k}\n"
        ths = []
        for f in fifos:
            if os.path.exists(f): os.remove(f)
            os.mkfifo(f)
            ths.append(threading.Thread(target=eat, args=(f + "",))); ths[-1].start()
        r = subprocess.run([sim, *args, *tr], capture_output=True, text=True, timeout=3600)
        for f in fifos:                      # (a FIFO the sim never opened: unblock its reader)
            try:
                fd = os.open(f, os.O_WRONLY | os.O_NONBLOCK); os.close(fd)
            except OSError: pass
        for t_ in ths: t_.join()
        for f in fifos:
            os.remove(f); open(f, "w").write(res.get(f, "none\n"))
        open(f"{d}/t/{n}.out", "w").write(r.stdout + r.stderr)
        return n, ("PASS" if "TEST PASSED" in r.stdout else "FAIL"), \
            [l for l in r.stdout.splitlines() if l.startswith("cycles=")]
    with ThreadPoolExecutor(2) as ex:
        for n, s, c in ex.map(one, run_tests.tests(B, W + "/local-assets/arm-tests")):
            print(f"{s} {n:18s} {' '.join(c)}", flush=True)


def diff(a, b):
    da, db = os.path.join(OUT, a, "t"), os.path.join(OUT, b, "t")
    bad = 0
    names = sorted(os.listdir(da))
    for f in names:
        fb = os.path.join(db, f)
        rd = lambda p: [l for l in open(p) if not l.startswith("- ")] if p.endswith(".out") else open(p).read()
        if not os.path.exists(fb) or rd(os.path.join(da, f)) != rd(fb):
            print("DIFF", f); bad += 1
    lines = sum(int(open(os.path.join(da, f)).read().split()[1]) for f in names if f[-3:-1] == "op")
    print(f"{len(names)} files, {lines} retired instructions with cycle stamps, {bad} differ")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    c = sys.argv[1]
    if c == "build": build(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
    elif c == "run": run(sys.argv[2])
    elif c == "diff": diff(sys.argv[2], sys.argv[3])
