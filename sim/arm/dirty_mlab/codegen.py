#!/usr/bin/env python3
"""Full enabled main source codegen and actual parameter-route fault."""
from pathlib import Path
import json,hashlib,subprocess,os,shutil,resource
R=Path(__file__).resolve().parents[3];D=R/'build/main-dirty-codegen';D.mkdir(parents=True,exist_ok=True);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
script=(R/'sim/pocket_ds/run.py').read_text();scope={};exec(script[script.index('RTL = '):script.index('\n\n',script.index('SIM = '))],scope)
# Static simulation list omits modules selected by main's default profile.
# Supplement with the existing production build_ds.sh inventory, not source edits.
extra=['arm/arm7_ds.sv','arm/arm7_wram.sv','ds/nds_spi_mc.sv','pocket/nds_cart_scpu.sv','pocket/nds_mbox.sv','pocket/nds_apf_wr.sv','pocket/nds_controls_fw.sv']+['serv/'+p.name for p in (R/'rtl/serv').glob('*.v')]
files=list(dict.fromkeys(['rtl/'+p for p in scope['RTL']+extra]+scope['SIM']));headers=[str(p.relative_to(R)) for root in ['rtl','sim'] for p in (R/root).rglob('*') if p.is_file() and p.suffix in ['.svh','.vh']];hashes={}
for f in dict.fromkeys(files+headers):
 q=D/f;q.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(R/f,q);hashes[f]=hashlib.sha256(q.read_bytes()).hexdigest()
base=subprocess.check_output(['git','rev-parse','2c4e980c'],cwd=R,text=True).strip()
r={'base':base,'sha256':hashes,'inventory_sha256':hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest(),'PID':os.getpid(),'NI':10,'jobs':1,'threads':1,'flag':'A9_DIRTY_MLAB=1','stages':[]}
V=Path('build/tools/oss-cad-suite/bin/verilator')
cmd=[V,'--cc','--timing','--assert','--threads','1','-j','1','-Wno-fatal','--timescale','1ns/1ps','--top-module','core_top','-GA9_DIRTY_MLAB=1','--Mdir',D/'obj','-I'+str(D/'rtl/pocket'),'-I'+str(D/'rtl/sound'),*[D/f for f in files]]
def run(name,cmd):
 with (D/(name+'.log')).open('w') as log:
  p=subprocess.Popen(list(map(str,cmd)),stdout=log,stderr=subprocess.STDOUT);row={'name':name,'PID':p.pid,'command':list(map(str,cmd))};r['stages'].append(row);(D/'receipt.json').write_text(json.dumps(r));row['exit']=p.wait(timeout=120);row['reaped']=True
 assert row['exit']==0,(name,(D/(name+'.log')).read_text()[-2000:])
 return '\n'.join(f.read_text() for f in Path(cmd[cmd.index('--Mdir')+1]).iterdir() if f.suffix in ['.cpp','.h'])
text=run('enabled',cmd);needle='g_dirty_mlab__DOT__way';assert needle in text,'enabled dirty bank route missing'
r['enabled_route_symbols']=[l.strip()[:400] for l in text.splitlines() if needle in l][:8]
# Mutate only the new main caller parameter binding. No accepted CPU edits.
f=D/'rtl/arm/arm_cpu.sv';src=f.read_text();old='.DIRTY_MLAB(ARM9_DIRTY_MLAB)';assert src.count(old)==1;f.write_text(src.replace(old,".DIRTY_MLAB(1'b0)",1));r['route_mutant_sha256']=hashlib.sha256(f.read_bytes()).hexdigest()
cmd[cmd.index('--Mdir')+1]=D/'faultobj';text=run('route-fault',cmd);assert needle not in text,'route fault not caught';r['route_fault']='CAUGHT enabled bank symbols absent after actual binding mutation'
f.write_text(src);r['status']='PASS_ENABLED_MAIN_FULL_CODEGEN_AND_CAUGHT_ROUTE_FAULT';r['generated_bytes']=sum(f.stat().st_size for d in ['obj','faultobj'] for f in (D/d).iterdir() if f.is_file());(D/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(r['status'],r['inventory_sha256'],flush=True)
