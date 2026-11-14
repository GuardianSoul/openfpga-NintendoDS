#!/usr/bin/env python3
"""Freeze exact e63 services and assemble their original accepted boundaries."""
from pathlib import Path
import hashlib,json,shutil,subprocess,sys
R=Path(__file__).resolve().parents[3]
SOURCE='e63b56125c40c94b849ddaf35a8e4d3d975803a7'
def sha(b):return hashlib.sha256(b).hexdigest()
def module(s,n):
 a=s.index('module '+n+' #(');return s[a:s.index('endmodule',a)+9]+'\n'
def prepare(B):
 B.mkdir(parents=True,exist_ok=False)
 src=(R/'rtl/ds/nds_gpu3d.sv').read_text()
 assert subprocess.check_output(['git','show',SOURCE+':rtl/ds/nds_gpu3d.sv'],cwd=R).decode()==src
 manifest={};sections={}
 def part(name,a,b):
  q=src[src.index(a):src.index(b,src.index(a))];sections[name]=sha(q.encode());return q
 params=part('parameters','#(\n    parameter bit FRPOOL','\n) (')
 decl=part('raster_signals','    logic        tex_req,','    // ---- diagnostics')
 drops=part('restart_returns','    logic        tc_v, pc_v;','    // G3D_STALL')
 raster=part('raster_instantiation','    gpu3d_raster #(', '\n    // ---------------------------------------------- texture/palette caches')
 # frame_done is an unused production output; observing it adds no DUT input.
 raster=raster.replace('.frame_done(),','.frame_done(frame_done),')
 cache=part('caches_and_owner_mux','    // ---------------------------------------------- texture/palette caches','    // ---------------------------------------------------------- 3D line ring')
 ring=part('selected_ring_call',"            nds_g3d_ring_deadline #(", '\n        end else begin : g_classic')
 ring=ring.replace('.l3d_rdata(ring_q)','.l3d_rdata(l3d_rdata)').replace('q_wreq','rg_wreq').replace('q_waddr','rg_waddr').replace('q_wdata','rg_wdata').replace('q_wack','rg_wack').replace('q_rreq','rg_rreq').replace('q_raddr','rg_raddr').replace('q_rack','rg_rack').replace('q_rvalid','rg_rvalid')
 guard=part('stage_guard','    wire         fp_hold =','    generate if (RING)')
 ports=(R/'sim/ds/render_service/ports.svh').read_text()
 common='''
    logic frame_go,r_busy;wire r_abort=RESTART&&fg_now&&r_busy;
    always_ff @(posedge clk)frame_go<=!rst&&fg_now;
    wire r_ps_valid=ps_valid;wire r_ps_ready;assign ps_ready=r_ps_ready;
    wire[15:0]r_dispcnt=16'h0081;wire[4:0]r_alpharef=0;
    wire[31:0]r_clear_attr1=32'h001f0000|32'(generation*1024+7);
    wire[14:0]r_clear_depth=15'h7fff;wire[20:0]r_fog_color=21'h123456;
    wire[14:0]r_fog_offset=0;wire tbl_we=0;wire[1:0]tbl_sel=0;
    wire[4:0]tbl_addr=0;wire[14:0]tbl_data=0;wire vram_wr=0;
    logic[3:0]st_busy;logic[7:0]fp_line;logic r_fp_act;
    logic[8:0]r_front_go;logic ll_rd,ll_ack;logic[1:0]ll_slot;
    logic[7:0]ll_x;logic[22:0]ll_q;
'''
 text=''
 for ideal in [False,True]:
  name='render_cone_reference' if ideal else 'render_cone'
  d=decl.replace('    logic        tex_req, tex_valid, pal_req, pal_valid;','    logic tex_valid,pal_valid;').replace('    logic [18:0] tex_addr;','').replace('    logic [16:0] pal_addr;','').replace('    logic        px_valid;','').replace('    logic [7:0]  px_x, px_y;','').replace('    logic [22:0] px_color;','')
  text+='module '+name+' import gpu2d_pkg::*;\n'+params+'\n'+ports+'\n'+common+d+drops+raster
  if ideal:
   text+='''
    `include "image.svh"
    always_ff @(posedge clk)begin
      tc_v<=!rst&&tex_req;pc_v<=!rst&&pal_req;
      tex_data<={texture_byte(int'(tex_addr&19'h7fffe)+1),texture_byte(int'(tex_addr&19'h7fffe))};
      pal_data<=palette_half(int'(pal_addr&17'h0fffe));
    end
    wire fp_hold=0;assign ll_rd=0;assign ll_slot=0;assign ll_x=0;
    assign ll_ack=0;assign ll_q=0;assign y_lim_rg=511;
    assign {rg_wreq,rg_waddr,rg_wdata,rg_rreq,rg_hurry,rg_raddr,l3d_rdata,l3d_have}=0;
'''
  else:
   text+=cache+guard+'\n'+ring+'\nassign l3d_have=ring_have;\n'
   text=text.replace('logic [3:0]  t_n;', 'logic [3:0]  t_n;',1)
  text+='endmodule\n'
 # The original call names its output ring_have; preserve that actual wire.
 text=text.replace('    logic[3:0]st_busy;', '    wire ring_have;logic[3:0]st_busy;')
 (B/'cone.sv').write_text(text)
 files=['rtl/gpu2d/gpu2d_pkg.sv',*map(str,(p.relative_to(R) for p in (R/'rtl/gpu3d').glob('*.sv'))),
 'rtl/ds/nds_lcache.sv','rtl/ds/nds_vram.sv','rtl/ds/nds_blk_arb.sv','rtl/ds/nds_g3d_ring_deadline.sv',
 'rtl/pocket/nds_ring_post_arb.sv','rtl/pocket/nds_cdc.sv','rtl/pocket/nds_x2b.sv','rtl/pocket/nds_sdram_mc.sv','rtl/pocket/nds_sdram_bus.sv',
 'sim/phase1/sim_prims.sv','sim/phase1/sdram_chip_model.sv','sim/pocket_ds/sim_prims_ds.sv']
 for f in files:
  data=(R/f).read_bytes();assert data==subprocess.check_output(['git','show',SOURCE+':'+f],cwd=R),f
  manifest[f]=sha(data);(B/Path(f).name).write_bytes(data)
 for f in ['image.svh','provider.sv','tb.sv','observe.svh']:
  shutil.copyfile(R/'sim/ds/render_service'/f,B/f)
 (B/'cache.sv').write_text(module(src,'nds_g3d_cache2')+module(src,'nds_g3d_data4'))
 faults=[('nds_sdram_bus.sv','own[own_w] <= g;',"own[own_w] <= g ^ $clog2(N)'($test$plusargs(\"fault_native_owner\"));"),
 ('nds_blk_arb.sv','own[wp] <= pick_b;',"own[wp] <= pick_b ^ $test$plusargs(\"fault_block_owner\");"),
 ('nds_g3d_ring_deadline.sv','candidate_ok[n] = candidate < 192', 'candidate_ok[n] = !($test$plusargs("fault_deadline") && candidate == 2) && candidate < 192')]
 for f,a,b in faults:
  p=B/f;s=p.read_text();assert s.count(a)==1;p.write_text(s.replace(a,b));assert p.read_text().replace(b,a)==s
 (B/'source.json').write_text(json.dumps(dict(source=SOURCE,production_files=manifest,exact_sections=sections,
  boundary='PS line stream, original tex/pal and block handshakes, VRAM CPU/capture, native port/FIFO, ring consumer/due; no game or CPU core',
  policy='e63 unchanged; runtime fault probes inverse-exact; reference has ideal data only',
  files={p.name:sha(p.read_bytes()) for p in B.glob('*') if p.is_file()}),indent=2)+'\n')
if __name__=='__main__':prepare(Path(sys.argv[1]).resolve())
