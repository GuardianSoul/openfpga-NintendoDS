#!/usr/bin/env python3
"""Three ARM9 architectural streams against sealed retained original traces.
No original model rebuild/run; cycle equality is intentionally not claimed.
"""
import pathlib,json,hashlib,subprocess,os,time,resource
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-elastic-cpu';T=D/'architectural';T.mkdir(exist_ok=True);I=W/'build/cpu232-service-cpu-gates/inputs';G=W/'build/cpu232-retimed/trace-comparison';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
r={'status':'RUNNING','no_control_rebuild_or_run':True,'cases':{}}
model=D/'obj/Vtb_arm';assert H(model)==json.loads((D/'result.json').read_text())['model_sha256'];gold=json.loads((G/'result.json').read_text())
for name in ['bpred9','normal-01','DENSE-01']:
 img='bpred9'if name=='bpred9'else name
 args=[f'+img0={I}/{img}.hex','+pc0=02000000','+run=1','+maxcycles='+('16150'if name=='bpred9'else'2000000'),'+trace0='+str(T/(name+'.trace0'))]
 with(T/(name+'.log')).open('w')as f:
  p=subprocess.Popen([model,*args],stdout=f,stderr=subprocess.STDOUT)
  s=json.loads(STATUS.read_text());s.update(phase='ELASTIC_ARCH_'+name,workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'job':'elastic-trace'},{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':name}],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');t.replace(STATUS)
  rc=p.wait(timeout=180)
 assert rc==0 and 'TEST PASSED' in (T/(name+'.log')).read_text()
 original=G/(name+'-control.trace0');assert H(original)==gold['cases'][name]['control']['trace0']
 new=T/(name+'.trace0');r['cases'][name]={'original_sha256':H(original),'candidate_sha256':H(new),'original_rows':len(original.read_text().splitlines()),'candidate_rows':len(new.read_text().splitlines()),'equal':original.read_bytes()==new.read_bytes()}
 (T/'result.json').write_text(json.dumps(r,indent=2)+'\n');print(name,r['cases'][name],flush=True)
 a=original.read_text().splitlines();b=new.read_text().splitlines();n=min(len(a),len(b));tail=a[n:]+b[n:];prefix_equal=a[:n]==b[:n]
 tokens=(I/(img+'.hex')).read_text().split();memory={};idx=0
 for token in tokens:
  if token.startswith('@'):idx=int(token[1:],16)
  else:memory[idx]=int(token,16);idx+=1
 pc=int((a if len(a)<len(b) else b)[-1].split(',')[0],16);mi=((pc>>24)&15)*65536+((pc>>2)&65535)
 tail_only=prefix_equal and all(row==a[n-1] for row in tail) and memory.get(mi)==0xeafffffe
 r['cases'][name].update(common_rows_equal=prefix_equal,extra_rows=len(tail),verified_terminal_selfbranch_only=tail_only)
 (T/'result.json').write_text(json.dumps(r,indent=2)+'\n')
 fields_a=[x.split(',') for x in a[:n]];fields_b=[x.split(',') for x in b[:n]]
 r['cases'][name]['pc_rf_mismatches']=sum([x[0],*x[2:]]!=[y[0],*y[2:]] for x,y in zip(fields_a,fields_b))
 r['cases'][name]['cpsr_mismatches']=sum(x[1]!=y[1] for x,y in zip(fields_a,fields_b))
 r['cases'][name]['first_cpsr_differences']=[{'row':i,'pc':x[0],'original':x[1],'candidate':y[1]} for i,(x,y) in enumerate(zip(fields_a,fields_b)) if x[1]!=y[1]][:8]
 (T/'result.json').write_text(json.dumps(r,indent=2)+'\n')
r['status']='THREE_ARM9_TRACE_SCREEN_COMPLETE_CPSR_DIFFERENCES_NOT_EQUIVALENCE';(T/'result.json').write_text(json.dumps(r,indent=2)+'\n');s=json.loads(STATUS.read_text());s.update(phase=r['status'],workers=[],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');t.replace(STATUS)
