#!/usr/bin/env python3
"""Clock-exact default-off ring glue and SDRAM pins against b621ba32."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import check

PIN='b621ba32f5a04f031abdc759ef1255bac628dca8'
IN='''input logic clk,rst,frame_go,l3d_go,l3d_done,
input logic[7:0] l3d_line,l3d_raddr,px_x,px_y,fp_line,
input logic[22:0] px_color,ll_q,input logic px_valid,r_fp_act,ll_ack,q_wack,q_rack,q_rvalid,rg_wdrained,
input logic[31:0] rg_rdata,input logic[8:0] r_front_go,input logic[6:0]rg_wfill,rg_wpcnt,
input logic ring_due_valid,input logic[7:0]ring_due_line,input logic[13:0]ring_due_sys,
output wire[22:0] ring_q,output wire[8:0]y_lim_rg,output wire ring_have,
output wire[3:0]st_busy,output wire ll_rd,output wire[1:0]ll_slot,output wire[7:0]ll_x,
output wire q_wreq,q_rreq,rg_hurry,output wire[23:0]q_waddr,q_raddr,output wire[31:0]q_wdata'''
INPUTS='clk rst frame_go l3d_go l3d_done l3d_line l3d_raddr px_x px_y fp_line px_color ll_q px_valid r_fp_act ll_ack q_wack q_rack q_rvalid rg_wdrained rg_rdata r_front_go rg_wfill rg_wpcnt ring_due_valid ring_due_line ring_due_sys'.split()
OUTPUTS='ring_q y_lim_rg ring_have st_busy ll_rd ll_slot ll_x q_wreq q_rreq rg_hurry q_waddr q_raddr q_wdata'.split()


def baseline(p):
    return subprocess.check_output(['git','show',PIN+':'+p],cwd=check.ROOT).decode()


def glue(source,name):
    a=source.index('    generate if (RING) begin : g_ring')
    b=source.index('    end else begin : g_oring',a)
    return 'module '+name+'('+IN+');\nlocalparam bit RING=1,RDEADLINE=0,YLIM2=1,LLR=1,RPRI=1,NX2=0,TR3=0,FEAT_EDGE=1,LB2=0;\nlocalparam int RH_AT=32,RLEAD=192;\n'+source[a:b]+'end endgenerate\nendmodule\n'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--fault',action='store_true')
    args=ap.parse_args();os.nice(10)
    B=args.out.resolve();assert not B.exists();B.mkdir(parents=True);check.admission()
    paths=['rtl/ds/nds_gpu3d.sv','rtl/ds/nds_g3d_ring.sv','rtl/ds/nds_g3d_ring_deadline.sv',
           'rtl/gpu3d/gpu3d_ram.sv','rtl/pocket/nds_sdram_bus.sv','rtl/pocket/nds_sdram_mc.sv',
           'rtl/pocket/nds_cdc.sv','sim/phase1/sim_prims.sv']
    manifest={}
    for p in paths:
        q=B/Path(p).name;q.write_bytes((check.ROOT/p).read_bytes());manifest[p]=check.sha(q)
    assert baseline('rtl/ds/nds_g3d_ring.sv')==(B/'nds_g3d_ring.sv').read_text()
    actual=(B/'nds_gpu3d.sv').read_text()
    if args.fault:
        a='o_wr,o_wa,o_wd,o_rr,o_ra};';assert actual.count(a)==1
        actual=actual.replace(a,"o_wr,o_wa,(o_wd ^ 32'd1),o_rr,o_ra};")
    (B/'glue.sv').write_text(glue(actual,'ring_glue')+glue(baseline('rtl/ds/nds_gpu3d.sv'),'ring_glue_before'))
    before=baseline('rtl/pocket/nds_sdram_bus.sv').split('endmodule')[0]+'endmodule\n'
    before=before.replace('module nds_sdram_bus #','module nds_sdram_bus_before #').replace('nds_sdram_mc #','nds_sdram_mc_before #')
    (B/'bus_before.sv').write_text(before)
    (B/'mc_before.sv').write_text(baseline('rtl/pocket/nds_sdram_mc.sv').replace('module nds_sdram_mc #','module nds_sdram_mc_before #'))
    t='''`timescale 1ns/1ps
module defaultoff_tb;
logic clk=0,mc=0;always #7.5 clk=!clk;always #5 mc=!mc;
logic rst=1,frame_go=0,l3d_go=0,l3d_done=0;
logic[7:0]l3d_line=0,l3d_raddr=0,px_x=0,px_y=0,fp_line=0;
logic[22:0]px_color=0,ll_q=0;
logic px_valid=0,r_fp_act=0,ll_ack=0,q_wack=0,q_rack=0,q_rvalid=0,rg_wdrained=0;
logic[31:0]rg_rdata=0;logic[8:0]r_front_go=0;
logic[6:0]rg_wfill=0,rg_wpcnt=0;logic ring_due_valid=0;logic[7:0]ring_due_line=0;logic[13:0]ring_due_sys=0;
wire[22:0]ring_q,ring_q_b;wire[8:0]y_lim_rg,y_lim_rg_b;wire ring_have,ring_have_b;
wire[3:0]st_busy,st_busy_b;wire ll_rd,ll_rd_b;wire[1:0]ll_slot,ll_slot_b;wire[7:0]ll_x,ll_x_b;
wire q_wreq,q_wreq_b,q_rreq,q_rreq_b,rg_hurry,rg_hurry_b;
wire[23:0]q_waddr,q_waddr_b,q_raddr,q_raddr_b;wire[31:0]q_wdata,q_wdata_b;
@GLUE_INST@
integer sys_n=0,eq_ring=0,eq_pin=0,commands=0;
integer rm=0,rk=0;
always @(negedge clk)begin
 sys_n++;
 q_wack=q_wreq&&sys_n%3!=0;ll_ack=ll_rd&&sys_n%4!=0;ll_q=23'(sys_n);
 q_rack=0;q_rvalid=0;
 if(rm==0&&q_rreq)begin q_rack=1;rm=1;rk=0;end
 else if(rm==1)begin q_rvalid=1;rg_rdata=32'(sys_n*65537);rk++;if(rk==8)rm=0;end
 rg_wdrained=sys_n%13==0;
 ring_due_valid=sys_n%2;ring_due_line=8'(sys_n);ring_due_sys=14'(sys_n*31);
end
wire[130:0]ringa={@RING_A@},ringb={@RING_B@};
always @(posedge clk)begin #1;if(!rst)begin eq_ring++;if(ringa!==ringb)$fatal(1,"DEFAULT_RING_DATE a=%h b=%h",ringa,ringb);end end
logic init=1;logic[6:0]valid=0,we=0;logic[167:0]addr=0;logic[27:0]n=0,be=0;logic[223:0]wd=0;
wire[6:0]take,take_b,rv,rv_b;wire[31:0]rd,rd_b;wire ready,ready_b,late_ref,late_b;
logic[6:0]hurry=0;logic bv=0;logic[23:0]baddr=0;logic[31:0]bdata=0;logic[1:0]bhe=3;
wire bread,bread_b;wire[15:0]dq,dq_b;wire[12:0]a,a_b;wire[1:0]ba,ba_b,dqm,dqm_b;
wire nwe,nwe_b,nras,nras_b,ncas,ncas_b,cke,cke_b,sclk,sclk_b;
@BUS_INST@
assign dq=!after_bus.mc.dq_oe?16'h59c7:16'hzzzz;
assign dq_b=!before_bus.mc.dq_oe?16'h59c7:16'hzzzz;
integer mem_n=0;logic[31:0]random_bits=32'hac51e83f;
always @(negedge mc)begin
 mem_n++;random_bits={random_bits[30:0],random_bits[31]^random_bits[21]^random_bits[1]^random_bits[0]};
 if(mem_n==5)init=0;
 if(ready)begin
  for(integer i=0;i<7;i++)begin
   if(take[i])valid[i]=0;
   else if(!valid[i]&&random_bits[i])begin
    valid[i]=1;we[i]=random_bits[7+i];addr[i*24+:24]={1'b0,random_bits[1:0],11'd0,random_bits[3:2],random_bits[11:7],3'b000};
    n[i*4+:4]=we[i]?1:(i%2==0?8:4);be[i*4+:4]=random_bits[19:16];wd[i*32+:32]=random_bits;
   end
  end
  hurry=random_bits[6:0];bv=mem_n%5!=0;
  if(bread)begin baddr=baddr+24'd1;bdata=random_bits;bhe=random_bits[1:0];end
 end
 if(mem_n==100000)begin
  if(eq_ring<1000||eq_pin<10000||commands<1000)$fatal(1,"EQ_COVERAGE");
  $display("DEFAULT_OFF_PASS ring=%0d pin=%0d commands=%0d",eq_ring,eq_pin,commands);$finish;
 end
end
wire[255:0]pina={dq,a,ba,dqm,nwe,nras,ncas,cke,sclk,ready,take,rv,rd,late_ref,bread,after_bus.mc.dq_oe,after_bus.mc.dq_out};
wire[255:0]pinb={dq_b,a_b,ba_b,dqm_b,nwe_b,nras_b,ncas_b,cke_b,sclk_b,ready_b,take_b,rv_b,rd_b,late_b,bread_b,before_bus.mc.dq_oe,before_bus.mc.dq_out};
always @(mc)begin #1;eq_pin++;if(pina!==pinb)$fatal(1,"DEFAULT_MEM_PIN a=%h b=%h",pina,pinb);if({nras,ncas,nwe}!=7)commands++;end
initial begin
 repeat(5)@(negedge clk);rst=0;frame_go=1;@(negedge clk);frame_go=0;
 for(integer y=0;y<24;y++)begin
  while(st_busy[y%4])@(negedge clk);
  for(integer x=0;x<256;x++)begin @(negedge clk);px_valid=1;px_x=8'(x);px_y=8'(y);px_color=23'(y*256+x+1);end
  @(negedge clk);px_valid=0;
 end
end
initial begin
 wait(!rst);
 for(integer y=0;y<40;y++)begin
  repeat(500)@(negedge clk);l3d_go=1;@(negedge clk);l3d_go=0;l3d_line=8'(y);
  for(integer x=0;x<256;x++)begin @(negedge clk);l3d_raddr=8'(x);end
  repeat(50)@(negedge clk);l3d_done=1;@(negedge clk);l3d_done=0;
 end
end
endmodule
'''
    inst=[]
    for module,suffix in [('ring_glue',''),('ring_glue_before','_b')]:
        inst.append(module+' g'+suffix+'('+','.join('.'+x+'('+x+')' for x in INPUTS)+','+','.join('.'+x+'('+x+suffix+')' for x in OUTPUTS)+');')
    t=t.replace('@GLUE_INST@','\n'.join(inst)).replace('@RING_A@',','.join(OUTPUTS)).replace('@RING_B@',','.join(x+'_b' for x in OUTPUTS))
    inst=[]
    common={'clk':'mc','init':'init','m_hurry':'hurry','m_valid':'valid','m_we':'we','m_addr':'addr','m_n':'n','m_wdata':'wd','m_be':'be','bw_valid':'bv','bw_addr':'baddr','bw_data':'bdata','bw_he':'bhe'}
    outs={'ready':'ready','m_take':'take','w_valid':'rv','w_data':'rd','ref_late':'late_ref','bw_read':'bread','SDRAM_DQ':'dq','SDRAM_A':'a','SDRAM_BA':'ba','SDRAM_DQML':'dqm[0]','SDRAM_DQMH':'dqm[1]','SDRAM_nWE':'nwe','SDRAM_nRAS':'nras','SDRAM_nCAS':'ncas','SDRAM_CKE':'cke','SDRAM_CLK':'sclk'}
    for module,name,suffix in [('nds_sdram_bus','after_bus',''),('nds_sdram_bus_before','before_bus','_b')]:
        ports=dict(common)
        for k,v in outs.items():
            v=v.replace('late_ref','late') if suffix else v
            ports[k]=v.replace('[',suffix+'[') if '[' in v else v+suffix
        inst.append(module+' #(.N(7),.OPEN(1),.OUT_REG(1),.HURRY(1)) '+name+'('+','.join('.'+k+'('+v+')' for k,v in ports.items())+');')
    t=t.replace('@BUS_INST@','\n'.join(inst));(B/'bench.sv').write_text(t)
    (B/'source.json').write_text(json.dumps({'before':PIN,'actual_paths':manifest,'fault':args.fault,'generated':{p.name:check.sha(p) for p in B.glob('*.sv')}},indent=2)+'\n')
    files=[B/Path(p).name for p in paths if not p.endswith('nds_gpu3d.sv')]+[B/'bus_before.sv',B/'mc_before.sv',B/'glue.sv',B/'bench.sv']
    try:
        rc=check.run([check.BIN/'verilator','--binary','--timing','--assert','--threads','1','-j','1','-O1',
                      '-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-PINMISSING','-Wno-TIMESCALEMOD',
                      '-Wno-MULTIDRIVEN','--compiler','clang','-CFLAGS','-std=c++20 -O0',
                      '-MAKEFLAGS','CXX=clang++ VM_PARALLEL_BUILDS=1','--top-module','defaultoff_tb',
                      '--Mdir',B/'obj',*files],B/'build.log',True)
        assert rc==0,(B/'build.log').read_text()[-3000:]
        rc=check.run([B/'obj/Vdefaultoff_tb'],B/'run.log');log=(B/'run.log').read_text()
        ok=rc!=0 and 'DEFAULT_RING_DATE' in log if args.fault else rc==0 and 'DEFAULT_OFF_PASS' in log and 'ERROR:' not in log
        (B/'result.json').write_text(json.dumps({'PASS':ok,'returncode':rc,'fault':args.fault,'log_sha256':check.sha(B/'run.log')},indent=2)+'\n')
        print(log[-2500:]);assert ok,B
    finally:check.status()


if __name__=='__main__':main()
