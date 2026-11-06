#!/usr/bin/env python3
"""Validate a coordinator's post-build binary pin and game argv; never execute."""
import argparse
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate(base, model_pin, command, scene):
    manifest_path=base/'composition.json'
    manifest=json.loads(manifest_path.read_text())
    plan=json.loads((base/'game-build-plan.json').read_text())
    assert model_pin['build_exit']==0, 'shared game build incomplete'
    assert model_pin['source']==manifest['source'], 'wrong source pin'
    assert model_pin['composition_sha256']==sha(manifest_path), 'wrong composed actor/input binding'
    assert model_pin['game_build_plan_sha256']==manifest['build_plan_sha256']==sha(base/'game-build-plan.json'), 'wrong game build command'
    assert model_pin['actual_compile_argv_sha256']==hashlib.sha256(json.dumps(plan['argv']).encode()).hexdigest(), 'actual compiler argv differs'
    for name,digest in manifest['copies_sha256'].items():
        assert sha(base/name)==digest, ('bound source/include/observer/input changed',name)
    binary=Path(model_pin['binary_path']).resolve()
    assert binary.exists(), 'actual built model required'
    with binary.open('rb')as stream:assert stream.read(4)==b'\x7fELF', 'actual built model ELF required'
    assert sha(binary)==model_pin['binary_sha256'], 'binary hash mismatch'
    assert Path(command[0]).resolve()==binary, 'launch does not select pinned binary'
    args={}
    for value in command[1:]:
        if value.startswith('+') and '=' in value:
            k,v=value[1:].split('=',1)
            assert k not in args, ('duplicate argument',k)
            args[k]=v
    assert '+combined_wram_restore' in command, 'WRAM opt-in required for this game import'
    assert scene in manifest['scene_import_files'], 'scene input not bound'
    for file,digest in manifest['scene_import_files'][scene].items():
        key=file.removesuffix('.hex')
        assert sha(Path(args[key]))==digest, ('original game import input differs',key)
    contract=json.loads((base/'wram-input-contract.json').read_text())
    assert sha(args['combined_wram_expected'])==contract['scenes'][scene]['expected_sha256'], 'expected WRAM image differs'
    assert 'sound_v2_command' not in args, 'game import must not enable sound ROI actor'
    assert args.get('combined_wram_fault','none') in ('none','wrong-private','wrong-shared','missing-private','missing-shared'), 'unsupported WRAM fault'
    if 'g3d_seed' in args:
        assert scene=='hg-title' and args.get('g3d_seed_kind')=='hg193'
        history=json.loads((base/'include/history-control-preparation.json').read_text())
        for name,digest in history['generated_sha256'].items():
            if name.endswith('.hex') and name!='sd-packets.hex':
                assert sha(Path(args['g3d_seed'])/name)==digest, ('retained HG history differs',name)
        assert sha(Path(args['g3d_seed'])/'sd-packets.hex')==history['generated_sha256']['sd-packets.hex']
        assert args.get('frames')=='85' and args.get('imp_vcount')=='193', 'HG fixed window differs'
    return dict(state='POST_BUILD_SOURCE_INPUT_BINARY_GUARDS_PASS_RUNTIME_NOT_EXECUTED',scene=scene,
                source=manifest['source'],model_sha256=model_pin['binary_sha256'],argv=command,
                runtime_wram_equality='UNKNOWN until actual candidate readback/fault controls',models_executed=0)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--composition',required=True,type=Path)
    parser.add_argument('--model-pin',required=True,type=Path)
    parser.add_argument('--argv-json',required=True,type=Path)
    parser.add_argument('--scene',required=True)
    args=parser.parse_args()
    print(json.dumps(validate(args.composition.resolve(),json.loads(args.model_pin.read_text()),
                             json.loads(args.argv_json.read_text()),args.scene),indent=2))
