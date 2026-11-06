#!/usr/bin/env python3
"""Stage the compact host ABI1 adapter; no compiler/model or ROM access."""
import argparse,difflib,hashlib,json,re,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
PIN='1ecda7d75b84f6c19c2254d957ad5cd2cd12bde5'
N58=Path('/home/user/Git/NDS_Pocket-codex-native58/build/joined-native58')
N60=Path('/home/user/Git/NDS_Pocket-codex-vram-joint-turn/build/vram-native60')

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,x):p.write_text(json.dumps(x,indent=2)+'\n')
def replace(s,old,new,edits):
 assert s.count(old)==1,(old,s.count(old));edits.append(dict(old=old,new=new));return s.replace(old,new)
def prepare(compact,out):
 out=out.resolve();assert not out.exists();out.mkdir(parents=True)
 read=lambda p:subprocess.check_output(['git','show',PIN+':'+p],cwd=compact).decode()
 tb=read('sim/pocket_ds/tb_ds_pocket.sv');runner=read('sim/pocket_ds/run.py');oldtb=tb;oldrunner=runner;edits=[];redits=[]
 ref58=(N58/'host-overlay/tb_native52.sv').read_text();ref60=(N60/'host-overlay/tb_native52.sv').read_text()
 def clean(s):return re.search(r'`ifdef CLEAN_BOOT\n    initial if[\s\S]*?\n`endif',s)[0]
 cleanblock=clean(ref58);assert cleanblock==clean(ref60)
 # Source-model defaults and physical pin timing remain the original models.
 model_checks={}
 for f in ['sim/phase1/cram_model.sv','sim/phase1/sdram_chip_model.sv','sim/phase1/sram_model.sv']:
  data=read(f).encode();assert data==(N58/'source'/f).read_bytes()==(N60/'source'/f).read_bytes();model_checks[f]=hashlib.sha256(data).hexdigest()
 old='`ifdef IMPORT\n  `define TB_MEM_DIRTY 0\n`else\n  `define TB_MEM_DIRTY 1\n`endif'
 new='`ifdef COMPACT_HOST_V1\n `ifdef CLEAN_BOOT\n  `define TB_MEM_DIRTY 0\n `elsif IMPORT\n  `define TB_MEM_DIRTY 0\n `else\n  `define TB_MEM_DIRTY 1\n `endif\n`else\n'+old+'\n`endif'
 tb=replace(tb,old,new,edits)
 mark='module tb_ds_pocket;'
 tb=replace(tb,mark,mark+'\n`ifdef COMPACT_HOST_V1\n `include "compact_profile.svh"\n `include "compact_wram.svh"\n`endif',edits)
 # This pinned compact source has serial VRAM: no early capture or CRB.
 # Retain its complete physical-read shadow. Native's VM guard accepts zero
 # CRB reads; do not invent accesses or reference nonexistent CRB signals.
 vram=read('rtl/ds/nds_vram.sv');top=read('rtl/pocket/core_top_ds.sv')
 assert 'chk_v' not in vram and 'vm_write_capture' not in top
 oldvm='    final if (vmc_on) $display("vmcheck: %0d words read, %0d mismatches", vmc_n, vmc_bad);'
 newvm='    // ABI1 pinned serial VRAM has no CPU block buffer.\n    final if (vmc_on) $display("vmcheck: %0d words read, 0 CPU reads from the block buffer, %0d mismatches", vmc_n, vmc_bad);'
 tb=replace(tb,oldvm,'`ifdef COMPACT_HOST_V1\n'+newvm+'\n`else\n'+oldvm+'\n`endif',edits)
 mark='    // ---------------- +preload:'
 assert tb.count(mark)==1
 tb=replace(tb,mark,'`ifdef COMPACT_HOST_V1\n'+cleanblock+'\n`endif\n\n'+mark,edits)
 line='        for (integer w = 0; w < 32\'h6000; w++) begin u_sram.mem[2 * w] = imp_sram[w][15:0]; u_sram.mem[2 * w + 1] = imp_sram[w][31:16]; end'
 tb=replace(tb,line,line+'\n`ifdef COMPACT_HOST_V1\n        compact_restore_wram();\n`endif',edits)
 mark='        void\'(\u0024value\u0024plusargs("timeout_ms=%d", timeout_ms));'
 tb=replace(tb,mark,'`ifdef COMPACT_HOST_V1\n        int stop_done=0;\n        void\'(\u0024value\u0024plusargs("stop_done=%d",stop_done));\n`endif\n'+mark,edits)
 old='            wait (v_frames >= frames);'
 new='`ifdef COMPACT_HOST_V1\n            while(v_frames<frames && !(stop_done && ram_word(32\'hFC000)==32\'h52545344 && ram_word(32\'hFC003)==1)) @(v_frames);\n`else\n'+old+'\n`endif'
 tb=replace(tb,old,new,edits)
 line='        $display("result: magic %h checks %0d mask %h done %0d", magic, n, mask, done);'
 tb=replace(tb,line,line+'\n`ifdef COMPACT_HOST_V1\n        if(stop_done)for(int i=0;i<n && i<32;i++)$display("value %0d %0d",i,ram_word(32\'hFC004+i));\n`endif',edits)
 # CLI opt-in never changes the existing mode's default or input bytes.
 mark='    a = ap.parse_args()'
 runner=replace(runner,mark,'    ap.add_argument("--compact-host-v1", action="store_true", help="explicit compact host ABI1")\n    ap.add_argument("--clean-boot", action="store_true", help="ABI1 native58/60 clean-zero boot")\n'+mark+'\n    if a.clean_boot and (not a.compact_host_v1 or a.imp):ap.error("--clean-boot requires --compact-host-v1 without --import")',redits)
 mark="    rom_aw = max(24, (Path(a.rom).stat().st_size - 1).bit_length() - 2)"
 runner=replace(runner,mark,'    if a.compact_host_v1:obj=obj.with_name(obj.name+"_compactv1"+("_clean"if a.clean_boot else""))\n'+mark,redits)
 mark="           '-I' + str(rtl / 'pocket'), '--Mdir', str(obj), *srcs]"
 runner=replace(runner,mark,'           *(["--assert", "+define+COMPACT_HOST_V1", "-I"+str(ROOT/"sim/pocket_ds")]if a.compact_host_v1 else[]), *(["+define+CLEAN_BOOT"]if a.clean_boot else[]),\n'+mark,redits)
 mark='    # the output passes through as it comes;'
 runner=replace(runner,mark,'    if a.compact_host_v1:plus.append("+compact_host_abi=1")\n'+mark,redits)
 profile=json.loads((Path('/home/user/Git/NDS_Pocket')/'build/coordinator/compact-fast-v1/profile.json').read_text())['parameters']
 profile.update(SHELL_CPU=2,BOOT_SRAM=1,ARM7_CACHE=1,A7_WRAM_SWP_PIPE=1)
 witness=['// Compact ABI1, source-specific constants only; no CPU/device writes.','localparam int COMPACT_HOST_ABI_VERSION=1;','initial begin',' int version;',' assert($value$plusargs("compact_host_abi=%d",version) && version==COMPACT_HOST_ABI_VERSION)else $fatal(1,"COMPACT_HOST_VERSION_REQUIRED");']
 witness += [f' assert(dut.{k}==={v})else $fatal(1,"COMPACT_PROFILE {k}");'for k,v in sorted(profile.items())]
 witness+=[' $display("COMPACT_HOST_ABI1_PROFILE_PASS");','end','']
 (out/'compact_profile.svh').write_text('\n'.join(witness));(out/'compact_wram.svh').write_bytes((HERE/'wram.svh').read_bytes())
 (out/'tb_ds_pocket.sv').write_text(tb);(out/'run.py').write_text(runner)
 patch=[]
 for name,before,after in [('run.py',oldrunner,runner),('tb_ds_pocket.sv',oldtb,tb),('compact_profile.svh','',(out/'compact_profile.svh').read_text()),('compact_wram.svh','',(out/'compact_wram.svh').read_text())]:
  patch.extend(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='a/sim/pocket_ds/'+name if before else '/dev/null',tofile='b/sim/pocket_ds/'+name))
 # Git accepts empty context lines without the otherwise trailing space.
 (out/'adapter.patch').write_text(''.join(patch).replace('\n \n','\n\n'))
 for name,after,before,changes in [('tb',tb,oldtb,edits),('runner',runner,oldrunner,redits)]:
  restored=after
  for e in reversed(changes):assert restored.count(e['new'])==1;restored=restored.replace(e['new'],e['old'])
  assert restored==before,name
 n58inputs=json.loads((N58/'inputs.json').read_text());n60inputs=json.loads((N60/'runs/unita7/manifest.json').read_text())
 image=n58inputs['rom_sha256']['unita7.nds'];assert image==n60inputs['ROM_sha256']
 write(out/'adapter.json',dict(version=1,compact_pin=PIN,default_enable=False,tb_edits=edits,runner_edits=redits,original_tb_sha256=hashlib.sha256(oldtb.encode()).hexdigest(),original_runner_sha256=hashlib.sha256(oldrunner.encode()).hexdigest(),profile=profile,physical_models=model_checks,clean_block_matches_native58_native60=True,VM_physical_shadow_unchanged=True,VM_block_buffer_absent=True,native58_rtl_source=n58inputs['source'],native60_rtl_source=n60inputs['source'],original_unita7_image_sha256=image,clean_block_sha256=hashlib.sha256(cleanblock.encode()).hexdigest(),input_image_or_oracle_changes=False,extra_waits_in_import_or_release=False,new_fullhost_models=0,files={n:sha(out/n)for n in ['run.py','tb_ds_pocket.sv','compact_profile.svh','compact_wram.svh']}))
 print('STAGED_COMPACT_HOST_ABI1_DEFAULT_OFF',out)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--compact',required=True,type=Path);p.add_argument('--out',required=True,type=Path);a=p.parse_args();prepare(a.compact,a.out)
