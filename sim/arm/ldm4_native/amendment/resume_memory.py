#!/usr/bin/env python3
"""Retain strict quiet-state failure and finish only the requested memory control."""
from pathlib import Path
import argparse,ast,datetime,hashlib,importlib.util,json,os,re,resource,shutil,signal,subprocess,sys,time
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);a=p.parse_args();D=a.directory.resolve();plan=json.loads((D/'plan.json').read_text());P=D/'common';U=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json');frozen=json.loads((D/'frozen.json').read_text())
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));result=json.loads((D/'results.json').read_text())
assert result['failure'].startswith("AssertionError(('ds30', 4544, 69")and 'ACK1/unitmem'not in result['runs'],result.get('failure')
shutil.copy2(D/'results.json',D/'results-strict-state-failure.json')
result['strict_state_failure']=result.pop('failure');result['previous_controller']={'PID':result['controller'],'starttime':result['controller_starttime']}
# Reuse the exact frozen subprocess/guard functions, without importing or
# executing its top-level build/run loop. No model/guest is rebuilt or replayed.
tree=ast.parse((D/'amendment/run_amended.py').read_text());functions=[x for x in tree.body if isinstance(x,(ast.FunctionDef,ast.AsyncFunctionDef))]
exec(compile(ast.Module(body=functions,type_ignores=[]),str(D/'amendment/run_amended.py'),'exec'),globals())
result.update(controller=os.getpid(),controller_starttime=ident(os.getpid()))
B=D/'ACK1/runs/ds30';text=(B/'run.log').read_text();match=re.search(r'LDM4_NATIVE_ACTIVITY words(\d+) lists(\d+) admissions(\d+) physicalACKs(\d+) returns(\d+) heldedges(\d+) legacyhitoffers(\d+) pending([01]) listlive([01]) physical([01])',text);assert match
stats=dict(zip(['words','lists','admissions','physical_ACKs','returns','held_edges','legacy_hit_offers','pending','list_live','physical_live'],map(int,match.groups())))
assert stats['words']==28160 and stats['lists']==7040 and stats['admissions']==stats['physical_ACKs']==stats['words']and not any(stats[k]for k in ['pending','list_live','physical_live'])
guards=json.loads((B/'scoped-guards.json').read_text());state=json.loads((B/'state-differences.json').read_text());assert state['all_words_exact']and state['full_state_equivalence']is False
quiet={'guards':guards,'values':[int(x['arm7_cycles_per_op_x100'])for x in guards['rows']],'activity':stats,'state_differences':state,'full_state_equivalence':False,'verdict':'FAIL enabled promotion: quiet timing widens; IRQbankedstate mismatch unresolved','words_SHA256':H(B/'ldm4.words'),'state_SHA256':H(B/'ldm4.state'),'edges_SHA256':H(B/'ldm4.edges')};save(B/'checked.json',quiet)
result['runs']['ACK1/ds30']={'checked_SHA256':H(B/'checked.json'),'activity':stats,'values':quiet['values'],'full_state_equivalence':False,'verdict':quiet['verdict']}
v=plan['variants']['ACK1'];V=D/'ACK1';model=V/'model/Vtb_ds_pocket';assert H(model)==result['models']['ACK1']['SHA256']=='f13af846fec529431ef71833dd2eeffb0b3adefca7cfca7680e1ad1d8a0ed587'
guest='unitmem';g=plan['guests'][guest];B=V/'runs'/guest;W=B/'run';W.mkdir(parents=True,exist_ok=False);shutil.copytree(P/'runtime',W,dirs_exist_ok=True)
rom=(P/'roms/unitmem.nds').read_bytes();assert hashlib.sha256(rom).hexdigest()==g['ROM_SHA256'];rom+=bytes(-len(rom)%4);(W/'rom.hex').write_text(''.join('%08x\n'%int.from_bytes(rom[i:i+4],'little')for i in range(0,len(rom),4)))
cmd=[model,f'+rom={W}/rom.hex',f'+romsize={(P/"roms/unitmem.nds").stat().st_size}',f'+bios9={W}/bios9.hex',f'+bios7={W}/bios7.hex',f'+fw={W}/firmware.hex',f'+boot={W}/boot.hex','+fwsize=262144','+frames='+str(g['frames']),'+timeout_ms='+str(g['simulated_ms']),'+vmcheck','+g3dperf','+progress',f'+ldm4_observe={B}/ldm4','+stop_done=1']
manifest={'source':v['source'],'profile':v['profile'],'model_sha256':H(model),'ROM_sha256':g['ROM_SHA256'],'expanded_sha256':{x.name:H(x)for x in W.iterdir()if x.is_file()},'argv':list(map(str,cmd)),'cwd':str(W),'scope':'Already-authorized negative memory control only; strict quiet-state failure preserved; no enabled acceptance.'};save(B/'manifest.json',manifest)
try:
 call(cmd,W,B/'run.log','ACK1-unitmem',g['wall_seconds']);assert H(model)==manifest['model_sha256'];checked=analyze('ACK1','unitmem',B);result['runs']['ACK1/unitmem']={'checked_SHA256':H(B/'checked.json'),'activity':checked['activity'],'values':checked['values']}
 result['enabled_promotion']='FAIL quiet timing and unresolved IRQbankedstate mismatch';status('COMPLETE amended affected reference native; ACK1 promotionFAIL; strict quiet-state mismatch retained');print(result['enabled_promotion'],flush=True)
except BaseException as exc:result['failure']=repr(exc);status('STOPPED memory-control failure; enabled promotion remainsFAIL');raise
