#!/usr/bin/env python3
"""Real Quartus altdpram, portable backend, and old FF consumer oracle."""
import datetime,hashlib,json,os,re,resource,subprocess
from pathlib import Path
R=Path(__file__).resolve().parents[3];B=R/'build/cull-mlab25/native';B.mkdir(parents=True,exist_ok=True);S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json');T=Path('build/tools/oss-cad-suite/bin');Q=Path('build/tools/quartus-lite/25.1/quartus');vendor=Q/'eda/sim_lib/altera_mf.v'
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));full=(R/'rtl/gpu3d/gpu3d_gxeng.sv').read_text();cache=re.search(r'(?ms)^module gpu3d_gxcull_cache\b.*?^endmodule',full)[0];mem=re.search(r'(?ms)^module gpu3d_gxcull_mlab32\b.*?^endmodule',full)[0]
rec={'controller_PID':os.getpid(),'vendor':str(vendor),'vendor_SHA256':hashlib.sha256(vendor.read_bytes()).hexdigest(),'cache_SHA256':hashlib.sha256(cache.encode()).hexdigest(),'mem_SHA256':hashlib.sha256(mem.encode()).hexdigest(),'cases':{}}
def run(label,cmd,log):
 with log.open('w')as f:
  p=subprocess.Popen(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT);d=json.loads(S.read_text());d['phase']='D1 cull25native '+label;d['worker']={'active':True,'host':'Desktop','PID':os.getpid(),'child_PID':p.pid,'lease':'D1 Root cullMLAB25','nice':10,'jobs':1,'threads':1};d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();s=json.dumps(d,separators=(',',':'))+'\n';assert len(s.encode())<=2048;t=S.with_suffix('.Geometry25.tmp');t.write_text(s);t.replace(S);rc=p.wait()
 return rc,p.pid
bench=r'''`timescale 1ns/1ps
module tb_cull_native;
reg clk=0,clk2=0,rf_we=0,snap=0;
reg[10:0]rf_wa=0;reg[31:0]rf_wd=0;
reg[1:0]snap_group=0,rg[3];reg[31:0]sd[3];
wire[31:0]nq[3][3],pq[3][3];reg[31:0]gold[3][4],expected[3][3],nc[3][3],pc[3][3];
reg[31:0]rng=32'h3a5ccf71;integer n,c,r,g,word,consumed=0,same=0,different=0,resetwrites=0,hint_reset=0;
function[31:0]rand32;begin rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);rand32=rng;end endfunction
native_cache dut(.clk,.clk2,.rf_we,.rf_wa,.rf_wd,.snap,.snap_group,.snap_data(sd),.read_group(rg),.q(nq));
portable_cache mdl(.clk,.clk2,.rf_we,.rf_wa,.rf_wd,.snap,.snap_group,.snap_data(sd),.read_group(rg),.q(pq));
always @(posedge clk)for(integer i=0;i<3;i=i+1)for(integer j=0;j<3;j=j+1)begin nc[i][j]<=nq[i][j];pc[i][j]<=pq[i][j];end
task edge_clock(input integer sys);begin #3;clk2=1;clk=sys;#2;clk2=0;clk=0;#3;end endtask
initial begin
 for(c=0;c<3;c=c+1)begin rg[c]=0;sd[c]=0;for(g=0;g<4;g=g+1)gold[c][g]=0;end
 // Prime phase and initialize every live cell through actual RF writes.
 edge_clock(1);
 for(n=0;n<2060;n=n+1)begin
  // Inputs and read addresses can change before M. Only the prior SYS's
  // held snapshot may write, regardless of these live values.
  rf_wa=11'(rand32());rf_wd=rand32();rf_we=rand32()[0];snap=rand32()[0];snap_group=2'(rand32());
  for(c=0;c<3;c=c+1)begin sd[c]=rand32();rg[c]=2'(rand32());end
  edge_clock(0);
  // New E operands cover all simultaneous-writer priority combinations.
  word=n%3==2?3:n%3;
  rf_we=n<12||n%7!=0;rf_wa={5'b01000,2'(n<12?n/3:rand32()),4'(word)};rf_wd=rand32();
  if(n>=12&&n%17==0)rf_wa[10:6]=5'b11100;
  snap=n>=12&&n%4!=0;snap_group=n%2==0?rf_wa[5:4]:2'(rf_wa[5:4]+1);
  for(c=0;c<3;c=c+1)sd[c]=n%31==0?32'h80000000+c:rand32();
  hint_reset=n%37==0;
  for(r=0;r<3;r=r+1)for(c=0;c<3;c=c+1)expected[r][c]=gold[c][rg[r]];
  edge_clock(1);
  if(n>=12)for(r=0;r<3;r=r+1)for(c=0;c<3;c=c+1)begin
   if(nc[r][c]!==expected[r][c])begin $display("NATIVE_CONSUMER_FAIL n%0d r%0d c%0d got%08x expected%08x",n,r,c,nc[r][c],expected[r][c]);$fatal(1,"SYS_OLD_DATA_OR_PRIORITY");end
   if(pc[r][c]!==expected[r][c])$fatal(1,"PORTABLE_CONSUMER_FAIL");
   consumed=consumed+1;
  end
  if(rf_we&&rf_wa[10:6]==5'b01000)begin
   if(rf_wa[3:0]==0)gold[0][rf_wa[5:4]]=rf_wd;
   if(rf_wa[3:0]==1)gold[1][rf_wa[5:4]]=rf_wd;
   if(rf_wa[3:0]==3)gold[2][rf_wa[5:4]]=rf_wd;
   if(hint_reset)resetwrites=resetwrites+1;
   if(snap)begin if(snap_group==rf_wa[5:4])same=same+1;else different=different+1;end
  end
  if(snap)for(c=0;c<3;c=c+1)gold[c][snap_group]=sd[c];
 end
 if(consumed<18000||same==0||different==0||resetwrites==0)$fatal(1,"COVERAGE");
 $display("PASS_NATIVE_CULL SYS2060 consumed%0d sameSlot%0d differentSlot%0d resetWrites%0d full32bit/noreset/threeReadReplica",consumed,same,different,resetwrites);$finish;
end
endmodule
'''.replace('rand32()[0]',"1'(rand32())")
for label in ['positive','dropM','RFwins']:
 O=B/label;O.mkdir(exist_ok=True);actual=cache
 if label=='dropM':
  old='wire we=mid?snap_hold:';assert actual.count(old)==1;actual=actual.replace(old,"wire we=mid?1'b0:")
 if label=='RFwins':
  old='wire mid=epoch!=seen;';actual=actual.replace(old,old+"\n logic collision_hold;logic[3:0]rf_word_hold;\n always_ff @(posedge clk)begin collision_hold<=rf_we&&rf_wa[10:6]==5'b01000&&rf_wa[5:4]==snap_group;rf_word_hold<=rf_wa[3:0];end")
  old='wire we=mid?snap_hold:';assert actual.count(old)==1;actual=actual.replace(old,"wire we=mid?(snap_hold&&!(collision_hold&&rf_word_hold==4'(WORD))):")
 native='`define ALTERA_RESERVED_QIS\n'+actual.replace('gpu3d_gxcull_cache','native_cache').replace('gpu3d_gxcull_mlab32','native_mlab32')+'\n'+mem.replace('gpu3d_gxcull_mlab32','native_mlab32')+'\n`undef ALTERA_RESERVED_QIS\n'
 portable=cache.replace('gpu3d_gxcull_cache','portable_cache').replace('gpu3d_gxcull_mlab32','portable_mlab32')+'\n'+mem.replace('gpu3d_gxcull_mlab32','portable_mlab32')+'\n'
 (O/'actual.sv').write_text(native+portable);(O/'bench.sv').write_text(bench)
 cmd=[str(T/'iverilog'),'-g2012','-s','tb_cull_native','-o',str(O/'model.vvp'),str(vendor),str(O/'actual.sv'),str(O/'bench.sv')]
 rc,bpid=run(label+' compile',cmd,O/'build.log');assert rc==0,(O/'build.log').read_text()[-3000:]
 rc,pid=run(label+' runtime',[str(T/'vvp'),str(O/'model.vvp')],O/'run.log');text=(O/'run.log').read_text();assert(rc==0)==(label=='positive'),text[-2500:]
 if label!='positive':assert'SYS_OLD_DATA_OR_PRIORITY'in text,text[-2500:]
 rec['cases'][label]={'build_PID':bpid,'runtime_PID':pid,'exit':rc,'command':cmd,'actual_SHA256':hashlib.sha256((O/'actual.sv').read_bytes()).hexdigest(),'log_SHA256':hashlib.sha256((O/'run.log').read_bytes()).hexdigest(),'tail':text[-1500:]};(B/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n');print(label,rc,text[-300:],flush=True)
d=json.loads(S.read_text());d['worker']['active']=False;d['phase']='cull25 real native and actual M/priority mutations done';t=S.with_suffix('.Geometry25.tmp');t.write_text(json.dumps(d,separators=(',',':'))+'\n');t.replace(S)
