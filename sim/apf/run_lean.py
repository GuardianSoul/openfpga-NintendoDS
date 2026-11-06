#!/usr/bin/env python3
"""The lean APF command handler against the template (docs/phase1-foundation.md, "APF shell trim").

    sim/apf/run_lean.py [--seeds 6] [--cycles 1000000]

Regenerates rtl/apf/core_bridge_cmd_lean.v and checks it is the committed
copy, runs sim/apf/tb_bridge_cmd_lean.sv (template and lean copy in lockstep,
every output every clock) for each seed, then the planted faults, which
must each fail.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
LEAN = ROOT / 'rtl/apf/core_bridge_cmd_lean.v'
# (name, original, planted fault) in the lean copy
MUTANTS = [
    ('0x2C reads the offset', "8'h2C: bridge_rd_data_out <= target_dataslot_length;",
     "8'h2C: bridge_rd_data_out <= target_dataslot_slotoffset;"),
    ('openfile reports the response struct', "t_kind <= 2'd3;", "t_kind <= 2'd2;"),
    ('request id from the wrong word', "assign dataslot_requestread_id = host_20[15:0];",
     "assign dataslot_requestread_id = host_24[15:0];"),
]


def run(lean, out, seeds, cycles):
    out.mkdir(parents=True, exist_ok=True)
    cmd = [str(TOOLS / 'verilator'), '--binary', '-O3', '-j', '8', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC',
           '-Wno-UNUSEDSIGNAL', '--top-module', 'tb_bridge_cmd_lean', '--Mdir', str(out),
           str(ROOT / 'rtl/apf/core_bridge_cmd.v'), str(lean), str(ROOT / 'rtl/apf/common.v'),
           str(ROOT / 'sim/probe/mf_datatable_model.sv'), str(ROOT / 'sim/apf/tb_bridge_cmd_lean.sv')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout[-2000:] + r.stderr[-2000:])
    lines = []
    for s in range(1, seeds + 1):
        r = subprocess.run([str(out / 'Vtb_bridge_cmd_lean'), f'+seed={s}', f'+cycles={cycles}'], capture_output=True, text=True)
        res = [l for l in r.stdout.splitlines() if l.startswith(('cycles', 'PASS', 'FAIL', 'MISMATCH'))]
        lines.append((s, res))
        if 'PASS' not in res:
            return False, lines
    return True, lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seeds', type=int, default=6)
    ap.add_argument('--cycles', type=int, default=1000000)
    a = ap.parse_args()
    before = LEAN.read_text()
    subprocess.run([sys.executable, str(ROOT / 'tools/apf/bridge_cmd_lean.py')], check=True, capture_output=True)
    if LEAN.read_text() != before:
        sys.exit('rtl/apf/core_bridge_cmd_lean.v was stale (now regenerated): commit it')
    ok, lines = run(LEAN, ROOT / 'build/apf/lean', a.seeds, a.cycles)
    for s, res in lines:
        print(f'seed {s}: ' + ' | '.join(res))
    if not ok:
        sys.exit('FAIL: the lean copy differs from the template')
    caught = 0
    for i, (name, old, new) in enumerate(MUTANTS):
        text = LEAN.read_text()
        if text.count(old) != 1:
            sys.exit(f'mutant anchor not found: {old}')
        d = ROOT / f'build/apf/mut{i}'
        d.mkdir(parents=True, exist_ok=True)
        (d / 'core_bridge_cmd_lean.v').write_text(text.replace(old, new))
        mok, _ = run(d / 'core_bridge_cmd_lean.v', d / 'obj', 2, a.cycles // 4)
        print(f"mutant '{name}': " + ('MISSED' if mok else 'caught'))
        caught += not mok
    if caught != len(MUTANTS):
        sys.exit(f'FAIL: {len(MUTANTS) - caught} mutants missed')
    print(f'PASS: {a.seeds} seeds, {len(MUTANTS)} mutants caught')


if __name__ == '__main__':
    main()
