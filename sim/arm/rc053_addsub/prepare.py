"""Pin immutable RC7 MLAB-control assets without running a CPU baseline."""
from pathlib import Path
import subprocess,json,hashlib,shutil
R=Path(__file__).resolve().parents[3];P=Path('/home/user/Git/NDS_Pocket-codex-rc7-rf-m10k/build/rf-m10k-cpu');Q=P.parent/'rf-m10k';D=R/'build/rc053-cpu';D.mkdir(exist_ok=True,parents=True);H=lambda b:hashlib.sha256(b).hexdigest();BASE='887187e64c420d5a5c87c9b8863bcf3a484d2b89'
meta=json.loads((P/'result.json').read_text());assert meta['base']==BASE and meta['PASS'] and len(meta['checks'])==83
assert (P/'reference.sv').read_bytes()==subprocess.check_output(['git','show',BASE+':rtl/arm/arm9_core.sv'],cwd=R)
files='arm_pkg arm_regfile arm_mul arm_thumb arm_core arm7_ds arm9_ram arm9_mem arm_cpu'.split();hashes={}
for n in files:
 f='rtl/arm/'+n+'.sv';b=subprocess.check_output(['git','show',BASE+':'+f],cwd=R);assert b==(R/f).read_bytes();hashes[f]=H(b)
f='sim/arm/tb_arm.sv';b=subprocess.check_output(['git','show',BASE+':'+f],cwd=R);assert b==(R/f).read_bytes();hashes[f]=H(b)
# Retain the original reference model/source/command and actual immutable input paths.
# Raw baseline trace hashes will be read during the leased comparison, not now.
r={'base':BASE,'source_hashes':hashes,'reference_source_SHA256':H((P/'reference.sv').read_bytes()),'baseline_receipt':str(P/'result.json'),'baseline_receipt_SHA256':H((P/'result.json').read_bytes()),'baseline_reference_command':json.loads((P/'reference-cmd.json').read_text()),'baseline_RF':'MLAB','candidate_RF':'MLAB','checks':meta['checks'],'inherited_failures':meta['inherited_failures'],'original_data':str(P),'status':'PREPARED_ONLY_NO_BUILD_OR_TEST','lease_required':True};(D/'control-binding.json').write_text(json.dumps(r,indent=2)+'\n');print('Prepared exact RC7 source/control binding; no RF work or baseline execution')
