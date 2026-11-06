"""Changed head identity: MAIN repeats and affected cancellation/shift checks."""
from pathlib import Path
exec(compile(Path(__file__).with_name("runner_functions.py").read_text(),
             "runner_functions.py", "exec"))
import shutil

result = dict(main={}, adverse={}, shift={})


def build(role, directory):
    sources = sorted((ROOT / directory).glob("*.sv"), key=lambda p: p.name != "arm_pkg.sv")
    out = ROOT / role / "obj"
    guard()
    command = ["build/tools/oss-cad-suite/bin/verilator", "--binary",
               "--timing", "--assert", "--threads", "1", "-j", "1", "-O2", "-Wno-fatal",
               "--top-module", "tb", "-GHEAD_RETURN=1", "--Mdir", str(out), *map(str, sources)]
    log = ROOT / (role + "/build.log")
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as stream:
        child = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        row = dict(pid=child.pid, starttime=starttime(child.pid), controller=controller, command=command)
        save("active.json", row)
        print("START", role + "/build", child.pid, flush=True)
        rc = wait_owned(child)
    row.update(exit=rc, reaped=True)
    save(role + "/build.process.json", row)
    assert rc == 0, log.read_text()[-3000:]
    retained = ROOT / role / "retained-Vtb"
    shutil.copy2(out / "Vtb", retained)
    save(role + "/model.json", dict(sha256=sha(retained),
                                    sources={str(p.relative_to(ROOT)): sha(p) for p in sources}))
    return retained


try:
    model = build("on", "source")
    model_hash = sha(model)
    for name, kind, case, rs, rs6, ds, _ in cases:
        reports = []
        for rep in range(5):
            elapsed = {}
            for n in [4, 16]:
                tag = f"on/{name}-r{rep}-n{n}"
                elapsed[str(n)] = run(tag, kind, case, rs, rs6, 1, n)
                if rep:
                    duplicates(tag, f"on/{name}-r0-n{n}")
                else:
                    for ext in ["state", "data"]:
                        assert architectural(ROOT / (tag + "." + ext)) == architectural(
                            ROOT / "previous-main" / f"{name}-n{n}.{ext}"), (name, n, ext)
                    save(tag + ".prior-captures.json", {ext: dict(
                        before=sha(ROOT / "previous-main" / f"{name}-n{n}.{ext}"),
                        after=sha(ROOT / (tag + "." + ext)),
                        literal_equal=(ROOT / "previous-main" / f"{name}-n{n}.{ext}").read_bytes() ==
                                      (ROOT / (tag + "." + ext)).read_bytes())
                        for ext in ["state", "data", "edge", "full", "pins", "slot", "phase", "csv"]})
            assert elapsed["16"] - elapsed["4"] == 2 * ds, (name, rep, elapsed, ds)
            reports.append(dict(repetition=rep, elapsed=elapsed, DS_exact=True))
            result["main"][name] = reports
            save("results.json", result)
    for scenario in [1, 2, 3, 4, 5]:
        tag = f"adverse/s{scenario}"
        elapsed = run(tag, 1, 1, 0x7fffffff, 0x7fffffff, 1, 4, scenario)
        compared = {}
        for ext in ["state", "data"]:
            current = architectural(ROOT / (tag + "." + ext))
            old = architectural(ROOT / f"previous-adverse/s{scenario}.{ext}")
            if scenario == 2:
                current = current[current.index("RESET") + 1:]
                old = old[old.index("RESET") + 1:]
            assert current == old, (tag, ext)
            compared[ext] = len(current)
        result["adverse"][str(scenario)] = dict(elapsed=elapsed, normalized_equal=True, rows=compared)
        save("results.json", result)
    model = build("shift", "shift-source")
    model_hash = sha(model)
    for scenario in [0, 1, 5]:
        tag = f"shift/s{scenario}"
        elapsed = run(tag, 1, 0, 1, 1, 1, 4, scenario)
        assert "RSHIFT_META_PASS" in (ROOT / (tag + ".log")).read_text()
        compared = {}
        for ext in ["state", "data"]:
            current = architectural(ROOT / (tag + "." + ext))
            old = architectural(ROOT / f"previous-shift/s{scenario}.{ext}")
            assert current == old, (tag, ext)
            compared[ext] = len(current)
        result["shift"][str(scenario)] = dict(elapsed=elapsed, normalized_equal=True, rows=compared)
        save("results.json", result)
    save("complete.json", dict(controller=controller, MAIN_DS_exact_pairs=35, adverse=5, shift=3))
    print("HEAD_IDENTITY_MAIN_CONTROLS_PASS", flush=True)
except BaseException:
    save("failure.json", dict(traceback=traceback.format_exc()))
    raise
finally:
    for role in ["on", "shift"]:
        if (ROOT / role / "obj").exists():
            for path in (ROOT / role / "obj").iterdir():
                if path.is_file() and path.name not in ["Vtb", "Vtb__verFiles.dat"]:
                    path.unlink()
    save("terminal.json", dict(controller=controller, complete=(ROOT / "complete.json").exists()))
