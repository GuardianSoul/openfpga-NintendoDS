#!/usr/bin/env python3
"""Check disabled host equivalence, native finish correspondence and CLI argv."""
import argparse, contextlib, hashlib, importlib.util, io, json, os, re, subprocess, sys
from pathlib import Path
from unittest.mock import patch
from prepare import PIN,N58,N60

def load(p,name):
 spec=importlib.util.spec_from_file_location(name,p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--compact',type=Path,required=True);p.add_argument('--adapter',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();out=a.out.resolve();assert not out.exists();out.mkdir(parents=True)
 v='build/tools/oss-cad-suite/bin/verilator'
 read=lambda f:subprocess.check_output(['git','show',PIN+':'+f],cwd=a.compact).decode()
 originaltb=out/'original_tb.sv';originaltb.write_text(read('sim/pocket_ds/tb_ds_pocket.sv'))
 originalrunner=out/'original_run.py';originalrunner.write_text(read('sim/pocket_ds/run.py'))
 def pp(f,defines=[]):
  r=subprocess.run([v,'-E','-P','-I'+str(a.adapter.resolve()),*['+define+'+d for d in defines],str(f)],capture_output=True,text=True,preexec_fn=lambda:os.setpriority(os.PRIO_PROCESS,0,10));assert r.returncode==0,r.stderr;return r.stdout
 compacttb=a.adapter/'tb_ds_pocket.sv';disabled=pp(compacttb);base=pp(originaltb)
 # Ignore formatting outside string literals; keep all printed text exact.
 squash=lambda s:re.sub(r'("(?:\\.|[^"\\])*")|\s+',lambda m:m[1] or '',s)
 assert squash(disabled)==squash(base)
 # IMPORT must also be identical with the ABI disabled (no deposit changes).
 assert squash(pp(compacttb,['IMPORT']))==squash(pp(originaltb,['IMPORT']))
 native=pp(compacttb,['COMPACT_HOST_V1','CLEAN_BOOT'])
 def finish(s):
  s=s[s.index('    integer timeout_ms ='):];s=s[:s.index('        $finish;')+len('        $finish;')]
  s=re.sub(r'//[^\n]*','',s);return s
 compactfinish=finish(native)
 refs=[]
 for basepath in [N58,N60]:
  s=(basepath/'host-overlay/tb_native52.sv').read_text()
  s=s[s.index('    integer timeout_ms ='):];s=s[:s.index('    // DS-measured cache organization')]
  # Exclude disabled, unrelated sound ROI include and IMPORT clause.
  s=re.sub(r'    `include "sound_v2_roi.svh"\n','',s)
  s=re.sub(r'`ifdef IMPORT[\s\S]*?`endif','',s)
  s=s.replace(' && !ds30_done','').replace('@(v_frames or ds30_done)','@(v_frames)')
  s=re.sub(r'`G_LOG\((\w+)\)',r'dut.g_log.\1',s)
  # Reading the three independent plusargs has no event/delay dependency.
  stop='        void\'($value$plusargs("stop_done=%d", stop_done));\n'
  assert s.count(stop)==1;s=s.replace(stop,'');mark='        int stop_done = 0;\n';s=s.replace(mark,mark+stop)
  refs.append(squash(finish(s)))
 assert refs[0]==refs[1]==squash(compactfinish)
 # Exercise the actual runner using only generated 4-byte files and mocked
 # build/process calls: no original ROM reads and no model invocation.
 root=out/'synthetic-root';root.mkdir();images=root/'images';images.mkdir()
 for name in ['bios9.bin','bios7.bin','firmware.bin','fixture.nds']:(images/name).write_bytes(bytes([1,2,3,4]))
 for rel in ['build/boot/bootrom.hex','sw/boot/bootrom.bin','sw/scpu/cache.bin','sw/scpu/mbox.hex']:
  f=root/rel;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(b'00000000\n'if f.suffix in ['.hex']else b'\0\0\0\0')
 def invoke(script,extra):
  m=load(script,'runner_under_check');m.ROOT=root;calls=[]
  class Dummy:
   def __init__(self,cmd,**kw):calls.append(('model',cmd));self.stdout=iter([])
   def wait(self):return 0
  def run(cmd,**kw):calls.append(('build',cmd));return subprocess.CompletedProcess(cmd,0,'','')
  argv=[str(script),'--rom',str(images/'fixture.nds'),'--roms-dir',str(images),'--out',str(root/'out'),*extra]
  with patch.object(sys,'argv',argv),patch.object(m.subprocess,'run',run),patch.object(m.subprocess,'Popen',Dummy),contextlib.redirect_stdout(io.StringIO()):
   try:m.main()
   except SystemExit as e:assert e.code==0,e.code
  return calls
 original=invoke(originalrunner,[]);ordinary=invoke(a.adapter/'run.py',[]);assert ordinary==original
 enabled=invoke(a.adapter/'run.py',['--compact-host-v1','--clean-boot','--plus','stop_done=1','--vmcheck'])
 compilecmd=[cmd for kind,cmd in enabled if kind=='build'and'--binary'in cmd][0]
 assert '--assert'in compilecmd and '+define+COMPACT_HOST_V1'in compilecmd and '+define+CLEAN_BOOT'in compilecmd
 model=[cmd for kind,cmd in enabled if kind=='model'][0]
 assert '+compact_host_abi=1'in model and '+stop_done=1'in model and '+vmcheck'in model
 assert '_compactv1_clean'in model[0] and '_compactv1'not in [cmd for kind,cmd in ordinary if kind=='model'][0][0]
 for flags in [['--clean-boot'],['--compact-host-v1','--clean-boot','--import','unused']]:
  m=load(a.adapter/'run.py','invalid_args')
  with patch.object(sys,'argv',['run.py',*flags]),contextlib.redirect_stderr(io.StringIO()):
   try:m.main();assert False
   except SystemExit as e:assert e.code==2
 result=dict(disabled_native_preprocessing_equal=True,disabled_import_preprocessing_equal=True,disabled_nonwhitespace_sha256=hashlib.sha256(squash(disabled).encode()).hexdigest(),native58_native60_unit_finish_correspondence=True,unit_finish_excludes_inactive_ds30_and_sound_ROI=True,ordinary_runner_build_and_run_argv_byte_equal=True,opt_in_assert_defines_unique_obj_plusargs=True,invalid_modes_rejected=True,only_generated_files_opened_for_runner_spy=True,actual_model_invocations=0)
 (out/'check.json').write_text(json.dumps(result,indent=2)+'\n');print('COMPACT_HOST_SOURCE_AND_RUNNER_CHECK_PASS')
if __name__=='__main__':main()
