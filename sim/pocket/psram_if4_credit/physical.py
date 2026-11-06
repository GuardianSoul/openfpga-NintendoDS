#!/usr/bin/env python3
"""Adapt the existing paired-chip credit ledger; one worker, /tmp only."""
from pathlib import Path
import datetime,hashlib,json,os,resource,shutil,subprocess,sys
ROOT=Path(__file__).resolve().parents[3]
OUT=Path('/tmp/nds-if4-credit-physical');OUT.mkdir(exist_ok=True)
os.chdir(ROOT);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
def pinned(path):
 return subprocess.check_output(['git','show','c74a3620:'+path])
H=OUT/'helpers';H.mkdir(exist_ok=True)
for n in['worker_guard.py','sim_ownership.py']:(H/n).write_bytes(pinned('sim/arm/read_ack/'+n))
sys.path.insert(0,str(H));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
base=subprocess.check_output(['git','show','e704c35b:rtl/pocket/nds_psram.sv'],text=True)
assert hashlib.sha256(base.encode()).hexdigest()=='b4dfdff78ba20175f273925b8a5878dd114d06b458bf7b1e59cb6968076a619e'
candidate=(ROOT/'rtl/pocket/nds_psram.sv').read_text();source_hash=hashlib.sha256(candidate.encode()).hexdigest()
tb=pinned('sim/pocket/psram_if4_publish/tb.sv').decode()
def change(old,new):
 global tb
 assert old in tb,old;tb=tb.replace(old,new)
change('parameter ENABLE=1, SKEW=0, GAPS=0','parameter ENABLE=1, SKEW=0, GAPS=0, PREFILL=0')
change('reg s_req = 0, s_we = 0, s_n8 = 0, s_if4=0;', 'reg s_req = 0, s_we = 0, s_n8 = 0, s_if4=0, s_ld4=0;')
change('.IF_STREAM4(ENABLE))','.IF_STREAM4(ENABLE),.IF_PREFILL8(PREFILL),.LDM_STREAM4(1))')
change('.initialized(init_r), .s_if4,','.initialized(init_r), .s_if4, .s_ifseq(1\'b0),.s_ifgen(2\'d0),.s_ld4,')
change('.initialized(init_n), .s_if4,','.initialized(init_n), .s_if4, .s_ifseq(1\'b0),.s_ifgen(2\'d0),.s_ld4,')
change('credit_target=dut.req_write?0:dut.req_n8?8:ledger_typed?4:0;', 'credit_target=dut.req_write?0:dut.req_n8?8:(ledger_typed||dut.req_ld4)?4:0;')
change('if(credit_n>paired_before || stored[credit_n-1]==0 || $time-stored[credit_n-1]<9946)', 'if(credit_n>paired_after || stored[credit_n-1]==0 || $time-stored[credit_n-1]<1)')
change('credit before registered paired halves','credit before paired halves committed')
change('$time-stored[0]!=9947','$time-stored[0]!=1')
change('$time-stored[0]!=19893','$time-stored[0]!=9947')
change('if(!ledger_typed && (dut.wc!==refd.wc || dut.wc_g!==refd.wc_g) && !ENABLE)', 'if(!ledger_typed && (credit_n!=credit_r || delta_n!=delta_r || (!ENABLE && (dut.wc!==refd.wc || dut.wc_g!==refd.wc_g))))')
change('disabled cumulative credit cycle changed','non-IF4 cumulative credit cycle changed')
change('input logic[3:0]be=15);','input logic[3:0]be=15,input bit ld4=0);')
change('s_be=be;\n        active_read', 's_be=be;s_ld4=ld4;\n        active_read')
change('active_read=0;active_if4=0;s_if4=0;', 'active_read=0;active_if4=0;s_if4=0;s_ld4=0;')
change("s_addr=24'd64;s_we=0;s_n8=0;s_if4=1;s_be=15;s_req=1;", "s_addr=24'd64;s_we=0;s_n8=0;s_if4=1;s_ld4=0;s_be=15;s_req=1;")
change('if(ENABLE)begin\n            // Joint reset', '''for(int k=0;k<8;k++)begin
            request(4*k,0,0,0,0,15,1);
            request(4*k+1,0,0,0);
            request(k,1,0,0,value(k+512),4'hA);
        end
        if(ENABLE)begin
            // Joint reset''')
(OUT/'tb.sv').write_text(tb)
def status(phase,pid=None):
 p=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json');j=json.loads(p.read_text())
 def start(n):
  try:return int(Path(f'/proc/{n}/stat').read_text().rsplit(')',1)[1].split()[19])
  except FileNotFoundError:return None
 j.update(phase=phase,profile='paired PSRAM publication; IF4/PREFILL8 on-off; LDM_STREAM4=1; three phases/skew/row gaps',updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),evidence=str(OUT))
 j['worker'].update(controller=os.getpid(),PID=pid,starttime={'controller':start(os.getpid()),'PID':start(pid)if pid else None})
 t=json.dumps(j,indent=2)+'\n';assert len(t.encode())<=2048;q=p.with_name('CPU.json.tmp.'+str(os.getpid()));q.write_text(t);os.replace(q,p)
def call(cmd,d,name,negative=False,expected=None):
 guard();cmd=list(map(str,cmd))
 with(d/(name+'.log')).open('w')as f:
  p=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT)
  with(OUT/'processes.jsonl').open('a')as q:q.write(json.dumps({'controller':os.getpid(),'PID':p.pid,'NI':10,'argv':cmd,'log':str(d/(name+'.log'))})+'\n')
  status(d.name+'/'+name,p.pid);print(d.name,name,p.pid,flush=True);rc=wait_owned(p)
 text=(d/(name+'.log')).read_text()
 if negative:assert rc!=0 and expected in text and 'timeout'not in text.lower(),(d.name,text[-2000:])
 else:assert rc==0 and (name=='build' or 'PASS publication'in text),(d.name,text[-2000:])
 return text
variants=[('default',0,0,0,0),('paired',1,0,0,0),('slow-half1',1,1,1,0),('slow-half0',1,2,1,0),('prefill8',1,0,0,1),
          ('fault-earlyhalf',1,1,1,0),('fault-order',1,0,0,0),('fault-reset',1,0,0,0),('fault-scope',1,0,0,0)]
summary={'before_PHY':hashlib.sha256(base.encode()).hexdigest(),'candidate_PHY':source_hash,'TB':sha(OUT/'tb.sv'),'donor':'existing ld4_pairs, data-commit-edge count; actual data capture/CDC and physical sequencer unchanged','cases':{}}
if (OUT/'summary.json').exists():
 saved=json.loads((OUT/'summary.json').read_text());assert saved['candidate_PHY']==source_hash and saved['before_PHY']==summary['before_PHY'];summary['cases']=saved['cases']
for name,enable,skew,gaps,prefill in variants:
 d=OUT/name
 if name in summary['cases']:
  assert sha(d/'obj/Vtb_publish')==summary['cases'][name]['model_SHA256']
  print('REUSE accepted',name,flush=True);continue
 d.mkdir(exist_ok=True);new=candidate;expected=None
 mutations={
  'fault-earlyhalf':('wire [4:0] paired_words = ld4_pairs;','wire [4:0] paired_words = ld4_n0 > ld4_n1 ? ld4_n0 : ld4_n1;','credit before paired halves committed'),
  'fault-order':("out_k <= out_k + 3'd1; stream_left <= stream_left - 4'd1;","out_k <= out_k + (b_if4 ? 3'd2 : 3'd1); stream_left <= stream_left - 4'd1;",'typed word payload'),
  'fault-reset':('&& !(TYPED4 && reset_mem_i) && state == RD_DATA', '&& state == RD_DATA','credit during reset'),
  'fault-scope':('wire if4_publish = IF_STREAM4 != 0 && req_if4','wire if4_publish = IF_STREAM4 != 0','non-IF4 cumulative credit cycle changed')}
 if name in mutations:
  old,replacement,expected=mutations[name];assert new.count(old)==1;new=new.replace(old,replacement)
 (d/'old.sv').write_text(base.replace('module nds_psram #','module old_nds_psram #',1));(d/'new.sv').write_text(new);shutil.copyfile(OUT/'tb.sv',d/'tb.sv')
 for p,n in[(ROOT/'rtl/mem/psx_pq_psram.sv','chip.sv'),(ROOT/'sim/phase1/sim_prims.sv','prims.sv')]:shutil.copyfile(p,d/n)
 (d/'cram.sv').write_bytes(pinned('sim/pocket/psram_if4/cram_model.sv'))
 (d/'inputs.json').write_text(json.dumps({p.name:sha(p)for p in d.glob('*.sv')},indent=2)+'\n')
 model=d/'obj/Vtb_publish';cmd=['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','-O2','-j','1','--threads','1','-Wno-fatal','--top-module','tb_publish',f'-GENABLE={enable}',f'-GSKEW={skew}',f'-GGAPS={gaps}',f'-GPREFILL={prefill}','--Mdir',model.parent,*[d/n for n in['chip.sv','old.sv','new.sv','prims.sv','cram.sv','tb.sv']]]
 call(cmd,d,'build')
 for p in model.parent.iterdir():
  if p.is_file()and(p.suffix in['.gch','.o','.a','.d']or(p.name.startswith('Vtb')and p.suffix in['.cpp','.h','.mk','.dat'])):p.unlink()
 runs=[]
 for phase in([0]if expected else[0,3000,7000]):
  text=call([model,f'+phase={phase}'],d,f'run-{phase}',bool(expected),expected);runs.append({'phase':phase,'caught':bool(expected),'verdict':expected or next(l for l in text.splitlines()if l.startswith('PASS publication'))})
 summary['cases'][name]={'model_SHA256':sha(model),'runs':runs};(OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
assert sha(ROOT/'rtl/pocket/nds_psram.sv')==source_hash
status('physical publication/pairing/nonIF4/reset gates PASS; delivery owner/stale gates next')
print('IF4_PAIR_PUBLICATION_PASS',flush=True)
