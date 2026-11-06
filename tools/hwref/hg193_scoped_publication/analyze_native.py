#!/usr/bin/env python3
"""Analyze bounded publication console/source evidence without raw/ELF reads."""
import argparse,hashlib,json,re,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from source_gate import audit,NAMES,generate

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def analyze(host,parent,out):
 out.mkdir(exist_ok=False,parents=True)
 source=json.loads((host/'native-source-check.json').read_text());pin=json.loads((host/'model-pin.json').read_text());complete=json.loads((host/'complete.json').read_text())
 text=(host/'diagnostic/native.log').read_text();old=(parent/'diagnostic/native.log').read_text()
 schema=json.loads((host/'protected-schema.json').read_text())
 # Console identity up to the strict control boundary, not a new execution or
 # a substitute for reference CPU-state/game/pace equivalence.
 prefixes=('HG193_CPU_CLAUSE','HG193_CPU_RAW','HG193_OWNER','HG193_CALLER','HG193_ALL_GUARD')
 oldlines=[s for s in old.splitlines()if s.startswith(prefixes)];newlines=[s for s in text.splitlines()if s.startswith(prefixes)]
 identity=oldlines==newlines
 compact_prefixes=('HG193_MISSING','HG193_STUB_WORD','HG193_BRIDGE_HISTORY','HG193_SELECTED_STUB')
 compact_old=[s for s in old.splitlines()if s.startswith(compact_prefixes)];compact_new=[s for s in text.splitlines()if s.startswith(compact_prefixes)]
 compact_identity=compact_old==compact_new
 markerrows={}
 for line in text.splitlines():
  if line.startswith('HG193_NATIVE_'):
   key=line.split()[0];assert key not in markerrows,('duplicate marker',key);markerrows[key]=line
 expectedtime=source['expected_publication_time_ps']
 success=complete['pass']and complete['native_exit']==0
 result=dict(source=pin['source'],profile=60,model_sha256=pin['binary_sha256'],native_pass=success,markers=markerrows,original_point_console_identity=identity,original_point_console_lines=len(oldlines),compact_observation_identity=compact_identity,compact_observation_lines=len(compact_old),protected_fields=schema['field_count'],protected_elements=schema['element_count'],original_input_contract_sha256=sha(host/'diagnostic/cwd-binding.json'),raw_scans=0,elf_reads=0,fullscene_or_pace_qualification=False,default_enable=0,explicit_flag=True)
 if success:
  assert identity and len(oldlines)>450
  before=markerrows['HG193_NATIVE_BEFORE'];after=markerrows['HG193_NATIVE_PUBLICATION_READBACK_PASS']
  for row in [before,after]:assert f'ticks_ps={expectedtime}'in row,row
  assert 'returned=3'in before and 'fourthvalid=1'in before and 'pending_a7_ack=0'in before
  assert 'default0=0 optin=1'in after
  assert f"fields={schema['field_count']} elements={schema['element_count']}"in markerrows['HG193_NATIVE_PROTECTED_READBACK_PASS']
  tail=markerrows['HG193_NATIVE_BOUNDED_PASS'];edges=int(re.search(r'edges=(\d+)',tail)[1]);assert 1<=edges<128
  times={name:int(re.search(r'ticks_ps=(\d+)',row)[1])for name,row in markerrows.items()if 'ticks_ps='in row}
  assert times['HG193_NATIVE_FOURTH_ACCEPT']>expectedtime
  assert times['HG193_NATIVE_A9_DONE']>=times['HG193_NATIVE_FOURTH_ACCEPT']
  assert times['HG193_NATIVE_P7_DONE']>=times['HG193_NATIVE_P7_SAMPLE']>expectedtime
  sample=re.search(r'data=(\w+)',markerrows['HG193_NATIVE_P7_SAMPLE'])[1]
  assert 'data='+sample in markerrows['HG193_NATIVE_P7_DONE']and 'p7='+sample in tail
  result.update(publication_time_ps=expectedtime,publication_duration_ps=0,post_release_edges=edges,completion_times_ps=times,p7_sample=sample)
 # Preserve exact source/deposit proof for the actually compiled publisher.
 sources={n:(host/'include'/n).read_text()for n in NAMES}
 tb=(host/'observed-overlay/tb_native52_import.sv').read_text()
 for name in ['sd_index','sd_poke32','sd_peek32']:
  m=re.search(r'(?:function|task) automatic [^\n]*\b'+name+r'\([\s\S]*?end(?:function|task)',tb);assert m,name;sources[name+'.svh']=m[0]+'\n'
 proof=audit(sources);assert len(proof['hierarchical_deposits'])==2907
 proof['source_sha256']={n:hashlib.sha256(s.encode()).hexdigest()for n,s in sources.items()}
 for n,s in sources.items():(out/n).write_text(s)
 (out/'write-set.json').write_text(json.dumps(proof,indent=2)+'\n')
 hook=(host/'include/hg193_combined_hook.svh').read_text()
 for c in reversed(source['hook_edits']):assert hook.count(c['new'])==c['count'];hook=hook.replace(c['new'],c['old'])
 assert hashlib.sha256(hook.encode()).hexdigest()==source['parent_hook_sha256']
 assert hook==(parent/'include/hg193_combined_hook.svh').read_text()
 for n in ['hg193_sd_pair.svh','hg193_combined_drain.svh']:
  assert(host/'include'/n).read_bytes()==(parent/'include'/n).read_bytes()
 assert tb==(parent/'observed-overlay/tb_native52_import.sv').read_text()
 original=(host/'include/hg193_combined_drain.svh').read_text();generated,guard=generate(original)
 assert generated.replace('HG193_SCOPED_DEFAULT_ENABLE &&','(HG193_SCOPED_DEFAULT_ENABLE || hg193_proposal_enable) &&')==(host/'include/generated_native_scoped_drain.svh').read_text()
 result.update(exact_publisher_assignment_sites=len(proof['hierarchical_deposits']),source_write_set_disjoint=proof['disjoint'],default_hook_reconstruction=True,original_importer_byte_identical=True,guard_proposal=guard)
 (out/'qualification.json').write_text(json.dumps(result,indent=2)+'\n');return result
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--host',required=True,type=Path);p.add_argument('--parent',required=True,type=Path);p.add_argument('--out',required=True,type=Path);a=p.parse_args();r=analyze(a.host.resolve(),a.parent.resolve(),a.out.resolve());print(json.dumps({k:r[k]for k in ['native_pass','original_point_console_identity','protected_fields','exact_publisher_assignment_sites','default_hook_reconstruction']},indent=2))
