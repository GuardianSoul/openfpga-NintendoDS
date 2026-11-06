#!/usr/bin/env python3
"""Pin original C19 frontend/ABI/link inputs and prepare a private observer job."""
from pathlib import Path
import hashlib,json,shutil,sys
ROOT=Path(__file__).resolve().parents[3]
ORIGINAL=Path('/home/user/Git/NDS_Pocket-codex-shell/build/sound-full-v2-a9-dispatch-ready')
REFERENCE=Path('/home/user/Git/NDS_Pocket-codex-shell/build/sound-v2-reference-dispatch-run1')
BASE=ROOT/'build/census-current-rules-4faa92bc'
sha=lambda p:hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
def prepare(job):
 job=Path(job);assert not job.exists();job.mkdir()
 plan=json.loads((ORIGINAL/'plan.json').read_text());ref=json.loads((REFERENCE/'result.json').read_text())
 assert sha(ORIGINAL/'plan.json')==ref['prepared_plan_sha256']=='799bc51dab1c0af8e76ac1836da553020d0ce4773290faa94c6a0b8f2edc7ce5'
 assert sha(REFERENCE/'result.json')=='5f6c225e222c4903a63573e937052ef1f257f3c556e008618836b5dcb44c8e32'
 for n,h in plan['frontend_sha256'].items():assert sha(ORIGINAL/'census-frontend'/n)==h
 for n,h in ref['link_input_sha256'].items():assert sha(Path(n))==h
 front=job/'frontend';shutil.copytree(ORIGINAL/'census-frontend',front)
 s=(front/'census.cpp').read_text();anchor='static u32 curLine = 0;';assert s.count(anchor)==1;s=s.replace(anchor,anchor+'\n#include "sound_epoch.inc"')
 anchor='static void OnSPUMix(SPU& s)\n{';assert s.count(anchor)==1;s=s.replace(anchor,anchor+'\n    SoundEpochObserveMix(s);')
 anchor='    SoundV2Retire(cpu,pc);';assert s.count(anchor)==1;s=s.replace(anchor,'    SoundEpochLateRetire(cpu,pc);\n'+anchor);(front/'census.cpp').write_text(s)
 p=front/'sound_v2_entry.inc';s=p.read_text();anchor='    ExportState(nds,dir);';assert s.count(anchor)==1;s=s.replace(anchor,'    SoundEpochBegin(command);\n'+anchor)
 anchor='    // Keep running. The complete CSV/PCM outputs';assert s.count(anchor)==1;s=s.replace(anchor,'    SoundEpochFinish(dir,command,retiredPC);\n'+anchor);p.write_text(s)
 shutil.copy2(Path(__file__).with_name('observer.inc'),front/'sound_epoch.inc');shutil.copy2(Path(__file__).with_name('check.py'),job/'check.py')
 shutil.copytree(BASE/'melonDS/src',job/'core-headers',ignore=shutil.ignore_patterns('.git','*.o','*.a','__pycache__'))
 (job/'generated-headers').mkdir()
 for p in (BASE/'build/melonDS/src').glob('*.h'):shutil.copy2(p,job/'generated-headers'/p.name)
 for sub in ['gpu2d','sound']:shutil.copytree(BASE/'project/sim'/sub,job/'aux-headers'/sub,ignore=shutil.ignore_patterns('obj','obj_dir','*.o','*.a','__pycache__'))
 (job/'link').mkdir()
 for n,h in ref['link_input_sha256'].items():shutil.copy2(n,job/'link'/Path(n).name)
 (job/'inputs').mkdir();shutil.copy2(ROOT/'build/hwref-trip20261031/perftime.nds',job/'inputs/perftime.nds');shutil.copy2(ROOT/'build/hwref-trip20261031/preflight/perftime-final/script.txt',job/'inputs/script.txt')
 q=json.loads((ROOT/'build/hwref-trip20261031/preflight/perftime-final/qualification.json').read_text());shutil.copy2(ROOT/'build/hwref-trip20261031/preflight/perftime-final/qualification.json',job/'original-qualification.json')
 assert sha(job/'inputs/perftime.nds')==q['rom_sha256']=='f228ab533c1e58f1824f429f4a39128fe4b8acc789d6e7fd3ddfa7030aaf2f44'
 (job/'seed').mkdir()
 for n,h in q['output_sha256'].items():
  if Path(n).name.startswith('perftime'):continue
  source=ROOT/'build/hwref-trip20261031/preflight/perftime-final/sd'/n;assert sha(source)==h;dest=job/'seed'/n;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,dest)
 shutil.copytree(REFERENCE/'entries/c7684',job/'original-entry')
 for n,h in ref['entries']['7684'].items():assert sha(job/'original-entry'/n)==h
 (job/'original-reference.json').write_text(json.dumps(ref,indent=2)+'\n')
 shutil.copy2('/home/user/Git/NDS_Pocket/tools/ds/sim_ownership.py',job/'sim_ownership.py')
 compile_args=next(x['argv']for x in ref['commands']if x['name']=='compile');defs=[x for x in compile_args if x.startswith('-D')]
 data=dict(status='prepared original C19 +read-only observer; no execution',source_plan_sha256=ref['prepared_plan_sha256'],source_frontend_sha256=plan['frontend_sha256'],compile_defines=defs,link_inputs={Path(n).name:h for n,h in ref['link_input_sha256'].items()},ROM_sha256=q['rom_sha256'],bios_firmware_sha256=q['bios_firmware_sha256'],ownership_helper_sha256=sha(job/'sim_ownership.py'))
 (job/'plan.json').write_text(json.dumps(data,indent=2)+'\n')
 manifest={str(p.relative_to(job)):sha(p)for p in job.rglob('*')if p.is_file()};(job/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');return job
if __name__=='__main__':prepare(Path(sys.argv[1]).resolve())
