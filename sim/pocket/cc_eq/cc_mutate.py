#!/usr/bin/env python3
"""Planted bugs that cc_eq.sh must catch (firmware and nds_cart_scpu).   cc_mutate.py [seeds] [ops]"""
import subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
MUTANTS = [
    ('sw/scpu/cache.c', 'if (run_n++ == ext) break;', 'if (++run_n == ext) break;'),           # read-ahead run one short
    ('sw/scpu/cache.c', 'if (ref_get(h)) { ref_set(h, 0); continue; }', 'if (ref_get(h)) continue;'),   # CLOCK keeps the bit
    ('sw/scpu/cache.c', 't[0] = 0; t[1] = 0; t[2] = 0;', 't[0] = 0; t[1] = 0; t[2] = 0; t[3] = 0;'),  # eviction clears read-ahead
    ('rtl/pocket/nds_cart_scpu.sv', '((pf_due && !pf_fly) || (pf_fly && mk_v))', '(pf_fly && mk_v)'),  # no hold for a due prefetch
    ('sw/scpu/cache.c', 'IO(7) = run_slot[0];', 'IO(6) = C_MISS;'),                                     # a demand miss looked up again
]
seeds = sys.argv[1] if len(sys.argv) > 1 else '24'
ops = sys.argv[2] if len(sys.argv) > 2 else '30000'
missed = 0
for f, old, new in MUTANTS:
    p = ROOT / f; s = p.read_text()
    assert s.count(old) == 1, old
    p.write_text(s.replace(old, new))
    try:
        r = subprocess.run(['bash', str(ROOT / 'sim/pocket/cc_eq/cc_eq.sh'), seeds, ops], capture_output=True, text=True)
    finally:
        p.write_text(s)
    caught = r.returncode != 0
    missed += not caught
    print(('caught' if caught else 'MISSED'), f, new[:60], (r.stdout.strip().splitlines() or [''])[-1])
subprocess.run(['make', '-s', '-C', str(ROOT), 'build/scpu/cache.bin'], check=True)
print(f'{len(MUTANTS) - missed} of {len(MUTANTS)} caught')
sys.exit(1 if missed else 0)
