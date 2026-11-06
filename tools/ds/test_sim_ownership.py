"""Regression for the PSX GPU-probe burst that aborted NDS simulations."""
from pathlib import Path
import sim_ownership as scope
import subprocess
import sys
import tempfile
import time


def check(classify):
    app = {1: {"ppid": 0, "cwd": "/home/user/Git/NDS_Pocket", "argv": ["codex"]}}
    cases = [
        ({2: {"ppid": 1, "cwd": "/home/user/Git/NDS_Pocket-codex/build/obj", "args": "cc1plus -I build/tools/verilator/include"}}, True),
        ({2: {"ppid": 1, "cwd": "/home/user/Git/openfpga-PlayStation/build/sim/gpu-probe", "argv": ["cc1plus"]}}, False),
        ({2: {"ppid": 1, "cwd": "/home/user/Git/Other_Project/build", "argv": ["cc1plus"]}}, False),
        ({2: {"ppid": 1, "cwd": "/tmp/rnd", "argv": ["python3", "-u", "/home/user/Git/NDS_Pocket/rnd/gen.py"]}, 3: {"ppid": 2, "cwd": "/tmp/rnd", "argv": ["cc1plus"]}}, True),
        ({2: {"ppid": 0, "cwd": "/tmp", "argv": ["/home/user/Git/openfpga-PlayStation/build/Vtb_gpu_probe"]}}, False),
        ({2: {"ppid": 0, "cwd": "/home/user/.codex/worktrees/a1/NDS_Pocket/build", "argv": ["Vtb"]}}, True),
        ({2: {"ppid": 0, "cwd": "/tmp", "argv": ["cc1plus"]}}, False),
        ({2: {"ppid": 2, "cwd": "/tmp", "argv": ["cc1plus"]}}, False),
    ]
    for extra, expected in cases:
        rows = app | extra
        pid = max(extra)
        assert classify(pid, rows) is expected, (pid, rows, expected)


check(scope.belongs_to_nds)
source = Path(scope.__file__).read_text()
old = 'if owner is not None:\n            return owner == "NDS_Pocket"'
assert source.count(old) == 1
mutant = source.replace(old, 'if owner == "NDS_Pocket":\n            return True')
namespace = {}
exec(compile(mutant, "foreign-boundary-mutant", "exec"), namespace)
try:
    check(namespace["belongs_to_nds"])
except AssertionError:
    print("PASS: eight ownership cases; foreign-boundary mutant caught")
else:
    raise AssertionError("foreign-boundary mutant escaped")


def check_pause(pause):
    with tempfile.TemporaryDirectory(prefix="nds-scope-test-") as directory:
        output = Path(directory) / "counter.txt"
        program = "import sys,time\nwith open(sys.argv[1],'w',buffering=1) as f:\n for i in range(100):\n  f.write(str(i)+'\\n');time.sleep(.003)\n"
        child = subprocess.Popen([sys.executable, "-c", program, str(output)])
        try:
            deadline = time.monotonic() + 5
            while (not output.exists() or len(output.read_text().splitlines()) < 3):
                assert time.monotonic() < deadline
                time.sleep(.005)
            count = None
            until = time.monotonic() + .08

            def available():
                nonlocal count
                current = output.read_text()
                if count is None:
                    count = current
                assert current == count, "worker advanced while supposedly paused"
                return time.monotonic() >= until

            pause(child.pid, available, .01)
            assert child.wait(timeout=5) == 0
            assert output.read_text().splitlines() == [str(i) for i in range(100)]
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()


check_pause(scope.pause_own_worker)
namespace = {}
mutant = Path(scope.__file__).read_text().replace("os.kill(pid, signal.SIGSTOP)", "pass  # missing-pause mutant")
exec(compile(mutant, "missing-pause-mutant", "exec"), namespace)
try:
    check_pause(namespace["pause_own_worker"])
except AssertionError:
    print("PASS: paused counter stayed fixed and resumed exactly; missing-pause mutant caught")
else:
    raise AssertionError("missing-pause mutant escaped")
