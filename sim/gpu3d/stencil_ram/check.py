#!/usr/bin/env python3
"""Cycle/state equivalence of the actual private stencil RAM mapping, plus a real mutant.

One serial, single-threaded chain; all temporary models live in /tmp. The
existing scene/VRAM driver supplies identical traffic to three complete RTL
rasters: pinned before, candidate, and candidate with stencil write bit1
removed. No emulator is used as the equivalence oracle.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'build/raster-stencil50'
TMP = Path('/tmp/nds-raster-stencil50')
BASE = '00053c09e78e6d5393f67795ccb5506263aa8ade'
PROFILE = dict(TXD=9, PXD=9, VREG=1, LOV=1, EDIV4=1, SPO=1,
               EDGE2=1, EP2=1, FPSKIP=1, TRU=1, TRUL=1, FPCLR=1, LLR=1)


def digest(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def status(**kw):
    state.update(kw, updated=time.time())
    p = OUT / 'status.tmp'
    p.write_text(json.dumps(state, indent=2) + '\n')
    p.replace(OUT / 'status.json')


def run(cmd, label, expected_failure=False):
    status(phase=label, command=[str(x) for x in cmd])
    with (OUT / (label + '.log')).open('w') as f:
        p = subprocess.Popen([str(x) for x in cmd], cwd=ROOT,
                             stdout=f, stderr=subprocess.STDOUT,
                             preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
        status(child_pid=p.pid, child_starttime=Path(f'/proc/{p.pid}/stat').read_text().split()[21])
        rc = p.wait()
    status(child_pid=None, child_starttime=None)
    if expected_failure:
        assert rc != 0 and 'MUTANT_CAUGHT' in (OUT / (label + '.log')).read_text()
        status(**{label + '_result': dict(returncode=rc, verdict='CAUGHT_ACTUAL_STENCIL_BIT1_WRITE_REMOVAL')})
    elif rc:
        raise RuntimeError(f'{label} exited {rc}')


def prepare():
    before = subprocess.check_output(['git', 'show', BASE + ':rtl/gpu3d/gpu3d_raster.sv'], cwd=ROOT).decode()
    after = (ROOT / 'rtl/gpu3d/gpu3d_raster.sv').read_text()
    mutant = after.replace('.wdata(st_wdata),', ".wdata(st_wdata & 2'b01),", 1)
    assert mutant != after
    header = after[:after.index('\n);') + 3]
    clean = re.sub(r'//[^\n]*', '', header)
    params = re.findall(r'parameter\s+(?:bit|int)\s+(\w+)\s*=', clean)
    ports = re.findall(r'\b(input|output)\s+logic\s*(\[[^\]]+\])?\s*(\w+)', clean)
    assert len(params) > 35 and len(ports) > 35
    decl = []
    inst = []
    for kind in ('before', 'after', 'mutant'):
        p = TMP / (kind + '.sv')
        p.write_text(dict(before=before, after=after, mutant=mutant)[kind].replace('module gpu3d_raster #(', 'module raster_' + kind + ' #(', 1))
        for direction, width, name in ports:
            if direction == 'output' and kind != 'after':
                decl.append(f'wire {width} {kind}_{name};')
        connects = ', '.join(f'.{name}({kind + "_" if direction == "output" and kind != "after" else ""}{name})' for direction, width, name in ports)
        inst.append(f'raster_{kind} #(' + ', '.join(f'.{p}({p})' for p in params) + f') u_{kind} ({connects});')
    header = header[:-3] + ',\n output logic [63:0] eq_clocks, eq_spans, eq_pixels, mutant_witnesses\n);'
    checks = []
    for direction, width, name in ports:
        if direction == 'output':
            checks.append(f'if ({name} !== before_{name}) $fatal(1, "port mismatch {name}");')
    checks += [
        'if (u_before.tg !== u_after.tg || u_before.tsl !== u_after.tsl) $fatal(1, "pixel tag/slot mismatch");',
        'if (u_before.sd_cur !== u_after.sd_cur || u_before.sd_nx !== u_after.sd_nx) $fatal(1, "setup descriptor mismatch");',
        'if (u_before.adv !== u_after.adv || u_before.sd_load !== u_after.sd_load) $fatal(1, "advance/setup event mismatch");',
        'if (u_before.T13.v && (u_before.p13_av !== u_after.p13_av || u_before.p13_z !== u_after.p13_z || u_before.tv13 !== u_after.tv13)) $fatal(1, "attribute/depth state mismatch");',
        'if (u_before.st_rdata !== u_after.st_rdata) $fatal(1, "stencil registered read mismatch");',
        'if (u_before.st_we !== u_after.st_we || u_before.st_waddr !== u_after.st_waddr || u_before.st_wdata !== u_after.st_wdata) $fatal(1, "stencil write event/data mismatch");',
        'if (u_before.T21.v && (u_before.dt_pass !== u_after.dt_pass || u_before.dt_bot !== u_after.dt_bot || u_before.dt_attr !== u_after.dt_attr || u_before.dt_sv !== u_after.dt_sv)) $fatal(1, "P21 depth/stencil state mismatch");',
        'if (frame_done && u_before.u_stencil.mem !== u_after.u_stencil.mem) $fatal(1, "complete stencil state mismatch");',
        'if (test_mutant && u_before.T21.v && u_before.d21.attr[5:4] == 2\'d3 && u_before.st_rdata !== u_mutant.st_rdata) $fatal(1, "MUTANT_CAUGHT actual stencil bit1 write removed");',
    ]
    body = '\n'.join(decl + inst) + '''
bit test_mutant;
initial test_mutant = $test$plusargs("mutant");
always @(negedge clk) begin
  if (rst) begin eq_clocks<=0; eq_spans<=0; eq_pixels<=0; mutant_witnesses<=0; end
  else begin
    eq_clocks<=eq_clocks+1;
    eq_spans<=eq_spans+64'(u_before.sd_load);
    eq_pixels<=eq_pixels+64'(u_before.adv && u_before.T13.v);
    if (u_before.T21.v && u_before.d21.attr[5:4] == 2'd3 && u_before.st_rdata !== u_mutant.st_rdata) mutant_witnesses<=mutant_witnesses+1;
''' + '\n'.join(checks) + '\n end\nend\nendmodule\n'
    (TMP / 'equiv.sv').write_text(header + '\n' + body)
    driver = (ROOT / 'sim/gpu3d/tb_gpu3d.cpp').read_text().split('int main(')[0]
    # Observe counters before render_rtl destroys its model.
    driver = driver.replace('m->final();', 'm->clk=0; m->eval(); printf("COUNTS %s %llu %llu %llu %llu\\n", sc.name.c_str(), (unsigned long long)m->eq_clocks, (unsigned long long)m->eq_spans, (unsigned long long)m->eq_pixels, (unsigned long long)m->mutant_witnesses); m->final();')
    driver += '''
int main(int argc, char** argv) {
 Verilated::commandArgs(argc, argv);
 auto scenes=builtin_scenes();
 for (unsigned i=0;i<24;i++) scenes.push_back(random_mix_scene(0x49c01000u+i));
 auto extreme=scenes.front(); extreme.name="colour_extremes"; extreme.polys.clear();
 for (unsigned i=0;i<16;i++) {
  Poly p; p.attr=0x001f0000u|(i<<24); if (i&1) p.attr|=0x20;
  p.wbuffer=i&2; p.facing=i&4;
  p.v={{0,int(i*10),0x100000,0x1000,0,511,0,-32768,32767},
       {255,int(i*10+1),0x300000,(i&8)?0x1234u:0x1000u,511,0,511,32767,-32768},
       {128,int(i*10+30),0x200000,0x1000,511,511,511,0,0}};
  extreme.polys.push_back(p);
 }
 scenes.push_back(extreme);
 {
  const std::vector<std::vector<std::pair<int,int>>> shapes={
   {{0,0},{511,0},{0,192}}, {{0,0},{511,191},{0,192}},
   {{0,0},{511,0},{511,192},{0,192}},
   {{255,0},{256,0},{256,192},{255,192}},
   {{0,191},{511,191},{511,192},{0,192}},
   {{0,0},{0,0},{511,0},{511,192},{0,192}},
   {{0,0},{511,0},{511,64},{511,128},{384,192},{256,192},{128,192},{0,128},{0,64},{0,0}},
   {{256,0},{511,0},{511,192},{256,192}}
  };
  const uint32_t ws[4][3]={{0x1000,0x1000,0x1000},{1,65535,32768},{0,65535,1},{65535,65535,65535}};
  for (unsigned s=0;s<shapes.size();s++) for (unsigned w=0;w<4;w++) {
   Scene sc; sc.name="clip_setup_"+std::to_string(s)+"_w"+std::to_string(w);
   sc.dispcnt=1|(1<<1)|(1<<3)|(1<<4)|(1<<5); sc.clear_attr1=0x3f000000;
   for (unsigned mode=0;mode<4;mode++) for (unsigned wb=0;wb<2;wb++) {
    Poly p; p.attr=0x001f0000|(mode<<4)|((mode+1)<<24); p.wbuffer=wb; p.w_shifted_out=w==2;
    for (unsigned j=0;j<shapes[s].size();j++) {
     auto [x,y]=shapes[s][j];
     p.v.push_back({x,y,0xffffffu-j*0x10000u,ws[w][j%3],(j&1)?511:0,(j&1)?0:511,511,(int16_t)((j&1)?32767:-32768),(int16_t)((j&1)?-32768:32767)});
    }
    sc.polys.push_back(p);
   }
   scenes.push_back(sc);
  }
 }
 if (argc>1 && std::string(argv[1])=="+mutant") {
  std::vector<Scene> selected;
  for (auto& sc:scenes) if (sc.name=="shadow_layers") selected.push_back(sc);
  if (selected.size()!=1) return 3; scenes=std::move(selected);
 }
 for (size_t i=0;i<scenes.size();i++) {
  auto r=render_rtl(scenes[i], (i%2)?23:0, false, 0x49u+i);
  if (r.timeout) return 2;
  printf("PASS %s cycles=%llu\\n", scenes[i].name.c_str(),(unsigned long long)r.cycles); fflush(stdout);
 }
 printf("PASS_EQUIVALENCE scenes=%zu\\n",scenes.size()); return 0;
}
'''
    (TMP / 'driver.cpp').write_text(driver)
    golden = (ROOT / 'sim/gpu3d/golden.cpp').read_text()
    derive = golden[golden.index('PolyDerived derive('):golden.index('\n}\nnamespace melonDS')]
    (TMP / 'derive.cpp').write_text('#include "scene.h"\nnamespace g3d {\n' + derive + '\n}\n')
    status(inputs={str(p.relative_to(ROOT)): digest(p) for p in [Path(__file__), ROOT/'rtl/gpu3d/gpu3d_raster.sv', ROOT/'sim/gpu3d/tb_gpu3d.cpp', ROOT/'sim/gpu3d/scenes.cpp',
           *[ROOT/'rtl/gpu3d'/n for n in ('gpu3d_pkg.sv','gpu3d_div4.sv','gpu3d_ram.sv','gpu3d_edge.sv','gpu3d_front.sv','gpu3d_fpass.sv')], ROOT/'sim/gpu3d/stencil_ram/tb.sv', ROOT/'sim/gpu3d/stencil_ram/main.cpp']},
           generated={p.name:digest(p) for p in TMP.glob('*') if p.is_file()}, profile=PROFILE)


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    state = dict(source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT).decode().strip(), base=BASE,
                 host=os.uname().nodename, controller_pid=os.getpid(), controller_starttime=Path('/proc/self/stat').read_text().split()[21], NI=os.nice(0), jobs=1, threads=1)
    try:
        run(['python3','tools/ds/qlint.py','rtl/gpu3d/gpu3d_raster.sv'], 'qlint')
        prepare()
        unit_obj=TMP/'obj_unit'
        run(['verilator','--cc','--exe','--build','-j','1','--threads','1',
             '-Wno-fatal','--Mdir',unit_obj,'--top-module','tb_stencil_ram',
             ROOT/'rtl/gpu3d/gpu3d_ram.sv',ROOT/'sim/gpu3d/stencil_ram/tb.sv',
             ROOT/'sim/gpu3d/stencil_ram/main.cpp'],'unit_build')
        unit_binary=unit_obj/'Vtb_stencil_ram'
        run([unit_binary],'unit_equivalence')
        run([unit_binary,'+mutant'],'unit_actual_mutant',expected_failure=True)
        shutil.copy2(unit_binary,OUT/'Vtb_stencil_ram')
        assert digest(OUT/'Vtb_stencil_ram')==digest(unit_binary)
        status(unit_model_sha256=digest(unit_binary))
        shutil.rmtree(unit_obj)
        for profile, opts in [('root', PROFILE), ('default', {})]:
            obj = TMP / ('obj_' + profile)
            cmd = ['verilator','--cc','--exe','--build','-j','1','--threads','1','-O2','--assert',
                   '--x-assign','fast','--x-initial','fast','-Wno-fatal','--Mdir',obj,'--top-module','gpu3d_raster',
                   '-CFLAGS','-std=c++20 -O1 -I' + str(ROOT/'sim/gpu3d')]
            cmd += ['-G'+k+'='+str(v) for k,v in opts.items()]
            cmd += [ROOT/'rtl/gpu3d'/p for p in ['gpu3d_pkg.sv','gpu3d_div4.sv','gpu3d_ram.sv','gpu3d_edge.sv','gpu3d_front.sv','gpu3d_fpass.sv']]
            cmd += [TMP/p for p in ['before.sv','after.sv','mutant.sv','equiv.sv','driver.cpp','derive.cpp']]
            cmd += [ROOT/'sim/gpu3d/scenes.cpp']
            t0=time.time(); run(cmd,profile+'_build'); status(**{profile+'_build_seconds':time.time()-t0})
            binary=obj/'Vgpu3d_raster'
            run([binary], profile+'_equivalence')
            counts=[]
            for line in (OUT/(profile+'_equivalence.log')).read_text().splitlines():
                if line.startswith('COUNTS '):
                    parts=line.split();counts.append(dict(scene=parts[1],clocks=int(parts[2]),spans=int(parts[3]),pixels=int(parts[4]),mutant_witnesses=int(parts[5])))
            assert len(counts)==120 and sum(c['mutant_witnesses'] for c in counts)>0
            status(**{profile+'_result':dict(verdict='PASS',scenes=len(counts),totals={k:sum(c[k] for c in counts) for k in ('clocks','spans','pixels','mutant_witnesses')},model_sha256=digest(binary),counts=counts)})
            run([binary, '+mutant'], profile+'_actual_mutant', expected_failure=True)
            shutil.copy2(binary, OUT/('Vgpu3d_raster_'+profile))
            assert digest(OUT/('Vgpu3d_raster_'+profile)) == digest(binary)
            shutil.rmtree(obj)
        for p in TMP.glob('*'):
            if p.is_file(): shutil.copy2(p,OUT/p.name)
        status(phase='PASS',child_pid=None)
    except BaseException as e:
        status(phase='FAIL',error=repr(e))
        raise
