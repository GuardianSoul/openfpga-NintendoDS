#!/usr/bin/env python3
"""Recompute retained accounting and reject two actual input-field corruptions."""
import json
from pathlib import Path
import sys
import retained_trace as trace

def main():
    B=Path(sys.argv[1]);trace.main()
    directory=trace.MAIN/'build/rc053-elastic-ring-games/race-final-elastic-banked-ring-capture-observe'
    original=trace.lines;out={}
    for fault in ['native-address','time-as-SYS']:
        changed=[False]
        def bad_lines(path):
            for p in original(path):
                if path.name.endswith('.waits.csv') and not changed[0]:
                    if fault=='native-address' and p[0]=='MT':
                        p[2]=format(int(p[2],16)^1,'x');changed[0]=True
                    elif fault=='time-as-SYS' and p[0]=='V':
                        p[1]=p[2];changed[0]=True
                yield p
        trace.lines=bad_lines
        try:trace.analyze(directory)
        except AssertionError as e:
            assert changed[0]
            out[fault]=dict(caught=True,message=str(e))
        else:raise AssertionError('corrupted retained input accepted: '+fault)
        finally:trace.lines=original
    (B/'input-mutations.json').write_text(json.dumps(dict(PASS=True,faults=out,
        scope='Offline analyzer input faults, not RTL mutations or new core qualification.'),indent=2)+'\n')
    print('RETAINED_TRACE_CHECK_PASS positive=4 input_faults=2',flush=True)

if __name__=='__main__':main()
