"""Run only the missing observable window; require unchanged prior captures."""
import hashlib
import json
import os
from pathlib import Path
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
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, indent=2) + "\n")
    temp.replace(path)


def start(pid):
    return Path("/proc", str(pid), "stat").read_text().rsplit(")", 1)[1].split()[19]


assert not (ROOT / "controller.json").exists()
controller = dict(pid=os.getpid(), starttime=start(os.getpid()), host=os.uname().nodename,
                  NI=10, jobs=1, threads=1)
save("controller.json", controller)
try:
    for name, digest in json.loads((ROOT / "inputs.json").read_text()).items():
        assert sha(ROOT / name) == digest, name
    guard()
    command = json.loads((ROOT / "command.json").read_text())
    with (ROOT / "observed.log").open("w") as stream:
        child = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        row = dict(pid=child.pid, starttime=start(child.pid), controller=controller, command=command)
        save("active.json", row)
        print("N/S_PASSIVE_WINDOW", child.pid, flush=True)
        rc = wait_owned(child)
    row.update(exit=rc, reaped=True)
    save("observed.process.json", row)
    assert rc == 0, (ROOT / "observed.log").read_text()[-3000:]
    captures = {}
    for mode in [0, 1]:
        for ext in ["csv", "data", "fcomp"]:
            name = f"observed-m{mode}.{ext}"
            assert (ROOT / name).read_bytes() == (ROOT / f"previous-n16-m{mode}.{ext}").read_bytes()
            captures[name] = sha(ROOT / name)
    counts = lambda text: [line for line in text.splitlines() if line.startswith("PHYS_PASS")]
    assert counts((ROOT / "observed.log").read_text()) == counts((ROOT / "previous-n16.log").read_text())
    save("complete.json", dict(controller=controller, status="PASS passive exact prior sixcaptures/counts",
                               captures=captures, journals=[sha(ROOT / f"events-m{m}.csv") for m in [0, 1]]))
    print("N/S_PASSIVE_WINDOW_EXACT", flush=True)
except BaseException:
    save("failure.json", dict(traceback=traceback.format_exc()))
    raise
finally:
    save("terminal.json", dict(controller=controller, complete=(ROOT / "complete.json").exists()))
