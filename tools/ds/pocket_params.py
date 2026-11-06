#!/usr/bin/env python3
"""The nds_top parameters of the Pocket build (rtl/pocket/core_top_ds.sv), as
make variables for sim/ds/ds.mk, one per line (make test-ds-pocket):

    tools/ds/pocket_params.py [NAME=VALUE ...]

NAME=VALUE overrides a core_top_ds parameter first (GPU3D=0: the 3D-off
build). core_top_ds's defaults are evaluated, then the parameter map of its
nds_top instance, so tb_ds runs exactly the set a fit of this tree puts on the
Pocket (a combination that reached hardware untested: compat.md, #495)."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = (ROOT / 'rtl/pocket/core_top_ds.sv').read_text()
TOP = (ROOT / 'rtl/ds/nds_top.sv').read_text()


def strip_comments(s):
    return re.sub(r'//[^\n]*', '', re.sub(r'/\*.*?\*/', '', s, flags=re.S))


def split_top(s, sep):
    """s split at sep outside parentheses."""
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == sep and depth == 0:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    out.append(cur)
    return out


def ev(e, env):
    """A SystemVerilog constant expression: numbers, names, ?:, comparisons, && || !."""
    e = e.strip()
    depth = 0
    for i, ch in enumerate(e):              # the first top-level ?: (right-associative)
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        elif ch == '?' and depth == 0:
            rest, d, j = e[i + 1:], 0, 0
            for j, c2 in enumerate(rest):
                if c2 in '([':
                    d += 1
                elif c2 in ')]':
                    d -= 1
                elif c2 == '?' and d == 0:
                    d += 100                # a nested ?: in the true branch
                elif c2 == ':' and d == 0:
                    break
                elif c2 == ':' and d >= 100:
                    d -= 100
            return ev(rest[:j], env) if ev(e[:i], env) else ev(rest[j + 1:], env)
    py = re.sub(r"\d*'[sS]?([bdhBDH])([0-9a-fA-F_]+)",
                lambda m: str(int(m.group(2).replace('_', ''), {'b': 2, 'd': 10, 'h': 16}[m.group(1).lower()])), e)
    py = py.replace('&&', ' and ').replace('||', ' or ')
    py = re.sub(r'!(?!=)', ' not ', py)
    return int(eval(py, {}, dict(env)))


def params(text, module):
    """Parameter defaults of the module's header, in order."""
    t = strip_comments(text)
    m = re.search(r'module\s+' + module + r'\b[^#]*#\s*\((.*?)\)\s*\(', t, re.S)
    out = []
    for item in split_top(m.group(1), ','):
        p = re.match(r'\s*parameter\s+(?:[\w\[\]:\s]*?\s)?(\w+)\s*=\s*(.+)', item, re.S)
        if p:
            out.append((p.group(1), p.group(2).strip()))
    return out


def main():
    over = dict(a.split('=', 1) for a in sys.argv[1:])
    env = {}
    for name, expr in params(SRC, 'core_top'):
        if name in over:
            expr = over.pop(name)
        if expr.startswith('"'):
            continue
        try:
            env[name] = ev(expr, env)
        except Exception:
            pass                            # not a number (unused here)
    if over:
        sys.exit(f'pocket_params: no core_top_ds parameter {", ".join(over)}')
    t = strip_comments(SRC)
    m = re.search(r'nds_top\s*#\s*\((.*?)\)\s*ds\s*\(', t, re.S)
    top = {n for n, _ in params(TOP, 'nds_top')}
    sets = {}
    for item in split_top(m.group(1), ','):
        p = re.match(r'\s*\.(\w+)\s*\((.*)\)\s*$', item, re.S)
        if not p or p.group(2).strip().startswith('"'):
            continue
        name = p.group(1)
        if name not in top:
            sys.exit(f'pocket_params: nds_top has no parameter {name}')
        sets[name] = ev(p.group(2), env)
    # ds.mk's own knobs for the parameters it always passes; the rest by -G
    knob = {'SOUND': 'DS_SOUND', 'GPU3D': 'DS_3D', 'CPU_FAST': 'DS_FAST', 'ARM7_CACHE': 'DS_A7C', 'GX_USORT': 'DS_USORT'}
    lines = [f'{knob[n]}={v}' for n, v in sets.items() if n in knob]
    g = ' '.join(f'-G{n}={v}' for n, v in sets.items() if n not in knob)
    lines.append('DS_G=' + g)
    lines.append('DS_B=build/ds-pocket' + ('-3d' if sets.get('GPU3D') else '-2d'))
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
