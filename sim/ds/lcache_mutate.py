#!/usr/bin/env python3
"""Deliberate bugs in rtl/ds/nds_lcache.sv that sim/ds/lcache_test.sh must catch.
  lcache_mutate.py VERILATOR BUILD_DIR"""
import os
import shutil
import subprocess
import sys

MUTATIONS = [
    ("lookups of the line being filled not masked",
     "lm_q <= (f_busy && f_idx == l_idx) || queued(l_idx)", "lm_q <= queued(l_idx)"),
    ("a queued invalidation not masked (lookups)",
     "lm_q <= (f_busy && f_idx == l_idx) || queued(l_idx)", "lm_q <= (f_busy && f_idx == l_idx)"),
    ("a queued invalidation not masked (checks)",
     "!(f_busy && f_idx == cq_a) && !queued(cq_a)", "!(f_busy && f_idx == cq_a)"),
    ("the check's valid not forwarded from the last write",
     "(lw_v && lw_a == cq_a) ? lw_d : rq2_v", "rq2_v"),
    ("the lookup's valid-now not forwarded from the last write",
     "(lw_v && lw_a == la_q) ? lw_d : rq_v", "rq_v"),
    ("a killed fill written valid", "wv = f_ok ? cur : '0;", "wv = cur;"),
    ("an invalidation meeting a fill end dropped",
     "if (inv && !inv_w && !(f_end && inv_idx == f_idx)) begin : push", "if (1'b0) begin : push"),
    ("the sweep stops one entry short", "if (sp == LB'(N - 1)) sw_on <= 1'b0;", "if (sp == LB'(N - 2)) sw_on <= 1'b0;"),
    ("an invalidation writes back the tag read before the last write",
     "wire  [TW-1:0] c_tnow = (lw_v && lw_a == cq_a) ? lw_t : rq2_t;", "wire  [TW-1:0] c_tnow = rq2_t;"),
    ("a queued invalidation writes back another tag", "we = 1'b1; wa = qa[qh]; wt = qt[qh];", "we = 1'b1; wa = qa[qh]; wt = '0;"),
    ("the sweep writes back no tag", "we = 1'b1; wa = sw_wa; wt = rq_t;", "we = 1'b1; wa = sw_wa; wt = '0;"),
    ("MLAB: a lookup of the address the buffer writes reads the RAM", "assign rq = f1 ? fd : mq;", "assign rq = mq;"),
    ("MLAB: a check of the address the buffer writes reads the RAM", "assign rq2 = f2 ? fd : mq2;", "assign rq2 = mq2;"),
    ("MLAB: the buffer writes a cycle late twice", "always_ff @(posedge clk) begin pv <= we; pa <= wa; pd <= {wv, wt}; end",
     "logic pv0; always_ff @(posedge clk) begin pv0 <= we; pv <= pv0; pa <= wa; pd <= {wv, wt}; end"),
    ("the scrubber writes back no tag", "we = 1'b1; wa = sc_a; wt = rq_t;", "we = 1'b1; wa = sc_a; wt = '0;"),
    ("a scrub pass also cleans generations that went stale during it",
     "dirty <= dirty & ~snap;", "dirty <= (1 << VW)'(1) << cur;"),
    ("inv_all not waiting for a clean generation",
     "(f_end && f_ok)))) && !dirty[nxt]) begin", "(f_end && f_ok))))) begin"),
    ("inv_all skipped although a fill ended in its cycle",
     "if ((rst || inv_all) && (any_fill || (f_end && f_ok))) pend <= 1'b1;", "if ((rst || inv_all) && any_fill) pend <= 1'b1;"),
    ("the scrubber clears an entry written at its read's edge",
     " &&\n                   !(lw_v && lw_a == sc_a);", ";"),
    ("the scrubber's retry does not re-read", "if (retry) begin sp <= sc_a; sc_hold <= 1'b1; end", "if (1'b0) ;"),
]


def main():
    verilator, build = sys.argv[1], sys.argv[2]
    survived = 0
    for i, (name, old, new) in enumerate(MUTATIONS):
        d = os.path.join(build, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        src = open("rtl/ds/nds_lcache.sv").read()
        if src.count(old) != 1:
            print(f"ERROR     {name}: pattern found {src.count(old)} times")
            survived += 1
            continue
        open(os.path.join(d, "nds_lcache.sv"), "w").write(src.replace(old, new))
        r = subprocess.run(["sim/ds/lcache_test.sh", verilator, os.path.join(d, "obj"), d],
                           capture_output=True, text=True)
        print(f"{'caught   ' if r.returncode else 'SURVIVED '} {name}")
        survived += r.returncode == 0
    shutil.rmtree(build, ignore_errors=True)
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
