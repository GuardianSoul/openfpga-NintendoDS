#!/usr/bin/env python3
"""Source-composition gate, including actual inferred phase/mux equations."""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--readset',type=Path,required=True)
p.add_argument('--before',default='a9465f58a8a6a633655434b5285b60fb1fbf7095')
p.add_argument('--fit',default='d7aac51fcf7fdd8c1578de9e579577892592291b')
a=p.parse_args();os.nice(10);out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
H=lambda b:hashlib.sha256(b).hexdigest()
blob=lambda sha,n:subprocess.check_output(['git','show',sha+':'+n],cwd=ROOT)
readset=json.loads(a.readset.read_text())
assert readset['before']==a.before
assert readset['params']==dict(FF=1,LUNIT=1,VFIN=2,USORT=1,GX_DSX=1,GX_SWAP_OVERLAP=1,GX_L44_READ=1,GX_DIV_P2X=1,GX_MAT_PAR=1,GX_PRE=1,DIV_P2X=0,SPILL=1,GATH16=1,SP_ON=4096,SP_AW=18)
assert not readset['engine_PC']['violations'] and not readset['journal_ready']['violations']
assert readset['engine_PC']['primary_inputs']==['po_ready','rst','s_draw']
assert readset['journal_ready']['primary_inputs']==['rst']
names=['gpu3d_gxrom']+['gpu3d_gxrom_u'+s for s in 'slvwfx']
images=[]
for name in names:
    path='rtl/gpu3d/'+name+'.sv';before=blob(a.before,path).decode();after=(ROOT/path).read_text()
    words=lambda s:{int(i):int(v,16)for i,v in re.findall(r"ra\[(\d+)\] = 70'h([0-9a-fA-F]+);",s)}
    b=words(before);assert b==words(after) and len(b)==2048
    packed={k:int(v,16)for k,v in re.findall(r"localparam logic \[\d+:0\] (A_\w+) = \d+'h([0-9a-f]+);",after)}
    table=packed['A_WORD_LO_BITS']|(packed['A_WORD_HI_BITS']<<35840)
    index=packed['A_INDEX_BITS'];mask=(1<<70)-1
    assert all((table>>(70*((index>>(10*i))&1023))&mask)==b[i]for i in range(2048))
    assert packed['A_RESET_WORD']==b[40]
    # Invert only the A replacement. Exact byte equality below binds every
    # B/immediate value, clock, stage, declaration and other original line.
    undo=re.sub(r'    // BEGIN exact A dictionary.*?    // END exact A dictionary\n','',after,flags=re.S)
    undo=undo.replace(", parameter bit A_DICT = 1'b0",'').replace('    input  logic        clk2, rst,\n','')
    undo=re.sub(r'    generate if \(A_DICT\) begin : g_a_dict.*?    end endgenerate\n','',undo,flags=re.S)
    needle='    always_ff @(posedge clk) begin\n        b_q1 <='
    assert undo.count(needle)==1
    undo=undo.replace(needle,'    always_ff @(posedge clk) begin\n        a_q <= ra[a_addr[10:0]];\n        b_q1 <=',1)
    assert undo==before,name
    assert blob(a.fit,path)==after.encode()
    images.append(dict(image=name,PCs=2048,full_bits=70,classes=len(set(b.values())),
        before_sha256=H(before.encode()),after_sha256=H(after.encode()),
        inverse_source_identical=True,all_full_words_equal=True,reset40_equal=True))

eng_path='rtl/gpu3d/gpu3d_gxeng.sv';eng=(ROOT/eng_path).read_text();undo=eng
undo=re.sub(r'^    parameter bit ROM_DICT =.*\n','',undo,flags=re.M)
assert undo.count(', .A_DICT(ROM_DICT)')==7 and undo.count('.clk, .clk2(clk_2x), .rst, .a_addr')==7
undo=undo.replace(', .A_DICT(ROM_DICT)','').replace('.clk, .clk2(clk_2x), .rst, .a_addr','.clk, .a_addr')
assert undo.encode()==blob(a.before,eng_path)
assert eng.encode()==blob(a.fit,eng_path)
geom_path='rtl/gpu3d/gpu3d_geom.sv';geom=(ROOT/geom_path).read_text()
undo=re.sub(r'^    parameter bit GX_ROM_DICT =.*\n','',geom,flags=re.M)
assert undo.count('.ROM_DICT(GX_ROM_DICT && GX_DIV_P2X), ')==1
undo=undo.replace('.ROM_DICT(GX_ROM_DICT && GX_DIV_P2X), ','')
assert undo.encode()==blob(a.before,geom_path)
assert "GX_ROM_DICT = 1'b0" in geom
fit_geom=blob(a.fit,geom_path).decode()
assert re.sub(r'^    parameter bit GX_ROM_DICT =.*\n','',fit_geom,flags=re.M)==re.sub(r'^    parameter bit GX_ROM_DICT =.*\n','',geom,flags=re.M)
assert "GX_ROM_DICT = 1'b1" in fit_geom
gpu_path='rtl/ds/nds_gpu3d.sv';gpu=(ROOT/gpu_path).read_text()
assert gpu.count(".GX_ROM_DICT(1'b1), ")==1
assert gpu.replace(".GX_ROM_DICT(1'b1), ",'').encode()==blob(a.before,gpu_path)==blob(a.fit,gpu_path)
others=['rtl/gpu3d/gpu3d_'+s+'.sv'for s in ['gxu_pkg','ram','gxfront','gxvfin','gxlight','gxdiv','gxsort']]
for path in others:
    assert (ROOT/path).read_bytes()==blob(a.before,path)==blob(a.fit,path),path
for path,h in readset['source_hashes'].items():
    assert H(blob(a.before,path))==h,path
assert H(blob(a.fit,'rtl/ds/nds_g3d_journal.sv'))==readset['source_hashes']['rtl/ds/nds_g3d_journal.sv']

helper_path='rtl/gpu3d/gpu3d_gxrom_adict.sv';helper=(ROOT/helper_path).read_bytes()
assert helper==blob(a.fit,helper_path)
script=out/'helper.ys'
script.write_text('read_slang --top gpu3d_gxrom_adict -j 1 --ignore-initial --ignore-assertions '+str(ROOT/helper_path)+'; proc; write_json '+str(out/'helper.json')+'\n')
with(out/'helper.log').open('w')as log:
    subprocess.run(['build/tools/oss-cad-suite/bin/yosys','-Q','-T','-s',str(script)],stdout=log,stderr=subprocess.STDOUT,check=True)
m=json.loads((out/'helper.json').read_text())['modules']['gpu3d_gxrom_adict'];cells=m['cells'];nets=m['netnames']
bits=lambda n:nets[n]['bits']
sysclk=m['ports']['clk']['bits'];fastclk=m['ports']['clk2']['bits']
def flop(n,clk):
    found=[c for c in cells.values()if c['type']=='$dff'and c['connections']['Q']==bits(n)]
    assert len(found)==1;f=found[0];assert f['connections']['CLK']==clk and int(f['parameters']['CLK_POLARITY'],2)==1
    return f
ff={n:flop(n,sysclk if n in ['tg','reset_q']else fastclk)for n in ['tg','tq','ph','reset_q','index_q','word_q']}
driver={b:(c,p,i)for c in cells.values()for p,d in c['port_directions'].items()if d=='output'for i,b in enumerate(c['connections'][p])if isinstance(b,int)}
def mux_D(n):
    d=ff[n]['connections']['D'];c,port,_=driver[d[0]]
    assert c['type']=='$mux'and c['connections']['Y']==d and c['connections']['S']==bits('ph')
    return c['connections']
rd={c['parameters']['MEMID'].lstrip('\\'):c['connections']for c in cells.values()if c['type']=='$memrd_v2'}
im=mux_D('index_q');wm=mux_D('word_q')
assert im['A']==bits('index_q')and im['B']==rd['index_mem']['DATA']
assert wm['A']==rd['word_mem']['DATA']and wm['B']==bits('word_q')
assert rd['index_mem']['ADDR']==m['ports']['addr']['bits']and rd['word_mem']['ADDR']==bits('index_q')
assert len(bits('word_q'))==70 and len(bits('index_q'))==10
assert ff['reset_q']['connections']['D']==m['ports']['rst']['bits']
qout=m['ports']['q']['bits'];c,_,_=driver[qout[0]]
assert c['type']=='$buf';c,_,_=driver[c['connections']['A'][0]]
assert c['type']=='$mux'and c['connections']['S']==bits('reset_q')and c['connections']['A']==bits('word_q')
assert all(v=='0'for v in c['connections']['B']) # default RESET_WORD; all7 actual constants checked above/unit
assert 'assign q = reset_q ? RESET_WORD : word_q;' in helper.decode()

# Evaluate only the actual synthesized three-bit phase D-cone. No handwritten
# replacement phase recurrence or ROM-data oracle is used.
def value(b,state):
    if b in ('0','1'):return int(b)
    if b in state:return state[b]
    c,port,i=driver[b];co=c['connections'];typ=c['type']
    if typ in ('$logic_not','$not'):return 1-value(co['A'][0],state)
    if typ=='$eq':return int([value(x,state)for x in co['A']]==[value(x,state)for x in co['B']])
    if typ=='$buf':return value(co['A'][i],state)
    raise AssertionError((b,typ))
def event(s,e):
    state={bits(n)[0]:v for n,v in zip(['tg','tq','ph'],s)}
    return tuple(value(ff[n]['connections']['D'][0],state)if e=='E'or n!='tg'else v for n,v in zip(['tg','tq','ph'],s))
phase_cases=0
for seed in itertools.product((0,1),repeat=3):
    for first in ['M','E']:
        s=seed;edge=first;E=0
        for _ in range(32):
            if E>=3:
                assert s[2]==int(edge=='M')
                assert (s[0]!=s[1])==(edge=='M')
            s=event(s,edge);E+=int(edge=='E');edge='E'if edge=='M'else'M'
        phase_cases+=1
# The two phase predicates are inductive for unbounded running time.
for v in (0,1):
    assert event((v,v,0),'E')==(1-v,v,1)
    assert event((1-v,v,1),'M')==(1-v,1-v,0)
binding_paths=['rtl/pocket/core_top_ds.sv','rtl/ds/nds_top.sv','rtl/ds/nds_g3d_store_pair.sv','rtl/ds/nds_g3d_journal.sv']
binding_source={path:blob(a.fit,path).decode() for path in binding_paths}
core=binding_source[binding_paths[0]]
top=binding_source[binding_paths[1]];pair=binding_source[binding_paths[2]]
for name,v in [('GX_FAST',1),('GX_DIV_P2X',1),('GX_DSX',1),('GX_SWAP_OVERLAP',1),('GX_L44_READ',1),('GX_GATH16',1),('GX_SPAW',18),('GX_SP_ON',4096),('G3D_STORAGE_PAIR',1)]:
    assert re.search(r'parameter integer '+name+r'\s*=\s*'+str(v)+r'\s*[,)]',core),name
    assert '.'+name+'('+name+')' in core,name
assert ".GX_PRE(1'b1), .DIV_P2X(1'b0)" in gpu
assert '.GX_GATH16(GX_GATH16 != 0)' in top and '.GATH16(GX_GATH16)' in gpu
assert '.GX_FF(GX_FAST != 0 || GX_FF != 0)' in top
assert '.GX_LUNIT(GX_FAST != 0 || GX_LUNIT != 0)' in top and '.GX_VFIN(GX_FAST != 0 ? 2 : GX_VFIN)' in top
assert '.STORAGE_PAIR(G3D_STORAGE_PAIR != 0)' in top
assert 'if(STORAGE_PAIR)begin : g_pair' in gpu and 'nds_g3d_store_pair #' in gpu
assert 'nds_g3d_journal u_journal (' in pair and '.so_done,.po_ready,.wb,' in pair
assert '.clk(clk_sys), .clk_cpu(clk_cpu), .clk_2x(clk_2x), .rst(rst_sys)' in core
assert "rst_sys_s = 3'b111" in core and 'always @(posedge clk_sys or negedge pll_locked)'in core
assert "rst_sys_s <= {rst_sys_s[1:0], 1'b0}" in core
build=(ROOT/'scripts/build_ds.sh').read_text()
assert 'gpu3d/gpu3d_gxrom_adict.sv'in build
assert 'set gxarom_regs [get_registers -nowarn {*|gpu3d_gxrom_adict:*|*}]'in build
assert 'set_multicycle_path -setup -end 1 -from [get_clocks $clk_sys] -to $gxarom_regs'in build
assert 'set_multicycle_path -hold -end 0 -from [get_clocks $clk_sys] -to $gxarom_regs'in build
result=dict(before=a.before,fit=a.fit,images=images,other_engine_logic_byte_identical=True,
    readset_sha256=H(a.readset.read_bytes()),actual_readset_params=readset['params'],
    actual_binding_sha256={p:H(s.encode())for p,s in binding_source.items()},
    actual_binding='Pocket GX_FAST/DSX/P2X/L44/SWAP/GATH16=1, cache4096/SPAW18; wrapper PRE1/DIV_P2X0; STORAGE_PAIR1 journal-ready route; SYS reset/clk and aligned2x forwarded.',
    other_RTL_sha256={p:H((ROOT/p).read_bytes())for p in others},
    active_fit_binding='Fit6427 omits GX_ROM_DICT and uses geom default1; candidate Pocket explicitly passes1 with generic default0. All active ROM/helper/engine source and effective parameters identical. No extrafit needed for this binding change.',
    generic_scope='Generic callers default to original ROM; compressed mode requires actual bound SYS-held non-reset PC inputs, aligned2x clock and SYS reset release.',
    helper_sha256=H(helper),helper_netlist_sha256=H((out/'helper.json').read_bytes()),
    phase=dict(arbitrary_initial_states=8,start_orders=2,cases=phase_cases,legal_reset_SYS_edges=3,
        inductive_E='tg==tq,ph0; E maps to tg!=tq,ph1',inductive_M='tg!=tq,ph1; M maps to tg==tq,ph0',
        actual_mux_equations='M: index_q:=I(addr),word_q holds; E:index_q holds,word_q:=D(index_q)',
        all70_word_hold_bits=True,reset_selector_SYS_only=True,first_E_exact_RESET40=True,
        legal_release='Actual three-stage SYS release follows phase acquisition; first unreset M has correct phase/index and next E has original word. Asynchronous assertion afterM is handled by E reset override, not PC hold.'),
    composition='From the common qualified reset/reference state, identical fullA inputs at every E/M and byte-identical other transition/output logic imply identical all-state/observable cycle/order behavior by induction. PC hold follows the separately checked actual read set. No pre-first-clock value promised by either synchronous ROM.',
    actor='NO fullactorPASS. Retain sharedtimeout from missingPIO wiring/zerooutcomes and equalprefix. No corrected optional actor rerun; not used by composition.',
    clocks='Strict private normal setup1/hold0 present. Actual endpoint aliases/mapping and7.46ns physical closure remain fit/STA gates; no STA claim.',
    source_hashes={p:H((ROOT/p).read_bytes())for p in [eng_path,geom_path,gpu_path,'scripts/build_ds.sh']})
(out/'composition.json').write_text(json.dumps(result,indent=2)+'\n')
print('COMPOSITION_PASS all7x2048full70 inverse_source_identity phase16cases+induction reset40+release3 fit_binding_same; no_actorPASS/no_STA',flush=True)
