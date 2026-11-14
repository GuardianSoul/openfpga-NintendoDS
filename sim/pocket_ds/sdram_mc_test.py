#!/usr/bin/env python3
"""nds_sdram_mc against the SDRAM chip model (tb_sdram_mc.sv), then planted
bugs it must catch.

    sim/pocket_ds/sdram_mc_test.py          OPEN=1 sim/pocket_ds/sdram_mc_test.py   (open rows, with their own mutants)
"""
import concurrent.futures as cf
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
SRCS = ['sim/phase1/sim_prims.sv', 'sim/phase1/sdram_chip_model.sv', 'rtl/pocket/nds_sdram_mc.sv',
        'sim/pocket_ds/tb_sdram_mc.sv']
F = 'rtl/pocket/nds_sdram_mc.sv'
OPEN = os.environ.get('OPEN') == '1'
OUTR = os.environ.get('OUT_REG') == '1'
WOPEN = os.environ.get('WOPEN', '0')
WRAP = os.environ.get('WRAP') == '1'     # WRAP=1: 8-word reads from a random word with c_wrap (+wrap)       # WOPEN=1/2/3 (nds_sdram_mc WOPEN; bit 0 needs OPEN=1)     # OUT_REG=1: the pins' register stage (with or without OPEN)
BASES = ([("    parameter integer OPEN = 0", "    parameter integer OPEN = 1")] if OPEN else []) + \
        ([("    parameter integer OUT_REG = 0", "    parameter integer OUT_REG = 1")] if OUTR else []) + \
        ([("    parameter integer WOPEN = 0,", f"    parameter integer WOPEN = {WOPEN},")] if WOPEN != '0' else [])
# (old, new): each must make the test fail
MUTANTS = [
    ("parameter integer RD_LAT = 4,", "parameter integer RD_LAT = 5,"),                       # capture a beat late
    ("cmd <= C_READ; a <= col_a(col_of(q_addr), OPEN == 0 && q_left == 4'd1);",
     "cmd <= C_READ; a <= col_a(col_of(q_addr), 1'b0);"),                                       # reads never precharge
    ("!q_row || ", ""),                                                                         # a chain across rows
    ("dq_out <= q_wdata[31:16]; dqm <= ~q_be[3:2];", "dq_out <= q_wdata[31:16]; dqm <= ~q_be[1:0];"),  # high half's lanes
    ("cmd <= C_REF; ref_owed <= ref_owed - 1'b1; gap <= 4'd9;",
     "cmd <= C_REF; ref_owed <= ref_owed - 1'b1; gap <= 4'd3;"),                                # tRFC
    ("dqm <= {2{ch_hi ? !q_he : !bw_he[0]}};", "dqm <= 2'b00;"),                                # chain half enables ignored
    ("q_he <= bw_he[1];", "q_he <= bw_he[0];"),                                                 # the high half takes the low's
]


if OPEN:   # with open rows, "reads never precharge" is the design: its own faults instead
    MUTANTS = [m for m in MUTANTS if 'never precharge' not in m[1] and "1'b0);" not in m[1]] + [
        ("ob_rc == c_rb[12:0] && ", ""),                                                   # any open row is a hit
        ("wire       pre_ok = rd_age <= 3'd3 && act_age >= 3'd5 && ((WOPEN & 1) == 0 || wr_age >= 2'd2);", "wire       pre_ok = 1'b1;"),  # PRECHARGE too early
        ("c_valid && c_we) && rd_age != 0) begin", "c_valid && c_we) && 1'b0) begin"),             # a write over read data
        ("if (OPEN != 0 && ref_owed != 0 && ob_v != 0) begin", "if (1'b0) begin"),              # refresh with rows open
    ]


if int(WOPEN) & 1:   # write rows left open: their own faults
    MUTANTS = MUTANTS + [
        ("ob_v[wb] && ob_rw == row_of(bw_addr) && rd_age == 0) begin", "ob_v[wb] && rd_age == 0) begin"),   # a chain into another open row
        (" && ((WOPEN & 1) == 0 || wr_age >= 2'd2);", ";"),                                     # PRECHARGE before tWR
        ("last && !wop);", "last);"),                                                            # auto-precharged yet marked open
    ]


if WRAP:   # the wrap: reads that ignore it
    MUTANTS = MUTANTS + [("if (q_wrap) q_addr[2:0] <= q_addr[2:0] + 1'b1; else q_addr[7:0]", "if (1'b0) q_addr[2:0] <= q_addr[2:0] + 1'b1; else q_addr[7:0]")]


if OUTR:   # the read capture left where it was: the word is taken a clock early
    MUTANTS = MUTANTS + [("localparam integer RDL = RD_LAT + (OUT_REG != 0 ? 1 : 0);", "localparam integer RDL = RD_LAT;")]


def run(name, mut=None):
    d = ROOT / 'build/sdram_mc_test' / name
    shutil.rmtree(d, ignore_errors=True)
    for s in SRCS:
        (d / s).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / s, d / s)
    for b in BASES:
        t = (d / F).read_text(); assert t.count(b[0]) == 1; (d / F).write_text(t.replace(b[0], b[1]))
    if mut:
        t = (d / F).read_text()
        assert t.count(mut[0]) == 1, mut[0]
        (d / F).write_text(t.replace(mut[0], mut[1]))
    r = subprocess.run([str(TOOLS / 'verilator'), '--binary', '--timing', '-O2', '-Wno-fatal', '-Wno-WIDTHEXPAND',
                        '-Wno-WIDTHTRUNC', '--top-module', 'tb_sdram_mc', '--Mdir', str(d / 'obj'),
                        *[str(d / s) for s in SRCS]], capture_output=True, text=True)
    if r.returncode:
        return 'build failed: ' + (r.stdout + r.stderr)[-600:]
    r = subprocess.run([str(d / 'obj/Vtb_sdram_mc')] + (['+wrap'] if WRAP else []), capture_output=True, text=True, timeout=1200)
    shutil.rmtree(d / 'obj', ignore_errors=True)
    out = r.stdout.splitlines()
    summary = next((l for l in out if l.startswith('reads ')), '')
    return ('PASS ' if 'TEST PASSED' in r.stdout else 'FAIL ') + summary


def main():
    jobs = [('ref', None)] + [(f'mut{i}', m) for i, m in enumerate(MUTANTS)]
    with cf.ThreadPoolExecutor(min(3, len(jobs))) as ex:   # (AGENTS.md: at most 3 sims)
        res = dict(zip([j[0] for j in jobs], ex.map(lambda j: run(*j), jobs)))
    print('reference:', res['ref'])
    missed = 0
    for i, m in enumerate(MUTANTS):
        r = res[f'mut{i}']
        caught = r.startswith('FAIL') or r.startswith('build failed')
        missed += not caught
        print(f'{i} {"caught" if caught else "MISSED"} [{m[1][:60]}] {r[:90]}')
    sys.exit(1 if missed or not res['ref'].startswith('PASS') else 0)


if __name__ == '__main__':
    main()
