#!/usr/bin/env python3
"""Run only RF36 selection/build/native-import overlay after a granted lease."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from prepare import ROOT, OUT, prepare

TOOLS = Path("build/tools/oss-cad-suite/bin")
VENDOR = Path("build/tools/quartus-lite/25.1/quartus/eda/sim_lib")
STATUS = Path("/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json")


def status(phase, child=None, active=True):
    d = json.loads(STATUS.read_text())
    d.update(phase=phase, worker={"active": active, "host": "Desktop", "PID": os.getpid() if active else None,
        "child_PID": child, "lease": "Granted released slot; absoluteNI10/j1/t1 serial" if active else "Released; worker reaped"})
    s = json.dumps(d, separators=(",", ":"))
    assert len(s.encode()) <= 2048
    t = STATUS.with_suffix(".rf36.tmp"); t.write_text(s + "\n"); t.replace(STATUS)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--lease-granted", action="store_true", required=True)
    ap.add_argument("--reuse-builds", action="store_true")
    args = ap.parse_args()
    os.setpriority(os.PRIO_PROCESS, 0, 10)
    assert os.getloadavg()[0] < 24
    old = json.loads((OUT / "results.json").read_text()) if args.reuse_builds else []
    if args.reuse_builds:
        assert json.loads((OUT / "selection.json").read_text())["source_sha256"] == hashlib.sha256((ROOT / "rtl/serv/serv_rf_ram.v").read_bytes()).hexdigest()
        assert all(any(r["name"]==n and r["pass"] for r in old) for n in
            ["qlint", "build-main", "build-compact-off", "build-explicit-on", "build-compact-on"])
    prepare()
    results = [r for r in old if r["name"]=="qlint" or r["name"].startswith("build-")]

    def run(name, cmd, fault=False):
        start = time.monotonic()
        with (OUT / f"{name}.log").open("w") as log:
            p = subprocess.Popen(list(map(str, cmd)), cwd=OUT, stdout=log, stderr=subprocess.STDOUT)
            status(f"RF36 {name}", p.pid)
            rc = p.wait()
        text = (OUT / f"{name}.log").read_text(errors="replace")
        passed = rc != 0 and "RF36_PUBLIC" in text if fault else rc == 0
        row = {"name": name, "command": list(map(str, cmd)), "rc": rc, "pass": passed,
            "seconds": round(time.monotonic()-start, 3), "log_sha256": hashlib.sha256(text.encode()).hexdigest(),
            "summary": [l for l in text.splitlines() if "_PASS" in l or "FATAL:" in l]}
        results.append(row); (OUT / "results.json").write_text(json.dumps(results, indent=2)+"\n")
        print(json.dumps(row), flush=True)
        assert passed, name + ": " + text[-3000:]
        return text

    if not args.reuse_builds:
        run("qlint", ["python3", ROOT / "tools/ds/qlint.py", ROOT / "rtl/serv/serv_rf_ram.v"])
    for name, flags in [("main", []), ("compact-off", ["NDS_SERV_RF_NATIVE36"]),
                        ("explicit-on", ["NDS_SERV_RF_MLAB36"]),
                        ("compact-on", ["NDS_SERV_RF_NATIVE36", "NDS_SERV_RF_MLAB36"])]:
        if args.reuse_builds:
            continue
        run("build-"+name, [TOOLS / "verilator", "--cc", "--build", "-j", "1", "--threads", "1",
            "-Wno-fatal", "--top-module", "serv_rf_ram", "-Gwidth=2", "-Gcsr_regs=0",
            "--Mdir", OUT / ("obj-"+name)] + ["-D"+x for x in flags] + [ROOT / "rtl/serv/serv_rf_ram.v"])
    for fault in [False, True]:
        name = "fault" if fault else "overlay"
        run("compile-"+name, [TOOLS / "iverilog", "-g2012", "-s", "tb_overlay", "-o", OUT / (name+".vvp"),
            OUT / ("fault.v" if fault else "native_mlab.v"), OUT / "production.v", OUT / "original.v",
            ROOT / "rtl/serv/serv_rf_ram_if.v", ROOT / "sim/serv_rf36/native_m10k.sv",
            ROOT / "sim/serv_rf36/tb_overlay.sv", VENDOR / "altera_mf.v"])
        text = run(name, [TOOLS / "vvp", OUT / (name+".vvp")], fault)
        if not fault:
            assert "RF36_OVERLAY_PASS" in text
    status("RF36 new overlay/build/fault PASS; price handoff preparation", active=False)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        status("RF36 new overlay/build FAILED; preserve witness and fix fixture/binding", active=False)
        raise
