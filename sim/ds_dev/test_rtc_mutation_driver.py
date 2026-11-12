#!/usr/bin/env python3
"""Exercise mutation verdicts under normal Python, -O and PYTHONOPTIMIZE=1.
Fake compiler/executables isolate driver acceptance, not RTC functionality.
The separate real-Verilator campaign supplies the functional witnesses.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
driver = (root / 'sim/ds_dev/rtc_behavior_mutate.py').read_text()
rtl = (root / 'rtl/ds/nds_rtc.sv').read_text()
fake = '''#!/usr/bin/env python3
import os, pathlib, sys
out = pathlib.Path(sys.argv[sys.argv.index('--Mdir') + 1]); out.mkdir(parents=True, exist_ok=True)
base = out.parent.name == 'baseline'; scenario = os.environ['RTC_DRIVER_SCENARIO']
rc = 0 if base else 1
text = 'PASS: baseline' if base else 'FAIL [rtc-exhaust] functional witness'
if scenario == 'baseline-fail' and base: rc, text = 1, 'FAIL [rtc-exhaust] bad baseline'
if scenario == 'survivor' and not base: rc, text = 0, 'PASS: surviving mutant'
if scenario == 'crash' and not base: rc, text = 2, 'generic execution error'
p = out / 'Vtb_ds_dev'
p.write_text('#!/usr/bin/env python3\\nprint(' + repr(text) + ')\\nraise SystemExit(' + str(rc) + ')\\n')
p.chmod(0o755)
'''
with tempfile.TemporaryDirectory(prefix='rtc-driver-') as tmp:
    work = Path(tmp)
    (work / 'sim/ds_dev').mkdir(parents=True)
    (work / 'rtl/ds').mkdir(parents=True)
    script = work / 'sim/ds_dev/rtc_behavior_mutate.py'; script.write_text(driver)
    compiler = work / 'fake-verilator'; compiler.write_text(fake); compiler.chmod(0o755)
    for mode in ('normal', 'dash-O', 'env-optimize'):
        for scenario in ('caught', 'baseline-fail', 'survivor', 'crash', 'stale'):
            source = rtl.replace('if (!mode24 && v[6])', 'if (!mode24 && (v[6]))') if scenario == 'stale' else rtl
            (work / 'rtl/ds/nds_rtc.sv').write_text(source)
            env = dict(os.environ, RTC_DRIVER_SCENARIO=scenario)
            env.pop('PYTHONOPTIMIZE', None)
            if mode == 'env-optimize': env['PYTHONOPTIMIZE'] = '1'
            cmd = [sys.executable] + (['-O'] if mode == 'dash-O' else [])
            cmd += [str(script), '--verilator', str(compiler), '--out', str(work / 'output')]
            result = subprocess.run(cmd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            expected = 0 if scenario == 'caught' else 1
            if result.returncode != expected:
                raise SystemExit(f'{mode}/{scenario}: wrong status {result.returncode}: {result.stdout}')
            if scenario == 'caught' and result.stdout.count(': CAUGHT ') != 8:
                raise SystemExit('missing genuine catches: ' + result.stdout)
            if scenario in ('survivor', 'crash', 'baseline-fail') and ': CAUGHT ' in result.stdout:
                raise SystemExit('false catch: ' + result.stdout)
            if scenario == 'stale' and 'must match exactly once' not in result.stdout:
                raise SystemExit('stale edit not rejected: ' + result.stdout)
            print(f'PASS {mode}/{scenario}', flush=True)
print('PASS 15 driver acceptance scenarios')
