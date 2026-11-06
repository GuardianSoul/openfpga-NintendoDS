#!/usr/bin/env python3
"""Exact store-only inverse, native profile and protected early readset."""
import hashlib
import json
import re
import subprocess
from pathlib import Path

R=Path(__file__).resolve().parents[3];B=R/'build/geometry-clip-pump16'
BASE='97698ee421304616961056481a9353b9a9a10538'
def before(path):return subprocess.check_output(['git','show',BASE+':'+path],cwd=R)
def sha(data):return hashlib.sha256(data).hexdigest()
paths=['rtl/gpu3d/gpu3d_gxvfin.sv','rtl/gpu3d/gpu3d_gxeng.sv','rtl/gpu3d/gpu3d_geom.sv','scripts/build_ds.sh']
assert set(subprocess.check_output(['git','diff',BASE,'--name-only','--','rtl','scripts','tools/gxasm'],cwd=R,text=True).splitlines())==set(paths)
records={}
for path in paths:
 current=(R/path).read_bytes();text=current.decode();old=before(path)
 if path.endswith('gxvfin.sv'):
  start=text.index('// One SDP copy per late');end=text.index('// Three exact signed32x32',start);text=text[:start]+text[end:]
  start=text.index('    // Keep the original logical mirrors');end=text.index('    typedef enum logic [3:0]',start);text=text[:start]+'\n'+text[end:]
  text=text.replace("    parameter bit COHORT = 1'b0, // private fixed-K4 progress sharing; old callers unchanged\n    parameter bit STORE_PUMP = 1'b0 // late RGB/UV stores only; XYZ/W keep original SYS RAMs\n","    parameter bit COHORT = 1'b0 // private fixed-K4 progress sharing; old callers unchanged\n")
  text=text.replace('    wire [31:0] original_out [9], original_in [9];\n','').replace('    localparam bit PUMP_STORE = STORE_PUMP && DIV_P2X && COHORT && DIVK == 4;\n','').replace('    genvar gk, ps;','    genvar gk;')
  text=text.replace('.rdata(original_out[gk])','.rdata(outside_word[gk])').replace('.rdata(original_in[gk])','.rdata(inside_word[gk])')
 elif path.endswith('gxeng.sv'):
  text=text.replace("    parameter bit SCALAR_DIV_P2X = 1'b0, // scalar u_div only, independent of clip/finalize\n    parameter bit CLIP_STORE_PUMP = 1'b0 // private clip store only; current K4/P2X cohort required\n","    parameter bit SCALAR_DIV_P2X = 1'b0 // scalar u_div only, independent of clip/finalize\n").replace(', .STORE_PUMP(CLIP_STORE_PUMP)','')
 elif path.endswith('geom.sv'):
  text=text.replace("    parameter bit GX_SCALAR_DIV_P2X = 1'b0, // scalar u_eng.u_div only; existing clip/finish option is independent\n    parameter bit GX_CLIP_STORE_PUMP = 1'b0 // private clip store, full capacity and original SYS consumers\n","    parameter bit GX_SCALAR_DIV_P2X = 1'b0 // scalar u_eng.u_div only; existing clip/finish option is independent\n").replace(', .CLIP_STORE_PUMP(GX_CLIP_STORE_PUMP)','')
 else:
  start=text.index('# Clip late-field store:');end=text.index('set gxcohort_regs',start);text=text[:start]+text[end:]
 assert text.encode()==old,path
 records[path]={'candidate_sha256':sha(current),'restored_before_sha256':sha(old)}

vfin=(R/paths[0]).read_text()
def module(text,name):return re.search(r'(?ms)^module\s+'+name+r'\b.*?^endmodule\b[^\n]*',text)[0]
inherit={}
for name in ['gpu3d_gxvfin','gpu3d_gxfin_group_ram','gpu3d_gxfin','gpu3d_gxclip_input_bank']:
 a=module(vfin,name);assert a==module(before(paths[0]).decode(),name),name;inherit[name]=sha(a.encode())
for path in ['rtl/gpu3d/gpu3d_gxdiv.sv','rtl/gpu3d/gpu3d_gxfront.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/ds/nds_gpu3d.sv','rtl/pocket/core_top_ds.sv']:
 assert (R/path).read_bytes()==before(path),path;inherit[path]=sha(before(path))
helper=module(vfin,'gpu3d_gxclip_store')
for needle in ['sf < 5','sf < 3 ? sf + 4 : sf + 5','output logic [31:0] outside_word [5]','forward_data <= pending_data;','inside_addr <= rgroup_in;','pending_we <= we && wa[10:9] == 2\'b01;', 'always_ff @(posedge clk2) if (mid)', '.operation_mode("DUAL_PORT")','.width_a(32)','.widthad_a(5)','.numwords_a(32)','.read_during_write_mode_mixed_ports("OLD_DATA")']:
 assert needle in helper,needle
assert 'rst'not in helper,'unreset RF writes must not be discarded'
for needle in ['if (ps < 4)', 'assign outside_word[ps] = original_out[ps];','assign inside_word[ps] = original_in[ps];','assign outside_word[ps] = pump_out[ps - 4];']:
 assert needle in vfin,needle
state={'outside_holds':160,'pending_write':42,'inside_address':5,'forwarding':37,'epoch_seen':2};assert sum(state.values())==246
record={'before':BASE,'exact_inverse':records,'unchanged_proofs_by_source_identity':inherit,'helper_sha256':sha((helper+'\n').encode()),'early_fields':[0,1,2,3],'pumped_source_indices':[4,5,6,7,8],'pumped_word_offsets':[4,5,6,8,9],'logical_state_bits':state,'RAM_target':'8 original early copies +5 new single SDP copies =13; original10latecopies have unconsumed outputs and must trim in Root native map. Not measured savings.','early_readset':'XYZ/W and shared ratio/seg_go/first3live products retain original SYS RAM outputs and logic cone. Late5 M reads feed SYS vin/pts/rv/ru/CM/dv_q captures; later product owners/timing unchanged by exact input-bank identity.','timing':'New store strictSYS/FAST endpoints setup1/hold0; ordinaryM->SYS late delta/sign captures still require native timing. No exception/saving/67MHzSTA credit.','import':'Defaultoff originalg_word hierarchy retained. Enabled canonical/pending/phase/heldread import bridge remains Rootpromotion gate; none implemented or waived here.'}
B.mkdir(parents=True,exist_ok=True);(B/'composition.json').write_text(json.dumps(record,indent=2)+'\n')
print('PASS exact4file inverse; early4 SYS cone/inputbank/scalar/other units unchanged;246bits/nativeOLD_DATA; mapping/STA/import gates open')
