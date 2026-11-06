#!/usr/bin/env python3
"""Reconstruct fixed Corner39 VRAM snapshots from actual accepted writes."""
import collections,gzip,hashlib,heapq,json,os,re,struct,time
from pathlib import Path
import numpy as np
R=Path(__file__).resolve().parents[2];B=R/'build/ring65';H=B/'candidate-host'
BASES=[R/'build/scenes62/extended-host/results/corner',H/'results/corner']
DT=np.dtype([('t','<u8'),('k','<u4'),('p','<u4'),('a','<u4'),('d','<u4'),('x','<u4'),('y','<u4'),('z','<u8')])
EV=struct.Struct('<Q6IQ');MASK=(1<<64)-1
def sha(p):
 h=hashlib.sha256()
 with p.open('rb')as f:
  for v in iter(lambda:f.read(1<<20),b''):h.update(v)
 return h.hexdigest()
def put(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def main():
 os.setpriority(os.PRIO_PROCESS,0,10);start=time.monotonic();all_states=[];all_last=[];reports=[]
 for side,base in enumerate(BASES):
  states=[json.loads(s)for s in(base/'capture/capture.states.jsonl').read_text().splitlines()]
  initial=[int(s,16)for s in(base/'inputs/imp_vram.hex').read_text().split()];assert len(initial)==0x29000
  log=(base/'native.log').read_text();import_t=int(re.search(r'import: memories loaded at (\d+)',log)[1])
  manifest=json.loads((base/'capture-manifest.json').read_text());raw=base/'capture/capture.bus.gz';assert sha(raw)==manifest[raw.name]['sha256']
  filtered=B/f'vram-{side}-writes.bin.gz';n=0;kept=0
  with gzip.open(raw,'rb')as f,gzip.open(filtered,'wb')as g:
   header=f.read(16);assert struct.unpack('<4I',header)[:3]==(0x33504453,1,40);g.write(header)
   for data in iter(lambda:f.read(40*131072),b''):
    assert len(data)%40==0;a=np.frombuffer(data,DT);n+=len(a)
    m=(a['a']<0x29000)&((a['k']==4)|((a['k']==2)&((a['x']&256)!=0))|(((a['k']==23)|(a['k']==24))&(a['x']!=0)))
    v=a[m];g.write(v.tobytes());kept+=len(v)
  # Match the frozen SDRAM model's deterministic unopened halfwords and
  # tb sd_index mapping, before the one logged import transaction.
  def fill(i):return ((i*0x9e37)^(i>>5))&0xffff
  memory=[]
  for w in range(0x29000):
   i=((w>>8)<<10)|((w&255)<<1);memory.append(fill(i)|(fill(i+1)<<16))
  last={};queue=collections.deque();imported=False;frame=0;snaps=[];lasts=[];checks=[];counts=collections.Counter();pending=[];serial=0
  # Source-derived pin commit times, not comparison alignment: OUT_REG=1,
  # inverted 9946ps mem clock and TB chip-clock wire delay 2000ps. Both
  # bw_read and registered m_take observations precede low/high pin writes
  # by 1.5/2.5 mem clocks plus that wire delay respectively.
  def commit(until):
   while pending and pending[0][0]<=until:
    _,_,a,d,mask,owner=heapq.heappop(pending);memory[a]=(memory[a]&~mask)|(d&mask);last[a]=owner
  def snapshot(s):
   commit(s['time_ps']);h=1469598103934665603
   for i,v in enumerate(memory):h=((h^((i<<32)|v))*1099511628211)&MASK
   actual=f'{h:x}';assert actual==s['memory_fnv64'][1],(side,s['frame'],actual,s['memory_fnv64'][1])
   snaps.append(memory.copy());lasts.append(last.copy());checks.append(dict(frame=s['frame'],time_ps=s['time_ps'],replayed_fnv64=actual,exact=True))
  with gzip.open(filtered,'rb')as f:
   f.read(16)
   for data in iter(lambda:f.read(40*32768),b''):
    for row in EV.iter_unpack(data):
     t,k,p,a,d,x,y,z=row
     while frame<len(states) and states[frame]['time_ps']<t:
      if not imported and states[frame]['time_ps']>=import_t:memory=initial.copy();last={};imported=True
      snapshot(states[frame]);frame+=1
     if not imported and t>=import_t:memory=initial.copy();last={};imported=True
     counts[str(k)]+=1
     if k in (23,24):queue.append(row);continue
     elif k==4:
      assert queue and queue[0][3:5]==(a,d),(side,row,queue[0]if queue else None)
      offer=queue.popleft();owner=dict(physical=row,accepted=offer,owner='display_capture'if offer[1]==24 else'video_writer');mask=0xffffffff
     else:
      mask=sum(255<<(8*b)for b in range(4)if x&(1<<b));owner=dict(physical=row,owner='SDRAM_client_write')
     for delay,half in [(16919,0xffff),(26865,0xffff0000)]:
      serial+=1;heapq.heappush(pending,(t+delay,serial,a,d,mask&half,owner))
  while frame<len(states):
   if not imported and states[frame]['time_ps']>=import_t:memory=initial.copy();last={};imported=True
   snapshot(states[frame]);frame+=1
  all_states.append(snaps);all_last.append(lasts);reports.append(dict(side=['baseline','candidate'][side],raw_manifest=manifest,raw_records=n,filtered_records=kept,filtered_sha256=sha(filtered),import_time_ps=import_t,import_sha256=sha(base/'inputs/imp_vram.hex'),write_event_counts=dict(counts),snapshots=checks,pending_FIFO_words=len(queue)))
 diffs=[]
 with gzip.open(B/'vram-changed-words.jsonl.gz','wt')as f:
  for frame,(aa,bb)in enumerate(zip(*all_states)):
   rows=[]
   for i,(a,b)in enumerate(zip(aa,bb)):
    if a!=b:
     old=all_last[0][frame].get(i);new=all_last[1][frame].get(i)
     assert old and new and old['owner']==new['owner']=='display_capture',(frame,i,old,new)
     row=dict(frame=frame,word_address=i,baseline=a,candidate=b,baseline_last_write=old,candidate_last_write=new);f.write(json.dumps(row)+'\n');rows.append(i)
   if rows:diffs.append(dict(frame=frame,changed_words=len(rows),first_word=rows[0],last_word=rows[-1],all_changed_words_last_written_by_accepted_display_capture=True))
 result=dict(status='PASS_ALL80_VRAM_SNAPSHOTS_REPLAYED_ALL_DIFFERENCES_CAPTURE_WRITES',source=json.loads((H/'source-relation.json').read_text())['source'],model=json.loads((H/'model.json').read_text())['sha256'],replays=reports,changed_snapshots=diffs,changed_words_file_sha256=sha(B/'vram-changed-words.jsonl.gz'),physical_pin_commit_delay_ps=dict(low=16919,high=26865,source='OUT_REG=1; inverted9946ps mem clock; TB chip wire delay2000ps; m_take registered2clocks after controller capture'),scope='Exact VRAM FNV attribution at original timestamps. Display-capture differences remain observable; this does not waive later raster regression or establish Census/DS equivalence.',seconds=time.monotonic()-start)
 put(B/'vram-attribution.json',result);print(json.dumps(dict(status=result['status'],changed_snapshots=diffs,seconds=result['seconds'])),flush=True)
if __name__=='__main__':main()
