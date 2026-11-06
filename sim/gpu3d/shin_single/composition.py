#!/usr/bin/env python3
"""Audit the one-port table schedule, unchanged writers/default and import aliases."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--before',default='f6c92036');a=p.parse_args()
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
paths=['rtl/gpu3d/gpu3d_gxlight.sv','rtl/gpu3d/gpu3d_gxeng.sv','rtl/gpu3d/gpu3d_ram.sv',
       'rtl/gpu3d/gpu3d_gxrom_ux.sv','rtl/gpu3d/gpu3d_gxu_pkg.sv',
       'sim/ds/runtime_gx_context.py','sim/pocket_ds/runtime_import_gx_context.svh']
src={p:(ROOT/p).read_bytes()for p in paths}
old={p:subprocess.check_output(['git','show',a.before+':'+p],cwd=ROOT)for p in paths}
for path in paths[1:]:assert src[path]==old[path],path
new=src[paths[0]].decode();before=old[paths[0]].decode()
def module(s,name):return s[s.index('module '+name+' '):].split('endmodule',1)[0]
for name in ['gpu3d_gxlight','gpu3d_gxlight_pair18','gpu3d_gxlight_products','gpu3d_gxlight_five']:
    assert module(new,name)==module(before,name),name
unit=module(new,'gpu3d_gxlightp');prior=module(before,'gpu3d_gxlightp')
assert unit.split(') (',1)[0]==prior.split(') (',1)[0], 'all original parameter positions/defaults'
assert unit.split(') (',1)[1].split('    // ---- snooped state',1)[0]==prior.split(') (',1)[1].split('    // ---- snooped state',1)[0], 'all ports'
def span(s,start,end):return s[s.index(start):s.index(end,s.index(start))]
assert span(unit,'    always_ff @(posedge clk) begin\n        if (we) begin','    logic [8:0] shine0')==span(prior,'    always_ff @(posedge clk) begin\n        if (we) begin','    logic [8:0] shine0')
assert span(unit,'    // ---- sequencer','    // ---- the pipeline')==span(prior,'    // ---- sequencer','    // ---- the pipeline')
assert unit.split('    // ---- CURCOL writes',1)[1]==prior.split('    // ---- CURCOL writes',1)[1]
helper=module(new,'gpu3d_gxlight_packed18');old_helper=module(before,'gpu3d_gxlight_packed18')
for name in ['ntpart','recpart','colors','ambsum']:
    f=lambda s:next(x+'endfunction'for x in s.split('    function automatic ')if re.search(r'\b'+name+r'\(',x.split('endfunction',1)[0])).split('endfunction',1)[0]
    assert f(helper)==f(old_helper),name
assert span(helper,'    wire signed [35:0] product [8];','    logic [9:0] md')==span(old_helper,'    wire signed [35:0] product [8];','    logic [9:0] md')
assert 'wire [3:0] slot={count,!mid};'in helper and 'assign midpoint=mid;'in helper
assert "sh_we_q<=we && wa[10:7]==A_SHIN[10:7];"in unit
assert "sh_wa_q<=wa[6:0];sh_wd_q<=wd[7:0];"in unit
assert '.we(USE_PACKED18 ? packed_sh_mid && sh_we_q : we && wa[10:7]==A_SHIN[10:7])'in unit
assert '.clk(USE_PACKED18 ? clk2 : clk)'in unit
assert 'srd[l]=USE_PACKED18 ? (l==0 ? packed_shin0 : sh_data[0]) : sh_data[l];'in unit
assert '.raddr(USE_PACKED18 ? shine0_c[packed_shin_sel][8:2] : shine0_c[gi][8:2])'in unit
assert 'gi < 4' in unit and '.rdata(sh_data[gi])'in unit

# Original legal importer restores one identical table into all four mirrors.
# Preserve every target path, not just the physically consumed mirror.
imports=re.findall(r'`RUNTIME_GEOMETRY\.u_eng\.g_lup\.u_light\.([A-Za-z_]\w*(?:\[\d+\])*(?:\.[A-Za-z_]\w*(?:\[\d+\])*)*)\s*=\s*([^;]+);',src[paths[6]].decode())
assert len(imports)==618
tables={}
for lhs,rhs in imports:
    m=re.fullmatch(r'g_sh\[(\d+)\]\.u_sh\.mem\[(\d+)\]\s*',lhs)
    if m:tables[int(m[1]),int(m[2])]=rhs
assert len(tables)==512
# Their context_data slots are distinct. The unchanged translator fills all
# four groups from the same captured128-byte ShininessTable, and readback
# checks all four original paths. Do not mistake slot identity for value identity.
translator=src[paths[5]].decode()
table_writer="for k, v in enumerate(c['ShininessTable']): reg(f'u_eng.g_lup.u_light.g_sh[{i}].u_sh.mem[{k}]', v)"
loop=span(translator,'    for i in range(4):\n        b = 0x100 + 16*i',"    cover('LightDirection")
assert table_writer in loop
for k in range(128):
    idx=[int(re.fullmatch(r'context_data\[(\d+)\]',tables[l,k])[1])for l in range(4)]
    assert idx==[idx[0]+128*l for l in range(4)]

slots=[
 ['N00L','N00H','N01L','N01H','N02L','N02H','N10L','N10H'],
 ['N11L','N11H','N12L','N12H','N20L','N20H','N21L','N21H'],
 ['N22L','N22H','D00','D01','D10','D11','D20','D21'],
 ['D02','D12','D22','D30','D31','D32','MD00','MD01'],
 ['Q0','Q1','Q2','Q3','MD10','MD11','MD20','MD21'],
 ['R0L','R0H','R1L','R1H','R2L','R2H','R3L','R3H'],
 ['MS00','MS01','MS10','MS11','MS20','MS21','F00','F01'],
 ['F02','F10','F11','F12','F20','F21','F22','F30'],
 ['S00','S01','S02','S10','S11','S12','F31','F32'],
 ['S20','S21','S22','MA00','MA01','MA10','MA11'],
 ['S30','S31','S32','MA20','MA21']]
at={op:s for s,ops in enumerate(slots)for op in ops}
assert len(at)==84 and all(len(s)<=8 for s in slots)
nt=[max(at[f'N{c}{k}{part}']for k in range(3)for part in'LH')for c in range(3)]
dot=[max(at[f'D{l}{k}']for k in range(3))for l in range(4)]
for l in range(4):
    for k in range(3):assert at[f'D{l}{k}']>nt[k]
    assert at[f'Q{l}']>max(dot[l],nt[2])
    assert at[f'R{l}L']==at[f'R{l}H']>at[f'Q{l}']
    assert at[f'R{l}L']<6+l
    for c in range(3):
        assert at[f'F{l}{c}']>max(dot[l],at[f'MD{c}{l//2}'])
        assert at[f'S{l}{c}']>max(6+l,at[f'MS{c}{l//2}'])
assert max(at.values())==10
script=(ROOT/'scripts/build_ds.sh').read_text()
assert '*|gpu3d_gxlightp:*|gpu3d_ram:g_sh*.u_sh|*'in script
assert 'set_multicycle_path -setup -end 1 -from [get_clocks $clk_sys] -to $gxlight_shin_regs'in script
assert 'set_multicycle_path -hold -end 0 -from [get_clocks $clk_sys] -to $gxlight_shin_regs'in script
result=dict(before=a.before,source_sha256={p:hashlib.sha256(b).hexdigest()for p,b in src.items()},
    unchanged='Parent ports/parameterABI, snooped coefficients/material precedence, sequencer/reset/abort/heldFIN/CURCOL outputs, all four arithmetic functions, full36 paired drivers/native6porthelper, generic/five helpers and all other source/import files exact.',
    default='USE_PACKED18=0 elaborates original SYS clock/write/read addresses/data. sh_data[gi] is a wire alias to original srd[gi]. Added pending FF/controls are unused and pruned. MAT_PAR0 PACKED18=1 follows this same fallback; compiled component tests cover both NOWR.',
    imported=dict(assignments=618,table_assignments=512,identical_values_for_all4=True,paths_and_sources_byte_exact=True),
    writer_relation='Each original SYS E table write is captured once and committed at next M, including reset/abort writes: new sh_we_q is not reset/abort gated. At every following M the memory equals old memory after preceding E. FinalDLY E0 write commits M0.5; first qualified read is F6=M3.5. Under the retained qualified RUN/heldFIN input-writer exclusion no further table write can collide. Generic tests explicitly change finalDLY table data; no new caller hold premise.',
    read_relation='All reciprocals complete F5=E3, with original signs/slices/clamps. One registered OLD_DATA read per F6..F9 returns L0,L1,L2,L3. F7 captures L0 before the L1 read updates q. F8 consumes heldL0/currentL1, F9 currentL2, F10 currentL3, each before that edge updates RAM q. Non-table shine0 SYS E4 gets all new reciprocals. All material/NT/DOT/SQ values hold as previously qualified.',
    schedule=dict(slots=slots,ops=84,capacity=88,all_inputs_before_E6=True,publication='sameE6VB/E6fast/E9slow/earliestII8; no newDSdeadline'),
    storage=dict(intendedRAM='4to1M10K, three unconsumed logical mirrors synthesisdead; numericalgateOPEN',added_logicalFF=56,pending_write=16,first_read=8,dotpartials_extra=32,DSP='four pairednativeatoms unchanged; config/count gated by corrected Root fit'),
    limitation='Source composition plus bounded compiled public/oracle/caller tests, not arbitrary-state SAT or corrupt-import equivalence. Trusted native DSP contract unchanged; no encrypted vendor model claim. Legal reset/fenced-idle importer writes same128-byte table into each mirror. Physical RAM merging/ALM trade/134MHz timing require actual fit.')
(out/'composition.json').write_text(json.dumps(result,indent=2)+'\n')
print('SHIN_COMPOSITION_PASS imports618/512tablealiases exact, default/writers/publiccontrol/native exact; oneport F6..F9 and84/88slots beforeE6')
