#!/usr/bin/env python3
"""Prepare a passive DS30 overlay for an explicit immutable Root; never build/run."""
from pathlib import Path
import argparse,difflib,hashlib,json,shutil,subprocess
HERE=Path(__file__).resolve().parent;REPO=HERE.parents[2]
sha=lambda b:hashlib.sha256(b).hexdigest()
def prepare(root,adapter,out):
 assert not out.exists();out.mkdir(parents=True)
 m=json.loads((adapter/'manifest.json').read_text());original=(adapter/'captured/arm7time.nds').read_bytes()
 assert sha(original)==m['retained_producer_SHA256']['arm7time.nds']
 assert m['ROM_SHA256']=='5163eb3cb0653b6278be3604e4abb827c85513d58175c67cb7e3987fea2e333e'
 assert sha((adapter/'arm7-ds30.nds').read_bytes())==m['ROM_SHA256']
 source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
 paths=['sim/pocket_ds/tb_ds_pocket.sv','rtl/arm/arm_core.sv','rtl/arm/arm_cpu.sv','rtl/arm/arm9_mem.sv','rtl/arm/arm9_ram.sv','rtl/arm/arm_regfile.sv','rtl/arm/arm7_wram.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_ram.sv','rtl/ds/nds_top.sv','rtl/arm/cpu_domain.sv','rtl/sys/nds_sys.sv']
 hashes={n:sha((root/n).read_bytes())for n in paths}
 for n in paths:
  if n.startswith('rtl/'):
   assert sha(subprocess.check_output(['git','show',source+':'+n],cwd=root))==hashes[n],('dirty production source',n)
 bodies=[];blob=bytearray()
 for row in m['preserved_bodies']:
  data=original[row['ROM_offset']:row['ROM_offset']+row['bytes']];assert sha(data)==row['sha256']
  bodies.append(dict(row,file_offset=len(blob)));blob+=data
 assert len(bodies)==25
 def function(name,values):
  return 'function automatic integer '+name+'(input integer i);\n case(i)\n'+''.join(f" {i}:return 32'h{v:08x};\n"for i,v in enumerate(values))+' default:return 0;\n endcase\nendfunction\n'
 table='localparam integer DS30_BYTES='+str(len(blob))+';\n'+''.join(function(name,[r[field]for r in bodies])for name,field in [('ds30_cpu','cpu'),('ds30_address','address'),('ds30_size','bytes')])
 target='sim/pocket_ds/tb_ds_pocket.sv';before=(root/target).read_text();after=before
 anchor='    // ---------------- finish ----------------';assert after.count(anchor)==1
 observer=(HERE/'observer.svh').read_text()
 marker=sha((observer+table).encode())
 after=after.replace(anchor,'    // DS30_OBSERVER_INPUT_SHA256 '+marker+'\n    `include "sim/pocket_ds/ds30_observer.svh"\n'+anchor)
 if 'wait (v_frames >= frames);'in after:
  assert after.count('wait (v_frames >= frames);')==1;after=after.replace('wait (v_frames >= frames);','wait (v_frames >= frames || ds30_done);')
 else:
  anchor='while (v_frames < frames && !(stop_done && ram_word(32\'hFC000) == 32\'h52545344 && ram_word(32\'hFC003) == 1)) @(v_frames);'
  assert after.count(anchor)==1,'unknown finish hook; preserve existing coordinator harness'
  after=after.replace(anchor,anchor.replace('v_frames < frames &&','v_frames < frames && !ds30_done &&').replace('@(v_frames);','@(v_frames or ds30_done);'))
 overlays={target:after,'sim/pocket_ds/ds30_observer.svh':observer,'sim/pocket_ds/ds30_tables.svh':table}
 patch=''
 for n,text in overlays.items():
  old=before if n==target else ''
  assert n==target or not(root/n).exists()
  patch+=''.join(difflib.unified_diff(old.splitlines(True),text.splitlines(True),fromfile='a/'+n if old else '/dev/null',tofile='b/'+n))
  p=out/'overlay'/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
 # Git accepts empty context lines without a prefix; avoid trailing-space
 # warnings when the unified patch itself is committed as a text artifact.
 patch=''.join('\n'if line==' \n'else line for line in patch.splitlines(True))
 (out/'overlay.patch').write_text(patch);(out/'run-assets').mkdir();(out/'run-assets/ds30_expected.hex').write_text(''.join(f'{v:02x}\n'for v in blob))
 shutil.copy2(adapter/'manifest.json',out/'adapter-manifest.json');shutil.copy2(adapter/'arm7-ds30.nds',out/'arm7-ds30.nds')
 shutil.copy2(HERE/'check_observer.py',out/'check_observer.py');shutil.copy2(HERE/'check.py',out/'check.py')
 shutil.copy2(HERE/'selftest_observer.py',out/'selftest_observer.py')
 required=dict(CPU_FAST=0,A9_SOLO=5,A9_OPT=461366243)
 plan=dict(status='SOURCE-ONLY READY PATCH; no HDL compile/elaboration/native execution',source=source,source_hashes=hashes,ROM_SHA256=m['ROM_SHA256'],bodies=bodies,total_body_bytes=len(blob),overlay_SHA256={n:sha(t.encode())for n,t in overlays.items()},patch_SHA256=sha(patch.encode()),expected_hex_SHA256=sha((out/'run-assets/ds30_expected.hex').read_bytes()),
  required_profile=required,plusargs=['+ds30_observe=OUTPUT_PREFIX','+ds30_expected='+str(out/'run-assets/ds30_expected.hex'),'+frames=160','+timeout_ms=3000'],wall_watchdog_seconds=7200,
  host_source_SHA256={p.name:sha(p.read_bytes())for p in [Path(__file__),HERE/'observer.svh',HERE/'check_observer.py',HERE/'check.py']},
  build_integration=dict(compile_cwd='frozen source root',include_root='frozen source root',apply_before='existing tb_canonical harness generation',cache_binding='TB comment hashes observer+tables, forcing cache-key change when either changes',observer_tables_SHA256=marker),
  checkpoints=dict(ping=0x0200145c,endpoint=0x02001f34),commands=[0x81]+[int(r['arg'])*256+i for i,name in enumerate(dict.fromkeys(r['kernel']for r in m['DS_rows']))for r in m['DS_rows']if r['kernel']==name],
  semantics='Direct unmerged ARM9 preposedge retirement; latch pc/CPSR/R0 then snapshot postNBA+1ps. Host arrays/files/testbench completion only; no DUT deposits, forces or guest APIs. DUAL_WRITE RF backing is explicitly required.',
  completion='50 exact body checks+32calls/32returns+full MAIN dump, then host ds30_done wakes normal finish path with existing video/model/final VM guards. No canonical test header is synthesized.',
  limitations=['No native/HDL proof yet; actual next changed-source build must elaborate declared hierarchy and execute.', 'Retrospective DS live-context/prehistory limitations unchanged; no timing acceptance from loaded-body equality.', 'No CPU FE admission observer or RTL changes; no new DS probe/baseline.'])
 assert len(plan['commands'])==32
 (out/'hook-manifest.json').write_text(json.dumps(plan,indent=2)+'\n')
 subprocess.run(['git','apply','--check',str(out/'overlay.patch')],cwd=root,check=True)
 return plan
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--adapter',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();m=prepare(a.root.resolve(),a.adapter.resolve(),a.out.resolve());print(json.dumps({k:m[k]for k in ['status','source','total_body_bytes','patch_SHA256']},indent=2))
