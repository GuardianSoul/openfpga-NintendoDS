#!/usr/bin/env python3
"""Bounded production-cone proof; no CPU/native baseline rerun."""
from pathlib import Path
import os,json,subprocess,re,hashlib,resource
R=Path(__file__).resolve().parents[3];D=R/'build/main-dirty-mlab-proof';D.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
T=Path('build/tools/oss-cad-suite/bin')
src=(R/'rtl/arm/arm9_mem.sv').read_text();before=subprocess.check_output(['git','show','2c4e980c:rtl/arm/arm9_mem.sv'],cwd=R,text=True)
(D/'before.sv').write_text(before);(D/'after.sv').write_text(src)
r={'source_before':'2c4e980c','PID':os.getpid(),'NI':os.getpriority(os.PRIO_PROCESS,0),'jobs':1,'threads':1,'stages':[],'status':'ACTIVE'}
def save():
 p=D/'receipt.tmp';p.write_text(json.dumps(r,indent=2)+'\n');p.replace(D/'receipt.json')
def run(name,cmd,fault=False):
 with (D/(name+'.log')).open('w') as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=D,stdout=f,stderr=subprocess.STDOUT);row={'name':name,'PID':p.pid,'command':list(map(str,cmd))};r['stages'].append(row);save()
  try:row['exit']=p.wait(timeout=120)
  except subprocess.TimeoutExpired:p.terminate();row['exit']=p.wait(timeout=5);row['timeout']=True
  row['reaped']=True;save()
 text=(D/(name+'.log')).read_text();assert (row['exit']!=0 if fault else row['exit']==0),(name,text[-3000:])
 if fault:assert 'mismatch' in text,text
 print(name,row['exit'],text[-250:],flush=True)
# The complete production WB admission cone, unchanged byte for byte.
a=src.index('  always_comb begin\n    d_ok =');b=src.index('\n  end',a)+len('\n  end');body=src[a:b];assert body in before
# S_TAGW is in the literal busy_d=1 case. Every state giving clear is included.
assert 'S_TAG, S_EVRD, S_EVRD2, S_EVWR, S_FILL, S_TAGW: begin\n        busy_d = 1\'b1;' in src
assert "wire dirty_clear = !rst && MEM1 && st == S_TAGW;" in src
clean=re.sub(r'//[^\n]*','',body);ids=set(re.findall(r'\b[A-Za-z_]\w*\b',clean));keywords={'always_comb','begin','end','if','else','b0','b1'}
outputs={'d_ok','d_abort','wd_store_cache','wd_push','wd_need','wd_tcmw','cp_ok','wd_kind'};constants={x for x in ids if x.startswith('DK_')};inputs=sorted(ids-keywords-outputs-constants-{'cp_kind','busy_d'})
decl='module writers('+','.join('input '+n for n in inputs)+', input [2:0] cp_kind,input tagw, other_busy, rst, mem1, output safe);\n'
decl+='wire busy_d=tagw||other_busy;\nlogic '+','.join(sorted(outputs-{'wd_kind'}))+'; logic [2:0] wd_kind;\n'
decl+='\n'.join('localparam [2:0] '+n+'=3\'d'+str(i)+';' for i,n in enumerate(sorted(constants)))+'\n'+body+'\nassign safe= !((!rst&&mem1&&tagw)&&(!rst&&mem1&&wd_store_cache&&wd_buf));\nendmodule\n'
(D/'writers.sv').write_text(decl)
# Exact production helper plus a logical before-state oracle, all addresses/ways.
helper=src[src.index('module arm9_dirty_bank #'):];(D/'bank.sv').write_text(helper)
assert hashlib.sha256(helper.encode()).hexdigest() == '3f8aa441d586e28fd90274bc45798007d3cd37af48af11d43ff023cd9c03e124'
r['reused_native']='cbf0269a:docs/results/arm9-dirty-mlab-20261103/proof.tar.gz'
r['reused_helper_sha256']=hashlib.sha256(helper.encode()).hexdigest()
try:
 run('exclusive',[T/'yosys','-p','read_verilog -sv writers.sv; prep -top writers; sat -prove safe 1 -verify -show-inputs'])
 r['status']='PASS_MAIN_WRITER_EXCLUSIVITY_NATIVE_HELPER_BYTE_IDENTICAL'
finally:
 r['hashes']={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in D.iterdir() if f.is_file() and f.name!='receipt.json'};save()
