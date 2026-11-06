#!/usr/bin/env python3
"""Check the public scalar-divider profile, selected hierarchy and clocks."""
from pathlib import Path
import hashlib,json,os,re,runpy,subprocess
R=Path(__file__).resolve().parents[3];D=R/'build/scalar14-public';D.mkdir(parents=True,exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10)
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=runpy.run_path(str(R/'sim/pocket_ds/run.py'),run_name='inventory')
files=[R/'rtl'/p for p in m['RTL']]+[R/p for p in m['SIM']]
# Full current main enables dedicated ARM7, microcoded SPI and SERV.
files += [R/'rtl'/p for p in ['arm/arm7_ds.sv','arm/arm7_stm4_owner.sv','arm/arm7_wram.sv','ds/nds_spi_mc.sv']]
files += sorted((R/'rtl/serv').glob('*.v'))
v='build/tools/oss-cad-suite/bin/verilator'
base=[v,'--cc','--timing','--assert','--threads','1','-j','1','-Wno-fatal','--timescale','1ns/1ps','--top-module','core_top','--Mdir',str(D/'obj'),'-I'+str(R/'rtl/pocket'),'-I'+str(R/'rtl/sound'),*map(str,files)]
w={'owner':'Root','PID':os.getpid(),'host':os.uname().nodename,'lease':'DesktopD2 returned Geometry','NI':10,'jobs':1,'threads':1,'active':True,'source_base':subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),'source_hashes':{str(p.relative_to(R)):H(p)for p in files},'stages':[]}
def save():
 p=D/'worker.json';t=p.with_suffix('.tmp');t.write_text(json.dumps(w,indent=2)+'\n');t.replace(p)
def run(name,cmd):
 with (D/(name+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=R,stdout=log,stderr=subprocess.STDOUT);s={'name':name,'PID':p.pid,'cmd':cmd};w['stages'].append(s);save();s['exit']=p.wait();s['reaped']=True;save();assert s['exit']==0,(name,(D/(name+'.log')).read_text()[-1500:])
def walk(x):
 if isinstance(x,dict):
  yield x
  for v in x.values():yield from walk(v)
 elif isinstance(x,list):
  for v in x:yield from walk(v)
def val(v):
 n=v['valuep'][0]['name'];z=re.fullmatch(r"\d+'s?([bdho])([0-9a-f_]+)",n);assert z,n;return int(z[2].replace('_',''),{'b':2,'d':10,'h':16,'o':8}[z[1]])
def route(p,enabled):
 js=json.loads(p.read_text());mods={x['addr']:x for x in js['modulesp']};m=next(x for x in mods.values()if x.get('origName')=='core_top');links={};seen=[]
 def resolve(a):
  while a in links:a=links[a]
  return a
 rv={x['name']:x['addr']for x in m['stmtsp']if x['type']=='VAR'};clocks={'clk':rv['clk_sys'],'clk_2x':rv['clk_2x'],'clk2':rv['clk_2x']}
 for name,key in [('ds','GX_SCALAR_DIV_P2X'),('u_gpu3d','GX_SCALAR_DIV_P2X'),('u_geom','GX_SCALAR_DIV_P2X'),('u_eng','SCALAR_DIV_P2X'),('u_div','K4_P2X')]:
  cells=[x for x in walk(m['stmtsp'])if x['type']=='CELL'and x.get('name')==name];assert len(cells)==1,(name,len(cells));c=cells[0]
  for pin in c.get('pinsp',[]):
   if pin['name'] not in clocks:continue
   e=pin['exprp'];assert len(e)==1 and e[0]['type']=='VARREF',(name,pin['name']);links[pin['modVarp']]=resolve(e[0]['varp']);assert resolve(pin['modVarp'])==clocks[pin['name']],f'wrong {name}.{pin["name"]} clock'
  m=mods[c['modp']];ps={x['name']:val(x)for x in m.get('stmtsp',[])if x['type']=='VAR'and x.get('isParam')and x.get('valuep')and x['name']in [key,'K','PU']};assert ps[key]==int(enabled),f'wrong {name}.{key}'
  seen.append({'instance':name,'module':m.get('origName'),'params':ps})
 cells=[x for x in walk(m['stmtsp'])if x['type']=='CELL'and x.get('name')=='u_fast']
 assert bool(cells)==enabled,'wrong selected scalar helper'
 if enabled:
  assert len(cells)==1;helper=mods[cells[0]['modp']];ps={x['name']:val(x)for x in helper.get('stmtsp',[])if x['type']=='VAR'and x.get('isParam')and x.get('valuep')and x['name']in ['P2X','SYS_Q','K']};assert ps=={'P2X':1,'SYS_Q':1,'K':4},ps;seen.append({'helper':ps})
 return seen
cases={}
for label,flag,mutant in [('enabled',1,None),('default-off',0,None),('disconnected',1,True)]:
 cmd=['--json-only' if x=='--cc'else x for x in base]+['--json-only-output',str(D/(label+'.json')),'-GGX_SCALAR_DIV_P2X='+str(flag)]
 if mutant:
  path=R/'rtl/ds/nds_gpu3d.sv';s=path.read_text();needle='.GX_SCALAR_DIV_P2X(GX_SCALAR_DIV_P2X)';assert s.count(needle)==1;s=s.replace(needle,".GX_SCALAR_DIV_P2X(1'b0)");p=D/'disconnected.sv';p.write_text(s);cmd[cmd.index(str(path))]=str(p)
 run(label,cmd)
 try:r=route(D/(label+'.json'),bool(flag));caught=False;error=None
 except AssertionError as e:r=None;caught=True;error=str(e)
 assert caught if mutant else not caught,(label,error)
 if mutant:assert 'wrong u_geom.GX_SCALAR_DIV_P2X'in error,error
 cases[label]={'route':r,'caught':caught,'error':error,'json_SHA256':H(D/(label+'.json'))}
 print(label,'CAUGHT'if caught else'PASS',flush=True)
run('full-cc',base+['-GGX_SCALAR_DIV_P2X=1'])
for label,defs in [('apf-enabled',['+define+NDS_GX_SCALAR_P2X']),('apf-default',[])]:run(label,[v,'-E','-I'+str(R/'rtl/apf'),*defs,str(R/'rtl/apf/apf_top.v')])
assert 'core_top #(.GX_SCALAR_DIV_P2X(1)) ic ('in (D/'apf-enabled.log').read_text()
assert 'core_top ic ('in (D/'apf-default.log').read_text()
assert "echo 'set_global_assignment -name VERILOG_MACRO NDS_GX_SCALAR_P2X'"in (R/'scripts/build_ds.sh').read_text()
w.update(active=False,reaped=True,status='PASS public0/1 selected-clock hierarchy, actual disconnected-source mutant, enabled fullcc and APFprofile',cases=cases);save();print(w['status'],flush=True)
