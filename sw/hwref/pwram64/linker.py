#!/usr/bin/env python3
"""Shared code/data and temporary stack; retain BIOS/private startup stacks."""
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
a='wram    : ORIGIN = 0x37f8000, LENGTH = 0x17000'
b='__sys_start  = ORIGIN(wram) + LENGTH(wram)'
assert s.count(a)==1 and s.count(b)==1,'SDK layout changed'
s=s.replace(a,'wram    : ORIGIN = 0x37f8000, LENGTH = 0x8000').replace(b,'__sys_start  = 0x0380f000')
s+='\nASSERT(__wram_bss_end <= 0x03800000, "probe shared WRAM overflow")\n'
Path(sys.argv[2]).write_text(s)
