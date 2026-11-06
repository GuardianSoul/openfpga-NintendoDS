#!/usr/bin/env python3
"""Literal old/new raw helpers with post-M operand changes and a full64 oracle."""
import argparse,hashlib,json,os,resource,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--before',default='49746326');a=p.parse_args()
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
print('MAC_RAW_PID',os.getpid(),'NI10/j1/t1',flush=True)
def helper(s,name):return s[s.index('module '+name+' ('):].split('endmodule',1)[0]+'endmodule\n'
src=(ROOT/'rtl/gpu3d/gpu3d_gxeng.sv').read_text();oldsrc=subprocess.check_output(['git','show',a.before+':rtl/gpu3d/gpu3d_gxeng.sv'],cwd=ROOT).decode()
new=helper(src,'gpu3d_gxmac_products');old=helper(oldsrc,'gpu3d_gxmac_products').replace('gpu3d_gxmac_products','mac_before')
pair=helper((ROOT/'rtl/gpu3d/gpu3d_gxlight.sv').read_text(),'gpu3d_gxlight_pair18')
(out/'units.sv').write_text(old+new+pair)
top=r'''
module tb;
reg clk=0,clk2=0;
reg signed[31:0] ma=0,mb=0,v1=0,v2=0,v3=0;
wire signed[63:0] p_old,p_new;
wire signed[43:0] q_old[3],q_new[3];
gpu3d_gxmac_products after_unit(.clk,.clk2,.ma,.mb,.v1,.v2,.v3,.pr(p_new),.vp1(q_new[0]),.vp2(q_new[1]),.vp3(q_new[2]));
mac_before before_unit(.clk,.clk2,.ma,.mb,.v1,.v2,.v3,.pr(p_old),.vp1(q_old[0]),.vp2(q_old[1]),.vp3(q_old[2]));
reg[31:0] seed=32'h251129bc;
function automatic[31:0] randomword;
 begin seed=seed^(seed<<13);seed=seed^(seed>>17);seed=seed^(seed<<5);randomword=seed;end
endfunction
function automatic[63:0] product(input logic signed[31:0] a,b);
 product=a*b;
endfunction
reg[31:0] edgeword[0:11];
reg[63:0] want_p,previous_p,temporary;
reg[43:0] want_q[3],previous_q[3];
integer cycles=0,latecases=0,checks=0,fullmb=0,signs=0,carrymask=0;
integer i,k;reg ready=0;
reg[31:0] ll,lh,hl;reg[17:0] middle;
task cycle(input bit late_change);
 begin
 #1;
 want_p=product(ma,mb);want_q[0]=product(v1,mb);
 ll={16'd0,ma[15:0]}*{16'd0,mb[15:0]};
 lh=$signed({1'b0,ma[15:0]})*$signed(mb[31:16]);
 hl=$signed(ma[31:16])*$signed({1'b0,mb[15:0]});
 middle={2'b0,ll[31:16]}+{2'b0,lh[15:0]}+{2'b0,hl[15:0]};
 carrymask=carrymask|(1<<middle[17:16]);
 signs=signs|(1<<{ma[31],mb[31]});
 if(mb!={{16{mb[15]}},mb[15:0]})fullmb=fullmb+1;
 clk2=1;#1;
 if(ready)begin
  if(p_new!==previous_p || p_new!==p_old)$fatal(1,"M scalar publication changed");
  for(k=0;k<3;k=k+1)if(q_new[k]!==previous_q[k]||q_new[k]!==q_old[k])$fatal(1,"M vector publication changed lane%0d",k);
  checks=checks+4;
 end
 clk2=0;#1;
 if(late_change)begin
  ma=randomword();mb=randomword();v1=randomword();v2=randomword();v3=randomword();latecases=latecases+1;
 end
 want_q[1]=product(v2,mb);want_q[2]=product(v3,mb);
 #1;clk=1;clk2=1;#1;
 if(ready)begin
  if(p_new!==want_p||p_new!==p_old)$fatal(1,"E scalar mismatch cycle%0d old%h new%h oracle%h",cycles,p_old,p_new,want_p);
  for(k=0;k<3;k=k+1)if(q_new[k]!==want_q[k]||q_new[k]!==q_old[k])$fatal(1,"E vector mismatch cycle%0d lane%0d old%h new%h oracle%h",cycles,k,q_old[k],q_new[k],want_q[k]);
  checks=checks+4;
 end
 previous_p=p_new;for(k=0;k<3;k=k+1)previous_q[k]=q_new[k];
 clk=0;clk2=0;cycles=cycles+1;
 end
endtask
initial begin
 edgeword[0]=0;edgeword[1]=1;edgeword[2]=32'hffffffff;edgeword[3]=32'h7fffffff;
 edgeword[4]=32'h80000000;edgeword[5]=32'hffff;edgeword[6]=32'hffff0000;edgeword[7]=32'h10000;
 edgeword[8]=32'h7fff8000;edgeword[9]=32'h80007fff;edgeword[10]=32'h55555555;edgeword[11]=32'haaaaaaaa;
 repeat(3)cycle(0);ready=1;
 for(i=0;i<100144;i=i+1)begin
  ma=i<144?edgeword[i%12]:randomword();mb=i<144?edgeword[(i/12)%12]:randomword();
  v1=randomword();v2=randomword();v3=randomword();
  cycle(i%2!=0);
 end
 if(signs!=15||carrymask!=7||latecases!=50072||fullmb<90000)$fatal(1,"coverage signs%x carry%x late%0d fullmb%0d",signs,carrymask,latecases,fullmb);
 $display("PASS raw SYS=%0d words=%0d lateAllFiveOperands=%0d full32MB=%0d signs=%x carrymask=%x",cycles,checks,latecases,fullmb,signs,carrymask);$finish;
end
endmodule
'''
(out/'tb.sv').write_text(top)
cmd=['iverilog','-g2012','-s','tb','-o',str(out/'model.vvp'),str(out/'units.sv'),str(out/'tb.sv')]
def capacity():
    rows=[s.split(None,3)for s in subprocess.check_output(['ps','-eo','pid,ppid,ni,comm'],text=True).splitlines()[1:]]
    parent={int(p):int(pp)for p,pp,_,_ in rows}
    def ancestors(pid):
        seen=set()
        while pid in parent and pid not in seen:seen.add(pid);pid=parent[pid]
        return seen
    heavy={int(p)for p,_,_,c in rows if c.startswith(('V','verilator_bin','clang','census'))or c in('cc1plus','cc1','lto1')}
    leaves={pid for pid in heavy if not any(pid in ancestors(other)-{other}for other in heavy)}
    foreign=[pid for pid in leaves if os.getpid()not in ancestors(pid)]
    with(out/'capacity.jsonl').open('a')as f:f.write(json.dumps({'time':time.time(),'foreign':foreign,'max_foreign':2})+'\n')
    return len(foreign)<=2

while not capacity():print("WAIT global<=3",flush=True);time.sleep(5)
with(out/'build.log').open('w')as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
assert r.returncode==0,'raw helper build failed'
while not capacity():print("WAIT global<=3",flush=True);time.sleep(5)
with(out/'run.log').open('w')as f:r=subprocess.run(['vvp',str(out/'model.vvp')],stdout=f,stderr=subprocess.STDOUT)
log=(out/'run.log').read_text();print(log,flush=True)
rec=dict(before=a.before,command=cmd,exit=r.returncode,controller_pid=os.getpid(),source_sha256=hashlib.sha256(src.encode()).hexdigest(),helper_sha256=hashlib.sha256(new.encode()).hexdigest(),pair_sha256=hashlib.sha256(pair.encode()).hexdigest(),scope='Actual old/new raw helper plus independent full64 multiplication; all five operands change post-M in50072cases. Full signed32 MB, middlecarry0/1/2, both signs, M publication holds and exactEoutputs. Fallback pair18 arithmetic; exact native donor separately bound to actual1172 physical result by composition.',output=log)
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
raise SystemExit(r.returncode)
