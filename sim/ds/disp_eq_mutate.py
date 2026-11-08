#!/usr/bin/env python3
"""Deliberate bugs in the docs/space-2d.md changes that the nds_disp lockstep
(sim/ds/disp_eq.sh, against 669c40c9) must catch: each mutation in a copy of
the RTL, the release configuration, one seed.
  disp_eq_mutate.py VERILATOR BUILD_DIR [NAME_SUBSTRING]
EQ_REF: the version to compare with (default 669c40c9)."""
import os
import shutil
import subprocess
import sys

FILES = ["rtl/gpu2d/gpu2d_pkg.sv", "rtl/ds/nds_ram.sv", "rtl/gpu2d/gpu2d_ram.sv", "rtl/gpu2d/gpu2d_cache.sv",
         "rtl/gpu2d/gpu2d_bg.sv", "rtl/gpu2d/gpu2d_obj.sv", "rtl/gpu2d/gpu2d.sv", "rtl/ds/nds_disp_refs.sv",
         "rtl/ds/nds_disp.sv"]

MUTATIONS = [
    # item 3: the clear after reset
    ("refs: the clear after a reset skips entries 4-7", "rtl/ds/nds_disp_refs.sv",
     "wire [3:0]  wa = z_we ? z_a :", "wire [3:0]  wa = z_we ? (z_a & 4'd11) :"),
    # item 1: the merged RAM and BGxRefInternal in u_refs
    ("u_pr: a Q_PRE copy step waits for a u_ar write (the extra clock)", "rtl/ds/nds_disp.sv",
     "            busy = 1'b0;\n", "            busy = ar_we != 4'd0;\n"),
    ("u_refs: Q_LOAD reads the wrong BGxRefInternal entry", "rtl/ds/nds_disp.sv",
     "{1'b1, q_eng, 2'(q_word + 5'd1)}", "{1'b1, q_eng, 2'(q_word)}"),
    ("u_pr: u_ar's words read from the parameter half", "rtl/ds/nds_disp.sv",
     "pr_ra = {1'b1, ar_ra};", "pr_ra = {1'b0, ar_ra};"),
    ("u_pr: Q_PRE reads a word that is not 0", "rtl/ds/nds_disp.sv",
     "else if (q != Q_LOAD) pr_ra = 6'd8;", "else if (q != Q_LOAD) pr_ra = 6'd4;"),
    # item 2
    ("pw_d: the deferred PD half written as 0", "rtl/ds/nds_disp.sv",
     "pr_wd = {pw_d, pw_d};", "pr_wd = {16'd0, pw_d};"),
    # item 5: halfword reads from the caches
    ("cache: byte lanes swapped", "rtl/gpu2d/gpu2d_cache.sv",
     "assign q = {48'd0, q1, q0};", "assign q = {48'd0, q0, q1};"),
    ("cache: a held read takes the new halfword", "rtl/gpu2d/gpu2d_cache.sv",
     "assign r_half = hold ? q_half : a_half;", "assign r_half = a_half;"),
    ("BG: the VRAM-display pixel's halfword from the wrong x bits", "rtl/gpu2d/gpu2d_bg.sv",
     "t_ahalf = s3.x[1:0];", "t_ahalf = s3.x[2:1];"),
    ("OBJ: the texel halfword from the wrong address bits", "rtl/gpu2d/gpu2d_obj.sv",
     "t_aword_h = p0_a[2:1];", "t_aword_h = p0_a[3:2];"),
    # WH_RAM: WIN0H/WIN1H in u_ar (against the version before it)
    ("WH: the X1 > X2 flags from the word before the write", "rtl/ds/nds_disp.sv",
     "if (io_be[b]) m[b*8 +: 8] = io_wdata[b*8 +: 8];", ";"),
    ("WH: state word 13's X bytes swapped", "rtl/ds/nds_disp.sv",
     "{pr_q[7:0], pr_q[15:8]}", "{pr_q[15:8], pr_q[7:0]}"),
    ("WH: u_rb's word 6 not cleared after reset", "rtl/ds/nds_disp.sv",
     "wire rb_cl = WH && pr_cl > 6'd32;", "wire rb_cl = 1'b0;"),
]


def main():
    verilator, build = sys.argv[1], sys.argv[2]
    only = sys.argv[3] if len(sys.argv) > 3 else ""
    survived = 0
    for i, (name, path, old, new) in enumerate(MUTATIONS):
        if only not in name:
            continue
        d = os.path.join(build, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        for f in FILES:
            os.makedirs(os.path.join(d, os.path.dirname(f)), exist_ok=True)
            shutil.copy(f, os.path.join(d, f))
        src = open(path).read()
        if src.count(old) != 1:
            print(f"ERROR     {name}: pattern found {src.count(old)} times")
            survived += 1
            continue
        open(os.path.join(d, path), "w").write(src.replace(old, new))
        env = dict(os.environ, EQ_CFGS="rel", EQ_SEEDS="1", EQ_CYCLES=os.environ.get("EQ_CYCLES", "3000000"),
                   EQ_ARGS="--rst 300000")
        env.pop("NEWREF", None)
        r = subprocess.run(["sim/ds/disp_eq.sh", verilator, os.path.join(d, "obj"), os.environ.get("EQ_REF", "669c40c9"), d],
                           capture_output=True, text=True, env=env)
        print(f"{'caught   ' if r.returncode else 'SURVIVED '} {name}: {r.stdout.strip()[:160]}", flush=True)
        survived += r.returncode == 0
        shutil.rmtree(d, ignore_errors=True)
    shutil.rmtree(build, ignore_errors=True)
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
