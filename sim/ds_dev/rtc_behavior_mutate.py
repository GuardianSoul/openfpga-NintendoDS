#!/usr/bin/env python3
"""RTC behavior fault controls; baseline must pass this isolated gate first.

Uses --only rtc-exhaust so preexisting firmware/high-byte failures cannot make
an unrelated mutant look detected. Build errors/timeouts are errors, not catches.
Full build and run logs are retained per fault. No firmware image is required.
"""
import argparse
import pathlib
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--verilator', default='verilator')
p.add_argument('--out', default='build/rtc-behavior-mutations')
p.add_argument('--self-test-survivor', action='store_true',
               help='run baseline then a harmless edit; must exit nonzero as NOT CAUGHT')
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[2]
out = pathlib.Path(a.out).resolve()
out.mkdir(parents=True, exist_ok=True)
source = (root / 'rtl/ds/nds_rtc.sv').read_text()
mutations = {
    'baseline': None,
    'bad-digit-accepted': ("v[3:0] > 4'd9 || v[7:4] > 4'd9 || ", ''),
    'day-carry-lost': ('wire day_carry = day_in > dim(mo, leap(yr));', "wire day_carry = 1'b0;"),
    'pm-write-lost': ('if (!mode24 && v[6])', "if (1'b0)"),
    'mode-read-ignored': ('s1[1] ? hr : hour12(hr)', 'hr'),
    'decimal-hour-carry-lost': ("h[3:0] >= 4'd8 ? 8'h18 : 8'h12", "8'h12"),
    'leap-year-broken': ("y[3:0] == 4'h4 ||", "y[3:0] == 4'h5 ||"),
    'century-wrap-broken': ("v[7:4] == 4'h9 ? 4'h0", "v[7:4] == 4'h9 ? 4'h1"),
    'count-through-cs': ('wire k_rel = pend && !io[2];', 'wire k_rel = pend;'),
}
if a.self_test_survivor:
    mutations = {'baseline': None, 'deliberate-survivor':
                 ('// ---- state', '// ---- state (deliberate equivalent control)')}


def require(condition, message):
    # These are acceptance checks, never Python asserts: -O must retain them.
    if not condition:
        raise SystemExit(message)


for name, edit in mutations.items():
    work = out / name
    work.mkdir(exist_ok=True)
    rtl = source
    if edit:
        old, new = edit
        require(rtl.count(old) == 1, name + ': mutation must match exactly once')
        rtl = rtl.replace(old, new)
    path = work / 'nds_rtc.sv'
    path.write_text(rtl)
    cmd = [a.verilator, '--cc', '--exe', '--build', '-j', '4', '-O2',
           '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL',
           '--top-module', 'tb_ds_dev', '--Mdir', str(work / 'obj'),
           '-CFLAGS', '-std=c++20 -O2', str(root / 'rtl/ds/nds_dsp_add.sv'),
           str(root / 'rtl/ds/nds_spi.sv'), str(path),
           str(root / 'sim/ds_dev/tb_ds_dev.sv'), str(root / 'sim/ds_dev/tb_ds_dev.cpp')]
    with (work / 'build.log').open('w') as log:
        subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    with (work / 'run.log').open('w') as log:
        result = subprocess.run([str(work / 'obj/Vtb_ds_dev'), '--only', 'rtc-exhaust',
                                 '--fw', '/nonexistent/rtc-test-needs-no-firmware'],
                                stdout=log, stderr=subprocess.STDOUT, timeout=180)
    report = (work / 'run.log').read_text()
    if edit:
        require(result.returncode == 1 and 'FAIL [rtc-exhaust]' in report,
                name + ': NOT CAUGHT or invalid execution: ' + report[-500:])
    else:
        require(result.returncode == 0 and 'PASS:' in report,
                'baseline failed: ' + report[-500:])
    print(name + ': ' + ('CAUGHT ' if edit else '') + report.strip().splitlines()[-1], flush=True)
