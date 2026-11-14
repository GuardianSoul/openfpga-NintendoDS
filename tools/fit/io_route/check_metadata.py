#!/usr/bin/env python3
"""Light attribute-only identity proof against c5; no C++ build/Quartus/fit."""
import hashlib,json,os,pathlib,re,subprocess
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[2];OUT=ROOT/'build/io-metadata';OUT.mkdir(parents=True,exist_ok=True)
BASE='c5ae8d39a142d6be1414ac77ec126f46c81e6717'
V=pathlib.Path('build/tools/oss-cad-suite/bin/verilator')
sha=lambda b:hashlib.sha256(b).hexdigest()
os.nice(10)
before=subprocess.check_output(['git','show',BASE+':rtl/ds/nds_io.sv'],cwd=ROOT).decode()
after=(ROOT/'rtl/ds/nds_io.sv').read_text()
changes=[('    logic [1:0] route_lane;','    (* preserve, dont_merge *) logic [1:0] route_lane;'),('    (* syn_encoding="user", fsm_encoding="none" *) logic [2:0] route_envelope;','    (* preserve, dont_merge, syn_encoding="user", fsm_encoding="none" *) logic [2:0] route_envelope;'),('    logic ram_reply_mirror;','    (* preserve, dont_merge *) logic ram_reply_mirror;')]
expected=before
for old,new in changes:assert expected.count(old)==1;expected=expected.replace(old,new)
assert after==expected,'change is not exactly the three approved attribute additions'
def contract(text):
    for _,line in changes:assert text.count(line)==1,'missing preservation/merge contract'
contract(after)
attribute_faults={}
for name,_,replacement in [('envelope_preserve',None,changes[1][1].replace('preserve, ','')),('lane_dont_merge',None,changes[0][1].replace('dont_merge','')),('reply_preserve',None,changes[2][1].replace('preserve, ',''))]:
    index=1 if name.startswith('envelope')else 0 if name.startswith('lane')else 2
    mutant=after.replace(changes[index][1],replacement)
    try:contract(mutant)
    except AssertionError:attribute_faults[name]='CAUGHT'
    else:raise AssertionError('escaped attribute omission '+name)
def tokens(text):
    # Attribute syntax is distinct from @(*): the opening must be followed
    # by an identifier, not the event-control closing parenthesis.
    text=re.sub(r'\(\*(?=\s*[A-Za-z_]).*?\*\)','',text,flags=re.S)
    text=re.sub(r'/\*.*?\*/|//[^\n]*','',text,flags=re.S)
    return re.findall(r'"(?:\\.|[^"\\])*"|[^\s]',text)
inputs={'before':before,'after':after,'fault_lane_sample':after.replace('route_lane <= wa[1:0];',"route_lane <= wa[1:0] ^ 2'b01;")}
# Mutate only the capture block's real clock, not the comparator or driver.
mark=after.index('        route_lane <= wa[1:0];');edge=after.rfind('always_ff @(posedge clk)',0,mark);assert edge>=0
inputs['fault_capture_edge']=after[:edge]+after[edge:].replace('always_ff @(posedge clk)','always_ff @(negedge clk)',1)
for name,source in inputs.items():(OUT/(name+'.sv')).write_text(source)
records={};outputs={}
for profile,defs in [('SIM',[]),('QIS',['-DALTERA_RESERVED_QIS'])]:
    outputs[profile]={}
    for name in inputs:
        command=[str(V),'-E','-P','--threads','1',*defs,str(OUT/(name+'.sv'))]
        p=subprocess.run(command,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        (OUT/(profile+'-'+name+'.pre')).write_bytes(p.stdout);(OUT/(profile+'-'+name+'.err')).write_bytes(p.stderr)
        assert p.returncode==0,p.stderr.decode(errors='replace')
        ts=tokens(p.stdout.decode());outputs[profile][name]=ts
        records[profile+'-'+name]={'command':command,'exit':p.returncode,'raw_sha256':sha(p.stdout),'significant_token_sha256':sha(json.dumps(ts,separators=(',',':')).encode()),'tokens':len(ts)}
    assert outputs[profile]['before']==outputs[profile]['after'],profile+' behavior tokens differ'
    for name in ('fault_lane_sample','fault_capture_edge'):assert outputs[profile][name]!=outputs[profile]['before'],'escaped real RTL sampling/edge fault'
lintcommand=[str(V),'--lint-only','--threads','1','--top-module','nds_io','-GROUTE_MIRROR=1','-Wno-fatal','rtl/ds/nds_io.sv','rtl/ds/nds_ram.sv']
lint=subprocess.run(lintcommand,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(OUT/'verilator-lint.log').write_bytes(lint.stdout);assert lint.returncode==0,lint.stdout.decode()
qlint={}
for name,args in [('qlint',['python3','tools/ds/qlint.py']),('qlint-apf',['python3','tools/ds/qlint.py','rtl/apf/apf_top.v'])]:
    p=subprocess.run(args,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(OUT/(name+'.log')).write_bytes(p.stdout);assert p.returncode==0,p.stdout.decode();qlint[name]={'exit':p.returncode,'sha256':sha(p.stdout)}
unchanged=['rtl/ds/nds_io_route.hex','rtl/ds/nds_io_route.mif','rtl/arm/arm9_mem.sv','rtl/arm/arm9_ram.sv','tools/fit/io_route/names.tcl','tools/fit/io_route/strict.tcl','tools/fit/io_route/collect.tcl','tools/fit/io_route/gate.py','tools/fit/q0/standard_clock.tcl','scripts/build_ds.sh']
hashes={}
for path in unchanged:
    actual=(ROOT/path).read_bytes();assert actual==subprocess.check_output(['git','show',BASE+':'+path],cwd=ROOT),path;hashes[path]=sha(actual)
fixture=json.loads((HERE/'fixtures/2172-metadata-map.json').read_text());mapfile=pathlib.Path(fixture['report']);assert sha(mapfile.read_bytes())==fixture['report_sha256']
gates=json.loads((ROOT/'build/rc16/gate-tests.json').read_text());assert len(gates['cases'])==20 and all(x['PASS']for x in gates['cases'])
result={'status':'PASS_ATTRS_ONLY_CURRENT_SOURCE_IDENTITY_AND_20_OFFLINE_FIXTURES','base':BASE,'before_sha256':sha(before.encode()),'after_sha256':sha(after.encode()),'exact_three_attribute_additions':True,'metadata_bits':{'route_lane':2,'route_envelope':3,'ram_reply_mirror':1},'attribute_omissions_caught':attribute_faults,'preprocessed_identity':records,'real_RTL_sampling_and_edge_mutants_caught':['fault_lane_sample','fault_capture_edge'],'verilator_lint':{'command':lintcommand,'exit':lint.returncode,'sha256':sha(lint.stdout)},'qlint':qlint,'unchanged':hashes,'actual2172_map_sha256':fixture['report_sha256'],'Gate_fixture_cases':20,'scope':'Attributes ignored in RTL execution; exact source and SIM/QIS token identity preserve c5 behavior. Vendor docs support preservation/inference semantics; actual native names/area/STA still require Root retry. No accepted1.3M simulation/CPU repeat, Quartus, fit, C++ build or heavy worker.'}
(OUT/'proof.json').write_text(json.dumps(result,indent=2)+'\n')
print(result['status'])
