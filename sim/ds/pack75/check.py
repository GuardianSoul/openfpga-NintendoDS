#!/usr/bin/env python3
"""Header packing: prepare sources freely; run only on an allocated unit lease.

The executable compares public protocol cycles and meaningful data against
the literal predecessor, with an independent full-capacity payload oracle.
The mutant changes the actual masked-write way in production RTL.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import resource
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build/pack75/unit"
BASE = "3e8355aa431fa34d7d04918b4d9fc84ecdb7b10a"
SOURCE = "rtl/ds/nds_g3d_pair_cache.sv"
VERILATOR = "build/tools/oss-cad-suite/bin/verilator"
OWNER = Path("/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def put(path, value):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(path)


def prepare():
    OUT.mkdir(parents=True, exist_ok=True)
    old = subprocess.check_output(["git", "show", BASE + ":" + SOURCE], cwd=ROOT).decode()
    old = old.replace("module nds_g3d_pair_cache #(", "module pack75_before #(", 1)
    (OUT / "before.sv").write_text(old)
    current = (ROOT / SOURCE).read_text()
    needle = ".clk, .we(filling && beat == 2'd3), .way(miss_way),"
    assert current.count(needle) == 1
    mutant = current.replace("module nds_g3d_pair_cache #(", "module pack75_mutant #(", 1)
    mutant = mutant.replace("nds_g3d_header_data", "pack75_mutant_header_data")
    mutant = mutant.replace(needle, ".clk, .we(filling && beat == 2'd3), .way(miss_way ^ 2'd1),", 1)
    (OUT / "mutant.sv").write_text(mutant)
    command = [VERILATOR, "--binary", "--timing", "--assert", "-j", "1", "--threads", "1",
               "-Wno-fatal", "--top-module", "tb_pack75", "--Mdir", str(OUT / "obj"),
               str(ROOT / "rtl/gpu3d/gpu3d_ram.sv"), str(OUT / "before.sv"),
               str(ROOT / SOURCE), str(OUT / "mutant.sv"), str(ROOT / "sim/ds/pack75/tb.sv")]
    put(OUT / "command.json", command)
    files = [OUT / "before.sv", OUT / "mutant.sv", ROOT / SOURCE,
             ROOT / "rtl/gpu3d/gpu3d_ram.sv", ROOT / "sim/ds/pack75/tb.sv"]
    result = dict(base=BASE, source_sha256=sha(ROOT / SOURCE),
                  compiled_inputs={str(p): sha(p) for p in files},
                  command_sha256=sha(OUT / "command.json"),
                  status="PREPARED_NOT_BUILT_OR_RUN", workers=[])
    put(OUT / "preparation.json", result)
    return result


def owner(phase, worker=None):
    value = json.loads(OWNER.read_text())
    value.update(phase="PACK75_" + phase, worker=[] if worker is None else [worker],
                 source_sha256=sha(ROOT / SOURCE), updated_at=time.time())
    tmp = OWNER.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, separators=(",", ":")) + "\n")
    assert tmp.stat().st_size <= 2048
    tmp.replace(OWNER)


def run(label, command, fault=False):
    def limits():
        os.setpriority(os.PRIO_PROCESS, 0, 10)
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    started = time.monotonic()
    put(OUT / (label + "-command.json"), command)
    with (OUT / (label + ".log")).open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, preexec_fn=limits)
        worker = dict(host=os.uname().nodename, pid=process.pid,
                      starttime=Path(f"/proc/{process.pid}/stat").read_text().split()[21],
                      NI=10, jobs=1, threads=1)
        owner(label, worker)
        rc = process.wait()
    owner(label + "_DONE")
    text = (OUT / (label + ".log")).read_text()
    verdict = bool(rc and "PACK75_ACTUAL_WAY_MUTANT_CAUGHT" in text) if fault else rc == 0 and (label == "BUILD" or "PACK75_PASS" in text)
    receipt = dict(exit=rc, expected_actual_mutant=fault, passed=verdict,
                   seconds=time.monotonic() - started, log_sha256=sha(OUT / (label + ".log")))
    put(OUT / (label + "-receipt.json"), receipt)
    assert verdict, (label, text[-3000:])
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "run"])
    args = parser.parse_args()
    if args.action == "prepare":
        print(json.dumps(prepare(), indent=2))
        return
    assert os.getloadavg()[0] < 24
    # Preserve finished results and fixture faults; no automatic reruns.
    (OUT / "run.attempt").open("x").write(str(time.time()) + "\n")
    result = json.loads((OUT / "preparation.json").read_text())
    for path, value in result["compiled_inputs"].items():
        assert sha(path) == value, path
    assert sha(OUT / "command.json") == result["command_sha256"]
    result["build"] = run("BUILD", json.loads((OUT / "command.json").read_text()))
    model = OUT / "obj/Vtb_pack75"
    result["model_sha256"] = sha(model)
    result["positive"] = [run("RUN" + str(seed), [str(model), "+seed=" + str(seed)]) for seed in [1, 17, 75]]
    result["actual_mutant"] = run("MUTANT", [str(model), "+seed=75", "+mutant"], fault=True)
    result["status"] = "PASS_HEADER_PUBLIC_CYCLES_DATA_ORDER_AND_ACTUAL_MASKED_WAY_MUTANT"
    put(OUT / "result.json", result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
