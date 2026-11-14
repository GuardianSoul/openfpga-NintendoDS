#!/usr/bin/env python3
"""Freeze the observable full-controller oracle before editing the architecture."""
import pathlib,re,subprocess,json,hashlib,os
os.setpriority(os.PRIO_PROCESS,0,10)
W=pathlib.Path(__file__).resolve().parents[3];O=W/'build/cpu232-service-ucode';O.mkdir(parents=True,exist_ok=True)
s=subprocess.check_output(['git','show','232c26ac:rtl/arm/arm9_mem.sv'],cwd=W).decode()
assert s==(W/'rtl/arm/arm9_mem.sv').read_text()
# Icarus does not support a module-header package import. This module uses no
# package identifiers; keep all body logic and assertions unchanged.
s=s.replace(' import arm_pkg::*;','')
ref=s.replace('module arm9_mem #','module reference_mem #',1).replace('packed_update','ref_packed_update')
(O/'reference.sv').write_text(ref)
mut=s.replace('module arm9_mem #','module candidate_mem #',1).replace('packed_update','dut_packed_update')
assert mut.count("{dp_a[31:5], 3'(k + fsd), 2'b00}")==1
mut=mut.replace("{dp_a[31:5], 3'(k + fsd), 2'b00}","({dp_a[31:5], 3'(k + fsd), 2'b00} ^ 32'd4)")
(O/'mutant.sv').write_text(mut)
ports=re.findall(r'^  (input|output)\s+logic\s*(\[[^\]]+\])?\s*(\w+)\s*[,\n]',s,re.M)
# clk/rst and every public handshake, data and bus signal are covered.
assert len(ports)==37,len(ports)
lines=['module tb;']
for dr,width,n in ports:
 lines.append(f'logic {width} {n}'+(';' if dr=='input' else f'_r, {n}_c;'))
for module,suffix in [('reference_mem','r'),('candidate_mem','c')]:
 args=', '.join(f'.{n}({n if dr=="input" else n+"_"+suffix})' for dr,width,n in ports)
 lines.append(f'{module} #(.WAYS(2),.BURST(1),.SLOW(1),.EVB(1),.EARLYD(1),.XD(2),.XI(1),.OPT(1711268835)) {suffix} ({args});')
lines.append('''integer cyc=0, beats=0, answers=0, triple=0, ifill_overlap=0; logic [31:0] mem[0:16383]; integer stall=0; logic [31:0] rng=32'h137fac31; logic[15:0] seen=0;
always_comb begin b_ack=b_req_r && (rng[2:0]!=0) && (cyc%17>=stall);b_wnext=0;b_rdata=mem[b_addr_r[15:2]];end
task tick;
 begin
 clk=0;#5;
 if(b_ack && b_we_r) for(integer b=0;b<4;b=b+1) if(b_be_r[b]) mem[b_addr_r[15:2]][b*8+:8]=b_wdata_r[b*8+:8];
 clk=1;#5;cyc=cyc+1;rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 if(!rst) begin
 seen[r.st]=1;
 if(r.st==7 && i_req && i_ok_r)ifill_overlap=ifill_overlap+1;
 if(r.st==7 && i_req && i_ok_r && d_req && d_ok_r && r.wd_hit && r.f_cach && r.dc_we[r.vway]==4'hf && r.w_addr[12:5]!=r.dp_a[12:5] && b_ack)triple=triple+1;
 if(b_ack)beats=beats+1;
 if(d_ok_r&&d_req)answers=answers+1;
''')
# Inactive payloads are not observable. Compare data only with a valid answer,
# bus fields only when requesting, and byte-write payload only in enabled bytes.
for n in ['i_ok','i_abort','d_ok','d_abort','d_wait','hivecs','b_req','dg_fill']:
 lines.append(f'if ({n}_r !== {n}_c) $fatal(1,"ORACLE {n} cycle=%0d",cyc);')
lines.append('''if(i_req && i_ok_r && !i_abort_r && ({i_rdata_r,i_half_r} !== {i_rdata_c,i_half_c})) $fatal(1,"ORACLE instruction data cycle=%0d",cyc);
if((d_req||cp_req)&&d_ok_r&&!d_abort_r && d_rdata_f_r !== d_rdata_f_c) $fatal(1,"ORACLE data cycle=%0d",cyc);
if(b_req_r && {b_addr_r,b_we_r,b_n8_r,b_be_r,b_tmr_r} !== {b_addr_c,b_we_c,b_n8_c,b_be_c,b_tmr_c}) $fatal(1,"ORACLE bus cycle=%0d",cyc);
if({r.dc_we[0],r.dc_we[1],r.ic_we,r.dt_we,r.it_we} !== {c.dc_we[0],c.dc_we[1],c.ic_we,c.dt_we,c.it_we})$fatal(1,"ORACLE RAM enables cycle=%0d",cyc);
if((|r.dt_we) && {r.dt_aa,r.dt_ad} !== {c.dt_aa,c.dt_ad})$fatal(1,"ORACLE D tag write cycle=%0d",cyc);
if((|r.it_we) && {r.it_aa,r.it_ad} !== {c.it_aa,c.it_ad})$fatal(1,"ORACLE I tag write cycle=%0d",cyc);
if((|r.ic_we) && {r.ic_aa,r.ic_ad} !== {c.ic_aa,c.ic_ad})$fatal(1,"ORACLE I fill write cycle=%0d",cyc);
for(integer w=0;w<2;w=w+1)for(integer b=0;b<4;b=b+1)if(r.dc_we[w][b] && {r.dc_aa,r.dc_ad[b*8+:8]} !== {c.dc_aa,c.dc_ad[b*8+:8]})$fatal(1,"ORACLE D byte write cycle=%0d",cyc);
if(b_req_r&&b_we_r)for(integer b=0;b<4;b=b+1)if(b_be_r[b] && b_wdata_r[b*8+:8] !== b_wdata_c[b*8+:8])$fatal(1,"ORACLE write cycle=%0d",cyc);
end
 end
endtask
task cp(input[3:0]crn,crm,input[2:0]opc,input[31:0]v);
 begin
 cp_op={5'd0,crn,crm,opc};cp_wdata=v;cp_req=1;cp_we=1;d_req=0;tick();
 for(integer n=0;n<20000;n=n+1)begin
 if(d_ok_r)begin cp_req=0;tick();return;end
 tick();
 end
 $fatal(1,"CP timeout");
 end
endtask
task access_d(input bit wr,input[31:0]a,v,input[3:0]be);
 begin
 cp_req=0;d_req=1;d_we=wr;d_addr=a;d_wdata=v;d_be=be;tick();
 for(integer n=0;n<20000;n=n+1)begin
 if(d_ok_r)begin d_req=0;tick();return;end
 tick();
 end
 $fatal(1,"data timeout");
 end
endtask
initial begin
''')
for dr,width,n in ports:
 if dr=='input' and n not in ['b_ack','b_wnext','b_rdata']: lines.append(f'{n}=0;')
lines.append('''if($value$plusargs("seed=%h",rng))begin end
if($value$plusargs("stall=%d",stall))begin end
if(stall>14 || rng==0)$fatal(1,"bad fixture parameters");
for(integer m=0;m<16384;m=m+1)mem[m]=32'h652b7301^m;
rst=1;i_priv=1;d_priv=1;repeat(4)tick();rst=0;tick();
i_req=1;i_addr=32'h03000420;repeat(16)tick();i_req=0;
cp(6,0,0,32'h0200002b);cp(2,0,0,1);cp(3,0,0,1);cp(1,0,0,32'h0000107d);
cp(7,5,0,0);cp(7,6,0,0);
i_req=1;i_addr=32'h02000814;
access_d(0,32'h02000204,0,15);repeat(200)tick();
// Prime a hit in a different set, then issue it during another D fill.
d_req=1;d_we=0;d_addr=32'h02000314;tick();
begin : overlap
 for(integer q=0;q<1000;q=q+1)begin
  if(r.st==7 && r.k>=1)begin d_addr=32'h02000204;tick();while(r.st==7)tick();d_req=0;disable overlap;end
  tick();
 end
end
repeat(30)tick();
for(integer q=0;q<20;q=q+1)begin
 access_d(0,32'h02000114+(q%3)*32'h2000,0,15);
 access_d(1,32'h02000114+(q%3)*32'h2000,32'h13572000+q,1<<(q%4));
 access_d(0,32'h02000114+(q%3)*32'h2000,0,15);
end
cp(7,10,1,32'h02000114);cp(7,14,2,0);cp(7,5,2,0);
access_d(0,32'h03000100,0,15);access_d(1,32'h04000100,32'hf5cc0034,3);cp(7,10,4,0);
cp(9,1,0,32'h0080000a);cp(1,0,0,32'h0001107d);
access_d(1,32'h00800004,32'h42cc7733,15);access_d(0,32'h00800004,0,15);
repeat(80)tick();
// Reset with queued service is checked without changing the native RAM reset contract.
d_req=1;d_we=0;d_addr=32'h03000480;tick();rst=1;tick();rst=0;d_req=0;i_req=0;repeat(8)tick();
if(triple==0 || ifill_overlap==0)$fatal(1,"missing real bank concurrency triple=%0d seen=%h Ihit=%0d",triple,seen,ifill_overlap);
if((seen & 16'h7fff)!=16'h7fff)$fatal(1,"missing reachable service states %h",seen);
$display("PASS cycles=%0d busbeats=%0d answers=%0d states=%h triple=%0d Ihit_Dfill=%0d",cyc,beats,answers,seen,triple,ifill_overlap);$finish;
end
endmodule
''')
(O/'tb.sv').write_text('\n'.join(lines)+'\n')
print(json.dumps({'reference_sha256':hashlib.sha256(ref.encode()).hexdigest(),'mutant':'D fill bus address bit2 inverted','ports':len(ports)}))
