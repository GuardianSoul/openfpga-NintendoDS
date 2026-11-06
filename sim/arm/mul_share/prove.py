#!/usr/bin/env python3
"""Complete-domain bit-vector proof, split only on the signed-long Boolean."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, time
R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--solver',default='build/tools/oss-cad-suite/bin/z3')
a=p.parse_args();D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
os.setpriority(os.PRIO_PROCESS,0,10)
sha=lambda b:hashlib.sha256(b).hexdigest()
raw=(R/'sim/arm/mul_share/relation.smt2').read_text()
current=(R/'rtl/arm/arm7_ds.sv').read_text()
old=subprocess.check_output(['git','show','c25c2ed3:rtl/arm/arm7_ds.sv'],cwd=R,text=True)
def block(s):
    return s[s.index('  // ---------------------------------------------------------------- multiplier (DSP)'):s.index('  // ---------------------------------------------------------------- loads')]
expected="""  // ---------------------------------------------------------------- multiplier (DSP)
  logic [63:0] prod;
  always_comb begin
    logic signed [32:0] ma, mb;
    logic signed [65:0] p;
    logic signed_long;
    signed_long = k == K_MULL && ins[22];
    ma = $signed({signed_long && opa[31], opa});
    mb = $signed({signed_long && opb[31], opb});
    p = ma * mb;
    prod = p[63:0] + (ins[21] ? ((k == K_MULL) ? {opd, opc} : {32'h0, opc}) : 64'h0);
  end

"""
assert block(current)==expected
assert current.replace(expected,block(old))==old,'change outside arithmetic block'
q=dict(base='c25c2ed3',RTL_SHA256=sha(current.encode()),old_RTL_SHA256=sha(old.encode()),
       solver_SHA256=sha(Path(a.solver).read_bytes()),relation_SHA256=sha(raw.encode()),processes=[])
for flag in ['true','false']:
    # Proving both cases with long/sign/accumulate still otherwise free is
    # stronger than restricting them to their feasible instruction decode.
    source=raw.replace('(and long sign)',flag)
    f=D/(flag+'.smt2');f.write_text(source);cmd=[a.solver,'-T:10',str(f)];start=time.monotonic()
    with(D/(flag+'.log')).open('w')as log:
        child=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT)
        row=dict(case=flag,PID=child.pid,NI=os.getpriority(os.PRIO_PROCESS,child.pid),cmd=cmd,input_SHA256=sha(source.encode()))
        row['exit']=child.wait(timeout=20)
    row.update(reaped=True,seconds=time.monotonic()-start,result=(D/(flag+'.log')).read_text().strip())
    assert row['exit']==0 and row['NI']==10 and row['result']=='unsat',row
    q['processes'].append(row)
# A concrete sign-extension counterexample controls vacuity. The compiled
# CPU mutant is separate and must also be caught by actual state checks.
source=raw.replace('(and long sign)','true').replace('(ite signed-long ((_ extract 31 31) a) #b0)','#b0')
source=source.replace('(check-sat)','(assert (= a #x80000000))\n(assert (= b #x00000001))\n(assert (not accum))\n(check-sat)')
f=D/'sign-counterexample.smt2';f.write_text(source);cmd=[a.solver,'-T:10',str(f)]
with(D/'sign-counterexample.log').open('w')as log:
    child=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT)
    row=dict(case='actual sign fault relation',PID=child.pid,NI=os.getpriority(os.PRIO_PROCESS,child.pid),cmd=cmd,input_SHA256=sha(source.encode()))
    row['exit']=child.wait(timeout=20)
row.update(reaped=True,result=(D/'sign-counterexample.log').read_text().strip());assert row['result']=='sat' and row['exit']==0
q['processes'].append(row);q['status']='PASS complete128bits/allcontrolchoices; UNSAT both signed-long cases; sign fault SAT'
(D/'receipt.json').write_text(json.dumps(q,indent=2)+'\n');print(q['status'])
