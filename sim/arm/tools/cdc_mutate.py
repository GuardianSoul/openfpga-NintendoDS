#!/usr/bin/env python3
"""Deliberate bugs in the clock crossings (rtl/arm/cdc_req.sv, cdc_fifo.sv)
that sim/arm/tools/cdc_test.sh must catch.
  cdc_mutate.py VERILATOR BUILD_DIR"""
import os
import shutil
import subprocess
import sys

MUTATIONS = [
    ("cdc_req: answered before the slave did", "cdc_req.sv",
     "end else if (m_ack1 != m_ack2) begin", "end else if (1'b1) begin"),
    ("cdc_req: the request just answered is taken again", "cdc_req.sv",
     "end else if (m_req && !m_done) m_arm <= 1'b1;", "end else if (m_req) m_arm <= 1'b1;"),
    ("cdc_req: the payload taken in the request's first cycle", "cdc_req.sv",
     "end else if (m_req && !m_done) m_arm <= 1'b1;",
     "end else if (m_req && !m_done) begin m_busy <= 1'b1; p_hold <= m_p; m_t <= !m_t; end"),
    ("cdc_req: the slave's answer not kept", "cdc_req.sv", "q_hold <= s_q;", "q_hold <= q_hold;"),
    ("cdc_fifo: the read pointer does not advance", "cdc_fifo.sv", "      rp <= rp + 1'b1;\n", ""),
    ("cdc_fifo: the head read from the next slot", "cdc_fifo.sv",
     "assign r_d = mem[rp[AB-1:0]];", "assign r_d = mem[rp[AB-1:0] + 1'b1];"),
]


def main():
    verilator, build = sys.argv[1], sys.argv[2]
    survived = 0
    for i, (name, fname, old, new) in enumerate(MUTATIONS):
        d = os.path.join(build, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        for f in ("cdc_req.sv", "cdc_fifo.sv"):
            shutil.copy(os.path.join("rtl/arm", f), d)
        p = os.path.join(d, fname)
        src = open(p).read()
        if src.count(old) != 1:
            print(f"ERROR  {name}: pattern found {src.count(old)} times")
            survived += 1
            continue
        open(p, "w").write(src.replace(old, new))
        r = subprocess.run(["sim/arm/tools/cdc_test.sh", verilator, os.path.join(d, "obj"), d],
                           capture_output=True, text=True)
        if r.returncode:
            print(f"caught    {name}")
        else:
            print(f"SURVIVED  {name}")
            survived += 1
    shutil.rmtree(build, ignore_errors=True)
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
