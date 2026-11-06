from pathlib import Path
import datetime,hashlib,json,os,re,resource,subprocess,sys,traceback
G=Path(__file__).resolve().parent;os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
sys.path.insert(0,str(G/'helpers'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def save(n,j):
 p=G/n;q=p.with_suffix('.tmp');q.write_text(json.dumps(j,indent=2)+'\n');os.replace(q,p)
def start(p):return Path('/proc',str(p),'stat').read_text().rsplit(')',1)[1].split()[19]
assert not(G/'controller.json').exists();controller=dict(pid=os.getpid(),starttime=start(os.getpid()),host=os.uname().nodename,NI=10,jobs=1,threads=1);save('controller.json',controller)
inputs=json.loads((G/'inputs.json').read_text());base=json.loads((G/'run-inputs.json').read_text());results={}
def verify():
 for n,h in inputs.items():assert sha(G/n)==h,n
def call(cmd,tag,fault=False):
 verify();guard();cmd=list(map(str,cmd));log=G/(tag+'.log');log.parent.mkdir(parents=True,exist_ok=True)
 with log.open('w')as f:
  p=subprocess.Popen(cmd,cwd=G,stdout=f,stderr=subprocess.STDOUT);row=dict(pid=p.pid,starttime=start(p.pid),tag=tag,controller=controller,command=cmd);save('active.json',row);print('START',tag,p.pid,flush=True);rc=wait_owned(p)
 row.update(exit=rc,reaped=True);save(tag+'.process.json',row);verify();s=log.read_text()
 if fault:assert rc!=0 and'PHASE_RX_CAPTURE_OWNER'in s and'timeout'not in s.lower();return s
 assert rc==0,(tag,rc,s[-3000:]);return s
def build(role,enabled,fault=False):
 D=G/role;D.mkdir(exist_ok=True);S=G/'source';sources=sorted(S.glob('*.sv'),key=lambda p:p.name!='arm_pkg.sv')
 if fault:sources[sources.index(S/'p7.sv')]=G/'p7-wrong-owner.sv'
 if role=='on'and(G/'retained-on-Vtb').exists():
  m=json.loads((D/'model.json').read_text());assert sha(G/'retained-on-Vtb')==m['sha256'];assert all(sha(G/n)==h for n,h in m['inputs'].items());return G/'retained-on-Vtb'
 call(['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','-GCOMMIT=1','-GPHASE_META=1','-GPHASE_SERVICE='+str(enabled),'--Mdir',D/'obj',*sources],role+'/build')
 save(role+'/model.json',dict(sha256=sha(D/'obj/Vtb'),inputs={str(p.relative_to(G)):sha(p)for p in sources}));return D/'obj/Vtb'
def command(model,tag,kind,case,rs,rs6,region,loops,scenario=0):
 args={s.split('=',1)[0]:s.split('=',1)[1]for s in base['template'][1:]}
 for n in['kernel','wrapper','boot']:args['+'+n]=str(G/'inputs'/f'{kind}-{n}.hex')
 private=0x03800640 if kind==0 else 0x03800740;wrapper=private+272
 words=[int.from_bytes((G/'inputs'/f'{kind}-wrapper.bin').read_bytes()[i:i+4],'little')for i in range(0,(G/'inputs'/f'{kind}-wrapper.bin').stat().st_size,4)];ret=wrapper+4*(words.index(0xe12fff14)+1)
 args.update({'+out':str(G/tag),'+phase_out':str(G/(tag+'.csv')),'+kind':str(kind),'+case':str(case),'+rs':format(rs,'x'),'+rs6':format(rs6,'x'),'+region':str(region),'+loops':str(loops),'+detail':'1','+scenario':str(scenario),'+private':format(private,'x'),'+wrapper_entry':format(wrapper,'x'),'+return_pc':format(ret,'x')})
 return[model,*[k+'='+v for k,v in args.items()]]
try:
 model=build('on',1)
 cases=[('u1',0,0,0x7f,0x7f,7092),('u2',0,1,0x7fff,0x7fff,7092),('u3',0,2,0x7fffff,0x7fffff,7092),('u4',0,3,0x7fffffff,0x7fffffff,7860),('ms',1,0,0x7f,0x7f,7092),('ml',1,1,0x7fffffff,0x7fffffff,7860),('ma',1,2,0x7f,0x7fffffff,7476)]
 for name,kind,case,rs,rs6,ds in cases:
  elapsed={}
  for n in[4,16]:
   tag='on/'+name+'-n'+str(n);s=call(command(model,tag,kind,case,rs,rs6,1,n),tag);m=re.search(r'MUL_PHASE_PASS[^\n]*elapsed(\d+)',s);assert m and'PHASE_FUNCTION_PASS errors0'in s;elapsed[str(n)]=int(m[1])
  results[name]=dict(kind=kind,case=case,elapsed=elapsed,actual_delta_core=elapsed['16']-elapsed['4'],DS_delta_ticks=ds,DS_exact=(elapsed['16']-elapsed['4']==2*ds));save('timings.json',results)
 off=build('off',0);tag='off/c2-s0-p1';call(command(off,tag,1,2,0x7f,0x7fffffff,1,4),tag)
 for ext in['state','data','edge','full','pins','slot']:assert(G/(tag+'.'+ext)).read_bytes()==(G/'reference/c2-s0-p1'/ext).read_bytes(),('defaultoffliteral',ext)
 fault=build('wrong-owner',1,True);tag='wrong-owner/c2';call(command(fault,tag,1,2,0x7f,0x7fffffff,1,4),tag,True)
 save('complete.json',dict(status='Receiver functional/defaultoff/actualfault complete; DS timing verdict separate',controller=controller,DS_exact_count=sum(r['DS_exact']for r in results.values())));print('PHASE_RECEIVER_FIRST_GATE_COMPLETE',flush=True)
except BaseException:save('failure.json',dict(traceback=traceback.format_exc()));raise
finally:
 for role in['on','off','wrong-owner']:
  D=G/role
  if(D/'model.json').exists()and(D/'obj').exists():
   for p in(D/'obj').iterdir():
    if p.is_file()and p.name not in['Vtb','Vtb__verFiles.dat']:p.unlink()
 save('terminal.json',dict(controller=controller,complete=(G/'complete.json').exists()))
