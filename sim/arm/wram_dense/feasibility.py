#!/usr/bin/env python3
"""Prove the proposed five-word/four-row layout before production RTL."""
from pathlib import Path
import argparse, collections, hashlib, json, os, resource

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--source-root',type=Path,help='frozen before-source root for an offline replay')
a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CPU,(30,30))
resource.setrlimit(resource.RLIMIT_AS,(512*1024**2,512*1024**2))
D=a.output.resolve();D.mkdir(parents=True,exist_ok=False)
R=a.source_root.resolve()if a.source_root else Path(__file__).resolve().parents[3]
def cells(word):
    group,slot=divmod(word,5)
    for bank in range(4):
        if slot==4:
            yield bank,group*4+bank,2,8,bank*8
        elif bank==slot:
            yield bank,group*4+slot,0,2,bank*10
        else:
            yield bank,group*4+slot,0,10,bank*10-(8 if bank>slot else 0)
def mask(word,be):
    m=sum(255<<(b*8)for b in range(4)if be>>b&1)
    return {(b,row):(m>>src&((1<<n)-1))<<offset for b,row,offset,n,src in cells(word)}
owned=set();extent=[0]*4
for word in range(16384):
    destinations=list(cells(word))
    assert len(destinations)==4 and len({x[0]for x in destinations})==4
    logical=[]
    for bank,row,offset,n,src in destinations:
        assert row<13108 and offset+n<=10
        extent[bank]=max(extent[bank],row+1)
        for bit in range(n):
            coordinate=(bank*13108+row)*10+offset+bit
            assert coordinate not in owned,'overlapping logical ownership'
            owned.add(coordinate);logical.append(src+bit)
    assert sorted(logical)==list(range(32))
assert len(owned)==65536*8 and extent==[13108]*4
# Every possible byte enable, pair of layout slots, and same/different
# group: shared-cell writes can merge because their masks are disjoint.
pair_checks=shared_cells=0
for ga,gb in [(0,0),(0,1),(3275,3276)]:
    for sa in range(5):
        for sb in range(5):
            wa,wb=ga*5+sa,gb*5+sb
            if max(wa,wb)>=16384:continue
            for ba in range(16):
                for bb in range(16):
                    ma,mb=mask(wa,ba),mask(wb,bb)
                    if wa!=wb:
                        for k in ma.keys()&mb.keys():
                            assert not ma[k]&mb[k],'independent words share writable bits'
                            shared_cells+=bool(ma[k] and mb[k])
                    # Equal logical words use the existing B-wins retry;
                    # it is not silently extended to different words.
                    pair_checks+=1
proof=dict(status='PASS pre-RTL layout/port feasibility; native rden/phase gate separate',
    logical_words=16384,logical_bytes=65536,unique_bits=len(owned),banks=4,bank_width=10,
    bank_depth=extent,expected_M10K=4*((13108+1023)//1024),prior_private_M10K=64,
    expected_saving_M10K=12,measured_saving=False,pair_mask_checks=pair_checks,
    shared_cell_write_cases=shared_cells,
    schedule='Each bank: two read addresses at aligned SYS/2x E; two merged RMW writes at middle2x M. rden low at M must hold both Q outputs. At most one physical write if both rows equal; merge masks, B priority only on overlap (same logical owner already arbitrated).',
    reset='Capture take/mask/data at E with original reset gate; accepted writes finish at M even if reset asserts meanwhile. Phase epoch/seen free-run, never reset independently. No contents clear or extra service cycle.',
    limitations='Capacity/ports are algebraic, not a measured fit/STA. Division5/mapping/mask/merge cost and 134MHz halfcycle timing remain unmeasured. Imported logical image must preserve full64KiB.',
    references={'primitive':'rtl/ds/nds_ram.sv','PLL':'rtl/pocket/nds_pll_ds.sv','phase_reuse':'rtl/ds/nds_lcache.sv g_pump','vendor_rden_reuse':'rtl/gpu3d/gpu3d_gxeng.sv gpu3d_gxrf',
        'M10K_byteenable':'https://cdrdv2-public.intel.com/666995/cv_5v2-683375-666995.pdf',
        'read_enable_output_hold':'https://cdrdv2-public.intel.com/654378/ug_ram.pdf'},
    source_SHA256={n:hashlib.sha256((R/n).read_bytes()).hexdigest()for n in ['rtl/arm/arm7_wram.sv','rtl/ds/nds_ram.sv','rtl/pocket/nds_pll_ds.sv','sim/pocket_ds/sim_prims_ds.sv']})
(D/'layout.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps({k:proof[k]for k in ['status','logical_bytes','unique_bits','expected_M10K','pair_mask_checks','shared_cell_write_cases']},indent=2))
