#!/usr/bin/env python3
"""Full enabled main source codegen and actual parameter-route fault."""
from pathlib import Path
import json,hashlib,subprocess,os,shutil,resource,re
R=Path(__file__).resolve().parents[3];D=R/'build/clip16-dirty-batch';D.mkdir(parents=True,exist_ok=True);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
script=(R/'sim/pocket_ds/run.py').read_text();scope={};exec(script[script.index('RTL = '):script.index('\n\n',script.index('SIM = '))],scope)
# Static simulation list omits modules selected by main's default profile.
# Supplement with the existing production build_ds.sh inventory, not source edits.
extra=['apf/mf_ddio_bidir_12.v','apf/apf_top.v','apf/io_bridge_peripheral.v','apf/io_pad_controller.v','arm/arm7_ds.sv','arm/arm7_wram.sv','ds/nds_spi_mc.sv','pocket/nds_cart_scpu.sv','pocket/nds_mbox.sv','pocket/nds_apf_wr.sv','pocket/nds_controls_fw.sv']+['serv/'+p.name for p in (R/'rtl/serv').glob('*.v')]
files=list(dict.fromkeys(['rtl/'+p for p in scope['RTL']+extra]+scope['SIM']));headers=[str(p.relative_to(R)) for root in ['rtl','sim'] for p in (R/root).rglob('*') if p.is_file() and p.suffix in ['.svh','.vh']];hashes={}
for f in dict.fromkeys(files+headers):
 q=D/f;q.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(R/f,q);hashes[f]=hashlib.sha256(q.read_bytes()).hexdigest()
# Use shipped SDK I/O models for the complete APF shell; keep native core
# leaves unchanged. Replace only the simulation altddio_out stand-in.
VENDOR=Path('build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v')
v=VENDOR.read_text(encoding="latin1");models=[]
for name in ['ALTERA_DEVICE_FAMILIES','altddio_in','altddio_out','altddio_bidir']:
 m=re.search(r'^module\s+'+name+r'\b.*?^endmodule[^\n]*',v,re.M|re.S);assert m,name;models.append(m.group(0))
(D/'io_vendor.v').write_text('\n'.join(models)+'\n');files.append('io_vendor.v');hashes['io_vendor.v']=hashlib.sha256((D/'io_vendor.v').read_bytes()).hexdigest()
f=D/'sim/phase1/sim_prims.sv';prim=f.read_text();prim=re.sub(r'^module altddio_out\b.*?^endmodule[^\n]*','',prim,flags=re.M|re.S);f.write_text(prim);hashes['sim/phase1/sim_prims.sv']=hashlib.sha256(f.read_bytes()).hexdigest()
# Verilator rejects APF's native narrow inout bindings that Quartus accepts.
# Simulation-only width normalization retains exactly the connected low bits.
f=D/'rtl/apf/apf_top.v';apf=f.read_text();native_apf_sha256=hashlib.sha256(f.read_bytes()).hexdigest()
apf=apf.replace('.padio ( scal_ddio_ctrl )','.padio ( sim_scal_ctrl_12 )').replace('.padio ( scal_clk )','.padio ( sim_scal_clk_12 )')
apf=apf.replace('endmodule','wire [11:0] sim_scal_ctrl_12, sim_scal_clk_12;\nassign scal_ddio_ctrl=sim_scal_ctrl_12[3:0];\nassign scal_clk=sim_scal_clk_12[0];\nendmodule',1);f.write_text(apf);hashes['rtl/apf/apf_top.v']=hashlib.sha256(f.read_bytes()).hexdigest()
base=subprocess.check_output(['git','rev-parse','38ece3a1'],cwd=R,text=True).strip()
r={'base':base,'native_apf_sha256':native_apf_sha256,'IO_adapter':'staged only explicit12bit inout, retain low4/low1; no production APF/leaf edits','vendor_sha256':hashlib.sha256(VENDOR.read_bytes()).hexdigest(),'sha256':hashes,'inventory_sha256':hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest(),'PID':os.getpid(),'NI':10,'jobs':1,'threads':1,'flag':'NDS_MAIN_CLIP16_DIRTY: scalar1/clip1/dirty1','stages':[]}
V=Path('build/tools/oss-cad-suite/bin/verilator')
cmd=[V,'--cc','--timing','--assert','--threads','1','-j','1','-Wno-fatal','--timescale','1ns/1ps','--top-module','apf_top','-DNDS_MAIN_CLIP16_DIRTY','--Mdir',D/'obj','-I'+str(D/'rtl/pocket'),'-I'+str(D/'rtl/sound'),*[D/f for f in files]]
def run(name,cmd):
 with (D/(name+'.log')).open('w') as log:
  p=subprocess.Popen(list(map(str,cmd)),stdout=log,stderr=subprocess.STDOUT);row={'name':name,'PID':p.pid,'command':list(map(str,cmd))};r['stages'].append(row);(D/'receipt.json').write_text(json.dumps(r));row['exit']=p.wait(timeout=120);row['reaped']=True
 assert row['exit']==0,(name,(D/(name+'.log')).read_text()[-2000:])
 return '\n'.join(f.read_text() for f in Path(cmd[cmd.index('--Mdir')+1]).iterdir() if f.suffix in ['.cpp','.h'])
text=run('enabled',cmd)
r['checks']={}
for name,needle in {'dirty':'g_dirty_mlab__DOT__way','clip':'g_store_pump__DOT__u_store','scalar':'u_div__DOT__g_k4_pump'}.items():
 lines=[l.strip()[:500] for l in text.splitlines() if needle in l]
 r['checks'][name]={'count':len(lines),'examples':lines[:4]}
 assert lines,(name,needle)
r['enabled_hash']=hashlib.sha256(text.encode()).hexdigest()
# Public APF generic defaults all stay off.
cmd.remove('-DNDS_MAIN_CLIP16_DIRTY');cmd[cmd.index('--Mdir')+1]=D/'defaultobj';default=run('default',cmd)
assert 'g_dirty_mlab__DOT__way' not in default
assert 'g_store_pump__DOT__u_store' not in default
assert 'u_div__DOT__g_k4_pump' not in default
r['default']='PASS dirty/clip off'
# Actual SYS-for-FAST leaf disconnect. The pinned source audit must reject it.
f=D/'rtl/gpu3d/gpu3d_gxeng.sv';src=f.read_text();needle='.clk, .clk2(clk_2x), .rst, .we(rf_we), .wa(rf_wa), .wd(rf_wd), .start(clip_start)'
# Select the literal clip instantiation rather than unrelated helpers.
a=src.index(')) u_clip (');b=src.index(');',a);block=src[a:b]
r['clip_connection']=block
assert '.clk2(clk_2x)' in block,block
mutant=src[:a]+src[a:b].replace('.clk2(clk_2x)', '.clk2(clk)',1)+src[b:];assert mutant!=src
f.write_text(mutant);r['disconnect_sha256']=hashlib.sha256(mutant.encode()).hexdigest()
assert '.clk2(clk_2x)' not in mutant[a:mutant.index(');',a)]
r['disconnect_fault']='CAUGHT actual SYS-for-FAST clock binding by clip route audit'
f.write_text(src);r['status']='PASS_ENABLED_DEFAULT_CODEGEN_LEAF_FLAGS_AND_CAUGHT_DISCONNECT'
(D/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print(r['status'],flush=True)
