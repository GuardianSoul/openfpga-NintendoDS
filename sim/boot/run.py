#!/usr/bin/env python3
"""make test-boot: sw/boot/key1.s against key1_ref.c, and key1_ref.c against melonDS.

For each ROM:
  1. key1_ref writes the encrypted secure area (enc.bin, re-encrypted the way
     melonDS does on cart insert if the dump is decrypted), the file's bytes
     unchanged (raw.bin) and the expected direct-boot results of both.
  2. The melonDS oracle (gen_oracle.py) checks those four files.
  3. The ARM7 context of sim/arm/tb_arm.sv runs key1_test.s + key1.s on both
     vectors and compares the bytes and return value in the core itself.
A baseline run with the call skipped gives the cycles of the routine alone.
One planted fault (a flipped expected byte) must make the RTL check fail.
"""
import argparse
import os
import re
import subprocess
import sys

MKHEX = os.path.join(os.path.dirname(__file__), "..", "arm", "tools", "mkhex.py")
AREA, PARAMS = 0x02000000, 0x02001000


def sim(a, d, vec, exp, gamecode, ret, skip=0):
    params = os.path.join(d, f"{vec}.params")
    with open(params, "wb") as f:
        for w in (gamecode, ret, skip):
            f.write(w.to_bytes(4, "little"))
    hexf = os.path.join(d, f"{vec}.hex")
    subprocess.run([sys.executable, MKHEX, hexf, f"{a.bios7}@0", f"{a.prog}@0x8000",
                    f"{os.path.join(d, vec + '.bin')}@{AREA:#x}", f"{exp}@{AREA + 0x800:#x}",
                    f"{params}@{PARAMS:#x}"], check=True)
    p = subprocess.run([a.sim, f"+img1={hexf}", "+pc1=8000", "+run=2", "+maxcycles=5000000"],
                       capture_output=True, text=True)
    open(os.path.join(d, f"{vec}.log"), "w").write(p.stdout + p.stderr)
    cyc = re.search(r"cycles=(\d+)", p.stdout)
    res = re.search(r"result=([0-9a-f]+)", p.stdout)
    ret_n = re.search(r"retired=(\d+)", p.stdout)
    return (int(res.group(1), 16) if res else None,
            int(cyc.group(1)) if cyc else None,
            int(ret_n.group(1)) if ret_n else None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--prog", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--oracle")
    ap.add_argument("--bios7", required=True)
    ap.add_argument("roms", nargs="+")
    a = ap.parse_args()
    bad = 0
    base = None
    for rom in a.roms:
        name = os.path.splitext(os.path.basename(rom))[0]
        d = os.path.join(a.build, name)
        os.makedirs(d, exist_ok=True)
        r = subprocess.run([a.ref, rom, a.bios7, d], capture_output=True, text=True)
        if r.returncode:
            print(f"FAIL  {name}: key1_ref: {r.stderr.strip()}")
            bad += 1
            continue
        print(f"      {name}: {r.stdout.strip()}")
        if a.oracle:
            o = subprocess.run([a.oracle, rom, a.bios7, d], capture_output=True, text=True)
            print(f"{'PASS' if o.returncode == 0 else 'FAIL'}  {name}: {o.stdout.strip()}")
            bad += o.returncode != 0
        gc, enc_ret, raw_ret = (int(x, 16) for x in open(os.path.join(d, "params.txt")).read().split())
        if base is None:
            res, base, base_n = sim(a, d, "enc", os.path.join(d, "enc.exp"), gc, enc_ret, skip=1)
            if base is None:
                print(f"FAIL  baseline run did not finish (see {d}/enc.log)")
                return 1
        for vec, ret in (("enc", enc_ret), ("raw", raw_ret)):
            res, cyc, n = sim(a, d, vec, os.path.join(d, f"{vec}.exp"), gc, ret)
            ok = res == 0
            bad += not ok
            what = "encryObj" if ret == 0 else "no encryObj, filled"
            print(f"{'PASS' if ok else 'FAIL'}  {name} {vec}: RTL ARM7 {what}, result={res if res is None else hex(res)}, "
                  f"{cyc - base if cyc else '?'} cycles, {n - base_n if n else '?'} instructions in the call")
    # planted fault: one flipped expected byte must be caught
    d = os.path.join(a.build, os.path.splitext(os.path.basename(a.roms[0]))[0])
    gc, enc_ret, _ = (int(x, 16) for x in open(os.path.join(d, "params.txt")).read().split())
    exp = bytearray(open(os.path.join(d, "enc.exp"), "rb").read())
    exp[0x123] ^= 0x10
    fault = os.path.join(d, "fault.exp")
    open(fault, "wb").write(exp)
    res, _, _ = sim(a, d, "enc", fault, gc, enc_ret)
    caught = res == 1
    print(f"{'PASS' if caught else 'FAIL'}  planted fault (one flipped expected byte): result={res}")
    bad += not caught
    print("TEST PASSED" if bad == 0 else f"TEST FAILED ({bad})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
