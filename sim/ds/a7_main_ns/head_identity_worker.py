"""Allocated actual PHY identity check and paired captured-fetch controls."""
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import traceback

ROOT = Path(__file__).resolve().parent
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
sys.path.insert(0, str(ROOT / "helpers"))
from worker_guard import guard, wait_owned
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def save(name, value):
    path = ROOT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, indent=2) + "\n")
    temp.replace(path)


def start(pid):
    return Path("/proc", str(pid), "stat").read_text().rsplit(")", 1)[1].split()[19]


assert not (ROOT / "controller.json").exists()
controller = dict(pid=os.getpid(), starttime=start(os.getpid()), host=os.uname().nodename,
                  NI=10, jobs=1, threads=1)
save("controller.json", controller)
negative = json.loads((ROOT / "configuration.json").read_text())["negative"]


def call(command, tag, fault=False):
    guard()
    log = ROOT / (tag + ".log")
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as stream:
        child = subprocess.Popen(list(map(str, command)), cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        row = dict(pid=child.pid, starttime=start(child.pid), tag=tag, controller=controller,
                   command=list(map(str, command)))
        save("active.json", row)
        print("START", tag, child.pid, flush=True)
        rc = wait_owned(child)
    row.update(exit=rc, reaped=True)
    save(tag + ".process.json", row)
    text = log.read_text()
    if fault:
        assert rc != 0 and "HEAD_PHYSICAL_WORD_IDENTITY" in text and "timeout" not in text.lower()
    else:
        assert rc == 0, (tag, rc, text[-3000:])
    return text


try:
    for name, digest in json.loads((ROOT / "inputs.json").read_text()).items():
        assert sha(ROOT / name) == digest, name
    sources = sorted((ROOT / "source").glob("*.sv"), key=lambda p: p.name != "arm_pkg.sv")
    call(["build/tools/oss-cad-suite/bin/verilator", "--binary", "--timing",
          "--assert", "--threads", "1", "-j", "1", "-O2", "-Wno-fatal", "+define+A7_FLOW_SOURCE",
          "--top-module", "tb", "--Mdir", ROOT / "obj", *sources], "build")
    model = ROOT / "retained-Vtb"
    shutil.copy2(ROOT / "obj/Vtb", model)
    save("model.json", dict(sha256=sha(model), sources={str(p.relative_to(ROOT)): sha(p) for p in sources}))
    cases = json.loads((ROOT / "cases.json").read_text())
    if negative:
        cases = [next(c for c in cases if c["case"] == "b_s32_o8")]
    previous = json.loads((ROOT / "previous-results.json").read_text())["fetch39"]
    result = []
    for case in cases:
        for region in ([1] if negative else [0, 1]):
            entry = case["main_entry"] if region else case["source_entry"]
            body = case["main_body"] if region else case["source_body"]
            totals = {0: {}, 1: {}}
            for n in ([4] if negative else [4, 16]):
                tag = f'runs/{case["case"]}-r{region}-n{n}'
                text = call([model, f'+img={ROOT / "images" / (case["case"] + ".hex")}',
                             f'+entry={entry:x}', f'+source={case["source_entry"]:x}', f'+body={body:x}',
                             f'+size={case["size"]}', f'+sum={case["checksum"]}', f'+loops={n}',
                             f'+trace={ROOT / tag}', f'+data={ROOT / tag}', f'+events={ROOT / (tag + "-events")}'], tag, negative)
                if negative:
                    save("complete.json", dict(status="Actual old head address fault CAUGHT", controller=controller, tag=tag))
                    break
                assert "FETCH39_FUNCTION_PASS" in text
                old_stem = ROOT / "previous" / Path(tag).name
                for mode in [0, 1]:
                    match = re.search(r"PHYS_PASS mode" + str(mode) + r" cycles(\d+)", text)
                    assert match
                    totals[mode][n] = int(match[1])
                    for ext in ["csv", "data", "fcomp"]:
                        assert (ROOT / (tag + f"-m{mode}." + ext)).read_bytes() == Path(str(old_stem) + f"-m{mode}." + ext).read_bytes(), (tag, mode, ext)
                old_text = Path(str(old_stem) + ".log").read_text()
                old_cycles = int(re.search(r"PHYS_PASS mode0 cycles(\d+)", old_text)[1])
                assert totals[0][n] == old_cycles, (tag, "disabled consumer changed")
            if not negative:
                old = next(r for r in previous if r["case"] == case["case"] and r["region"] == region)
                value = totals[1][16] - totals[1][4]
                result.append(dict(case=case["case"], region=region, elapsed=totals,
                                   before_delta_core=old["actual_delta_core"], actual_delta_core=value,
                                   DS_delta_core=old["DS_delta_core"],
                                   not_wider=abs(value-old["DS_delta_core"]) <= abs(old["actual_delta_core"]-old["DS_delta_core"])))
                save("results.json", result)
    if not negative:
        save("complete.json", dict(controller=controller, rows=len(result),
                                   changed=sum(r["before_delta_core"] != r["actual_delta_core"] for r in result),
                                   wider=[r for r in result if not r["not_wider"]]))
except BaseException:
    save("failure.json", dict(traceback=traceback.format_exc()))
    raise
finally:
    if (ROOT / "obj").exists():
        for path in (ROOT / "obj").iterdir():
            if path.is_file() and path.name not in ["Vtb", "Vtb__verFiles.dat"]:
                path.unlink()
    save("terminal.json", dict(controller=controller, complete=(ROOT / "complete.json").exists()))
