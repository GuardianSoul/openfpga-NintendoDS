#!/usr/bin/env python3
"""Attribute first current-heavy gaps from final captures, without a model run."""
import gzip
import json
import time
from heavy_game59 import OUT, GAME, STAGED, sha, write
from heavy_game59_compare import a


def main():
    start = time.monotonic()
    report = json.loads((OUT / 'comparison.json').read_text())
    # Final complete streams only; the earlier live-prefix diagnostic is not
    # an input to this replay. Bind the raw files before selecting a prefix.
    captures = {}
    for label, base in [('game52', GAME), ('current', OUT)]:
        manifest = json.loads((base / 'capture-manifest.json').read_text())
        captures[label] = {}
        for name in ('capture.bus.gz', 'capture.cpu.gz', 'capture.states.jsonl'):
            row = manifest[name]
            p = base / 'capture' / name
            assert p.stat().st_size == row['bytes'] and sha(p) == row['sha256']
            captures[label][name] = row

    states = [[json.loads(s) for s in (base / 'capture/capture.states.jsonl').read_text().splitlines()]
              for base in (GAME, OUT)]
    first_memory = next(i for i, (x, y) in enumerate(zip(*states))
                        if x['memory_fnv64'] != y['memory_fnv64'])
    assert first_memory == 6
    cutoff = states[0][first_memory]['time_ps']
    assert cutoff == states[1][first_memory]['time_ps']
    initial = [int(s, 16) for s in (STAGED / 'inputs/imp_main.hex').read_text().split()]
    assert len(initial) == 1 << 20
    memories, lasts, writes, fnvs = [], [], [], []
    for base in (GAME, OUT):
        memory = initial.copy()
        last = {}
        n = 0
        for row in a.rows(base / 'capture/capture.bus.gz'):
            t, kind, master, addr, data, be, _, _ = row
            if t > cutoff:
                break
            if kind != 56:
                continue
            assert addr >> 24 == 2
            index = (addr & 0x3fffff) >> 2
            mask = sum(255 << (8 * b) for b in range(4) if be & (1 << b))
            memory[index] = (memory[index] & ~mask) | (data & mask)
            last[index] = row
            n += 1
        h = 1469598103934665603
        for i, value in enumerate(memory):
            h = ((h ^ ((i << 32) | value)) * 1099511628211) & ((1 << 64) - 1)
        memories.append(memory); lasts.append(last); writes.append(n); fnvs.append(f'{h:x}')
    expected = [ss[first_memory]['memory_fnv64'][0] for ss in states]
    assert fnvs == expected
    words = []
    for i, (x, y) in enumerate(zip(*memories)):
        if x == y:
            continue
        old_write, new_write = lasts[0].get(i), lasts[1].get(i)
        assert new_write is not None and new_write[2] == 3
        assert old_write is None or old_write[2] == 3
        words.append(dict(ARM_address=f'0x{0x02000000 + i * 4:08x}',
                          game52=f'0x{x:08x}', current=f'0x{y:08x}',
                          old_last_write=old_write, new_last_write=new_write))
    assert len(words) == 319 and writes == [320, 324]
    main_memory = dict(frame=first_memory, time_ps=cutoff, changed_words=len(words),
        first_address=words[0]['ARM_address'], last_address=words[-1]['ARM_address'],
        write_counts=writes, reconstructed_FNV64=fnvs, captured_FNV64=expected,
        reconstructed_both_exact_to_capture=True, all_explanatory_writes_sound_master3=True,
        old_words_still_from_import=sum(r['old_last_write'] is None for r in words),
        words=words,
        scope='Exact first MAIN snapshot gap is sound-capture writes, including four current-only words. The underlying sample/service-cadence cause and later MAIN/WRAM state remain OPEN.')

    boot = [int(s, 16) for s in (STAGED / 'inputs/boot.hex').read_text().split()]
    opcodes = [0xe3a0d301, 0xe28ddc01, 0xe1dde3b0, 0xe35e0000, 0x1afffffa, 0xe3e0e000]
    assert initial[(0x021aa1b4 - 0x02000000)//4:(0x021aa1b4 - 0x02000000)//4+6] == opcodes
    assert boot[(0x947c-0x8000)//4:(0x947c-0x8000)//4+6] == opcodes
    contexts = json.loads((OUT / 'first-semantic-context.json').read_text())
    cpus = {}
    for cpu, pc in [('0', 0x021aa1bc), ('1', 0x9484)]:
        diff = report['CPU'][cpu]['first_semantic_difference']
        assert diff['old'][1:5] == [101, int(cpu), 30, 0x3ff]
        assert diff['new'][1:5] == [101, int(cpu), 30, 0]
        for label in ('game52', 'current'):
            before = [r for r in contexts[cpu]['records'][label][:12] if r[1] == 100]
            assert before[-1][3:5] == [pc-4, 0x200000db]
        cpus[cpu] = dict(first=diff, instruction_PC=f'0x{pc:08x}',
            physical_RF30='r14_und; CPSR 0x200000db', opcode='e1dde3b0: ldrh r14,[r13,#0x30]',
            address='0x04000130 KEYINPUT',
            classification='The same original import wait loop samples 0x3ff before release versus 0 inside the unchanged release pulse at this original ordinal. Polling iteration counts differ; later application state is not inferred equivalent.')
    actor = (STAGED / 'overlay/sim/pocket_ds/tb_ds_pocket.sv').read_text()
    assert 'force dut.keys = 12\'h3FF;' in actor and 'repeat (400) @(posedge dut.clk_sys);' in actor
    releases = [x[-1] for x in report['import_events'].values()]
    assert releases[0] == releases[1] == 'import: released at 112501717000, video frame 6'

    extra = []
    for path in (GAME / 'comparison-streams.json.gz', OUT / 'current-streams.json.gz'):
        with gzip.open(path, 'rt') as f:
            data = json.load(f)
        extra.append(data[1] if isinstance(data, list) else data)
    old, new = extra
    assert len(old['deadlines']) == len(new['deadlines']) == 4609
    assert [(r[0], r[1]) for r in old['deadlines']] == [(r[0], r[1]) for r in new['deadlines']]
    deadlines = []
    for i, (x, y) in enumerate(zip(old['deadlines'], new['deadlines'])):
        if x == y:
            continue
        assert x[:5] == y[:5] and x[6:] == y[6:] and abs(x[5]-y[5]) == 1
        assert x[2] == y[2] == 0
        deadlines.append(dict(index=i, game52=x, current=y, field='wsafe',
            both_wsafe_above_display_line=min(x[5],y[5]) > x[1]))
    assert len(deadlines) == 3 and all(x['both_wsafe_above_display_line'] for x in deadlines)
    # Full raw PCM is explicitly an open acceptance gate even though the
    # historical comparator separates it from its architectural-gaps list.
    acceptance = dict(finite_image_save_storage_checks='PASS_SCOPED',
        full_current_source_game='OPEN',
        open_observables=['CPU_semantic_sequence', 'later_MAIN_WRAM_and_CPU_frame_state',
                          'raw_PCM_values_and_cadence'],
        raw_PCM=report['audio'], audio_closure=False,
        deadline_stamps_and_lines_exact=True, internal_wsafe_differences=deadlines,
        no_timestamp_input_frame_or_sample_shift=True,
        scope='No CPU/state/audio timing waiver, global DS acceptance, six-scene qualification, or fit claim.')
    write(OUT / 'attribution.json', dict(source=report['source'], raw_capture_bindings=captures,
        import_wait_CPU=cpus, original_input_opcodes=[f'{x:08x}' for x in opcodes],
        unchanged_release_event=releases[0], MAIN_frame6=main_memory, acceptance=acceptance,
        wall_seconds=time.monotonic()-start))
    print(json.dumps(dict(status='PASS_FIRST_GAP_ATTRIBUTION_OPEN_AUDIO_AND_LATER_STATE',
        sound_MAIN_words=len(words), current_only_words=main_memory['old_words_still_from_import'],
        deadline_stamps_exact=4609, safe_internal_wsafe_differences=len(deadlines),
        wall_seconds=time.monotonic()-start)))


if __name__ == '__main__':
    main()
