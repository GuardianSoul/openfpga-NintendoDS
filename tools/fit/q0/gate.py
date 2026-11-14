#!/usr/bin/env python3
"""Collect or verify post-fit Q0 timing/mapping. Missing evidence fails closed."""
import argparse,csv,hashlib,json,math,re,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from resources import table,number
H=lambda b:hashlib.sha256(b).hexdigest()
class GateError(Exception):pass
def need(x,msg):
 if not x:raise GateError(msg)
def rows(p):
 need(p.is_file(),f'missing {p.name}')
 return list(csv.reader(p.read_text().splitlines(),delimiter='\t'))
def new(n):return 'gpu3d_factor_pump:'in n or 'q0_fast_'in n or 'q0_sys_'in n
def scalar(s):
 x=float(s);need(math.isfinite(x),'nonfinite measurement');return x
def empty_exceptions(text):
 # Never infer absence from an empty/unknown/truncated report.
 need(not re.search(r'\bset_(?:false_path|multicycle_path|max_delay|min_delay|clock_groups|data_delay)\b',text),'applied exception touches Q0')
 need(bool(re.search(r'(?:\bno (?:timing )?(?:exceptions|paths) (?:were )?found\b|\bfound 0 (?:timing )?exceptions\b|\bnumber of exceptions\s*[:;]\s*0\b)',text,re.I)),'exception report lacks explicit zero-exception result')
def mapping(fit,mapping_text):
 need(bool(re.search(r'^;\s*Fitter Status\s*;\s*Successful',fit,re.M)),'fitter not successful: no physical/STA qualification')
 entities=table(fit,'Fitter Resource Utilization by Entity','Compilation Hierarchy Node')
 factors=[r for r in entities if 'gpu3d_factor_pump:'in r.get('Full Hierarchy Name','')]
 need(len(factors)==1,'missing/ambiguous factor entity mapping')
 for r in factors:
  need(number(r.get('DSP Blocks',''))==0,'factor mapped to DSP')
  need(number(r.get('Block Memory Bits',''))==0,'factor mapped to block memory')
 rams=table(fit,'Fitter RAM Summary','Name');need(rams,'missing physical RAM table')
 need(not any(new(r['Name']) for r in rams),'Q0 RAM unexpectedly present')
 need(not any('u_raster' in r['Name'] and 'u_frecip'in r['Name']for r in rams),'old raster reciprocal ROM still present')
 dsps=table(fit,'Fitter DSP Block Usage Summary','Statistic');need(dsps,'missing actual DSP modes')
 fit_total=next((number(r['Number Used'])for r in dsps if r['Statistic']=='Total number of DSP blocks'),None)
 need(fit_total is not None,'missing actual DSP total')
 syn=re.findall(r'^;\s*Total DSP Blocks\s*;\s*([\d,]+)\s*;',mapping_text,re.M);need(syn,'missing synthesis DSP evidence')
 return {'factor_entity':factors,'raster_RAM_rows':[r for r in rams if 'u_raster'in r['Name']], 'fitter_DSP_modes':dsps,'actual_DSP_total':fit_total,'synthesis_DSP_totals':sorted(set(int(x.replace(',',''))for x in syn))}
def evaluate(out,allow_mock=False):
 manifest=json.loads((out/'manifest.json').read_text());origin=manifest['origin']
 need(origin=='live-quartus-sta'or(allow_mock and origin=='mock'),'not live Quartus evidence')
 need(manifest['collector_exit']==0,'collector failed')
 need(re.fullmatch(r'[0-9a-f]{40}',manifest['source'])is not None,'unpinned source')
 actual_files={str(p.relative_to(out))for p in out.rglob('*')if p.is_file()and p.name not in ['manifest.json','verdict.json']}
 need(actual_files==set(manifest['files']),'manifest file set differs')
 for name,row in manifest['files'].items():
  p=out/name;need(p.is_file()and H(p.read_bytes())==row['SHA256'],f'changed/missing evidence: {name}')
 need((out/'complete.txt').read_text().strip()=='Q0_COLLECTION_COMPLETE','incomplete collection')
 need(manifest.get('source_bindings'),'source bindings absent')
 if origin=='live-quartus-sta':
  required={'rtl/gpu3d/gpu3d_factor_pump.sv','rtl/gpu3d/gpu3d_raster.sv','rtl/ds/nds_gpu3d.sv'}
  need(required<=set(manifest['source_bindings']),'incomplete live source bindings')
  need(all(re.fullmatch(r'[0-9a-f]{64}',h)for h in manifest['source_bindings'].values()),'invalid live source hashes')
  need((out/'collector.tcl').read_bytes()==Path(__file__).with_name('collect.tcl').read_bytes(),'collector implementation changed')
  need((out/'standard_clock.tcl').read_bytes()==Path(__file__).with_name('standard_clock.tcl').read_bytes(),'clock lookup implementation changed')
  for n in ['sta.rpt','project.qsf','project.sdc','collector.log']:need((out/n).is_file()and(out/n).stat().st_size>0,f'missing live provenance: {n}')
 inv=rows(out/'inventory.tsv');clocks={r[1]:scalar(r[2])for r in inv if r[0]=='clock'}
 need(len(clocks)==2,'clock inventory incomplete')
 sysclock=next((n for n in clocks if 'general[5]'in n),None);fast=next((n for n in clocks if 'general[7]'in n),None)
 need(sysclock and fast,'wrong SYS/FAST clocks');fp=clocks[fast];sp=clocks[sysclock]
 # 2ps covers independently rounded 1ps report fields, not timing margin.
 resolution=0.002
 need(0<fp<=1000/134 and abs(sp-2*fp)<=resolution,'clock rate/phase family changed')
 regs={}
 for r in inv:
  if r[0]!='register':continue
  need(len(r)==4 and r[3]in ['0','1'],'invalid register row')
  n,c,flag=r[1:];need(bool(int(flag))==new(n),'new endpoint misclassified');regs.setdefault(n,set()).add(c)
 nr={n:cs for n,cs in regs.items()if new(n)};legacy={n for n,cs in regs.items()if fast in cs and not new(n)}
 need(nr and legacy,'empty new/legacy inventory')
 ends=[r for r in inv if r[0]=='inventory_end'];need(ends==[['inventory_end',str(len(nr)),str(len(legacy))]],'incomplete inventory closure')
 fanins={r[1]:int(r[2])for r in inv if r[0]=='fanin_count'}
 need(set(fanins)==set(nr)|legacy,'incomplete fanin count inventory')
 for n,cs in nr.items():need(len(cs)==1 and next(iter(cs))in clocks,'unclocked/ambiguous Q0 endpoint')
 for stem in ['q0_fast_seen','q0_fast_phase','q0_fast_run','q0_sys_toggle','q0_sys_q']:
  need(any(stem in n for n in nr),f'missing mapped family {stem}')
 for stem in ['rem','den','q']:
  for stage in range(4):need(any(f'q0_fast_{stem}[{stage}]'in n for n in nr),f'missing stage {stem}{stage}')
 for stage in range(4):need(any(f'q0_sys_q[{stage}]'in n for n in nr),f'missing SYS quotient stage{stage}')
 arcs={};destinations=set();families=set()
 for r in rows(out/'arcs.tsv'):
  need(len(r)==6,'bad arc row');id,kind,src,dst,sc,dc=r
  need(id not in arcs and kind in ['new','legacy'],'duplicate/invalid arc')
  need(src in regs and dst in regs and regs[src]=={sc}and regs[dst]=={dc},'arc not in complete register inventory')
  need((kind=='new'and dst in nr)or(kind=='legacy'and dst in legacy and sc==sysclock),'wrong arc scope')
  arcs[id]=(kind,src,dst,sc,dc);destinations.add(dst)
  if kind=='new':families.add((sc,dc))
 need(set(nr)<=destinations,'new endpoints missing fanin checks')
 need(any(a[0]=='legacy'for a in arcs.values()),'no reachable legacy MCP evidence')
 for n,count in fanins.items():need(sum(a[2]==n for a in arcs.values())==count,f'incomplete fanin arcs for {n}')
 need({(sysclock,fast),(fast,sysclock),(fast,fast)}<=families,'missing SYS/FAST service arc family')
 data=rows(out/'paths.tsv');corners=[r[1]for r in data if r[0]=='corner']
 need(len(corners)==len(set(corners))and any('fast'in c.lower()for c in corners)and any('slow'in c.lower()for c in corners),'missing fast/slow corners')
 coverage={};observed={};worst={}
 for r in data:
  if r[0]=='corner':continue
  if r[0]=='coverage':
   need(len(r)==6,'bad coverage row');_,c,id,t,n,cut=r;k=(c,id,t)
   need(k not in coverage and id in arcs and c in corners and t in ['setup','hold'],'duplicate/unexpected coverage')
   need(n=='1'and cut=='0',f'missing/false-pathed arc {k}');coverage[k]=1
  elif r[0]=='path':
   need(len(r)==15,'bad path row');_,c,id,t,src,dst,sc,dc,actual,slack,rel,ss,se,hs,he=r;k=(c,id,t)
   need(k not in observed and id in arcs and c in corners,'duplicate/unexpected path')
   kind,es,ed,ec,et=arcs[id];need((src,dst,sc,dc)==(es,ed,ec,et),'timed path endpoints/clocks mismatch')
   need(actual==t and t in ['setup','hold'],'max/min delay substituted for setup/hold')
   slack=scalar(slack);rel=scalar(rel);need(slack>=0,f'negative {t} slack {k}: {slack}')
   expected=(0,2,0,1)if kind=='legacy'else(0,1,0,0)
   need(tuple(map(int,[ss,se,hs,he]))==expected,f'applied MCP changed {k}')
   expected_rel=0 if t=='hold'else(sp if kind=='legacy'or(sc==sysclock and dc==sysclock)else fp)
   need(abs(rel-expected_rel)<=resolution,f'wrong {t} relationship {k}: {rel} expected {expected_rel}')
   observed[k]=1;wk=(kind,t);worst[wk]=min(worst.get(wk,slack),slack)
  else:raise GateError('unknown path record')
 expected={(c,id,t)for c in corners for id in arcs for t in ['setup','hold']}
 need(set(coverage)==set(observed)==expected,'incomplete per-pair/per-corner/setup/hold coverage')
 for t in ['setup','hold']:
  for d in ['from','to']:empty_exceptions((out/f'exceptions-{t}-{d}.rpt').read_text())
 for t in ['setup','hold']:
  need(re.search(r'multicycle',(out/f'legacy-exceptions-{t}.rpt').read_text(),re.I),'legacy applied-exception report absent/unknown')
 for n in ['applied-sdc.rpt','ignored-sdc.rpt']:
  need((out/n).is_file()and(out/n).stat().st_size>0,f'missing {n}')
 physical=mapping((out/'fit.rpt').read_text(errors='replace'),(out/'map.rpt').read_text(errors='replace'))
 return {'status':'MOCK_GATE_PASS_NOT_STA'if origin=='mock'else'PASS_Q0_POSTFIT_TIMING_MAPPING_ONLY','source':manifest['source'],'new_endpoints':len(nr),'new_fast':sum(cs=={fast}for cs in nr.values()),'legacy_fast':len(legacy),'legacy_reachable_endpoints':len({a[2]for a in arcs.values()if a[0]=='legacy'}),'structural_pairs':len(arcs),'corner_checks':len(expected),'corners':corners,'worst_slack':{str(k):v for k,v in worst.items()},'mapping':physical}
def seal(out,origin,source,rc,source_bindings):
 files={str(p.relative_to(out)):{'SHA256':H(p.read_bytes()),'bytes':p.stat().st_size}for p in out.rglob('*')if p.is_file()and p.name not in ['manifest.json','verdict.json']}
 (out/'manifest.json').write_text(json.dumps({'origin':origin,'source':source,'collector_exit':rc,'source_bindings':source_bindings,'files':files},indent=2)+'\n')
def collect(a):
 need(not a.out.exists(),'output exists; refuse mixed/stale evidence')
 root=a.source_tree.resolve();project=a.project.resolve();rev=a.revision
 need(re.fullmatch(r'[0-9a-f]{40}',a.source)is not None,'use full source SHA')
 qsf=project/(rev+'.qsf');text=qsf.read_text();bindings={}
 for name in re.findall(r'^set_global_assignment -name (?:SYSTEMVERILOG_FILE|VERILOG_FILE) "([^"]+)"',text,re.M):
  p=Path(name);p=p if p.is_absolute()else project/p
  if p.resolve().is_relative_to(root/'rtl'):
   rel=str(p.resolve().relative_to(root));expected=subprocess.check_output(['git','show',a.source+':'+rel],cwd=root)
   need(p.read_bytes()==expected,f'fitted source tree differs from pinned commit: {rel}');bindings[rel]=H(expected)
 need('rtl/gpu3d/gpu3d_factor_pump.sv'in bindings,'QSF does not bind Q0 source')
 fit=project/'output_files'/(rev+'.fit.rpt');mapping_text=(project/'output_files'/(rev+'.map.rpt')).read_text(errors='replace')
 mapping(fit.read_text(errors='replace'),mapping_text) # Failed fit never launches STA collector.
 tcl=Path(__file__).with_name('collect.tcl');log=project/('q0-collector-'+a.out.name+'.log')
 with log.open('w')as f:
  p=subprocess.Popen(['nice','-n','10',a.quartus_sta,'-t',str(tcl),rev,rev,str(a.out.resolve())],cwd=project,stdout=f,stderr=subprocess.STDOUT);print('collector PID',p.pid,flush=True);rc=p.wait()
 a.out.mkdir(parents=True,exist_ok=True)
 for n,p in [('fit.rpt',fit),('map.rpt',project/'output_files'/(rev+'.map.rpt')),('sta.rpt',project/'output_files'/(rev+'.sta.rpt')),('project.qsf',qsf),('project.sdc',project/(rev+'.sdc')),('collector.log',log),('collector.tcl',tcl),('standard_clock.tcl',tcl.with_name('standard_clock.tcl'))]:
  if p.exists():(a.out/n).write_bytes(p.read_bytes())
 seal(a.out,'live-quartus-sta',a.source,rc,bindings)
def main():
 ap=argparse.ArgumentParser(description=__doc__);sub=ap.add_subparsers(dest='mode',required=True)
 c=sub.add_parser('collect');c.add_argument('--project',type=Path,required=True);c.add_argument('--revision',default='apf_top');c.add_argument('--source',required=True);c.add_argument('--source-tree',type=Path,required=True);c.add_argument('--quartus-sta',default='quartus_sta');c.add_argument('--out',type=Path,required=True)
 v=sub.add_parser('check');v.add_argument('out',type=Path)
 a=ap.parse_args()
 try:
  if a.mode=='collect':collect(a)
  result=evaluate(a.out)
 except (GateError,OSError,ValueError,KeyError,IndexError)as e:
  result={'status':'FAIL_CLOSED','reason':str(e)}
 if a.out.is_dir():(a.out/'verdict.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result,indent=2));return 0 if result['status'].startswith('PASS_')else 1
if __name__=='__main__':sys.exit(main())
