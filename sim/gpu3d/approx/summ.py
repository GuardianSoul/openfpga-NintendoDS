#!/usr/bin/env python3
# summ.py <result.txt>...: per file: frames, frames differing, %px differing (mean, max),
# max error, mean error, pixels with error > 2, pixels with a changed top polygon ID
import sys
for fn in sys.argv[1:]:
    r = [l.split() for l in open(fn) if l.strip()]
    if not r: continue
    n = len(r); nd = sum(1 for x in r if int(x[1]) > 0)
    pct = [float(x[2]) for x in r]
    mx = max(int(x[3]) for x in r)
    me = [float(x[4]) for x in r if int(x[1]) > 0]
    big = sum(int(x[5]) for x in r); idc = sum(int(x[6]) for x in r)
    worst = max(r, key=lambda x: float(x[2]))
    print(f"{fn.split('/')[-1][:-4]:12s} frames {n:4d} differ {nd:4d}  px% mean {sum(pct)/n:6.3f} max {max(pct):6.3f} ({worst[0]})"
          f"  maxerr {mx:2d}  meanerr {(sum(me)/len(me) if me else 0):5.2f}  err>2 px/frame {big/n:8.1f}  idchg px/frame {idc/n:8.1f}")
