#!/usr/bin/env python3
"""Host/source/retained-observable checks only; no compilation or simulation."""
import argparse
import copy
import gzip
import hashlib
import importlib.util
import itertools
import json
from pathlib import Path
import shutil
import re
import struct
import sys
import tempfile

import check_observed
from prepare_capture import sha, write


def check_assertion_bindings(base,names):
    modules={'full_game':('full_game_capture_contract.sv','nds_full_game_capture_contract'),
        'current41':('current41_binding.sv','nds_capture41_binding')}
    for name in names:
        filename,module=modules[name]
        text=(base/'observed-overlay'/filename).read_text()
        assert re.search(r'^\s*bind\s+tb_ds_pocket\s+'+module+r'\s+\w+\s*\(',text,re.M),('unbound assertion module',module)


def check_source(base):
    binding=json.loads((base/'composition.json').read_text())
    check_assertion_bindings(base,binding.get('assertion_bindings_required',[]))
    parent=json.loads((base/'parent-composition.json').read_text())
    plan=json.loads((base/'game-build-plan.json').read_text())
    for name,digest in binding['copies_sha256'].items():assert sha(base/name)==digest,name
    assert binding['profile']==plan['full_profile']==parent['profile'] and len(binding['profile'])==60
    assert binding['binary_sha256'] is None and plan['model_sha256'] is None
    assert sha(base/'game-build-plan.json')==binding['build_plan_sha256']
    assert sha(base/'publication-contract.json')==binding['publication_contract_sha256']
    assert sha(base/'capture-source-rebind.json')==binding['source_rebind_sha256']
    assert sha(base/'scene-launch-plans.json')==binding['scene_launch_plans_sha256']
    assert sha(base/'stub-lifecycle-binding.json')==binding['stub_lifecycle_binding_sha256']
    assert sha(base/'hg-history-control-plan.json')==binding['hg_history_control_plan_sha256']
    scenes=json.loads((base/'scene-launch-plans.json').read_text())
    assert len(scenes)==6
    for scene in scenes.values():
        assert scene['capture_capacity']>=106 and scene['frames']<=scene['capture_capacity']
        assert scene['expected_states']==scene['frames']+1
        assert f'+scene_capture_frames={scene["capture_capacity"]}' in scene['argv']
        assert f'+frames={scene["frames"]}' in scene['argv']
    tb=(base/'observed-overlay/tb_native52_import.sv').read_text()
    edits=json.loads((base/'edits.json').read_text())
    check_observed.identity(tb,edits,binding['actual_observed_tb_sha256'])
    before=(base/'include/parent-hg193_combined_hook.svh.txt').read_text()
    hook=(base/'include/hg193_combined_hook.svh').read_text()
    assert hook.replace('\n`include "hg193_publication_diagnostics.svh"','').replace(
        ' hg193_publication_diagnostics("before-publication");\n','')==before
    assert sha(base/'include/hg193_combined_drain.svh')==parent['copies_sha256']['include/hg193_combined_drain.svh']
    assert sha(base/'include/runtime_import_arm9_mem_ready.svh')==parent['copies_sha256']['include/runtime_import_arm9_mem_ready.svh']
    diagnostics=(base/'include/hg193_publication_diagnostics.svh').read_text()
    api=json.loads((base/'publication-contract.json').read_text())
    for row in api['cpu_arm9_cache_clauses']:
        assert f'name={row["name"]} pass=' in diagnostics and row['expression'] in diagnostics
        assert row['gate']=='RETAINED_UNCHANGED'
    assert diagnostics.count('HG193_CPU_CLAUSE')==26 and '@(' not in diagnostics and '$readmem' not in diagnostics
    assert len([a for a in plan['argv'] if a.endswith('.cpp') and 'capture-bindings' in a])==2
    assert '+define+SCENE_SD' in plan['argv'] and '+define+FULL_GAME_CAPTURE' in plan['argv']
    assert '-lz' in plan['argv'] and '-GROM_AW=25' in plan['argv'] and '--assert' in plan['argv']
    assert not any(a.endswith('capture-bindings/tb_ds_pocket.sv') for a in plan['argv'])
    source_binding=json.loads((base/'capture-source-rebind.json').read_text())
    for name,digest in source_binding['qualified_files'].items():assert sha(base/'capture-bindings'/Path(name).name)==digest
    pending=json.loads((base/'model-pin.pending.json').read_text())
    assert pending['build_exit'] is None and pending['binary_sha256'] is None
    return dict(default085_reconstruction='PASS',strict_publication_guards_unchanged='PASS',
        clause_diagnostics=26,profile_fields=60,compiled_or_model_runs=0,copies=len(binding['copies_sha256']))


def source_mutations(base):
    cases=[('changed-CPU-sampling-edge','capture-bindings/storage_pair_capture.sv',
        'always @(posedge `CS.u_cpud.cclk)','always @(negedge `CS.u_cpud.cclk)'),
        ('lost-clause-diagnostic','include/hg193_publication_diagnostics.svh','name=ibuf_v pass=','name=REMOVED pass='),
        ('relaxed-strict-publication-guard','include/hg193_combined_drain.svh',
            'return arm9_mem_publication_ready() &&','return 1\'b1 &&')]
    caught=[]
    for label,name,before,after in cases:
        with tempfile.TemporaryDirectory(prefix='nds-capture-source-control-')as tmp:
            target=Path(tmp)/'copy';shutil.copytree(base,target)
            path=target/name;text=path.read_text();assert before in text
            path.write_text(text.replace(before,after))
            binding=json.loads((target/'composition.json').read_text())
            binding['copies_sha256'][name]=sha(path)
            write(target/'composition.json',binding)
            try:check_source(target)
            except AssertionError:caught.append(label)
            else:raise AssertionError('source mutation survived: '+label)
    return caught


def observable_fixture(base,qualified):
    fixtures=base/'observable-fixtures';fixtures.mkdir(exist_ok=True)
    source=qualified/'results/ac/capture/capture.states.jsonl'
    manifest=json.loads((qualified/'results/ac/capture-manifest.json').read_text())
    assert sha(source)==manifest['capture.states.jsonl']['sha256']
    data=source.read_bytes();(fixtures/'actual-ac106.states.jsonl').write_bytes(data)
    states=[json.loads(line)for line in data.splitlines()]
    assert [s['frame']for s in states]==list(range(107))
    def extent(rows):assert [s['frame']for s in rows]==list(range(107))
    rejected=[]
    try:extent(states[:25])
    except AssertionError:rejected.append('actual107state-earlyclose24')
    else:raise AssertionError('old24 cutoff survived')
    host=qualified/'host/checker-lib'
    shutil.copytree(host,base/'checker-bindings',dirs_exist_ok=True)
    sys.path.insert(0,str(host))
    spec=importlib.util.spec_from_file_location('qualified_capture_reader',host/'storage_pair_capture_analyze.py')
    reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)
    actual=Path('/home/user/Git/NDS_Pocket-codex-raster-colour49/build/scenes62/extended-host/results/ac/capture/capture.bus.gz')
    assert sha(actual)==manifest['capture.bus.gz']['sha256']
    # The early recording is mostly idle controller transitions. Retain its
    # first64 records, then every actual offer/take/return through16 returns.
    # This is an explicitly selected physical-channel prefix, not a claim to
    # retain every event type or the full captured scene.
    events=[];returns=0;scanned=0
    for i,event in enumerate(reader.rows(actual)):
        scanned=i+1
        if i<64 or event[1] in (1,2,3):events.append(event)
        if event[1]==3:returns+=1
        if returns>=16:break
        assert i<20000000, 'bounded physical fixture could not find16 returns'
    assert events and returns==16
    with gzip.open(actual,'rb')as stream:header=stream.read(16)
    raw=header+b''.join(reader.EVENT.pack(*row)for row in events)
    fixture=fixtures/'actual-ac-event-prefix.gz';fixture.write_bytes(gzip.compress(raw,mtime=0))
    assert list(reader.rows(fixture))==events
    fixture_rows=reader.rows
    reader.capture=lambda case,name: fixture
    baseline,_=reader.bus('B1');assert baseline['error_count']==0,baseline
    accepted=next(i for i,row in enumerate(events)if row[1]==2)
    mutated=list(events);row=list(mutated[accepted]);row[3]^=1;mutated[accepted]=tuple(row)
    reader.rows=lambda path:iter(mutated)
    failure,_=reader.bus('B1')
    assert failure['error_count']>0 and any(e['kind']=='accepted_descriptor_changed'for e in failure['protocol_errors'])
    rejected.append('actualaccepted-physical-descriptor-changed')
    reader.rows=fixture_rows
    bad=fixtures/'actual-ac-event-prefix-no-footer.gz';bad.write_bytes(fixture.read_bytes()[:-8])
    try:list(reader.rows(bad))
    except (EOFError,gzip.BadGzipFile):rejected.append('actualprefix-gzip-footer-missing')
    else:raise AssertionError('missing footer survived')
    return dict(actual_state_source=str(source),actual_state_sha256=sha(source),
        actual_bus_source=str(actual),actual_full_bus_sha256=manifest['capture.bus.gz']['sha256'],
        actual_selected_events=len(events),actual_source_records_scanned=scanned,
        selection='first64 events plus every kind1/2/3 through16 returns; physical-channel prefix only',
        qualified_reader_sha256={p.name:sha(p)for p in host.glob('*.py')},
        positive_extent=107,positive_physical_error_count=baseline['error_count'],
        observable_mutations_rejected=rejected,models_executed=0,
        scope='Actual OLD-source retained observables exercise reader/ABI controls only; currentmain60 capture not compiled or qualified')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base',required=True,type=Path)
    parser.add_argument('--qualified',type=Path)
    parser.add_argument('--offline',action='store_true')
    args=parser.parse_args();base=args.base.resolve()
    source=check_source(base)
    mutations=source_mutations(base)
    if args.offline:
        previous=json.loads((base/'capture-source-check.json').read_text())
        assert mutations==previous['source_mutations_rejected']
        sys.path.insert(0,str(base/'checker-bindings'))
        import storage_pair_capture_analyze as reader
        rows=reader.rows
        fixture=base/'observable-fixtures/actual-ac-event-prefix.gz'
        events=list(rows(fixture));assert events
        reader.capture=lambda case,name:fixture
        baseline,_=reader.bus('B1');assert baseline['error_count']==0
        index=next(i for i,event in enumerate(events)if event[1]==2)
        mutated=list(events);event=list(mutated[index]);event[3]^=1;mutated[index]=tuple(event)
        reader.rows=lambda path:iter(mutated)
        failure,_=reader.bus('B1')
        assert failure['error_count']>0 and any(e['kind']=='accepted_descriptor_changed'for e in failure['protocol_errors'])
        reader.rows=rows
        try:list(rows(base/'observable-fixtures/actual-ac-event-prefix-no-footer.gz'))
        except (EOFError,gzip.BadGzipFile):pass
        else:raise AssertionError('missing footer survived offline')
        assert len((base/'observable-fixtures/actual-ac106.states.jsonl').read_text().splitlines())==107
        previous['source']=source
        write(base/'capture-source-check.json',previous)
        print(json.dumps(dict(offline='PASS',source=source,source_mutations_rejected=mutations,
            observable_mutations_rejected=previous['observable']['observable_mutations_rejected'],models_executed=0),indent=2))
        raise SystemExit(0)
    assert args.qualified
    observable=observable_fixture(base,args.qualified.resolve())
    write(base/'capture-source-check.json',dict(source=source,observable=observable,source_mutations_rejected=mutations,
        current_runtime='UNKNOWN; pending next required game build and per-clause diagnostics'))
    print(json.dumps(dict(source=source,source_mutations_rejected=mutations,
        observable_mutations_rejected=observable['observable_mutations_rejected']),indent=2))
