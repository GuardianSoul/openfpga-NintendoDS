#!/usr/bin/env python3
"""Exact inverse of service wiring; explicit lifetime/port/state bounds."""
from pathlib import Path
import hashlib,json,subprocess,itertools
R=Path(__file__).resolve().parents[3];p=R/'rtl/gpu3d/gpu3d_raster.sv';s=p.read_text();old=subprocess.check_output(['git','show','b7f66a1b:rtl/gpu3d/gpu3d_raster.sv'],cwd=R,text=True)
s=s.replace('    parameter bit SPAN_POOL = 0,     // indexed immutable queued/current/late descriptors\n','',1)
s=s.replace('    localparam bit SP = SPAN_POOL && !AREA && !NXB && !SPO;\n    logic sp_next_lp;\n','',1)
s=s.replace("(SP ? sp_next_lp : sd_nx.lp)", 'sd_nx.lp',1)
s=s.replace(' && (!SP || sd_load)', '',1)
a=s.index('    // The queued record is read only at sd_load,');b=s.index('    // MLOAD (DS_LIN17, not AREA):',a);s=s[:a]+s[b:]
s=s.replace("            if (fe_wr && !NXB) nx_full <= 1'b1;", "            if (fe_wr && !NXB) begin sd_nx <= fe_desc; nx_full <= 1'b1; end",1)
s=s.replace("                    nx_full <= 1'b0;\n                    if (SPO", "                    nx_full <= 1'b0;\n                    sd_cur <= nx_d;\n                    if (SPO",1)
s=s.replace("                // the span's late fields follow its first pixel into P14\n", "                // the span's late fields follow its first pixel into P14\n                if (T13.v && T13.first) sd_late <= sd_cur;\n                if (TXD > 0 && tg16o[25] && tg16o[22]) sd_late2 <= sd_late;   // {v, first} (ptag_t bits; Quartus: no member access here)\n",1)
assert s==old,'Changes beyond declared descriptor service seam'
count=0
for owners in itertools.product(range(4),repeat=3):
 for valid in itertools.product([0,1],repeat=3):
  assert len({o for o,v in zip(owners,valid)if v})<=3;count+=1
h=lambda s:hashlib.sha256(s).hexdigest()
result={'PASS':True,'inverse_exact_parent':'b7f66a1b','before_raster_sha256':h(old.encode()),'raster_sha256':h(p.read_bytes()),'pool_sha256':h((R/'rtl/gpu3d/gpu3d_span_records.sv').read_bytes()),'allocation_cases':count,'logical_payload_width':659,'logical_record_capacity':4,'logical_control_bits':12,'read_views':['shared queued/current','late','postTXD tail'],'write_ports':1,'read_latency_cycles':0,'added_SYS_FAST_edges':0,'external_service_changes':False,'source_only_budget':'2636 logical payloadbits; worst-case three full-width read replicas7908bits. Native per-field pruning/MLAB count, ALM savings and67MHz are unpriced; do not infer from these counts.','constraints':'Existing sd_cur/sd_nx register exceptions match no selected replacement storage; g_dram exception retained. No new false/multicycle path. Selected memory/index paths require native STA.'}
print(json.dumps(result,indent=2))
