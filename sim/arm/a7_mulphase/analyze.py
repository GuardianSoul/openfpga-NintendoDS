#!/usr/bin/env python3
"""Read only saved detailed MUL traces; identify request/work/consume ordering."""
from pathlib import Path
from collections import Counter
import argparse,csv,json,os,resource
HEX={'pc','ins','ia','iq','flow_a','fa','fq','opa','opb'}
def overlap(path,case):
 assert path.stat().st_size<8*1024**2
 with path.open()as f:rows=[{k:int(v,16 if k in HEX else 10)for k,v in r.items()}for r in csv.DictReader(f)]
 assert len(rows)<65536
 first=[];steps=[];capture=None;caps=[];ready={};delays=[];mismatches=0
 for pos,r in enumerate(rows):
  c=r['cycle'];addr=r['ia'];main=0x02fcd000<=addr<0x02fcd110
  if r['ir']and not r['flow_v']and main:
   capture=dict(cycle=c,addr=addr,seq=r['iseq']);caps.append(capture);ready={}
  if r['flow_v']and main and r['flow_a']!=(addr>>2):mismatches+=1
  if r['ph']and r['io']and r['flow_v']and main and r['flow_a']==addr>>2:
   if pos and rows[pos-1]['cycle']==c-1 and rows[pos-1]['ir']and rows[pos-1]['ia']==addr:ready.setdefault(addr,c)
  if r['consume']and addr in ready:delays.append(c-ready.pop(addr))
  if r['e_mul']and r['pipe_fire']and r['esub']in [0,1]and 0x02fcd004<=r['pc']<0x02fcd104:
   assert r['ins']==0xe0030291 and r['opa']==3 and r['opb']==[0x7f,0x7fff,0x7fffff,0x7fffffff][case]
   steps.append(r)
   if r['esub']==0:
    assert capture is not None and capture['addr']==addr and r['flow_v']and r['flow_a']==addr>>2
    first.append(dict(capture_age=c-capture['cycle'],seq=capture['seq'],left=r['flow_left']))
 assert len(first)==1024 and len(steps)==(case+1)*1024 and not mismatches
 hist=lambda rs,k:dict(sorted(Counter(str(r[k])for r in rs).items()))
 result=dict(trace_bytes=path.stat().st_size,rows=len(rows),actual_internal_advances=len(steps),first_internal_steps=len(first),
  first_step_capture_age=hist(first,'capture_age'),first_step_captured_seq=hist(first,'seq'),first_step_flow_left=hist(first,'left'),
  all_internal_step_flow_left=hist(steps,'flow_left'),all_internal_step_iseq=hist(steps,'iseq'),all_internal_step_iok=hist(steps,'io'),
  all_internal_step_consume=hist(steps,'consume'),first_qualified_ready_to_consume_ticks=dict(sorted(Counter(map(str,delays)).items())),
  visible_logical_captures=len(caps),visible_logical_capture_seq=dict(Counter(str(c['seq'])for c in caps)),address_mismatches=mismatches,
  scope='Saved MUL-body window; ready sample requires phase1 and observed prior-cycle i_req/address, per literal f_rq<=i_req. No new logical-finish or physical-uop ownership claim.')
 assert result['first_step_capture_age']=={'1':1024}and result['first_step_captured_seq']=={'1':1024}and result['first_step_flow_left']=={'2':1024}
 assert result['all_internal_step_iseq']=={'1':1024*(case+1)}and result['all_internal_step_consume']=={'0':1024*(case+1)}
 return result
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('run',type=Path);a=p.parse_args()
 os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CPU,(30,30));resource.setrlimit(resource.RLIMIT_AS,(512*1024**2,512*1024**2))
 result={str(i):overlap(a.run/f'c{i}-r1-p0-n16.edge',i)for i in range(4)}
 (a.run/'overlap.json').write_text(json.dumps(result,indent=2)+'\n');print('PASS saved request/internal/consume ordering; no model execution')
if __name__=='__main__':main()
