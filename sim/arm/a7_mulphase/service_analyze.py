#!/usr/bin/env python3
"""Bounded saved-evidence constraints; no RTL model or timing extrapolation."""
from pathlib import Path
from fractions import Fraction as F
from collections import Counter
import argparse,csv,hashlib,io,json,os,resource,tarfile

p=argparse.ArgumentParser(description=__doc__);p.add_argument('packet',type=Path);a=p.parse_args();D=a.packet.resolve()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CPU,(30,30));resource.setrlimit(resource.RLIMIT_AS,(512*1024**2,512*1024**2))
sha=lambda b:hashlib.sha256(b).hexdigest()
receipt=json.loads((D/'inputs.json').read_text());assert sha(Path(__file__).read_bytes())==receipt['analyzer_SHA256'];archive=(D/'inputs.tar.gz').read_bytes();assert sha(archive)==receipt['archive_SHA256']
with tarfile.open(fileobj=io.BytesIO(archive))as t:
 files={m.name:t.extractfile(m).read()for m in t if m.isfile()}
assert set(files)==set(receipt['files'])
for n,h in receipt['files'].items():assert sha(files[n])==h,n
js=lambda n:json.loads(files[n])
ds=js('DS-MUL.json')['MUL_summary'];main=[];wram=[];raw=[]
for m in range(1,5):
 pair={r['region']:r for r in ds if r['m']==m};assert len(pair)==2
 for region,rows in [('MAIN',main),('private_WRAM',wram)]:
  row=pair[region];assert len(row['ticks4'])==len(row['ticks16'])==5
  assert len(set(row['ticks4']))==len(set(row['ticks16']))==1
  short=min(row['ticks4']);long=min(row['ticks16']);slope=F(long-short,768);assert slope==F(row['slope']);rows.append(slope)
  # An algebraic two-length decomposition only, not a wrapper/loop price.
  loop=F(long-short,12);intercept=short-4*loop
  raw.append(dict(m=m,region=region,short=short,long=long,per_loop=str(loop),two_length_intercept=str(intercept)))
assert main==[F(591,64)]*3+[F(655,64)]and wram==[F(m,1)+F(17,16)for m in range(1,5)]
delta=lambda xs:[str(b-a)for a,b in zip(xs,xs[1:])]
ordinary=js('DS39.json')['summaries'];native=js('CPU39.json')['rows'];thumb=js('DS42.json')
assert len(ordinary)==len(native)==36
assert all(r['core']==r['DS']for r in native if r['region']==0)
assert thumb['probe_paired_slopes_PASS']and thumb['absolute_window_difference_ticks']==67
for row in ordinary:
 n=next(r for r in native if r['case']==row['name']and r['region']==int(row['region']=='MAIN'))
 assert F(n['DS'])==F(row['min16']-row['min4'],768)
# Negative controls demonstrate that these constraints are actually checked.
def accepted_vector(v):return v==[F(591,64)]*3+[F(655,64)]
assert not accepted_vector([main[0]]*4)and not accepted_vector([x+F(1,768)for x in main])
uniform=[1]*64
def local(ms):return 399+sum(max(3,m)for m in ms)
def shared(ms):
 assert len(ms)%2==0
 return 399+sum(max(6,ms[i]+ms[i+1])for i in range(0,len(ms),2))
for m in range(1,5):
 ms=[m]*64;assert F(local(ms),64)==main[m-1]==F(shared(ms),64)
 r=next(r for r in ds if r['m']==m and r['region']=='private_WRAM')
 for n in [4,16]:assert 137+n*(68+64*m)==r['ticks'+str(n)][0]
 for n in [4,16]:
  r=next(r for r in ds if r['m']==m and r['region']=='MAIN')
  assert 136+n*local(ms)==136+n*shared(ms)==r['ticks'+str(n)][0]
mixed=[1,4]*32
counterexamples=dict(local_clipping=dict(per_loop=local(mixed),slope=str(F(local(mixed),64)),short=136+4*local(mixed),long=136+16*local(mixed)),
 shared_window=dict(per_loop=shared(mixed),slope=str(F(shared(mixed),64)),short=136+4*shared(mixed),long=136+16*shared(mixed)))
assert counterexamples['local_clipping']['short']-counterexamples['shared_window']['short']==128
assert counterexamples['local_clipping']['long']-counterexamples['shared_window']['long']==512
core=js('component.json')['cases'];padding=[main[m-1]-F(core[f'{m-1}-1']['core_A7_slope'])for m in range(1,5)]
assert len(set(padding))>1
# Join original F preparation to each first/last executed internal advance,
# and to the original consumer. This is observed old-source ordering only.
hist=lambda xs:dict(sorted(Counter(map(str,xs)).items()))
traces={}
for case in range(4):
 b=files[f'c{case}.edge'];assert len(b)<8*1024**2
 hexcols={'pc','ins','ia','iq','flow_a','fa','fq','opa','opb'}
 rows=[{k:int(v,16 if k in hexcols else 10)for k,v in r.items()}for r in csv.DictReader(io.StringIO(b.decode()))];assert len(rows)<65536
 capture=None;tokens=[];by_capture={};last_steps={};age=[];fdelta=[];consume=[];ready=[];prepared=[];seq=[];left=[]
 for pos,r in enumerate(rows):
  if r['ir']and not r['flow_v']and 0x02fcd000<=r['ia']<0x02fcd110:
   capture=dict(cycle=r['cycle'],address=r['ia'],pc=r['pc'],seq=r['iseq']);by_capture[capture['cycle']]=capture
  if r['e_mul']and r['pipe_fire']and r['esub']in [0,1]and 0x02fcd004<=r['pc']<0x02fcd104:
   assert r['ins']==0xe0030291 and r['mterm']==case+1
   if r['esub']==0:
    assert capture and capture['address']==r['ia'];capture.update(first=r['cycle'],Epc=r['pc'],last=r['cycle']);tokens.append(capture)
    seq.append(capture['seq']);left.append(r['flow_left']);age.append(r['cycle']-capture['cycle']);fdelta.append(r['ia']-r['pc']);prepared.append(r['pc']-capture['pc'])
   else:
    assert capture and 'first'in capture;capture['last']=r['cycle']
  if capture and 'first'in capture and r['ph']and r['io']and r['flow_v']and r['flow_a']==r['ia']>>2:
   if pos and rows[pos-1]['ir']and rows[pos-1]['cycle']==r['cycle']-1 and rows[pos-1]['ia']==r['ia']:
    capture.setdefault('qualified_ready',r['cycle'])
  if r['consume']and capture and 'first'in capture:
   assert r['ia']==capture['address'];capture['consume']=r['cycle']
   consume.append(r['cycle']-capture['first'])
   if 'qualified_ready'in capture:ready.append(r['cycle']-capture['qualified_ready'])
 assert len(tokens)==1024 and all('consume'in x for x in tokens)
 assert hist(seq)=={'1':1024}and hist(left)=={'2':1024}
 assert hist(age)=={'1':1024}and hist(fdelta)=={'8':1024}and hist(prepared)=={'0':1024}
 assert hist(x['last']-x['first']for x in tokens)=={str(2*case):1024}
 traces[str(case)]=dict(bytes=len(b),rows=len(rows),MUL_owners=len(tokens),captured_seq=hist(seq),first_step_flow_left=hist(left),capture_to_first_SYS=hist(age),F_address_minus_E_PC=hist(fdelta),E_PC_change_since_capture=hist(prepared),
  first_to_last_advance_SYS=hist(x['last']-x['first']for x in tokens),first_to_consume_SYS=hist(consume),qualified_ready_to_consume_SYS=hist(ready),
  scope='Existing source/quiet fixture; actual consume is separate from the qualified-ready observation. No DS F-phase trace or retimed model.')
source=files['source/nds_arm7_port.sv'].decode();cpu=files['source/arm7_ds.sv'].decode()
assert "flow_left <= i_seq && !(first_s && n_block != i_addr[31:5]) ? 5'd2 : 5'd16;"in source
assert "if (flow_v && flow_left != 5'd0) flow_left <= flow_left - 5'd1;"in source
assert 'offer_owned ? held_context : current_context'in cpu
out=dict(status='PASS bounded constraints; unique DS bus law NOT identified',source=receipt['source'],raw=raw,
 finite_deltas=dict(MAIN=delta(main),WRAM=delta(wram)),required_addition_to_current_component=list(map(str,padding)),
 empirical_witnesses=dict(scope='Two arithmetic accounting families, not physical timing laws. Intercepts/399 are fitted to two measured lengths; no cost subtraction or extrapolated acceptance.',same_all80_raw_times=True,mixed_32small_32large=counterexamples,
  proposed_discriminator='Same272B pair-opcode body, alternating Rs r2/r6; initialize bothsmall/bothlarge/mixed outside timed64-MUL body. Same-code matched anchors required. Not built, staged or requested.'),
 trace_frontiers=traces,
 retained_constraints=dict(MAIN_layouts=18,private_WRAM_layouts=18,all_WRAM_exact=True,Thumb_streams=9,Thumb_pairs=45,Thumb_absolute_plus67_retained=True,
  MAIN_rows=[dict(name=r['name'],DS=r['cycles_per_unit'],native=next(n['core']for n in native if n['region']==1 and n['case']==r['name']))for r in ordinary if r['region']=='MAIN']),
 selected='Original-F ownership and request/execution separation only; finite MAIN derivative[0,0,1]. Reject fixed pad, serialized width cost and a floor applied to the current whole component total; no unique N/S/I price or commit placement.',
 next='Memory: preserve the original descriptor, model logical prepare/commit/finish separately, and predeclare cross-operation/mixed-width prediction before a service prototype. Root public wiring after native61. Existing evidence cannot select local vs shared overlap; no extra native baseline or hardware probe performed.')
print(json.dumps(out,indent=2))
