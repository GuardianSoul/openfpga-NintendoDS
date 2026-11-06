#!/usr/bin/env python3
"""Gated NI10/j1/t1 host component, with atomic coordinator status."""
import argparse, datetime, hashlib, importlib.util, json, os, re, resource, subprocess, sys, time
from pathlib import Path
STATUS=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/hwref.json')

def write(p,v):
 t=p.with_suffix(p.suffix+'.tmp');t.write_text(json.dumps(v,indent=2)+'\n');os.replace(t,p)
def identity():
 return dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],nice=os.getpriority(os.PRIO_PROCESS,0))
def status(phase,controller,child=None):
 d=json.loads(STATUS.read_text());d.update(updated_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),phase=phase,worker=dict(host='Desktop',active=int(child is not None),controller=controller,child=child))
 assert len(json.dumps(d,indent=2).encode())+1<=2048;write(STATUS,d)
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--child');a=p.parse_args();out=a.out.resolve()
 os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
 if a.child:
  write(out/(a.child+'.child.json'),identity())
  while not(out/(a.child+'.release')).exists():time.sleep(.05)
  cmd=json.loads((out/'plan.json').read_text())[a.child];os.execvpe(cmd[0],cmd,os.environ)
 controller=identity();write(out/'controller.json',controller)
 while not(out/'controller.release').exists():time.sleep(.05)
 spec=importlib.util.spec_from_file_location('compact_native_guard',out/'native_guard.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
 expected={int(k):v for k,v in json.loads((out/'source.json').read_text())['synthetic_transport_payload_from_retained_native60_values'].items()}
 results={}
 try:
  for name in json.loads((out/'plan.json').read_text()):
   assert not(out/(name+'.child.json')).exists(),'use a fresh prepared component directory'
   with(out/(name+'.log')).open('w')as log:
    child=subprocess.Popen([sys.executable,__file__,'--out',str(out),'--child',name],cwd=out,stdout=log,stderr=subprocess.STDOUT)
    while not(out/(name+'.child.json')).exists():
     assert child.poll()is None;time.sleep(.05)
    info=json.loads((out/(name+'.child.json')).read_text());assert info['nice']==10
    write(out/'active.json',dict(phase=name,controller=controller,child=info))
    status('Compact ABI1 component '+name,controller,info)
    (out/(name+'.release')).touch();started=time.monotonic();rc=child.wait();elapsed=time.monotonic()-started
   text=(out/(name+'.log')).read_text();r=dict(exit=rc,child=info,reaped=True,seconds=elapsed)
   results[name]=r;write(out/'results.json',results)
   if name.startswith('compile_'):
    assert rc==0,(name,text[-5000:]);model=out/('obj_'+name[8:])/'Vtb_component';r['component_sha256']=hashlib.sha256(model.read_bytes()).hexdigest()
   elif name in ['wram_deposit','model_error','missing_version']:
    marker={'wram_deposit':'COMPACT_WRAM_PRIVATE_READBACK word0','model_error':'model, video or FIFO errors','missing_version':'COMPACT_HOST_VERSION_REQUIRED'}[name]
    assert rc!=0 and marker in text,(name,rc,text[-2500:]);r['caught']=marker
   else:
    assert rc==0,(name,text[-3500:]);assert text.count('Verilog $finish')==1
    if name in ['native','value_address','vm_response']:
     r['guards']=mod.validate(text,22,'unita7');r['data_exact']=r['guards']['values']==expected
     if name=='native':assert r['guards']['accepted'] and r['data_exact'],r
     elif name=='value_address':assert not r['guards']['accepted'] and not r['data_exact'];r['caught']='actual ram_word value address increment'
     else:assert not r['guards']['VM'] and not r['guards']['no_errors'];r['caught']='actual VM returned word differs from shadow'
    if name in ['ordinary','import']:
     assert re.search(r'^PASS$',text,re.M) and 'video: 3 frames, 0 errors' in text and not re.search(r'^value ',text,re.M)
    if name=='ordinary':assert 'COMPONENT_NONIMPORT_INTERNAL_WRAM_UNTOUCHED_PASS'in text and 'COMPACT_HOST_ABI1_PROFILE_PASS'not in text and 'clean-boot:'not in text
    if name=='import':assert 'COMPACT_WRAM_IMPORT_READBACK_PASS'in text and 'COMPONENT_IMPORT_EXTERNAL24576_AND_CPU_ENDPOINTS_PASS'in text and 'clean-boot:'not in text
    if name=='native':assert 'video: 1 frames, 0 errors'in text and 'COMPONENT_CLEAN_EXACT_MAIN1048576_VRAM167936_PASS'in text and 'COMPACT_WRAM_IMPORT_READBACK_PASS'not in text
   write(out/'results.json',results)
  write(out/'complete.json',dict(results=results,default_enable=False,game_or_full_core_executions=0,original_image_executions=0,new_DS_measurements=0))
  status('Compact ABI1 component qualification PASS; preparing receipt',controller)
  print('COMPACT_ABI1_COMPONENT_QUALIFICATION_PASS',flush=True)
 except Exception:
  status('Compact ABI1 component stopped; local fixture/source diagnosis next',controller)
  raise
 finally:write(out/'active.json',dict(phase='complete'if(out/'complete.json').exists()else'stopped',controller=controller,child=None,all_owned_children_reaped=True))
if __name__=='__main__':main()
