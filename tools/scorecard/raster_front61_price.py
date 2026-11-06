#!/usr/bin/env python3
"""Rank disjoint raster-front rows and price a paired-edge sharing route; read only."""
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[2]
MAIN=Path('/home/user/Git/NDS_Pocket')
RAW=MAIN/'build/coordinator/compress59-fit1156/raw'
DEST=ROOT/'docs/results/raster-front61-price-20261102'
OLD=MAIN/'docs/results/compact-reference-comparison-20261101/1109-apf_top.fit.rpt.gz'
PIN='c25c2ed39d21a0588d50018a513aa82306dc9e29'
FIT='5846f5cf619ee88650189acb863090dd5d5c9f29'
PRE='|apf_top|core_top:ic|nds_top:ds|nds_gpu3d:g_3d.u_gpu3d|gpu3d_raster:u_raster|gpu3d_front:u_front'


def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def number(s):return float(s.split()[0])
def own(s):return float(s.split('(')[1].removesuffix(')'))
def entities(lines):
    header=None;out={}
    for line in lines:
        cells=[c.strip()for c in line.split(';')[1:-1]]
        if 'Full Hierarchy Name'in cells and 'ALMs needed [=A-B+C]'in cells:header=cells;continue
        if header and len(cells)==len(header):
            row=dict(zip(header,cells));key=row['Full Hierarchy Name']
            if key.startswith('|apf_top'):out[key]=row
    assert PRE in out
    return out


def main():
    data=(RAW/'output_files__apf_top.fit.rpt.gz').read_bytes()
    receipt=json.loads((RAW/'receipt.json').read_text())
    assert receipt['source']==FIT and receipt['files']['output_files__apf_top.fit.rpt.gz']==hashlib.sha256(data).hexdigest()
    current=json.loads(gzip.decompress((RAW/'entities.json.gz').read_bytes()))
    lines=gzip.decompress(data).decode(errors='replace').splitlines()
    parsed=entities(lines)
    assert {k:v for k,v in current.items()if k==PRE or k.startswith(PRE+'|')}=={k:v for k,v in parsed.items()if k==PRE or k.startswith(PRE+'|')}
    donor=entities(gzip.decompress(OLD.read_bytes()).decode(errors='replace').splitlines())
    sources={}
    for file in ['rtl/gpu3d/gpu3d_front.sv','rtl/gpu3d/gpu3d_edge.sv','rtl/gpu3d/gpu3d_raster.sv','rtl/gpu3d/gpu3d_ram.sv']:
        a=subprocess.check_output(['git','show',PIN+':'+file],cwd=ROOT)
        assert a==subprocess.check_output(['git','show',FIT+':'+file],cwd=ROOT)==(ROOT/file).read_bytes()
        sources[file]=hashlib.sha256(a).hexdigest()
    children=[k for k in current if k.startswith(PRE+'|')and k.count('|')==PRE.count('|')+1]
    rows=[dict(path=PRE,group='Front own control/span logic (not resolved to individual operators)',needed_ALM=own(current[PRE]['ALMs needed [=A-B+C]']),FF=own(current[PRE]['Dedicated Logic Registers']),DSP=0)]
    for key in children:
        r=current[key]
        rows.append(dict(path=key,group=key.removeprefix(PRE+'|'),needed_ALM=number(r['ALMs needed [=A-B+C]']),FF=number(r['Dedicated Logic Registers']),DSP=int(r['DSP Blocks'])))
    rows.sort(key=lambda r:r['needed_ALM'],reverse=True)
    assert abs(sum(r['needed_ALM']for r in rows)-3886.5)<0.11
    assert sum(r['DSP']for r in rows)==8
    rams=json.loads(gzip.decompress((RAW/'rams.json.gz').read_bytes()))
    rams=[r for r in rams if '|gpu3d_front:u_front|'in r['Name']]
    ram_header=None;raw_rams=[]
    for line in lines:
        cells=[c.strip()for c in line.split(';')[1:-1]]
        if cells and cells[0]=='Name'and'M10K blocks'in cells:ram_header=cells
        elif ram_header and len(cells)==len(ram_header)and'|gpu3d_front:u_front|'in cells[0]:raw_rams.append(dict(zip(ram_header,cells)))
    assert rams==raw_rams
    targets=['gpu3d_edge:g_pp2.u_edge2a','gpu3d_edge:g_pp2.u_edge2b','gpu3d_div4:g_pp2.u_div2','gpu3d_lram:g_pp2.u_vys2']
    selected=[r for r in rows if r['group']in targets]
    assert len(selected)==4
    gross=round(sum(r['needed_ALM']for r in selected),1);assert gross==1198.1
    right_ram=[r for r in rams if any('|'+x+'|'in r['Name']for x in targets)]
    banks=[]
    for key in children:
        for name,row in current.items():
            if name.startswith(key+'|')and name.count('|')==key.count('|')+1 and any(s in name for s in ('g_slim.u_','u_vtx','u_vys','u_lrom','u_rom')):
                banks.append(dict(path=name,needed_ALM=number(row['ALMs needed [=A-B+C]']),FF=number(row['Dedicated Logic Registers']),DSP=int(row['DSP Blocks']),scope='Nested in its parent row; never add again to disjoint total.'))
    donor_children={k.removeprefix(PRE+'|'):v for k,v in donor.items()if k.startswith(PRE+'|')and k.count('|')==PRE.count('|')+1}
    result=dict(status='SOURCE_REPORT_ONLY_ARCHITECTURE_ROUTE_NO_GAIN_OR_TIMING_ACCEPTANCE',source=PIN,fit_source=FIT,donor_source=subprocess.check_output(['git','rev-parse','3a15a7b5'],cwd=ROOT,text=True).strip(),
        current_raster_sources_match_actual1156=sources,report_hashes={str(RAW/'output_files__apf_top.fit.rpt.gz'):digest(RAW/'output_files__apf_top.fit.rpt.gz'),str(RAW/'entities.json.gz'):digest(RAW/'entities.json.gz'),str(RAW/'rams.json.gz'):digest(RAW/'rams.json.gz'),str(OLD):digest(OLD)},
        current_parent=current[PRE],donor_parent=donor[PRE],donor_direct_children=donor_children,
        disjoint_current=rows,disjoint_ALM_total=round(sum(r['needed_ALM']for r in rows),1),nested_bank_detail=banks,
        current_RAM_rows=rams,current_reported_M10K=sum(int(r['M10K blocks'])for r in rams),current_reported_MLAB=sum(int(r['MLABs'])for r in rams),
        candidate=dict(name='Two-context A/B edge pipeline on existing clk_2x; fixed left/right slots each base cycle',
            removed_owned_rows=selected,gross_removed_needed_ALM=gross,gross_removed_DSP=sum(r['DSP']for r in selected),
            removed_reported_M10K=sum(int(r['M10K blocks'])for r in right_ram),removed_reported_MLAB=sum(int(r['MLABs'])for r in right_ram),
            removed_registers_to_account_again=sum(int(r['FF'])for r in selected),
            retained_current_arithmetic='Existing stage1/slim endpoint path and dual-item stage2, all current DS rules/precision; each context advances once per67MHz cycle in one134MHz phase.',
            target_net_needed_ALM=500,maximum_measured_countercost_for_target=round(gross-500,1),
            measured_countercost=None,measured_net_gain=None,
            countercost_scope='All second-context state, base-domain input snapshots, result staging, context mux/decoder, phase/reset, divider context, any extra ROM/RAM ports or duplicated banks. 1146 retained logical registers are not free or priced by a guessed FF/ALM ratio.',
            required_service='Preserve each original left/right context transition, data, metadata, request/result and ready/backpressure at each base-cycle boundary. No scalar donor schedule or inserted waits.',
            storage_scope='Share input copies only where old-data/bank ownership/phase reads prove equivalent; reuse current RAM helpers. Existing vertex writes remain base-clock, edge reads use fixed134MHz slots. No new off-chip traffic or lower queue/record capacity.',
            blockers=['134MHz operator/context-mux paths have no measured STA on this proposed architecture; existing clock alone is not acceptance.',
                'Need exact two-phase input snapshot/output commit relation for arbitrarily different left/right stalls and simultaneous bank handover.',
                'Context and RAM-port implementation must map within698.1neededALM countercost for500net; no candidate mapping exists. Whole1156 is capacityFAIL/noSTA.'],
            proposed_next='Coordinator architecture disposition; keep source/report-only until countercost route accepted. No implementation, miter/model, fit or unchanged native baseline.'),
        donor_limit='1354.7ALM/4DSP donor has one serial left/right EP2 pipeline and single-item issue; AA/fog/edge/lower features differ. Its2531.8ALM parent gap is not isolated removable cost.',
        closed='product60 deferred; lerp6/decal/colour49, AC-RATE/HG-WING remain closed; current-source speed/game/audio gaps remain separate.')
    DEST.mkdir(parents=True,exist_ok=True)
    (DEST/'price.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(status=result['status'],disjoint_ALM=result['disjoint_ALM_total'],gross_candidate=gross,countercost_limit=698.1,net_gain=None,compiled=False)))


if __name__=='__main__':main()
