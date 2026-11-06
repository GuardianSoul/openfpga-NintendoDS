#!/usr/bin/env python3
"""Copy and bind the coordinator-supplied native60 actor; NEVER build/run it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

import prepare


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def adapt(text):
    edits = []

    def change(old, new):
        assert text.count(old) == 1, old[:100]
        edits.append((old, new))
        return text.replace(old, new)

    gate = '    initial if ($test$plusargs("sound_v2_command=") && $value$plusargs("imp_main=%s", imp_f)) begin'
    text = change(gate, '    initial if (\n`ifdef COMBINED_STATE_IMPORT\n'
        '        ($test$plusargs("combined_wram_restore") || $test$plusargs("sound_v2_command="))\n'
        '`else\n        $test$plusargs("sound_v2_command=")\n`endif\n'
        '        && $value$plusargs("imp_main=%s", imp_f)) begin')
    clean = '    initial if (!$test$plusargs("sound_v2_command=")) begin'
    text = change(clean, '    initial if (!$test$plusargs("sound_v2_command=")\n'
        '`ifdef COMBINED_STATE_IMPORT\n        && !$test$plusargs("combined_wram_restore")\n`endif\n    ) begin')
    old_wram = ('        if (dut.A7_WRAM != 0) begin\n'
        '            for (integer w = 0; w < 32\'h4000; w++) dut.ds.u_wram.u_private.mem[w] = imp_sram[w];\n'
        '            for (integer w = 0; w < 32\'h2000; w++) dut.ds.u_wram.u_shared.mem[w] = imp_sram[32\'h4000 + w];\n'
        '        end')
    text = change(old_wram, '`ifdef COMBINED_STATE_IMPORT\n'
        '        if(combined_wram_present)combined_restore_wram();\n        else begin\n`endif\n' +
        old_wram + '\n`ifdef COMBINED_STATE_IMPORT\n        end\n`endif')
    schedule = ('        repeat (4000) @(posedge dut.clk_sys);\n'
        '        while (!(dut.line_start && dut.vcount == imp_vc)) @(posedge dut.clk_sys);')
    text = change(schedule, '`ifdef HG193_COMBINED_HOOK\n        if(hg193_combined_present)begin\n'
        '            repeat(3999)@(posedge dut.clk_sys);@(negedge dut.clk_sys);\n'
        '            while(!(dut.line_start && dut.vcount==imp_vc))begin\n'
        '                @(posedge dut.clk_sys);@(negedge dut.clk_sys);\n            end\n'
        '            hg193_combined_publish();@(posedge dut.clk_sys);\n'
        '        end else begin\n`endif\n' + schedule + '\n`ifdef HG193_COMBINED_HOOK\n        end\n`endif')
    finish = '        // (a game has no result block: no verdict)'
    text = change(finish, '`ifdef COMBINED_STATE_IMPORT\n'
        '        if(combined_wram_present)begin\n'
        '            assert(combined_wram_applied && imp_frame>=0)else $fatal(1,"COMBINED_IMPORT_NOT_RELEASED");\n'
        '`ifdef HG193_COMBINED_HOOK\n'
        '            if(hg193_combined_present)assert(hg193_applied)else $fatal(1,"HG193_HISTORY_NOT_PUBLISHED");\n'
        '`endif\n        end\n`endif\n' + finish)
    text = change('endmodule', '`include "runtime_combined_wram.svh"\n'
        '`include "hg193_combined_hook.svh"\nendmodule')
    return text, edits


def compose(tb, root, out):
    root, tb, out = root.resolve(), tb.resolve(), out.resolve()
    assert root in tb.parents and root not in out.parents and out != root
    metadata = {n: root / n for n in ('profile.json', 'build-command.json',
        'compile-host-frozen.json', 'compile-release.json', 'source-manifest.json', 'joint-source-guard.json')}
    blobs = {n: p.read_bytes() for n, p in metadata.items()}
    profile = json.loads(blobs['profile.json'])
    build = json.loads(blobs['build-command.json'])
    frozen = json.loads(blobs['compile-host-frozen.json'])
    released = json.loads(blobs['compile-release.json'])
    production = json.loads(blobs['source-manifest.json'])
    assert build['source'] == frozen['source'] == production['source'] == prepare.TARGET
    assert len(profile) == 60 and profile == build['profile']
    if 'profile' in frozen:
        assert profile == frozen['profile']
    argv = build['argv']
    assert released['source'] == prepare.TARGET
    assert released['build_command_sha256'] == prepare.sha(blobs['build-command.json'])
    active = json.loads((root / 'build.active.json').read_text())
    assert active['argv'] == argv
    # The first failed compiler's freeze remains a historical receipt. The
    # successful retry explicitly replaced the CPU observer and its readers.
    retired = {n: {'frozen': h, 'released': released['host_sha256'][n]}
               for n, h in frozen['host_sha256'].items()
               if released['host_sha256'][n] != h}
    allowed_refresh = {'host-inputs/actual-source-guard.json', 'host-inputs/source-ready.json',
        'host-inputs/ldm53_observer_plan.json', 'host-inputs/source-check.json',
        'host-observer/tools/scorecard/ldm53_observer_plan.json',
        'host-observer/tools/scorecard/ldm53_observer_selftest.py',
        'host-observer/tools/scorecard/ldm53_observer.py',
        'host-observer/sim/pocket_ds/ldm53_observer.sv'}
    assert set(retired) <= allowed_refresh, retired
    assert build['host_observer_ref'] == 'e1337f1f711d9543272fefe333a60b68f3c059ed'
    assert released['host_sha256']['host-observer/sim/pocket_ds/ldm53_observer.sv'] == \
        '49355f602164b535a9ab4bedfcf20df14c64aaf8b2cd5b9ae8eedf213f7b6391'
    params = next(a for a in argv if a.startswith('+define+TB_CORE_PARAMS='))
    assert {k: int(v) for k, v in re.findall(r'\.(\w+)\((\d+)\)', params)} == profile
    relative_tb = str(tb.relative_to(root))
    assert argv.count(str(tb)) == 1 and digest(tb) == frozen['host_sha256'][relative_tb]
    before_tb = tb.read_bytes()
    actual_files = {str(p.relative_to(root)): p for a in argv
                   if a.endswith(('.sv', '.v', '.cpp', '.cc')) for p in [Path(a)]}
    assert all(p.exists() and root in p.parents for p in actual_files.values())
    for name, path in actual_files.items():
        if name.startswith('source/'):
            assert digest(path) == production['files'][name.removeprefix('source/')], name
    for name, expected in released['host_sha256'].items():
        assert digest(root / name) == expected, name
        actual_files[name] = root / name
    includes = [Path(a[2:]) for a in argv if a.startswith('-I')]
    pending = list(actual_files.values())
    while pending:
        path = pending.pop()
        if path.suffix not in ('.sv', '.v', '.svh', '.vh'):
            continue
        for include in re.findall(r'`include\s+"([^"\n]+)"', path.read_text()):
            candidates = [d / include for d in [root / 'source', *includes, path.parent]]
            found = list(dict.fromkeys(p.resolve() for p in candidates if p.is_file()))
            assert found, (path, include)
            assert len({digest(p) for p in found}) == 1, ('ambiguous include', include)
            for p in found:
                assert root in p.parents
                name = str(p.relative_to(root))
                if name not in actual_files:
                    actual_files[name] = p
                    pending.append(p)
    inputs_before = {name: digest(p) for name, p in actual_files.items()}
    inputs_before.update({n: prepare.sha(data) for n, data in blobs.items()})
    previous_path=out/'composition.json'
    previous=json.loads(previous_path.read_text()) if previous_path.exists() else None
    rebind=None
    if previous and previous['donor_inputs_sha256']!=inputs_before:
        history=out/'previous-bindings';history.mkdir(exist_ok=True)
        old_digest=digest(previous_path)
        shutil.copyfile(previous_path,history/(old_digest+'.json'))
        rebind=dict(previous_composition_sha256=old_digest,
            changed_parent_inputs=[n for n,h in inputs_before.items() if previous['donor_inputs_sha256'].get(n)!=h],
            observer_ref=build.get('host_observer_ref'),
            scope='Explicit staged observer refresh for NEXT game build; no active-kernel binary identity inferred')
    prepare.prepare(out)  # History/input controls only; never a compiler/model.
    (out/'manifest.json').rename(out/'raw-source-control-manifest.json')
    snapshot = out / 'snapshot'
    for name, path in actual_files.items():
        dest = snapshot / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
    for name, data in blobs.items():
        (snapshot / name).write_bytes(data)
    composed, edits = adapt(before_tb.decode())
    private_tb = out / 'observed-overlay/tb_native52_import.sv'
    private_tb.parent.mkdir(exist_ok=True)
    private_tb.write_text(composed)
    reconstructed = composed
    for old, new in reversed(edits):
        assert reconstructed.count(new) == 1
        reconstructed = reconstructed.replace(new, old)
    assert reconstructed.encode() == before_tb
    # Bind the actual observed source/profile at compile time. Binary identity
    # is a separate required launcher pin AFTER the next game build succeeds.
    compiled_binding = prepare.sha(json.dumps(inputs_before, sort_keys=True).encode())
    pin = ['`ifndef COMBINED_SHARED_MODEL_BINDING_SVH', '`define COMBINED_SHARED_MODEL_BINDING_SVH',
           f'localparam string COMBINED_BOUND_SOURCE="{prepare.TARGET}";',
           f'localparam string COMBINED_BOUND_INPUTS_SHA256="{compiled_binding}";',
           'task automatic assert_hg193_shared_model_binding;']
    for name, value in sorted(profile.items()):
        pin += [f' if(dut.{name}!=={value})$fatal(1,"COMBINED_SHARED_PROFILE_MISMATCH {name}");']
    pin += [' if(ROM_AW!=25)$fatal(1,"COMBINED_GAME_ROM_AW_REQUIRED_25");', 'endtask', '`endif', '']
    (out / 'include/hg193_shared_model_binding.svh').write_text('\n'.join(pin))
    candidate = []
    for arg in argv:
        if arg == str(tb):
            arg = str(private_tb)
        elif arg.startswith(str(root) + '/'):
            arg = str(snapshot / Path(arg).relative_to(root))
        elif arg.startswith('-I' + str(root) + '/'):
            arg = '-I' + str(snapshot / Path(arg[2:]).relative_to(root))
        if arg == '-GROM_AW=24':
            arg = '-GROM_AW=25'
        candidate.append(arg)
    candidate[candidate.index('--Mdir') + 1] = str(out / 'private-game-obj')
    candidate[1:1] = ['--assert', '-I' + str(out / 'include'),
        '+define+COMBINED_STATE_IMPORT', '+define+COMBINED_WRAM_FAULTS', '+define+HG193_COMBINED_HOOK']
    plan = dict(state='SOURCE_ONLY_NEXT_REQUIRED_GAME_BUILD_NOT_EXECUTED', source=prepare.TARGET,
        full_profile=profile, argv=candidate, cwd=str(snapshot / 'source'), model_sha256=None,
        changes=['private observed TB composition only', '--assert required for readback/fault checks',
                 'opt-in combined WRAM/HG and dormant fault controls', 'ROM_AW24→25 for existing128MiB HG input',
                 'private output directory/include path; all other donor compiler inputs/order retained'])
    write(out / 'game-build-plan.json', plan)
    write(out / 'edits.json', [dict(old=a, new=b) for a, b in edits])
    assert all(digest(root / name) == expected for name, expected in inputs_before.items())
    copies = {str(p.relative_to(out)): digest(p) for folder in ['snapshot', 'observed-overlay', 'include', 'wram-expected']
              for p in (out / folder).rglob('*') if p.is_file()}
    binding = dict(state='OBSERVED_SOURCE_PROFILE_COMPOSED_BINARY_AND_RUNTIME_UNQUALIFIED',
        source=prepare.TARGET, donor_root=str(root), donor_tb=str(tb),
        actual_observed_tb_sha256=prepare.sha(before_tb), profile_fields=60, profile=profile,
        donor_inputs_sha256=inputs_before, compiled_input_binding_sha256=compiled_binding,
        donor_default_reconstruction_sha256=prepare.sha(reconstructed.encode()),
        donor_untouched=True, copies_sha256=copies,
        build_plan_sha256=digest(out / 'game-build-plan.json'),
        edits_sha256=digest(out / 'edits.json'), binary_sha256=None,
        captures='All observed actor bytes outside six guarded edit sites retained; all original includes/observer files copied unchanged',
        game_import='existing WRAM deposit wrapped, sound-only IMPORT selector extended only for combined request; competing CLEAN_BOOT suppressed only for combined request',
        raw_source_control='raw-source-control-manifest.json is the prior146 actor control, not the observed composition authority',
        runtime_wram_equality='UNKNOWN; positive and actual wrong/missing-deposit controls remain for shared game candidate',
        observer_inputs='donor/VRC/publicbind/CPUraw exact current staged files and metadata retained',
        host_observer_ref=build.get('host_observer_ref'),explicit_parent_rebind=rebind,
        native60_current_chain='Unmodified; no build/model/worker started by composition',
        parent_compiler_observation=active,
        receipt_reconciliation={'current_compile_release_sha256':prepare.sha(blobs['compile-release.json']),
            'actual_build_command_sha256':prepare.sha(blobs['build-command.json']),
            'earlier_host_freeze_command_sha256':frozen['build_command_sha256'],
            'added_release_host_files':sorted(set(released['host_sha256'])-set(frozen['host_sha256'])),
            'superseded_failed_compile_host_inputs':retired,
            'basis':'Current compile-release binds actual command; active compiler argv matches. Historical failed-compile receipt retained with explicit e133 observer/readers replacement; all other overlapping bytes equal. Profile independently equals profile.json/build metadata/all60 compiled arguments.'},
        next='Use next required game build only; launcher must bind successful actual binary to this build-plan/composition and validate inputs before any run')
    contract=json.loads((out/'wram-input-contract.json').read_text())
    binding['scene_import_files']={name:{file:digest(Path(row['existing_imp_sram_path']).parent/file)
        for file in ('imp_main.hex','imp_real.hex','imp_vram.hex','imp_sram.hex')}
        for name,row in contract['scenes'].items()}
    write(out / 'composition.json', binding)
    write(out/'model-pin.pending.json',dict(state='PENDING_ACTUAL_NEXT_GAME_BUILD',
        source=prepare.TARGET,composition_sha256=digest(out/'composition.json'),
        game_build_plan_sha256=binding['build_plan_sha256'],
        actual_compile_argv_sha256=prepare.sha(json.dumps(candidate).encode()),
        build_exit=None,binary_path=None,binary_sha256=None))
    return binding


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tb', required=True, type=Path)
    parser.add_argument('--host-root', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    b = compose(args.tb, args.host_root, args.out)
    print(json.dumps({k: b[k] for k in ('state', 'actual_observed_tb_sha256', 'profile_fields', 'compiled_input_binding_sha256', 'donor_untouched', 'runtime_wram_equality')}, indent=2))
