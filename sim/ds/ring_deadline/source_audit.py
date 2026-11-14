#!/usr/bin/env python3
"""Exhaustive source-state inventory and read-only display noninterference."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[3]
FIELDS={
 'state':9,'row':24,'next_block':18,'slot_epoch':3,'epoch':1,
 'dline':8,'d_on':1,'go_q':1,'consumer':2,'consumer_valid':1,
 'st_full':4,'st_pres':4,'st_y':32,'posted':9,'ordered':9,
 'ticket_valid':1,'ticket':7,'ticket_row':8,
 'w_active':1,'w_drop':1,'w_row':8,'w_x':8,'w_next':8,
 'cp_active':1,'cp_late':1,'cp_pv':1,'cp_slot':2,'cp_src':2,'cp_row':8,'cp_px':8,'cp_x':9,
 'fp_done':9,'fp_act_q':1,'lc_count':12,
 'rs':2,'r_slot':2,'r_row':8,'r_block':5,'r_in':3,'r_written':4,'r_drop':1,
 'skid':184,'skid_wp':3,'skid_rp':3,'skid_count':4,'direct_active':1,'direct_slot':2,
}


def main():
    path=ROOT/'rtl/ds/nds_g3d_ring_deadline.sv';s=path.read_text()
    ff=s.split('always_ff @(posedge clk) begin',1)[1].split('`ifndef SYNTHESIS',1)[0]
    lhs=set(re.findall(r'\b(\w+)\s*(?:\[[^\]]+\]\s*)*<=',ff))
    assert lhs==set(FIELDS),('state inventory differs',sorted(lhs-set(FIELDS)),sorted(set(FIELDS)-lhs))
    assert sum(FIELDS.values())==444
    assert '(* ramstyle = "logic" *) logic [22:0] skid [8];' in s
    assert '.AW(10), .STYLE("M10K")' in s
    # Reversing only the new outputs and read-only forecast must recover
    # the exact old display controller. No old job/timer/IO driver changed.
    p='rtl/ds/nds_disp.sv';d=(ROOT/p).read_text()
    ports='''    output logic        ring_due_valid, // advisory only; never changes job admission
    output logic [7:0]  ring_due_line,
    output logic [13:0] ring_due_sys,
'''
    assert d.count(ports)==1;d=d.replace(ports,'')
    a=d.index('    // Read-only forecast from the actual HBlank sequencer.')
    end='        ring_due_sys <= due_t;\n    end\n';b=d.index(end,a)+len(end)
    d=d[:a]+d[b:]
    old=subprocess.check_output(['git','show','b621ba32:'+p],cwd=ROOT).decode()
    assert d==old,'display existing logic changed'
    result={'kind':'SOURCE_INVENTORY_NOT_NATIVE_PRICE','ring_source_sha256':hashlib.sha256(s.encode()).hexdigest(),
            'sequential_ring_fields_bits':FIELDS,'ring_total_bits':444,'display_hint_bits':23,
            'poster_bits':8,'MEM_arbiter_bits':17,'new_chain_event_bits':2,'service_total_bits':494,
            'planning_envelope_bits':704,'display_old_logic_exact_b621ba32':True,
            'excluded':'Existing shared controller/FIFO/crossing state and existing RAM read outputs; RAM payload bits counted separately. Quartus enum encoding, packing, replication and physical FF counts remain unmeasured.',
            'RAM':'Stage1024x23 unchanged; read512x23->1024x23 with3of4slots live; +1expectedM10K only. Skid8x23 forced logic. No DSP change proposed.'}
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
