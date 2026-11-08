#!/usr/bin/env python3
"""Deliberate bugs in rtl/ds/nds_disp_refs.sv that sim/ds/disp_refs_test.sh
must catch.
  disp_refs_mutate.py VERILATOR BUILD_DIR"""
import os
import shutil
import subprocess
import sys

MUTATIONS = [
    ("a CPU write in the clock of a sequencer write of the same reference kept",
     "done = !c_we || (p_we && p_a == {1'b0, c_a});", "done = !c_we;"),
    ("a sequencer write does not drop a queued write of its reference",
     "if (p_we) for (int k = 0; k < QD; k++) if ({1'b0, qa[k]} == p_a) qv[k] <= 1'b0;", ""),
    ("reads do not take a queued value",
     "for (int k = 0; k < QD; k++) if (qv[k] && {1'b0, qa[k]} == a) r = qd[k];", ""),
    ("a queued write leaves the queue in a clock the sequencer writes (lost)",
     "for (int k = QD - 1; k >= 0; k--) if (qv[k]) begin dr = !p_we; dk = k; end",
     "for (int k = QD - 1; k >= 0; k--) if (qv[k]) begin dr = 1'b1; dk = k; end"),
    ("the clear after a reset skips half the entries",
     "wire [3:0]  wa = z_we ? z_a :", "wire [3:0]  wa = z_we ? (z_a & 4'd3) :"),
    ("the clear after a reset writes the old data",
     "wire [31:0] wd = z_we ? 32'd0 :", "wire [31:0] wd = 1'b0 ? 32'd0 :"),
    ("a newer CPU write does not replace its reference's queued value",
     "if (!done && qv[k] && qa[k] == c_a && !(dr && dk == k)) begin\n                    qd[k] <= c_wd; done = 1'b1;",
     "if (1'b0) begin\n                    qd[k] <= c_wd; done = 1'b1;"),
]


def main():
    verilator, build = sys.argv[1], sys.argv[2]
    survived = 0
    for i, (name, old, new) in enumerate(MUTATIONS):
        d = os.path.join(build, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        src = open("rtl/ds/nds_disp_refs.sv").read()
        if src.count(old) != 1:
            print(f"ERROR     {name}: pattern found {src.count(old)} times")
            survived += 1
            continue
        open(os.path.join(d, "nds_disp_refs.sv"), "w").write(src.replace(old, new))
        r = subprocess.run(["sim/ds/disp_refs_test.sh", verilator, os.path.join(d, "obj"), d],
                           capture_output=True, text=True)
        print(f"{'caught   ' if r.returncode else 'SURVIVED '} {name}")
        survived += r.returncode == 0
    shutil.rmtree(build, ignore_errors=True)
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
