#!/usr/bin/env python3
"""Bounded reservation split experiment, with exact original/mixed DS rows."""
from pathlib import Path
from fractions import Fraction
import argparse,ast,hashlib,json,os,re,resource,shutil,subprocess,sys
from reserve import patch

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
p.add_argument('--prepare',action='store_true');a=p.parse_args();D=a.output.resolve();R=Path(__file__).resolve().parents[3]
sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()
def save(n,v):(D/n).write_text(json.dumps(v,indent=2)+'\n')
if a.prepare:
 D.mkdir(parents=True,exist_ok=False)
 A=R/'build/a7-logical-slot-pair-v1';B=R/'build/a7-logical-slot-pair-v2'
 C=Path('/home/user/Git/NDS_Pocket-cpu-a7mulphase-compare')
 for n in ['source','inputs','helpers']:shutil.copytree(B/n,D/n,ignore=shutil.ignore_patterns('__pycache__'))
 shutil.copyfile(B/'normal/cpu.sv',D/'source/cpu.sv')
 q=(B/'normal/p7.sv').read_text();(D/'source/p7.sv').write_text(patch(q));(D/'mutant-p7.sv').write_text(patch(q,'wrong-owner'))
 tb=(D/'source/tb.sv').read_text().replace(' nds_arm7_port_slot_trial #(',' nds_arm7_port_reserve_trial #(',1)
 needle='.i_commit_valid(cv),.i_commit_addr(cvaddr),.i_commit_accept(ca)'
 assert tb.count(needle)==2
 start=tb.index(' nds_arm7_port_reserve_trial #(')
 tb=tb[:start]+tb[start:].replace(needle,needle+',.i_prepare_valid(reserve_enable&&cpu.phase_prepare&&cpu.e_mul),.i_prepare_addr((cpu.phase_owner_live?{cpu.phase_f_owner,2\'b00}:ia)+32\'d4)',1)
 extra='''
 integer reserve_enable=0,resfd=0;
 always @(posedge clk)if(!rst&&resfd)begin
  if(p7.reserve_take)$fdisplay(resfd,"PREP,%0d,%h,%0d,%0d",cycle,p7.i_prepare_addr,p7.reserve_price,p7.if_gen);
  if(ca)$fdisplay(resfd,"ACCEPT,%0d,%h,%b,%0d,%0d",cycle,cvaddr,p7.reserve_match,p7.reserve_left,p7.reserve_at_commit);
  if((iredirect||cpu_reset)&&p7.reserve_v)$fdisplay(resfd,"CANCEL,%0d,%h",cycle,{p7.reserve_addr,2'b00});
 end
'''
 tb=tb.replace(' logic initialized,idle;',extra+'\n logic initialized,idle;',1)
 tb=tb.replace('  wrap_words=kind?25:24;', '  void\'($value$plusargs("reserve=%d",reserve_enable));\n  resfd=$fopen({out,".reserve"},"w");\n  wrap_words=kind?25:24;',1)
 (D/'source/tb.sv').write_text(tb)
 oldlayout=C/'build/a7-mulphase-compare/attempt1/inputs/mul-layout.json'
 shutil.copyfile(oldlayout,D/'original-layout.json')
 for f in(C/'build/a7-mul-local/attempt1/inputs').glob('0-*'):shutil.copyfile(f,D/'inputs'/f.name)
 old=json.loads((D/'original-layout.json').read_text())
 assert sha(D/'inputs/0-kernel.bin')==old['code_SHA256']
 assert sha(D/'inputs/0-wrapper.bin')==old['wrapper']['SHA256']
 assert sha(D/'inputs/1-kernel.bin')==json.loads((R/'docs/results/a7mulmix-dslite-20261102/measurement.json').read_text())['summary'][0]['code_SHA256']
 (D/'run-inputs.json').write_bytes((B/'run-inputs.json').read_bytes())
 for f in ['docs/results/a7mulmix-dslite-20261102/measurement.json','docs/results/a7mul-service-proposal-20261102/analysis.json']:
  shutil.copyfile(R/f,D/('DS-mixed.json'if f.endswith('measurement.json')else'DS-original.json'))
 refs=json.loads((B/'results.json').read_text());control={}
 for case in range(3):
  key=f'normal/c{case}-s0-p1';z=refs[key];control[str(case)]=dict(captures=z['captures'],source=str(A if z.get('reused_from')else B))
 save('qualified-controls.json',control)
 for n in ['run.py','reserve.py']:shutil.copyfile(Path(__file__).with_name(n),D/n)
 save('inputs.json',dict(status='SOURCE FROZEN; trial unrun',qualified_pair='98373e35',production='d087bb7f held; this test changes no production',files={str(f.relative_to(D)):sha(f)for f in D.rglob('*')if f.is_file()},scope='Only actual firstinternal/prepared originalF+4 reserves existing2/16; actual commit/payload/rp ownership unchanged; reject any DS anchor mismatch'))
 print('RESERVATION_PREPARED',D);sys.exit(0)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
manifest=json.loads((D/'inputs.json').read_text())
for n,h in manifest['files'].items():assert sha(D/n)==h,n
assert sha(D/'helpers/sim_ownership.py')=='64e5e2c840070707b82c0d657ea0a4207dc47ed1e1cc1f733a5053d6bbc15003'
sys.path.insert(0,str(D/'helpers'));from worker_guard import guard,wait_owned
start=lambda pid:Path('/proc',str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
assert not(D/'controller.json').exists();controller=dict(pid=os.getpid(),starttime=start(os.getpid()),host=os.uname().nodename,NI=10,jobs=1,threads=1);save('controller.json',controller)
def call(cmd,stem,fault=None):
 guard();cmd=list(map(str,cmd));log=D/(stem+'.log');log.parent.mkdir(parents=True,exist_ok=True)
 with log.open('w')as f:
  q=subprocess.Popen(cmd,cwd=D,stdout=f,stderr=subprocess.STDOUT);r=dict(pid=q.pid,starttime=start(q.pid),command=cmd,log=str(log));save('active.json',r);print('START',stem,q.pid,flush=True);rc=wait_owned(q)
 r.update(exit=rc,reaped=True);save(stem+'.process.json',r);text=log.read_text()
 if fault:assert rc!=0 and fault in text and'timeout'not in text.lower(),(stem,rc,text[-2200:])
 else:assert rc==0,(stem,rc,text[-2200:])
 return dict(exit=rc,log_sha256=sha(log),caught=fault)
info=json.loads((D/'run-inputs.json').read_text());layout=json.loads((D/'original-layout.json').read_text());results={}
normalize=lambda f:['RESET'if x.startswith('RESET,')else x.split(',',1)[1]for x in f.read_text().splitlines()]
vectors=[(0,c,0,n,res)for c in range(4)for n in [4,16]for res in [0,1]]+[(1,c,0,n,res)for c in range(3)for n in [4,16]for res in [0,1]]+[(1,1,s,4,res)for s in [1,2,3,4]for res in [0,1]]
try:
 for role in ['normal','wrong-owner']:
  Q=D/role;Q.mkdir();sources=sorted((D/'source').glob('*.sv'),key=lambda f:f.name!='arm_pkg.sv')
  if role!='normal':sources=[D/'mutant-p7.sv'if f.name=='p7.sv'else f for f in sources]
  call(['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','--Mdir',Q/'obj',*sources],role+'/build')
  model=Q/'obj/Vtb';save(role+'/model.json',dict(sha256=sha(model),inputs={str(f.relative_to(D)):sha(f)for f in sources}))
  for kind,case,scenario,n,res in(vectors if role=='normal'else[(1,1,0,4,1)]):
   stem=f'{role}/k{kind}-c{case}-s{scenario}-n{n}-r{res}';args={x.split('=',1)[0]:x.split('=',1)[1]for x in info['template'][1:]}
   rs,rs6=([(127,127),(32767,32767),(8388607,8388607),(2147483647,2147483647)]if kind==0 else[(127,127),(2147483647,2147483647),(127,2147483647)])[case]
   args.update({'+out':str(D/stem),'+kind':str(kind),'+case':str(case),'+scenario':str(scenario),'+loops':str(n),'+policy':'1','+reserve':str(res),'+rs':format(rs,'x'),'+rs6':format(rs6,'x'),'+detail':'1'})
   for x in ['kernel','wrapper','boot']:args['+'+x]=str(D/'inputs'/f'{kind}-{x}.hex')
   if kind==0:
    for x,v in [('private',layout['source_entry']),('wrapper_entry',layout['wrapper']['entry']),('return_pc',layout['wrapper']['return_address'])]:args['+'+x]=format(v,'x')
   if scenario==3:
    args['+boot']=str(D/'inputs/irq-boot.hex')
    for x,s in [('call','timed_call'),('done','timed_done'),('sym_rs','rs_literal'),('sym_rs6','rs6_literal'),('sym_loops','loops_literal'),('sym_entry','entry_literal')]:args['+'+x]=format(info['IRQ_symbols'][s],'x')
   r=call([model,*[k+'='+v for k,v in args.items()]],stem,'RESERVE_WRONG_COMMIT_OWNER'if role!='normal'else None)
   if role=='normal':
    log=(D/(stem+'.log')).read_text();assert 'PAIRED_SLOT_PASS'in log and'PHASE_FUNCTION_PASS'in log
    r['elapsed_SYS']=int(re.search(r'MUL_PHASE_PASS.*elapsed(\d+)',log)[1]);r['captures']={x:sha(D/(stem+'.'+x))for x in ['state','data','edge','full','pins','slot','reserve']}
    if res:
     control=stem[:-1]+'0'
     for x in ['state','data']:assert normalize(D/(stem+'.'+x))==normalize(D/(control+'.'+x)),('architecture mismatch',stem,x)
    if kind==1 and scenario==0 and n==4 and not res:
     ref=json.loads((D/'qualified-controls.json').read_text())[str(case)]['captures']
     for x in ref:assert r['captures'][x]==ref[x],('reserve-disabled literal mismatch',stem,x)
   results[stem]=r;save('results.json',results)
 ds0=json.loads((D/'DS-original.json').read_text());ds1=json.loads((D/'DS-mixed.json').read_text());rows=[]
 for kind,count in [(0,4),(1,3)]:
  for c in range(count):
   target=Fraction(next(x['per_loop']for x in ds0['raw']if x['region']=='MAIN'and x['m']==c+1))/64 if kind==0 else Fraction(str(next(x['slope']for x in ds1['summary']if x['region']=='MAIN'and x['case_id']==c)))
   slopes={str(res):str(Fraction(results[f'normal/k{kind}-c{c}-s0-n16-r{res}']['elapsed_SYS']-results[f'normal/k{kind}-c{c}-s0-n4-r{res}']['elapsed_SYS'],1536))for res in [0,1]}
   rows.append(dict(kind=kind,case=c,slopes=slopes,DS=str(target),enabled_matches=Fraction(slopes['1'])==target))
 save('decision.json',dict(disposition='KEEP_FOR_NEXT_GATES'if all(x['enabled_matches']for x in rows)else'REJECT_DS_ANCHOR_CONTRADICTION',rows=rows,scope='Bounded test-only2/16 reservation; no price retune, production enable, area or native claim'))
 save('complete.json',dict(status='FUNCTION/OWNER/MUTANT checks PASS; timing decision separate',positive_cases=36,actual_faults=1,controller=controller));print('RESERVATION_COMPLETE',json.dumps(rows),flush=True)
finally:
 removed=[]
 for role in ['normal','wrong-owner']:
  Q=D/role
  if not(Q/'model.json').exists():continue
  assert sha(Q/'obj/Vtb')==json.loads((Q/'model.json').read_text())['sha256']
  for f in(Q/'obj').iterdir():
   if f.is_file()and f.name not in ['Vtb','Vtb__verFiles.dat']:removed.append(f.stat().st_size);f.unlink()
 save('compiler-cleanup.json',dict(files=len(removed),bytes=sum(removed)));save('terminal.json',dict(controller=controller,complete=(D/'complete.json').exists()))
