#!/usr/bin/env python3
"""Inspect paired-option routing in the complete APF frontend and catch a cut.

The command JSON is the saved selected APF codegen command, using the exact
generated QSF macros. Its inputs and simulation-only adapters are archived.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]


def walk(obj):
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from walk(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from walk(value)


def inspect(ast, enabled):
    modules = {m["addr"]: m for m in ast["modulesp"]}
    top = next(m for m in modules.values() if m.get("origName") == "apf_top")

    def child(module, name):
        cells = [c for c in walk(module.get("stmtsp", []))
                 if c.get("type") == "CELL" and c.get("name", "").split(".")[-1] == name]
        assert len(cells) == 1, name
        return modules[cells[0]["modp"]]

    def parameters(module):
        return {v["name"]: v["valuep"][0]["name"] for v in module["stmtsp"]
                if v.get("type") == "VAR" and v.get("isParam")}

    def number(value):
        match = re.fullmatch(r"\d+'s?([bdho])([0-9a-f_]+)", value)
        assert match, value
        return int(match[2].replace("_", ""), dict(b=2, d=10, h=16, o=8)[match[1]])

    core = child(top, "ic")
    ds = child(core, "ds")
    cpu = child(ds, "u_cpud")
    port = child(cpu, "u_p7")
    wram = child(ds, "u_wram")
    rows = {name: parameters(module) for name, module in
            [("core", core), ("ds", ds), ("cpu", cpu), ("port", port), ("wram", wram)]}
    expected = [("core", "WRAM_REINVEST", enabled), ("ds", "WRAM_REINVEST", enabled),
                ("cpu", "A7_TAG_MLAB", enabled), ("port", "TAG_WLATE", 1),
                ("port", "TAG_STYLE", int.from_bytes(b"MLAB" if enabled else b"M10K", "big")),
                ("wram", "SHARED_DENSE", 1-enabled)]
    for owner, name, want in expected:
        got = number(rows[owner][name])
        assert got == want, f"ROUTE_MISMATCH {owner}.{name}: {got} != {want}"
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    os.setpriority(os.PRIO_PROCESS, 0, 10)
    base = json.loads(args.command.read_text())
    base.remove("--cc")
    base.remove("+define+NDS_WRAM_REINVEST41")
    path = ROOT / "rtl/pocket/core_top_ds.sv"
    source = path.read_text()
    old = ".WRAM_REINVEST(WRAM_REINVEST)"
    assert source.count(old) == 1
    fault = out / "core_top_disconnect.sv"
    fault.write_text(source.replace(old, ".WRAM_REINVEST(1'b0)", 1))
    rec = dict(cases={}, stages=[], source_sha256=hashlib.sha256(source.encode()).hexdigest(),
               command_sha256=hashlib.sha256(args.command.read_bytes()).hexdigest())

    def save():
        (out / "receipt.json").write_text(json.dumps(rec, indent=2) + "\n")

    for name in ["on", "off", "disconnect"]:
        command = base.copy()
        command[command.index("--Mdir")+1] = str(out / (name + "-obj"))
        ast = out / (name + ".json")
        command += ["--json-only", "--json-only-output", str(ast)]
        if name != "off":
            command += ["+define+NDS_WRAM_REINVEST41"]
        if name == "disconnect":
            command = [str(fault) if value == str(path) else value for value in command]
        with (out / (name + ".log")).open("w") as log:
            p = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            row = dict(name=name, PID=p.pid, command=command)
            rec["stages"].append(row)
            save()
            row.update(exit=p.wait(), reaped=True)
            save()
        assert row["exit"] == 0, (name, (out / (name + ".log")).read_text()[-2000:])
        raw = ast.read_bytes()
        result = dict(AST_sha256=hashlib.sha256(raw).hexdigest())
        if name == "disconnect":
            try:
                inspect(json.loads(raw), 1)
            except AssertionError as error:
                assert str(error) == "ROUTE_MISMATCH ds.WRAM_REINVEST: 0 != 1", str(error)
                result["caught_actual_disconnect"] = str(error)
            else:
                raise AssertionError("public-route fault escaped")
        else:
            result["parameters"] = inspect(json.loads(raw), int(name == "on"))
        rec["cases"][name] = result
        save()
        ast.unlink()
        print(name, "PASS", flush=True)
    # No unrelated CPU, sound, video or service parameter changes between profiles.
    differences = set()
    for owner, before in rec["cases"]["off"]["parameters"].items():
        after = rec["cases"]["on"]["parameters"][owner]
        assert before.keys() == after.keys()
        differences.update((owner, key) for key in before if before[key] != after[key])
    assert differences == {("core", "WRAM_REINVEST"), ("ds", "WRAM_REINVEST"),
                           ("cpu", "A7_TAG_MLAB"), ("port", "TAG_STYLE"), ("wram", "SHARED_DENSE")}, differences
    rec["status"] = "PASS_PUBLIC_ON_OFF_AND_ACTUAL_DISCONNECT"
    save()
    print(rec["status"])


if __name__ == "__main__":
    main()
