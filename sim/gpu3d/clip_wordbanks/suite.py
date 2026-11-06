#!/usr/bin/env python3
"""Run the three affected checks sequentially in one allocated worker slot."""
import os
from pathlib import Path
import subprocess
import sys

os.setpriority(os.PRIO_PROCESS,0,10)
root=Path(sys.argv[1]).resolve()
print(f'suite_pid={os.getpid()} nice=10 jobs=1 threads=1',flush=True)
for name,red,fault in [('positive-red1',1,False),('positive-red0',0,False),('mutant-red1',1,True)]:
    cmd=[sys.executable,str(Path(__file__).with_name('check.py')),'--out',str(root/name),'--red',str(red)]
    if fault:cmd.append('--mutant')
    print(f'CHECK {name}',flush=True)
    subprocess.run(cmd,check=True)
print('SUITE_PASS',flush=True)
