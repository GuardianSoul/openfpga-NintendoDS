#!/usr/bin/env python3
"""Constrain calico's ARM7 code/data to private WRAM for ownership probes."""
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
pattern = r'(\bwram\s*:\s*ORIGIN\s*=\s*)0x37f8000(,\s*LENGTH\s*=\s*)0x17000'
source, count = re.subn(pattern, r'\g<1>0x3800000\g<2>0x0f000', source)
if count != 1:
    raise SystemExit('unexpected calico ds7.ld layout; inspect before linking')
Path(sys.argv[2]).write_text('/* wramarb: private WRAM only; generated from calico ds7.ld */\n'+source)
