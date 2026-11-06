#!/usr/bin/env python3
"""Read-only representability check for native per-CPU shared timer dividers.

This is an import preflight, not a repair or a new reference oracle. It does
not require an absolute divider epoch to equal SysTimestamp. Independent
hardware IF delays are outside this native storage-format contract.
"""
import argparse,json
from pathlib import Path

PRESCALER = (1,64,256,1024)


def check(state):
    clock = state['clock']
    timers = state['timers']
    if len(timers) != 8:
        raise ValueError('eight CPU timer records required')
    banks = []
    for cpu in range(2):
        now = (clock['ARM9Timestamp'] >> clock['ARM9ClockShift']) if cpu == 0 else clock['ARM7Timestamp']
        elapsed = now - clock['TimerTimestamp'][cpu]
        if elapsed < 0:
            raise ValueError('timer last-update time is after its CPU time')
        active = []
        for local in range(4):
            i = cpu * 4 + local
            t = timers[i]
            if t['Cnt'] & 0x84 != 0x80:
                continue  # Disabled/cascaded timers do not constrain this divider.
            divisor = PRESCALER[t['Cnt'] & 3]
            shift = 10 - (divisor.bit_length() - 1)
            if t['CycleShift'] != shift:
                raise ValueError(f'timer{i} CycleShift inconsistent with control')
            # Reload/overflow changes add multiples of1024 and cannot change
            # this fraction. Translate every timer to the SAME domain time.
            # Sub-SYS low bits are unobservable here and are not rejected.
            phase = (((t['Counter'] & 1023) >> shift) + elapsed) % divisor
            active.append(dict(timer=i,divisor=divisor,phase=phase,
                               stored_fraction=t['Counter'] & 1023,
                               next_increment_SYS=divisor-phase))
        allowed = [dv for dv in range(1024)
                   if all(dv % t['divisor'] == t['phase'] for t in active)]
        conflicts = []
        for a in range(len(active)):
            for b in range(a+1,len(active)):
                x,y = active[a],active[b]
                modulus = min(x['divisor'],y['divisor'])
                delta = (x['phase']-y['phase']) % modulus
                if delta:
                    conflicts.append(dict(timers=[x['timer'],y['timer']],
                                          modulus=modulus,phase_delta=delta))
        banks.append(dict(cpu=cpu,domain_now=now,last_update=clock['TimerTimestamp'][cpu],
                          lazy_elapsed=elapsed,timers=active,allowed_divider_values=allowed,
                          representable=bool(allowed),conflicts=conflicts))
    return dict(schema_version=1,scope='native one-shared-divider-per-CPU representability only',
                representable=all(b['representable'] for b in banks),banks=banks,
                absolute_epoch_required=False,seed_modified=False,
                hardware_limit='DS43 measures observable F64 IF phase after explicit setup; arbitrary independent IF delays and original seed creation are not identified')


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('runtime',type=Path)
    p.add_argument('--out',type=Path)
    p.add_argument('--require-representable',action='store_true')
    a=p.parse_args()
    if a.out and (a.out.resolve()==a.runtime.resolve() or
                  (a.out.exists() and a.out.samefile(a.runtime))):
        p.error('output must not overwrite the input snapshot')
    result=check(json.loads(a.runtime.read_text()))
    text=json.dumps(result,indent=2)+'\n'
    if a.out:a.out.write_text(text)
    else:print(text,end='')
    if a.require_representable and not result['representable']:
        raise SystemExit(2)
