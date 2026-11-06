#!/usr/bin/env python3
"""A scripted NSMB player by search, to reach busy level sections for scenes (docs/pocket-sim.md).

    play_search.py STATE.mln OUTDIR [--segments N] [--len FRAMES]

From a census savestate inside a level, each step tries a set of key segments (RIGHT+Y held, with A jumps
at different times and lengths) from the current state, scores each by how far right Mario's icon is on
the bottom screen's level-progress bar after the segment (back on the world map, i.e. dead, scores -1),
keeps the best, saves the state after it and goes on. Prints each step's score and the 3D polygons drawn
(census --final-bgx), and writes OUTDIR/step_NNN.mln states, OUTDIR/route.txt (the whole key script from
STATE) and OUTDIR/steps.txt.
"""
import argparse
import itertools
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ROMS = Path.home() / 'Git/NDS_Pocket/roms'
CENSUS = ROOT / 'build/census-melonds/build/census'


def icon_x(ppm):
    """the Mario icon's x on the progress bar (bottom screen, rows 230-250: red cap pixels), -1 if none"""
    d = ppm.read_bytes()
    e = 0
    for _ in range(3):
        e = d.index(b'\n', e) + 1
    px = d[e:]
    xs = []
    for y in range(232, 252):
        for x in range(8, 248):
            i = (y * 256 + x) * 3
            r, g, b = px[i], px[i + 1], px[i + 2]
            if r > 170 and g < 80 and b < 80:
                xs.append(x)
    return sum(xs) / len(xs) if len(xs) >= 6 else -1


def run(state, script, frames, out, save=None):
    out.mkdir(parents=True, exist_ok=True)
    (out / 'keys.txt').write_text(script)
    cmd = [str(CENSUS), '--bios9', str(ROMS / 'bios9.bin'), '--bios7', str(ROMS / 'bios7.bin'),
           '--firmware', str(ROMS / 'firmware.bin'), '--rom', str(ROMS / 'nsmb.nds'), '--script', str(out / 'keys.txt'),
           '--out', str(out), '--frames', str(frames), '--shot-every', str(frames), '--load-state', str(state),
           '--final-bgx', '1']
    if save:
        cmd += ['--save-state', str(save), '--save-state-at', str(frames - 1)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    m = re.search(r'polys (\d+)', r.stdout)
    shot = out / 'shots' / f'f{frames:06d}.ppm'
    polys = int(m.group(1)) if m else 0
    # Mario is a 3D model: (nearly) no polygons means he is dying or the level is gone
    return (icon_x(shot) if shot.exists() and polys >= 50 else -1), polys


def candidates(n):
    """key segments of n frames: RIGHT+Y held, jumps (A) starting at t for d frames, up to two"""
    base = f'0 {n - 1} RIGHT Y\n'
    out = [base]
    starts = range(0, n - 8, 8)
    for t in starts:
        for d in (6, 14, 24):
            out.append(base + f'{t} {min(n - 1, t + d)} A\n')
    for t1, t2 in itertools.combinations(range(0, n - 8, 16), 2):
        out.append(base + f'{t1} {t1 + 14} A\n{t2} {min(n - 1, t2 + 14)} A\n')
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('state')
    ap.add_argument('out')
    ap.add_argument('--segments', type=int, default=20)
    ap.add_argument('--len', type=int, default=48)
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    state = Path(a.state)
    route, t0 = [], 0
    with open(out / 'steps.txt', 'w') as log:
        for step in range(a.segments):
            best = None
            for k, scr in enumerate(candidates(a.len)):
                x, polys = run(state, scr, a.len, out / 'try')
                if x < 0 or (best is not None and x <= best[0]):
                    continue
                # look ahead: some simple continuation (run on, or jump at once) must survive the next segment
                tmp = out / 'tmp.mln'
                run(state, scr, a.len, out / 'try', save=tmp)
                alive = any(run(tmp, c, a.len, out / 'try2')[0] >= 0
                            for c in (f'0 {a.len - 1} RIGHT Y\n', f'0 {a.len - 1} RIGHT Y\n0 14 A\n', f'0 {a.len - 1} Y\n'))
                if alive:
                    best = (x, polys, scr)
            if best is None:
                print(f'step {step}: no candidate survives; stop'); break
            x, polys, scr = best
            nxt = out / f'step_{step:03d}.mln'
            x2, polys2 = run(state, scr, a.len, out / 'keep', save=nxt)
            for l in scr.strip().splitlines():
                f0, f1, *keys = l.split()
                route.append(f'{t0 + int(f0)} {t0 + int(f1)} {" ".join(keys)}')
            t0 += a.len
            line = f'step {step}: frame {t0}, icon x {x2:.1f}, 3D polygons {polys2}, state {nxt.name}'
            print(line); log.write(line + '\n'); log.flush()
            state = nxt
    (out / 'route.txt').write_text('\n'.join(route) + '\n')
    shutil.rmtree(out / 'try', ignore_errors=True)


if __name__ == '__main__':
    main()
