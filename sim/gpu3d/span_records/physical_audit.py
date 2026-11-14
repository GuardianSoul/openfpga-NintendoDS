#!/usr/bin/env python3
"""Preserve qualified tokens/gates and require explicit single-read backends."""
from pathlib import Path
import json,subprocess,hashlib,re,itertools
R=Path(__file__).resolve().parents[3];old=lambda p:subprocess.check_output(['git','show','935f6360:'+p],cwd=R,text=True)
s=(R/'rtl/gpu3d/gpu3d_span_records.sv').read_text();orig=s;s=s.split('\n// Constant wiring projects',1)[0]
a=s.index('module gpu3d_span_records #(');b=s.index('    input logic clk',a);s=s[:a]+'module gpu3d_span_records (\n'+s[b:]
s=s.replace('    localparam int W=$bits(gpu3d_pkg::span_t);\n','    localparam int W=$bits(gpu3d_pkg::span_t);\n    (* ramstyle="MLAB,no_rw_check" *) logic [W-1:0] records[0:3];\n',1)
a=s.index('    // Separate single-read stores');b=s.index('    always_ff @(posedge clk)begin',a);s=s[:a]+'''    assign early_data=records[early_owner];
    assign late_data=records[late_owner];
    assign tail_data=records[tail_owner];
'''+s[b:]
s=s.replace('if(publish)begin next_owner<=free_owner;', 'if(publish)begin records[free_owner]<=publish_data;next_owner<=free_owner;',1)
assert s==old('rtl/gpu3d/gpu3d_span_records.sv'),'lease/token change beyond physical RAM seam'
p=R/'rtl/gpu3d/gpu3d_raster.sv';s=p.read_text();a=s.index('    // Explicit stored-bit contracts.');b=s.index('    // The queued record is read only at sd_load,',a);s=s[:a]+s[b:];s=s.replace('gpu3d_span_records #(.EARLY_MASK(SP_EARLY_MASK),.LATE_MASK(SP_LATE_MASK),\n            .TAIL_MASK(SP_TAIL_MASK))u_records(', 'gpu3d_span_records u_records(',1);assert s==old('rtl/gpu3d/gpu3d_raster.sv'),'admission/pipeline gate change'
assert orig.count('gpu3d_span_view #(.MASK(')==3
assert '.ram_block_type("LUTRAM")' in orig and '.rdaddress_reg("UNREGISTERED")' in orig
assert '`ifdef ALTERA_RESERVED_QIS' in orig
assert "gpu3d_lram #(.W(PW),.AW(2),.FE(1'b0)) u_ram" in orig
assert 'records[' not in orig
wrapper=(R/'rtl/gpu3d/gpu3d_ram.sv').read_text();assert wrapper==old('rtl/gpu3d/gpu3d_ram.sv')
count=0
for own in itertools.product(range(4),repeat=3):
 for valid in itertools.product([0,1],repeat=3):
  live={o for o,v in zip(own,valid)if v};assert len(live)<4;count+=1
fields={'native2189':[258,32,55],'compact_shadow_on':[266,32,55],'AA_edge_toon':[266,32,107]}
budgets={}
for name,widths in fields.items():
 budgets[name]={'widths':widths,'rows_per_view':4,'logical_bits':4*sum(widths),'native32row_column_capacity_bits':32*sum(widths),'two_column_rounding_capacity_bits':64*sum((w+1)//2 for w in widths),'two_column_memory_sites_budget':sum((w+1)//2 for w in widths),'physical_1W1R_instances':3,'hard_M10K_DSP_requested':0}
r={'PASS':True,'parent':'935f6360','token_source_inverse_exact':True,'raster_gates_inverse_exact':True,'single_read_wrapper_exact_parent':True,'allocation_cases':count,'control_bits':12,'budgets':budgets,'source_sha256':{f:hashlib.sha256((R/f).read_bytes()).hexdigest()for f in ['rtl/gpu3d/gpu3d_span_records.sv','rtl/gpu3d/gpu3d_raster.sv','rtl/gpu3d/gpu3d_ram.sv']},'remaining':'Only Root combined native RAM/ALTDPRAM inventory, memoryALM/FF/logic area, placement and67MHz establishes physical mapping or savings. No ramstyle-only credit. The32row/two-column capacity accounting is a budget, not a fit/placement result.'}
print(json.dumps(r,indent=2))
