#!/usr/bin/env python3
"""Retained bounded packets and cached record metadata only; no raw trace scan."""
import bisect,collections,gzip,hashlib,json,os,struct,time
from pathlib import Path
R=Path(__file__).resolve().parents[2];B=R/'build/turn69r1';C=B/'candidate-host/results/corner';OLD=R/'build/record68/candidate-host/results/corner';EV=struct.Struct('<Q6IQ')
def J(p):return json.loads(p.read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def put(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def window(name):
 p=B/(name+'-window.bin');v=J(B/'trace-attribution-windows.json')['windows'][name];assert sha(p)==v['sha256'];q=collections.deque();offer=None;reads=[];writes=collections.defaultdict(list)
 for t,k,port,a,d,x,y,z in EV.iter_unpack(p.read_bytes()):
  if k==11 and x:writes[(a-0x80000)>>8].append([t,a&255,d])
  elif k==10 and port==6:
   if x&4 and offer is None:offer=t
   if x&2:q.append(dict(address=a,offer=offer,ACK=t,returns=[]));offer=None
   if x&1 and q:
    v=q[0];v['returns'].append([t,d])
    if len(v['returns'])==8:reads.append(q.popleft())
 return reads,writes
os.setpriority(os.PRIO_PROCESS,0,10);start=time.monotonic();assert J(B/'analysis-controller-status.json')['phase']=='FULL39_ANALYSIS_COMPLETE_NO_AUTO_DS_ACCEPTANCE'
owner=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json');v=J(owner);v.update(phase='TURN69R1_BOUNDED_CAUSAL_CACHE',worker=[dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=10,jobs=1,threads=1)],lease='D1 one bounded/cached NI10 reader; all native/integrity workers reaped');q=owner.with_suffix('.tmp');q.write_text(json.dumps(v,separators=(',',':'))+'\n');assert q.stat().st_size<=2048;q.replace(owner)
first,fw=window('first');rr=[r for r in first if r['address']&~255==0x83800];ww=fw[86];deadline=153982370694
assert len(rr)==32 and len(ww)==256 and[r['address']&255 for r in rr]==list(range(0,256,8))and[r[1]for r in ww]==list(range(256))
assert rr[0]['returns'][0][1]==0x7f8b9e and rr[-1]['returns'][-1][0]<deadline
read_between_write_blocks=[]
for i in range(7,248,8):
 a=ww[i][0];z=ww[i+1][0];rs=[r['address']&255 for r in rr if a<r['ACK']<z]
 if rs:read_between_write_blocks.append(dict(after_write_word=i,previous_ACK=a,next_ACK=z,read56_blocks=rs))
newreads,nw=window('regression');selected={};summary={}
for side,base in [('Record68',OLD),('r1',C)]:
 binding=J(base/'analysis-prefix-binding.json');p=base/'streams.json.gz';assert sha(p)==binding['files']['streams.json.gz']
 with gzip.open(p,'rt')as f:s=json.load(f)
 eof=[r[0]for r in s['stream']if r[1]==3];groups={};lines=[]
 for y in range(130,136):
  records=[r for r in s['logical_stream']if 357000000000<=r[0]<=361000000000 and r[5]==y]
  if not records:lines.append(dict(line=y,status='NO_SELECTED_RECORDS'));continue
  identity={(r[2],r[4])for r in records};assert len(identity)==1
  bank,gen=next(iter(identity));use=[r for r in s['uses']if r[1]in[0,1]and r[3]==bank and r[5]==gen and r[4]==y and 357000000000<=r[0]<=records[-1][0]]
  ds=[r for r in s['deadlines']if r[1]==y and 357000000000<=r[0]<=361000000000];assert len(ds)==1
  d=ds[0];ei=bisect.bisect_left(eof,records[-1][0]);assert ei<len(eof)
  row=dict(line=y,bank=bank,generation=gen,records=len(records),first_lookup=use[0][0],last_consumption=records[-1][0],EOF=eof[ei],deadline=d,records_consumed_before_deadline=sum(r[0]<d[0]for r in records),EOF_relative_deadline_ps=eof[ei]-d[0],lookup_attempts=len(use));lines.append(row);groups[str(y)]=records
 target=[r for r in s['logical_stream']if r[2]==1 and r[4]==3802 and r[5]==56 and 146000000000<=r[0]<=154100000000];assert len(target)==20
 summary[side]=dict(binding=binding,lines=lines,row56_records=target,row56_deadlines=[d for d in s['deadlines']if d[0]==deadline]);selected[side]=dict(target_row56=target,regression_lines=groups)
 del s
same={}
for y in range(130,136):
 a=selected['Record68']['regression_lines'].get(str(y),[]);b=selected['r1']['regression_lines'].get(str(y),[]);same[str(y)]=dict(data_order_exact=[r[1:]for r in a]==[r[1:]for r in b],original_timestamp_differences=sum(a[0]!=b[0]for a,b in zip(a,b)),Record68_records=len(a),r1_records=len(b))
assert all(r['data_order_exact']for r in same.values())
with gzip.open(B/'causal-selected-records.json.gz','wt')as f:json.dump(selected,f)
reg132=[r for r in newreads if r['address']&~255==0x88400]
result=dict(source=J(B/'candidate-host/source-relation.json')['source'],model=J(B/'candidate-host/model.json')['sha256'],status='FIRST_ROW_CONSUMER_FIX_PINNED_LATER_IMAGE_REGRESSION_REJECTED',first_row56=dict(required_words=256,received_before_deadline=256,first_offer=rr[0]['offer'],last_return=rr[-1]['returns'][-1][0],deadline=deadline,slack_ps=deadline-rr[-1]['returns'][-1][0],first_pixel_SYS=rr[0]['returns'][0],read56_packet_count=len(rr),write86_first_ACK=ww[0][0],write86_last_ACK=ww[-1][0],accepted_write86_words=len(ww),native_read_write_block_turns=read_between_write_blocks,expiries=[]),cached_metadata=summary,regression_line_data_order=same,first_new_pixel_vs_Record68=dict(raw=21,reference=16,x=7,y=132,candidate=[0,199,251],Record68_and_Census=[203,219,227]),regression_row132_SYS_packets=[dict(address=r['address'],offer=r['offer'],ACK=r['ACK'],last_return=r['returns'][-1][0])for r in reg132],selected_records_sha256=sha(B/'causal-selected-records.json.gz'),scope='Original timestamps/IDs and exact records. Full producer/data/order proof is separate. wsafe observations do not stand in for l3d_have: staging/direct/LLR are active. Individual rb_v/lc/front-line history was not captured, so this report does not invent the exact partial-copy pixel mechanism.',next_action='Keep source rejected. If Root assigns another required changed model, batch passive rb_v/lc/front-line and original-producer-opportunity/writer-service counters; no unchanged-model rerun or journal-depth change.',seconds=time.monotonic()-start)
put(B/'causal-boundary.json',result);print(json.dumps(dict(status=result['status'],first_row56=result['first_row56'],lines={side:value['lines']for side,value in summary.items()},seconds=result['seconds'])),flush=True)
v=J(owner);v.update(phase='TURN69R1_REJECT_PACKET_SEAL',worker=[],lease='D1 analysis reaped; sealing/source-only next');q=owner.with_suffix('.tmp');q.write_text(json.dumps(v,separators=(',',':'))+'\n');assert q.stat().st_size<=2048;q.replace(owner)
