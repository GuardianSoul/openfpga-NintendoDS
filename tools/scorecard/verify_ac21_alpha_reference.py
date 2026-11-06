"""Verify one passive AC reference observation against actual native inputs."""
import argparse
import copy
from fractions import Fraction
import json
from pathlib import Path


def blend(top, second, eva, evb):
    return [min(63, (a*eva+b*evb+8) >> 4) for a, b in zip(top, second)]


def expand6(color):
    return [(v << 2) | (v >> 4) for v in color]


def pocket(color):
    return [((v >> 1) << 3) | (v >> 3) if i != 1 else (v << 2) | (v >> 4)
            for i, v in enumerate(color)]


def verify(reference, plan, native):
    assert reference['normal_CLI_completion'] and not reference['errors']
    assert reference['observer_calls'] == reference['observer_state_writes'] == 0
    assert reference['runframe_entries'] == list(range(5))
    epoch = reference['epoch']
    assert epoch['SysTimestamp'] == 420142500 and epoch['GPU_VCount'] == 262
    assert epoch['NumFrames'] == 750 and epoch['curFrame'] == epoch['curLine'] == 0
    assert epoch['ARM9Timestamp'] == 840285000 and epoch['ARM7Timestamp'] == 420142500
    assert epoch['ARM9ClockShift'] == 1
    assert epoch['ARM9']['Halted'] == epoch['ARM7']['Halted'] == 1
    assert epoch['ARM9']['IRQ'] == epoch['ARM7']['IRQ'] == 0
    assert epoch['IME'] == [1, 1] and epoch['IE'] == [0x4000b, 0x104009d]
    assert epoch['IF'] == [0x280000, 0]
    assert epoch['engines'][0]['BlendCnt'] == 0x2148
    assert epoch['engines'][0]['BlendAlpha'] == 0x0709
    lcd = epoch['events'][0]
    assert lcd == dict(index=0, active=False, Timestamp=420142500, FuncID=2, Param=263)
    assert len(reference['writes']) == 2
    for write in reference['writes']:
        assert write['cpu'] == 9 and write['source'] == 'CPU' and write['src'] == 0
        assert write['address'] == 0x04000050 and write['bytes'] == 4
        assert write['PC_R15'] == 0x02110afc and write['CurInstr'] == 0xe5801000
    assert [r['curFrame'] for r in reference['lines99']] == list(range(5))
    assert [r['image'] for r in reference['outputs']] == list(range(1, 6))
    for line in reference['lines99']:
        e = line['engineA']
        assert e['EVA'] == min(16, e['BlendAlpha'] & 31)
        assert e['EVB'] == min(16, (e['BlendAlpha'] >> 8) & 31)
        preceding = [w for w in reference['writes'] if w['ARM9Timestamp'] <= line['ARM9Timestamp']]
        last_word = preceding[-1]['value'] if preceding else 0x07092148
        assert e['BlendCnt'] == (last_word & 0x3fff)
        assert e['BlendAlpha'] == ((last_word >> 16) & 0x1f1f)
    for output in reference['outputs']:
        expected = plan['reference_outputs'][str(output['image'])]
        assert output['fb_hash'] == expected['fb_hash']
        assert output['PPM_sha256'] == expected['PPM_sha256']
        assert output['byte_exact_to_archived_image'] and not output['image_exported']
    line = reference['lines99'][4]
    final = reference['outputs'][4]
    actual = native['matching_native_pixel_events'][0]
    assert line['Output3D_RGBAbytes'] == list(line['Output3D68'].to_bytes(4, 'little'))
    assert line['Output3D_RGBAbytes'] == actual['second']+[31]
    assert actual['top_flags'] == 8 and actual['second_flags'] == 95
    palette = line['palette17']
    assert palette == 0x33ff
    foreground = [(palette & 31) << 1, ((palette >> 5) & 31) << 1 | (palette >> 15),
                  ((palette >> 10) & 31) << 1]
    assert foreground == actual['top']
    ref6 = blend(foreground, actual['second'], line['engineA']['EVA'], line['engineA']['EVB'])
    native6 = blend(foreground, actual['second'], actual['eva'], actual['evb'])
    assert expand6(ref6) == final['RGB']
    assert native6 == actual['out'] and pocket(native6) == actual['PocketRGB']
    assert pocket(ref6) == native['fixed_pixel']['reference_projected']
    assert actual['frame'] == 10 and native['fixed_pixel']['raw'] == 10
    return dict(reference_curFrame=4, reference_image=5, line=99, x=68, stacked_y=291,
                BLDCNT=line['engineA']['BlendCnt'], BLDALPHA=line['engineA']['BlendAlpha'],
                actual_reference_factors=[line['engineA']['EVA'], line['engineA']['EVB']],
                actual_native_factors=[actual['eva'], actual['evb']], foreground_RGB6=foreground,
                background_RGBA6=line['Output3D_RGBAbytes'], actual_background_equal=True,
                reference_RGB6=ref6, reference_RGB8=final['RGB'],
                reference_PocketRGB=pocket(ref6), native_RGB6=native6, native_PocketRGB=pocket(native6),
                reference_fb_hash=final['fb_hash'], reference_PPM_sha256=final['PPM_sha256'],
                conclusion='Actual reference13/3 versus native11/5 with equal captured foreground/background explains this fixed pixel; no coefficient fit or phase change')


def timing(reference, native):
    # Actual frozen native sim_prims_ds.sv: 14919ps half-period on clk_bus.
    period = 29838
    anchor = 116944588000
    previous = None
    transitions = []
    for port in native['blend_writes']:
        if port['engine'] != 0:
            continue
        if previous and port['word'] != previous['word'] and port['time_ps'] > anchor:
            ref = next(w for w in reference['writes'] if w['value'] == port['word'])
            lower = Fraction(previous['time_ps']-anchor, period)
            upper = Fraction(port['time_ps']-anchor, period)
            ref_cpu = Fraction(ref['ARM9Timestamp']-reference['epoch']['ARM9Timestamp'],
                               1 << ref['ARM9ClockShift'])
            transitions.append(dict(factors=[port['eva'], port['evb']],
                native_last_old_port_ps=previous['time_ps'], native_first_new_port_ps=port['time_ps'],
                native_port_observation_bounds_bus_ticks=[float(lower), float(upper)],
                reference_cpu=dict(frame=ref['curFrame'], line=ref['curLine'], source=ref['source'],
                    cpu=ref['cpu'], PC_R15_hex=f"{ref['PC_R15']:08x}", CurInstr_hex=f"{ref['CurInstr']:08x}",
                    relativeSys=ref['relativeSys'], relative_ARM9_bus_ticks=float(ref_cpu),
                    written_word_hex=f"{ref['value']:08x}"),
                native_port_bounds_minus_reference_CPU_ticks=[float(lower-ref_cpu), float(upper-ref_cpu)]))
        previous = port
    assert len(transitions) == 2
    gaps = [t['native_port_bounds_minus_reference_CPU_ticks'] for t in transitions]
    assert max(g[0] for g in gaps) > min(g[1] for g in gaps)
    return dict(native_pre_line0_anchor_ps=anchor, native_bus_tick_ps=period,
                transitions=transitions, no_common_constant_offset_between_observed_transition_ranges=True,
                scope='Native values are old/new line-state port observations, not native CPU MMIO commit timestamps. Reference SysTimestamp is scheduler time; ARM9Timestamp/2 is also retained. Disjoint ranges reject a simple constant time-offset explanation, not all import effects.',
                unresolved='Native MMIO PC/time is not observed. Import starts with invalid ARM9 caches/empty pipelines (docs/state-import.md); import cold-state costs versus production/DS-vs-emulator timing are not separated. Top876 still unexplained; no production fix, waiver or game PASS.')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for flag in ['reference', 'plan', 'native', 'out']:
        p.add_argument('--'+flag, type=Path, required=True)
    args = p.parse_args()
    reference = json.loads(args.reference.read_text())
    plan = json.loads(args.plan.read_text())
    native = json.loads(args.native.read_text())
    fixed = verify(reference, plan, native)
    # A real recorded CPU write changed privately: 13/3 -> 12/3. The actual
    # line99 live register must then disagree; no new inferior run is made.
    bad = copy.deepcopy(reference)
    bad['writes'][1]['value'] ^= 1 << 16
    try:
        verify(bad, plan, native)
    except AssertionError:
        caught = True
    else:
        raise AssertionError('actual recorded alpha-write bit mutation escaped')
    result = dict(status='PASS_BOUNDED_REFERENCE_OBSERVATION_GAME_GATE_STILL_FAIL',
                  fixed_pixel=fixed, timing=timing(reference, native),
                  recorded_actual_alpha_write_bit16_mutant_caught=caught,
                  all_five_reference_outputs_byte_identical=True,
                  GDB_PID=reference['GDB_PID'], inferior_PID=reference['inferior_PID'],
                  NI=10, terminal=True, slots=0)
    args.out.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result['fixed_pixel'], indent=2))
