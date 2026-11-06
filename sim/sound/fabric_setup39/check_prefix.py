"""Require exact original live prefix before interpreting the new fabric trace."""
from pathlib import Path
import tarfile,json,hashlib,csv,io,re
W=Path(__file__).resolve().parents[3];B=W/'build/sound-fabric39';O=B/'result';A=Path('/home/user/Git/NDS_Pocket-cpu-if4-credit/build/a7-native42-finished.tar.gz')
log=(B/'native.log').read_text();m=re.search(r'SOUND_FABRIC_PREARM_STOP cycle=(\d+) capture0=0 capture1=0',log);assert m,'missing actual pre-arm stop/capture-off';stop=int(m[1]);assert stop==8687721,stop
assert not (O/'packet.bin').exists(),'full capture/reply should not occur'
assert 'SND_V2_REPLY'not in log

def prefix(b):
 result=[]
 for line in b.splitlines(keepends=True):
  if line.startswith(b'#END'):continue
  first=line.split(b',',1)[0]
  if first.isdigit():
   if int(first)>stop:break
   if b',COVER,'in line:continue
  result.append(line)
 return b''.join(result)
receipts={}
with tarfile.open(A)as t:
 for p in sorted(O.glob('*.csv')):
  if p.name=='fabric.csv':continue
  name='sound/result-c7684/'+p.name;old=t.extractfile(name).read();new=p.read_bytes();x,y=prefix(old),prefix(new)
  assert x==y,(p.name,len(x),len(y),'original observable prefix changed')
  receipts[p.name]={'bytes':len(y),'rows':len(y.splitlines()),'prefix_sha256':hashlib.sha256(y).hexdigest(),'old_full_sha256':hashlib.sha256(old).hexdigest(),'new_full_sha256':hashlib.sha256(new).hexdigest()}
 assert len(receipts)==8,receipts.keys()
plan=json.loads((B/'plan.json').read_text())
for n,h in plan['source_sha256'].items():assert hashlib.sha256((B/'source'/n).read_bytes()).hexdigest()==h,n
for n,h in plan['entry_sha256'].items():assert hashlib.sha256((B/'import'/n).read_bytes()).hexdigest()==h,n
for n,h in plan['runtime_sha256'].items():assert hashlib.sha256((B/'native'/n).read_bytes()).hexdigest()==h,n
result={'status':'PASS','stop_cycle':stop,'capture_off':True,'no_full_PCM_or_reply':True,'original_source_files_unchanged':len(plan['source_sha256']),'entry_files_unchanged':len(plan['entry_sha256']),'all_original_live_trace_prefixes_byte_identical':receipts,'terminal_scope':'Old final #END/COVER records are completion summaries for different run lengths; only live rows through actual pre-arm stop compared. No live CPU/P7/store/event row changed.'}
(B/'prefix-qualification.json').write_text(json.dumps(result,indent=2)+'\n');print('PREFIX_PASS',len(receipts),'originalobserverfiles; prearm',stop,'allruntimeimages/source/entry unchanged')
