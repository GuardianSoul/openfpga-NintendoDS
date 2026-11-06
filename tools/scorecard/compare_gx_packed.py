#!/usr/bin/env python3
"""Pair exact packed-GX endpoints with DS run38, retaining every raw difference."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
from statistics import median

import gx_packed as gx
import gx_packed_native as native
from stage_gx_packed import elf_symbol


def protocol_log(text, address=0x023f0100):
    """Keep every post-header write; retain a digest of pre-protocol traffic."""
    active = False
    kept, prologue = [], []
    first = None
    base = address & 0x3fffff
    for number, line in enumerate(text.splitlines(keepends=True), 1):
        match = re.search(r'WW port\s+([0-9a-fA-F]+) <= ([0-9a-fA-F]+) be ([0-9a-fA-F]+)', line)
        if match:
            at, value, enables = (int(v, 16) for v in match.groups())
            if at == base and value == 0x47585031 and enables == 15:
                active = True
                if first is None:
                    first = number
            if not active and base <= at < base + 64:
                prologue.append(line)
                continue
        kept.append(line)
    native.require(active, 'no complete first GX protocol header')
    return ''.join(kept), dict(first_header_line=first, pre_protocol_port_writes=len(prologue),
                               pre_protocol_lines=prologue,
                               pre_protocol_sha256=hashlib.sha256(''.join(prologue).encode()).hexdigest(),
                               scope='only watched-window port writes before first full magic header; every subsequent write retained')


def ds_rows(rows):
    native.require(len(rows) == 18, 'DS needs exactly18 packed rows')
    packets = []
    for index, row in enumerate(rows):
        kind, length = index // 6, (index % 6) // 3 + 1
        native.require(row['body'] == ('LOAD44', 'TRINRML4', 'TRIXCLIP')[kind], 'DS body/order mismatch')
        _, _, words = gx.stream(kind, length)
        packets.append([0x47585031, index + 1, kind,
                        *[int(row[key]) for key in ('n', 'rep', 'entries', 'words', 'dma_sys', 'idle_sys')],
                        *[int(row[key], 16) for key in ('dma_gxstat', 'idle_gxstat', 'clip0_after_idle')],
                        int(row['timeout']), length, gx.input_hash(words), index + 1])
    # DS CSV has no RAM commit or FNV field. Those two metadata fields are
    # reconstructed from the frozen source contract, never described as
    # observed on the DS. All recorded inputs/endpoints/outcomes are checked.
    return gx.validate(packets)


def summarize(rows):
    result = []
    for body in ('LOAD44', 'TRINRML4', 'TRIXCLIP'):
        group = [r for r in rows if r['body'] == body]
        lengths = sorted({r['n'] for r in group})
        native.require(len(lengths) == 2, 'need two matched body lengths')
        small, large = [[r for r in group if r['n'] == n] for n in lengths]
        native.require(all([r['rep'] for r in g] == [0, 1, 2] for g in (small, large)), 'need three ordered repetitions')
        delta = lengths[1] - lengths[0]
        values = dict(body=body, n=lengths, delta_bodies=delta)
        for endpoint in ('dma_sys', 'idle_sys'):
            values[endpoint] = dict(small=[r[endpoint] for r in small], large=[r[endpoint] for r in large],
                                    paired_slopes=[(b[endpoint] - a[endpoint]) / delta for a, b in zip(small, large)],
                                    median_group_slope=(median(r[endpoint] for r in large) -
                                                        median(r[endpoint] for r in small)) / delta)
        values['tail_sys'] = [[r['idle_sys'] - r['dma_sys'] for r in g] for g in (small, large)]
        result.append(values)
    return result


def compare(base, capture, protocol, shipping_rom):
    plan_path, run = base / 'plan.json', base / 'execution.json'
    plan, execution = json.loads(plan_path.read_text()), json.loads(run.read_text())
    native.require(execution['plan_sha256'] == native.sha(plan_path), 'native plan digest mismatch')
    native.require(plan['source'] == native.SOURCE and plan['profile'] == native.PROFILE, 'unexpected source/profile')
    native.require(execution['actual_model_sha256'] == native.MODEL and execution['host'] == plan['host'],
                   'actual native model/host mismatch')
    native.require(execution['frozen_files_unchanged'], 'native inputs changed during run')
    native.require(execution['argv'] == plan['argv'] and execution['cwd'] == plan['cwd'], 'actual command differs from plan')
    for name, digest in plan['frozen_files'].items():
        native.require(native.sha(base / name) == digest, f'native prepared input changed: {name}')
    for name, digest in plan['reporting_tools'].items():
        native.require(native.sha(Path(name)) == digest, f'native reporting tool changed: {name}')
    log = base / 'native.log'
    native.require(execution['log_sha256'] == native.sha(log), 'native log digest mismatch')
    text = log.read_text()
    projected, publication_scope = protocol_log(text)
    try:
        native.check_log(text, execution['exit'])
        original_verdict = 'PASS'
    except ValueError as error:
        original_verdict = str(error)
    measured = native.check_log(projected, execution['exit'])
    contract = json.loads((protocol / 'manifest.json').read_text())
    native.require(native.sha(protocol / 'manifest.json') == plan['protocol_manifest_sha256'], 'sampler/source contract changed')
    native.require(native.sha(shipping_rom) == contract['qualified_ds_rom_sha256'], 'shipping DS ROM changed')
    native.require(native.sha(protocol / 'packed.elf') == contract['elf_sha256'], 'counterpart ELF changed')
    sampler = elf_symbol(protocol / 'packed.elf', 'gxlat_dma')
    native.require(sampler['address'] == 0x01ff8020 and sampler['size'] == 320 and
                   hashlib.sha256(sampler['body']).hexdigest() == native.SAMPLER and
                   shipping_rom.read_bytes().count(sampler['body']) == 1 and
                   (base / 'packed.nds').read_bytes().count(sampler['body']) == 1, 'exact sampler proof failed')
    manifest = json.loads(capture.read_text())
    csv_path = capture.parent / 'trip20261031/gxlatency_v4_packed.csv'
    native.require(native.sha(csv_path) == manifest['files'][csv_path.name], 'raw DS CSV digest mismatch')
    with csv_path.open(newline='') as stream:
        reference = ds_rows(list(csv.DictReader(stream)))
    pairs = []
    for a, b in zip(measured['rows'], reference):
        fields = ('body', 'n', 'rep', 'entries', 'words', 'stream_fnv1a32')
        native.require(all(a[key] == b[key] for key in fields), 'paired DS/Pocket inputs differ')
        pairs.append(dict(input={key: a[key] for key in fields}, pocket=a, ds=b,
                          delta_sys={key: a[key] - b[key] for key in ('dma_sys', 'idle_sys')},
                          pocket_over_ds={key: a[key] / b[key] for key in ('dma_sys', 'idle_sys')}))
    return dict(source=plan['source'], profile=plan['profile'], host=execution['host'],
                geometry_profile=dict(GX_PRE=1, DIV_P2X=0, GATH16=1, SPILL=1, SP_AW=18, DX_SKID=0,
                                      basis='verified frozen12e1 defaults/parameter forwarding; end-to-end Pocket probe, not intrinsic SPILL0 capacity'),
                actual_model_sha256=execution['actual_model_sha256'], model_pid=execution['model_pid'],
                plan_sha256=native.sha(plan_path), execution_sha256=native.sha(run), native_log_sha256=native.sha(log),
                source_manifest_pins=plan['snapshot_pins'], source_files=plan['source_files'],
                publication_scope=publication_scope, original_decoder_verdict=original_verdict,
                projected_log_sha256=hashlib.sha256(projected.encode()).hexdigest(),
                canonical_harness_sha256=plan['harness_sha256'], actual_command=execution['argv'],
                capture=dict(run=38, ds_model=manifest['ds_model'], cart=manifest['cart'],
                             manifest_sha256=native.sha(capture), csv_sha256=native.sha(csv_path)),
                sampler_sha256=native.SAMPLER, protocol_manifest_sha256=native.sha(protocol / 'manifest.json'),
                shipping_rom_sha256=native.sha(shipping_rom), pocket_rom_sha256=native.sha(base / 'packed.nds'),
                canonical_checks=2, complete_packets=18, native_gate='PASS: canonical/model/input/endpoint/outcome checks only',
                native_vram_words=measured['vm_words'], pairs=pairs,
                slopes=dict(pocket=summarize(measured['rows']), ds=summarize(reference)),
                qualification='raw timings compared; no timing equivalence or arbitrary tolerance accepted',
                limits=['FAT/journals replaced by RAM; surrounding cache/heap history and stream address differ',
                        'Timed320-byte sampler and command packing source match; whole harness is not timing-identical',
                        'DS FNV is source-derived; Pocket packet FNV is observed; no measured DS RAM-commit field',
                        'DMA-finish and subsequent GX-idle remain separate; neither is substituted for the other',
                        'No game/frame/save/runtime-RAM equivalence follows from this probe',
                        'Historical12e1/58713059/RA2 only; newer combined heads/CPU options remain unmeasured here',
                        'Median-of-length-group slopes do not erase individual repetition timing outliers'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('native', 'capture', 'protocol', 'shipping-rom', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    result = compare(args.native.resolve(), args.capture.resolve(), args.protocol.resolve(), args.shipping_rom.resolve())
    with args.out.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print('18 exact input pairs / two endpoints compared; raw timing differences retained')


if __name__ == '__main__':
    main()
