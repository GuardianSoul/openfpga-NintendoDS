#!/usr/bin/env python3
"""Check source ordering/hold contracts; this is not runtime qualification."""
import argparse
import json
from pathlib import Path
import re


def verify(tb, hook, pin, wram):
    assert tb.index('hg193_combined_publish();') < tb.index('for (integer w = imp_ov + imp_stubn')
    assert tb.index('for (integer w = imp_ov + imp_stubn') < tb.index('force dut.keys =')
    assert tb.index('if(combined_wram_present)combined_restore_wram();') < tb.index('stubs done at')
    assert '`ifdef COMBINED_STATE_IMPORT' in wram and 'HG193_COMBINED_HOOK' not in wram
    assert 'w<16384' in wram and 'w<8192' in wram and 'w<24576' in wram
    assert 'u_private.mem[w]=imp_sram[w]' in wram and 'u_shared.mem[w]=imp_sram[16384+w]' in wram
    assert 'COMBINED_WRAM_PRIVATE_READBACK_MISMATCH' in wram and 'COMBINED_WRAM_SHARED_READBACK_MISMATCH' in wram
    assert all(name in wram for name in ['missing-private','missing-shared','wrong-private','wrong-shared'])
    assert 'repeat(3999)' in tb and 'repeat (4000)' in tb and 'repeat (400)' in tb
    assert 'imp_stub_pend = imp_stubn != 0;' in tb
    assert 'initial if' not in pin and '$fatal(1,"HG193 combined shared model/profile not pinned' in pin
    hold = hook.split('task automatic hg193_combined_hold_clocks;', 1)[1].split('endtask', 1)[0]
    release = hook.split('task automatic hg193_combined_release_clocks;', 1)[1].split('endtask', 1)[0]
    clocks = {'clk_74a', 'clk_74b'} | {'dut.' + c for c in
        'clk_sys clk_2x clk_cpu clk_mem clk_bus clk_cram clk_vid clk_vid90'.split()}
    assert set(re.findall(r'force\s+([\w.]+)=hg193_clock_levels\[\d+\]', hold)) == clocks
    assert set(re.findall(r'release\s+([\w.]+)', release)) == clocks
    for code in (hold, release):
        code = re.sub(r'//[^\n]*', '', code)
        assert '@' not in code and '#' not in code
    publish = hook.split('task automatic hg193_combined_publish;', 1)[1].split('endtask', 1)[0]
    publish = re.sub(r'//[^\n]*', '', publish)
    assert publish.count('@') == 1 and 'while' not in publish and '#' not in publish
    assert publish.index('hold_clocks();') < publish.index('assert_hg193_combined_drained();') < publish.index('hg193_publish(')
    assert publish.rindex('assert_hg193_combined_drained();') > publish.index('hg193_publish(')
    assert publish.index('$realtime==before_time') < publish.index('release_clocks();')


def main(base):
    tb = (base / 'overlay/sim/pocket_ds/tb_ds_pocket.sv').read_text()
    hook = (base / 'include/hg193_combined_hook.svh').read_text()
    pin = (base / 'include/hg193_shared_model_binding.svh').read_text()
    wram = (base / 'include/runtime_combined_wram.svh').read_text()
    verify(tb, hook, pin, wram)
    cases = [
        ('missing-memory-clock-hold', tb, re.sub(r'force dut.clk_mem=[^;]+;', '', hook), pin),
        ('late-publication-after-key-release', tb.replace('hg193_combined_publish();', '').replace(
            'force dut.keys = 12\'h3FF;', 'force dut.keys = 12\'h3FF;hg193_combined_publish();'), hook, pin),
        ('readiness-poll-retimes-release', tb, hook.replace('before_time=$realtime;',
            'while(!hg193_combined_transport_drained())@(posedge dut.clk_sys);before_time=$realtime;'), pin),
        ('unbound-model-gate-removed', tb, hook, pin.replace('$fatal(1,', '$display('))]
    rejected = []
    for name, a, b, c in cases:
        try:
            verify(a, b, c, wram)
        except AssertionError:
            rejected.append(name)
        else:
            raise AssertionError('mutation survived: ' + name)
    manifest = json.loads((base / 'manifest.json').read_text())
    try:
        verify(tb,hook,pin,wram.replace('COMBINED_WRAM_SHARED_READBACK_MISMATCH','REMOVED'))
    except AssertionError:
        rejected.append('shared-wram-readback-removed')
    else:
        raise AssertionError('missing shared WRAM readback survived')
    contract=json.loads((base/'wram-input-contract.json').read_text())
    assert len(contract['scenes'])==6 and all(v['words_verified']==24576 for v in contract['scenes'].values())
    result = dict(state='SOURCE_ORDER_HOLD_DEFAULT_BRANCH_CHECK_PASS_RUNTIME_PENDING',
        target_source=manifest['target_source'], predicates=manifest['predicate_count'],
        default_reconstruction_sha256=manifest['default_branch_reconstruction_sha256'],
        deliberate_source_mutations_rejected=rejected, shared_model_pin='UNBOUND; requested seed fails closed',
        six_scene_export_and_existing_input_words_verified=6*24576,
        actual_runtime_wram_equality='UNKNOWN; must run positive and wrong/missing-deposit controls on pinned shared candidate',
        compiler_or_model_executed=False, source_only=True)
    (base / 'source-check.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, type=Path)
    main(parser.parse_args().base.resolve())
