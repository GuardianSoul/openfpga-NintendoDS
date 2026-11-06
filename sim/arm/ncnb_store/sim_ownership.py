"""Identify NDS workers without charging another project's compiler jobs.

Pass the complete local process inventory, keyed by PID. Keep foreign rows
in that inventory so ancestry remains available. Quota enforcement and PID
ownership remain the caller's; the pause helper is only for recorded own PIDs.
"""
from pathlib import Path, PurePosixPath
import shlex
import os
import signal
import time


def project_at(path):
    parts = PurePosixPath(str(path)).parts
    for index, part in enumerate(parts):
        for project in ("NDS_Pocket", "openfpga-PlayStation"):
            if part == project or part.startswith((project + "-", project + "_")):
                return project
        if part == "Git" and index + 1 < len(parts):
            name = parts[index + 1]
            if not name.startswith(("NDS_Pocket", "openfpga-PlayStation")):
                return "foreign"
    return None


def belongs_to_nds(pid, rows):
    """Use the nearest project context, never a shared Verilator include path."""
    visited = set()
    while pid in rows and pid not in visited:
        visited.add(pid)
        row = rows[pid]
        cwd = row.get("cwd")
        if cwd is None:
            try:
                cwd = str(Path("/proc", str(pid), "cwd").resolve(strict=True))
            except OSError:
                cwd = ""
        owner = project_at(cwd)
        if owner is not None:
            return owner == "NDS_Pocket"
        argv = row.get("argv")
        if argv is None:
            try:
                argv = shlex.split(row.get("args", ""))
            except ValueError:
                argv = []
        # Executable and script paths identify a job; -I tool paths do not.
        paths = argv[:1] + [a for a in argv[1:4] if a.endswith((".py", ".sh"))]
        for path in paths:
            owner = project_at(path)
            if owner is not None:
                return owner == "NDS_Pocket"
        pid = int(row.get("ppid", 0))
    return False


def pause_own_worker(pid, capacity_available, poll_seconds=0.1):
    """Pause only a caller-owned PID; resume it without losing simulated state."""
    started = time.monotonic()
    os.kill(pid, signal.SIGSTOP)
    try:
        while not capacity_available():
            time.sleep(poll_seconds)
    finally:
        try:
            os.kill(pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
    return time.monotonic() - started
