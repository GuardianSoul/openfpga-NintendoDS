#!/usr/bin/env python3
"""Reject unrepresentable timer epochs before an atomic native import.

Reads the exact optional clean runtime; never changes a seed, counter, phase,
clock, reference pairing or native model. A passing timer check is necessary,
not sufficient, for the separately qualified publication transaction.
"""
from pathlib import Path
import argparse
import hashlib
import json


def timer_constraints(runtime):
    clock = runtime['clock']
    banks = []
    for cpu in range(2):
        now = (clock['ARM9Timestamp'] >> clock['ARM9ClockShift']) if cpu == 0 else clock['ARM7Timestamp']
        elapsed = now - clock['TimerTimestamp'][cpu]
        if elapsed < 0:
            raise ValueError('timer timestamp is ahead of its CPU domain')
        candidates = set(range(1024))
        rows = []
        for index in range(cpu*4, cpu*4+4):
            timer = runtime['timers'][index]
            if timer['Cnt'] & 0x84 != 0x80:
                continue
            pre = [0, 6, 8, 10][timer['Cnt'] & 3]
            shift = 10-pre
            if timer['CycleShift'] != shift:
                raise ValueError(f'timer{index} inconsistent prescaler encoding')
            fraction = (timer['Counter'] + (elapsed << shift)) & 1023
            if fraction & ((1 << shift)-1):
                raise ValueError(f'timer{index} contains an unrepresentable subcycle fraction')
            period = 1 << pre
            phase = fraction >> shift
            candidates &= {dv for dv in range(1024) if dv % period == phase}
            rows.append(dict(timer=index, period_SYS=period, saved_fraction=fraction,
                             required_divider_low=phase, next_increment_SYS=period-phase))
        banks.append(dict(cpu=cpu, CPU_domain_now=now, lazy_elapsed_SYS=elapsed,
                          requirements=rows, native_divider_candidates=sorted(candidates),
                          representable=bool(candidates)))
    return dict(representable=all(bank['representable'] for bank in banks), banks=banks,
                authority='Representability only. ARM7 shared-prescaler law remains an assumption pending DS probe.',
                policy='No phase normalization or per-timer timing adapter; original seed and references remain immutable.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runtime', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    data = args.runtime.read_bytes()
    report = timer_constraints(json.loads(data))
    report.update(source_runtime=str(args.runtime.resolve()), runtime_sha256=hashlib.sha256(data).hexdigest(),
                  status='TIMER_EPOCH_REPRESENTABLE' if report['representable'] else 'ATOMIC_PUBLICATION_REJECTED_TIMER_PHASE',
                  native_publication_performed=False)
    args.report.write_text(json.dumps(report, indent=2)+'\n')
    print(report['status'])
    return 0 if report['representable'] else 3


if __name__ == '__main__':
    raise SystemExit(main())
