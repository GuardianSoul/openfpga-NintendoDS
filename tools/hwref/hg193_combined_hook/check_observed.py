#!/usr/bin/env python3
"""Source/default identity checks only; no compiler or simulation."""
import argparse
import hashlib
import json
from pathlib import Path

import verify_game_launch


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity(text, edits, original_sha):
    for edit in reversed(edits):
        assert text.count(edit['new'])==1
        text=text.replace(edit['new'],edit['old'])
    assert hashlib.sha256(text.encode()).hexdigest()==original_sha


def check(base):
    binding=json.loads((base/'composition.json').read_text())
    plan=json.loads((base/'game-build-plan.json').read_text())
    assert len(binding['profile'])==60 and plan['full_profile']==binding['profile']
    assert binding['binary_sha256'] is None and plan['model_sha256'] is None
    for name,digest in binding['copies_sha256'].items():assert sha(base/name)==digest,name
    edits=json.loads((base/'edits.json').read_text())
    tb=(base/'observed-overlay/tb_native52_import.sv').read_text()
    identity(tb,edits,binding['actual_observed_tb_sha256'])
    pin=(base/'include/hg193_shared_model_binding.svh').read_text()
    assert 'not pinned; source prep only' not in pin
    for name,value in binding['profile'].items():
        assert f'if(dut.{name}!=={value})' in pin,name
    assert binding['compiled_input_binding_sha256'] in pin
    assert '--assert' in plan['argv'] and '-GROM_AW=25' in plan['argv']
    for define in ('COMBINED_STATE_IMPORT','COMBINED_WRAM_FAULTS','HG193_COMBINED_HOOK'):
        assert '+define+'+define in plan['argv']
    rejected=[]
    for name,mutant in [
        ('dropped-public-route-capture',tb.replace('NATIVE60_WRITE_TURN_ROUTE_PASS','REMOVED')),
        ('duplicate-deposit-bypasses-fault',tb.replace('if(combined_wram_present)combined_restore_wram();\n        else begin',
                                                     'if(combined_wram_present)combined_restore_wram();\n        begin')),
        ('competing-clean-boot-not-suppressed',tb.replace('&& !$test$plusargs("combined_wram_restore")','&& 1\'b1'))]:
        try:identity(mutant,edits,binding['actual_observed_tb_sha256'])
        except AssertionError:rejected.append(name)
        else:raise AssertionError('actor identity mutation survived: '+name)
    pending=json.loads((base/'model-pin.pending.json').read_text())
    try:verify_game_launch.validate(base,pending,['unbuilt'], 'hg-title')
    except AssertionError as e:
        assert str(e)=='shared game build incomplete';rejected.append('unbuilt-binary-launch')
    else:raise AssertionError('pending binary was accepted')
    capture_inputs=[n for n in binding['donor_inputs_sha256'] if any(s in n for s in
        ['host-observer','host-overlay','host-sound51','host-inputs','witness.svh'])]
    result=dict(state='OBSERVED_ACTOR_SOURCE_IDENTITY_AND_BINDINGS_PASS_RUNTIME_UNKNOWN',
        actual_observed_tb_sha256=binding['actual_observed_tb_sha256'],
        reconstructed_default_sha256=binding['donor_default_reconstruction_sha256'],
        core_profile_fields=60,copied_bound_inputs=len(binding['copies_sha256']),
        donor_capture_inputs_preserved=len(capture_inputs),source_mutations_rejected=rejected,
        shared_startup_binding='actual source/profile/compiled input bytes; fatal placeholder replaced',
        binary_guard='pending successful next game build; unbuilt launch rejected',
        compiler_or_model_runs=0,donor_untouched=True,
        runtime_internal_wram_equality='UNKNOWN',game_or_HG_qualification='NOT_RUN')
    (base/'observed-source-check.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base',required=True,type=Path)
    check(parser.parse_args().base.resolve())
