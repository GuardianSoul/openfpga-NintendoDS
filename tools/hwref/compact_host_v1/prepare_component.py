#!/usr/bin/env python3
"""Prepare small extracted host-code components, not a DS/game model."""
import argparse, hashlib, json, re, subprocess
from pathlib import Path
from prepare import HERE, PIN, N58, N60

def sha(b):return hashlib.sha256(b).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--compact',type=Path,required=True);p.add_argument('--adapter',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 out=a.out.resolve();assert not out.exists();out.mkdir(parents=True)
 read=lambda f:subprocess.check_output(['git','show',PIN+':'+f],cwd=a.compact).decode()
 tb=(a.adapter/'tb_ds_pocket.sv').read_text();meta=json.loads((a.adapter/'adapter.json').read_text())
 for f,h in meta['files'].items():assert sha((a.adapter/f).read_bytes())==h
 for f in ['compact_profile.svh','compact_wram.svh']:(out/f).write_bytes((a.adapter/f).read_bytes())
 # Only the fixture has faults; production header has no fault controls.
 wram=(a.adapter/'compact_wram.svh').read_text()
 old='  dut.ds.u_wram.u_private.mem[w]=imp_sram[w];'
 new='  if($test$plusargs("fault_wram_deposit") && w==0) dut.ds.u_wram.u_private.mem[w]=imp_sram[w+1];\n  else\n'+old
 assert wram.count(old)==1; (out/'component_wram.svh').write_text(wram.replace(old,new))
 finish=tb[tb.index('    integer timeout_ms = 2000, frames = 30;'):tb.index('    // Passive integration diagnostic:')]
 old='ram_word = {cram1.peek'
 new='if($test$plusargs("fault_value_address") && w>=32\'hFC004 && w<32\'hFC004+22)w=w+1;\n        '+old
 assert finish.count(old)==1;finish=finish.replace(old,new)
 clean=re.search(r'`ifdef COMPACT_HOST_V1\n`ifdef CLEAN_BOOT\n[\s\S]*?\n`endif\n`endif',tb)[0]
 vm=re.search(r'    bit vmc_on = 0;[\s\S]*?\n`endif',tb)[0]
 helpers=tb[tb.index('    function automatic int sd_index'):tb.index('    integer pl_blocks = 0;')]
 deposit=re.search(r'        for \(integer w = 0; w < 32\'h6000;[\s\S]*?\n`endif',tb)[0]
 native60=json.loads((N60/'runs/unita7/result.json').read_text())['guards']['values']
 assert len(native60)==22 and native60['21']==1
 template=(HERE/'component.sv.in').read_text()
 substitutions=dict(PROFILE_PARAMETERS='\n'.join('localparam int %s=%d;'%(k,v)for k,v in meta['profile'].items()),SD_HELPERS=helpers,CLEAN_BLOCK=clean,VM_BLOCK=vm,FINISH_BLOCK=finish,RESULT_WORDS='\n'.join("put('h%05x,%d);"%(0xfc004+int(k),v)for k,v in native60.items()),IMPORT_DEPOSIT=deposit)
 for k,v in substitutions.items():assert template.count('{{'+k+'}}')==1;template=template.replace('{{'+k+'}}',v)
 assert '{{'not in template;(out/'tb_component.sv').write_text(template)
 source_files={}
 for f in ['sim/phase1/cram_model.sv','sim/phase1/sdram_chip_model.sv','sim/phase1/sram_model.sv','rtl/arm/arm7_wram.sv','rtl/ds/nds_ram.sv']:
  dest=out/Path(f).name;dest.write_text(read(f));source_files[f]=sha(dest.read_bytes())
 # Pin the original guard without its unrelated full-speed route banners.
 # Its canonical/data/video/physical/VM/finish/no-error checks stay verbatim.
 guard=(N60/'native_guard.py').read_text();body=guard[guard.index('    final = re.findall'):guard.index('    if require_routes:flags')]
 guard='import re\ndef validate(text,checks,name):\n    result={}\n'+body+"    result['accepted']=all(result[k] for k in flags)\n    return result\n"
 (out/'native_guard.py').write_text(guard)
 # Default-off compilation must preprocess identically to the pinned host.
 oldtb=read('sim/pocket_ds/tb_ds_pocket.sv');(out/'original_tb.sv').write_text(oldtb)
 for key,filename,original in [('tb_edits','tb_ds_pocket.sv',oldtb),('runner_edits','run.py',read('sim/pocket_ds/run.py'))]:
  s=(a.adapter/filename).read_text()
  for e in reversed(meta[key]):assert s.count(e['new'])==1;s=s.replace(e['new'],e['old'])
  assert s==original
 # Source correspondence of native finish protocol; ds30 ROI is not in ABI1.
 native_finishes=[]
 for base in [N58,N60]:
  s=(base/'host-overlay/tb_native52.sv').read_text();s=s[s.index('    integer timeout_ms ='):];s=s[:s.index('    // DS-measured cache organization')]
  native_finishes.append(s)
 assert native_finishes[0]==native_finishes[1]
 verilator=Path('build/tools/oss-cad-suite/bin/verilator')
 plan={}
 for name,defines in [('ordinary',[]),('native',['COMPACT_HOST_V1','CLEAN_BOOT']),('import',['COMPACT_HOST_V1','IMPORT'])]:
  obj=out/('obj_'+name)
  plan['compile_'+name]=[str(verilator),'--binary','--timing','--assert','--threads','1','-j','1','-O1','-Wno-fatal','--top-module','tb_component','--Mdir',str(obj),'-I'+str(out),*['+define+'+d for d in defines],str(out/'tb_component.sv'),*[str(out/Path(f).name)for f in source_files]]
  args=[str(obj/'Vtb_component'),'+frames=3','+vmcheck']+(['+compact_host_abi=1']if defines else[])
  plan[name]=args+(['+stop_done=1']if name=='native'else[])
  if name=='native':
   for fault in ['value_address','vm_response']:plan[fault]=[*plan[name],'+fault_'+fault]
   plan['model_error']=[*plan[name],'+fault_model_error']
   plan['missing_version']=[x for x in plan[name]if x!='+compact_host_abi=1']
  if name=='import':plan['wram_deposit']=[*plan[name],'+fault_wram_deposit']
 (out/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
 (out/'source.json').write_text(json.dumps(dict(compact_pin=PIN,adapter=meta,component_files={f.name:sha(f.read_bytes())for f in out.iterdir()if f.suffix in ['.sv','.svh','.py']},source_files=source_files,synthetic_transport_payload_from_retained_native60_values=native60,original_native58_native60_finish_byte_equal=True,full_core_or_game_execution=False,private_native_model=False,original_guard_generic_body_sha256=sha(body.encode()),faults_only_in_component=True),indent=2)+'\n')
 print('COMPACT_HOST_COMPONENT_PREPARED',out)
if __name__=='__main__':main()
