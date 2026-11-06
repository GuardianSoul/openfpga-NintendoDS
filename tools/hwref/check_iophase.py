#!/usr/bin/env python3
"""Check finite IO phase capture completeness/provenance separately from model fit."""
import argparse,csv,json,re,struct,tempfile
from pathlib import Path
from iophase_models import check as model_check

def fnv(raw):
 h=2166136261
 for v in raw:h=((h^v)*16777619)&0xffffffff
 return h

def expected_code(prefix,gap):
 x=[0xe92d40f0,0xe1a07000,0xe5904010,0xe3a05000]+[0xe1a08008]*64
 first=len(x)
 if prefix:x+=[0xe1a08008]
 x += [0xe1d400b0,0xe1a08008,0xe1d410b0]
 if gap:x+=[0xe1a08008]
 x += [0xe1c450b2,0xe1d420b0,0xe1d430b0]
 last=len(x)
 x += [0xe887000f,0xe8bd40f0,0xe12fff1e]
 return x,first,last

def check_flat(root,software=False):
 observations=model_check(root/'trials.csv')
 rows=list(csv.DictReader((root/'trials.csv').open()))
 for r in rows:
  values=[int(r['r'+str(i)],0) for i in range(4)]
  assert fnv(struct.pack('<4I',*values))==int(r['checksum'],0),'raw result checksum'
  assert int(r['restore_ok'])==1,'register restore failed'
  assert int(r['cpsr'],0)&0x80,'IRQ not masked in leaf'
 if software:
  # Software production sanity, never a DS timing/model-fit acceptance rule.
  assert all(o['stopped_value_stable'] for o in observations['observations']),'actual stopped-value result fault'
  assert all(o['control_before']==0x80 and o['control_after']==0 for o in observations['observations']),'software timer control state'
  assert all(o['read_read_ticks']>0 for o in observations['observations']),'software counter made no progress'
 code=list(csv.DictReader((root/'code.csv').open()))
 for case in range(4):
  x,first,last=expected_code(case%2,case//2)
  actual=[r for r in code if int(r['case'])==case]
  assert len(actual)==len(x) and [int(r['index']) for r in actual]==list(range(len(x))),'code coverage'
  assert [int(r['word'],0) for r in actual]==x,'actual ARM code differs'
  assert [int(r['in_leaf']) for r in actual]==[int(first<=i<last) for i in range(len(x))],'leaf boundary differs'
 assert len(code)==sum(len(expected_code(c%2,c//2)[0]) for c in range(4)),'extra code rows'
 assert(root/'progress.txt').read_text()==''.join(f'{verb} {c}\n'for c in range(4)for verb in ['start','done']),'incomplete journal'
 regs=list(csv.DictReader((root/'registers.csv').open()));assert len(regs)==128
 for c in range(4):
  for rep in range(16):
   pair=[r for r in regs if int(r['case'])==c and int(r['rep'])==rep]
   assert [r['tag']for r in pair]==['before','restored'],'missing paired register capture'
   for key in ['tm2cnt','dispcnt','bg0cnt','dispstat_stable']:assert pair[0][key]==pair[1][key],('register changed',key)
 text=(root/'info.txt').read_text();assert 'trials=64 restore_failures=0 complete=1' in text
 snapshots={}
 for tag in ['initial','restored']:
  lines=[s for s in text.splitlines()if s.startswith(tag+' ')]
  fields=dict(re.findall(r'(\w+)=([0-9a-fA-F]+)', ' '.join(lines)))
  snapshots[tag]={k:int(v,16)for k,v in fields.items()}
 assert snapshots['initial']==snapshots['restored'],'CP15 changed'
 config=snapshots['initial'];assert config['ctrl']&1,'MPU disabled'
 address=0x04000108;matches=[]
 for r in range(8):
  v=config['region'+str(r)];n=(v>>1)&31;size=2<<n;base=(v&0xfffff000)&~(size-1)
  if v&1 and base<=address<base+size:matches.append(r)
 assert matches,'no MPU IO mapping'
 region=max(matches);assert not(config['dc']>>region&1)and not(config['wb']>>region&1),'IO must be C0B0'
 m=re.search(r'code=([0-9a-f]+) context=([0-9a-f]+)',text);assert m
 assert 0x01ff8000<=int(m[1],16)<0x02000000,'kernel outside ITCM'
 assert 0x02ff0000<=int(m[2],16)<0x03000000,'context outside DTCM mapping'
 return dict(**observations,code_words=len(code),effective_IO_region=region,C0B0=True,source_state_restored=True,software_control=software,
   timing_scope='All raw counts retained; model fit is descriptive, including all-model rejection. No Census timing asserted as DS truth.')

def journal_audit(root,require_complete=True):
 tag=(root/'manifest.txt').read_text();lines=tag.splitlines()
 m=re.fullmatch(r'iophase-v2 source=([0-9a-f]{64}) cases=4 reps=16',lines[0]);assert m,'unbound version/source'
 source=m[1];assert len(lines)==5,'extra manifest data'
 expected_headers={}
 for case in range(4):
  words,first,last=expected_code(case%2,case//2);h=fnv(struct.pack('<'+'I'*len(words),*words))
  expected_headers[case]=f'iophase-v2 source={source} case={case} code={h:08x} reps=16\n'
  assert lines[case+1]==f'case{case} code={h:08x} words={len(words)} first={first} last={last}','manifest code differs'
 states=[0]*4;raw=(root/'progress.txt').read_text();assert not raw or raw.endswith('\n'),'truncated journal'
 for line in raw.splitlines():
  m=re.fullmatch('(start|done) ([0-3])',line);assert m,'malformed journal'
  verb,case=m[1],int(m[2]);assert states[case]==(0 if verb=='start'else 1),'duplicate/reordered journal'
  states[case]+=1
 completed=[i for i,v in enumerate(states)if v==2]
 for case in completed:
  text=(root/f'case{case}.commit').read_text();parts=text.splitlines(keepends=True)
  assert len(parts)==5 and parts[0]==expected_headers[case],'commit source/code differs'
  for part,suffix in zip(parts[1:],['trials.csv','code.csv','registers.csv','info.txt']):
   name=f'case{case}.{suffix}';data=(root/name).read_bytes()
   assert part==f'{name} {len(data)} {fnv(data):08x}\n','completed case checksum mismatch'
  rows=list(csv.DictReader((root/f'case{case}.trials.csv').open()))
  assert len(rows)==16 and {(int(r['case']),int(r['rep']))for r in rows}=={(case,r)for r in range(16)},'case raw coverage'
  text=(root/f'case{case}.info.txt').read_text();assert f'source={source} case={case} 'in text and'trials=16 restore_failures=0 complete=1'in text
  snapshots=[]
  for label in ['initial','restored']:snapshots.append([l[len(label):]for l in text.splitlines()if l.startswith(label+' ')])
  assert snapshots[0]==snapshots[1],'case CP15 changed'
 if require_complete:assert states==[2]*4,'incomplete return: interrupted/unmeasured cases remain'
 return dict(states=states,completed_cases=completed,interrupted_cases=[i for i,v in enumerate(states)if v==1],source_id=source)

def check(root,software=False):
 if not(root/'manifest.txt').exists():return check_flat(root,software)
 # Software result faults are observations even with a faulted code identity.
 # Detect the actual result fault independently before normal-code provenance.
 if software:
  rows=[r for c in range(4)for r in csv.DictReader((root/f'case{c}.trials.csv').open())]
  assert all(int(r['r2'],0)==int(r['r3'],0)for r in rows),'actual stopped-value result fault'
 audit=journal_audit(root)
 with tempfile.TemporaryDirectory(prefix='iophase-journal-check-')as td:
  dest=Path(td)
  for suffix in ['trials.csv','code.csv','registers.csv']:
   texts=[(root/f'case{c}.{suffix}').read_text().splitlines(keepends=True)for c in range(4)]
   assert all(t[0]==texts[0][0]for t in texts),'case format mismatch'
   (dest/suffix).write_text(''.join(texts[0]+[line for t in texts[1:]for line in t[1:]]))
  text=(root/'case0.info.txt').read_text().replace('trials=16 restore_failures=0 complete=1','trials=64 restore_failures=0 complete=1')
  (dest/'info.txt').write_text(text);(dest/'progress.txt').write_bytes((root/'progress.txt').read_bytes())
  result=check_flat(dest,software)
 return dict(**result,journal=audit,case_durability='Each START, raw/code/state commit and DONE is independently closed; completed case hashes verified before reuse.')
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);p.add_argument('--software-control',action='store_true');a=p.parse_args()
 print(json.dumps(check(a.root,a.software_control),indent=2))
