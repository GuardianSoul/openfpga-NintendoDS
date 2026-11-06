#!/usr/bin/env python3
"""Bind the pilot to the qualified caller/default/imports and audit its schedule."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='8ad7034b376ba0a117f5855e931d2e9784856e00')
a = p.parse_args()
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
paths = ['rtl/gpu3d/gpu3d_gxlight.sv', 'rtl/gpu3d/gpu3d_gxeng.sv',
         'rtl/gpu3d/gpu3d_gxrom_ux.sv', 'rtl/gpu3d/gpu3d_gxu_pkg.sv',
         'sim/ds/runtime_gx_context.py', 'sim/pocket_ds/runtime_import_gx_context.svh']
current = {s: (ROOT/s).read_bytes() for s in paths}
before = {s: subprocess.check_output(['git', 'show', a.before+':'+s], cwd=ROOT) for s in paths}
for s in paths[2:]:
    assert current[s] == before[s], s
assert current[paths[1]].replace(b'.PACKED18(MAT_PAR), ', b'') == before[paths[1]]
light = current[paths[0]].decode()
old = before[paths[0]].decode()
native_pair = 'module gpu3d_gxlight_pair18 (' in light
if native_pair:
    # The separate native.py gate validates the actual QIS binding and its
    # transparent arithmetic contract. Normalize only this paired driver
    # boundary to reuse the exact already-qualified schedule composition.
    paired = light[light.index('module gpu3d_gxlight_pair18 ('):].split('endmodule',1)[0]+'endmodule\n'
    new_drivers = '''    wire signed [35:0] product [8];
    genvar pair;
    generate for(pair=0;pair<4;pair++) begin : g_pair
        gpu3d_gxlight_pair18 u_pair (
            .a0(a[2*pair]), .b0(b[2*pair]), .a1(a[2*pair+1]), .b1(b[2*pair+1]),
            .p0(product[2*pair]), .p1(product[2*pair+1]));
    end endgenerate'''
    old_drivers = '''    (* multstyle = "dsp" *) wire signed [35:0] product [8];
    genvar lane;
    generate for(lane=0;lane<8;lane++) begin : g_lane
        assign product[lane]=a[lane]*b[lane];
    end endgenerate'''
    assert light.count(new_drivers)==1
    light=light.replace(paired+'\n','',1).replace(new_drivers,old_drivers)
    assert light==subprocess.check_output(['git','show','3e34e6e8:'+paths[0]],cwd=ROOT).decode()
helper = light[light.index('module gpu3d_gxlight_packed18 ('):].split('endmodule', 1)[0]+'endmodule\n'
start = light.index('// Eight signed18x18 products')
end = light.index('endmodule', light.index('module gpu3d_gxlight_packed18 ('))+len('endmodule\n')
restored = light[:start]+light[end:]
# Remove the private append and apply its constant-false elaboration. This
# checks every old/default expression and all old helper bodies byte for byte.
restored = restored.replace("    parameter bit SHARED5 = 1'b0, // opt-in; appended to preserve existing positional parameter ABI\n    parameter bit PACKED18 = 1'b0 // private packed-material/native-half-DSP schedule",
                            "    parameter bit SHARED5 = 1'b0 // opt-in; appended to preserve existing positional parameter ABI")
restored = restored.replace("    localparam bit USE_PACKED18 = PACKED18 && MAT_PAR;\n    wire [11:0] packed_ambient [3];\n", '')
start = restored.index('    generate if (USE_PACKED18) begin : g_packed18')
end = restored.index('    end else if (!SHARED5) begin : g_original_products', start)
restored = restored[:start]+'    generate if (!SHARED5) begin : g_original_products'+restored[end+len('    end else if (!SHARED5) begin : g_original_products'):]
restored = restored.replace('if (!SHARED5 && !USE_PACKED18)', 'if (!SHARED5)')
restored = restored.replace("            if (USE_PACKED18) s = s + {3'd0, packed_ambient[c], 9'd0};\n", '')
restored = restored.replace("(USE_PACKED18 ? 24'd0 : {5'd0, ambient_product[i][c]})", "{5'd0, ambient_product[i][c]}")
# The insertion adds one separating blank line before the original module.
restored = restored.replace('endmodule\n\n\n// The lighting unit', 'endmodule\n\n// The lighting unit')
if restored != old:
    (out/'restored.sv').write_text(restored)
    (out/'before.sv').write_text(old)
assert restored == old, 'default/source inverse differs'
imports = sorted(set(re.findall(r'`RUNTIME_GEOMETRY\.u_eng\.g_lup\.u_light\.([A-Za-z_]\w*(?:\[\d+\])*(?:\.[A-Za-z_]\w*(?:\[\d+\])*)*)\s*=', current[paths[5]].decode())))
assert len(imports) == 618
assert not any(x.startswith(('g_packed18', 'packed_ambient')) for x in imports)
assert 'input logic clk,clk2,rst,abort,run,' in helper
assert 'wire [3:0] slot={count,!mid};' in helper
assert 'assign product[lane]=a[lane]*b[lane];' in helper
assert 'return {3\'d0,hi,5\'d0,lo};' in helper
assert 'return lo[22:0]+{hi[10:0],12\'d0};' in helper
assert "return 31'(lo)+(31'(hi)<<<10);" in helper

# Exhaust the entire common-coefficient packing domain. This arithmetic
# lemma complements, rather than substitutes for, the compiled RTL oracle.
packing_cases = 0
for m in range(32):
    for lo in range(32):
        for hi in range(32):
            v = m*(lo+(hi << 10))
            assert (v & 1023) == m*lo and ((v >> 10) & 1023) == m*hi
            packing_cases += 1

# Each operation occupies one actual multiplier for one FAST interval.
# A wide NT/reciprocal operation occupies two lanes simultaneously. Audit
# producer completion, the E4 SYS-table fence, and all E6-VB dependencies.
slots = [
    ['N00L','N00H','N01L','N01H','N02L','N02H','N10L','N10H'],
    ['N11L','N11H','N12L','N12H','N20L','N20H','N21L','N21H'],
    ['N22L','N22H','MD00','MD01','MD10','MD11','MD20','MD21'],
    ['D00','D01','D02','D10','D11','D12','D20','D21'],
    ['D22','D30','D31','D32','Q0','Q1','MS00','MS01'],
    ['Q2','Q3','R0L','R0H','R1L','R1H','MS10','MS11'],
    ['R2L','R2H','R3L','R3H','F00','F01','F02','F10'],
    ['F11','F12','F20','F21','F22','F30','MS20','MS21'],
    ['S00','S01','S02','S10','S11','S12','S20','S21'],
    ['S22','S30','S31','S32','MA00','MA01','MA10','MA11'],
    ['F31','F32','MA20','MA21'],
]
at = {op: s for s, ops in enumerate(slots) for op in ops}
assert len(at) == 84 and all(len(s) <= 8 for s in slots)
nt = [max(at[f'N{c}{k}{part}'] for k in range(3) for part in 'LH') for c in range(3)]
dot = [max(at[f'D{l}{k}'] for k in range(3)) for l in range(4)]
for l in range(4):
    for k in range(3):
        assert at[f'D{l}{k}'] > nt[k]
    assert at[f'Q{l}'] > max(dot[l], nt[2])
    assert at[f'R{l}L'] == at[f'R{l}H'] > at[f'Q{l}']
    assert at[f'R{l}L'] < 7  # before E4's OLD_DATA table sampling
    for c in range(3):
        assert at[f'F{l}{c}'] > max(dot[l], at[f'MD{c}{l//2}'])
        assert at[f'S{l}{c}'] > max(7, at[f'MS{c}{l//2}'])
assert all(s < 11 for s in at.values())  # all visible-sum inputs before E6
result = dict(before=a.before, source_sha256={s: hashlib.sha256(b).hexdigest() for s,b in current.items()},
              native_pair_boundary='Required separate native.py source/vendor-schema/contract gate; normalized eight drivers to four pairs, rest exact3e34e6e8. No encrypted vendor simulation claimed.'if native_pair else None,
              inverse_default_byte_exact=True, caller_except_private_opt_in_byte_exact=True,
              imports=dict(paths=imports, count=618, files_byte_exact=True, private_caches_imported=False),
              arithmetic=dict(common_coefficient_packing_cases=packing_cases,
                  NT='For signed10 n and unsigned23 v=lo12+2^12*hi11: n*v mod2^23=(n*lo12+(n*hi11)<<12) mod2^23. Each lane is signed18, low operands zero-extended, complete original low23 sum and bits22:12 retained.',
                  reciprocal='For unsigned10 s and signed20 c=unsignedlo10+2^10*signedhi10: s*c mod2^31=s*lo10+(s*hi10)<<10 mod2^31. Full signed31 preserved before original wrap/clamp.',
                  ambient='Four selected unsigned10 products sum<=4*961=3844 fits12. Summing once then shifting9 is identical modulo2^24 to the original enabled-light ambient additions.'),
              schedule=dict(slots=slots, count=84, capacity=88, table_reads='E4 all four original SYS ports; outputs ready F8', publication='unchangedSYS E6/E9/II8; no new DS rule or public latency bound'),
              sampling='Actual registered snooped mirrors, precedence, DLY fence, dispatch/interlock/ROM and group ownership are unchanged from the qualified five69 caller. Inputs hold RUN/FIN under that existing legal-caller proof; new reads all occur inside RUN. Generic default0 restored byte-exact. Component tests retain final-DLY writers; no additional input-hold premise introduced.',
              reset='Private unreset material/partial/ambient registers are overwritten before use on every RUN. Reset/abort gates all FAST writes and original SYS sequencer. Cancel/held-FIN edge tests are separate compiled evidence.',
              limits='Source composition and bounded executed oracle/caller; not arbitrary-state SAT or corrupt-runtime-import equivalence. New helpers/caches must meet ordinary7.46ns FAST setup/hold; mapping/netarea/STA require actual fit.')
(out/'composition.json').write_text(json.dumps(result, indent=2)+'\n')
print('COMPOSITION_PASS default/caller/imports618 exact; packing32768; 84/88slots producer/table/E6 fences')
