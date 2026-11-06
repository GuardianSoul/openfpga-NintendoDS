"""Elaborate the actual vm34 Root->DS->GPU->record PACK route, plus a dropped-PACK fault."""
from pathlib import Path
import collections,gzip,hashlib,importlib.util,json,os,re,resource,subprocess,time

r=Path(__file__).resolve().parents[2];out=r/'build/record-pack34/route';out.mkdir(parents=True,exist_ok=True)
sim=Path('/home/user/Git/NDS_Pocket-codex-raster/build/gpu3d/ac33-final-prepared/source')
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
spec=importlib.util.spec_from_file_location('source_list',sim/'sim/pocket_ds/run.py');source_list=importlib.util.module_from_spec(spec);spec.loader.exec_module(source_list)
v=Path('build/tools/oss-cad-suite/bin/verilator');sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
config=json.loads(subprocess.check_output(['git','show','15655ceb:docs/results/provisional-vm34-20261101/configuration.json'],cwd=r))['profile']
def walk(node):
    if isinstance(node,dict):
        yield node
        for x in node.values():yield from walk(x)
    elif isinstance(node,list):
        for x in node:yield from walk(x)
def params(mod):
    result={}
    for x in mod.get('stmtsp',[]):
        a=x.get('valuep',[])
        if x.get('isParam') and len(a)==1 and a[0]['type']=='CONST':
            m=re.fullmatch(r"(\d+)'s?([hbd])([0-9a-fA-F]+)",a[0]['name'])
            if m:result[x['name']]=int(m[3],{'h':16,'b':2,'d':10}[m[2]])
    return result
def inspect(tree):
    mods={m['addr']:m for m in tree['modulesp']}
    roots=[m for m in mods.values() if m.get('origName')=='core_top'];assert len(roots)==1
    root=roots[0];assert all(params(root).get(k)==v for k,v in config.items()),'vm34 Root defaults differ'
    result=[];mod=root
    for target,key,value in [('nds_top','G3D_RECORD_RAM',1),('nds_gpu3d','RECORD_RAM',1),('nds_g3d_record_ram','PACK',1)]:
        found=[(c,mods[c['modp']]) for c in walk(mod.get('stmtsp',[])) if c.get('type')=='CELL' and mods[c['modp']].get('origName')==target]
        assert len(found)==1,('missing/ambiguous actual instance',target)
        cell,mod=found[0];actual=params(mod).get(key);assert actual==value,('actual PACK route differs',target,key,actual)
        result.append({'cell':cell['name'],'module':target,'parameter':key,'value':actual})
    dims=collections.Counter()
    for cell in walk(mod.get('stmtsp',[])):
        if cell.get('type')=='CELL' and mods[cell['modp']].get('origName')=='gpu3d_ram':
            p=params(mods[cell['modp']]);dims[(p['W'],p['AW'])]+=1
    assert dims==collections.Counter({(32,14):3,(25,12):1,(20,12):3}),('physical packing inactive',dims)
    return {'Root_vm34_defaults':len(config),'Root_G3D_RECORD_RAM':params(root)['G3D_RECORD_RAM'],'actual_chain':result,'actual_RAMs':[{'W':w,'AW':a,'copies':n}for(w,a),n in sorted(dims.items())]}
results=[]
for case in ['candidate','dropped-PACK']:
    subprocess.run(['uptime'],check=True)
    ps=subprocess.check_output(['ps','-eo','pid,comm,stat'],text=True)
    heavy=[x for x in ps.splitlines()[1:] if len(x.split())==3 and not x.split()[2].startswith(('T','Z')) and(x.split()[1].startswith(('Vtb','Vnds','verilator_bin'))or x.split()[1]=='cc1plus')]
    print('actual workers',heavy,flush=True);assert len(heavy)<3
    dest=out/case;dest.mkdir(exist_ok=True);files=[r/'rtl'/x for x in source_list.RTL]+[sim/x for x in source_list.SIM]
    if case=='dropped-PACK':
        s=(r/'rtl/ds/nds_gpu3d.sv').read_text();old=".PACK(1'b1)";assert s.count(old)==1
        mutant=dest/'nds_gpu3d.sv';mutant.write_text(s.replace(old,".PACK(1'b0)"));files=[mutant if x==r/'rtl/ds/nds_gpu3d.sv' else x for x in files]
    raw=dest/'tree.json'
    cmd=[v,'--json-only','--timing','--threads','1','-Wno-fatal','--timescale','1ns/1ps','--top-module','tb_ds_pocket','--json-only-output',raw,'--Mdir',dest/'obj','-I'+str(r/'rtl/pocket'),'-I'+str(r/'rtl/sound'),*files]
    with(dest/'elaboration.log').open('w')as log:
        proc=subprocess.Popen(list(map(str,cmd)),stdout=log,stderr=subprocess.STDOUT,cwd=r)
        rec={'case':case,'PID':proc.pid,'NI':os.getpriority(os.PRIO_PROCESS,proc.pid),'argv':list(map(str,cmd)),'files_sha256':{str(p):sha(p)for p in files}}
        print('OWN route PID',proc.pid,case,flush=True);rc=proc.wait(timeout=180)
    assert rc==0,(dest/'elaboration.log').read_text()[-2800:]
    tree=json.loads(raw.read_text());rec['tree_sha256']=sha(raw)
    try:
        rec['route']=inspect(tree);assert case=='candidate','dropped-PACK mutant escaped'
    except AssertionError as e:
        assert case=='dropped-PACK' and 'actual PACK route differs' in str(e),str(e)
        rec['actual_RTL_mutant_caught']=str(e)
    del tree
    with raw.open('rb')as f,gzip.open(dest/'tree.json.gz','wb')as z:
        while chunk:=f.read(1024*1024):z.write(chunk)
    raw.unlink();results.append(rec);(out/'route.json').write_text(json.dumps({'status':'PASS'if len(results)==2 else'candidate_pass_mutant_pending','scope':'Actual Root34 defaults and resolved instance parameters/RAM dimensions, no model/game run. No new public enable.','results':results},indent=2)+'\n')
print('PASS actual Root34->DS->GPU->PACK1 physical RAM route; actual dropped-PACK RTL mutant caught; children terminal',flush=True)
