#!/usr/bin/env python3
"""sim/space_gxdict/mutate.py shift|word OUT.sv: a mutant of rtl/gpu3d/gpu3d_gxrom_uf.sv's gpu3d_gxrom_ufd
(docs/space-gxdict.md): shift = the index ROM shifted by one entry (rs[p] takes rs[p + 1]); word = one
dictionary word corrupted (bit 5 of the A dictionary word of pc 0x57, NOENT, the idle DISP)."""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
kind, out = sys.argv[1], Path(sys.argv[2])
text = (ROOT / 'rtl/gpu3d/gpu3d_gxrom_uf.sv').read_text()
old, new = text.split('\nmodule gpu3d_gxrom_ufd')
rs = {int(i): (w, v) for i, w, v in re.findall(r"rs\[(\d+)\] = (\d+)'h([0-9a-f]+);", new)}
if kind == 'shift':
    new = re.sub(r"rs\[(\d+)\] = (\d+)'h([0-9a-f]+);",
                 lambda m: f"rs[{m.group(1)}] = {m.group(2)}'h{rs[(int(m.group(1)) + 1) % 2048][1]};", new)
elif kind == 'word':
    i0 = int(re.search(r"q0 (\d+) at 0", new).group(1))
    k = int(rs[0x56][1], 16) & ((1 << i0) - 1)
    m = re.search(rf"rd0\[{k}\] = (\d+)'h([0-9a-f]+);", new)
    v = int(m.group(2), 16) ^ (1 << 5)
    new = new.replace(m.group(0), f"rd0[{k}] = {m.group(1)}'h{v:0{len(m.group(2))}x};")
    print('group 0 dictionary word', k, 'bit 5 flipped')
else:
    sys.exit('shift|word')
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(old + '\nmodule gpu3d_gxrom_ufd' + new)
