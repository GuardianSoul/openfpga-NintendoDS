#!/usr/bin/env python3
"""Offline source/capture/event replay. Never runs a model or baseline."""
import csv
import hashlib
import json
from pathlib import Path
import sys


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def events(p):
    rows=list(csv.DictReader(p.open()));live=False;owner=None
    counts={k:0 for k in ['start','advance','commit','accepted','cancel']}
    for r in rows:
        v={k:int(x,16) if k in ('pc','address') else int(x) for k,x in r.items()}
        for k in counts:counts[k]+=v[k]
        if v['cancel']:
            assert not any(v[k] for k in ['owner_valid','start','advance','commit','accepted','address'])
            live=False;owner=None
            continue
        assert v['start']==v['raw_start'] and v['advance']==v['raw_advance']
        assert v['commit']==v['old_commit'] and v['accepted']==(v['commit'] and v['old_accept'])
        if v['start']:
            assert not live and v['advance'] and v['address']==v['pc']+12
            live=True;owner=(v['generation'],v['address'])
        assert v['owner_valid']==live
        if live:assert (v['generation'],v['address'])==owner
        else:assert v['address']==0
        if v['advance']:assert live
        if v['accepted']:
            assert live;live=False;owner=None
    assert not live
    return dict(rows=len(rows),**counts)


def main(root):
    manifest=json.loads((root/'manifest.json').read_text())
    for n,h in manifest['files'].items():assert sha(root/n)==h,n
    cpu=(root/'production/arm7_ds.sv').read_text();pkg=(root/'production/arm_pkg.sv').read_text()
    erased=cpu.replace('  parameter bit MUL_META = 0,     // passive request-time MUL context / advances\n  parameter bit MAIN_IF_PHASE_META = 0 // passive actual I/held-owner events only',
                       '  parameter bit MUL_META = 0      // passive request-time MUL context / advances')
    erased=erased.replace('  output logic        dbg_halted,\n  output a7_if_phase_t if_phase','  output logic        dbg_halted')
    lo=erased.index('  // Passive producer only:');hi=erased.index('  wire if_wait',lo);erased=erased[:lo]+erased[hi:]
    assert erased==(root/'before/arm7_ds.sv').read_text()
    lo=pkg.index('  // Logical next-F preparation events');hi=pkg.index('  // temp_addr update',lo)
    assert pkg[:lo]+pkg[hi:]==(root/'before/arm_pkg.sv').read_text()
    result=json.loads((root/'pair/results.json').read_text());assert result['status'].startswith('PASS8producerON+1metadataOFF')
    assert len(result['cases'])==9
    assert all(s['NI']==10 and s['reaped'] for s in result['stages'])
    assert result['actual_fault']['caught']=='PHASE_META_WRONG_OWNER_ADDRESS'
    all_events={}
    for key,row in result['cases'].items():
        case=key.split('/')[1]
        for ext,h in row['captures'].items():
            p=root/'pair'/(key+'.'+ext);q=root/'pair/reference'/case/ext
            assert sha(p)==h and p.read_bytes()==q.read_bytes()
        csv_path=root/'pair'/(key+'.csv');assert sha(csv_path)==row['phase_csv']
        all_events[key]=events(csv_path)
    assert all_events['meta-off/c2-s0-p1']['rows']==0
    for role,row in result['models'].items():
        assert sha(root/'pair'/role/'model')==row['SHA256']
        for n,h in row['sources'].items():assert sha(root/'pair'/n)==h
    changed=(root/'pair/cpu-wrong-owner.sv').read_text()
    normal=(root/'pair/source/cpu.sv').read_text()
    expected=cpu.replace('module arm7_ds import','module arm7_ds_slot_trial import',1)
    expected=expected.rstrip()[:-len('endmodule')]+(root/'cpu_ledger.svh').read_text()+'\nendmodule\n'
    assert normal==expected and (root/'pair/source/arm_pkg.sv').read_text()==pkg
    previous=json.loads((root/'pair/previous-results.json').read_text())
    for name,h in previous['models']['on']['inputs'].items():
        if name not in ['source/cpu.sv','source/arm_pkg.sv','source/tb.sv']:
            assert sha(root/'pair'/name)==h,'unchanged P7/physical source '+name
    needle="if_phase.address = (phase_owner_live ? {phase_f_owner,2'b00} : i_addr) + 32'd4;"
    assert normal.count(needle)==1 and normal.replace(needle,needle.replace("32'd4","32'd8"))==changed
    fault=(root/'pair/wrong-owner/c2-s0-p1.log').read_text()
    assert 'PHASE_META_WRONG_OWNER_ADDRESS' in fault
    for directory,case in [('shift-quiet','s0'),('shift-stalls','s1'),('shift-stalls','s5')]:
        p=root/directory
        log=(p/(case+'.log')).read_text()
        assert all(s in log for s in ['RSHIFT_META_PASS','PHASE_FUNCTION_PASS errors0','PAIRED_SLOT_PASS','ADVERSE_PASS'])
        v=events(p/(case+'.csv'))
        assert (v['start'],v['advance'],v['accepted'])==(320,320,320)
        all_events[directory+'/'+case]=v
        tb=(p/'source/tb.sv').read_text()
        assert (p/'source/cpu.sv').read_text()==normal and (p/'source/arm_pkg.sv').read_text()==pkg
        assert "words[k]=(k%2)?32'he1813231:32'he1813631;" in tb
        assert 'RSHIFT_FIXTURE_ARGUMENTS' in tb
    # The old quiet fixture's unreachable MUL pause predicate is retained,
    # then corrected only in the new stalled-shift fixture.
    assert 'intervention not reached' in (root/'shift-quiet/s1.log').read_text()
    assert 'cpu.esub==2&&cpu.phase_prepared' in (root/'shift-stalls/source/tb.sv').read_text()
    assert (root/'qlint.log').read_bytes()==b''
    contract=json.loads((root/'receiver-contract.json').read_text())
    assert contract['version']==1 and len(contract['fields'])==8
    summary=dict(status='PASS CPU-only passive producer',source=manifest['source'],parent=manifest['parent'],
                 erased_previous_CPU_and_package=True,literal_capture_files=54,producer_ON_cases=8,
                 metadata_OFF_cases=1,actual_wrong_owner_fault=True,register_shift_cases=3,events=all_events,
                 receiver='contract only; Memory after DMA; Root public forwarding',
                 limits='No P7/service change, service price, DS timing closure, enabled area or public-forwarding acceptance.')
    encoded=json.dumps(summary,indent=2,sort_keys=True)+'\n'
    p=root/'analysis.json'
    if p.exists():assert p.read_text()==encoded
    else:p.write_text(encoded)
    print(json.dumps(summary))


if __name__=='__main__':
    main(Path(sys.argv[1] if len(sys.argv)>1 else '.').resolve())
