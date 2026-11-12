#!/usr/bin/env python3
"""Original video reset/slot regression: public pins, synthetic pixels/SDRAM, no assets."""
import argparse,fcntl,hashlib,json,os,signal,subprocess,time
from pathlib import Path
P=argparse.ArgumentParser(description=__doc__);P.add_argument('--out',type=Path,required=True);P.add_argument('--expect-reset-failure',action='store_true');P.add_argument('--revert',action='store_true');P.add_argument('--short-pulses',action='store_true');A=P.parse_args()
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2];OUT=A.out.resolve();BASE='82d264d6cc96ec30e35abb87f369a5a1be419f3c'
def need(v,m):
 if not v:raise RuntimeError(m)
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
need(not OUT.exists(),'fresh output directory');OUT.mkdir(parents=True);need(not subprocess.check_output(['git','status','--porcelain'],cwd=ROOT).strip(),'commit source and helpers before execution')
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
if A.revert:
 # Revert the complete edge-slot change to the exact qualified original.
 need(current.count('end else rgb <= de ?')==1 and 'wire slot0 =' not in current,'edge-only revert anchor')
 current=original
header=original[:original.index('    // ---------------- DS raster')].replace('module nds_video #','module video_reset_miter #',1).replace('output reg','output wire')
import re
header=re.sub(r' = 0(?=,|\n)', '', header)
outs={'frame_pulse':'','w_req':'','w_addr':'[23:0]','w_data':'[31:0]','r_req':'','r_addr':'[23:0]','underruns':'[15:0]','layout':'[1:0]','rgb':'[23:0]','de':'','hs':'','vs':''};ports=['clk','reset','vid_t','layout_in','rotation','touch','pen','cur_x','cur_y','px_valid','px_eng','px_line','px_x','px_rgb','line_start','vcount','swap','frame_pulse','w_req','w_addr','w_data','w_ack','r_req','r_addr','r_ack','r_rvalid','r_rdata','underruns','layout','rgb','de','hs','vs']
i=header.rindex('\n);');header=header[:i]+',\n'+',\n'.join('    output wire '+w+' ref_'+p for p,w in outs.items())+header[i:]
conn=lambda old:','.join('.'+p+'('+('ref_'+p if old and p in outs else p)+')'for p in ports)
sv=header+'nds_video_impl candidate('+conn(False)+');\nnds_video_ref reference('+conn(True)+');\nendmodule\n'+current.replace('module nds_video #','module nds_video_impl #',1)+original.replace('module nds_video #','module nds_video_ref #',1)
source=OUT/'video_reset_miter.sv';source.write_text(sv)
cmd=['verilator','--cc','--exe','--build','-j','2','-O2','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-UNUSEDSIGNAL','--top-module','video_reset_miter','--Mdir',str(OUT/'obj'),'-CFLAGS','-std=c++17 -O2',str(source),str(HERE/'video_reset.cpp')]
need(run(cmd,'compile',180,True)==0,'compile failed');exe=OUT/'obj/Vvideo_reset_miter';results=[]
for suite in (['short-pulses']if A.short_pulses else ['reset']if A.revert else ['reset','steady']if A.expect_reset_failure else ['reset','boundaries','steady','short-pulses']):
 rc=run([str(exe),suite],suite,300);log=(OUT/(suite+'.log')).read_text();m=re.search(r'^RESULT suite=([\w-]+) cases=(\d+) passed=(\d+) failed=(\d+)$',log,re.M);need(m is not None,'suite receipt missing');total,passed,failed=map(int,m.groups()[1:]);expected_failure=suite=='reset'and(A.revert or A.expect_reset_failure)
 if expected_failure:
  need(rc==1 and(total,passed,failed)==(36,4,32),'baseline/revert did not discriminate modes');need(sum(x.startswith('FAIL ')and'reset-DE-fall-slot'in x for x in log.splitlines())==32,'wrong failure predicate')
 else:need(rc==0 and failed==0 and total==passed and total=={'reset':36,'boundaries':132,'steady':36,'short-pulses':108}[suite]and'FAIL 'not in log,'positive suite failed')
 if suite=='short-pulses':
  high=sum(map(int,re.findall(r'reset_high_falls=(\d+)',log)));post=sum(map(int,re.findall(r'post_deassert_falls=(\d+)',log)));need(high>0 and post>0 and high+post==108,'short pulse fall coverage')
 results.append(dict(suite=suite,cases=total,passed=passed,failed=failed,expected_failure=expected_failure,log_sha256=sha(OUT/(suite+'.log'))))
need(all(sha(p)==h for p,h in inputs.items()),'source changed');save(OUT/'summary.json',dict(pass_=True,revision=rev,baseline=BASE,revert=A.revert,expected_reset_failure=A.expect_reset_failure,inputs=inputs,compiled_source_sha256=sha(source),reference_sha256=sha(OUT/'reference-source.sv'),executable_sha256=sha(exe),commands_sha256=sha(OUT/'commands.json'),results=results,scope='Finite actual original/fixed-module pin observations and uninterrupted cycle miter. No full APF/physical scaler/shared-controller/fit claim.'))
print(json.dumps(dict(pass_=True,revision=rev,results=results)))
