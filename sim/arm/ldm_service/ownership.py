#!/usr/bin/env python3
"""One worker: real-chip cache poison/owner/reset checks and route elaboration."""
from pathlib import Path
exec(compile(Path(__file__).with_name('run.py').read_text().split("names=")[0],str(Path(__file__).with_name('run.py')),'exec'))
V='build/tools/oss-cad-suite/bin/verilator'
qualified=json.loads((G/'qualified.json').read_text())
for p,h in qualified['source'].items():assert sha(p)==h
results={}
for name in ['ownership','stale-mutant']:
 d=G/name;d.mkdir(exist_ok=True);inputs=[]
 for f in FILES[8:]:
  b=(R/f).read_bytes()
  if name=='stale-mutant'and f=='rtl/ds/nds_fabric.sv':
   old=b"if (mon_we && mon_addr[31:24] == 8'h02)";assert b.count(old)==1;b=b.replace(old,b"if (1'b0 && mon_we && mon_addr[31:24] == 8'h02)")
  p=d/f;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b);inputs.append(p)
 for f in ['transport_ownership.sv','tb_ownership.sv']:
  p=d/f;p.write_bytes((R/'sim/arm/ldm_service'/f).read_bytes());inputs.append(p)
 model=d/'Vtb_ownership';call([V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_ownership','--Mdir',d,*inputs],d/'build.log')
 record(d/'model.json',dict(sha256=sha(model),inputs={str(p):sha(p)for p in inputs}))
 rc=call([model],d/'run.log',name!='ownership');t=(d/'run.log').read_text()
 if name=='ownership':assert'SERVICE_OWNERSHIP_PASS'in t and'OPPOSING_ARM7_PROGRESS'in t,(rc,t[-2000:])
 else:assert rc!=0 and'ownership independent DATA mismatch'in t and'timeout'not in t.lower(),(rc,t[-2000:])
 results[name]=dict(exit=rc,summary=[x for x in t.splitlines()if'OWNERSHIP_PASS'in x or'OPPOSING_ARM7_PROGRESS'in x or'ownership independent DATA mismatch'in x])
 for p in d.iterdir():
  if p.is_file()and p.suffix!='.sv'and p.name not in ['Vtb_ownership','build.log','run.log','model.json']:p.unlink()
 print(name,results[name],flush=True)
# All existing shared/dedicated CPU domain routes with the new forwarding
# parameter explicitly enabled; metadata/CDC width is unchanged.
arm=[R/'rtl/arm'/(f+'.sv')for f in 'arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu arm7_ds cpu_domain cdc_req cdc_fifo cdc_a7'.split()]+[R/p for p in ['rtl/ds/nds_ram.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_lcache.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/gpu2d/gpu2d_ram.sv']]
routes=[]
for fast in [0,1]:
 for solo in [1,3,5]:
  call([V,'--lint-only','--timing','--assert','-Wno-fatal','--top-module','cpu_domain','-GA9_LDM_BASE_FORWARD=1',f'-GCPU_FAST={fast}',f'-GA9_SOLO={solo}',*arm],G/f'route-fast{fast}-solo{solo}.log');routes.append([fast,solo])
record(G/'ownership.json',dict(results=results,routes=routes,source={p:sha(p)for p in qualified['source']},public_routes={p:sha(R/p)for p in ['rtl/arm/cpu_domain.sv','rtl/ds/nds_top.sv']}))
print('OWNERSHIP_POISON_CANCEL_ROUTES_PASS',flush=True)
