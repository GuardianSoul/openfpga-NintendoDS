#!/usr/bin/env python3
"""Literal paired36-row non-MUL cycle/state/port/pin regression for the trial."""
from pathlib import Path
import argparse, hashlib, importlib.util, json, os, resource, struct, subprocess, tarfile, time

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--trial',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False);S=D/'source';S.mkdir()
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_CPU,(240,240))
resource.setrlimit(resource.RLIMIT_AS,(4*1024**3,4*1024**3));resource.setrlimit(resource.RLIMIT_FSIZE,(128*1024**2,128*1024**2))
sha=lambda b:hashlib.sha256(b).hexdigest()
with tarfile.open(R/'docs/results/arm7-data-ack-20261101/proof.tar.gz')as t:donor=t.extractfile('cpu36/tb.sv').read().decode()
lane=donor[donor.index('module cpu_after '):donor.index('module cpu_bad ')]
lane=lane.replace('module cpu_after ','module control_lane ')
lane=lane.replace(' arm7_ds\n',' arm7_ds_trial\n')
lane=lane.replace('.i_rdata(iq),.i_ok(io),.d_req', '.phase_trial(MODE!=0),.i_rdata_in(iq),.i_ok_in(io),.d_req',1)
lane=lane.replace('.DATA_ACK_HANDOFF(1)', '.MAIN_IF_REJOIN(1),.MAIN_STORE_TURN(1),.DATA_ACK_HANDOFF(0)')
lane=lane.replace(' physical_after #(', ' physical_before #(')
lane=lane.replace('endmodule', '''
 wire[2047:0]control_ports={ir,ia,io,iq,dr,dw,dok,da,dd,db,psr,wen,wa,wd,ret,pc,
  iseq,iredirect,iconsume,fr,fn,fw,ack,rv,fa,fd,fq,wr,ww,wok,wrd,wb,wa_mem,wwd,pins,run};
 logic[4:0]pst,pmode;logic[3:0]pk;logic[1:0]pesub;logic pph,pdm,pifwait;
 logic[31:0]pinsn,ppc;logic[4095:0]core_state;logic[1023:0]rf_state,rfb_state;
 `PROBE(cpu)
 always @(posedge clk)if(!rst&&run&&(cpu.phase_prepare||cpu.phase_next_commit||cpu.phase_f_finish))
  $fatal(1,"non-MUL control unexpectedly enters trial class");
endmodule''')
top='''`timescale 1ps/1ps
`default_nettype none
`include "probe.svh"
'''+lane+'''
module tb;
 logic clk=0,clk_mem=0,clk_cram=0,rst=1;
 always #4973 clk_mem=~clk_mem;
 initial begin #14919;forever begin clk=1;#7460;clk=0;#7459;end end
 always @(clk_mem)clk_cram<=#6838 clk_mem;
 wire done0,done1;
 control_lane #(.MODE(0))l0(clk,clk_mem,clk_cram,rst,done0);
 control_lane #(.MODE(1))l1(clk,clk_mem,clk_cram,rst,done1);
 always @(posedge clk)if(!rst)begin
  assert(l0.control_ports===l1.control_ports)else $fatal(1,"non-MUL port/pin/cycle difference");
  assert(l0.core_state===l1.core_state&&l0.rf_state===l1.rf_state&&l0.rfb_state===l1.rfb_state)
   else $fatal(1,"non-MUL full core/register difference");
 end
 initial begin repeat(8)@(negedge clk);rst=0;wait(done0&&done1);$display("NONMUL_PAIR_EXACT_PASS");$finish;end
endmodule
'''
(S/'tb.sv').write_text(top)
(S/'probe.svh').write_text((R/'sim/arm/stm4_meta/probe.svh').read_text().replace('pins=', 'pinsn='))
files=[]
for f in sorted((a.trial/'source').glob('*.sv')):
 if f.name=='tb.sv':continue
 out=S/f.name;out.write_bytes(f.read_bytes());files.append(out)
files.sort(key=lambda f:f.name!='arm_pkg.sv');files.append(S/'tb.sv')
result=dict(core_trial_SHA256=sha((S/'arm7_ds.sv').read_bytes()),source_SHA256={f.name:sha(f.read_bytes())for f in files},stages=[],rows=[])
def save():(D/'results.json').write_text(json.dumps(result,indent=2)+'\n')
def call(cmd,tag,timeout):
 begin=time.monotonic()
 with(D/(tag+'.log')).open('w')as f:
  proc=subprocess.Popen(list(map(str,cmd)),cwd=R,stdout=f,stderr=subprocess.STDOUT)
  row=dict(tag=tag,PID=proc.pid,starttime=Path('/proc',str(proc.pid),'stat').read_text().rsplit(')',1)[1].split()[19]);result['stages'].append(row);save();print(tag,proc.pid,flush=True)
  q=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json');j=json.loads(q.read_text());j['phase']='non-MUL phase trial '+tag;j['worker']=dict(host='Desktop',active=True,PID=proc.pid,NI=10,jobs=1,threads=1);tmp=q.with_suffix('.tmp');tmp.write_text(json.dumps(j,indent=2)+'\n');tmp.replace(q)
  try:row['exit']=proc.wait(timeout=timeout)
  except subprocess.TimeoutExpired:proc.terminate();row['exit']=proc.wait(timeout=10);row['timeout']=True
 row.update(reaped=True,wall_seconds=round(time.monotonic()-begin,3));save()
 j['worker']=dict(host='Desktop',active=False,PID=None,NI=10,jobs=0,threads=0);tmp.write_text(json.dumps(j,indent=2)+'\n');tmp.replace(q)
 assert row['exit']==0,(tag,(D/(tag+'.log')).read_text()[-2500:])
 return(D/(tag+'.log')).read_text()
call(['build/tools/oss-cad-suite/bin/verilator','--binary','--timing','--assert','+define+A7_FLOW_SOURCE','--threads','1','-j','1','-O2','-Wno-fatal','-I'+str(S),'--top-module','tb','--Mdir',D/'obj',*files],'build',180)
spec=importlib.util.spec_from_file_location('cpu39',R/'sw/tests/a7fetch39/build.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);blobs,layout=m.captured()
for c in layout['cases']:
 raw=blobs[f'arm7fetch_v1_k{c["id"]:02d}_r0.bin'];code=raw[348:348+c['size']];assert sha(code)==c['code_sha256']
 image=D/(c['case']+'.hex');image.write_text(''.join(f'{v:08x}\n'for v in struct.unpack('<1024I',code+bytes(4096-len(code)))))
 checksum=struct.unpack_from('<I',raw,344)[0]
 for n in [4,16]:
  tag=c['case']+'-n'+str(n);stem=D/tag
  log=call([D/'obj/Vtb',f'+img={image}',f'+entry={c["main_entry"]:x}',f'+source={c["source_entry"]:x}',f'+body={c["main_entry"]+c["source_body"]-c["source_entry"]:x}',f'+size={c["size"]}',f'+sum={checksum}',f'+loops={n}',f'+trace={stem}',f'+data={stem}'],tag,30)
  assert 'NONMUL_PAIR_EXACT_PASS'in log
  for suffix in ['csv','data','fcomp']:assert Path(str(stem)+'-m0.'+suffix).read_bytes()==Path(str(stem)+'-m1.'+suffix).read_bytes()
  result['rows'].append(dict(case=c['case'],loops=n,byte_equal=True));save()
result['status']='PASS36 non-MUL matched rows: exact full core/RF/ports/pins/cycles and traces';save();print(result['status'])
q=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json');j=json.loads(q.read_text());j['phase']=result['status'];j['worker']=dict(host='Desktop',active=False,PID=None,NI=10,jobs=0,threads=0);tmp=q.with_suffix('.tmp');tmp.write_text(json.dumps(j,indent=2)+'\n');tmp.replace(q)
