#!/usr/bin/env python3
"""gpu3d_lmac's altera_mult_add instance under Intel's own simulation model (altera_lnsim.sv, extracted as
openfpga-PlayStation scripts/run_mdec_idct_mac.py does), against tb_lmac.sv's reference; plus mutants of the instance that
must fail.   sim/gpu3d/a123_eq/lmac_vendor.py OUTDIR [tb_lmac.sv | tb_lmac4.sv]"""
import re, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
TOOLS = Path.home()/'Git/openfpga-PlayStation/build/tools'
vendor = TOOLS/'quartus-lite/25.1/quartus/eda/sim_lib/altera_lnsim.sv'
iverilog = TOOLS/'oss-cad-suite/bin/iverilog'; vvp = iverilog.with_name('vvp')
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
text = vendor.read_text(); mods = []
for m in re.finditer(r'(?m)^module\s+(\w+)\b', text):
    if m[1].startswith('ama_') or m[1] in ('altera_mult_add', 'altera_mult_add_rtl'):
        e = re.search(r'(?m)^[ \t]*endmodule\b', text[m.start():]); mods.append(text[m.start():m.start() + e.end()])
(out/'vendor.sv').write_text('`timescale 1ps/1ps\n' + '\n'.join(mods) + '\n')
ram = (ROOT/'rtl/gpu3d/gpu3d_ram.sv').read_text()
lmac = re.search(r'(?ms)^module gpu3d_lmac\b.*?^endmodule', ram)[0]
lmac2 = re.search(r'(?ms)^module gpu3d_lmac2\b.*?^endmodule', ram)[0]
both = lmac + '\n' + lmac2
tb = sys.argv[2] if len(sys.argv) > 2 else 'tb_lmac.sv'
cases = [('positive', both), ('sload-off', both.replace('.sload_accum(!ld)', '.sload_accum(1\'b1)')),
         ('preload', both.replace('.loadconst_value(63)', '.loadconst_value(43)')),
         ('operand-edge', both.replace('.input_register_a0("CLOCK0")', '.input_register_a0("UNREGISTERED")')),
         ('enable', both.replace('.ena1(en)', '.ena1(1\'b1)'))]
ok = True
for name, src in cases:
    d = out/name; d.mkdir(exist_ok=True)
    (d/'dut.sv').write_text('`timescale 1ns/1ps\n`define ALTERA_RESERVED_QIS\n' + src + '\n')
    subprocess.run([str(iverilog), '-g2012', '-s', 'tb', '-o', str(d/'sim'), str(ROOT/'sim/gpu3d/a123_eq'/tb),
                    str(d/'dut.sv'), str(out/'vendor.sv')], check=True, stdout=open(d/'compile.log', 'w'), stderr=subprocess.STDOUT)
    r = subprocess.run([str(vvp), '-N', str(d/'sim')], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
    (d/'run.log').write_text(r.stdout)
    good = ('PASS LMAC' in r.stdout) if name == 'positive' else ('LMAC mismatch' in r.stdout)
    ok &= good
    print(name, 'PASS' if good else 'FAIL', r.stdout.strip().splitlines()[-1][:160] if r.stdout.strip() else '')
sys.exit(0 if ok else 1)
