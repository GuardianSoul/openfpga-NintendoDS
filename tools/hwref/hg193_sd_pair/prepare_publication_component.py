#!/usr/bin/env python3
"""Generate a component fixture from actual full-profile elaboration constants."""
import argparse
import hashlib
import json
from pathlib import Path

import prepare


def emit(base):
    binding, images, profile = prepare.bound_inputs()
    resolved = json.loads((base / 'resolved-gpu-parameters.json').read_text())
    assert resolved['source'] == binding['source']
    assert len(resolved['actual_gpu_cells']) == 1
    assert resolved['actual_gpu_cells'][0]['modName'] == resolved['actual_gpu_module']
    out = base / 'fixture'
    out.mkdir(exist_ok=True)
    (out / 'component_profile_parameters.svh').write_text(',\n'.join(
        f' parameter integer {name}={value}' for name, value in sorted(profile.items())) + '\n')
    (out / 'component_gpu_parameters.svh').write_text(',\n'.join(
        f' .{name}({value})' for name, value in resolved['parameters'].items()) + '\n')
    snapshot = ['task automatic initialize_snapshot_fixture;',
                " `C_FIN.slot_version=96'hf0f00f0fa55a5aaacccc3333;",
                " for(int e=0;e<4;e++)begin `C_FIN.snapshot_slot[e]=3'((e+2)%6);",
                "  `C_FIN.snapshot_version[e]=16'ha55a^(16'(e)<<4);end"]
    for word in range(16):
        path = f'`C_FIN.g_snapshot_word[{word}].u_word.mem'
        snapshot.append(f" for(int s=0;s<16;s++){path}[s]=32'ha5a00000^(32'({word})<<12)^32'(s);")
        snapshot.append(f" for(int s=0;s<6;s++)`C_FIN.check_slot[s][{word}]="
                        f"{path}[8*int'(`C_FIN.slot_version[16*s+{word}])+s];")
        snapshot.append(f" for(int e=0;e<4;e++)`C_FIN.check_snapshot[e][{word}]="
                        f"{path}[8*int'(`C_FIN.snapshot_version[e][{word}])+int'(`C_FIN.snapshot_slot[e])];")
    snapshot += ['endtask', 'task automatic save_inactive_snapshot_fixture(output logic[31:0]words[0:95]);']
    for word in range(16):
        path = f'`C_FIN.g_snapshot_word[{word}].u_word.mem'
        snapshot += [f" for(int s=4;s<6;s++)words[16*(s-4)+{word}]={path}[8*int'(`C_FIN.slot_version[16*s+{word}])+s];",
                     f" for(int e=0;e<4;e++)words[32+16*e+{word}]={path}[8*int'(`C_FIN.snapshot_version[e][{word}])+int'(`C_FIN.snapshot_slot[e])];"]
    snapshot += ['endtask', 'task automatic verify_inactive_snapshot_fixture(input logic[31:0]words[0:95]);',
                 ' logic[31:0]actual[0:95];save_inactive_snapshot_fixture(actual);',
                 ' for(int i=0;i<96;i++)assert(actual[i]===words[i])else $fatal(1,"unexported inactive snapshot changed %0d",i);',
                 'endtask']
    (out / 'component_snapshot_fixture.svh').write_text('\n'.join(snapshot) + '\n')
    mapping = prepare.legacy_mapping(Path(binding['legacy']['g3d_import_context597.svh']['path']).read_text())
    paths, _ = prepare.translate_context(mapping, images['context'])
    fingerprint = [f" mix(64'(`C_GPU.u_geom.{path}));" for path in sorted(paths)]
    for path, count in [('g_ext.g_pair.u_store.u_ord.mem', 4096), ('g_ext.g_pair.u_store.u_ytab.mem', 4096),
                        ('g_ext.g_pair.u_store.u_lk.mem', 2048), ('g_ext.g_pair.u_store.u_bk.mem', 256),
                        ('g_ext.g_pair.u_store.u_bkf.mem', 256), ('g_ring.u_ringx.u_stage.mem', 1024),
                        ('g_ring.u_ringx.u_rbuf.mem', 512)]:
        fingerprint.append(f" for(int i=0;i<{count};i++)mix(64'(`C_GPU.{path}[i]));")
    for word in range(16):
        fingerprint.append(f" for(int s=0;s<16;s++)mix(64'(`C_FIN.g_snapshot_word[{word}].u_word.mem[s]));")
    for path in ['g_ext.g_pair.u_store.u_journal.head', 'g_ext.g_pair.u_store.u_journal.tail',
                 'g_ext.g_pair.u_store.u_journal.wb', 'g_ext.g_pair.u_store.ready',
                 'g_ext.g_pair.u_store.rb', 'g_ext.g_pair.u_store.bank_gen[0]',
                 'g_ext.g_pair.u_store.bank_gen[1]', 'g_ext.g_pair.u_canonical.state',
                 'r_busy', 'frame_go', 'rg_wreq', 'rg_rreq', 'g_busy', 'sk_v']:
        fingerprint.append(f" mix(64'(`C_GPU.{path}));")
    (out / 'component_before_fingerprint.svh').write_text('\n'.join(fingerprint) + '\n')
    (out / 'tb_publication.sv').write_bytes((prepare.HERE / 'tb_publication.sv').read_bytes())
    # Deliberate context mutation is isolated to a separate optional test payload.
    mutant = base / 'mutant-strip'
    mutant.mkdir(exist_ok=True)
    for path in (base / 'payload').iterdir():
        if path.is_file() and path.suffix == '.hex':
            (mutant / path.name).write_bytes(path.read_bytes())
    words = images['context'].copy()
    words[3593] = 1
    prepare.write_hex(mutant / 'context.hex', words)
    files = {str(p.relative_to(base)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in out.iterdir() if p.is_file()}
    record = {'state': 'FIXTURE_STAGED', 'source': binding['source'],
              'resolved_gpu_parameters': resolved,
              'scope': 'actual frozen GPU instance with constants from full actual profile58 elaboration; isolated clocks/IO/SDRAM backing fixture, no CPU/game',
              'fingerprint': '2869 mapped paths plus banked tables, ring storage, snapshot physical words and ownership',
              'snapshot_fixture': 'nonzero values, mixed live versions, independent frozen slots/versions; check32+64 preserved',
              'files_sha256': files}
    (base / 'publication-fixture.json').write_text(json.dumps(record, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, type=Path)
    emit(parser.parse_args().base.resolve())
