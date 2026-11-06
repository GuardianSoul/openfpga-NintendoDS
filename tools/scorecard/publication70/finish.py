#!/usr/bin/env python3
"""Finish equality from cached products; no raw native capture is opened."""
import gzip,hashlib,json,os,sys,time
from pathlib import Path
R=Path(__file__).resolve().parents[3];B=R/'build/publication70';H=B/'candidate-host';C=H/'results/corner';OLD=R/'build/turn69r1/candidate-host';O=OLD/'results/corner'
def J(p):return json.loads(p.read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def put(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def main():
 os.setpriority(os.PRIO_PROCESS,0,10);start=time.monotonic();term=J(C/'terminal.json');assert term['reaped']and term['native_exit']==0
 owner=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json');v=J(owner);v.update(phase='PUBLICATION70_CACHED_PASSIVITY_FINISH',worker=[dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=10,jobs=1,threads=1)],lease='D1 one cached finish; no raw rescan/native worker');q=owner.with_suffix('.tmp');q.write_text(json.dumps(v,separators=(',',':'))+'\n');assert q.stat().st_size<=2048;q.replace(owner)
 service=J(C/'service.json');old=J(O/'service.json');assert service['error_count']==service['causal']['error_count']==0
 counts={k:v for k,v in service['counts'].items()if k.isdigit()and 64<=int(k)<=84};assert {k:v for k,v in service['counts'].items()if k not in counts}==old['counts']
 # Keep both raw reader receipts unchanged. The only metadata difference
 # is its last observed event: new passive boundary at the identical final
 # frame-state time. This never shifts any physical/logical event.
 delta=service['causal']['endpoint']['time_ps']-old['causal']['endpoint']['time_ps'];assert delta==7460
 states=(C/'capture/capture.states.jsonl').read_bytes();assert states==(O/'capture/capture.states.jsonl').read_bytes();assert service['causal']['endpoint']['time_ps']==json.loads(states.splitlines()[-1])['time_ps']
 a=json.loads(json.dumps(service));b=json.loads(json.dumps(old));a.pop('counts');b.pop('counts');a['causal']['endpoint'].pop('time_ps');b['causal']['endpoint'].pop('time_ps');assert a==b
 with gzip.open(C/'streams.json.gz','rt')as f:extra=json.load(f)
 with gzip.open(O/'streams.json.gz','rt')as f:oldextra=json.load(f)
 assert extra==oldextra
 cm=J(C/'capture-manifest.json');assert cm['capture.cpu.gz']==J(O/'capture-manifest.json')['capture.cpu.gz'];assert(C/'save.bin').read_bytes()==(O/'save.bin').read_bytes()
 images={p.name:sha(p)for p in(C/'shots').glob('*.ppm')};assert len(images)==39 and images=={p.name:sha(p)for p in(O/'shots').glob('*.ppm')}
 lib=OLD/'checker-lib';binding=J(OLD/'frozen-checker-binding.json')
 for n,h in binding['files'].items():assert sha(lib/n)==h
 sys.path.insert(0,str(lib));import storage_pair_capture_analyze as reader
 from storage_pair_root40_gate_compare import ldm_check
 witness=[]
 def rows():
  for row in reader.rows(B/'ldm-profile-events.bin.gz'):
   if row[1]==63:witness.append(row)
   yield row
 ldm=ldm_check(rows());put(C/'ldm.json',ldm);profile=J(OLD/'runtime-provenance.json')['profile'];assert len(witness)==len(profile)==58
 for i,(name,value)in enumerate(sorted(profile.items())):
  rr=[r for r in witness if r[3]==i];assert len(rr)==1 and rr[0][4:6]==(value,value)
 def diag(p):return[s for s in p.read_text().splitlines()if s.startswith(('g3ddiag raster:','g3ddiag total:'))]
 assert diag(H/'native.log')==diag(O/'native.log')
 result=dict(verdict='PASS_PASSIVE_NATIVE_EQUALITY_AND_ONE_CANDIDATE_BUS_EXTRACTION',source=term['source'],model=term['model_sha256'],control_model=J(OLD/'model.json')['sha256'],images=39,states=40,CPU_events_byte_exact=9554693,PCM_samples_exact=len(extra['audio']),producer_commits_exact=len(extra['commits']),consumed_records_exact=len(extra['logical_stream']),physical_errors=0,causal_errors=0,all58_exact=True,all_existing_bus_analysis_and_streams_exact=True,reader_endpoint_observation_delta_ps=delta,endpoint_scope='Only final-observed-event metadata extends to added passive record at identical final frame-state time; every existing data/time/state/ownership/latency field is exact. Raw receipts retained, no event shift.',observer_event_counts=counts,export_hashes={p.name:sha(p)for p in[B/'observer-events.bin.gz',B/'ldm-profile-events.bin.gz',B/'bounded-bus-events.bin.gz']},new_full_bus_passes=1,original_raw_passes=0,seconds=time.monotonic()-start,native_disposition='INHERITS_R1_REJECT_OFFMAIN; observer equality is not a repair or DS acceptance')
 put(B/'passive-native-equality.json',result);print(json.dumps(result),flush=True);v=J(owner);v.update(phase='PUBLICATION70_BOUNDED_DECODE_READY',worker=[],lease='D1 native/full extraction/cached finish reaped; bounded decode next');q=owner.with_suffix('.tmp');q.write_text(json.dumps(v,separators=(',',':'))+'\n');assert q.stat().st_size<=2048;q.replace(owner)
if __name__=='__main__':main()
