#!/usr/bin/env python3
"""Original-versus-front-record-lifetime publication/date and actual faults."""
from pathlib import Path
import argparse,importlib.util,json,re,shutil,time
R=Path(__file__).resolve().parents[3]
a=argparse.ArgumentParser();a.add_argument('--out',required=True);a.add_argument('--scenes',type=int,default=71);a.add_argument('--default-off',action='store_true');args=a.parse_args();B=R/args.out;assert not B.exists();B.mkdir()
sp=importlib.util.spec_from_file_location('es_runner',R/'sim/gpu3d/edge_span_service/runner.py');run=importlib.util.module_from_spec(sp);sp.loader.exec_module(run)
O=R/'build/raster-symptoms/edge-span-original-v4';assert json.loads((O/'result.json').read_text())['result']=='PASS_ORIGINAL_PUBLICATION_AND_TWO_ACTUAL_FAULTS'
libs=['gpu3d_pkg.sv','gpu3d_div4.sv','gpu3d_ram.sv','gpu3d_edge.sv','gpu3d_front.sv','gpu3d_fpass.sv','gpu3d_raster.sv','gpu3d_factor_pump.sv','gpu3d_line_pool.sv','gpu3d_tpf.sv']
for n in libs:shutil.copyfile(O/n,B/n)
# Existing source oracle, clock driver and scenes are reused byte-for-byte
# except renamed types and selecting the enabled candidate at the wrapper.
s=(R/'rtl/gpu3d/gpu3d_front.sv').read_text();s=s.replace('module gpu3d_front #(','module front_probe #(',1);(B/'front_probe.sv').write_text(s)
s=(R/'rtl/gpu3d/gpu3d_raster.sv').read_text();s=s.replace('module gpu3d_raster #(','module raster_probe #(',1).replace('gpu3d_front #(','front_probe #(',1);(B/'raster_probe.sv').write_text(s)
# Unchanged, unselected ES2/EPSCHED modules are required by the source list.
shutil.copyfile(R/'rtl/gpu3d/gpu3d_edge_span.sv',B/'gpu3d_edge_span.sv')
s=(R/'rtl/gpu3d/gpu3d_front_records.sv').read_text()
mutations=[('wire [2:0] wa=middle?held_late_owner:early_owner;', 'wire [2:0] wa=middle?(held_late_owner ^ 3\'($test$plusargs("wrong_late_owner"))):early_owner;'),('wire we_late=!rst&&middle&&held_late_we;','wire we_late=!rst&&(middle ^ $test$plusargs("wrong_late_phase"))&&held_late_we;')]
for good,bad in mutations:assert s.count(good)==1;s=s.replace(good,bad)
inverse=s
for good,bad in mutations:inverse=inverse.replace(bad,good)
assert inverse==(R/'rtl/gpu3d/gpu3d_front_records.sv').read_text();(B/'gpu3d_front_records.sv').write_text(s)
s=(B/'front_probe.sv').read_text();n='.early_owner({a_ph==2\'d3,ha[1:0]})';b='.early_owner({a_ph==2\'d3,$test$plusargs("wrong_early_cursor")?2\'(e_wp):ha[1:0]})';assert s.count(n)==1;s=s.replace(n,b);assert s.replace(b,n)==(R/'rtl/gpu3d/gpu3d_front.sv').read_text().replace('module gpu3d_front #(','module front_probe #(',1);(B/'front_probe.sv').write_text(s)
s=(O/'tb.sv').read_text().replace('raster_probe #(', f'raster_probe #(.ES2(0),.EP_SCHED(0),.FRPOOL({int(not args.default_off)}),',1)
# No probe hierarchy assumptions: the gold hierarchy remains frozen original.
s=s.replace('ORIGINAL_PUBLICATION','CONNECTED_PUBLICATION')
s=s.replace('longint checks=0,', 'longint fr_dual=0,fr_full=0,fr_take_write=0,fr_late_right=0;longint checks=0,',1)
s=s.replace(' checks++;',""" checks++;
 if(u_gold.u_front.a_ho_v&&u_gold.u_front.b_done)fr_dual++;
 if(u_gold.u_front.lcn==3)fr_full++;
 if((u_gold.u_front.a_ho_v||u_gold.u_front.b_done)&&u_gold.u_front.s_take)fr_take_write++;
 if(u_gold.u_front.a_ho_v&&u_gold.u_front.a_ph==3&&2'(u_gold.u_front.e_wp)!=u_gold.u_front.ha[1:0])fr_late_right++;
 if(u_gold.u_front.ss==u_gold.u_front.SS_EP&&{u_gold.u_front.ep_len_c,u_gold.u_front.ep_covx_c,u_gold.u_front.ep_cov5_c,u_gold.u_front.ep_negn_c}!=={u_probe.u_front.ep_len_c,u_probe.u_front.ep_covx_c,u_probe.u_front.ep_cov5_c,u_probe.u_front.ep_negn_c})$fatal(1,"FRONT_RECORDS_FAIL params");
 if({u_gold.u_front.eu_bb,u_gold.u_front.eu_bf}!=={u_probe.u_front.eu_bb,u_probe.u_front.eu_bf})$fatal(1,"CONNECTED_PUBLICATION_FAIL edge_handshake");
 if({u_gold.u_front.ed_start,u_gold.u_front.ed2_start}!=={u_probe.u_front.ed_start,u_probe.u_front.ed2_start})$fatal(1,"CONNECTED_PUBLICATION_FAIL span_divider_date");
 if((u_gold.u_front.ed_start||u_gold.u_front.ed2_start)&&{u_gold.u_front.ed_num,u_gold.u_front.ed_den}!=={u_probe.u_front.ed_num,u_probe.u_front.ed_den})$fatal(1,"CONNECTED_PUBLICATION_FAIL span_divider_value");
""")
# Three real in-flight reset windows, selected from the frozen oracle.
s=s.replace('\n);', '\n, output logic [2:0] abort_windows\n);',1)
s=s.replace('final $display',"""assign abort_windows={u_gold.u_front.ss==u_gold.u_front.SS_ATTR&&u_gold.u_front.at_k==2,
 u_gold.u_front.ss==u_gold.u_front.SS_EPM,
 u_gold.u_front.g_ep2.u_edgeb.xs==u_gold.u_front.g_ep2.u_edgeb.X_IP&&u_gold.u_front.g_ep2.u_edgeb.k==3};
final $display""",1)
s=s.replace('final $display("CONNECTED_PUBLICATION_COUNTS', 'final $display("FRPOOL_COVERAGE dual%0d full%0d takeWrite%0d lateRight%0d",fr_dual,fr_full,fr_take_write,fr_late_right);\nfinal $display("CONNECTED_PUBLICATION_COUNTS',1)
(B/'tb.sv').write_text(s)
s='#include <stdexcept>\n'+(O/'main.cpp').read_text().replace('PASS_ORIGINAL_PUBLICATION','PASS_CONNECTED_PUBLICATION')
s=s.replace('RtlResult render_rtl(', 'static bool es_abort_mode=false;\nRtlResult render_rtl(',1)
s=s.replace('    bool done = false;', '    bool done = false; unsigned es_aborted=0;',1)
s=s.replace('        // drive inputs for this cycle', '''        if(es_abort_mode && es_aborted<3 && (m->abort_windows & (1u<<es_aborted))) {
            m->rst=1;m->ps_valid=0;m->tex_valid=0;m->pal_valid=0;m->frame_start=0;tick();tick();
            q.clear();texq.clear();palq.clear();tw_at.clear();lreq.clear();sp_gap=-1;
            m->rst=0;m->frame_start=1;tick();m->frame_start=0;es_aborted++;
        }
        // drive inputs for this cycle''',1)
s=s.replace('    res.timeout = !done;', '    if(es_abort_mode) { if(es_aborted!=3)throw std::runtime_error("RESET_WINDOW_COVERAGE");printf("PASS_ABORT_WINDOWS %u\\n",es_aborted); }\n    res.timeout = !done;',1)
s=s.replace('auto s=builtin_scenes();','for(int i=1;i<argc;i++)if(std::string(argv[i])=="+exercise_abort")es_abort_mode=true;auto s=builtin_scenes();',1)
s=s.replace('uint64_t clocks=0,spans=0;', 'if(es_abort_mode)s.resize(4);uint64_t clocks=0,spans=0;',1)
if args.scenes<71:s=s.replace('uint64_t clocks=0,spans=0;',f's.resize({args.scenes});uint64_t clocks=0,spans=0;')
(B/'main.cpp').write_text(s)
for n in ['scene.h','scenes.cpp','derive.cpp']:shutil.copyfile(O/n,B/n)
files=[B/n for n in libs+['gpu3d_front_records.sv','front_probe.sv','raster_probe.sv','gpu3d_edge_span.sv','tb.sv','main.cpp','scenes.cpp','derive.cpp']]
profile=json.loads((O/'snapshot.json').read_text())['profile'];run.put(B/'snapshot.json',dict(at=time.time(),source_parent='f0bec5c1; GPU exact Rootc10a40fd',profile=profile,scenes=args.scenes,candidate_ES2=0,candidate_EP_SCHED=0,candidate_FRPOOL=int(not args.default_off),original_snapshot_sha256=run.sha(O/'snapshot.json'),candidate_sources={str(p.relative_to(R)):run.sha(p)for p in (R/'rtl/gpu3d').glob('*.sv')if p.name in ['gpu3d_front_records.sv','gpu3d_edge_span.sv','gpu3d_front.sv','gpu3d_raster.sv']},inverse_mutations_exact=True,inputs={p.name:run.sha(p)for p in files+[B/'scene.h']}))
for p in files+[B/'scene.h']:p.chmod(0o444)
V='build/tools/oss-cad-suite/bin/verilator';cmd=[V,'--cc','--exe','--build','--no-timing','--assert','-j','1','--threads','1','-Wno-fatal','--compiler','clang','-CFLAGS','-std=c++20 -O1 -I'+str(B),'-MAKEFLAGS','CXX=clang++ VM_PARALLEL_BUILDS=1','--top-module','publication_tb','--Mdir',B/'obj',*['-G'+k+'='+str(v)for k,v in profile.items()],*files]
rc,t=run.worker(B,'build',cmd,build=True);assert rc==0,t[-6000:];run.put(B/'model.json',dict(sha256=run.sha(B/'obj/Vpublication_tb'),snapshot_sha256=run.sha(B/'snapshot.json')))
results={}
cases=[('positive',[],None),('reset-abort',['+exercise_abort'],None)]
if not args.default_off:cases += [('late-owner',['+wrong_late_owner'],'CONNECTED_PUBLICATION_FAIL'),('late-phase',['+wrong_late_phase'],'CONNECTED_PUBLICATION_FAIL'),('early-cursor',['+wrong_early_cursor'],'FRONT_RECORDS_FAIL params')]
for name,opts,needle in cases:
 rc,t=run.worker(B,name,[B/'obj/Vpublication_tb',*opts],seconds=600);good=(rc!=0 and needle in t)if needle else(rc==0 and'PASS_CONNECTED_PUBLICATION'in t and(name!='reset-abort' or t.count('PASS_ABORT_WINDOWS 3')==4));results[name]=dict(passed=good,exit=rc,tail=t.splitlines()[-6:]);
 if name=='positive':
  rows=[list(map(int,x))for x in re.findall(r'FRPOOL_COVERAGE dual(\d+) full(\d+) takeWrite(\d+) lateRight(\d+)',t)];assert len(rows)==args.scenes;coverage=list(map(sum,zip(*rows)));assert all(x>0 for x in coverage);run.put(B/'coverage.json',dict(zip(['simultaneous_early_late_writes','full_four_polygon_SYS','take_with_write','late_right_handover'],coverage)))
 run.put(B/'result.json',dict(result='IN_PROGRESS',cases=results));assert good,t[-6000:]
run.put(B/'result.json',dict(result=('PASS_DEFAULT_OFF_PUBLICATION_AND_ABORT'if args.default_off else'PASS_FRONT_RECORDS_PUBLICATION_AND_ACTUAL_FAULTS'),cases=results,remaining='Native MLAB/FAST and whole area/game gates are Root owned; no saving or physical acceptance.'));print('PASS_FRONT_RECORDS_PUBLICATION_AND_ACTUAL_FAULTS')
