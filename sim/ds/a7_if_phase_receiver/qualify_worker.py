"""Sequential, pinned-model qualification; no prior model is rebuilt or rerun."""
import hashlib
import json
import os
from pathlib import Path
import re
import resource
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
    os.replace(temp, path)


def starttime(pid):
    return Path("/proc", str(pid), "stat").read_text().rsplit(")", 1)[1].split()[19]


assert not (ROOT / "controller.json").exists()
controller = dict(pid=os.getpid(), starttime=starttime(os.getpid()),
                  host=os.uname().nodename, NI=10, jobs=1, threads=1)
save("controller.json", controller)
for name, digest in json.loads((ROOT / "inputs.json").read_text()).items():
    assert sha(ROOT / name) == digest, name
model = ROOT / "retained-Vtb"
model_hash = json.loads((ROOT / "model.json").read_text())["sha256"]
base = json.loads((ROOT / "run-inputs.json").read_text())
extensions = ["state", "data", "edge", "full", "pins", "slot", "phase", "csv", "head"]
cases = [
    ("u1", 0, 0, 0x7f, 0x7f, 7092, 1584),
    ("u2", 0, 1, 0x7fff, 0x7fff, 7092, 2352),
    ("u3", 0, 2, 0x7fffff, 0x7fffff, 7092, 3120),
    ("u4", 0, 3, 0x7fffffff, 0x7fffffff, 7860, 3888),
    ("ms", 1, 0, 0x7f, 0x7f, 7092, 1584),
    ("ml", 1, 1, 0x7fffffff, 0x7fffffff, 7860, 3888),
    ("ma", 1, 2, 0x7f, 0x7fffffff, 7476, 2736),
]
result = dict(model=model_hash, main={}, wram={}, adverse={})
main_only = json.loads((ROOT / "configuration.json").read_text()).get("main_only", False)


def command(tag, kind, case, rs, rs6, region, n, scenario=0):
    args = {s.split("=", 1)[0]: s.split("=", 1)[1] for s in base["template"][1:]}
    for name in ["kernel", "wrapper", "boot"]:
        args["+" + name] = str(ROOT / "inputs" / f"{kind}-{name}.hex")
    private = 0x03800640 if kind == 0 else 0x03800740
    wrapper = private + 272
    binary = (ROOT / "inputs" / f"{kind}-wrapper.bin").read_bytes()
    words = [int.from_bytes(binary[i:i+4], "little") for i in range(0, len(binary), 4)]
    ret = wrapper + 4 * (words.index(0xe12fff14) + 1)
    args.update({"+out": str(ROOT / tag), "+phase_out": str(ROOT / (tag + ".csv")),
                 "+kind": str(kind), "+case": str(case), "+rs": format(rs, "x"),
                 "+rs6": format(rs6, "x"), "+region": str(region), "+loops": str(n),
                 "+detail": "1", "+scenario": str(scenario), "+private": format(private, "x"),
                 "+wrapper_entry": format(wrapper, "x"), "+return_pc": format(ret, "x"),
                 "+policy": "1" if region else "0"})
    if scenario == 3:
        args["+boot"] = str(ROOT / "inputs/irq-boot.hex")
        symbols = base["IRQ_symbols"]
        for flag, symbol in [("call", "timed_call"), ("done", "timed_done"),
                             ("sym_rs", "rs_literal"), ("sym_rs6", "rs6_literal"),
                             ("sym_loops", "loops_literal"), ("sym_entry", "entry_literal")]:
            args["+" + flag] = format(symbols[symbol], "x")
    return [str(model), *[k + "=" + v for k, v in args.items()]]


def run(tag, *args, **kwargs):
    assert sha(model) == model_hash
    guard()
    cmd = command(tag, *args, **kwargs)
    log = ROOT / (tag + ".log")
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as stream:
        process = subprocess.Popen(cmd, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        row = dict(pid=process.pid, starttime=starttime(process.pid), tag=tag,
                   controller=controller, command=cmd)
        save("active.json", row)
        print("START", tag, process.pid, flush=True)
        rc = wait_owned(process)
    row.update(exit=rc, reaped=True)
    save(tag + ".process.json", row)
    text = log.read_text()
    assert rc == 0, (tag, rc, text[-3500:])
    for marker in ["PHASE_FUNCTION_PASS errors0", "PAIRED_SLOT_PASS", "ADVERSE_PASS"]:
        assert marker in text, (tag, marker)
    match = re.search(r"MUL_PHASE_PASS[^\n]*elapsed(\d+)", text)
    assert match, tag
    return int(match[1])


def duplicates(tag, reference):
    hashes = {}
    for ext in extensions:
        path = ROOT / (tag + "." + ext)
        previous = ROOT / (reference + "." + ext)
        digest = sha(path)
        assert digest == sha(previous), (tag, ext, "nonrepeatable")
        hashes[ext] = digest
    save(tag + ".capture-hashes.json", dict(reference=reference, literal_equal=True, sha256=hashes))
    for ext in extensions:
        (ROOT / (tag + "." + ext)).unlink()


def architectural(path):
    rows = []
    for line in path.read_text().splitlines():
        parts = line.split(",")
        rows.append("RESET" if parts[0] == "RESET" else ",".join(parts[1:]))
    return rows


try:
    for name, kind, case, rs, rs6, ds, _ in cases:
        rows = []
        for rep in range(1, 5):
            elapsed = {}
            for n in [4, 16]:
                tag = f"main/{name}-r{rep}-n{n}"
                elapsed[str(n)] = run(tag, kind, case, rs, rs6, 1, n)
                duplicates(tag, f"baseline/{name}-n{n}")
            assert elapsed["16"] - elapsed["4"] == 2 * ds, (name, rep, elapsed)
            rows.append(dict(repetition=rep, elapsed=elapsed, DS_exact=True))
            result["main"][name] = rows
            save("results.json", result)
    for name, kind, case, rs, rs6, _, ds in ([] if main_only else cases):
        rows = []
        for rep in range(5):
            elapsed = {}
            for n in [4, 16]:
                tag = f"wram/{name}-r{rep}-n{n}"
                elapsed[str(n)] = run(tag, kind, case, rs, rs6, 0, n)
                if rep:
                    duplicates(tag, f"wram/{name}-r0-n{n}")
            assert elapsed["16"] - elapsed["4"] == 2 * ds, (name, rep, elapsed, ds)
            rows.append(dict(repetition=rep, elapsed=elapsed, DS_exact=True))
            result["wram"][name] = rows
            save("results.json", result)
    for scenario in ([] if main_only else range(1, 6)):
        tag = f"adverse/s{scenario}"
        elapsed = run(tag, 1, 1, 0x7fffffff, 0x7fffffff, 1, 4, scenario=scenario)
        comparisons = {}
        for ext in ["state", "data"]:
            current = architectural(ROOT / (tag + "." + ext))
            previous = architectural(ROOT / f"reference/c1-s{scenario}-p1/{ext}")
            assert current == previous, (scenario, ext, "architectural difference")
            comparisons[ext] = dict(rows=len(current), normalized_equal=True)
        result["adverse"][str(scenario)] = dict(elapsed=elapsed, comparisons=comparisons)
        save("results.json", result)
    save("complete.json", dict(controller=controller, main_total_pairs=35,
                               wram_total_pairs=0 if main_only else 35,
                               main_first7_reused=True, adverse=0 if main_only else 5, status="PASS"))
    print("IF_HEAD_REPEATS_CONTROLS_ADVERSE_PASS", flush=True)
except BaseException:
    save("failure.json", dict(traceback=traceback.format_exc()))
    raise
finally:
    save("terminal.json", dict(controller=controller, complete=(ROOT / "complete.json").exists()))
