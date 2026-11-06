from pathlib import Path
import os,json,subprocess,hashlib,shutil,socket
from sim_ownership import belongs_to_nds
from check import check
from check_window import check_window
R=Path(__file__).resolve().parent;os.setpriority(os.PRIO_PROCESS,0,10)
os.environ.update(OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',CMAKE_BUILD_PARALLEL_LEVEL='1')
sha=lambda p:hashlib.file_digest(Path(p).open('rb'),'sha256').hexdigest()
plan=json.loads((R/'plan.json').read_text());ref=json.loads((R/'original-reference.json').read_text());q=json.loads((R/'original-qualification.json').read_text())
for n,h in json.loads((R/'source-manifest.json').read_text()).items():assert sha(R/n)==h,n
for n,h in plan['link_inputs'].items():assert sha(R/'link'/n)==h
for n,h in plan['bios_firmware_sha256'].items():assert sha(Path('/home/user/Git/NDS_Pocket/roms')/n)==h
out=R/'results';assert not out.exists();out.mkdir()
state=dict(controller=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],host=socket.gethostname(),NI=10,jobs=1,threads=1,events=[])
def save():(out/'execution.json').write_text(json.dumps(state,indent=2)+'\n')
def guard():
 rows={}
 for l in subprocess.check_output(['ps','-eo','pid,ppid,comm,args'],text=True).splitlines()[1:]:
  a=l.strip().split(None,3)
  if len(a)==4:rows[int(a[0])]=dict(ppid=int(a[1]),comm=a[2],args=a[3])
 heavy={p:r for p,r in rows.items()if r['comm'].startswith(('Vtb','Vnds','census'))or r['comm']in ['cc1','cc1plus','clang','clang++','verilator_bin']}
 nds={p:r for p,r in heavy.items()if belongs_to_nds(p,rows)}
 leaves={p:r for p,r in nds.items()if not any(x['ppid']==p for x in nds.values())}
 assert len(leaves)<3 and os.getloadavg()[0]<=24,(leaves,os.getloadavg())
 return dict(load=os.getloadavg(),other_NDS_workers=leaves)
def run(label,argv):
 e=dict(label=label,argv=list(map(str,argv)),capacity=guard());state['events'].append(e);save()
 with(out/(label+'.log')).open('w')as f:
  p=subprocess.Popen(e['argv'],cwd=R,stdout=f,stderr=subprocess.STDOUT);e.update(pid=p.pid,starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21]);save();print(label,'PID',p.pid,flush=True)
  try:e['exit']=p.wait(timeout=480)
  except subprocess.TimeoutExpired:p.kill();p.wait();e['timeout']=True;raise
  finally:e['reaped']=True;save()
 if e['exit']:print((out/(label+'.log')).read_text()[-12000:],flush=True)
 assert e['exit']==0,(label,e['exit'])
print('C19 window controller',state['controller'],state['starttime'],flush=True);save()
run('fixture-compile',['/usr/bin/c++','-O3','-DNDEBUG','-std=c++20','-c',R/'fat_time_fixture.cpp','-o',out/'fat_time_fixture.o'])
cmd=['/usr/bin/c++',*plan['compile_defines']]
for p in [R/'frontend',R/'aux-headers/gpu2d',R/'aux-headers/sound',R/'core-headers',R/'generated-headers']:cmd+=['-I'+str(p)]
cmd+=['-O3','-DNDEBUG','-fwrapv','-std=c++20','-c',R/'frontend/census.cpp','-o',out/'census.o'];run('frontend-compile',cmd)
run('link',['/usr/bin/c++','-O3','-DNDEBUG',out/'census.o',out/'fat_time_fixture.o',R/'link/export_state.cpp.o',R/'link/platform.cpp.o',R/'link/libcore.a',R/'link/libteakra.a','-Wl,--wrap=get_fattime','-o',out/'census','-lrt'])
sd=out/'sd';shutil.copytree(R/'seed',sd);args=list(next(x['argv']for x in ref['commands']if x['name']=='export'));args[0]=str(out/'census')
for flag,value in [('--rom',R/'inputs/perftime.nds'),('--script',R/'inputs/script.txt'),('--out',out/'runtime'),('--sd-dir',sd),('--sound-v2-entries',out/'entries')]:args[args.index(flag)+1]=str(value)
assert '--load-state'not in args;run('export',args)
mismatches=[n for n,h in q['output_sha256'].items()if not(sd/n).is_file()or sha(sd/n)!=h]
entry=out/'entries/c7684';em=[n for n,h in ref['entries']['7684'].items()if not(entry/n).is_file()or sha(entry/n)!=h]
extra=sorted(str(p.relative_to(entry))for p in entry.rglob('*')if p.is_file()and str(p.relative_to(entry))not in ref['entries']['7684'])
qualification=dict(binary_sha256=sha(out/'census'),old_outputs=89,output_mismatches=mismatches,old_entry_files=20,entry_mismatches=em,additional_entry_files=extra,epoch_sha256=sha(entry/'epoch.json'),accepted_epoch_sha256=sha(R/'accepted-epoch.json'))
(out/'qualification.json').write_text(json.dumps(qualification,indent=2)+'\n')
assert not mismatches and not em and extra==['epoch.json','window.jsonl']and qualification['epoch_sha256']==qualification['accepted_epoch_sha256'],qualification
check(entry);coverage=check_window(entry/'window.jsonl');(out/'coverage.json').write_text(json.dumps(coverage,indent=2)+'\n')
state.update(status='PASS original20+89+accepted epoch exact; first80dc+256 capture complete',all_children_reaped=True,active_workers=0);save();print(state['status'],flush=True)
