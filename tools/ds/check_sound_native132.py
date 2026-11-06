#!/usr/bin/env python3
"""Check the explicit sound context RAM with the installed Intel model.

Reuses the pinned native131 stimulus and codec oracle, compares to the actual
previous component, and adds writes attempted while CE is low. No Quartus,
production integration, or area/DS timing claim. All simulations are serial.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]
SOURCE = "b9b8249b44e24528feea8f038eab6de01945334c"
BASELINE = "03090d9bae4e2456370fa703bf0674f37246ae90"
DONOR = "0a4b5dbac44e351939cc0ccb64ba8a3d196a2095"
RTL = "rtl/sound/study/sound_native130.sv"
MODEL = ROOT.parent / "openfpga-PlayStation/build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v"
MODEL_SHA256 = "ce0c10121162fc3f07c0056046017e0b9030f7a127face48586ffdb1ff713466"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True)


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError("source anchor changed: " + before)
    return text.replace(before, after, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--source", default=SOURCE)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--model", type=Path, default=MODEL)
    parser.add_argument("--status-file", type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    model = args.model.resolve(strict=True)
    if sha(model) != MODEL_SHA256:
        raise ValueError("Intel model differs from the inspected native132 handoff dependency")
    os.setpriority(os.PRIO_PROCESS, 0, 10)
    source = git("rev-parse", args.source + "^{commit}").strip()
    baseline = git("rev-parse", args.baseline + "^{commit}").strip()
    inputs = {}

    def pinned(ref, path):
        text = git("show", ref + ":" + path)
        inputs[ref + ":" + path] = hashlib.sha256(text.encode()).hexdigest()
        return text

    candidate = pinned(source, RTL)
    if "altsyncram #(" not in candidate:
        raise ValueError("candidate must instantiate the native RAM")
    (out / "candidate.sv").write_text(candidate)
    before = pinned(baseline, RTL)
    (out / "before.sv").write_text(replace_once(
        before, "module sound_native130 #(", "module sound_native130_before #("))
    tb = pinned(source, "sim/sound/native130_tb.sv")
    # Do not inherit an implicit time unit from the vendor compilation unit.
    # This is a functional 10ns test clock, not a physical timing constraint.
    tb = "`timescale 1ns/1ps\n" + tb
    # In the inherited matrix CE pauses only occur with writes deasserted.
    # Attempt writes to every row while paused, then read every row back.
    # The retained golden image must be unchanged; outputs must hold while
    # addresses/data/byte enables change and a RAM request is in flight.
    paused = """
 for(integer a=0;a<256;a=a+1)begin
  read_addr=8'(a^85);tick();
  wr=1;write_addr=8'(a);write_data=~pattern(a);byte_en=20'hfffff;
  read_addr=8'(a^170);pause_ce(2);wr=0;byte_en=0;tick();
 end
 for(integer a=0;a<256;a=a+1)begin read_addr=8'(a);tick();end
 repeat(4)tick();
 $display("PASS132_PAUSED_WRITES rows=256 edges=512");
"""
    tb = replace_once(tb, " pause_ce(5);", " pause_ce(5);\n" + paused)
    (out / "tb.sv").write_text(tb)
    engine = pinned(DONOR, "rtl/sound/sound_engine.svh")
    ram = pinned(DONOR, "rtl/sound/sound_ram.sv")
    (out / "sound_ram_pinned.sv").write_text(ram)
    start = engine.index("    logic        d_ok;")
    oracle = engine[start:engine.index("    logic at_loop;", start)]
    start = oracle.index("`ifndef ALTERA_RESERVED_QIS")
    end = oracle.index("`endif", start) + len("`endif")
    oracle = oracle[:start] + oracle[end:]
    header = """module codec_reference(input logic[14:0] step,input logic[6:0] idx,input logic[3:0] nib,input logic[15:0]f_val,output logic[15:0] sample,output logic[6:0]index);
localparam WORKER_PIPE=0,OWNED_RUNTIME=0;
wire[33:0]ff_q={19'd0,step};wire[9:0]rom_ra_q={idx,nib[2:0]};wire[22:0]rom_q;
wire[15:0]pipe_decode_sample=0;wire[6:0]pipe_decode_index=0;
sound_adpcm_step original(.step,.ra(rom_ra_q),.q(rom_q));
"""
    (out / "codec_reference.sv").write_text(header + oracle +
        "assign sample=vnew;assign index=inew;\nendmodule\n")
    start = ram.index("    function automatic logic [14:0] adpcm_step")
    end = ram.index("    endfunction", start) + len("    endfunction")
    (out / "step_function.svh").write_text(ram[start:end] + "\n")
    mutants = {
        "read-row": (".address_b(read_addr_q)", ".address_b(read_addr_q ^ 8'h80)",
                     "NATIVE_ROW_MISMATCH"),
        "ce-write": (".clocken0(ce)", ".clocken0(1'b1)", "NATIVE_ROW_MISMATCH"),
        "old-data": ('.read_during_write_mode_mixed_ports("OLD_DATA")',
                     '.read_during_write_mode_mixed_ports("DONT_CARE")',
                     "NATIVE_ROW_MISMATCH"),
        "saturation": ("parameter bit FAULT_SAT = 1'b0",
                       "parameter bit FAULT_SAT = 1'b1", "CODEC_VALUE_MISMATCH"),
    }
    for name, (old, new, _) in mutants.items():
        (out / (name + ".sv")).write_text(replace_once(candidate, old, new))
    toolroot = ROOT.parent / "openfpga-PlayStation/build/tools/oss-cad-suite/bin"

    def tool(name):
        found = shutil.which(name) or str(toolroot / name)
        if not Path(found).is_file():
            raise FileNotFoundError(found)
        return found

    report = dict(source=source, baseline=baseline, donor=DONOR, inputs=inputs,
                  vendor_model=dict(path=str(model), sha256=sha(model)),
                  checker_sha256=sha(Path(__file__)), cases=[], workers=[],
                  scope="Isolated context store/codec; no full sound service, native FIFO mapping, Standard legality, area, STA or DS acceptance")

    def save():
        (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")

    def status(pid=None):
        if args.status_file:
            state = json.loads(args.status_file.read_text())
            state["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            state["worker"] = dict(active=pid is not None, host="Desktop", PID=pid,
                                   controller=os.getpid(), NI=10, jobs=1, threads=1)
            data = json.dumps(state, separators=(",", ":")) + "\n"
            if len(data.encode()) > 2048:
                raise ValueError("owner status exceeds 2KB")
            temp = args.status_file.with_suffix(".tmp")
            temp.write_text(data)
            temp.replace(args.status_file)

    def run(argv, log):
        with (out / log).open("w") as stream:
            process = subprocess.Popen(list(map(str, argv)), stdout=stream, stderr=subprocess.STDOUT)
            record = dict(pid=process.pid, argv=list(map(str, argv)), log=log)
            report["workers"].append(record)
            save()
            try:
                status(process.pid)
                record["exit"] = process.wait(timeout=55)
            except BaseException:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise
            finally:
                record["reaped"] = process.poll() is not None
                save()
                status()
        return record["exit"], (out / log).read_text()

    try:
        for name in ["positive", *mutants]:
            rtl = "candidate.sv" if name == "positive" else name + ".sv"
            argv = [tool("iverilog"), "-g2012", "-I", out, "-s", "native130_tb",
                    "-o", out / (name + ".vvp"), model, out / "tb.sv", out / "before.sv",
                    out / "codec_reference.sv", out / rtl, out / "sound_ram_pinned.sv"]
            rc, log = run(argv, name + "-build.log")
            if rc:
                raise RuntimeError(name + " frontend failed: " + log[-1800:])
            rc, log = run([tool("vvp"), out / (name + ".vvp")], name + ".log")
            if name == "positive":
                counts = re.search(r"PASS130_NATIVE_CODEC states=(\d+) bankcycles=(\d+) FIFOcycles=(\d+) latency=4", log)
                holds = re.search(r"PASS131_CE_HOLD checks=(\d+)", log)
                if rc or not counts or not holds or "PASS132_PAUSED_WRITES rows=256 edges=512" not in log:
                    raise RuntimeError("native positive failed: " + log[-1800:])
                if int(counts[1]) != 14336 or min(int(counts[2]), int(counts[3])) < 62987 or int(holds[1]) < 517:
                    raise RuntimeError("incomplete native coverage")
                report["checks"] = dict(codec_transitions=int(counts[1]), bank_cycles=int(counts[2]),
                                        fifo_cycles=int(counts[3]), ce_hold_edges=int(holds[1]),
                                        paused_write_rows=256, native_return_FAST=2, codec_result_FAST=4)
            elif rc == 0 or mutants[name][2] not in log:
                raise RuntimeError("mutant not caught by expected diagnostic: " + name + " " + log[-1800:])
            report["cases"].append(dict(case=name, exit=rc, source_sha256=sha(out / rtl),
                                        expected_diagnostic=None if name == "positive" else mutants[name][2],
                                        log_sha256=sha(out / (name + ".log"))))
            save()
            print(name + ": " + log.strip(), flush=True)
        report["status"] = "PASS"
    except BaseException as error:
        report["status"] = "FAIL"
        report["error"] = str(error)
        raise
    finally:
        report["files"] = {p.name: sha(p) for p in out.iterdir() if p.is_file() and p.name != "result.json"}
        save()
    print("PASS132_INTEL_NATIVE_EQUIVALENCE_AND_MUTANTS")


if __name__ == "__main__":
    main()
