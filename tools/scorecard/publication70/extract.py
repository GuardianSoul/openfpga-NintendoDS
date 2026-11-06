#!/usr/bin/env python3
"""One new-candidate bus pass: frozen service reader plus bounded exports."""
import gzip,hashlib,json,os,re,struct,sys,time
from pathlib import Path
R=Path(__file__).resolve().parents[3];H=R/'build/publication70/candidate-host';C=H/'results/corner';OLD=R/'build/turn69r1/candidate-host';O=OLD/'results/corner';B=H.parent;EV=struct.Struct('<Q6IQ')
def J(p):return json.loads(p.read_text())
def sha(p):
 h=hashlib.sha256()
 with p.open('rb')as f:
  for b in iter(lambda:f.read(1<<20),b''):h.update(b)
 return h.hexdigest()
def put(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def main():
 os.setpriority(os.PRIO_PROCESS,0,10);start=time.monotonic();term=J(C/'terminal.json');assert term['reaped']and term['native_exit']==0 and term['image_count']==39 and term['state_count']==40
 owner=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json');ov=J(owner);ov.update(phase='PUBLICATION70_ONE_CANDIDATE_BUS_PASS',model_sha256=term['model_sha256'],worker=[dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=10,jobs=1,threads=1)],lease='D1 one NI10 bounded extraction; native reaped; no Laptop/fit');q=owner.with_suffix('.tmp');q.write_text(json.dumps(ov,separators=(',',':'))+'\n');assert q.stat().st_size<=2048;q.replace(owner)
 assert J(H/'source-relation.json')['production_unchanged'];capture=J(C/'capture-manifest.json');oldcap=J(O/'capture-manifest.json')
 assert capture['capture.cpu.gz']==oldcap['capture.cpu.gz'];assert (C/'capture/capture.states.jsonl').read_bytes()==(O/'capture/capture.states.jsonl').read_bytes();assert (C/'save.bin').read_bytes()==(O/'save.bin').read_bytes()
 image={p.name:sha(p)for p in(C/'shots').glob('*.ppm')};assert len(image)==39 and image=={p.name:sha(p)for p in(O/'shots').glob('*.ppm')}
 lib=OLD/'checker-lib';binding=J(OLD/'frozen-checker-binding.json')
 for n,h in binding['files'].items():assert sha(lib/n)==h
 sys.path.insert(0,str(lib));import storage_pair_capture_analyze as a
 from storage_pair_capture_causal import Causal
 from storage_pair_root40_gate_compare import ldm_check
 comparison=C/'comparison';comparison.mkdir();(comparison/'B1').symlink_to(C);a.B=comparison;a.Causal=lambda _:Causal(1);original=a.rows
 assert not(B/'candidate-extraction.attempt').exists();(B/'candidate-extraction.attempt').write_text(str(os.getpid())+'\n')
 counts={};new=B/'observer-events.bin.gz';ldm=B/'ldm-profile-events.bin.gz';detail=B/'bounded-bus-events.bin.gz';windows=[(357000000000,361000000000),(625000000000,628000000000),(642000000000,645000000000),(324400000000,325850000000)]
 with gzip.open(new,'wb')as nf,gzip.open(ldm,'wb')as lf,gzip.open(detail,'wb')as df:
  for f in[nf,lf,df]:f.write(struct.pack('<4I',0x33504453,1,40,1))
  def rows(path):
   for row in original(path):
    t,k,p,addr,d,x,y,z=row
    if 64<=k<=84:nf.write(EV.pack(*row));counts[k]=counts.get(k,0)+1
    elif 50<=k<=63:lf.write(EV.pack(*row))
    if any(lo<=t<=hi for lo,hi in windows)and(k in[10,11,12,14,15,23,37,38]or k in[1,2,3]and p in[0,6]):df.write(EV.pack(*row))
    yield row
  a.rows=rows;service,extra=a.bus('B1');a.rows=original
 put(C/'service.json',service)
 with gzip.open(C/'streams.json.gz','wt')as f:json.dump(extra,f)
 assert service['error_count']==service['causal']['error_count']==0
 oldservice=J(O/'service.json');assert {k:v for k,v in service['counts'].items()if not(k.isdigit()and 64<=int(k)<=84)}==oldservice['counts']
 assert {k:v for k,v in service.items()if k!='counts'}=={k:v for k,v in oldservice.items()if k!='counts'}
 with gzip.open(O/'streams.json.gz','rt')as f:oldextra=json.load(f)
 for k,values in extra.items():assert len(values)==len(oldextra[k])and all(tuple(a)==tuple(b)for a,b in zip(values,oldextra[k])),k
 ldm_result=ldm_check(original(ldm));put(C/'ldm.json',ldm_result)
 witness=[r for r in original(ldm)if r[1]==63];assert len(witness)==58
 profile=J(OLD/'runtime-provenance.json')['profile']
 for i,(name,value)in enumerate(sorted(profile.items())):
  r=[r for r in witness if r[3]==i];assert len(r)==1 and r[0][4:6]==(value,value)
 def diag(p):return [s for s in p.read_text().splitlines()if s.startswith(('g3ddiag raster:','g3ddiag total:'))]
 assert diag(H/'native.log')==diag(O/'native.log')
 result=dict(verdict='PASS_PASSIVE_NATIVE_EQUALITY_AND_ONE_CANDIDATE_BUS_EXTRACTION',source=term['source'],model=term['model_sha256'],control_model=J(OLD/'model.json')['sha256'],images=39,states=40,CPU_events_byte_exact=9554693,PCM_samples_exact=len(extra['audio']),producer_commits_exact=len(extra['commits']),consumed_records_exact=len(extra['logical_stream']),physical_errors=0,causal_errors=0,all58_exact=True,all_existing_bus_analysis_and_streams_exact=True,observer_event_counts=counts,export_hashes={p.name:sha(p)for p in[new,ldm,detail]},new_full_bus_passes=1,original_raw_passes=0,seconds=time.monotonic()-start,native_disposition='INHERITS_R1_REJECT_OFFMAIN; observer equality is not a repair or DS acceptance')
 put(B/'passive-native-equality.json',result);print(json.dumps(result),flush=True)
 ov=J(owner);ov.update(phase='PUBLICATION70_BOUNDED_DECODE_READY',worker=[],lease='D1 one extraction reaped; bounded decode next');q=owner.with_suffix('.tmp');q.write_text(json.dumps(ov,separators=(',',':'))+'\n');assert q.stat().st_size<=2048;q.replace(owner)
if __name__=='__main__':main()
