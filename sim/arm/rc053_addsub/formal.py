"""Run only after a coordinator worker lease: source-bound address equivalence."""
from pathlib import Path
import os,re,json,subprocess,hashlib
R=Path(__file__).resolve().parents[3];os.chdir(R);D=R/'build/rc053-cpu/formal';D.mkdir(exist_ok=True,parents=True)
# Preparation is source-only; invocation of this script is a leased worker.
lease=R/'build/rc053-cpu/lease.json';assert lease.exists() and json.loads(lease.read_text()).get('authorized') is True,'no explicit recorded CPUCompression lease'
os.setpriority(os.PRIO_PROCESS,0,10);Y='build/tools/oss-cad-suite/bin/yosys';H=lambda b:hashlib.sha256(b).hexdigest();src=(R/'rtl/arm/arm9_core.sv').read_text();old=subprocess.check_output(['git','show','887187e6:rtl/arm/arm9_core.sv'],text=True);subprocess.run(['python3','sim/arm/rc053_addsub/source_check.py'],check=True)
base=re.search(r'  assign a_sum\s*=.*?;',old)[0].replace('eu.alu','alu')
new=re.search(r'  wire\s+a_sub =.*?assign a_sum = a_addsub\[32:1\];',src,re.S)[0].replace('eu.alu','alu')
needle="{a_off ^ {32{a_sub}}, a_sub}";assert src.count(needle)==1;bad=src.replace(needle,"{a_off ^ {32{a_sub}}, 1'b0}");(D/'actual-wrongcarry-source.sv').write_text(bad)
r={'state':'RUNNING','source_SHA256':H(src.encode()),'fault_source_SHA256':H(bad.encode()),'input_bits':69,'result_bits':32,'cases':[]}
for tag,body,verb in [('equiv',new,'verify'),('wrongcarry',new.replace(needle,"{a_off ^ {32{a_sub}}, 1'b0}"),'falsify')]:
 sv='module old_addr(input wire[31:0]e_a,a_off,input wire[4:0]alu,output wire[31:0]a_sum);localparam[4:0]AL_SUB=2;\n'+base+'\nendmodule\nmodule new_addr(input wire[31:0]e_a,a_off,input wire[4:0]alu,output wire[31:0]a_sum);localparam[4:0]AL_SUB=2;\n'+body+'\nendmodule\nmodule miter(input wire[31:0]e_a,a_off,input wire[4:0]alu,output wire difference);wire[31:0]o,n;old_addr g(e_a,a_off,alu,o);new_addr t(e_a,a_off,alu,n);assign difference=o!=n;endmodule\n';(D/(tag+'.sv')).write_text(sv);ys=D/(tag+'.ys');ys.write_text('read_verilog -sv '+str(D/(tag+'.sv'))+'\nprep -top miter -flatten\nopt -full\nsat -'+verb+' -prove difference 0 -set-def-inputs -show-inputs -show-outputs -dump_json '+str(D/(tag+'-witness.json'))+'\n')
 with(D/(tag+'.log')).open('w')as f:p=subprocess.run([Y,'-Q','-T','-s',str(ys)],stdout=f,stderr=subprocess.STDOUT,timeout=60)
 log=(D/(tag+'.log')).read_text();assert p.returncode==0 and ('no model found: SUCCESS!'if tag=='equiv'else'model found: FAIL!')in log,log[-1500:];r['cases'].append({'tag':tag,'verdict':'PASS'if tag=='equiv'else'CAUGHT','miter_SHA256':H(sv.encode()),'log_SHA256':H(log.encode())})
r['state']='PASS';(D/'result.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r))
