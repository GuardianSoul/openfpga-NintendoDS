#!/usr/bin/env python3
"""Audit run38 captures and prepare a pinned 2D fixture; never build or run it."""
import argparse
import array
import csv
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import sys
ROOT=Path(__file__).resolve().parents[2]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def stamp(p,x):p.write_text(json.dumps(x,indent=2,sort_keys=True)+'\n')
def pixels(p):
    a=array.array('H');a.frombytes(p.read_bytes())
    if sys.byteorder!='little':a.byteswap()
    if len(a)!=256*192:raise ValueError('wrong raw length '+str(p))
    return a

def audit(ds,ref):
    ds=Path(ds);ref=Path(ref);rows=[];targets=[]
    for load in range(3):
        base=(ds/f'load2d_{load}_0_0_f0.bin').read_bytes()
        for b in range(2):
            for stress in range(2):
                for rep in range(2):
                    name=f'load2d_{load}_{b}_{stress}_f{rep}.bin';a=pixels(ds/name);c=pixels(ref/name)
                    diff=[i for i,(x,y) in enumerate(zip(a,c)) if x!=y]
                    rows.append(dict(file=name,load=load,engine_b=b,stress=stress,rep=rep,ds_sha256=sha(ds/name),census_sha256=sha(ref/name),
                                     ds_matches_same_load_control=(ds/name).read_bytes()==base,different_pixels=len(diff),
                                     different_coordinates=[[i%256,i//256] for i in diff]))
                    if load==2:targets.append(set(diff))
    if not all(r['ds_matches_same_load_control'] for r in rows):raise ValueError('unexpected condition dependence')
    background=pixels(ds/'load2d_1_0_0_f0.bin');d=pixels(ds/'load2d_2_0_0_f0.bin');c=pixels(ref/'load2d_2_0_0_f0.bin')
    target=targets[0]
    if any(t!=target for t in targets):raise ValueError('different load2 masks')
    prefix_masks={n:set() for n in range(1,129)}
    allmask=set()
    for y in range(192):
        active=[i for i in range(128) if ((y-(i%6)*32)&255)<64]
        mask=0;prefix=[]
        for i in active:
            x=(i*17)&255;mask|=((1<<min(64,256-x))-1)<<x;prefix.append(mask)
        allmask.update(y*256+x for x in range(256) if mask>>x&1)
        for n in prefix_masks:
            missed=mask^(prefix[min(n,len(prefix))-1] if prefix else 0)
            prefix_masks[n].update(y*256+x for x in range(256) if missed>>x&1)
    composed=[0x803f if i in allmask else background[i] for i in range(49152)]
    return dict(captures=rows,unlimited_uniform_OBJ_composition_vs_census_pixels=sum(a!=b for a,b in zip(composed,c)),
                ds_missing_pixels_equal_BG=all(d[i]==background[i] and c[i]==0x803f for i in target),
                prefix_count_hypotheses_matching_mask=[n for n,m in prefix_masks.items() if m==target],
                inference='geometric mask ambiguity only; no count/cycle limit or general clipping rule established')


def prepare(out,source,ds,qualification):
    if out.exists():raise ValueError('output exists; preserve evidence')
    q=json.loads(qualification.read_text());ref=qualification.parent/'sd/hwref/trip20261031'
    if q['exit']!=0:raise ValueError('reference did not qualify')
    binary=Path(q['command'][0])
    if sha(binary)!=q['census_sha256']:raise ValueError('qualified Census binary changed')
    pin=subprocess.check_output(['git','-C',str(ROOT),'rev-parse',source],text=True).strip()
    out.mkdir(parents=True);(out/'captures').mkdir();shutil.copy2(__file__,out/'preparer.py');src=out/'source';src.mkdir()
    data=subprocess.check_output(['git','-C',str(ROOT),'archive',pin,'rtl/gpu2d','rtl/ds/nds_ram.sv','sim/gpu2d'])
    with tarfile.open(fileobj=io.BytesIO(data)) as t:t.extractall(src,filter='data')
    probe=src/'probe/sw/hwref/load2d/main.c';probe.parent.mkdir(parents=True)
    probe.write_bytes(subprocess.check_output(['git','-C',str(ROOT),'show',q['source_sha']+':sw/hwref/load2d/main.c']))
    if sha(probe)!=q['source_sha256']['sw/hwref/load2d/main.c']:raise ValueError('qualified probe source changed')
    probe_rom=Path(q['command'][q['command'].index('--rom')+1])
    if sha(probe_rom)!=q['rom_sha256']:raise ValueError('qualified ROM changed')
    for kind,base in [('ds',ds),('census',ref)]:
        dest=out/kind;dest.mkdir()
        for f in base.glob('load2d*'):
            if f.is_file():shutil.copy2(f,dest/f.name)
    for f in (out/'census').glob('*.bin'):
        if sha(f)!=q['output_sha256']['hwref/trip20261031/'+f.name]:raise ValueError('qualified capture changed '+f.name)
    rows=list(csv.DictReader((out/'ds/load2d.csv').open()))
    keys={(int(r['load']),int(r['engine_b']),int(r['stress']),int(r['rep'])) for r in rows}
    if len(rows)!=24 or keys!={(l,b,s,r) for l in range(3) for b in range(2) for s in range(2) for r in range(2)} or any(int(r['timeout']) or int(r['dma_busy']) for r in rows):raise ValueError('incomplete or failing DS matrix')
    report=audit(out/'ds',out/'census');stamp(out/'audit.json',report)
    fixture=src/'sim/gpu2d/load2d_run38.cpp';shutil.copy2(ROOT/'sim/gpu2d/load2d_run38.cpp',fixture)
    tb=src/'sim/gpu2d/tb_gpu2d.cpp';text=tb.read_text()
    old='    int firstbad = -1;'
    assert text.count(old)==1
    text=text.replace(old,old+'''\n    std::vector<u16> raw_rtl(49152),raw_gold(49152);
    std::vector<unsigned> seen_rtl(49152),seen_gold(49152);''')
    old='        st.capw += go.cap.size();';assert text.count(old)==1
    text=text.replace(old,'''        for(const auto& c:rtl.cap) if((c.addr>>16)==3 && (c.addr&65535)<49152) { raw_rtl[c.addr&65535]=c.data;seen_rtl[c.addr&65535]++; }
        for(const auto& c:go.cap) if((c.addr>>16)==3 && (c.addr&65535)<49152) { raw_gold[c.addr&65535]=c.data;seen_gold[c.addr&65535]++; }
'''+old)
    old='    bool ok = st.bad == 0 && st.capbad == 0;';assert text.count(old)==1
    text=text.replace(old,'''    if(const char* dir=getenv("RUN38_OUT")) {
        unsigned good_rtl=0,good_gold=0;
        for(unsigned i=0;i<49152;i++){good_rtl+=seen_rtl[i]==1;good_gold+=seen_gold[i]==1;}
        printf("RUN38_CAPTURE name=%s rtl_unique=%u gold_unique=%u\\n",seg.name.c_str(),good_rtl,good_gold);
        for(int kind=0;kind<2;kind++) {
            std::string file=std::string(dir)+"/"+seg.name+(kind?"-gold.bin":"-rtl.bin");
            FILE* f=fopen(file.c_str(),"wb");if(!f){perror(file.c_str());exit(4);}
            const auto& raw=kind?raw_gold:raw_rtl;
            if(fwrite(raw.data(),sizeof(u16),raw.size(),f)!=raw.size()){fclose(f);exit(4);}fclose(f);
        }
    }
'''+old);tb.write_text(text)
    # The DS-rule renderer samples DISPCNT in GPU.cpp's scanline callback.
    # This standalone register sequencer must provide that same latch event.
    seq=src/'sim/gpu2d/golden2d.cpp';seqtext=seq.read_text()
    for anchor in ['    p->gpu.VCount = 262;', '    p->gpu.VCount = y;']:
        if seqtext.count(anchor)!=1:raise ValueError('sequencer latch anchor changed')
        seqtext=seqtext.replace(anchor,anchor+'\n    p->a.DsDispCntLine = p->a.DispCnt; p->b.DsDispCntLine = p->b.DispCnt;')
    seq.write_text(seqtext)
    gold=out/'golden';gold.mkdir()
    census_source=binary.parents[1]/'melonDS/src'
    for name in ['GPU2D.cpp','GPU2D.h','GPU2D_Soft.cpp','GPU2D_Soft.h','GPU_ColorOp.h','types.h','Census.h']:shutil.copy2(census_source/name,gold/name)
    provenance=json.loads((binary.parents[1]/'provenance.json').read_text())
    for p in gold.iterdir():
        if sha(p)!=provenance['fresh_source_file_sha256']['src/'+p.name]:raise ValueError('Census19 renderer source changed: '+p.name)
    # Retain qualified instrumented renderer bytes. Its optional Census index
    # wrappers need their real header plus null hooks in this standalone harness.
    (gold/'CensusHooks.cpp').write_text('#include "Census.h"\nnamespace melonDS::Census { Hooks* Active = nullptr; }\n')
    flags=provenance['declared_rules']
    rtl=['gpu2d/gpu2d_pkg.sv','ds/nds_ram.sv','gpu2d/gpu2d_ram.sv','gpu2d/gpu2d_cache.sv','gpu2d/gpu2d_bg.sv','gpu2d/gpu2d_obj.sv','gpu2d/gpu2d.sv']
    cpp=[src/'sim/gpu2d'/p for p in ['tb_gpu2d.cpp','golden2d.cpp','load2d_run38.cpp','dump2d.cpp']]+[gold/'GPU2D.cpp',gold/'GPU2D_Soft.cpp',gold/'CensusHooks.cpp']
    inc=[src/'sim/gpu2d',src/'sim/gpu2d/melonds_shim',gold]
    cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','-O3',
         '--threads','1','--x-assign','fast','--x-initial','fast','-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-UNUSEDSIGNAL',
         '--top-module','gpu2d','--Mdir',str(out/'obj'),'-GPERSIST=1','-GOAM_CPU=1','-GTEX_IDXW=7','-GTAG_MLAB=1',
         '-CFLAGS','-std=c++20 -O2 -fwrapv -include '+str(gold/'Census.h')+' '+' '.join('-I'+str(p) for p in inc)+' '+' '.join('-D'+f for f in flags),
         *[str(src/'rtl'/p) for p in rtl],*[str(p) for p in cpp]]
    m=dict(core_source_sha=pin,probe_source_sha=q['source_sha'],probe_source_sha256=sha(probe),generator_sha256=sha(__file__),preparer_snapshot_sha256=sha(out/'preparer.py'),build_jobs=1,threads=1,build_command=cmd,
           run_command=[str(out/'obj/Vgpu2d'),'--scenes','--lat','13','--dcyc','16','--maxq','2'],
           run_environment={'RUN38_OUT':str(out/'captures')},
           source_sha256={str(p.relative_to(src)):sha(p) for p in src.rglob('*') if p.is_file()},
           golden_sha256={p.name:sha(p) for p in gold.iterdir()},ds_sha256={p.name:sha(p) for p in (out/'ds').iterdir()},
           census_sha256={p.name:sha(p) for p in (out/'census').iterdir()},census_binary_sha256=q['census_sha256'],qualification_path=str(qualification),qualification_sha256=sha(qualification),
           probe_rom_sha256=sha(Path(q['command'][q['command'].index('--rom')+1])),
           status='prepared only; native build/run requires coordinator worker; no core fix or budget rule',
           scope='stable six load/sub-engine state fixtures,192 lines; does not emulate CPU/DMA stress or nds_disp scheduling',
           acceptance='all gold captures must equal qualified Census19 raw captures before drawing a core-versus-DS conclusion; then compare all raw16 bits with every DS condition; observed mismatch remains data, not a generic budget rule')
    stamp(out/'plan.json',m);return m

def compare(out,log):
    out=Path(out);m=json.loads((out/'plan.json').read_text());text=Path(log).read_text()
    for directory,key in [('source','source_sha256'),('golden','golden_sha256'),('ds','ds_sha256'),('census','census_sha256')]:
        for name,h in m[key].items():
            if sha(out/directory/name)!=h:raise ValueError('input changed: '+directory+'/'+name)
    import re
    if re.search(r'(?i)timeout|%Error|%Fatal',text) or not re.search(r'(?:PASS|FAIL): [0-6]/6 runs pixel-exact, 1152 lines,',text):
        raise ValueError('incomplete/failing native fixture')
    capture=re.findall(r'RUN38_CAPTURE name=(\S+) rtl_unique=(\d+) gold_unique=(\d+)',text)
    names={f'run38-load{l}-b{b}' for l in range(3) for b in range(2)}
    if len(capture)!=6 or {n for n,_,_ in capture}!=names or any(int(a)!=49152 or int(b)!=49152 for _,a,b in capture):
        raise ValueError('missing/duplicate capture writes')
    rows=[];reference_ok=True
    for load in range(3):
        for b in range(2):
            stem=f'run38-load{load}-b{b}';rpath=out/'captures'/(stem+'-rtl.bin');gpath=out/'captures'/(stem+'-gold.bin')
            r,g=pixels(rpath),pixels(gpath)
            for stress in range(2):
                for rep in range(2):
                    name=f'load2d_{load}_{b}_{stress}_f{rep}.bin';ds=pixels(out/'ds'/name);c=pixels(out/'census'/name)
                    count=lambda a,b:sum(x!=y for x,y in zip(a,b))
                    gc=count(g,c);reference_ok &= gc==0
                    rows.append(dict(capture=name,fixture_gold_vs_Census19_pixels=gc,core_vs_DS_pixels=count(r,ds),core_vs_Census19_pixels=count(r,c),
                                     core_capture_sha256=sha(rpath),fixture_gold_sha256=sha(gpath)))
    result=dict(core_source_sha=m['core_source_sha'],plan_sha256=sha(out/'plan.json'),native_log_sha256=sha(log),model_sha256=sha(out/'obj/Vgpu2d'),
                fixture_reference_valid=reference_ok,core_matches_DS=reference_ok and all(r['core_vs_DS_pixels']==0 for r in rows),comparisons=rows,
                scope=m['scope'],claim='captured stable scene only; no inferred general OBJ count/cycle budget and no full-system contention proof')
    stamp(out/'core-comparison.json',result)
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--compare-log',type=Path);p.add_argument('--source',default='12e1c032')
    p.add_argument('--ds',type=Path,default=Path('/home/user/Git/NDS_Pocket/build/hwref-return-20261031/trip20261031'))
    p.add_argument('--qualification',type=Path,default=Path('/home/user/Git/NDS_Pocket-codex-hwref/build/hwref-trip20261031/preflight/load2d-final/qualification.json'))
    a=p.parse_args()
    if a.compare_log:
        r=compare(a.out.resolve(),a.compare_log);print('fixture reference valid',r['fixture_reference_valid'],'core matches DS',r['core_matches_DS']);sys.exit(0 if r['core_matches_DS'] else 1 if r['fixture_reference_valid'] else 2)
    m=prepare(a.out.resolve(),a.source,a.ds,a.qualification);print('prepared',m['core_source_sha'],'no build/run')
