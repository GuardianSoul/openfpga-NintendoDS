#!/usr/bin/env python3
"""Finite design analysis, not a DS timing oracle or an emulator result.

Enumerate all integer source/capture relative phases. The proposed crossover
keeps one capture stream/clock alive while selecting direct/mixer/direct.
"""
import argparse
import json
from pathlib import Path


def ceildiv(a, b):
    return -(-a // b)


def analyze(short_window_fault=False):
    # Observed run38 C260 enable brackets <=74 SYS and capture arm33 SYS.
    # Future returned brackets must be checked; these are not assumed op costs.
    # Gate the returned interval [voice2.before-voice0.after,
    # voice2.after-voice0.before], not a guessed loop/MMIO instruction cost.
    gap = range(255, 508)
    clock = 254  # proposed T127 capture: phase walk against sourceT512
    reset = {ceildiv(p+g, clock)-ceildiv(p, clock)
             for p in range(clock) for g in gap}
    common = {ceildiv(p+g, clock)-ceildiv(p, clock)
              for p in range(clock) for g in (0, 1024)}
    assert not reset & common
    # PCM pattern [0,0,1..14]; actual channels use64*code and1024*code.
    period = 16*1024
    wave = bytes(0 if t//1024 < 2 else t//1024-1 for t in range(period))
    windows = [range(256, 1280), range(2700, 3724), range(5100, 6124)]
    if short_window_fault:
        windows = [range(w.start, w.start+512) for w in windows]

    def signature(phase, window, delay=0):
        return bytes(wave[(phase+n*clock-delay) % period] for n in window)

    # Two beats are needed: the two zero prefix samples hide one source edge
    # in a single512-sample beat. The next beat moves that omitted edge.
    direct = {}
    for phase in range(0, period, 2):
        a = signature(phase, windows[0])
        assert a not in direct, 'direct window does not identify phase bin'
        direct[a] = phase
        assert a == signature(phase+1, windows[0])
    deltas = [0, 1, 2, 254, 256]
    intersections = {}
    for delta in deltas:
        aliases = 0
        # Odd/even phases are observationally equal in the direct window.
        for phase in direct.values():
            baseline = signature(phase, windows[1])
            alternatives = [signature(phase+parity, windows[1], delta) for parity in (0, 1)]
            if baseline in alternatives:
                aliases += 1
            assert signature(phase, windows[2]) == signature(phase+1, windows[2])
        intersections[str(delta)] = aliases
    assert intersections['0'] == intersections['1'] == len(direct)
    assert all(intersections[str(d)] == 0 for d in (2, 254, 256))
    # Exact permutation proof for two independent clocks: any delay is
    # absorbed by the second unit's phase, including256SYS.
    independent = all(signature(p, windows[1], 256) ==
                      signature((p-256) % period, windows[1])
                      for p in range(period))
    assert independent
    return dict(status='DESIGN FAMILY DISCRIMINATOR PASS; CONDITIONAL, NOT DS MEASUREMENT',
                run38_quiet_enable_max_observed_SYS=74, run38_capture_arm_observed_SYS=33,
                intended_enable_gap_SYS=384, required_returned_gap_interval_SYS=[min(gap), max(gap)],
                capture_period_SYS=clock, source_period_SYS=1024,
                onset_index_separation=dict(start_relative=sorted(reset),
                                            common_sample_grid_equal_pipeline=sorted(common)),
                pattern_samples=[0, 0, *range(1, 15)], windows=[[w.start, w.stop-1] for w in windows],
                integer_phases=period, direct_phase_bins=len(direct), phase_bin_width_SYS=2,
                independent_clocks_absorb_constant_delay=independent,
                crossover_intersections_against_zero_delay=intersections,
                required_crossover='one uninterrupted capture stream direct0/mixer/direct0; clocks and voices never reset',
                control='same source writes at same times, direct0/direct0/direct0; always-mixer second unit',
                invalidators=['source write restarts/pauses/reindexes capture',
                              'tagged source phases or clocks change across windows',
                              'actual brackets exceed finite family envelope',
                              'samples cannot be decomposed into declared unique labels'],
                non_identified=['0 versus1SYS visibility gap', 'common absolute delay/source phase',
                                'arbitrary per-channel startup bias versus timer phase',
                                'per-source capture path latency versus physical mixer delay'],
                hardware_verdict=False)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--short-window-fault', action='store_true')
    a = p.parse_args()
    result = analyze(a.short_window_fault)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(result, indent=2)+'\n')
    print(result['status'])
