#!/usr/bin/env python3
"""Reuse the qualified paired25DENSE/26tb_arm driver against this exact parent.

The WRAM native proof is separate: this broad fixture exercises the unchanged
CPU leaves, not the packed backend. No baseline timings are remeasured.
"""
from pathlib import Path
import subprocess

R=Path(__file__).resolve().parents[3]
parent='1b16d2c09715da8189317d9bbf9c0a071af5ef1f'
for name in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu arm7_ds'.split():
    f='rtl/arm/'+name+'.sv'
    before=subprocess.check_output(['git','show',parent+':'+f],cwd=R)
    assert (R/f).read_bytes()==before,('CPU leaf changed',f)
driver=R/'sim/arm/a7_if_commit/run_cpu.py'
source=driver.read_text()
assert source.count("base='de6039a5'")==1
source=source.replace("base='de6039a5'","base='"+parent+"'")
exec(compile(source,str(driver),'exec'),dict(__file__=str(driver),__name__='__main__'))
