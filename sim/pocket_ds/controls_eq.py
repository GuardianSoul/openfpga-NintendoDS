#!/usr/bin/env python3
"""nds_controls against an earlier version, then planted bugs it must catch.
Against a version before the gestures (tb_controls_eq.sv) the gestures stay
at their defaults (A Touch, B/X/Y Button); against one with them
(tb_controls_eq_g.sv) the settings are random and pen_x/pen_y are compared.
--fw (tb_controls_fw.sv, docs/space-ctl.md): nds_controls FW = 1 with
nds_cart_scpu, SERV and the firmware (sw/scpu/cache.c) against the old
version's hardware, per clock outside the firmware's windows, while the ROM
cache serves misses; seeds 1..N (--seeds N), then the control run without
frames for the miss latencies, then the mutants.

    sim/pocket_ds/controls_eq.py [OLD_REV]            (default 11be2ed7, before the gestures)
    sim/pocket_ds/controls_eq.py --fw [--seeds N] [--nframes N] [--no-control] [--no-mutants] OLD_REV
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
SRCS = ['rtl/pocket/nds_cdc.sv', 'rtl/pocket/psx_pocket_pad_combo.sv', 'rtl/pocket/nds_controls.sv',
        'sim/pocket_ds/tb_controls_eq.sv']
MUTANTS = [
    # B/X/Y held back from the game in touch mode although they are Button
    ('rtl/pocket/nds_controls.sv', "assign g_on[gi] = gest[3 * gi +: 3] != 3'd0;", "assign g_on[gi] = 1'b1;"),
]
MUTANTS_G = [
    # the gesture point loaded on the frame the cursor moves (the shared add's cursor step); no clamp at 191
    ('rtl/pocket/nds_controls.sv', "if (!mv) begin g_x <= q_x; g_y <= q_y; end", "begin g_x <= q_x; g_y <= q_y; end"),
    ('rtl/pocket/nds_controls.sv', "py > 10'sd191 ? 8'd191", "py > 10'sd192 ? 8'd192"),
]
FW_SRCS = ['rtl/pocket/psx_pocket_pad_combo.sv', 'rtl/pocket/nds_controls.sv', 'rtl/pocket/nds_cart_scpu.sv',
           'sim/pocket_ds/tb_controls_fw.sv', 'sw/scpu/cache.c', 'sw/scpu/start.s', 'sw/scpu/link.ld'] + \
          sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'rtl/serv').glob('*.v'))
# each: a list of (file, old, new), all applied
MUTANTS_FW = [
    # A/B/X/Y a frame late in the snapshot: a gesture starts a frame late
    [('rtl/pocket/nds_controls.sv', "reg [12:0] snap = 0;", "reg [12:0] snap = 0; reg [3:0] fb_late = 0;"),
     ('rtl/pocket/nds_controls.sv', "if (frame) snap <= {pen, t_off, t_up, ana && !top_only, touch, keys[7:0]};",
      "if (frame) begin snap <= {pen, t_off, t_up, ana && !top_only, touch, fb_late, keys[3:0]}; fb_late <= keys[7:4]; end")],
    # the gesture's point clamped at 192
    [('sw/scpu/cache.c', "c_add(c_y, dy, 191) << 24", "c_add(c_y, dy, 192) << 24")],
    # the cursor clamped at 192
    [('sw/scpu/cache.c', "c_y = c_add(c_y, dy, 191);", "c_y = c_add(c_y, dy, 192);")],
    # the left stick's release threshold for down/right at 0xB0 (not 0xA8)
    [('sw/scpu/cache.c', "(v > 42) << 3", "(v > 44) << 3")],
    # a gesture started again by the firmware's write after touch mode went off and on
    [('rtl/pocket/nds_controls.sv', "else if (io_we1) g_act <= io_wd[8] && !t_off;", "else if (io_we1) g_act <= io_wd[8];")],
    # the cursor hidden by the firmware's write after touch mode was switched on in the window
    [('rtl/pocket/nds_controls.sv', "shown_q <= io_wd[9] || t_up;", "shown_q <= io_wd[9];")],
    # the idle count not reset by touch mode switched on between frames
    [('sw/scpu/cache.c', "u32 i = c_st & S_CTUP ? 180 : c_idle;", "u32 i = c_idle;")],
]


def run(d):
    obj = d / 'obj'
    cmd = [str(TOOLS / 'verilator'), '--binary', '--timing', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-j', '6',
           '--top-module', 'tb_controls_eq', '--Mdir', str(obj), *[str(d / s) for s in SRCS], str(d / 'old.sv')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        return 'build failed: ' + (r.stdout + r.stderr)[-800:]
    r = subprocess.run([str(obj / 'Vtb_controls_eq')], capture_output=True, text=True)
    print('   ', next((l for l in r.stdout.splitlines() if 'cycles' in l), ''))
    return 'PASS' if 'EQUIVALENT' in r.stdout and 'NOT' not in r.stdout else 'FAIL: ' + r.stdout.strip().splitlines()[0]


def tree(name, old, srcs):
    d = ROOT / 'build/controls_eq' / name
    shutil.rmtree(d, ignore_errors=True)
    for s in srcs:
        (d / s).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / s, d / s)
    (d / 'old.sv').write_text(old)
    return d


def fw_build(d):
    """d's firmware image as hex words (as sim/ds/ds.mk builds sw/scpu/cache.bin), or an error"""
    elf, b = d / 'cache.elf', d / 'cache.bin'
    r = subprocess.run(['clang', '--target=riscv32', '-march=rv32i', '-mabi=ilp32', '-Os', '-ffreestanding', '-nostdlib',
                        '-fno-builtin', '-fuse-ld=lld', '-Wl,--relax-gp', f'-Wl,-T,{d}/sw/scpu/link.ld',
                        str(d / 'sw/scpu/start.s'), str(d / 'sw/scpu/cache.c'), '-o', str(elf)], capture_output=True, text=True)
    if r.returncode:
        return None, 'firmware build failed: ' + r.stderr[-400:]
    subprocess.run(['llvm-objcopy', '-O', 'binary', str(elf), str(b)], check=True)
    data = b.read_bytes()
    if len(data) > 4096:
        return None, f'firmware over 4 KiB ({len(data)})'
    data += bytes(-len(data) % 4)
    (d / 'fw.hex').write_text(''.join('%08x\n' % int.from_bytes(data[i:i + 4], 'little') for i in range(0, len(data), 4)))
    return d / 'fw.hex', len(data)


def run_fw(d, seeds, nframes, frames=1, client=1):
    hexf, size = fw_build(d)
    if hexf is None:
        return size, []
    obj = d / 'obj'
    cmd = [str(TOOLS / 'verilator'), '--binary', '--timing', '-O2', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC',
           '-Wno-PINMISSING', '-j', '6', '--top-module', 'tb_controls_fw', '--Mdir', str(obj),
           *[str(d / s) for s in FW_SRCS if s.endswith(('.sv', '.v'))], str(d / 'old.sv')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        return 'build failed: ' + (r.stdout + r.stderr)[-800:], []
    outs, fails = [], 0
    for s in seeds:
        r = subprocess.run([str(obj / 'Vtb_controls_fw'), f'+verilator+seed+{s}', f'+fw={hexf}', f'+frames={frames}',
                            f'+nframes={nframes}', f'+client={client}'], capture_output=True, text=True)
        out = r.stdout
        outs.append(out)
        ok = 'EQUIVALENT' in out and 'NOT' not in out
        fails += frames and not ok
        print(f'    seed {s}: ' + ' | '.join(l for l in out.splitlines() if re.match(r"(\d+ cycles|window|misses|DIFF|NOT|EQUIV|NO FRAMES|debug)", l)))
    shutil.rmtree(obj, ignore_errors=True)
    if not frames:
        return 'CONTROL', outs
    return ('PASS' if fails == 0 else f'FAIL: {fails}/{len(seeds)} seeds'), outs


def main_fw(rev, nseeds, nframes, mutants=True, control=True):
    old = subprocess.run(['git', '-C', str(ROOT), 'show', f'{rev}:rtl/pocket/nds_controls.sv'],
                         capture_output=True, text=True, check=True).stdout
    old = old.replace('module nds_controls (', 'module nds_controls_old (').replace('module nds_controls #(', 'module nds_controls_old #(')
    seeds = list(range(1, nseeds + 1))
    print(f'reference ({rev}), {nseeds} seeds x {nframes} frames:')
    res, outs = run_fw(tree('fw_ref', old, FW_SRCS), seeds, nframes)
    print('reference:', res)
    if res != 'PASS':
        sys.exit(1)
    if control:
        print('control run (no frames: the misses without the controls):')
        run_fw(tree('fw_ctl', old, FW_SRCS), seeds, nframes, frames=0)
        print('no cart reads (the controls window alone):')
        run_fw(tree('fw_quiet', old, FW_SRCS), seeds[:1], min(nframes, 100), client=0)
    missed = 0
    for i, edits in enumerate(MUTANTS_FW if mutants else []):
        d = tree(f'fw_mut{i}', old, FW_SRCS)
        for f, o, n in edits:
            s = (d / f).read_text()
            assert s.count(o) == 1, o
            (d / f).write_text(s.replace(o, n))
        res, _ = run_fw(d, seeds[:2], min(nframes, 150))
        caught = res.startswith('FAIL')
        missed += not caught
        print(f'{i} {"caught" if caught else "MISSED"} [{edits[-1][2][:70]}] {res[:100]}')
    shutil.rmtree(ROOT / 'build/controls_eq', ignore_errors=True)
    sys.exit(1 if missed else 0)


def main():
    args = sys.argv[1:]
    if '--fw' in args:
        args.remove('--fw')
        nseeds, nframes = 4, 300
        if '--seeds' in args:
            i = args.index('--seeds'); nseeds = int(args[i + 1]); del args[i:i + 2]
        if '--nframes' in args:
            i = args.index('--nframes'); nframes = int(args[i + 1]); del args[i:i + 2]
        flags = {f: f in args for f in ('--no-mutants', '--no-control')}
        args = [a for a in args if a not in flags]
        return main_fw(args[0] if args else 'HEAD', nseeds, nframes, not flags['--no-mutants'], not flags['--no-control'])
    rev = args[0] if args else '11be2ed7'
    old = subprocess.run(['git', '-C', str(ROOT), 'show', f'{rev}:rtl/pocket/nds_controls.sv'],
                         capture_output=True, text=True, check=True).stdout
    old = old.replace('module nds_controls (', 'module nds_controls_old (').replace('module nds_controls #(', 'module nds_controls_old #(')
    global SRCS, MUTANTS
    if 'input wire [11:0] gest' in old:
        SRCS = SRCS[:-1] + ['sim/pocket_ds/tb_controls_eq_g.sv']
        MUTANTS = MUTANTS_G
    res = run(tree('ref', old, SRCS))
    print('reference:', res)
    if res != 'PASS':
        sys.exit(1)
    missed = 0
    for i, (f, o, n) in enumerate(MUTANTS):
        d = tree(f'mut{i}', old, SRCS)
        s = (d / f).read_text()
        assert s.count(o) == 1, o
        (d / f).write_text(s.replace(o, n))
        res = run(d)
        caught = res.startswith('FAIL')
        missed += not caught
        print(f'{i} {"caught" if caught else "MISSED"} [{n[:60]}] {res[:100]}')
    shutil.rmtree(ROOT / 'build/controls_eq', ignore_errors=True)
    sys.exit(1 if missed else 0)


if __name__ == '__main__':
    main()
