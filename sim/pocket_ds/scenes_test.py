#!/usr/bin/env python3
"""scenes.py's verdicts for scenes that didn't run (no Verilator, no ROMs).

    sim/pocket_ds/scenes_test.py

A scene whose import (state_import) or run.py fails measured nothing: it
must print ERROR, never KNOWN, and the sweep must exit non-zero, even when
scenes.txt marks the scene known (2026-11-07: a Laptop run without the
exports printed KNOWN for gsdd-title and kh-heavy and an overall PASS).
"""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scenes  # noqa: E402

ROW = dict(name='t-known', rom='none.nds', state='none.mst', frames=8, top=0, bottom=0, known=True)


def sweep(fail_prepare, rc=0, no_run=False):
    """main() over one known scene; returns (exit code, output)."""
    def prepare(s, d):
        if fail_prepare:
            raise subprocess.CalledProcessError(1, ['state_import.py', str(d / 'exp')])

    real_run = subprocess.run

    def run(cmd, *a, **k):
        if cmd[:2] == ['make', '-s']:
            return subprocess.CompletedProcess(cmd, 0)
        if any(str(c).endswith('run.py') for c in cmd):
            return subprocess.CompletedProcess(cmd, rc)
        return real_run(cmd, *a, **k)

    saved = scenes.ROOT, scenes.read_table, scenes.prepare, scenes.subprocess.run, sys.argv
    with tempfile.TemporaryDirectory() as tmp:
        scenes.ROOT = Path(tmp)
        scenes.read_table = lambda: [dict(ROW)]
        scenes.prepare = prepare
        scenes.subprocess.run = run
        sys.argv = ['scenes.py', '--jobs', '1'] + (['--no-run'] if no_run else [])
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out):
                scenes.main()
            code = 0
        except SystemExit as e:
            code = e.code
        finally:
            scenes.ROOT, scenes.read_table, scenes.prepare, scenes.subprocess.run, sys.argv = saved
    return code, out.getvalue()


def main():
    os.environ['NDS_DISK_GUARD_OFF'] = '1'
    bad = 0
    for what, kw in (('import fails', dict(fail_prepare=True)),
                     ('run.py exits 1', dict(fail_prepare=False, rc=1)),
                     ('--no-run without a run log', dict(fail_prepare=False, no_run=True))):
        code, out = sweep(**kw)
        line = next((l for l in out.splitlines() if l.startswith('t-known')), '')
        ok = ' ERROR ' in line and 'KNOWN' not in line and code not in (0, None) and out.rstrip().endswith('FAIL')
        print(f'{"ok  " if ok else "BAD "} {what}: exit {code}: {line[:120]}')
        bad += not ok
    print('PASS' if not bad else 'FAIL')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
