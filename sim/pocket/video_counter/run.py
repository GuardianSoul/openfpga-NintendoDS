#!/usr/bin/env python3
"""Counter-width long/missing-anchor miter and actual functional negative controls."""
import argparse,fcntl,hashlib,json,os,signal,subprocess,time
from pathlib import Path
P=argparse.ArgumentParser(description=__doc__);P.add_argument('--out',type=Path,required=True);P.add_argument('--expect-reset-failure',action='store_true');P.add_argument('--revert',action='store_true');P.add_argument('--short-pulses',action='store_true');P.add_argument('--mutant',choices=['hc_too_small','hc_wrap']);A=P.parse_args()
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2];OUT=A.out.resolve();BASE='401ebad545db14a508c1f5547296469ce30ee0c6'
def need(v,m):
 if not v:raise RuntimeError(m)
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
need(not A.revert and not A.expect_reset_failure,'counter experiment uses fixed401 reference; negative controls use video_counter runner');need(not OUT.exists(),'fresh output directory');OUT.mkdir(parents=True);need(not subprocess.check_output(['git','status','--porcelain'],cwd=ROOT).strip(),'commit source and helpers before execution')
rev=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip();inputs={str(p):sha(p)for p in [ROOT/'rtl/pocket/nds_video.sv',*HERE.glob('*')]if p.is_file()};save(OUT/'inputs.json',dict(revision=rev,files=inputs));commands=[];cancel=[]
for sig in [signal.SIGTERM,signal.SIGINT]:signal.signal(sig,lambda s,f:cancel.append(s))
def run(cmd,name,timeout,compile=False):
 lock=None;p=None;started=None;error=None;code=None;timed=False;cleanup=[];queued=time.time_ns()
 try:
  if compile:
   lock=(Path.home()/'.cache/nds-sim-build.lock').open('a');q=time.monotonic()
   while True:
    need(not cancel,'cancelled in queue');need(time.monotonic()-q<1800,'compile queue timeout')
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);break
    except BlockingIOError:time.sleep(.5)
  need(not cancel,'cancelled before spawn');started=time.time_ns();start=time.monotonic()
  with (OUT/(name+'.log')).open('w')as log:
   p=subprocess.Popen(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
   while True:
    status=os.waitid(os.P_PID,p.pid,os.WEXITED|os.WNOHANG|os.WNOWAIT)
    if status:break
    need(not cancel,'cancelled')
    if time.monotonic()-start>timeout:timed=True;raise RuntimeError('execution timeout')
    time.sleep(.1)
 except BaseException as exc:error=f'{type(exc).__name__}: {exc}'
 finally:
  # Keep the leader unreaped until both group signals have been sent.
  if p:
   for sig in [signal.SIGTERM,signal.SIGKILL]:
    try:os.killpg(p.pid,sig)
    except ProcessLookupError:pass
    except OSError as e:cleanup.append(str(e))
    if sig==signal.SIGTERM:time.sleep(.1)
   try:code=p.wait(timeout=5)
   except subprocess.TimeoutExpired:cleanup.append('leader did not reap within5s')
  if lock:lock.close()
 row=dict(argv=cmd,cwd=str(ROOT),returncode=code,queued_ns=queued,started_ns=started,completed_ns=time.time_ns(),timed_out=timed,cancelled=list(cancel),error=error,cleanup_errors=cleanup,log_sha256=sha(OUT/(name+'.log'))if(OUT/(name+'.log')).exists()else None)
 commands.append(row);save(OUT/'commands.json',commands);need(not error and not cancel and not cleanup,'command lifecycle failure '+str(error));return code
current=(ROOT/'rtl/pocket/nds_video.sv').read_text();original=subprocess.check_output(['git','show',BASE+':rtl/pocket/nds_video.sv'],cwd=ROOT,text=True);(OUT/'reference-source.sv').write_text(original)
if A.mutant=='hc_too_small':
 for a,b in [("reg [10:0] hc = 0;","reg [9:0] hc = 0;"),("hc != 11'h7FF","hc != 10'h3FF"),("hc[10:2]","{1'b0,hc[9:2]}")]:
  need(current.count(a)==1,'mutant anchor '+a);current=current.replace(a,b)
elif A.mutant=='hc_wrap':
 a="else if (hc != 11'h7FF) hc <=";need(current.count(a)==1,'mutant anchor');current=current.replace(a,'else hc <=')
header=original[:original.index('    // ---------------- DS raster')].replace('module nds_video #','module video_reset_miter #',1).replace('output reg','output wire')
import re
header=re.sub(r' = 0(?=,|\n)', '', header)
outs={'frame_pulse':'','w_req':'','w_addr':'[23:0]','w_data':'[31:0]','r_req':'','r_addr':'[23:0]','underruns':'[15:0]','layout':'[1:0]','rgb':'[23:0]','de':'','hs':'','vs':''};ports=['clk','reset','vid_t','layout_in','rotation','touch','pen','cur_x','cur_y','px_valid','px_eng','px_line','px_x','px_rgb','line_start','vcount','swap','frame_pulse','w_req','w_addr','w_data','w_ack','r_req','r_addr','r_ack','r_rvalid','r_rdata','underruns','layout','rgb','de','hs','vs']
i=header.rindex('\n);');header=header[:i]+',\n'+',\n'.join('    output wire '+w+' ref_'+p for p,w in outs.items())+header[i:]
conn=lambda old:','.join('.'+p+'('+('ref_'+p if old and p in outs else p)+')'for p in ports)
sv=header+'nds_video_impl candidate('+conn(False)+');\nnds_video_ref reference('+conn(True)+');\nendmodule\n'+current.replace('module nds_video #','module nds_video_impl #',1)+original.replace('module nds_video #','module nds_video_ref #',1)
source=OUT/'video_reset_miter.sv';source.write_text(sv)
cmd=['verilator','--cc','--exe','--build','-j','2','-O2','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-UNUSEDSIGNAL','--top-module','video_reset_miter','--Mdir',str(OUT/'obj'),'-CFLAGS','-std=c++17 -O2',str(source),str(HERE/'counter_miter.cpp')]
need(run(cmd,'compile',180,True)==0,'compile failed');exe=OUT/'obj/Vvideo_reset_miter';results=[]
rc=run([str(exe)],'long-lines',300);log=(OUT/'long-lines.log').read_text();m=re.findall(r'^RESULT long-lines cases=(\d+) passed=(\d+) failed=(\d+)$',log,re.M);need(len(m)==1,'one suite result');total,passed,failed=map(int,m[0]);need(total==36,'case inventory')
if A.mutant:
 need(rc==1 and passed==0 and failed==36,'mutant must fail all36 actual cases');need(sum(x.startswith('FAIL public-pin-')for x in log.splitlines())==36,'functional public-pin mutant failures')
else:need(rc==0 and passed==36 and failed==0 and 'FAIL 'not in log,'long-line equivalence failed')
need(all(sha(p)==h for p,h in inputs.items()),'source changed');save(OUT/'summary.json',dict(pass_=True,revision=rev,baseline=BASE,mutant=A.mutant,inputs=inputs,compiled_source_sha256=sha(source),reference_sha256=sha(OUT/'reference-source.sv'),executable_sha256=sha(exe),commands_sha256=sha(OUT/'commands.json'),actual_exit_code=rc,cases=total,passed=passed,failed=failed,scope='Actual full-module public-pin cycle equality under finite long/missing-line anchors, mode changes, reset and delayed responses. No full APF/physical/area/formal-all-history claim.'))
print(json.dumps(dict(pass_=True,revision=rev,mutant=A.mutant,cases=total,passed=passed,failed=failed)))
