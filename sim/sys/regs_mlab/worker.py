#!/usr/bin/env python3
from pathlib import Path
import os,time,json,subprocess,hashlib,signal,shutil,resource
D=Path(__file__).resolve().parent;O=D/'out';O.mkdir(exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
s=json.loads((D/'input.json').read_text())
for f,h in s['sha256'].items():assert hashlib.sha256((D/f).read_bytes()).hexdigest()==h,f
r={'host':os.uname().nodename,'PID':os.getpid(),'started':time.time(),'NI':10,'jobs':1,'threads':1,'baseline':s['baseline'],'status':'RUNNING','stages':[],'peak_bytes':0}
def save():
 p=O/'receipt.tmp';p.write_text(json.dumps(r,indent=2)+'\n');p.replace(O/'receipt.json')
def size():return sum(p.stat().st_size for p in D.rglob('*')if p.is_file())
def run(label,cmd,fail=False):
 with (O/(label+'.log')).open('w')as log:
  p=subprocess.Popen([str(c)for c in cmd],cwd=D,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  row={'label':label,'PID':p.pid,'process_group':p.pid,'started':time.time(),'command':[str(c)for c in cmd]};r['stages'].append(row);save()
  while p.poll()is None:
   used=size();r['peak_bytes']=max(r['peak_bytes'],used)
   if used>s['cap_bytes']or shutil.disk_usage(D).free<s['free_floor']or time.time()-row['started']>240:
    row['abort']='scratch/free/time budget';os.killpg(p.pid,signal.SIGTERM);break
   time.sleep(.5)
  try:row['exit']=p.wait(timeout=5)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);row['exit']=p.wait()
  row['reaped']=True;save()
 text=(O/(label+'.log')).read_text();assert (row['exit']!=0 if fail else row['exit']==0)and'abort'not in row,(label,text[-3000:]);return text
V='build/tools/oss-cad-suite/bin/verilator'
def model(label,top,files,defs=(),cpp=None):
 obj=O/'obj'
 try:
  run(label+'-elaborate',[V,'--cc','--exe',*(['--main','--timing']if cpp is None else []),'--assert','--threads','1','-j','1','-O1','--output-split','10000','-Wno-fatal','--top-module',top,'--Mdir',obj,*defs,*[D/f for f in files],*([D/cpp]if cpp else [])])
  (obj/'no-pch.mk').write_text('include V'+top+'.mk\n%.o: %.cpp\n\t$(CXX) $(CXXFLAGS) $(CPPFLAGS) -O0 -c -o $@ $<\n')
  run(label+'-build',['make','-C',obj,'-f','no-pch.mk','-j1','VM_DEFAULT_RULES=0','OPT_FAST=-O0','OPT_SLOW=-O0','OPT_GLOBAL=-O0','V'+top])
  return obj/('V'+top)
 except BaseException:
  if obj.exists():shutil.rmtree(obj)
  raise
files=[f+'.sv'for f in ['sys_ram','sys_irq','sys_timers','sys_ipc','sys_math','sys_dma','nds_sys']]
try:
 mode=os.environ.get('REG_TEST_MODE','helper')
 if mode=='helper':
  for native in [False,True]:
   label='helper-native-qis'if native else'helper-portable';defs=['+define+ALTERA_RESERVED_QIS']if native else[]
   binary=model(label,'tb_regs',['sys_ram.sv','nds_sys.sv','tb_regs.sv']+(['primitive.sv']if native else[]),defs)
   text=run(label+'-run',[binary]);assert'PASS_REGS'in text and '%Fatal'not in text and '%Error'not in text
   shutil.rmtree(O/'obj')
 if mode=='vendor':
  oss=Path(V).parent
  run('vendor-compile',[oss/'iverilog','-g2012','-DALTERA_RESERVED_QIS','-s','tb_regs','-o',O/'vendor.vvp',D/'altera_mf.v',D/'sys_ram.sv',D/'nds_sys.sv',D/'tb_regs.sv'])
  text=run('vendor-run',[oss/'vvp',O/'vendor.vvp']);assert 'PASS_REGS' in text and 'ERROR'not in text and 'Error'not in text,text[-3500:]
 if mode in ['caller','wrongbyte','owner']:
  p=D/'nds_sys.sv';original=p.read_text()
  if mode!='caller':
   old,new=('.wd(pending_data[(b%4)*8+:8])','.wd(pending_data[((b+1)%4)*8+:8])')if mode=='wrongbyte'else('.wa({io_cpu,rg_idx})','.wa({!io_cpu,rg_idx})')
   assert original.count(old)==1;mutant=original.replace(old,new);p.write_text(mutant);(O/('actual-'+mode+'-mutant.sv')).write_text(mutant)
   r['mutation']={'old':old,'new':new,'before_sha256':hashlib.sha256(original.encode()).hexdigest(),'mutant_sha256':hashlib.sha256(mutant.encode()).hexdigest()};save()
  try:
   for native in ([True]if mode!='caller'else[False,True]):
    label=mode+('-native-qis'if native else'-portable');defs=['+define+ALTERA_RESERVED_QIS']if native else[]
    binary=model(label,'nds_sys',files+['old_'+f for f in files]+['nds_dsp_add.sv','wrapper.sv']+(['primitive.sv']if native else[]),defs,'tb_sys.cpp')
    if mode!='caller':os.environ['SYS_REG_PUBLIC_ONLY']='1'
    text=run(label+'-run',[binary,'--seed','7'],mode!='caller')
    assert ('SYS_REG_PUBLIC_MISMATCH'in text if mode!='caller'else'PASS:'in text and'SYS_REG_COVERAGE'in text),text[-3500:]
    shutil.rmtree(O/'obj')
  finally:p.write_text(original)
 if mode=='extra':
  binary=model('extra-native-qis','nds_sys',files+['old_'+f for f in files]+['nds_dsp_add.sv','wrapper.sv','primitive.sv'],['+define+ALTERA_RESERVED_QIS'],'tb_sys.cpp')
  text=run('extra-native-qis-run',[binary,'--only','extra','--seed','7']);assert 'PASS:'in text and'SYS_REG_COVERAGE'in text
  shutil.rmtree(O/'obj')
 if mode=='shape':
  run('native-shape',[V,'--json-only','--json-only-output',O/'native.json','--Mdir',O/'shape','--top-module','sys_regs_mlab','-Wno-fatal','+define+ALTERA_RESERVED_QIS',D/'nds_sys.sv',D/'primitive.sv'])
  j=json.loads((O/'native.json').read_text());mods={m['addr']:m for m in j['modulesp']};top=next(m for m in mods.values()if m['origName']=='sys_regs_mlab');found=[]
  def walk(x):
   if isinstance(x,dict):
    yield x
    for v in x.values():yield from walk(v)
   elif isinstance(x,list):
    for v in x:yield from walk(v)
  def visit(m):
   if m['origName']=='altdpram':found.append({x['name']:x['valuep'][0]['name']for x in m['stmtsp']if x['type']=='VAR'and x.get('isParam')and x.get('valuep')and x['valuep'][0]['type']=='CONST'})
   for c in walk(m['stmtsp']):
    if c['type']=='CELL':visit(mods[c['modp']])
  visit(top);assert len(found)==8,found
  dec=lambda x:bytes.fromhex(x.split('h')[1]).decode('ascii')
  for x in found:
   assert dec(x['ram_block_type'])=='MLAB'and int(x['width'].split('h')[1],16)==8 and int(x['widthad'].split('h')[1],16)==5 and int(x['numwords'].split('h')[1],16)==32
   for f in ['rdaddress_reg','rdcontrol_reg','outdata_reg']:assert dec(x[f])=='UNREGISTERED'
  (O/'native-shape.json').write_text(json.dumps(found,indent=2)+'\n');shutil.rmtree(O/'shape')
 r['status']='PASS_'+mode.upper()

except BaseException:r['status']='FAIL';raise
finally:
 save()
 if(O/'obj').exists():shutil.rmtree(O/'obj')
