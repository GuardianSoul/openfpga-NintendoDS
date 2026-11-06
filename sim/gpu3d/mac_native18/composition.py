#!/usr/bin/env python3
"""Bind the exact replaced owner, native donor, ports, consumers and clock contract."""
import argparse,hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--before',default='49746326');a=p.parse_args()
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
H=lambda b:hashlib.sha256(b).hexdigest()
path='rtl/gpu3d/gpu3d_gxeng.sv';new=(ROOT/path).read_text();old=subprocess.check_output(['git','show',a.before+':'+path],cwd=ROOT).decode()
def helper(s,name):return s[s.index('module '+name+' ('):].split('endmodule',1)[0]+'endmodule'
before=helper(old,'gpu3d_gxmac_products');after=helper(new,'gpu3d_gxmac_products')
assert new.replace(after,before,1)==old,'all non-MAC source, consumers, defaults, imports and RF exact'
assert before.split(');',1)[0]==after.split(');',1)[0],'same ports/no new parameters'
paths=['rtl/gpu3d/gpu3d_gxlight.sv','scripts/build_ds.sh','sim/ds/runtime_gx_context.py','sim/pocket_ds/runtime_import_gx_context.svh']
bound={}
for name in paths:
 b=(ROOT/name).read_bytes();assert b==subprocess.check_output(['git','show',a.before+':'+name],cwd=ROOT),name;bound[name]=H(b)
pair=helper((ROOT/paths[0]).read_text(),'gpu3d_gxlight_pair18')
native_proof=subprocess.check_output(['git','show','f6c92036:'+paths[0]],cwd=ROOT).decode()
assert pair==helper(native_proof,'gpu3d_gxlight_pair18'),'reuse exact actual1172 one-DSP six-port native donor'
for tag in ['ll','lh','hl','hh']:assert after.count('gpu3d_gxlight_pair18 u_'+tag+'(')==1
assert 'pr <= join64(early_ll,early_lh,early_hl,early_hh);'in after
assert 'vp1 <= early_vector;'in after and 'vp3 <= product1;'in after
assert "wire mid = epoch != seen;"in before and "wire mid = epoch != seen;"in after
assert 'rst'not in after and 'enable'not in after
assert after.count('early_vector <= product1;')==1
assert after.count('logic [31:0] early_ll,early_lh,early_hl,early_hh;')==1
script=(ROOT/paths[1]).read_text()
assert 'set_multicycle_path -setup -end 1 -from [get_clocks $clk_sys] -to $gxmac_products_regs'in script
assert 'set_multicycle_path -hold -end 0 -from [get_clocks $clk_sys] -to $gxmac_products_regs'in script
# An independent integer recombination screen including signed extremes.
def signed(x,n):return x-(1<<n)if x>>(n-1)else x
edge=[0,1,0xffffffff,0x7fffffff,0x80000000,0xffff,0xffff0000,0x10000,0x7fff8000,0x80007fff,0x55555555,0xaaaaaaaa]
checks=0
for aa in edge:
 for bb in edge:
  ll=(aa&65535)*(bb&65535);lh=(aa&65535)*signed(bb>>16,16);hl=signed(aa>>16,16)*(bb&65535);hh=signed(aa>>16,16)*signed(bb>>16,16)
  assert 0<=ll<2**32 and all(-2**31<=v<2**31 for v in [lh,hl,hh])
  mid=(ll>>16)+(lh&65535)+(hl&65535);high=(hh+(lh>>16)+(hl>>16)+(mid>>16))&0xffffffff
  value=(high<<32)|((mid&65535)<<16)|(ll&65535)
  assert value==(signed(aa,32)*signed(bb,32))&((1<<64)-1)
  checks+=1
result=dict(before=a.before,source_sha256=H(new.encode()),old_sha256=H(old.encode()),native_pair_sha256=H(pair.encode()),unchanged=bound,
 inverse='Only gpu3d_gxmac_products body changes. Parent controls/defaults/parameterABI, sampled ma/mb/vma, pr/vpr consumers, all accumulators/flags/R/XS, cull/RF/lighting/snoop/imports and complete QSF/SDC byte-exact.',
 arithmetic='a=lo16_unsigned+hi16_signed*2^16. LL is unsigned32; LH/HL/HH signed32. Middle sums LLhigh16+LHlow16+HLlow16 (unsigned18). Upper32 adds HH+signed LHhigh16+signed HLhigh16+middlecarry2; low44 uses the same equation modulo12 in upper limb. Every original product bit is retained or truncated at the same bit44.',
 phase='At M, retain scalar LL/LH/HL/HH and vector1 low44. At SYS E, recombine the retained scalar and publish vector1. At FAST E, recompute vector2/vector3 from then-current operands, as before. No additional input-hold premise: raw helper post-M changes remain legal. Accumulators consume preceding pr/vpr at the same E. No reset/enable gate is added; epoch/seen unchanged.',
 native='Four unchanged measured six-active-port m18x18_full atoms: LL/LH/HL/HH pair logical operators0/1. All inputs/signs and full36 products source-bound; no native registers, preadders or accumulation. Prior actual1172 established one DSP per this exact donor body. New count/config/ALM/STA remains an actual-fit gate.',
 cost=dict(old_actual1172=dict(neededALM=157.5,FF=304,DSP=6),intendedDSP=4,old_logicalFF=306,new_logicalFF=370,added_logicalFF=64,
          added_arithmetic='Three middle18 two-adder reductions; upper32 three-adder scalar reduction and two upper12 three-adder vector reductions. Synthesis sharing/trimming and native DSP packing must be measured; no area saving claimed.'),
 timing='Existing normal setup1/hold0 retained. M partial registers split scalar DSP from its full64 recombination; live E vector paths include DSP+middle18+upper12 carry, so 134MHz STA remains unproved. No new multicycle exception.',
 independent_integer_edge_products=checks,
 limitation='Bounded old/new plus arithmetic oracle and source induction, not arbitrary-state formal equivalence. Native arithmetic inherits unchanged transparent independent-mode contract, not encrypted simulation. Hardware findings and all DS rules unchanged.')
(out/'composition.json').write_text(json.dumps(result,indent=2)+'\n')
print('MAC_NATIVE18_COMPOSITION_PASS owner-only inverse/nativeexact/ABI/import/SDC, scalar retiming, edgeproducts='+str(checks))
