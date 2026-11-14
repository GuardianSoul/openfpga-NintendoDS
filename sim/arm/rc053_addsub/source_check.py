"""Source-only inverse guard; does not run a compiler, SAT or simulation."""
from pathlib import Path
import subprocess,hashlib,json
R=Path(__file__).resolve().parents[3];p=R/'rtl/arm/arm9_core.sv';s=p.read_text();new='''  // One address carry chain for both signs. The extra low bit supplies
  // subtraction's +1 without a second arithmetic operation or result mux.
  wire         a_sub = (eu.alu == AL_SUB);
  wire [32:0]  a_addsub = {e_a, 1'b1} + {a_off ^ {32{a_sub}}, a_sub};
  assign a_sum = a_addsub[32:1];''';old='  assign a_sum   = (eu.alu == AL_SUB) ? e_a - a_off : e_a + a_off;';assert s.count(new)==1;before=subprocess.check_output(['git','show','887187e6:rtl/arm/arm9_core.sv'],cwd=R,text=True);assert s.replace(new,old,1)==before
D=R/'build/rc053-cpu';D.mkdir(parents=True,exist_ok=True);r={'state':'SOURCE_INVERSE_PASS_NOT_FUNCTIONAL_QUALIFICATION','base':'887187e64c420d5a5c87c9b8863bcf3a484d2b89','source_SHA256':hashlib.sha256(p.read_bytes()).hexdigest(),'scope':'active arm9_core only, a_sum mathematical representation; no state/RF/ports/control edits','unrun_gates':'allinputequivalence+actualmutant, normal/DENSE25each+tb_arm, same-seedarea/67MHz timing'};(D/'source-plan.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r))
