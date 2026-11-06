#!/usr/bin/env python3
"""nds_wifi against the C++ WiFi model (sim/ds/tb_wifi.cpp), on a recorded access list.

    sim/ds/wifi_test.py [--accesses F] [--from-trace TB_DS_LOG] [--mutate] [--mc]

--from-trace turns a tb_ds +wifitrace log ("wifi CYC: mst M R|W ADDR be B
wdata D") into an access list (sim/ds/wifi_hg.txt is HeartGold's WiFi start
on the continue path, docs/compat.md "WiFi"). Every read of the RTL must equal
the model's, apart from the timing-dependent registers (the microsecond
counter, IF, the counters), which are reported. --mutate: planted faults that
must make reads differ. --mc: the microcoded nds_wifi_mc (rtl/ds/nds_wifi_mc.sv)
instead of nds_wifi, with its own planted faults.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
MUTANTS = [
    ('baseband writes lose their data', "wm_wdata <= {4{rf_q[7:0]}};", "wm_wdata <= 32'd0;"),
    ('write masks ignored', "default: wmask = v;\n", "default: wmask = v & 16'hFFFE;\n"),
    ('W_ModeWEP not kept', "mode_wep <= wv[2:0]; wr(ix, wmask(ix, wv));", "mode_wep <= wv[2:0]; wr(ix, 16'd0);"),
]
# nds_wifi_mc: (name, regex, replacement[, access list[, max timing-dependent differences]]),
# the first match replaced
MC_MUTANTS = [
    ('baseband writes lose their data (ROM)', r"16'h00FF\};   // RDL 0x15A 0x00FF", "16'h0000};   // RDL 0x15A 0x00FF"),
    ('register writes lose bit 0', r"wire \[15:0\] b = src & imm;", "wire [15:0] b = src & imm & (c == S_W ? 16'hFFFE : 16'hFFFF);"),
    ('W_ModeWEP not kept (ROM)', r"16'h007F\};   // LD W 0x007F", "16'h0000};   // LD W 0x007F"),
    ('W_Random reads 0 (dispatch)', r"(\] = )9'd\d+(;   // R 044 H_RRND)", r"\g<1>9'd%(H_RZERO)d\2"),
    ('power-up: the transceiver stays off (ROM, power test)', r"16'h0001\};   // WR 0x034 IMM 1", "16'h0000};   // WR 0x034 IMM 1",
     'sim/ds/wifi_power.txt'),
    # the timer test's reads of the counters differ in a few reads at most (prescaler phase, docs/wifi.md)
    ('prescaler: 268 / 269 swapped', r"pcnt <= k268 \? 9'd268 : 9'd269;", "pcnt <= k268 ? 9'd269 : 9'd268;",
     'sim/ds/wifi_timer.txt', 5),
]


def from_trace(log, out):
    lines, last = [], None
    for l in open(log, errors='replace'):
        m = re.match(r'wifi (\d+): mst \d ([RW]) ([0-9a-f]{8}) be ([0-9a-f]) wdata ([0-9a-f]{8})$', l.strip())
        if not m:
            continue
        cyc, rw, a, be, d = m.groups()
        cyc = int(cyc)
        gap = 0 if last is None else min(max(cyc - last - 40, 0), 4000)
        last = cyc
        lines.append(f'{rw} {a} {be} {d} {gap}')
    Path(out).write_text('\n'.join(lines) + '\n')
    return len(lines)


def build(rtl, obj):
    obj.mkdir(parents=True, exist_ok=True)
    cmd = [str(TOOLS / 'verilator'), '--cc', '--exe', '--build', '-j', '8', '-O2', '-Wno-fatal', '-Wno-WIDTHEXPAND',
           '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL', '--top-module', rtl.stem, '--prefix', 'Vnds_wifi', '--Mdir', str(obj),
           '-CFLAGS', f'-std=c++17 -O2 -I{ROOT / "sim/ds"}', str(rtl), str(ROOT / 'sim/ds/tb_wifi.cpp')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout[-2000:] + r.stderr[-2000:])
    return obj / 'Vnds_wifi'


def run(tb, accesses, max_timing=None):
    """rc != 0 on a mismatch, or more timing-dependent differences than max_timing"""
    r = subprocess.run([str(tb), str(accesses), '--lat', '9'], capture_output=True, text=True, timeout=600)
    m = re.search(r'(\d+) timing-dependent differences', r.stdout)
    over = max_timing is not None and (not m or int(m.group(1)) > max_timing)
    return r.returncode or int(over), r.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--accesses', type=Path, default=ROOT / 'sim/ds/wifi_hg.txt')
    ap.add_argument('--from-trace', type=Path)
    ap.add_argument('--mutate', action='store_true')
    ap.add_argument('--mc', action='store_true')
    ap.add_argument('--max-timing', type=int, help='fail above this many timing-dependent differences')
    a = ap.parse_args()
    name = 'nds_wifi_mc' if a.mc else 'nds_wifi'
    if a.from_trace:
        print(f'{from_trace(a.from_trace, a.accesses)} accesses -> {a.accesses}')
    tb = build(ROOT / f'rtl/ds/{name}.sv', ROOT / f'build/wifi/obj_{name}')
    rc, out = run(tb, a.accesses, a.max_timing)
    print(out.rstrip())
    if rc:
        sys.exit('FAIL')
    if not a.mutate:
        return
    missed = 0
    src = (ROOT / f'rtl/ds/{name}.sv').read_text()
    labels = dict(re.findall(r"localparam logic \[\d:0\] E_(\w+) = \d'd(\d+);", src))
    entries = {k: int(v) for k, v in labels.items()}
    for i, (mname, old, new, *opt) in enumerate(MC_MUTANTS if a.mc else MUTANTS):
        acc, max_timing = (opt + [None, None])[:2]
        d = ROOT / f'build/wifi/mut_{name}{i}'
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        if a.mc:
            if not re.search(old, src):
                sys.exit(f'mutant anchor not found: {old}')
            ms = re.sub(old, new % entries if '%(' in new else new, src, count=1)
        else:
            if src.count(old) != 1:
                sys.exit(f'mutant anchor not found: {old}')
            ms = src.replace(old, new)
        (d / f'{name}.sv').write_text(ms)
        rc, out = run(build(d / f'{name}.sv', d / 'obj'), ROOT / acc if acc else a.accesses, max_timing)
        print(f"mutant '{mname}': " + ('caught' if rc else 'MISSED'))
        missed += not rc
    if missed:
        sys.exit(f'FAIL: {missed} mutants missed')


if __name__ == '__main__':
    main()
