#!/usr/bin/env python3
"""Compare joint capture on the fixed, frozen e63 game inputs."""
import json
from pathlib import Path
import shutil
import sys

from run import run

ROOT = Path('/home/user/Git/NDS_Pocket')
CONTROL = ROOT / 'build/rc053-elastic-ring-games'
TAG = 'final-elastic-banked-ring-capture'
FROZEN = CONTROL / f'frozen-model-{TAG}-source'
VARIANT = 'joint-capture-v2'

def load(path):
    return json.loads(path.read_text())

def prepare(out, component):
    out.mkdir(parents=True, exist_ok=False)
    manifest = load(CONTROL / f'model-{TAG}.json')
    assert manifest['source'] == 'e63b56125c40c94b849ddaf35a8e4d3d975803a7'
    sources = out / 'source'
    before = {}
    for entry in manifest['sources']:
        original = Path(entry['frozen_source'])
        assert run.sha(original) == entry['sha256']
        relative = original.relative_to(FROZEN)
        dest = sources / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, dest)
        before[str(relative)] = entry['sha256']

    def edit(name, old, new):
        path = sources / name
        content = path.read_text()
        assert content.count(old) == 1, (name, old, content.count(old))
        path.write_text(content.replace(old, new))

    component_manifest = load(component / 'source.json')
    for local, relative in [('nds_vram.sv', 'rtl/ds/nds_vram.sv'),
                            ('nds_ring_post_arb.sv', 'rtl/pocket/nds_ring_post_arb.sv')]:
        assert run.sha(component / local) == component_manifest['files'][local]
        assert before[relative] == component_manifest['original'][local], relative
        text = (component / local).read_text()
        text = text.replace('cap_a0 ^ $test$plusargs("fault_joint_capture_mask")', 'cap_a0')
        text = text.replace(' && !$test$plusargs("fault_joint_capture_alias")', '')
        (sources / relative).write_text(text)

    top = 'rtl/ds/nds_top.sv'
    edit(top, '    parameter integer CAP_CHAIN = 0,', '    parameter bit CAP_JOINT = 0,\n    parameter integer CAP_CHAIN = 0,')
    edit(top, '    output logic        cw_valid,', '''    output logic cw_is_capture, capture_dependency, capture_2d_work, capture_2d_done,
    output logic        cw_valid,''')
    edit(top, '    nds_vram #(.CAP_CHAIN(', '''    logic [1:0] capture_2d_owned, capture_2d_beat;
    assign capture_2d_done = d_rvalid && capture_2d_beat == 3;
    assign capture_2d_work = d_req || capture_2d_owned != 0;
    always_ff @(posedge clk) begin
        if (rst) begin
            capture_2d_owned <= 0;
            capture_2d_beat <= 0;
        end else begin
            capture_2d_owned <= capture_2d_owned + 2'(d_ack) - 2'(capture_2d_done);
            if (d_rvalid) capture_2d_beat <= capture_2d_beat + 1'b1;
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (!rst && CAP_JOINT && capture_2d_done && capture_2d_owned == 0)
            $fatal(1,"CAPTURE_UNOWNED_2D_BLOCK");
`endif
    nds_vram #(.CAP_CHAIN(''')
    edit(top, '.cap_we, .cap_addr, .cap_data, .cap_ready, .cw_valid,',
         '.cap_we, .cap_addr, .cap_data, .cap_ready, .joint_capture(CAP_JOINT), .cw_is_capture, .capture_dependency, .cw_valid,')

    core = 'rtl/pocket/core_top_ds.sv'
    edit(core, '    parameter integer CAP_CHAIN = 1,', '    parameter bit CAP_JOINT = 0,\n    parameter integer CAP_CHAIN = 1,')
    edit(core, '    wire        cw_valid, cw_ack;', '''    wire cw_is_capture, capture_dependency, capture_2d_work, capture_2d_done;
    localparam bit CAP_JOINT_ACTIVE = CAP_JOINT && G3D_RDEADLINE != 0 && CAP_CHAIN != 0 &&
        VR_PASS != 0 && VR_PH != 0 && VR_PDRAIN != 0 && VR_PF == 0;
    wire        cw_valid, cw_ack;''')
    edit(core, 'nds_top #(.G3D_FRPOOL(', 'nds_top #(.CAP_JOINT(CAP_JOINT_ACTIVE), .G3D_FRPOOL(')
    edit(core, '.cw_valid(cw_valid), .cw_addr(cw_addr)',
         '.cw_is_capture, .capture_dependency, .capture_2d_work, .capture_2d_done, .cw_valid(cw_valid), .cw_addr(cw_addr)')
    edit(core, 'nds_ring_post_arb post_arb (.clk(clk_sys), .reset(rst_sys),', '''nds_ring_post_arb post_arb (.clk(clk_sys), .reset(rst_sys),
            .joint_capture(CAP_JOINT_ACTIVE), .read_work(capture_2d_work), .read_done(capture_2d_done),
            .capture_data(cw_is_capture), .capture_dependency,''')
    after = {name: run.sha(sources / name) for name in before}
    assert {name for name in before if before[name] != after[name]} == {
        'rtl/ds/nds_top.sv', 'rtl/ds/nds_vram.sv', 'rtl/pocket/core_top_ds.sv', 'rtl/pocket/nds_ring_post_arb.sv'}
    run.put(out / 'source.json', dict(source=manifest['source'], before=before, files=after,
        component_source_sha256=run.sha(component / 'source.json'),
        control_model_sha256=manifest['sha256'],
        scope='Same e63 game model and fixed controls. Work is held 2D request or accepted owner outstanding.'))

def build(out):
    manifest = load(out / 'source.json')
    for name, digest in manifest['files'].items():
        assert run.sha(out / 'source' / name) == digest
    old = load(CONTROL / f'build-{TAG}.process.json')['command']
    command = [arg.replace(str(FROZEN), str(out / 'source')) for arg in old]
    command[command.index('--Mdir')+1] = str(out / 'obj')
    assert all('TB_CORE_PARAMS' not in arg for arg in command)
    command += ['+define+TB_CORE_PARAMS=, .CAP_JOINT(1)']
    # Retained build produced 272 MB of generated files including pruned objects.
    rc, log = run.worker(out, 'game-build', command, build=True, growth=512 << 20, seconds=1800)
    if rc:
        print(log[-6000:])
        raise SystemExit(rc)
    binary = out / 'obj/Vtb_ds_pocket'
    run.put(out / 'model.json', dict(source_sha256=run.sha(out / 'source.json'), binary_sha256=run.sha(binary)))
    print('GAME_BUILD_PASS', run.sha(binary))

def scene(out, name):
    control = CONTROL / f'{name}-{TAG}-observe'
    baseline = load(control / 'run.json')
    proc = load(control / 'run.process.json')
    cwd = Path(proc['cwd'])
    for entry in load(cwd / 'ready.json')['files']:
        assert run.sha(Path(entry['path'])) == entry['sha256'], entry['path']
    dest = out / name
    dest.mkdir(exist_ok=False)
    (dest / 'shots').mkdir()
    model = load(out / 'model.json')
    binary = out / 'obj/Vtb_ds_pocket'
    assert run.sha(binary) == model['binary_sha256']
    control_model = load(CONTROL / f'model-{TAG}.json')['model']
    assert proc['command'].count(control_model) == 1
    command = ['env', '--chdir='+str(cwd)]
    command.extend(str(binary) if arg == control_model else arg.replace(str(control), str(dest))
                   for arg in proc['command'])
    rc, log = run.worker(dest, 'run', command, growth=256 << 20, seconds=5400)
    result = dict(baseline, variant=VARIANT, rc=rc, model_sha256=model['binary_sha256'], control=str(control))
    run.put(dest / 'run.json', result)
    print(log[-1800:])
    if rc:
        raise SystemExit(rc)
    rc, log = run.worker(dest, 'analysis', ['python3', ROOT / 'tools/scorecard/raster_symptom_report.py', dest],
                         growth=32 << 20, seconds=180)
    print(log[-1800:])
    assert rc == 0

if __name__ == '__main__':
    action, path, *rest = sys.argv[1:]
    target = Path(path).resolve()
    if action == 'prepare':
        prepare(target, Path(rest[0]).resolve())
    elif action == 'build':
        build(target)
    else:
        assert action in ('race', 'title', 'battle')
        scene(target, action)
