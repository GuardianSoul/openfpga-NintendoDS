#!/usr/bin/env python3
"""Translate the retained HG193 images for the frozen profile58 SD pair.

Host preparation only. This never builds or executes a model, changes the
production tree, exports state, or connects itself to the ordinary importer.
The generated tasks require the enclosing coordinator's held/drained hook.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = 0x1A0000
FORMAT = 0x47335344
SEMANTIC = '32a48fc470e615e69c8cba485bde85d40a0e1a0836bcfd0121ae7d93cdd22b5b'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def bound_inputs():
    binding = json.loads((HERE / 'binding.json').read_text())
    root = Path(binding['host_root'])
    for name, sha in binding['manifests'].items():
        require(digest(root / name) == sha, 'host manifest changed: ' + name)
    compiled = json.loads((root / 'compiled-inputs.json').read_text())
    production = json.loads((root / 'production-manifest.json').read_text())
    for group in ('production', 'overlay', 'legacy'):
        for name, spec in binding[group].items():
            require(digest(spec['path']) == spec['sha256'], 'source changed: ' + name)
            if group == 'production':
                require(compiled[spec['path']] == production[name] == spec['sha256'],
                        'source not bound to compiled and production manifests: ' + name)
    tb = binding['overlay']['tb_ds_pocket.sv']
    require(compiled[tb['path']] == tb['sha256'], 'actual compiled TB differs')
    build = json.loads((root / 'build-command.json').read_text())
    param = next(a for a in build if a.startswith('+define+TB_CORE_PARAMS='))
    params = dict(re.findall(r'\.(\w+)\((\d+)\)', param))
    require(len(params) == 58 and params['G3D_STORAGE_PAIR'] == '1' and
            params['GX_DIV_P2X'] == '1', 'wrong production profile')
    payload = Path(binding['payload']['root'])
    require(digest(payload / 'manifest.json') == binding['payload']['manifest_sha256'],
            'retained payload manifest differs')
    manifest = json.loads((payload / 'manifest.json').read_text())
    require(manifest['semantic_sha256'] == SEMANTIC and manifest['seed_kind'] == 'hg193'
            and manifest['context_complete'], 'wrong retained HG payload')
    images = {}
    for name, spec in binding['payload']['files'].items():
        path = payload / (name + '.hex')
        require(digest(path) == spec['sha256'], 'retained image changed: ' + name)
        words = [int(w, 16) for w in path.read_text().split()]
        require(len(words) == spec['entries'] and
                all(0 <= w < 1 << spec['width'] for w in words), 'image shape: ' + name)
        images[name] = words
    return binding, images, params


def legacy_mapping(source):
    """Expand the accepted loader's literal loops; do not infer new semantics."""
    body = source.split('task automatic apply_context;', 1)[1].split('endtask', 1)[0]
    prefix = '$root.tb_ds_pocket.dut.ds.g_3d.u_gpu3d.u_geom.'
    result = {}
    used = set()
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        loop = re.fullmatch(r'for \(int i=0;i<(\d+);i\+\+\) (.+)', line)
        count, statement = (int(loop[1]), loop[2]) if loop else (1, line)
        match = re.fullmatch(r'(.+) = context_data\[(\d+)(\+i)?\];', statement)
        require(match is not None, 'unrecognized accepted context statement: ' + line)
        require(match[1].startswith(prefix), 'unexpected context root')
        for i in range(count):
            path = match[1][len(prefix):]
            path = re.sub(r'\[(\d+)\+i\]', lambda m: '[' + str(int(m[1]) + i) + ']', path)
            index = int(match[2]) + (i if match[3] else 0)
            require(path not in result, 'duplicate accepted context path: ' + path)
            result[path] = index
            used.add(index)
    require(used == set(range(3712)), 'accepted context coverage differs')
    return result


def packet(key, words):
    require(0 <= key < 16384 and len(words) == 4, 'canonical packet shape')
    tag = 0xC4E00000 | (key << 2)
    return list(words) + [tag, tag ^ 0xFFFFFFFF, FORMAT, 0]


def decode(key, words):
    require(len(words) == 8, 'canonical packet length')
    require(words[4:] == packet(key, [0] * 4)[4:], 'canonical address/tag/format/tail guard')
    return words[:4]


def translate_context(mapping, data):
    """Collapse old broadcast mirrors only after checking every retained alias."""
    destination = {}
    classifications = {}

    def put(path, index, kind):
        if path in destination:
            require(data[destination[path]] == data[index], 'unequal retained alias: ' + path)
        else:
            destination[path] = index
        classifications.setdefault(kind, 0)
        classifications[kind] += 1

    rf = {int(re.search(r'\[(\d+)\]$', p)[1]): i for p, i in mapping.items()
          if p.startswith('u_eng.u_rfa.mem[')}
    for path, index in mapping.items():
        clip = re.fullmatch(r'u_eng.g_cl.u_clip.g_gc\[(\d+)\].u_g.mem\[(\d+)\]', path)
        fin = re.fullmatch(r'u_eng.g_fu.u_fin.g_gc\[(\d+)\].u_g.mem\[(\d+)\]', path)
        sg = re.fullmatch(r'u_eng.g_fu.u_fin.sg\[(\d+)\]\[(\d+)\]', path)
        if clip:
            address = int(clip[2])
            require(data[index] == data[rf[0x200 + address]], 'clip mirror differs from retained RF')
            word = address % 16
            if word in (0, 1, 2, 3, 4, 5, 6, 8, 9):
                bank = word if word < 7 else word - 1
                for port in ('u_out', 'u_in'):
                    put(f'u_eng.g_cl.u_clip.g_word[{bank}].{port}.mem[{address // 16}]', index,
                        'clip full-word mirrors to nine word banks')
            else:
                classifications['clip words absent from current reader'] = classifications.get(
                    'clip words absent from current reader', 0) + 1
        elif fin:
            address = int(fin[2])
            require(data[index] == data[rf[0x200 + address]], 'finish mirror differs from retained RF')
            # Profile58 PU_DIV_P2X=1: two TDP copies, not four SYS-only copies.
            for copy in range(2):
                put(f'u_eng.g_fu.u_fin.g_group_pump.u_groups.g_pair[{copy}].u_ram.mem[{address}]',
                    index, 'finish four mirrors to two TDP copies')
        elif sg:
            slot, word = int(sg[1]), int(sg[2])
            require(data[index] == data[rf[0x200 + 16 * slot + word]], 'finish live slot differs from RF')
            # Applied through the versioned helper, after preserving all other words.
            classifications['live slots0..3 via versioned snapshot ABI'] = classifications.get(
                'live slots0..3 via versioned snapshot ABI', 0) + 1
        else:
            put(path, index, 'same logical field and physical path')
    # The old image never included sg[4:5] or ent[0:3]. They are preserved,
    # not initialized from guessed values. Current pm1/vn0/cs0/lr0 has no reuse.
    for field, expected in {'pm': 1, 'vn': 0, 'cs': 0, 'lr': 0}.items():
        require(data[mapping['u_eng.g_pu.' + field]] == expected,
                'unsupported HG continuation: ' + field)
    require(data[mapping['u_eng.np_r']] == data[mapping['u_eng.nv_r']] == 0,
            'HG writer bank is not empty')
    return destination, classifications


def write_hex(path, words):
    path.write_text(''.join(f'{w:08x}\n' for w in words))


def context_svh(destination):
    lines = ['// Generated from the accepted HG3712 map; qualified target is binding.json.',
             '// HG_GEOM and HG_FIN name the actual profile58 instances.',
             'task automatic hg193_apply_context;',
             ' hg193_read_finalize_snapshots(hg193_live,hg193_frozen);',
             ' for(int s=0;s<4;s++)for(int w=0;w<16;w++)',
             '  hg193_live[s][w]=hg193_context[2886+16*s+w];',
             ' hg193_import_finalize_snapshots(hg193_live,hg193_frozen,1\'b1);']
    for path, index in sorted(destination.items()):
        lines.append(f' `HG_GEOM.{path}=hg193_context[{index}];')
    lines += ['endtask', 'task automatic hg193_verify_context;',
              ' hg193_verify_finalize_snapshots(hg193_live,hg193_frozen);']
    for path, index in sorted(destination.items()):
        lines.append(f' assert(`HG_GEOM.{path} === $bits(`HG_GEOM.{path})\'(hg193_context[{index}]))'
                     f' else $fatal(1,"HG193 context readback: {path}");')
    lines += ['endtask', '']
    return '\n'.join(lines)


def cold_svhs():
    """The accepted cold, unpublished raster/ring state; no output pixels."""
    scalar = {}
    for macro, names in [
            ('HG_RING', 'wdone wdone_q wsafe st_full st_pres rb_v rb_p dir drop d_on dline '
                        'go_q sw_done lc_pend lc_cnt lc_pv lc_ab fp_d fp_act_q'),
            ('HG_RASTER.u_front', 'lines_go lines_done y y3'),
            ('HG_RASTER.u_fpass', 'fp_done fp_y fy3 fd3 clr_p'),
            ('HG_GPU', 'lv_fin lv_lo lv_on lv_go lv_skip l3d_rear dline')]:
        scalar.update({f'`{macro}.{name}': "'0" for name in names.split()})
    scalar.update({f'`HG_GPU.{name}': f'hg193_cold[{10+i}]' for i, name in enumerate(
        ['r_dispcnt', 'r_alpharef', 'r_clear_attr1', 'r_clear_depth', 'r_fog_color', 'r_fog_offset'])})
    arrays = []
    for slot in range(4):
        arrays += [(f'`HG_RASTER.g_lb4.g_lb[{slot}].u_top.mem[i]', 256, "'0"),
                   (f'`HG_RASTER.g_lb4.g_lb[{slot}].g_bot.u_bot.mem[i]', 256, "'0")]
    arrays += [('`HG_RING.u_stage.mem[i]', 1024, "'0"),
               ('`HG_RING.u_rbuf.mem[i]', 512, "'0"),
               ('`HG_RASTER.u_fpass.u_edge_tbl.mem[i]', 8, 'hg193_tables[i]'),
               ('`HG_RASTER.u_toon.mem[i]', 32, 'hg193_tables[8+i]'),
               ('`HG_RASTER.u_fpass.u_fog.mem[i]', 32, 'hg193_tables[40+i]')]
    apply, verify = [], []
    for path, value in scalar.items():
        apply.append(f' {path}={value};')
        verify.append(f' assert({path}===$bits({path})\'({value}))'
                      f' else $fatal(1,"HG193 cold epoch: {path}");')
    for path, count, value in arrays:
        apply.append(f' for(int i=0;i<{count};i++){path}={value};')
        verify.append(f' for(int i=0;i<{count};i++)assert({path}===$bits({path})\'({value}))'
                      f' else $fatal(1,"HG193 cold memory: {path}");')
    return '\n'.join(apply) + '\n', '\n'.join(verify) + '\n'


def prepare(out):
    binding, images, params = bound_inputs()
    mapping = legacy_mapping(Path(binding['legacy']['g3d_import_context597.svh']['path']).read_text())
    destination, classes = translate_context(mapping, images['context'])
    packets = []
    for key in range(16384):
        source = images['records'][4 * key:4 * key + 4]
        p = packet(key, source)
        require(decode(key, p) == source, 'packet translation round trip')
        packets += p
    # Negative vectors are HOST guards, never represented as executed RTL controls.
    rejected = []
    for name, key, mutation in [
            ('wrong-record', 1, packet(2, [0] * 4)),
            ('wrong-bank', 0x2000, packet(0, [0] * 4)),
            ('wrong-tag', 0, packet(0, [0] * 4)),
            ('wrong-inverse', 0, packet(0, [0] * 4)),
            ('wrong-format', 0, packet(0, [0] * 4)),
            ('wrong-tail', 0, packet(0, [0] * 4))]:
        if name.startswith('wrong-') and name not in ('wrong-record', 'wrong-bank'):
            mutation[{'wrong-tag': 4, 'wrong-inverse': 5, 'wrong-format': 6, 'wrong-tail': 7}[name]] ^= 1
        try:
            decode(key, mutation)
        except ValueError:
            rejected.append(name)
        else:
            raise ValueError('host negative control survived: ' + name)
    out.mkdir(parents=True, exist_ok=True)
    for name, words in images.items():
        # Preserve byte-for-byte accepted files, including their original widths.
        original = Path(binding['payload']['root']) / (name + '.hex')
        (out / original.name).write_bytes(original.read_bytes())
    write_hex(out / 'sd-packets.hex', packets)
    (out / 'hg193_context.svh').write_text(context_svh(destination))
    apply, verify = cold_svhs()
    (out / 'hg193_cold_apply.svh').write_text(apply)
    (out / 'hg193_cold_verify.svh').write_text(verify)
    for name in ('runtime_import_gx_sd_ready.svh', 'runtime_import_finalize_snapshots.svh'):
        helper = Path(binding['overlay'][name]['path']).read_text()
        for task in ('assert_gx_sd_pair_drained', 'import_finalize_snapshots',
                     'read_finalize_snapshots', 'verify_finalize_snapshots'):
            helper = re.sub(r'\b' + task + r'\b', 'hg193_' + task, helper)
        (out / name).write_text(helper)
    (out / 'hg193_sd_pair.svh').write_bytes((HERE / 'hg193_sd_pair.svh').read_bytes())
    (out / 'hg193_profile.svh').write_text('\n'.join(
        f' assert($root.tb_ds_pocket.dut.{name}=={value})else $fatal(1,"HG193 profile: {name}");'
        for name, value in sorted(params.items())) + '\n')
    generated = [name + '.hex' for name in images] + [
        'sd-packets.hex', 'hg193_context.svh', 'hg193_profile.svh', 'hg193_sd_pair.svh',
        'hg193_cold_apply.svh', 'hg193_cold_verify.svh',
        'runtime_import_gx_sd_ready.svh', 'runtime_import_finalize_snapshots.svh']
    report = {
        'state': 'SOURCE_READY_COMPONENT_EXECUTION_PENDING',
        'binding_sha256': digest(HERE / 'binding.json'),
        'source': binding['source'], 'profile_fields': 58, 'semantic_sha256': SEMANTIC,
        'images_verified': len(images), 'context_words': 3712,
        'legacy_path_assignments': len(mapping), 'target_path_assignments': len(destination),
        'translation_classes': classes,
        'canonical_records': 16384, 'canonical_words': len(packets),
        'canonical_word_range': [BASE, BASE + len(packets) - 1],
        'retained_banks': {'writer': 1, 'render': 0, 'polygons': 622, 'vertices': 4500},
        'host_guard_mutations_rejected': rejected,
        'preserved_unavailable_inactive_fields': ['finalize.live[4:5][0:15]',
                                                'finalize.frozen[0:3][0:15]'],
        'scope': 'pm1 vn0 cs0 lr0; empty writer; no active finalize; both clocks held; full transport drained',
        'not_run': ['compiler', 'actual RTL wrong-record/tag controls', 'RTL default-import control',
                    'full HG model', 'state export', 'first-use re-investigation'],
        'default_import': 'No existing launcher, testbench or production file edited; opt-in include only',
        'generated_sha256': {name: digest(out / name) for name in sorted(generated)},
    }
    (out / 'preparation.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    print(json.dumps(prepare(args.out), indent=2))
