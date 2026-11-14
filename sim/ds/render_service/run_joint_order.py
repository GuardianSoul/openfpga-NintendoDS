#!/usr/bin/env python3
"""Check the actual capture fences at the accepted VRAM interface."""
from pathlib import Path
import json
import sys

from run import V, run

def main():
    source = Path(sys.argv[1]).resolve()
    out = source / 'order'
    out.mkdir(exist_ok=False)
    manifest = json.loads((source / 'source.json').read_text())
    for name in ('gpu2d_pkg.sv', 'nds_vram.sv'):
        assert run.sha(source / name) == manifest['files'][name]
    test = Path(__file__).with_name('joint_capture_order.sv').resolve()
    command = [V, '--binary', '--timing', '--assert', '--threads', '1', '-j', '1', '-O1',
               '--compiler', 'clang', '-CFLAGS', '-std=c++20 -O0', '-MAKEFLAGS',
               'CXX=clang++ VM_PARALLEL_BUILDS=1', '-Wno-fatal', '--top-module',
               'joint_capture_order', '--Mdir', out / 'obj', source / 'gpu2d_pkg.sv',
               source / 'nds_vram.sv', test]
    rc, log = run.worker(out, 'build', command, build=True, growth=64 << 20, seconds=120)
    if rc:
        print(log[-4000:])
        raise SystemExit(rc)
    binary = out / 'obj/Vjoint_capture_order'
    cases = [('order', [], 'JOINT_CAPTURE_ORDER_PASS'),
             ('alias-fault', ['+fault_joint_capture_alias'], 'YOUNGER_ALIAS_OFFER')]
    if manifest.get('register_on_finish'):
        cases.append(('finish-owner-fault', ['+fault_joint_capture_finish_owner'],
                      'BLOCK_OWNER_OR_DATA'))
    result = {}
    for name, flags, expected in cases:
        rc, log = run.worker(out, name, [binary, *flags], growth=4 << 20, seconds=30)
        passed = expected in log and (rc == 0 if not flags else rc != 0)
        result[name] = dict(PASS=passed, returncode=rc, expected=expected)
        print(log[-1500:])
        assert passed, name
    run.put(out / 'result.json', dict(PASS=True, source_sha256=run.sha(source / 'nds_vram.sv'),
        fixture_sha256=run.sha(test), model_sha256=run.sha(binary), cases=result,
        scope='Actual captured read owners and posted physical alias/retirement against independent memory model'))

if __name__ == '__main__':
    main()
