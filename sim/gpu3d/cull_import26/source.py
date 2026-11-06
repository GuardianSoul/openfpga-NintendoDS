#!/usr/bin/env python3
"""Source scope and schema guard for the cull25 simulation-only import fix."""
import hashlib,importlib.util,json,subprocess
from pathlib import Path
R=Path(__file__).resolve().parents[3]
BASE='045691e776b2d0a64be4d2d32b3407c447f7a483'
def old(p):return subprocess.check_output(['git','show',BASE+':'+p],cwd=R,text=True)
p='sim/pocket_ds/runtime_import_gx_context.svh';before=old(p);after=(R/p).read_text()
after=after.replace('`include "runtime_import_cull_cache.svh"\n','').replace(' cull_import_preflight(context_data[2500:2511],held);\n','')
start=before.index(' `RUNTIME_GEOMETRY.u_eng.g_pu.cpw[0]=');end=before.index(' `RUNTIME_GEOMETRY.u_eng.g_pu.cs=',start)
after=after.replace(' cull_import_words(context_data[2500:2511],held);\n',before[start:end])
start=before.index(' assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cpw[0])');end=before.index(' assert($unsigned(`RUNTIME_GEOMETRY.u_eng.g_pu.cs)',start)
after=after.replace(' cull_verify_words(context_data[2500:2511]);\n',before[start:end]);assert after==before,'context edits outside cull twelve-word ABI'
unchanged=['sim/ds/runtime_gx_context.py','sim/ds/runtime_gx_context.sources.json','sim/pocket_ds/runtime_import_clip_store.svh','sim/pocket_ds/runtime_import_finalize_snapshots.svh','sim/pocket_ds/runtime_import_finalize_groups.svh']
unchanged += [str(p.relative_to(R))for p in (R/'rtl/gpu3d').glob('*.sv')]
for p in unchanged:assert (R/p).read_text()==old(p),p
path=R/'sim/ds/runtime_cull_context.py';spec=importlib.util.spec_from_file_location('adapter',path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
assert module.TARGET.read_text()==module.render()
rec={'source':BASE,'context_schema_words':2632,'only_remapped_words':list(range(2500,2512)),'replicas':9,'mapped_cells':36,'pending_policy':'preserve all101bits; pre-M active snapshot must agree with logical post-SYS canonical word; post-M stale valid ignored','unchanged_sha256':{p:hashlib.sha256((R/p).read_bytes()).hexdigest()for p in unchanged},'verdict':'PASS_CULL_IMPORT_SOURCE_SCOPE'}
d=R/'build/cull-import26';d.mkdir(parents=True,exist_ok=True);(d/'source.json').write_text(json.dumps(rec,indent=2)+'\n');print(rec['verdict'])
