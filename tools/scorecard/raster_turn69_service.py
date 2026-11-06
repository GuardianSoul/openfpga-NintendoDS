#!/usr/bin/env python3
"""Attribute the one finished Record68 run using unchanged raw timestamps."""
import collections,gzip,hashlib,json,os,statistics,struct,subprocess,time
from pathlib import Path
import numpy as np
R=Path(__file__).resolve().parents[2];B=R/'build/turn69r1';H=B/'candidate-host';C=H/'results/corner'
DT=np.dtype([('t','<u8'),('k','<u4'),('p','<u4'),('a','<u4'),('d','<u4'),('x','<u4'),('y','<u4'),('z','<u8')]);EV=struct.Struct('<Q6IQ')
def J(p):return json.loads(p.read_text())
def sha(p):
 h=hashlib.sha256()
 with p.open('rb')as f:
  for v in iter(lambda:f.read(1<<20),b''):h.update(v)
 return h.hexdigest()
def put(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def stats(v):
 v=sorted(v);return dict(n=len(v),min=v[0],median=statistics.median(v),max=v[-1],sum=sum(v))if v else dict(n=0)
def main():
 os.setpriority(os.PRIO_PROCESS,0,10);start=time.monotonic();terminal=J(C/'terminal.json');assert terminal['native_exit']==0 and terminal['reaped']
 manifest=J(C/'capture-manifest.json');attr=J(B/'trace-attribution-windows.json');assert attr['raw_manifest']==manifest
 baseline=R/'build/record68/native-service.json';old=J(baseline)
 # Bound the retained immediate-predecessor report to its already-sealed
 # native capsule, without rereading any baseline raw trace.
 import tarfile
 archive=R/'docs/results/raster-record68-pipeline-20261102/native-evidence.tar.gz'
 with tarfile.open(archive,'r:gz')as tf:expected=tf.extractfile('attribution/native-service.json').read()
 assert hashlib.sha256(expected).hexdigest()==sha(baseline)
 lo,hi=old['window'];assert[lo,hi]==attr['windows']['service']['bounds'];data=(B/'service-window.bin').read_bytes();assert hashlib.sha256(data).hexdigest()==attr['windows']['service']['sha256'];scanned=attr['raw_records']
 (B/'native-service-window.bin').write_bytes(data)
 phys=collections.deque();system=collections.deque();offers={};first=None;P=[];Y=[];acks={};fills=[];lines=[];line=None
 for t,k,p,a,d,x,y,z in EV.iter_unpack(data):
  if k==1:offers[p]=(t,a)
  elif k==2 and not x&256:phys.append(dict(offer=offers.pop(p,None),take=t,addr=a,left=(x>>4)&15,words=[]))
  elif k==3 and phys:
   q=phys[0];q['left']-=1;q['words'].append(d)
   if not q['left']:
    phys.popleft()
    if 0x1a0000<=q['addr']<0x1c0000:P.append(dict(**q,last_physical=t))
  elif k==10:
   if x&4 and first is None:first=(t,a)
   if x&2:system.append(dict(offer=first,ack=t,addr=a,left=8,words=[]));first=None
   if x&1 and system:
    q=system[0];q['left']-=1;q['words'].append(d)
    if not q['left']:
     system.popleft()
     if 0x1a0000<=q['addr']<0x1c0000:Y.append(dict(**q,last_SYS=t))
  elif k==37:acks[t]=dict(type=p,id=a,bank=d,generation=x)
  elif k==38:fills.append([t,p,a,d,x,y])
  elif k==14:
   if line is not None:lines.append(dict(**line,abandoned=True))
   line=dict(y=a,request=t,y_lim=d)
  elif k==15 and p==3 and line is not None:lines.append(dict(**line,EOF=t));line=None
 pmap=collections.defaultdict(list)
 for p in P:pmap[p['addr']].append(p)
 joined=[]
 for q in Y:
  c=acks[q['ack']];index=(q['addr']-0x1a0000)>>3;rid=index&8191;key=[int(rid>=2048),(index>>13)&1,rid-2048 if rid>=2048 else rid]
  assert [c['type'],c['bank'],c['id']]==key
  candidates=[p for p in pmap[q['addr']]if q['ack']<=p['take']<=q['last_SYS']];assert len(candidates)==1
  p=candidates[0];assert p['words']==q['words']and q['words'][4:]==[0xc4e00000|(index<<2),(0xc4e00000|(index<<2))^0xffffffff,0x47335344,0]
  joined.append(dict(**q,cache=c,physical=p))
 def next_vertex_gaps(blocks):
  out=[]
  for a,b in zip(blocks,blocks[1:]):
   x=a['cache'];y=b['cache']
   if x['type']==y['type']==1 and x['bank']==y['bank']and x['generation']==y['generation']and y['id']==x['id']+1:
    out.append(dict(previous=x,next=y,previous_ACK=a['ack'],previous_eighth_SYS=a['last_SYS'],next_ACK=b['ack'],gap_SYS=(b['ack']-a['last_SYS'])//14919))
  return out
 oldgap=next_vertex_gaps(old['canonical_blocks']);newgap=next_vertex_gaps(joined)
 with gzip.open(C/'streams.json.gz','rt')as f:streams=json.load(f)
 target=[r for r in streams['logical_stream']if r[2]==1 and r[4]==23846 and lo<=r[0]<=hi];byline=collections.defaultdict(list)
 for r in target:byline[r[5]].append(r)
 targetlines=[]
 for y in range(125,133):
  rr=byline[y]
  if not rr:targetlines.append(dict(line=y,status='TARGET_BANK_GENERATION_ABSENT_NO_REPHASING'));continue
  candidates=[a for a in lines if a['y']==y and a.get('request',hi)<rr[0][0]<=rr[-1][0]<=a.get('EOF',0)];assert len(candidates)==1
  ep=candidates[0];poll=[r for r in streams['uses']if ep['request']<=r[0]<=ep['EOF']];ff=[r for r in fills if ep['request']<=r[0]<=ep['EOF']];cycles=(ep['EOF']-ep['request'])//14919
  targetlines.append(dict(line=y,**ep,records=len(rr),record_keys=[r[1:5]for r in rr],stream_cycles=cycles,poll_uses=len(poll),fills=len(ff),observed_retry_cycles=2*(len(poll)-len(rr))))
 fixed_deadline=[r for r in streams['deadlines']if r[0]==325834928454];assert len(fixed_deadline)<=1
 out=dict(source=terminal['source'],model_sha256=terminal['model_sha256'],status='PASS_ORIGINAL_TIME_WINDOW_PACKET_AND_SERVICE_ATTRIBUTION_NO_ACCEPTANCE',raw_manifest=manifest,baseline_service_sha256=sha(baseline),baseline_source='0167fbc80b1e90ec775d3e1a5c59036e371adc97',window=[lo,hi],scanned_records=scanned,filtered_sha256=hashlib.sha256(data).hexdigest(),canonical_blocks=joined,consecutive_known_next_vertex=dict(baseline_stats_SYS=stats([x['gap_SYS']for x in oldgap]),candidate_stats_SYS=stats([x['gap_SYS']for x in newgap]),baseline_pairs=oldgap,candidate_pairs=newgap,scope='Immediate consecutive canonical vertex packets with equal bank/generation and ID+1. Original timestamps; includes physical arbitration waits, not isolated intrinsic latency.'),target_generation=dict(bank=1,generation=23846,lines=targetlines),original130_deadline_candidate_observation=fixed_deadline,scope='No originalframe/input/clock/PCM shift. Service/stream changes are causal attribution only; fixedimages/raster/CPU/PCM/save and physical guards decide the affected native gate. No all-hot or full-speed claim.',seconds=time.monotonic()-start)
 put(B/'native-service.json',out);print(json.dumps({k:out[k]for k in ['status','source','model_sha256','seconds']}));print(json.dumps(out['consecutive_known_next_vertex']['candidate_stats_SYS']))
if __name__=='__main__':main()
