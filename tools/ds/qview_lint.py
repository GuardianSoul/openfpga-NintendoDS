#!/usr/bin/env python3
"""Lint the core as Quartus reads it: Verilator over the fit's file list with
ALTERA_RESERVED_QIS and SYNTHESIS defined, so `ifndef`-hidden simulation code
drops out exactly as in synthesis.

    tools/ds/qview_lint.py QSF [--top core_top] [--baseline FILE] [--update]

QSF is a fit's apf_top.qsf (every nds-fit artifact has one; the file list
changes rarely, so the last fit's QSF serves a new commit). Paths are mapped
onto this checkout's rtl/. Quartus primitives (altsyncram, cyclonev_mac, altddio_out, altera_pll) get
port-shaped stubs with driven outputs.

Why (2026-11-05): 484d0829 put the eviction buffer's only write inside the
simulation-only block. Simulation and every scene gate passed, while on the
chip nothing booted (NDSPlay4/5/6). This lint reports "Signal is not driven:
'ev_d'" for that source.

Reports UNDRIVEN, MULTIDRIVEN, LATCH, COMBDLY and BLKANDNBLK warnings, and
fails on any not in the baseline (default tools/ds/qview_lint.baseline, one
"CODE file:signal" per line). --update rewrites the baseline from this run.
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERILATOR = Path.cwd() / 'build/tools/oss-cad-suite/bin/verilator'
CODES = ('UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'COMBDLY', 'BLKANDNBLK')
PRIMS = {'altsyncram': {'q_a', 'q_b', 'eccstatus'},
         'cyclonev_mac': {'resulta', 'resultb', 'chainout', 'scanouty'},
         'altddio_out': {'dataout', 'oe_out'},
         'altera_pll': {'outclk', 'locked', 'fboutclk', 'phout', 'lvds_clk', 'loaden', 'extclk_out', 'cascade_out'}}


def sources(qsf, root):
    files = []
    for line in qsf.read_text().splitlines():
        m = re.match(r'\s*set_global_assignment\s+-name\s+(SYSTEMVERILOG|VERILOG)_FILE\s+"?([^"]+?)"?\s*$', line)
        if not m:
            continue
        p = m[2]
        i = p.find('rtl/')
        if i < 0:
            continue
        f = root / p[i:]
        if f.suffix in ('.sv', '.v') and f.exists() and f not in files:  # the QSF lists some files twice
            files.append(f)
    return files


def stubs(files):
    """Port-shaped stubs for the Quartus primitives the RTL instantiates."""
    text = '\n'.join(f.read_text(errors='replace') for f in files)
    text = re.sub(r'/\*.*?\*/|//[^\n]*', ' ', text, flags=re.S)

    def group(i):
        """The balanced (...) starting at text[i] == '(': its inside and the index after it."""
        depth = 0
        for j in range(i, len(text)):
            depth += {'(': 1, ')': -1}.get(text[j], 0)
            if depth == 0:
                return text[i + 1:j], j + 1
        return '', len(text)

    out = ['/* verilator lint_off */']
    for name, outs in PRIMS.items():
        params, ports, insts = set(), set(), set()
        for m in re.finditer(r'\b%s\b\s*(#\s*)?' % name, text):
            i = m.end()
            if m[1]:
                inside, i = group(i)
                params |= set(re.findall(r'\.(\w+)\s*\(', inside))
            n = re.match(r'\s*(\w+)\s*(\[[^\]]*\]\s*)?\(', text[i:])
            if not n:
                continue
            insts.add(n[1])
            inside, _ = group(i + n.end() - 1)
            ports |= set(re.findall(r'\.(\w+)\s*\(', inside))
        for inst in insts:
            params |= set(re.findall(r'\bdefparam\s+%s\.(\w+)' % re.escape(inst), text))
            params |= set(re.findall(r'\b%s\.(\w+)\s*=' % re.escape(inst), text))
        if not ports:
            continue
        plist = ', '.join(f'parameter {p} = 0' for p in sorted(params))
        decl = [f'output logic [143:0] {p}' if p in outs else f'input wire [143:0] {p}' for p in sorted(ports)]
        out.append(f'module {name} #({plist}) ({", ".join(decl)});')
        out += [f'  assign {p} = 0;' for p in sorted(ports) if p in outs]
        out.append('endmodule')
    out.append('/* verilator lint_on */')
    return '\n'.join(out) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('qsf', type=Path)
    ap.add_argument('--top', default='core_top')
    ap.add_argument('--root', type=Path, default=ROOT, help='the source tree to lint (default: this checkout)')
    ap.add_argument('--baseline', type=Path, default=ROOT / 'tools/ds/qview_lint.baseline')
    ap.add_argument('--update', action='store_true')
    a = ap.parse_args()
    files = sources(a.qsf, a.root.resolve())
    if not files:
        sys.exit(f'{a.qsf}: no rtl/ sources found')
    incs = sorted({f'-I{f.parent}' for f in files})
    with tempfile.TemporaryDirectory() as d:
        stub = Path(d) / 'qview_stubs.sv'
        stub.write_text(stubs(sorted((a.root / 'rtl').rglob('*.[sv]*'))))
        cmd = [str(VERILATOR), '--lint-only', '-Wall', '-Wno-fatal', '-DALTERA_RESERVED_QIS', '-DSYNTHESIS',
               '--top-module', a.top, *incs, str(stub), *map(str, files)]
        r = subprocess.run(cmd, capture_output=True, text=True)
    log = r.stdout + r.stderr
    errors = [l for l in log.splitlines() if l.startswith('%Error')]
    if errors:
        print('\n'.join(errors[:20]))
        sys.exit('qview_lint: Verilator errors (above)')
    found = set()
    for m in re.finditer(r"%Warning-(\w+): ([^:]+):\d+:\d+: .*?'([^']+)'", log):
        if m[1] in CODES:
            sig = re.sub(r'unnamedblk\d+', 'unnamedblk', m[3])  # Verilator renumbers these between versions
            found.add(f'{m[1]} {Path(m[2]).name}:{sig}')
    if a.update:
        a.baseline.write_text(''.join(f'{w}\n' for w in sorted(found)))
        print(f'qview_lint: baseline {a.baseline} rewritten, {len(found)} entries')
        return
    base = set(a.baseline.read_text().split('\n')) if a.baseline.exists() else set()
    new = sorted(found - base)
    for w in new:
        print('NEW', w)
    print(f'qview_lint: {len(found)} findings, {len(new)} not in the baseline')
    sys.exit(1 if new else 0)


if __name__ == '__main__':
    main()
