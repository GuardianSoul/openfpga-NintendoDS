#!/usr/bin/env python3
"""Physical-view replacement against the accepted935 component source."""
from pathlib import Path
import argparse,importlib.util,json,shutil,subprocess,re,time
R=Path(__file__).resolve().parents[3];ap=argparse.ArgumentParser();ap.add_argument('--out',required=True);ap.add_argument('--fixture',type=Path);ap.add_argument('--scenes',type=int,default=4);ap.add_argument('--all-features',action='store_true');ap.add_argument('--default-off',action='store_true');ap.add_argument('--native-profile',action='store_true');a=ap.parse_args();assert 1<=a.scenes<=8;B=R/a.out;assert not B.exists();B.mkdir(parents=True)
spec=importlib.util.spec_from_file_location('runner',R/'sim/gpu3d/edge_span_service/runner.py');run=importlib.util.module_from_spec(spec);spec.loader.exec_module(run)
O=a.fixture.resolve() if a.fixture else R/'build/raster-symptoms/edge-span-original-v4'
libs=['gpu3d_pkg.sv','gpu3d_div4.sv','gpu3d_ram.sv','gpu3d_edge.sv','gpu3d_front.sv','gpu3d_front_records.sv','gpu3d_fpass.sv','gpu3d_factor_pump.sv','gpu3d_line_pool.sv','gpu3d_tpf.sv','gpu3d_edge_span.sv']
for n in libs:shutil.copyfile(R/'rtl/gpu3d'/n,B/n)
old=subprocess.check_output(['git','show','935f6360:rtl/gpu3d/gpu3d_raster.sv'],cwd=R,text=True);old=old.replace('gpu3d_span_records u_records','gpu3d_span_records_before u_records');(B/'gpu3d_raster.sv').write_text(old)
control=subprocess.check_output(['git','show','935f6360:rtl/gpu3d/gpu3d_span_records.sv'],cwd=R,text=True).replace('module gpu3d_span_records (','module gpu3d_span_records_before (');(B/'records_before.sv').write_text(control)
s=(R/'rtl/gpu3d/gpu3d_raster.sv').read_text().replace('module gpu3d_raster #(','module raster_probe #(',1);(B/'raster_probe.sv').write_text(s)
pool=R/'rtl/gpu3d/gpu3d_span_records.sv';s=pool.read_text()
x='cur_owner<=next_owner;';y='cur_owner<=next_owner ^ 2\'($test$plusargs("wrong_owner"));';assert s.count(x)==1;s=s.replace(x,y)
x2='if(late_take)begin';y2='if($test$plusargs("wrong_phase") ? late_delayed : late_take)begin';assert s.count(x2)==1;s=s.replace(x2,y2);assert s.replace(y,x).replace(y2,x2)==pool.read_text();s=s.replace('    logic [1:0] next_owner', '    logic late_delayed=0;always_ff @(posedge clk)late_delayed<=!rst&&late_take;\n    logic [1:0] next_owner',1);x3='.waddr(free_owner),.wdata(publish_data),.raddr(early_owner),';y3='.waddr($test$plusargs("wrong_collision")&&cur_valid?cur_owner:free_owner),.wdata(publish_data),.raddr(early_owner),';assert s.count(x3)==1;s=s.replace(x3,y3)
(B/'gpu3d_span_records.sv').write_text(s)
s=(O/'tb.sv').read_text().replace('gpu3d_raster #(', 'gpu3d_raster #(.SPAN_POOL('+str(int(not a.default_off))+'),.FRPOOL(1),',1).replace('raster_probe #(', 'raster_probe #(.FRPOOL(1)'+('' if a.default_off else ',.SPAN_POOL(1)')+',',1)
# The immediately previous raster/front is the control, not the old uncompressed front.
extra='''
 wire [$bits(gpu3d_pkg::span_t)-1:0] sp_e=u_probe.sd_cur,sp_l=u_probe.sd_late,sp_t=u_probe.sd_late2;
'''
extra+='''
 logic sp_late_live,sp_tail_live;
 wire [$bits(gpu3d_pkg::span_t)-1:0] sp_me=u_probe.SP_EARLY_MASK,sp_ml=u_probe.SP_LATE_MASK,sp_mt=u_probe.SP_TAIL_MASK;
 always_comb begin
 sp_late_live=u_gold.tg[14][25]||u_gold.tg[15][25]||u_gold.tg[16][25];
 sp_tail_live=u_gold.tg[17][25]||u_gold.tg[18][25]||u_gold.tg[19][25]||u_gold.tg[20][25]||u_gold.tg[21][25]||u_gold.tg[22][25];
 for(int i=0;i<TXD;i++)sp_late_live|=u_gold.txd_tag[3*i+2];
 for(int i=0;i<PXD;i++)sp_tail_live|=u_gold.pxd_tag[3*i+2];
 end
 longint sp_early=0,sp_queue=0,sp_late=0,sp_tail=0,sp_stalls=0,sp_four=0;
 always @(negedge clk)if(!rst)begin
 if(u_gold.wk_act||u_gold.early_busy)begin sp_early++;if(!$test$plusargs("public_fault")&&(sp_e&sp_me)!==(u_gold.sd_cur&sp_me))$fatal(1,"SPAN_EQ early_record");end
 if(u_gold.sd_load)begin sp_queue++;if(!$test$plusargs("public_fault")&&(SP_QUEUE_DATA&sp_me)!==(u_gold.sd_nx&sp_me))$fatal(1,"SPAN_EQ queued_record");end
 if(!u_gold.adv)sp_stalls++;
 if(!$test$plusargs("public_fault")&&!DEFAULT_OFF&&((sp_e&~sp_me)!=='0||(sp_l&~sp_ml)!=='0||(sp_t&~sp_mt)!=='0))$fatal(1,"SPAN_EQ zero_reconstruction");
 if(sp_late_live)begin
 sp_late++;if(!$test$plusargs("public_fault")&&(sp_l&sp_ml)!==(u_gold.sd_late&sp_ml))$fatal(1,"SPAN_EQ late_record");end
 if(TXD>0&&sp_tail_live)begin
 sp_tail++;if(!$test$plusargs("public_fault")&&(sp_t&sp_mt)!==(u_gold.sd_late2&sp_mt))$fatal(1,"SPAN_EQ tail_record");end
 end
 final $display("SPAN_COVERAGE width%0d early%0d queue%0d late%0d tail%0d holds%0d",$bits(gpu3d_pkg::span_t),sp_early,sp_queue,sp_late,sp_tail,sp_stalls);
'''
extra+='''
 assign abort_windows={u_gold.tg[17][25],u_gold.T13.v&&u_gold.T13.first,u_gold.nx_full&&u_gold.wk_act};
 longint sp_capture=0;always @(negedge clk)if(!rst&&ll_ack)sp_capture++;
 final $display("SPAN_CAPTURE samples=%0d",sp_capture);
'''
s=s.replace('\n);','\n, output logic [2:0] abort_windows\n);',1)
s=s.replace('endmodule',extra+'\nendmodule');s=s.replace('SP_QUEUE_DATA','u_probe.sd_nx' if a.default_off else 'sp_e').replace('DEFAULT_OFF',str(int(a.default_off)));s=s.replace('endmodule','final $display("SPAN_PHYSICAL widths=%0d,%0d,%0d",$countones(u_probe.SP_EARLY_MASK),$countones(u_probe.SP_LATE_MASK),$countones(u_probe.SP_TAIL_MASK));\nendmodule');(B/'tb.sv').write_text(s)
s=(O/'main.cpp').read_text();s=s.replace('uint64_t clocks=0,spans=0;',f'''std::vector<Scene> selected;for(auto&x:s)if(x.name=="shapes"||x.name=="tex_formats_linear"||x.name=="tex_formats_decal"||x.name=="wbuffer"||x.name=="blend"||x.name=="wireframe_aa"||x.name=="shadow_w_tex"||x.name=="pokemon_mix")selected.push_back(x);s=selected;s.resize(std::min(size_t({a.scenes}),s.size()));uint64_t clocks=0,spans=0;''',1);s=s.replace('PASS_ORIGINAL_PUBLICATION','PASS_SPAN_RECORD_PUBLICATION')
s=s.replace('RtlResult render_rtl(', 'static bool sp_exercise=false;\nRtlResult render_rtl(',1)
s=s.replace('    bool done = false;', '    bool done = false;unsigned sp_aborted=0;',1)
s=s.replace('        // drive inputs for this cycle', '''        if(sp_exercise && sp_aborted<3 && (m->abort_windows & (1u<<sp_aborted))) {
            m->rst=1;m->ps_valid=0;m->tex_valid=0;m->pal_valid=0;m->frame_start=0;tick();tick();
            q.clear();texq.clear();palq.clear();tw_at.clear();lreq.clear();sp_gap=-1;
            m->rst=0;m->frame_start=1;tick();m->frame_start=0;sp_aborted++;
        }
        m->px_hold=sp_exercise && res.cycles%257>=100 && res.cycles%257<117;
        m->ll_rd=sp_exercise && res.cycles%97<8;m->ll_slot=(m->fp_line+2)%3;m->ll_x=res.cycles%256;
        // drive inputs for this cycle''',1)
s=s.replace('    res.timeout = !done;', '    if(sp_exercise){if(sp_aborted!=3)throw std::runtime_error("SPAN_ABORT_COVERAGE");printf("SPAN_ABORT_PASS resets=%u\\n",sp_aborted);}\n    res.timeout = !done;',1)
s=s.replace('auto s=builtin_scenes();','for(int i=1;i<argc;i++)if(std::string(argv[i])=="+exercise")sp_exercise=true;auto s=builtin_scenes();',1)
(B/'main.cpp').write_text('#include <stdexcept>\n'+s)
for n in ['scene.h','scenes.cpp','derive.cpp']:shutil.copyfile(O/n,B/n)
profile=json.loads((O/'snapshot.json').read_text())['profile'];profile.update(FEAT_AA=1 if a.all_features else 0,FEAT_EDGE=1 if a.all_features else 0,FEAT_TOON=1 if a.all_features else 0,TR3=0 if a.all_features else 1)
if a.native_profile:profile.update(FEAT_SHADOW=0,FEAT_LOWER=0)
files=[B/n for n in libs+['gpu3d_raster.sv','records_before.sv','raster_probe.sv','gpu3d_span_records.sv','tb.sv','main.cpp','scenes.cpp','derive.cpp']]
run.put(B/'snapshot.json',dict(parent='935f6360',shadow=False,scenes=a.scenes,profile=profile,pool_sha256=run.sha(pool),files={p.name:run.sha(p)for p in files+[B/'scene.h']}))
V='build/tools/oss-cad-suite/bin/verilator';cmd=[V,'--cc','--exe','--build','--no-timing','--assert','--threads','1','-j','1','-Wno-fatal','--compiler','clang','-CFLAGS','-std=c++20 -O1 -I'+str(B),'-MAKEFLAGS','CXX=clang++ VM_PARALLEL_BUILDS=1','--top-module','publication_tb','--Mdir',B/'obj',*['-G'+k+'='+str(v)for k,v in profile.items()],*files]
rc,t=run.worker(B,'build',cmd,build=True);assert rc==0,t[-3500:]
run.put(B/'model.json',dict(sha256=run.sha(B/'obj/Vpublication_tb'),snapshot_sha256=run.sha(B/'snapshot.json')))
results={}
for name,opts in ([('positive',[]),('exercise',['+exercise'])] if a.default_off else [('positive',[]),('owner',['+wrong_owner']),('phase',['+wrong_phase']),('collision',['+wrong_collision']),('public-owner',['+wrong_owner','+public_fault']),('public-phase',['+wrong_phase','+public_fault']),('exercise',['+exercise'])]):
 rc,t=run.worker(B,name,[B/'obj/Vpublication_tb',*opts],seconds=600);good=(rc!=0 and 'SPAN_VIEW_QUALIFIED_COLLISION' in t) if name=='collision' else (rc!=0 and ('ORIGINAL_PUBLICATION_FAIL public_' in t or 'gpu3d_raster:' in t)) if name.startswith('public-') else rc!=0 and 'SPAN_EQ' in t if name in ['owner','phase'] else rc==0 and 'PASS_SPAN_RECORD_PUBLICATION' in t and (name!='exercise' or t.count('SPAN_ABORT_PASS resets=3')==a.scenes)
 results[name]=dict(PASS=good,returncode=rc,tail=t.splitlines()[-8:]);run.put(B/'result.json',dict(PASS=all(x['PASS']for x in results.values()),cases=results));assert good,t[-3000:]
print(json.dumps(results,indent=2))
