from pathlib import Path
import os,json,subprocess,hashlib,re,atexit,datetime,sys
R=Path(__file__).resolve().parents[3];os.chdir(R);os.setpriority(os.PRIO_PROCESS,0,10);O=R/'build/rc10-tags-controller';S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
def status(phase,workers):
 d=json.loads(S.read_text());d.update(updated=datetime.datetime.now(datetime.timezone.utc).isoformat(),phase=phase,workers=workers);t=S.with_name(S.name+'.'+str(os.getpid())+'.tmp');t.write_text(json.dumps(d));t.replace(S)
atexit.register(lambda:status('TAGS_CONTROLLER_STOPPED_REVIEW_RESULT',[]))
subprocess.run(['python3','tools/audits/tags_controller/prepare.py'],check=True)
def call(cmd,name):
 with (O/(name+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),stdout=f,stderr=subprocess.STDOUT,env={**os.environ,'OMP_NUM_THREADS':'1','OPENBLAS_NUM_THREADS':'1'});status(name,[dict(host='Desktop',controller=os.getpid(),child=p.pid,NI=10,jobs=1,threads=1)]);rc=p.wait()
 return rc,(O/(name+'.log')).read_text()
def build(name,before,after,tb,extra=(),updater=True):
 cmd=['python3','tools/audits/tags_controller/build_gate.py','--binary','--timing','--assert','-j','1','--threads','1','-O2','-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-UNUSEDSIGNAL','--top-module','tb_tags','--Mdir',str(O/('obj-'+name)),*extra,str(O/'arm_pkg.sv'),str(O/'arm9_ram.sv')]
 if updater:cmd.append(str(O/('fault-packed_update.sv'if name=='fault'else'packed_update.sv')))
 cmd += [str(O/before),str(O/after),'tools/audits/tags_controller/'+tb]
 (O/(name+'-command.json')).write_text(json.dumps(cmd,indent=2)+'\n');rc,log=call(cmd,name+'-build');assert rc==0,log[-2400:]
 return O/('obj-'+name)/'Vtb_tags'
resume='--resume-after-main'in sys.argv
if resume:
 res=json.loads((O/'result.json').read_text());assert res['binding']==json.loads((O/'binding.json').read_text()) and len(res['cases'])==3 and all(c['PASS'] for c in res['cases']);res['noncontinuation']=[]
else:res={'binding':json.loads((O/'binding.json').read_text()),'cases':[],'noncontinuation':[]}
def save():(O/'result.json').write_text(json.dumps(res,indent=2)+'\n')
if not resume:
 main=build('before-after','before.sv','after.sv','tb_tags.sv')
 for seed in [1,7,29]:
  rc,log=call([main,f'+seed={seed}','+rounds=256'],f'seed-{seed}');ok=rc==0 and'TAGS_CONTROLLER_PASS'in log and'I_SETWAY_ALL_ALIASES_INVALIDATED XI=1 count=2'in log and'SCOPE_OMISSION'not in log
  res['cases'].append(dict(seed=seed,PASS=ok,rc=rc,coverage=re.findall(r'^COVER.*$',log,re.M),result=re.findall(r'^TAGS_CONTROLLER_PASS.*$',log,re.M)));save();print('fixed-full',seed,ok,flush=True);assert ok,log[-2400:]
for name,extra,args in [('xi0',['-GXI=0'],[]),('pf',['-GOPT=1711268851'],['+omit_known_i_setway=1'])]:
 binary=build(name,'original-before.sv','fixed-after-unpacked.sv','tb_noncontinuation.sv',extra,False)
 rc,log=call([binary,'+seed=7','+rounds=256',*args],name);ok=rc==0 and'NONCONTINUATION_PASS'in log
 res['noncontinuation'].append(dict(name=name,PASS=ok,rc=rc,result=re.findall(r'^NONCONTINUATION_PASS.*$',log,re.M),scope='Original/fixed full unpacked controllers; PF run omits only I setway, the changed path.'));save();print(name,ok,flush=True);assert ok,log[-2400:]
reverted=build('reverted','original-before.sv','reverted-after-unpacked.sv','tb_noncontinuation.sv',(),False)
rc,log=call([reverted,'+seed=1','+rounds=256'],'reverted');caught=rc!=0 and'FIXTURE_TIMEOUT phase=3 st=0 cp=03aa'in log and'CONTROL_MISMATCH'not in log;res['reverted_fix']=dict(caught=caught,rc=rc,log=log);save();print('reverted',caught,flush=True);assert caught,log[-2400:]
fault=build('fault','before.sv','after.sv','tb_tags.sv')
rc,log=call([fault,'+seed=1','+rounds=256'],'fault');caught=rc!=0 and'CONTROL_MISMATCH'in log and'TAGS_CONTROLLER_PASS'not in log;assert caught,log[-2400:]
res.update(full_bounded_screen_PASS=True,fault=dict(caught=True,rc=rc,log=log,source_SHA256=hashlib.sha256((O/'fault-packed_update.sv').read_bytes()).hexdigest()),scope='Complete fixed-parent and packed candidate with real behavioral RAM, 3 finite sequences/assertion hooks; original/fixed XI0 and PF1 noncontinuation, actual reverted-fix timeout and actual updater corruption. Not all-state/fullCPU/game/vendor/physical qualification.')
save();print('full bounded controller screen and both actual mutations PASS',flush=True)
