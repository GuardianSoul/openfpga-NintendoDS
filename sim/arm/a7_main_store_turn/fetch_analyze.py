#!/usr/bin/env python3
"""Correlate real discarded F/target data with old/new physical owners."""
from pathlib import Path
import collections, csv, importlib.util, io, json, struct, sys

ROOT=Path(__file__).resolve().parents[3]
def analyze(read):
 fields=json.loads(read('fields.json'))
 spec=importlib.util.spec_from_file_location('af',ROOT/'sw/tests/a7fetch39/build.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 blobs,layout=m.captured();summary={};all_events={}
 for name in ['b_s16_o0','b_s16_o8']:
  c=next(c for c in layout['cases']if c['case']==name)
  rows=[{k:int(v,16 if fields[k][1]=='h'else 10)for k,v in r.items()}for r in csv.DictReader(io.StringIO(read(name+'-on-m1.witness.csv').decode()))]
  body=c['main_body'];entry=c['main_entry'];raw=blobs[f'arm7fetch_v1_k{c["id"]:02d}_r0.bin'];code=raw[348:348+c['size']];events=[]
  for j,r in enumerate(rows):
   if not(r['redirect']and r['brt']and body<=r['pc']<body+1024 and (r['pc']-body)%16==0):continue
   target=r['fl_tgt'];word=(target>>2)&3;quad=target>>4
   assert r['ph']and r['f_rq']and r['io']and not r['consume']and not r['if_wait']
   available=any(r['il_flow']>>b&1 and r['il_a'+str(b)]==quad and r['il_w'+str(b)]>>word&1 for b in [0,1])
   e=dict(cycle=r['cycle'],pc=r['pc'],target=target,discard=r['ia'],old_gen=r['if_gen'],target_present_before=bool(available),pending_target=bool(r['rp_v']and r['rp_i']and r['rp_a']>>4==quad))
   if e['pending_target']:
    old=next(q for q in rows[j:j+32]if q['fr']and q['rv']and q['rp_gen']==r['rp_gen']and q['rp_a']>>4==quad and q['rp_k']==word)
    tail=next(q for q in rows[j:j+32]if q['fr']and q['ack']and q['rp_gen']==r['rp_gen'])
    issue=next(q for q in rows[j+1:j+64]if q['mr_req']and (q['mr_addr']*4>>4)==(quad&0x3ffff)and q['fab_gen']!=r['rp_gen'])
    new=next(q for q in rows[j+1:j+64]if q['fr']and q['rv']and q['rp_a']>>4==quad and q['rp_k']==word and q['rp_gen']!=r['rp_gen'])
    assert old['fq']==new['fq']==struct.unpack_from('<I',code,target-entry)[0],('target payload',name,r['cycle'])
    assert old['rp_stale']and old['if_gen']==new['rp_gen']==(r['rp_gen']+1)%4,('generation',name,r['cycle'])
    e.update(old_target=old['cycle']-r['cycle'],old_tail=tail['cycle']-r['cycle'],old_target_stale=old['rp_stale'],new_issue=issue['cycle']-r['cycle'],new_target=new['cycle']-r['cycle'],new_gen=new['rp_gen'])
   events.append(e)
  assert len(events)==1024,(name,len(events))
  summary[name]=dict(count=len(events),counts={k:dict(collections.Counter(str(e[k])for e in events if k in e))for k in ['pending_target','target_present_before','old_target','old_tail','new_issue','new_target','old_target_stale']})
  all_events[name]=events
 expected={'pending_target':{'True':1024},'target_present_before':{'False':1024},'old_target':{'1':1024},'old_tail':{'2':1024},'new_issue':{'7':1024},'new_target':{'23':1024},'old_target_stale':{'1':1024}}
 assert summary['b_s16_o8']['counts']==expected
 return summary,all_events

if __name__=='__main__':
 B=Path(sys.argv[1])if len(sys.argv)>1 else ROOT/'build/a7-offset8-witness-r2'
 summary,events=analyze(lambda n:(B/n).read_bytes())
 (B/'attribution-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 for name,rows in events.items():(B/(name+'-attribution.json')).write_text(json.dumps(rows,indent=2)+'\n')
 print(json.dumps(summary,indent=2))
