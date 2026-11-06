"""Only unmet controls; previous timing repeats and reset run are not repeated."""
from pathlib import Path
exec(compile(Path(__file__).with_name("runner_functions.py").read_text(),
             "runner_functions.py", "exec"))

result = dict(adverse={}, shift={}, fetch39=[])
fetch_only = json.loads((ROOT / "configuration.json").read_text()).get("fetch_only", False)
if (ROOT / "previous-controls.json").exists():
    result["fetch39"] = json.loads((ROOT / "previous-controls.json").read_text())["fetch39"]


def execute(cmd, tag):
    guard()
    log = ROOT / (tag + ".log")
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as stream:
        child = subprocess.Popen(list(map(str, cmd)), cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        row = dict(pid=child.pid, starttime=starttime(child.pid), tag=tag,
                   command=list(map(str, cmd)), controller=controller)
        save("active.json", row)
        print("START", tag, child.pid, flush=True)
        rc = wait_owned(child)
    row.update(exit=rc, reaped=True)
    save(tag + ".process.json", row)
    text = log.read_text()
    assert rc == 0, (tag, rc, text[-3500:])
    return text


def build(directory, role):
    sources = sorted((ROOT / directory).glob("*.sv"), key=lambda p: p.name != "arm_pkg.sv")
    out = ROOT / role / "obj"
    execute(["build/tools/oss-cad-suite/bin/verilator",
             "--binary", "--timing", "--assert", "--threads", "1", "-j", "1", "-O2",
             "-Wno-fatal", "+define+A7_FLOW_SOURCE", "--top-module", "tb", "--Mdir", out,
             *(["-GHEAD_RETURN=1"] if role == "shift" else []), *sources], role + "/build")
    save(role + "/model.json", dict(sha256=sha(out / "Vtb"),
                                    inputs={str(p.relative_to(ROOT)): sha(p) for p in sources}))
    return out / "Vtb"


try:
    for scenario in ([] if fetch_only else [1, 2, 3, 4, 5]):
        tag = f"adverse/s{scenario}"
        text = execute(command(tag, 1, 1, 0x7fffffff, 0x7fffffff, 1, 4, scenario), tag)
        for marker in ["PHASE_FUNCTION_PASS errors0", "PAIRED_SLOT_PASS", "ADVERSE_PASS"]:
            assert marker in text, (tag, marker)
        checked = {}
        for ext in ["state", "data"]:
            current = architectural(ROOT / (tag + "." + ext))
            previous = architectural(ROOT / f"reference/c1-s{scenario}-p1/{ext}")
            if scenario == 2:
                # Reset is triggered by the live held packet, so faster
                # execution can retire a different prefix before that event.
                # Compare the actual restarted architectural execution.
                current = current[current.index("RESET") + 1:]
                previous = previous[previous.index("RESET") + 1:]
            assert current == previous, (tag, ext, "architectural difference")
            checked[ext] = dict(rows=len(current), normalized_equal=True)
        result["adverse"][str(scenario)] = checked
        save("results.json", result)
    if not fetch_only:
        model = build("shift-source", "shift")
    for scenario in ([] if fetch_only else [0, 1, 5]):
        tag = f"shift/s{scenario}"
        text = execute(command(tag, 1, 0, 1, 1, 1, 4, scenario), tag)
        for marker in ["RSHIFT_META_PASS", "PHASE_FUNCTION_PASS errors0", "PAIRED_SLOT_PASS", "ADVERSE_PASS"]:
            assert marker in text, (tag, marker)
        checked = {}
        for ext in ["state", "data"]:
            current = architectural(ROOT / (tag + "." + ext))
            previous = architectural(ROOT / f"shift-reference/s{scenario}.{ext}")
            assert current == previous, (tag, ext, "architectural difference")
            checked[ext] = dict(rows=len(current), normalized_equal=True)
        result["shift"][str(scenario)] = checked
        save("results.json", result)
    model = build("fetch-source", "fetch")
    ds = json.loads((ROOT / "ds39.json").read_text())["summaries"]
    for case in json.loads((ROOT / "fetch-cases.json").read_text()):
        for region in [0, 1]:
            name = case["case"]
            if any(row["case"] == name and row["region"] == region for row in result["fetch39"]):
                continue
            entry = case["main_entry"] if region else case["source_entry"]
            body = case["main_body"] if region else case["source_body"]
            elapsed = {"before": {}, "after": {}}
            for n in [4, 16]:
                tag = f"fetch/{name}-r{region}-n{n}"
                text = execute([model, f'+img={ROOT / "fetch-images" / (name + ".hex")}',
                                f'+entry={entry:x}', f'+source={case["source_entry"]:x}',
                                f'+body={body:x}', f'+size={case["size"]}',
                                f'+sum={case["checksum"]}', f'+loops={n}',
                                f'+trace={ROOT / tag}', f'+data={ROOT / tag}'], tag)
                assert "FETCH39_FUNCTION_PASS" in text
                for label, mode in [("before", 0), ("after", 1)]:
                    match = re.search(r"PHYS_PASS mode" + str(mode) + r" cycles(\d+)", text)
                    assert match
                    elapsed[label][str(n)] = int(match[1])
                for ext in ["csv", "data", "fcomp"]:
                    assert (ROOT / (tag + "-m0." + ext)).read_bytes() == (ROOT / (tag + "-m1." + ext)).read_bytes(), (tag, ext, "architectural/fetch difference")
            target = next(row for row in ds if row["name"] == name and
                          row["region"] == ("MAIN" if region else "private_WRAM"))
            expected = 2 * (target["min16"] - target["min4"])
            delta = elapsed["after"]["16"] - elapsed["after"]["4"]
            before = elapsed["before"]["16"] - elapsed["before"]["4"]
            result["fetch39"].append(dict(case=name, region=region, elapsed=elapsed,
                                          actual_delta_core=delta, before_delta_core=before,
                                          DS_delta_core=expected, DS_exact=delta == expected,
                                          unchanged_or_closer=abs(delta-expected)<=abs(before-expected)))
            save("results.json", result)
    save("complete.json", dict(controller=controller, adverse=0 if fetch_only else 5,
                               shift=0 if fetch_only else 3,
                               fetch39=36, fetch39_exact=sum(r["DS_exact"] for r in result["fetch39"])))
    print("IF_HEAD_REMAINING_CONTROLS_COMPLETE", flush=True)
except BaseException:
    save("failure.json", dict(traceback=traceback.format_exc()))
    raise
finally:
    save("terminal.json", dict(controller=controller, complete=(ROOT / "complete.json").exists()))
