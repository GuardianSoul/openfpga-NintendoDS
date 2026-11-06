#!/usr/bin/env python3
"""Print selected signals of an FST/VCD per clock edge (debug aid for sim/ds).

  wave.py FILE.fst 'regex' ['regex' ...] [--rise-only]
Signals are matched against their full hierarchical names; values print in hex.
"""
import re, subprocess, sys

def main():
    path = sys.argv[1]
    pats = [re.compile(p) for p in sys.argv[2:] if not p.startswith('--')]
    if path.endswith('.fst'):
        vcd = subprocess.run(['fst2vcd', path], capture_output=True, text=True).stdout
    else:
        vcd = open(path).read()
    ids, names, scope = {}, [], []
    lines = vcd.splitlines()
    i = 0
    while i < len(lines):
        l = lines[i].split()
        if not l: i += 1; continue
        if l[0] == '$scope': scope.append(l[2])
        elif l[0] == '$upscope': scope.pop()
        elif l[0] == '$var':
            name = '.'.join(scope + [l[4]])
            if any(p.search(name) for p in pats):
                ids.setdefault(l[3], []).append(name)
                if name not in names: names.append(name)
        elif l[0] == '$enddefinitions': i += 1; break
        i += 1
    val = {n: 'x' for n in names}
    t = None
    last = [None]
    def show():
        if t is not None and t % 2 == 0:
            s = ' '.join(f'{n.split(".")[-1]}={val[n]}' for n in names)
            if s != last[0]:
                print(f'{t//2:>9} ' + s)
                last[0] = s
    for l in lines[i:]:
        if not l: continue
        if l[0] == '#':
            show(); t = int(l[1:]); continue
        if l[0] in 'bBrR':
            v, k = l[1:].split()
            if k in ids:
                try: s = '%x' % int(v, 2)
                except ValueError: s = v
                for n in ids[k]: val[n] = s
        elif l[0] in '01xzXZ':
            k = l[1:]
            if k in ids:
                for n in ids[k]: val[n] = l[0]
    show()

if __name__ == '__main__':
    main()
