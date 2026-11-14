#!/usr/bin/env python3
"""Native altdpram asynchronous phase/codec and forbidden collision witnesses."""
from pathlib import Path
import argparse,importlib.util,json
R=Path(__file__).resolve().parents[3];ap=argparse.ArgumentParser();ap.add_argument('--out',required=True);a=ap.parse_args();B=R/a.out;assert not B.exists();B.mkdir(parents=True)
sp=importlib.util.spec_from_file_location('runner',R/'sim/gpu3d/edge_span_service/runner.py');run=importlib.util.module_from_spec(sp);sp.loader.exec_module(run)
V=Path('build/tools/oss-cad-suite/bin');vendor=Path('build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v')
s=(R/'rtl/gpu3d/gpu3d_span_records.sv').read_text();bad=s[s.index('module gpu3d_span_view #('):].replace('module gpu3d_span_view #(','module gpu3d_span_view_badphase #(',1).replace(".FE(1'b0)",".FE(1'b1)")
native=s[s.index('module gpu3d_span_view #('):].replace('module gpu3d_span_view #(','module gpu3d_span_view_native #(',1)
(B/'actual.sv').write_text(s+'\n'+bad+'\n`define ALTERA_RESERVED_QIS\n'+native+'\n`undef ALTERA_RESERVED_QIS\n');(B/'gpu3d_pkg.sv').write_text((R/'rtl/gpu3d/gpu3d_pkg.sv').read_text());(B/'gpu3d_ram.sv').write_text((R/'rtl/gpu3d/gpu3d_ram.sv').read_text())
(B/'bench.sv').write_text(r'''`timescale 1ns/1ps
module native_span_view #(parameter integer ROLE=0)(
 input logic clk,we,active,input logic[1:0]wa,ra,input gpu3d_pkg::span_t data,
 output logic [658:0] q,nq,bq
);
 function automatic [658:0] mask_;
  for(integer b=0;b<659;b++)mask_[b]=(b%3)==ROLE;
 endfunction
 localparam logic[658:0]MASK=mask_();
 localparam integer PW=ROLE<2?220:219;
 logic [PW-1:0] native_packed;
 gpu3d_span_view #(.MASK(MASK))u(.clk,.we,.waddr(wa),.wdata(data),.raddr(ra),.read_needed(active),.rdata(q));
 gpu3d_span_view_badphase #(.MASK(MASK))bad(.clk,.we,.waddr(wa),.wdata(data),.raddr(ra),.read_needed(active),.rdata(bq));
 gpu3d_span_view_native #(.MASK(MASK))n(.clk,.we,.waddr(wa),.wdata(data),.raddr(ra),.read_needed(active),.rdata(nq));
endmodule
module tb_span_native;
 logic clk=0,we=0,active=0;logic[1:0]wa=0,ra=0;gpu3d_pkg::span_t data;
 wire [658:0]q[3],nq[3],bq[3];logic[658:0]gold[4];logic[3:0]known=0;
 integer cycle,checks=0,quarter_checks=0,unused_collisions=0;
 logic[31:0]rng=32'h935f6360;
 function automatic [31:0] rand32;
  rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);return rng;
 endfunction
 genvar r;generate for(r=0;r<3;r=r+1)begin:g_view
  native_span_view #(.ROLE(r))v(.clk,.we,.active,.wa,.ra,.data,.q(q[r]),.nq(nq[r]),.bq(bq[r]));
 end endgenerate
 function automatic [658:0]mask_(input integer role);
  for(integer b=0;b<659;b++)mask_[b]=b%3==role;
 endfunction
 task automatic check_(input bit quarter);
  logic[658:0]expected,observed;
  if(active&&known[ra])for(integer r=0;r<3;r++)begin
   expected=gold[ra]&mask_(r);observed=$test$plusargs("wrong_phase")?bq[r]:q[r];
   if(observed!==expected)$fatal(1,"SPAN_NATIVE_PHASE_CODEC role=%0d cycle=%0d quarter=%0d",r,cycle,quarter);
   if(nq[r]!==expected)$fatal(1,"SPAN_NATIVE_VENDOR role=%0d cycle=%0d",r,cycle);
   checks++;if(quarter)quarter_checks++;
  end
 endtask
 initial begin
  for(cycle=0;cycle<6000;cycle++)begin
   clk=0;#1;
   wa=cycle<4?2'(cycle):2'(rand32());we=cycle<4||cycle%4!=0;
   ra=cycle<4?wa:2'(rand32());active=cycle>=4;
   if(we&&wa==ra)begin active=0;unused_collisions++;end
   if($test$plusargs("wrong_collision")&&cycle==8)begin we=1;active=1;ra=wa;end
   for(integer b=0;b<659;b++)data[b]=1'(rand32());
   #1;check_(0);clk=1;
   if(we)begin gold[wa]=data;known[wa]=1;end
   #1;check_(0);
   // Publication is retired after its write edge. Its newly written record
   // may be read now for the next SYS load. Post-edge input changes must
   // not alter the registered write bundle.
   if(we)begin
    we=0;active=1;ra=wa;wa=wa+2'd1;data='0;
   end
   #1;check_(1);
   // Change the read owner before the falling edge. Async data must follow
   // now, rather than borrowing the FE1 half-cycle service.
   if(active)begin ra=ra+2'd1;if(we&&ra==wa)ra=ra+2'd1;end
   #1;check_(1);clk=0;#1;check_(0);
  end
  if(checks<45000||quarter_checks<10000||unused_collisions<500)$fatal(1,"SPAN_NATIVE_COVERAGE");
  $display("SPAN_NATIVE_PASS checks=%0d quarter=%0d invalidCollisions=%0d qualifiedCollisions=0",checks,quarter_checks,unused_collisions);$finish;
 end
endmodule
''')
files=[B/'gpu3d_pkg.sv',B/'gpu3d_ram.sv',B/'actual.sv',B/'bench.sv'];run.put(B/'snapshot.json',dict(vendor=str(vendor),vendor_sha256=run.sha(vendor),production_sha256=run.sha(R/'rtl/gpu3d/gpu3d_span_records.sv'),wrapper_sha256=run.sha(R/'rtl/gpu3d/gpu3d_ram.sv'),scope='Native altdpram LUTRAM one synchronous write/asynchronous read, all659bit projection lanes, post-edge owner changes and qualified-vs-invalid collisions. Does not prove synthesis/inference/area/STA.',files={p.name:run.sha(p)for p in files}))
rc,t=run.worker(B,'build',[V/'iverilog','-g2012','-s','tb_span_native','-o',B/'model.vvp',vendor,*files],build=True);assert rc==0,t[-2500:];run.put(B/'model.json',dict(sha256=run.sha(B/'model.vvp')))
results={}
for name,opts,marker in [('positive',[],'SPAN_NATIVE_PASS'),('phase',['+wrong_phase'],'SPAN_NATIVE_PHASE_CODEC'),('collision',['+wrong_collision'],'SPAN_VIEW_QUALIFIED_COLLISION')]:
 rc,t=run.worker(B,name,[V/'vvp',B/'model.vvp',*opts]);ok=rc==0 and marker in t if not opts else rc!=0 and marker in t;results[name]=dict(PASS=ok,returncode=rc,tail=t.splitlines()[-6:]);run.put(B/'result.json',dict(PASS=all(x['PASS']for x in results.values()),cases=results));assert ok,t[-3000:]
print(json.dumps(results,indent=2))
