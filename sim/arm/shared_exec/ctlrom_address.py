#!/usr/bin/env python3
"""Lower source semantic IDs to direct raw-input Boolean logic, then prove ROM identity."""
import os,pathlib,json,subprocess,fcntl,re,hashlib,time
os.setpriority(os.PRIO_PROCESS,0,10)
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';S=D/'source';Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys';r=json.loads((D/'catalogue.json').read_text());assert r['status']=='SIX_PLANE_CAPACITY_PASS'
gen=(W/'sim/arm/shared_exec/ctlrom_generate.py').read_text();ports=gen.split("ports='''",1)[1].split("'''",1)[0];args=['c_ins','h_pc','c_bl2t','f_hw','rl_rem','c_cls','mode_in','rl_r','c_kind','ustep','h_th','h_ab','h_v','qpa','c_bl2','take_fiq','take_irq','hivec'];bindings=','.join('.'+x for x in args)
widths=[r['planes']['plane'+str(i)]['bits']for i in range(6)];iw=[r['planes']['plane'+str(i)]['ID_bits']for i in range(6)];n=sum(iw)
s='module ctlrom_address_source('+ports+f'output logic[{n-1}:0]ids,output logic[42:0]donly,output logic[22:0]seq);\n'
for i,w in enumerate(widths):s+=f'logic[{w-1}:0]p{i};\n'
s+='ctlrom_descriptor semantic('+bindings+',.p0,.p1,.p2,.p3,.p4,.p5,.donly,.seq);\n'
off=0
for i in range(6):
 p=r['planes']['plane'+str(i)];s+=f'always_comb begin ids[{off}+:{iw[i]}]=0;case(p{i})\n'
 for j,v in enumerate(p['words']):s+=f"{widths[i]}'h{v:x}:ids[{off}+:{iw[i]}]={iw[i]}'d{j};\n"
 s+='default:;endcase end\n';off+=iw[i]
s+='endmodule\n';(S/'ctlrom_address_source.sv').write_text(s)
# Source word->ID cases above are a lowering/intermediate oracle only. The
# candidate is the optimized Boolean raw-input function, not that RTL hierarchy.
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
files=[S/(n+'.sv')for n in ['arm_pkg','ctlrom_decode','ctlrom_descriptor','ctlrom_address_source']]
script='read_slang --allow-use-before-declare --top ctlrom_address_source '+' '.join(map(str,files))+f'; synth -top ctlrom_address_source -flatten -noabc; abc -g simple; clean -purge; rename ctlrom_address_source ctlrom_address; stat; write_json {D}/address-synthesis.json; write_verilog -noattr -noexpr {S}/ctlrom_address_cells.v; write_verilog -noattr {S}/ctlrom_address.sv'
with(D/'address-lowering.log').open('w')as log:p=subprocess.run([Y,'-Q','-T','-m','slang','-p',script],stdout=log,stderr=subprocess.STDOUT,timeout=90)
assert p.returncode==0,(D/'address-lowering.log').read_text()[-1800:]
# Preserve the same Boolean function while spelling output-bit aliases as
# scalar wires; this avoids false whole-vector feedback in simulation.
p=S/'ctlrom_address.sv';v=p.read_text()
for name,width in [('donly',43),('ids',35),('seq',23)]:
 def scalar(match):
  hi=int(match[1]);lo=int(match[2])if match[2]is not None else hi
  bs=['ctl_'+name+'_'+str(k)for k in range(hi,lo-1,-1)]
  return bs[0]if len(bs)==1 else'{'+','.join(bs)+'}'
 v=re.sub(name+r'\[(\d+)(?::(\d+))?\]',scalar,v)
 declaration='\n'.join('  wire ctl_'+name+'_'+str(k)+';'for k in range(width))+'\n'
 v=v.replace('  output ['+str(width-1)+':0] '+name+';',declaration+'  output ['+str(width-1)+':0] '+name+';',1)
 v=v.replace('endmodule','  assign '+name+'={'+','.join('ctl_'+name+'_'+str(k)for k in range(width-1,-1,-1))+'};\nendmodule',1)
p.write_text(v)
m=json.loads((D/'address-synthesis.json').read_text())['modules']['ctlrom_address'];types={c['type']for c in m['cells'].values()};assert all(t.startswith('$_')for t in types),types
assert all(c['direction']=='input'or n in ['ids','donly','seq']for n,c in m['ports'].items())
report={'status':'DIRECT_RAW_INPUT_BOOLEAN_ID_FUNCTION','ID_bits':n,'plane_ID_bits':iw,'Boolean_cells':len(m['cells']),'cell_types':sorted(types),'no_sequential_or_memory_cells':True,'ports':{k:len(v['bits'])for k,v in m['ports'].items()},'SV_sha256':hashlib.sha256((S/'ctlrom_address.sv').read_bytes()).hexdigest(),'no_native_area_claim':True}
(D/'address-result.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
