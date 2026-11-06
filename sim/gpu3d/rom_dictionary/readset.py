#!/usr/bin/env python3
"""Structural clock-induction proof of the actual pre-change PC read set."""
import argparse
from collections import defaultdict
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
YOSYS = 'build/tools/oss-cad-suite/bin/yosys'
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='a9465f58a8a6a633655434b5285b60fb1fbf7095')
a = p.parse_args()
os.nice(10)
out = a.out.resolve(); out.mkdir(parents=True, exist_ok=True)
print('readset_PID', os.getpid(), 'NI10/j1/t1', flush=True)
H = lambda b: hashlib.sha256(b).hexdigest()
paths = ['rtl/gpu3d/gpu3d_gxu_pkg.sv', 'rtl/gpu3d/gpu3d_ram.sv']
paths += [f'rtl/gpu3d/{s}' for s in ['gpu3d_gxrom.sv'] + [f'gpu3d_gxrom_u{v}.sv' for v in 'slvwfx']]
paths += [f'rtl/gpu3d/gpu3d_{v}.sv' for v in ['gxlight','gxvfin','gxdiv','gxfront','gxeng','gxsort','geom']]
extra = ['rtl/ds/nds_g3d_journal.sv','rtl/ds/nds_gpu3d.sv','rtl/pocket/core_top_ds.sv']
source = {}
for name in paths+extra:
    b = subprocess.check_output(['git','show',a.before+':'+name],cwd=ROOT)
    f = out/'source'/name; f.parent.mkdir(parents=True,exist_ok=True); f.write_bytes(b)
    source[name] = H(b)
params = dict(FF=1,LUNIT=1,VFIN=2,USORT=1,GX_DSX=1,GX_SWAP_OVERLAP=1,GX_L44_READ=1,GX_DIV_P2X=1,GX_MAT_PAR=1,GX_PRE=1,DIV_P2X=0,SPILL=1,GATH16=1,SP_ON=4096,SP_AW=18)
for top, files, flags in [
    ('gpu3d_geom',paths,' '.join('-G '+k+'='+str(v) for k,v in params.items())),
    ('nds_g3d_journal',[paths[1],extra[0]],'-D ALTERA_RESERVED_QIS')]:
    # Initial values are unconstrained, not replaced with a chosen ROM. The
    # hold theorem is for arbitrary static ROM/memory and arbitrary SYS state.
    cmd = ('read_slang --top '+top+' -j 1 --ignore-assertions --ignore-initial '
           '--allow-use-before-declare --allow-dup-initial-drivers '+flags+' '+
           ' '.join(str(out/'source'/v) for v in files)+'; proc; opt_clean; write_json '+str(out/(top+'.json')))
    script = out/(top+'.ys'); script.write_text(cmd+'\n')
    with (out/(top+'.log')).open('w') as log:
        subprocess.run([YOSYS,'-Q','-T','-s',str(script)],stdout=log,stderr=subprocess.STDOUT,check=True)


def cone(m, roots):
    cells=m['cells'];drivers=defaultdict(list)
    for n,c in cells.items():
        for port,d in c['port_directions'].items():
            if d=='output':
                for b in c['connections'][port]:
                    if isinstance(b,int):drivers[b].append(n)
    primary={b:n for n,p in m['ports'].items() if p['direction']=='input' for b in p['bits']}
    writes=defaultdict(list)
    for n,c in cells.items():
        if c['type'].startswith('$memwr'):writes[c['parameters']['MEMID']].append(n)
    seen=set();todo=list(roots);ff=set();memwr=set();mem=set();comb=set();inputs=set();bad=[]
    sysclk=m['ports']['clk']['bits']
    def clock(n,c):
        if c['connections']['CLK']!=sysclk or int(c['parameters']['CLK_POLARITY'],2)!=1:
            bad.append(dict(cell=n,type=c['type'],clock=c['connections']['CLK']))
    while todo:
        b=todo.pop()
        if not isinstance(b,int) or b in seen:continue
        seen.add(b)
        if b in primary:inputs.add(primary[b]);continue
        if len(drivers[b])!=1:bad.append(dict(bit=b,drivers=drivers[b]));continue
        n=drivers[b][0];c=cells[n];typ=c['type'];co=c['connections']
        if typ in ('$dff','$dffe','$sdff','$sdffe'):
            ff.add(n);clock(n,c);continue
        if typ.startswith(('$adff','$dlatch')):
            bad.append(dict(cell=n,type=typ));continue
        if typ.startswith('$memrd'):
            mid=c['parameters']['MEMID'];mem.add(mid)
            for w in writes[mid]:
                wc=cells[w];memwr.add(w)
                if int(wc['parameters']['CLK_ENABLE'],2):clock(w,wc)
                else:bad.append(dict(cell=w,type='unclocked_memory_write'))
            if int(c['parameters']['CLK_ENABLE'],2):ff.add(n);clock(n,c);continue
        comb.add(n)
        for port,d in c['port_directions'].items():
            if d=='input':todo.extend(co[port])
    return dict(bits=len(seen),comb_cells=len(comb),SYS_FF_groups=len(ff),SYS_memory_write_ports=len(memwr),
                memories=sorted(mem),primary_inputs=sorted(inputs),violations=bad,FF_cells=sorted(ff))


geom=json.loads((out/'gpu3d_geom.json').read_text())['modules']['gpu3d_geom']
journal=json.loads((out/'nds_g3d_journal.json').read_text())['modules']['nds_g3d_journal']
g=cone(geom,geom['netnames']['u_eng.upc_n']['bits'])
j=cone(journal,journal['ports']['po_ready']['bits'])
assert not g['violations'] and g['primary_inputs']==['po_ready','rst','s_draw']
assert not j['violations'] and j['primary_inputs']==['rst']
assert g['comb_cells']>300 and g['SYS_FF_groups']>50 and g['SYS_memory_write_ports']>10
assert j['SYS_FF_groups']>=5
changed=copy.deepcopy(geom)
R=set(geom['netnames']['u_eng.R']['bits'])
fault=next(n for n in g['FF_cells'] if R.intersection(geom['cells'][n]['connections'].get('Q',[])))
changed['cells'][fault]['connections']['CLK']=geom['ports']['clk_2x']['bits']
mutant=cone(changed,changed['netnames']['u_eng.upc_n']['bits'])
assert any(v.get('cell')==fault for v in mutant['violations'])
gpu=(out/'source'/extra[1]).read_text();core=(out/'source'/extra[2]).read_text()
assert 'always_ff @(posedge clk) sw_vb <=' in gpu and "assign s_draw = sw_vb >= 17'(SWIN);" in gpu
assert 'always @(posedge clk_sys or negedge pll_locked)' in core
assert "rst_sys_s <= {rst_sys_s[1:0], 1'b0}" in core
result=dict(before=a.before,source_hashes=source,params=params,engine_PC=g,journal_ready=j,
    clock_reader_mutation=dict(cell=fault,new_clock='clk_2x',caught=True,scope='Actual elaborated R flop clock changed in netlist; reader negative control, not the required RTL dictionary fault'),
    theorem='Every non-reset live PC leaf is positive-SYS state (including memory contents) or SYS-held ready/window. No clock edge writes that state between M and E. Combinational induction therefore holds upc_n(M)=upc_n(E-) for arbitrary state/ROM contents, given normal settling.',
    initial_scope='Ignored initial procedures strengthen state/ROM to arbitrary values for clock ownership only. No ROM-value/functional claim made by this pass.',
    reset='Actual assertion asynchronous; E-only full ra[40] override required. Actual release after3SYS edges, phase may align while reset; tested separately.',
    timing='No physical7.46ns propagation/setup/hold proof or STA claim.',
    files={v.name:H(v.read_bytes()) for v in out.glob('*.json')})
(out/'readset.json').write_text(json.dumps(result,indent=2)+'\n')
print('PC_READSET_PASS',g['bits'],g['comb_cells'],g['SYS_FF_groups'],g['SYS_memory_write_ports'],'journal',j['bits'],j['SYS_FF_groups'],'clockfault_caught',flush=True)
