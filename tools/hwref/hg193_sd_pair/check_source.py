#!/usr/bin/env python3
"""Source/host equivalence evidence only; no compiler or simulation process."""
import argparse
import json
from pathlib import Path
import tempfile

import prepare


def check(out):
    binding, images, _ = prepare.bound_inputs()
    source = Path(binding['legacy']['g3d_import_context597.svh']['path']).read_text()
    mapping = prepare.legacy_mapping(source)
    expected, _ = prepare.translate_context(mapping, images['context'])
    with tempfile.TemporaryDirectory(prefix='hg193-source-') as temp:
        generated = Path(temp)
        report = prepare.prepare(generated)
        # Independent decode of the physical image, retaining all four old
        # word lanes and both banks rather than sampling one live polygon.
        words = [int(w, 16) for w in (generated / 'sd-packets.hex').read_text().split()]
        decoded = []
        for bank in range(2):
            for index in range(8192):
                key = 8192 * bank + index
                record = words[8 * key:8 * key + 8]
                assert record[4] >> 16 == 0xC4E0
                assert (record[4] >> 2) & 0x3FFF == key
                assert record[4] & 3 == 0
                assert record[4] ^ record[5] == 0xFFFFFFFF
                assert record[6:] == [0x47335344, 0]
                decoded.extend(record[:4])
        assert decoded == images['records']
        for name in images:
            assert prepare.digest(generated / (name + '.hex')) == binding['payload']['files'][name]['sha256']
        # Every collapsed alias is explicitly checked by translate_context.
        # A deliberate mutation of a redundant clip or finish mirror must
        # fail; a checker that merely copied one chosen alias would miss it.
        mutations = []
        for name, index in [('clip-replica', 1524), ('finish-replica', 2694), ('live-slot', 2886),
                            ('strip-reuse', 3593), ('partial-polygon', 3608)]:
            mutant = images['context'].copy()
            mutant[index] ^= 1
            try:
                prepare.translate_context(mapping, mutant)
            except ValueError as error:
                mutations.append({'mutation': name, 'rejected': str(error)})
            else:
                raise AssertionError('logical equivalence mutation survived: ' + name)
        # Assert generated target copies retain the accepted values in
        # current physical paths. Slots4/5 and frozen entries have no guessed
        # target assignments; all are read and preserved before slot0..3 load.
        target = (generated / 'hg193_context.svh').read_text()
        for path, index in expected.items():
            assert f'`HG_GEOM.{path}=hg193_context[{index}];' in target
        assert 'hg193_read_finalize_snapshots(hg193_live,hg193_frozen);' in target
        assert 'for(int s=0;s<4;s++)' in target
        assert 'hg193_import_finalize_snapshots(hg193_live,hg193_frozen,1\'b1);' in target
        template = (generated / 'hg193_sd_pair.svh').read_text()
        assert '`ifdef HG193_SD_PAIR_OPT_IN' in template and 'initial begin' not in template
        assert 'hg193_assert_boundary(held);' in template
        assert template.index('hg193_assert_boundary(held);') < template.index('hg193_apply_context();')
        assert template.index('sd_poke32(') < template.index('`HG_STORE.ready=1;')
        assert template.index('`HG_STORE.ready=1;') < template.index('hg193_verify_publication();')
        prepare.bound_inputs()  # Actual default TB/source hashes unchanged after preparation.
        evidence = {
            'state': 'HOST_SOURCE_EQUIVALENCE_PASS_RTL_EXECUTION_PENDING',
            'binding_sha256': prepare.digest(prepare.HERE / 'binding.json'),
            'images_verified_and_byte_identical': 11,
            'records_word_exact': 16384, 'banks_exact': 2,
            'record_words_exact': 65536,
            'legacy_context_indices_covered': 3712,
            'target_assignments_verified': len(expected),
            'deliberate_logical_mutations': mutations,
            'host_packet_mutations': report['host_guard_mutations_rejected'],
            'default_import_static': 'frozen actual compiled TB hash unchanged; opt-in task has no initial block or caller',
            'publication_static': 'boundary before deposits; ready last; full readback while held',
            'not_claimed': ['SV compilation', 'held/drained runtime proof', 'actual wrong-record/tag rejection',
                            'executed default-import equivalence', 'HG scene qualification'],
        }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(evidence, indent=2) + '\n')
    return evidence


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    print(json.dumps(check(parser.parse_args().out), indent=2))
