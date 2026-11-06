#!/usr/bin/env python3
from pathlib import Path
import re,json,subprocess,os
R=Path(__file__).resolve().parents[3];D=R/'build/clip16-dirty-batch';os.setpriority(os.PRIO_PROCESS,0,10)
def body_at(s,a):
 start=s.index('{',a);depth=1;i=start+1
 while depth:
  if s[i]=='{':depth+=1
  elif s[i]=='}':depth-=1
  i+=1
 return s[start+1:i-1]
def audit(path):
 texts={f.name:f.read_text() for f in path.glob('*.cpp')};alltext='\n'.join(texts.values())
 clocks={clock:int(idx) for idx,clock in re.findall(r'region trigger index (\d+) is active: @\(posedge apf_top.ic.core_pll.(clk_sys|clk_2x)\)',alltext)}
 assert set(clocks)=={'clk_sys','clk_2x'},clocks
 funcs={};masks={}
 for text in texts.values():
  for m in re.finditer(r'^void (\w+)\([^\n]*\) \{',text,re.M):funcs[m[1]]=body_at(text,m.start())
  for m in re.finditer(r'if \(\(\(\((0x[0-9a-fA-F]+)ULL & vlSelfRef.__VnbaTriggered\[0U\]\)\) != 0ULL\)\) \{',text):
   for func in re.findall(r'(Vapf_top\w+)\(vlSelf\);',body_at(text,m.start())):masks.setdefault(func,set()).add(int(m[1],16))
 prefix='apf_top__DOT__ic__DOT__ds__DOT__g_3d__DOT__u_gpu3d__DOT__u_geom__DOT__u_eng__DOT__g_cl__DOT__u_clip__DOT__g_store_pump__DOT__u_store__DOT__'
 result={'clocks':clocks,'fields':{}}
 for field,clock in [('epoch','clk_sys'),('pending_data','clk_sys'),('inside_addr','clk_sys'),('seen','clk_2x'),('outside_word__BRA__0__KET__','clk_2x')]:
  found=[]
  pattern=r'vlSelfRef\.'+re.escape(prefix+field)+r'\s*='
  for name,body in funcs.items():
   if 'nba_sequent' in name and re.search(pattern,body):found.append({'function':name,'masks':sorted(masks.get(name,set()))})
  assert found,(field,'no generated driver')
  expected=1<<clocks[clock]
  assert all(row['masks']==[expected] for row in found),(field,clock,found)
  result['fields'][field]={'expected_clock':clock,'drivers':found}
 return result
r={'enabled':audit(D/'obj'),'PID':os.getpid(),'NI':10,'jobs':1,'threads':1}
f=D/'rtl/gpu3d/gpu3d_gxeng.sv';src=f.read_text();a=src.index(')) u_clip (');b=src.index(');',a);mutant=src[:a]+src[a:b].replace('.clk2(clk_2x)', '.clk2(clk)',1)+src[b:];assert mutant!=src;f.write_text(mutant);(D/'actual-disconnect.sv').write_text(mutant)
cmd=json.loads((D/'receipt.json').read_text())['stages'][0]['command'];cmd[cmd.index('--Mdir')+1]=str(D/'disconnectobj')
try:
 with(D/'disconnect-codegen.log').open('w')as log:
  p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT);rc=p.wait(timeout=120)
 r['stage']={'PID':p.pid,'exit':rc,'reaped':True};assert rc==0
 try:audit(D/'disconnectobj')
 except AssertionError as e:r['fault']='CAUGHT';r['witness']=str(e)
 else:raise AssertionError('actual SYS-for-FAST disconnect escaped generated driver audit')
finally:f.write_text(src)
r['status']='PASS_RESOLVED_SYS_FAST_DRIVERS_AND_CAUGHT_ACTUAL_DISCONNECT';(D/'routing.json').write_text(json.dumps(r,indent=2)+'\n');print(r['status'],r.get('witness'),flush=True)
