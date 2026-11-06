#!/usr/bin/env python3
"""Native RAM and actual WRAM arbitration check for the paired RAM trade.

Uses unchanged shared-WRAM and production arbitration stimuli. No Quartus or
DS/reference acceptance. P7 representation has its own retained proof.
"""
import argparse
import hashlib
import json
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[3]
BASE = "04cecc678a5fce5274021a1ee453234902085d64"
TOOLS = Path("build/tools/oss-cad-suite/bin")
MODEL = Path("build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v")
STATUS = Path("/home/user/Git/NDS_Pocket/build/coordinator/units/DirectionReview.json")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def replace(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--joined-only", action="store_true", help="resume the independent arbitration check")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    os.setpriority(os.PRIO_PROCESS, 0, 10)
    assert sha(MODEL.read_bytes()) == "ce0c10121162fc3f07c0056046017e0b9030f7a127face48586ffdb1ff713466"
    rec = dict(source=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               baseline=BASE, model_sha256=sha(MODEL.read_bytes()), stages=[], inputs={}, status="RUNNING")

    def old(path):
        return subprocess.check_output(["git", "show", BASE + ":" + path], cwd=ROOT).decode()

    def current(path):
        data = (ROOT / path).read_bytes()
        rec["inputs"][path] = sha(data)
        return data.decode()

    def save():
        (out / "receipt.json").write_text(json.dumps(rec, indent=2) + "\n")

    def status(pid=None):
        state = json.loads(STATUS.read_text())
        state["worker"].update(active=pid is not None, PID=pid, controller=os.getpid())
        temp = STATUS.with_suffix(".tmp")
        temp.write_text(json.dumps(state, separators=(",", ":")) + "\n")
        temp.replace(STATUS)

    def run(name, argv, expect=None, fault=False):
        with (out / (name + ".log")).open("w") as log:
            p = subprocess.Popen(list(map(str, argv)), stdout=log, stderr=subprocess.STDOUT)
            row = dict(name=name, PID=p.pid, command=list(map(str, argv)))
            rec["stages"].append(row)
            save()
            try:
                status(p.pid)
                row["exit"] = p.wait(timeout=180)
            except BaseException:
                p.terminate()
                try:
                    p.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
                raise
            finally:
                row["reaped"] = p.poll() is not None
                save()
                status()
        text = (out / (name + ".log")).read_text()
        assert (row["exit"] != 0 if fault else row["exit"] == 0), (name, text[-1800:])
        if expect:
            assert expect in text, (name, text[-1800:])
        print(name, row["exit"], text[-300:] if expect else "compiled", flush=True)

    def compile(name, top, sources):
        run(name + "-build", [TOOLS / "iverilog", "-g2012", "-D", "ALTERA_RESERVED_QIS",
                              "-s", top, "-o", out / (name + ".vvp"), MODEL, *sources])

    try:
        ram = current("rtl/arm/arm7_wram.sv")
        assert ram == old("rtl/arm/arm7_wram.sv"), "this trade must reuse the qualified memory implementations"
        (out / "current.sv").write_text(ram)
        before = re.sub(r"\b(arm7_wram(?:_dense|_shared)?)\b", r"\1_before", ram)
        (out / "before.sv").write_text(before)
        for path in ["rtl/ds/nds_ram.sv", "rtl/ds/nds_fr_arb.sv"]:
            assert current(path) == old(path)
            (out / Path(path).name).write_text(current(path))
        tb = current("sim/arm/shared_wram/tb_shared_wram.sv")
        tb = replace(tb, "#(.SHARED_DENSE(1'b1)) dut", "#(.SHARED_DENSE(1'b0)) dut")
        tb = replace(tb, "arm7_wram_before old(", "arm7_wram_before #(.SHARED_DENSE(1'b1)) old(")
        (out / "tb.sv").write_text(tb)
        common = [out / "nds_ram.sv", out / "before.sv", out / "tb.sv"]
        if not args.joined_only:
            compile("native", "tb_shared_wram", [*common, out / "current.sv"])
            run("native", [TOOLS / "vvp", out / "native.vvp"], "PASS_SHARED_WRAM_NATIVE")
            run("late", [TOOLS / "vvp", out / "native.vvp", "+late-only"], "PASS_SHARED_WRAM_LATE")
            faulty = replace(ram, ".clk, .a_addr, .a_we, .a_d, .a_q, .b_addr, .b_we, .b_d, .b_q);",
                             ".clk, .a_addr, .a_we(a_we & 4'b0111), .a_d, .a_q, .b_addr, .b_we, .b_d, .b_q);")
            (out / "mutant.sv").write_text(faulty)
            compile("byte-fault", "tb_shared_wram", [*common, out / "mutant.sv"])
            run("byte-fault", [TOOLS / "vvp", out / "byte-fault.vvp"], "A own NEW_DATA mismatch", fault=True)

        archive_ref = "0d6bb3d3f57ef66b990db0965543fabd1517aa1d:docs/results/compact-mapping1205-1207-20261102/evidence.tar.gz"
        archive = subprocess.check_output(["git", "show", archive_ref], cwd=ROOT)
        rec["joined_stimulus_archive_ref"] = archive_ref
        rec["joined_stimulus_archive_sha256"] = sha(archive)
        with tarfile.open(fileobj=io.BytesIO(archive)) as t:
            header = t.extractfile("joined/current_binding.sv").read().decode().split("    logic wrb_done;")[0]
            joined_tb = t.extractfile("joined/tb.sv").read()
        (out / "joined_tb.sv").write_bytes(joined_tb)

        def binding(source, name):
            start = source.index("    logic wrb_done;")
            end = source.index("));", source.index("    nds_fr_arb u_frarb", start)) + 3
            return header.replace("joined_current", name) + "localparam WRAM_REINVEST=1;\n" + source[start:end] + "\nassign service_data=ram_fr_rdata;\nendmodule\n"

        (out / "joined_before.sv").write_text(binding(old("rtl/ds/nds_top.sv"), "joined_previous"))
        joined = binding(current("rtl/ds/nds_top.sv"), "joined_current")
        (out / "joined_current.sv").write_text(joined)
        (out / "joined_fault.sv").write_text(replace(joined, ".a_be(wr_be)", ".a_be(4'd0)"))
        joined_common = [out / "nds_ram.sv", out / "nds_fr_arb.sv", out / "current.sv", out / "joined_before.sv", out / "joined_tb.sv"]
        compile("joined", "tb", [*joined_common, out / "joined_current.sv"])
        run("joined", [TOOLS / "vvp", out / "joined.vvp"], "PASS_JOINED_WRAM")
        compile("caller-fault", "tb", [*joined_common, out / "joined_fault.sv"])
        run("caller-fault", [TOOLS / "vvp", out / "caller-fault.vvp"], "JOINED_PUBLIC_DATA_A", fault=True)
        rec["status"] = "PASS_JOINED_AND_ACTUAL_CALLER_FAULT" if args.joined_only else "PASS_NATIVE_LATE_JOINED_AND_TWO_ACTUAL_FAULTS"
    except BaseException as e:
        rec["status"] = "FAIL"
        rec["error"] = str(e)
        raise
    finally:
        rec["files"] = {p.name: sha(p.read_bytes()) for p in out.iterdir() if p.is_file() and p.name != "receipt.json"}
        save()
    print(rec["status"])


if __name__ == "__main__":
    main()
