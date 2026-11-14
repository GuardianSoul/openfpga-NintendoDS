#!/usr/bin/env python3
"""One predeclared input case; production policy/guards are unchanged."""
from pathlib import Path
import argparse,hashlib,json,re,sys
import prepare

def main():
    ap=argparse.ArgumentParser();ap.add_argument('out',type=Path);ap.add_argument('--format',choices=['indexed8','compressed4x4'],default='indexed8');ap.add_argument('--urgency-prototype',action='store_true');a=ap.parse_args()
    B=a.out.resolve();prepare.prepare(B)
    p=B/'provider.sv';provider=(Path(__file__).parent/'pressure_provider.sv').read_bytes()
    header=int(re.search(rb"b\[63:32\]=32'h([0-9a-f]+)",provider).group(1),16)
    assert (header>>26)&7==4 and (header>>20)&7==5 and (header>>23)&7==5,'declared indexed8/256x256 fixture'
    if a.format=='compressed4x4':provider=provider.replace(b"32'h12d00000",b"32'h16d00000").replace(b'format4 indexed8',b'format5 compressed4x4')
    p.write_bytes(provider)
    p=B/'observe.svh';s=p.read_text();assert s.count('48*1024*1024')==1
    s=s.replace('48*1024*1024','128*1024*1024')
    needle=' obs_sys++;';assert s.count(needle)==1
    s=s.replace(needle,needle+'''
 if(!rst&&!dut.frame_go&&!dut.r_abort&&ring_due_valid&&completed_rows<=int'(ring_due_line)&&
    (dut.u_raster.wait17||dut.u_raster.wait19))begin
  if(fd&&({generation,ring_due_line,dut.u_raster.y,dut.u_raster.wait17,dut.u_raster.wait19}!=pressure_last))
   $fdisplay(fd,"DUE_DEPENDENCY,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",obs_sys,generation,ring_due_line,ring_due_sys,completed_rows,dut.u_raster.y,dut.u_raster.wait17,dut.u_raster.wait19,int'(vram.st));
  pressure_last={generation,ring_due_line,dut.u_raster.y,dut.u_raster.wait17,dut.u_raster.wait19};
  if(ring_due_sys==0)pressure_overdue++;else pressure_predue++;
 end else pressure_last='1;
''')
    s='logic[20:0]pressure_last=\'1;integer pressure_predue=0,pressure_overdue=0;\n'+s
    p.write_text(s)
    if a.urgency_prototype:
        p=B/'tb.sv';s=p.read_text();old='wire hurry2=d_req && syscycles%4260>=2800;';assert s.count(old)==1
        s=s.replace(old,'''wire producer_hurry=$test$plusargs("producer_hurry") && !rst&&!dut.frame_go&&!dut.r_abort&&
  ring_due_valid&&completed_rows<=int'(ring_due_line)&&(dut.u_raster.wait17||dut.u_raster.wait19);
 wire hurry2=(d_req && syscycles%4260>=2800)||producer_hurry;''');p.write_text(s)
    snap=json.loads((B/'source.json').read_text());snap['pressure_plan']='build/render-service-pressure-plan/plan.json'
    snap['input_scope']='Full-screen two256x256 '+a.format+' quad textures; same oracle inputs; no rate/deadline/guard change. Trace output cap128MiB only.'
    snap['urgency_prototype']=dict(present=a.urgency_prototype,default_off=True,scope='Test-only existing port2 urgency input; due unfinished row plus actual wait17/19. No production source/cost qualification; native bounded policy and2D urgency unchanged.')
    snap['files']={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in B.iterdir()if p.is_file()and p.name!='source.json'}
    (B/'source.json').write_text(json.dumps(snap,indent=2)+'\n')
if __name__=='__main__':main()
