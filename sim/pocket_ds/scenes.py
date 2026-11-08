#!/usr/bin/env python3
"""Saved scenes on the Pocket model: the gate before a build goes on the card (docs/pocket-sim.md).

    scenes.py [--only NAME[,NAME]] [--jobs N] [--update]

Each scene in sim/pocket_ds/scenes.txt is a melonDS savestate (build/census/states in the
main checkout). For each: census --export-state and sim/ds/state_import.py (cached in
build/scenes/NAME/exp), melonDS's own frames after the load (build/scenes/NAME/mel), then
run.py --nodebug --import: core_top_ds with the tree's own parameters, as the fit builds it
(NDS_DEBUG 0, the Pocket's 12,288 cache slots; only MEM_DIRTY differs, 0 for the import).

A scene fails if the import never releases, the run fails (model, video or FIFO errors), a
DS frame underruns, or a screen differs from melonDS's frames by more pixels than the
accepted baseline in scenes.txt (plus SLACK). A frame's difference is its least over
melonDS's frames near it (the Pocket's frame k after the release shows melonDS's frame k-4..k+1),
from the 4th frame after the release on. --update writes the measured values as the baseline.
"""
import argparse
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MAIN = Path.home() / 'Git/NDS_Pocket'
STATES = MAIN / 'build/census/states'
ROMS = MAIN / 'roms'
TABLE = ROOT / 'sim/pocket_ds/scenes.txt'
SLACK = 256                     # pixels per screen above the baseline


def census_bin():
    for c in (ROOT / 'build/census-melonds/build/census', MAIN / 'build/census-melonds/build/census'):
        if c.exists():
            return c
    sys.exit('no census build: run tools/melonds-census/build.sh')


def read_table():
    rows = []
    for l in TABLE.read_text().splitlines():
        p = l.split()
        if p and not p[0].startswith('#'):
            rows.append(dict(name=p[0], rom=p[1], state=p[2], frames=int(p[3]),
                             top=None if p[4] == '-' else int(p[4]), bottom=None if p[5] == '-' else int(p[5]),
                             known=len(p) > 6 and p[6] == 'known',
                             hold=next((x[5:] for x in p[6:] if x.startswith('hold=')), None)))
    return rows


KEYS = ('A', 'B', 'SELECT', 'START', 'RIGHT', 'LEFT', 'UP', 'DOWN', 'R', 'L', 'X', 'Y')   # census's names, the DS's bit order


def hold_script(s, out):
    """a scene's held keys (scenes.txt hold=UP+B): melonDS's script, pressed from the state's frame 0 on"""
    if not s.get('hold'):
        return '/dev/null'
    f = Path(out).parent / f'hold-{s["name"]}.txt'
    f.write_text(f'0 1000000 {" ".join(s["hold"].split("+"))}\n')
    return str(f)


def hold_mask(s):
    """the same keys for the core: tb_ds_pocket +hold, core_top's keys (pressed = 1) forced from the release on"""
    m = 0
    for k in s['hold'].split('+'):
        m |= 1 << KEYS.index(k)
    return f'{m:03x}'


def census(s, out, *extra):
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    cmd = [str(census_bin()), '--bios9', str(ROMS / 'bios9.bin'), '--bios7', str(ROMS / 'bios7.bin'),
           '--firmware', str(ROMS / 'firmware.bin'), '--rom', str(ROMS / s['rom']), '--script', hold_script(s, out),
           '--out', str(out), '--load-state', str(STATES / s['state']), *extra]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f'census: {r.stderr[-2000:]}')


def swaps_cover(mel, n):
    """melonDS's swap log (census --swap-log) reaches frame n (a --frames run longer than the cached one needs more)"""
    f = mel / 'swaps.txt'
    if not f.exists():
        return False
    last = [l.split()[0] for l in f.read_text().splitlines() if l.strip()]
    return bool(last) and int(last[-1]) >= n


def prepare(s, d):
    """the export and melonDS's frames, redone when the state or the census build is newer
    (without the state, as on the Laptop through tools/laptop-run.sh: the ones there)"""
    exp, mel = d / 'exp', d / 'mel'
    if s['state'].startswith('exports/'):
        # a prepared clean export (census --export-clean: exp/ and mel/shots) in the main checkout's build/census
        src = MAIN / 'build/census' / s['state']
        if not src.exists():
            if (exp / 'import.txt').exists():
                return                      # (the Laptop: the copy already here)
            raise RuntimeError(f'no {src}')
        if not (exp / 'import.txt').exists() or (exp / 'import.txt').stat().st_mtime < (src / 'exp/import.txt').stat().st_mtime:
            shutil.rmtree(exp, ignore_errors=True)
            shutil.rmtree(mel, ignore_errors=True)
            shutil.copytree(src / 'exp', exp)
            shutil.copytree(src / 'mel', mel)
        return
    st = STATES / s['state']
    if not st.exists():
        if (exp / 'import.txt').exists() and (mel / 'shots' / f'f{s["frames"] + 12:06d}.ppm').exists():
            if swaps_cover(mel, s['frames'] + 12):
                return
            raise RuntimeError(f'no {st}, and mel/swaps.txt ends before frame {s["frames"] + 12}: prepare the scene '
                               'on the Desktop first (scenes.py --frames N there, or its census swap log)')
        raise RuntimeError(f'no {st}')
    newest = max(st.stat().st_mtime, census_bin().stat().st_mtime, Path(__file__).stat().st_mtime)
    last = mel / 'shots' / f'f{s["frames"] + 12:06d}.ppm'
    if (exp / 'import.txt').exists() and last.exists() and min((exp / 'import.txt').stat().st_mtime, last.stat().st_mtime) >= newest:
        if not swaps_cover(mel, s['frames'] + 12):     # (exports made before the pace check, or a shorter run's)
            census(s, d / 'swaps-run', '--frames', str(s['frames'] + 12), '--shot-every', '0',
                   '--swap-log', str(mel / 'swaps.txt'))
            shutil.rmtree(d / 'swaps-run', ignore_errors=True)
        return
    # one census run: the export at the first line where the geometry engine is idle (--export-clean,
    # docs/state-import.md), and melonDS's frames from there on
    census(s, mel, '--frames', str(s['frames'] + 12), '--shot-every', '1', '--export-clean', str(exp),
           '--swap-log', str(mel / 'swaps.txt'))
    subprocess.run([sys.executable, str(ROOT / 'sim/ds/state_import.py'), str(exp)], check=True, capture_output=True)


def screens(p):
    """a 256x384 P6 PPM (both writers' format) as its two screens' RGB bytes (no PIL: the Laptop has none)"""
    data = p.read_bytes()
    end = 0
    for _ in range(3):
        end = data.index(b'\n', end) + 1
    px = data[end:end + 256 * 384 * 3]
    return [px[:256 * 192 * 3], px[256 * 192 * 3:]]


def diff(a, b):
    return sum(1 for i in range(0, len(a), 3)
               if max(abs(a[i] - b[i]), abs(a[i + 1] - b[i + 1]), abs(a[i + 2] - b[i + 2])) > 8)


PACE_MIN = 30                                                          # melonDS swaps for a resolved pace
OPT = {'tag': '', 'core_param': [], 'plus': [], 'diag': False}         # --tag, --core-param (a variant's runs beside the baseline's)


def not_run(s, detail):
    # a scene that didn't run (its import or run.py failed) is an ERROR, never KNOWN: it measured nothing
    return dict(s, known=False, error=True), False, detail, None


def run_scene(s, update, no_run=False):
    d = ROOT / 'build/scenes' / s['name']
    d.mkdir(parents=True, exist_ok=True)
    try:
        prepare(s, d)
    except (RuntimeError, subprocess.CalledProcessError) as e:
        return not_run(s, f'prepare: {e}')
    sfx = '-' + OPT['tag'] if OPT['tag'] else ''
    shots, log_p = d / ('pocket' + sfx), d / f'run{sfx}.log'
    if no_run:
        return compare(s, d, shots, update, log_p)
    for f in shots.glob('*.ppm'):
        f.unlink()
    # the release comes 6-8 video frames in; run the scene's frames past it
    cmd = [sys.executable, str(ROOT / 'sim/pocket_ds/run.py'), '--nodebug', '--rom', str(ROMS / s['rom']),
           '--import', str(d / 'exp'), '--frames', str(s['frames'] + 9), '--shots', str(shots), '--out', str(d / ('run' + sfx)),
           '--obj-root', str(ROOT / 'build/scenes/_obj')]
    for p in OPT['core_param']:
        cmd += ['--core-param', p]
    for p in OPT['plus']:
        cmd += ['--plus', p]
    if s.get('hold'):
        cmd += ['--plus', 'hold=' + hold_mask(s)]
    ndg = d / f'diag{sfx}.ndg'
    if OPT['diag']:
        # the log read back at quit, up to the last frame record (docs/diag.md layout)
        cmd += ['--diag-out', str(ndg), '--diag-words', str(0x4400 + 64 * (s['frames'] + 12))]
    with open(log_p, 'w') as log:
        rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
    if rc:
        return not_run(s, f'run.py exit {rc} (see {log_p})')
    if OPT['diag']:
        r = subprocess.run([sys.executable, str(ROOT / 'sim/pocket_ds/diag_check.py'), str(log_p), str(ndg)],
                           capture_output=True, text=True)
        (d / f'diag_check{sfx}.txt').write_text(r.stdout + r.stderr)
        if r.returncode:
            return s, False, f'diag_check: {(r.stdout.strip().splitlines() or ["?"])[-1]} (see diag_check{sfx}.txt)', None
    return compare(s, d, shots, update, log_p)


def compare(s, d, shots, update, log_p):
    if not log_p.exists():
        return not_run(s, f'no run log ({log_p})')
    text = log_p.read_text(errors='replace')
    # the testbench's ERROR lines, and Verilator's for $error/$fatal and assertions (%Error, %Fatal: the ring's
    # "staging slot ... still holds line" check printed %Error and the scene still passed)
    errs = [l.strip() for l in text.splitlines() if 'ERROR' in l or '%Error' in l or '%Fatal' in l]
    if errs:
        return s, False, f'{len(errs)} error lines, first: {errs[0][:160]}', None
    m = re.search(r'import: released at \d+, video frame (\d+)', text)
    if not m:
        return not_run(s, 'import never released')
    rel = int(m.group(1))
    # 2D lines the display missed after the release (a stale line on screen): any fails the scene
    # (only the run's frames: the quit read-backs after the 'video:' summary load the SDRAM and are not play)
    run_end = text.find('\nvideo: ')
    run = text if run_end < 0 else text[:run_end]
    late2d = sum(int(x) for x in re.findall(r'g2d LATE: (\d+) 2D lines late', run[run.index(m.group(0)):]))
    if late2d:
        return s, False, f'{late2d} 2D lines late after the release', None
    u = re.search(r'underruns (\d+)', text)
    if not u or int(u.group(1)):
        return s, False, f'underruns {u.group(1) if u else "?"}', None
    # melonDS's shots are numbered from the load; the export (the release) is in frame e0 (exp/clean.txt)
    e0 = int((d / 'exp/clean.txt').read_text().split()[1]) if (d / 'exp/clean.txt').exists() else 0
    mel = {}
    for f in (d / 'mel/shots').glob('f*.ppm'):
        mel[int(f.stem[1:]) - e0] = screens(f)
    worst, per = [0, 0], []
    for f in sorted(shots.glob('f*.ppm')):
        v = int(f.stem[1:])
        k = v - rel
        if k < 4:
            continue
        ours = screens(f)
        best = [min((diff(ours[h], mel[j][h]) for j in range(k - 4, k + 2) if j in mel), default=None) for h in (0, 1)]
        if None in best:
            continue
        per.append((v, *best))
        worst = [max(worst[h], best[h]) for h in (0, 1)]
    if len(per) < s['frames'] // 2:
        return s, False, f'only {len(per)} frames to compare', worst
    # stale-ring rows (a row repeating the one 4 or 8 lines above where melonDS's differ, stale_rows.py): a
    # failure even in a known scene, since the ring showing an old line is always a bug
    import stale_rows
    stale = 0
    for f in sorted(shots.glob('f*.ppm')):
        k = int(f.stem[1:]) - rel
        cands = [j for j in range(k - 4, k + 2) if j in mel]
        if k < 4 or not cands:
            continue
        cpx = stale_rows.px(f)
        mfile = {j: d / 'mel/shots' / f'f{j + e0:06d}.ppm' for j in cands}
        mj = min(cands, key=lambda j: sum(diff(screens(f)[h], mel[j][h]) for h in (0, 1)))
        stale += len(stale_rows.stale_in(cpx, stale_rows.px(mfile[mj])))
    # pace: 3D frames the game finished (swaps) over the compared frames, against melonDS's over the same
    # game frames (mel/swaps.txt, census --swap-log: cumulative by frame, numbered as its shots). A count of
    # M swaps resolves the rate to about one swap, +-100/M %: with M >= PACE_MIN (the 10-frame gate scenes
    # give 4-10, --frames 64 gives 30-60) below 95 % fails; with fewer it is reported as not resolved and
    # fails only when it is below 95 % by more than that resolution (a 10-frame scene can't tell 21 from
    # 30 fps: 4/5 swaps would pass)
    pace, pace_note = None, ''
    ps = {int(v): int(n) for n, v in re.findall(r'g3d swaps: (\d+) at video frame (\d+)', run)}
    if (d / 'mel/swaps.txt').exists() and ps:
        ms = {int(a): int(b) for a, b in (l.split() for l in (d / 'mel/swaps.txt').read_text().splitlines() if l.strip())}
        v0, v1 = rel + 4, max(ps)
        if v1 > v0 and v0 in ps and (v0 - rel + e0) in ms and (v1 - rel + e0) in ms:
            p_sw, m_sw = ps[v1] - ps[v0], ms[v1 - rel + e0] - ms[v0 - rel + e0]
            if m_sw > 0:
                pace = (p_sw, m_sw, v1 - v0)
        elif ms and v1 > v0:
            pace_note = f'; pace not measured: melonDS\'s swap log ends at frame {max(ms)} (prepare the scene again)'
    skipped = run.count('frame start skipped')
    late = sum(int(x) for x in re.findall(r'g3d LATE: (\d+) 3D lines late in the last frame', run))
    detail = (f'released at video frame {rel}; {len(per)} frames; most differing pixels top {worst[0]}, bottom {worst[1]}; '
              f'3D: {skipped} frame starts skipped, {late} late lines; 2D: {late2d} late lines; stale ring rows {stale}'
              + (f'; pace {pace[0]}/{pace[1]} swaps in {pace[2]} frames ({100 * pace[0] / pace[1]:.0f}% of melonDS, '
                 f'+-{100 / pace[1]:.0f}%{"" if pace[1] >= PACE_MIN else ", not resolved: --frames 64"})' if pace else pace_note))
    if stale:
        s = dict(s, known=False)                # (a known scene still fails on stale rows)
        return s, False, detail + ' (stale ring rows)', worst
    if pace and (pace[0] < 0.95 * pace[1] if pace[1] >= PACE_MIN else pace[0] + 1 < 0.95 * pace[1]):
        return s, False, detail + ' (slower than melonDS)', worst

    if update:
        return s, True, detail, worst
    for h, key in ((0, 'top'), (1, 'bottom')):
        if s[key] is not None and worst[h] > s[key] + SLACK:
            return s, False, detail + f' ({key} over the baseline {s[key]} + {SLACK})', worst
    return s, True, detail, worst


def verdict(s, passed):
    # a known-failing scene (scenes.txt 'known': an acceptance scene for a fix to come) is reported, not counted;
    # a scene that didn't run is an ERROR and fails the sweep
    return 'ERROR' if s.get('error') else 'PASS' if passed else 'KNOWN' if s['known'] else 'FAIL'


def main():
    # Disk guard: the shared Desktop disk filled up three times on 2026-11-06.
    # Sim builds take 1-4 GB each; stop here rather than fill the disk.
    free_gb = shutil.disk_usage(ROOT).free / 2**30
    if free_gb < 30 and not os.environ.get('NDS_DISK_GUARD_OFF'):
        sys.exit(f'only {free_gb:.0f} GB free on the disk (need 30): delete finished '
                 'sim builds, or wait for the hourly nds-disk-prune timer')
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', help='scene names, comma-separated')
    ap.add_argument('--jobs', type=int, default=3, help='scenes at once (AGENTS.md: at most 3 sims per session)')
    ap.add_argument('--update', action='store_true', help='write the measured differences as the baseline')
    ap.add_argument('--no-run', action='store_true', help='compare the last runs again (build/scenes/NAME/run.log, pocket/)')
    ap.add_argument('--core-param', action='append', default=[], metavar='NAME=V',
                    help='a core_top_ds parameter for a variant (run.py --core-param), e.g. RING=1; needs --tag')
    ap.add_argument('--plus', action='append', default=[], help='an extra plusarg for the runs (run.py --plus), e.g. g3dperf')
    ap.add_argument('--diag', action='store_true',
                    help='the NDSDiag build (DIAG=1, a second record every 8 frames, tag diag): also checks its log '
                         'read back at quit against the testbench mirror (diag_check.py)')
    ap.add_argument('--frames', type=int, help='run each scene this many frames past the release instead of '
                    'scenes.txt\'s (a pace measurement: --frames 64 gives >= 30 swaps at 30 fps; the pixel baselines '
                    'are for the table\'s frames, so they are not checked; needs --tag)')
    ap.add_argument('--tag', default='', help="a variant's name: its runs go to run-TAG/, pocket-TAG/, run-TAG.log")
    a = ap.parse_args()
    if a.diag:
        a.core_param += ['DIAG=1', 'DIAG_SEC=8']
        a.tag = a.tag or 'diag'
    if a.core_param and not a.tag:
        sys.exit('--core-param needs --tag (the baseline runs stay the default build)')
    if a.frames and (not a.tag or a.update):
        sys.exit('--frames needs --tag and no --update (the baselines are for scenes.txt\'s frames)')
    if a.update and a.tag:
        sys.exit('--update writes the baseline of the default build: not with --tag')
    OPT['tag'], OPT['core_param'], OPT['plus'], OPT['diag'] = a.tag, a.core_param, a.plus, a.diag
    rows = read_table()
    todo = [s for s in rows if not a.only or s['name'] in a.only.split(',')]
    if a.frames:
        todo = [dict(s, frames=a.frames, top=None, bottom=None) for s in todo]
    subprocess.run(['make', '-s', '-C', str(ROOT), 'build/boot/bootrom.hex'], check=True)
    with ThreadPoolExecutor(a.jobs) as ex:
        results = list(ex.map(lambda s: run_scene(s, a.update, a.no_run), todo))
    ok = True
    for s, passed, detail, worst in results:
        print(f'{s["name"]:12s} {verdict(s, passed)}  {detail}')
        ok &= verdict(s, passed) in ('PASS', 'KNOWN')
        if a.update and worst is not None:
            s['top'], s['bottom'] = worst
    if a.update:
        lines = []
        for l in TABLE.read_text().splitlines():
            p = l.split()
            r = next((s for s in rows if p and s['name'] == p[0]), None)
            lines.append(l if r is None else f'{r["name"]:12s} {r["rom"]:14s} {r["state"]:16s} {r["frames"]:<6d} '
                         f'{"-" if r["top"] is None else r["top"]:<6} {"-" if r["bottom"] is None else r["bottom"]:<6}'
                         f'{" known" if r["known"] else ""}'.rstrip())
        TABLE.write_text('\n'.join(lines) + '\n')
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
