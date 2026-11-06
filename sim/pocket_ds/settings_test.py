#!/usr/bin/env python3
"""Core Settings test (tb_settings.sv), then planted bugs it must catch.

    sim/pocket_ds/settings_test.py

Checks first that rtl/pocket/nds_settings.svh is current with
tools/ds/settings.py.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
SRCS = ['rtl/pocket/nds_cdc.sv', 'rtl/pocket/psx_pocket_pad_combo.sv', 'rtl/pocket/nds_controls.sv',
        'sim/pocket_ds/tb_settings.sv']
# (file, old, new): each must make the test fail
MUTANTS = [
    ('rtl/pocket/nds_controls.sv', "wire c_touch = |combos[5:2];", "wire c_touch = combos[3];"),
    # the two SELECT switches (#746): A/B/X/Y combos always off; L/R never off; A/B/X/Y never off; the switches crossed
    ('rtl/pocket/nds_controls.sv', ".combo_enable({{4{!combo_sel[1] && !top_only}}, {2{!combo_sel[0]}}})",
     ".combo_enable({{4{1'b0}}, {2{!combo_sel[0]}}})"),
    ('rtl/pocket/nds_controls.sv', ".combo_enable({{4{!combo_sel[1] && !top_only}}, {2{!combo_sel[0]}}})",
     ".combo_enable({{4{!combo_sel[1] && !top_only}}, 2'b11})"),
    ('rtl/pocket/nds_controls.sv', ".combo_enable({{4{!combo_sel[1] && !top_only}}, {2{!combo_sel[0]}}})",
     ".combo_enable({{4{!top_only}}, {2{!combo_sel[0]}}})"),
    ('rtl/pocket/nds_controls.sv', ".combo_enable({{4{!combo_sel[1] && !top_only}}, {2{!combo_sel[0]}}})",
     ".combo_enable({{4{!combo_sel[0] && !top_only}}, {2{!combo_sel[1]}}})"),
    ('rtl/pocket/nds_controls.sv', "assign pen = (touch && (|(fb & g_pen) || g_vis)) || pen_ana;",
     "assign pen = (touch && (fb[2] || g_vis)) || pen_ana;"),
    # gestures (A/B/X/Y in Touch Mode): Button held back; a circle that doesn't repeat while held; an 88 px
    # swipe; a wrong circle point; no clamp at the top; a swipe repeated while held; the pen at the cursor
    ('rtl/pocket/nds_controls.sv', "assign g_on[gi] = gest[3 * gi +: 3] != 3'd0;", "assign g_on[gi] = 1'b1;"),
    ('rtl/pocket/nds_controls.sv', "g_act <= g_circle && fb[g_btn];", "g_act <= 1'b0;"),
    ('rtl/pocket/nds_controls.sv', "g_circle ? 4'd15 : 4'd12", "g_circle ? 4'd15 : 4'd11"),
    # Circle at r 12, the size before the maintainer's 2026-11-06 change
    ('rtl/pocket/nds_controls.sv', "s_x = {sin12(g_step), 1'b0}", "s_x = sin12(g_step)"),
    # Big Circle (r 48, 16 points): a wrong point, the loop cut at 8 points, half the radius
    ('rtl/pocket/nds_controls.sv', "3'd2: m = 7'd34;", "3'd2: m = 7'd33;"),
    ('rtl/pocket/nds_controls.sv', "wire g_end = g_step == (g_circle ? 4'd15", "wire g_end = g_step == (g_circle ? (g_big ? 4'd7 : 4'd15)"),
    ('rtl/pocket/nds_controls.sv', "wire signed [7:0] c_x = g_big ? sin48(g_step)", "wire signed [7:0] c_x = g_big ? sin48(g_step) >>> 1"),
    ('rtl/pocket/nds_controls.sv', "3'd3: m = 5'd11;", "3'd3: m = 5'd10;"),
    ('rtl/pocket/nds_controls.sv', "g_y <= py[9] ? 8'd0", "g_y <= py[9] ? py[7:0]"),
    ('rtl/pocket/nds_controls.sv', "wire [3:0] g_new = fb & ~fb_q & g_gest;", "wire [3:0] g_new = fb & g_gest;"),
    ('rtl/pocket/nds_controls.sv', "assign pen_x = g_vis ? g_x : cur_x;", "assign pen_x = cur_x;"),
    ('rtl/pocket/nds_controls.sv', "speed == 2'd2 ? 8'd6 : 8'd3", "speed == 2'd2 ? 8'd3 : 8'd3"),
    # the setting's value taken only from the low byte (#253: on hardware it
    # arrives byte-swapped and the settings never changed)
    ('sim/pocket_ds/tb_settings.sv', "set_v = (bridge_wr_data[3:0] | bridge_wr_data[27:24])", "set_v = (bridge_wr_data[3:0])"),
    ('rtl/pocket/nds_controls.sv', "else if (c_next && !combo_d[1]) layout <= layout == 2'd2 ? 2'd0 : layout + 1'b1;",
     "else if (c_next && !combo_d[1]) layout <= layout == 2'd1 ? 2'd0 : layout + 1'b1;"),
    ('rtl/pocket/nds_controls.sv', "else if (c_prev && !combo_d[2]) layout <= layout == 2'd0 ? 2'd2 : layout - 1'b1;",
     "else if (c_prev && !combo_d[2]) layout <= layout == 2'd2 ? 2'd0 : layout + 1'b1;"),
    ('sim/pocket_ds/tb_settings.sv', "SET_CURSOR_SPEED_IDX:  set_a[SET_CURSOR_SPEED_BIT +: SET_CURSOR_SPEED_W]",
     "SET_CURSOR_SPEED_IDX:  set_a[SET_SELECT_LR_BIT +: SET_CURSOR_SPEED_W]"),
    # top only (2026-10-28): touch applied anyway; A/B/X/Y still combos there
    ('rtl/pocket/nds_controls.sv', "assign touch = touch_on && !top_only;", "assign touch = touch_on;"),
    ('rtl/pocket/nds_controls.sv', "{{4{!combo_sel[1] && !top_only}}", "{{4{!combo_sel[1]}}"),
    # the sticks: taken from any controller type; no hysteresis; the right stick ignoring the dead zone
    ('rtl/pocket/nds_controls.sv', "ana1 <= apf_type == 4'h3;", "ana1 <= 1'b1;"),
    ('rtl/pocket/nds_controls.sv', "sdir[LEFT]  <= sdir[LEFT]  ? lx < 5'd11 : lx < 5'd8;", "sdir[LEFT]  <= lx < 5'd8;"),
    ('rtl/pocket/nds_controls.sv', "rate = m > 4'd4 ? m - 4'd4 : 4'd0;", "rate = m;"),
    ('rtl/pocket/nds_controls.sv', "wire pen_ana = ana && !top_only && buttons[R3];", "wire pen_ana = ana && buttons[R3];"),
    # the cursor never hides
    ('rtl/pocket/nds_controls.sv', "assign cursor = !top_only && (touch || ana) && idle != 8'd180;",
     "assign cursor = !top_only && (touch || ana);"),
]


def run(d):
    obj = d / 'obj'
    cmd = [str(TOOLS / 'verilator'), '--binary', '--timing', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC',
           '--top-module', 'tb_settings', '-I' + str(ROOT / 'rtl/pocket'), '--Mdir', str(obj),
           *[str(d / s) for s in SRCS]]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        return 'build failed: ' + (r.stdout + r.stderr)[-800:]
    r = subprocess.run([str(obj / 'Vtb_settings')], capture_output=True, text=True)
    return 'PASS' if 'TEST PASSED' in r.stdout else 'FAIL: ' + r.stdout.strip().splitlines()[0]


def tree(name):
    d = ROOT / 'build/settings' / name
    shutil.rmtree(d, ignore_errors=True)
    for s in SRCS:
        (d / s).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / s, d / s)
    return d


def main():
    r = subprocess.run([sys.executable, str(ROOT / 'tools/ds/settings.py'), '--check',
                        str(ROOT / 'rtl/pocket/nds_settings.svh')])
    if r.returncode:
        sys.exit(1)
    res = run(tree('ref'))
    print('reference:', res)
    if res != 'PASS':
        sys.exit(1)
    missed = 0
    for i, (f, old, new) in enumerate(MUTANTS):
        d = tree(f'mut{i}')
        s = (d / f).read_text()
        assert s.count(old) == 1, old
        (d / f).write_text(s.replace(old, new))
        res = run(d)
        caught = res.startswith('FAIL')
        missed += not caught
        print(f'{i} {"caught" if caught else "MISSED"} [{new[:60]}] {res[:80]}')
    print(f'{len(MUTANTS) - missed} of {len(MUTANTS)} caught')
    sys.exit(1 if missed else 0)


if __name__ == '__main__':
    main()
