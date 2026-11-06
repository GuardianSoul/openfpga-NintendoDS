#!/usr/bin/env python3
"""Fixed original Corner39 observations; no frame/time/PCM alignment."""
import argparse,bisect,csv,gzip,hashlib,json,os,re
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[2];HOST=ROOT/'build/ring65/candidate-host';NEW=HOST/'results/corner';OLD=ROOT/'build/scenes62/extended-host/results/corner'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def J(p):return json.loads(Path(p).read_text())
def ppm(p):
 h=Path(p).read_bytes().split(b'\n',3);assert h[:3]==[b'P6',b'256 384',b'255']and len(h[3])==256*384*3
 return np.frombuffer(h[3],dtype=np.uint8).reshape(384,256,3).copy()
def diff(a,b):
 m=np.any(a!=b,axis=2);return dict(top=int(m[:192].sum()),bottom=int(m[192:].sum()),rows=np.flatnonzero(m[:192].any(axis=1)).tolist())
def images(partial):
 prep=J(NEW/'preparation.json');ref=Path(prep['reference_path']);assert sha(ref/'ready.json')==prep['ready_sha256']
 rows=[]
 for raw in range(10,39):
  n=NEW/'shots'/f'f{raw:03}.ppm';o=OLD/'shots'/f'f{raw:03}.ppm';r=ref/'mel/shots'/f'f{raw-5:06}.ppm'
  if not n.exists()or n.stat().st_size!=294927:
   assert partial,('missing/incompleteoriginalframe',raw);continue
  a=ppm(n);b=ppm(r);old=ppm(o);b[192:,:,0]=((b[192:,:,0]>>3)<<3)|(b[192:,:,0]>>5);b[192:,:,2]=((b[192:,:,2]>>3)<<3)|(b[192:,:,2]>>5)
  rows.append(dict(raw=raw,reference=raw-5,candidate_vs_Census=diff(a,b),baseline_vs_Census=diff(old,b),candidate_vs_baseline=diff(a,old),candidate_sha256=sha(n),reference_sha256=sha(r)))
 return dict(scope='PARTIAL_IMMUTABLE_FINISHED_IMAGES_NOT_FINAL'if partial else'ORIGINAL29_FIXED_PAIRS',pairs=rows,candidate_failed=sum(v['candidate_vs_Census']['top']or v['candidate_vs_Census']['bottom']for v in rows)!=0,candidate_failed_pairs=sum(bool(v['candidate_vs_Census']['top']or v['candidate_vs_Census']['bottom'])for v in rows),baseline_failed_pairs=sum(bool(v['baseline_vs_Census']['top']or v['baseline_vs_Census']['bottom'])for v in rows),numeric_mapping='raw-5 unchanged',available=len(rows))
def full():
 t=J(NEW/'terminal.json');assert t['native_exit']==0 and t['reaped'];m=J(HOST/'model.json');assert t['model_sha256']==m['sha256']==sha(HOST/'model.bin')
 result=images(False);assert result['available']==29
 new=[json.loads(s)for s in(NEW/'capture/capture.states.jsonl').read_text().splitlines()];old=[json.loads(s)for s in(OLD/'capture/capture.states.jsonl').read_text().splitlines()];assert len(new)==len(old)==40
 result['source']=t['source'];result['model_sha256']=m['sha256'];result['source_relation']=J(HOST/'source-relation.json')
 result['states']=[]
 for a,b in zip(new,old):
  assert a['frame']==b['frame']
  result['states'].append(dict(frame=a['frame'],time_ps=a['time_ps'],same_capture_time=a['time_ps']==b['time_ps'],equal_snapshot=a==b,changed_fields=[k for k in a if a[k]!=b.get(k)],candidate=a,baseline=b))
 prep=J(NEW/'preparation.json');ref=Path(prep['reference_path']);result['save']=dict(candidate_sha256=sha(NEW/'save.bin'),baseline_sha256=sha(OLD/'save.bin'),initial_sha256=prep['export_sha256']['save.bin']);result['save']['candidate_equals_baseline']=result['save']['candidate_sha256']==result['save']['baseline_sha256'];result['save']['candidate_equals_initial']=result['save']['candidate_sha256']==result['save']['initial_sha256']
 with gzip.open(NEW/'streams.json.gz','rt')as f:a=json.load(f)
 with gzip.open(OLD/'streams.json.gz','rt')as f:b=json.load(f)
 times=[s['time_ps']for s in new]
 def misses(v):
  rows={}
  for r in v['deadlines']:
   if r[2]or r[5]<=r[1]:rows.setdefault(str(bisect.bisect_right(times,r[0])-1),[]).append(r)
  return rows
 result['ring_deadlines']=dict(candidate_missed=misses(a),baseline_missed=misses(b),candidate_expired=sum(bool(r[2])for r in a['deadlines']),baseline_expired=sum(bool(r[2])for r in b['deadlines']),scope='All original expiry/write-not-safe observations retained; no genericvideo guard substitutes for raster availability')
 aa=a['audio'];bb=b['audio'];common=min(len(aa),len(bb));values=[i for i in range(common)if aa[i][1:]!=bb[i][1:]];timed=[i for i in range(common)if aa[i]!=bb[i]]
 result['PCM']=dict(candidate_samples=len(aa),baseline_samples=len(bb),payload_differences=len(values),time_or_payload_differences=len(timed),first_payload_difference=dict(index=values[0],candidate=aa[values[0]],baseline=bb[values[0]])if values else None,first_timed_difference=dict(index=timed[0],candidate=aa[timed[0]],baseline=bb[timed[0]])if timed else None,scope='Positional raw observation only; no sample/time shift. No Census/DS PCM oracle.')
 result['capture_integrity']=J(NEW/'CPU-state-replay.json');result['physical_errors']=J(NEW/'service.json')['error_count'];result['causal_errors']=J(NEW/'service.json')['causal']['error_count'];result['remaining']='Known laterproducer lateness and combined DS timing/CPU/audio acceptance remain separate; no blanket pass'
 def diagnostics(base):
  rows=[]
  for s in(base/'native.log').read_text().splitlines():
   if s.startswith('g3ddiag raster:'):
    pairs=re.findall(r'([a-z]+) (\d+)',s.split('|')[0]);rows.append({k:int(v)for k,v in pairs})
  return rows
 nd=diagnostics(NEW);od=diagnostics(OLD);assert len(nd)==len(od)==38
 result['raster_diagnostics']=dict(intervals=[dict(printed_interval_ordinal=i,baseline=b,candidate=a)for i,(a,b)in enumerate(zip(nd,od))],candidate_totals={k:sum(r[k]for r in nd)for k in ['late','underrun']},baseline_totals={k:sum(r[k]for r in od)for k in ['late','underrun']},regressed_intervals=[dict(printed_interval_ordinal=i,baseline=b,candidate=a)for i,(a,b)in enumerate(zip(nd,od))if a['late']>b['late']or a['underrun']>b['underrun']],scope='Actual printed intervals, not presumed raw-frame ordinals. Any regression remains blocking regardless of aggregate improvement.')
 nm=J(NEW/'capture-manifest.json');om=J(OLD/'capture-manifest.json');result['CPU_trace']=dict(candidate=nm['capture.cpu.gz'],baseline=om['capture.cpu.gz'],gzip_bytes_and_sha256_exact=nm['capture.cpu.gz']==om['capture.cpu.gz'],events_independently_replayed=result['capture_integrity']['records_replayed'],scope='Exact complete compressed capture bytes bind every CPU event, value, order and timestamp; no DS/reference execution oracle.')
 result['verdict']='MIXED_REGRESSION_KEEP_OFF_MAIN_NO_DS_ACCEPTANCE'
 return result
if __name__=='__main__':
 os.setpriority(os.PRIO_PROCESS,0,10);p=argparse.ArgumentParser();p.add_argument('--images-only',action='store_true');args=p.parse_args();v=images(True)if args.images_only else full();dest=NEW/('prefix-fixed-images.json'if args.images_only else'fixed-affected-comparison.json');dest.write_text(json.dumps(v,indent=2)+'\n');print(json.dumps({k:v[k]for k in ['scope','available','candidate_failed_pairs','baseline_failed_pairs']}));print([(r['raw'],r['candidate_vs_Census']['top'],r['baseline_vs_Census']['top'])for r in v['pairs']])
