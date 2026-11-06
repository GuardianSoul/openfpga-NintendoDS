#!/usr/bin/env python3
"""Actual full public flag/clock routing for the explicit reference profile."""
import datetime,hashlib,json,os,re,resource,runpy,subprocess
from pathlib import Path
R=Path(__file__).resolve().parents[3];B=R/'build/cull-mlab25/public';B.mkdir(parents=True,exist_ok=True)
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json');V='build/tools/oss-cad-suite/bin/verilator'
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
inv=runpy.run_path(str(R/'sim/pocket_ds/run.py'),run_name='inventory');files=[R/'rtl'/p for p in inv['RTL']]+[R/p for p in inv['SIM']]
files+=[R/'rtl'/p for p in ['arm/arm7_ds.sv','arm/arm7_stm4_owner.sv','arm/arm7_wram.sv','ds/nds_spi_mc.sv']];files+=sorted((R/'rtl/serv').glob('*.v'));files=list(dict.fromkeys(files))
w={'source_base':'9002ba2590ec05f2d9054dfb9625c1297da78cf5','actual_source_sha256':{str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest()for p in files},'controller_PID':os.getpid(),'stages':[],'cases':{}}
def save(): (B/'public.json').write_text(json.dumps(w,indent=2)+'\n')
def run(name,cmd):
 with(B/(name+'.log')).open('w')as log:
  p=subprocess.Popen(cmd,cwd=R,stdout=log,stderr=subprocess.STDOUT);d=json.loads(S.read_text());d['phase']='D1 cull25 '+name;d['worker']={'active':True,'host':'Desktop','PID':os.getpid(),'child_PID':p.pid,'lease':'D1 Root retained','nice':10,'jobs':1,'threads':1};d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=S.with_suffix('.Geometry22.tmp');text=json.dumps(d,separators=(',',':'))+'\n';assert len(text.encode())<=2048;t.write_text(text);t.replace(S)
  stage={'name':name,'PID':p.pid,'command':cmd};w['stages'].append(stage);save();stage['exit']=p.wait();stage['reaped']=True;save();assert stage['exit']==0,(name,(B/(name+'.log')).read_text()[-2000:])
def walk(x):
 if isinstance(x,dict):
  yield x
  for v in x.values():yield from walk(v)
 elif isinstance(x,list):
  for v in x:yield from walk(v)
def val(v):
 n=v['valuep'][0]['name'];z=re.fullmatch(r"\d+'s?([bdho])([0-9a-f_]+)",n);assert z,n;return int(z[2].replace('_',''),{'b':2,'d':10,'h':16,'o':8}[z[1]])
def route(path,enabled):
 js=json.loads(path.read_text());mods={m['addr']:m for m in js['modulesp']};root=next(m for m in mods.values()if m.get('origName')=='core_top');links={};rv={x['name']:x['addr']for x in root['stmtsp']if x['type']=='VAR'};roots={'clk':rv['clk_sys'],'clk_2x':rv['clk_2x'],'clk2':rv['clk_2x']};seen=[]
 def resolve(a):
  while a in links:a=links[a]
  return a
 def child(m,name,key=None,value=None):
  cells=[x for x in walk(m['stmtsp'])if x['type']=='CELL'and x.get('name')==name];assert len(cells)==1,(name,len(cells));c=cells[0]
  for pin in c.get('pinsp',[]):
   if pin['name']not in roots:continue
   e=pin['exprp'];assert len(e)==1 and e[0]['type']=='VARREF',f'disconnected clock {name}.{pin["name"]}'
   links[pin['modVarp']]=resolve(e[0]['varp']);assert resolve(pin['modVarp'])==roots[pin['name']],f'wrong clock {name}.{pin["name"]}'
  n=mods[c['modp']];ps={x['name']:val(x)for x in n.get('stmtsp',[])if x['type']=='VAR'and x.get('isParam')and x.get('valuep')}
  if key:assert ps[key]==value,f'wrong {name}.{key}: {ps[key]} expected{value}'
  seen.append({'instance':name,'module':n.get('origName'),'selected':{k:v for k,v in ps.items()if k in ['GX_CULL_MLAB','CULL_MLAB','SHARED4','STORE_PUMP','GX_CLIP_STORE_PUMP','CLIP_STORE_PUMP','GX_SCALAR_DIV_P2X','SCALAR_DIV_P2X','A9_DIRTY_MLAB','K','P2X','K4_P2X']}})
  return n
 m=root
 for n,k in [('ds','GX_CULL_MLAB'),('u_gpu3d','GX_CULL_MLAB'),('u_geom','GX_CULL_MLAB'),('u_eng','CULL_MLAB')]:m=child(m,n,k,int(enabled))
 eng=m
 clip=child(eng,'u_clip','STORE_PUMP',1);child(clip,'u_store')
 if enabled:
  cache=child(eng,'u_cache')
  cells=[x for x in walk(cache['stmtsp'])if x['type']=='CELL'and x.get('name')=='u_mem'];assert len(cells)==9,len(cells)
  for c in cells:
   assert mods[c['modp']].get('origName')=='gpu3d_gxcull_mlab32'
   pin=next(x for x in c['pinsp']if x['name']=='clk2');expr=pin['exprp'];assert len(expr)==1 and expr[0]['type']=='VARREF';assert resolve(expr[0]['varp'])==roots['clk2'],'replica FAST clock disconnected'
  seen.append({'logical_replicas':len(cells),'native_width_slices_each':[20,12],'capacity_per_slice':'32x20','physical_capacity_slices':18})
 else:assert not any(x['type']=='CELL'and x.get('name')=='u_cache'for x in walk(eng['stmtsp']))
 scalar=child(eng,'u_div','K4_P2X',1);child(scalar,'u_fast','P2X',1)
 return seen
base=[V,'--json-only','--timing','--assert','--threads','1','-j','1','-Wno-fatal','--timescale','1ns/1ps','--top-module','core_top','--Mdir',str(B/'obj'),'-I'+str(R/'rtl/pocket'),'-I'+str(R/'rtl/sound'),*map(str,files)]
for label,enabled,fault in [('enabled',1,None),('baseline-off',0,None),('flag-disconnect',1,'flag'),('clock-disconnect',1,'clock')]:
 cmd=base+['--json-only-output',str(B/(label+'.json')),'-GGX_CULL_MLAB='+str(enabled),'-GGX_CLIP_STORE_PUMP=1','-GGX_SCALAR_DIV_P2X=1','-GA9_DIRTY_MLAB=1']
 if fault:
  path=R/('rtl/ds/nds_gpu3d.sv'if fault=='flag'else'rtl/gpu3d/gpu3d_gxeng.sv');text=path.read_text()
  old,new=('.GX_CULL_MLAB(GX_CULL_MLAB)',".GX_CULL_MLAB(1'b0)")if fault=='flag'else('.clk2(clk_2x),.rf_we',".clk2(1'b0),.rf_we")
  assert text.count(old)==1;(B/(label+'.sv')).write_text(text.replace(old,new));cmd[cmd.index(str(path))]=str(B/(label+'.sv'))
 run(label,cmd)
 try:out=route(B/(label+'.json'),bool(enabled));caught=False;error=None
 except AssertionError as e:out=None;caught=True;error=str(e)
 assert caught==bool(fault),(label,error)
 if fault:assert ('u_geom.GX_CULL_MLAB'if fault=='flag'else'u_cache.clk2')in error,error
 w['cases'][label]={'caught':caught,'error':error,'route':out,'json_sha256':hashlib.sha256((B/(label+'.json')).read_bytes()).hexdigest()};save();print(label,'CAUGHT'if caught else'PASS',flush=True)
 # The full AST is disposable once its selected routes and digest are retained.
 (B/(label+'.json')).unlink()
run('full-cc',[('--cc'if x=='--json-only'else x)for x in base]+['-GGX_CULL_MLAB=1','-GGX_CLIP_STORE_PUMP=1','-GGX_SCALAR_DIV_P2X=1','-GA9_DIRTY_MLAB=1'])
for label,defs in [('apf-experiment',['+define+NDS_REFERENCE_CULL_MLAB','+define+NDS_MAIN_CLIP16_DIRTY']),('apf-baseline',['+define+NDS_MAIN_CLIP16_DIRTY']),('apf-default',[])]:run(label,[V,'-E','-I'+str(R/'rtl/apf'),*defs,str(R/'rtl/apf/apf_top.v')])
assert 'core_top #(.GX_CULL_MLAB(1), .GX_SCALAR_DIV_P2X(1), .GX_CLIP_STORE_PUMP(1), .A9_DIRTY_MLAB(1)) ic ('in(B/'apf-experiment.log').read_text()
assert 'core_top #(.GX_SCALAR_DIV_P2X(1), .GX_CLIP_STORE_PUMP(1), .A9_DIRTY_MLAB(1)) ic ('in(B/'apf-baseline.log').read_text()
assert 'core_top ic ('in(B/'apf-default.log').read_text()
run('qlint',['python3','tools/ds/qlint.py','rtl/gpu3d/gpu3d_gxvfin.sv','rtl/gpu3d/gpu3d_gxeng.sv','rtl/gpu3d/gpu3d_geom.sv','rtl/ds/nds_top.sv','rtl/ds/nds_gpu3d.sv','rtl/pocket/core_top_ds.sv'])
w['status']='PASS actual public cull flags/clocks/9replicas/clip16/scalar14, fullcc+qlint; area not yet measured';save();d=json.loads(S.read_text());d['worker']['active']=False;d['phase']='cull25 public/fullcc/qlint done; native/source strict receipt next';t=S.with_suffix('.Geometry22.tmp');t.write_text(json.dumps(d,separators=(',',':'))+'\n');t.replace(S);print(w['status'],flush=True)
