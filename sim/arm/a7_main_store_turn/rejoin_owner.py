#!/usr/bin/env python3
"""One allocated worker, sequential physical-owner gates and actual faults."""
from pathlib import Path
import hashlib, importlib.util, json, shutil

ROOT=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('worker',ROOT/'sim/arm/a7_main_store_turn/run.py');w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
w.OUT=ROOT/'build/a7-if-rejoin-owner';w.OUT.mkdir(exist_ok=True)
source=(ROOT/'rtl/ds/nds_arm7_port.sv').read_text()
variants=[('enabled',source,1,None),('default',source,0,None),
 ('fault-generation',source.replace('&& rp_stale && rp_rejoin_window','&& rp_stale'),1,'stale generation adopted after repeated redirect'),
 ('fault-target',source.replace('.wdata(f_rdata), .raddr({il_hit1',".wdata(f_rdata ^ ((rejoin_now || rejoin_live) ? 32'd1 : 32'd0)), .raddr({il_hit1"),1,'adopted target payload mismatch'),
 ('fault-freshness',source.replace('&& !rp_bad && !il_kill && !il_lookup_kill && !i_redirect;', '&& !il_lookup_kill && !i_redirect;'),1,'unfresh or wrong-target owner adopted')]
result={}
for name,body,option,fault in variants:
 if fault:assert body!=source,name
 d=w.OUT/name;d.mkdir(exist_ok=True);(d/'nds_arm7_port.sv').write_text(body)
 rels=['rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','sim/phase1/sim_prims.sv']
 for rel in rels:shutil.copyfile(ROOT/rel,d/Path(rel).name)
 shutil.copyfile(ROOT/'sim/arm/a7_main_store_turn/tb_rejoin.sv',d/'tb_rejoin.sv')
 files=sorted(d.glob('*.sv'));(d/'inputs.json').write_text(json.dumps({p.name:w.sha(p)for p in files},indent=2)+'\n')
 model=d/'obj/Vtb_rejoin'
 w.call([w.V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal',f'+define+REJOIN={option}',
         '--top-module','tb_rejoin','--Mdir',model.parent,*files],d,'build');w.prune(model.parent)
 text=w.call([model],d,'run',fault)
 if not fault:assert'REJOIN_OWNER_PASS cases12'in text
 result[name]=dict(model_sha256=w.sha(model),verdict=fault or 'PASS12',run_sha256=w.sha(d/'run.log'))
 (w.OUT/'summary.json').write_text(json.dumps(result,indent=2)+'\n');print('REJOIN_DONE',name,result[name]['verdict'],flush=True)
w.status('REJOIN owner terminal PASS;12cases +3 actual RTL faults')
