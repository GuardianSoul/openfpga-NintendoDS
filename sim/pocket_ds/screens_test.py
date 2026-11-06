#!/usr/bin/env python3
"""The Pocket's stacked screens against tb_ds's (docs/phase2-integration.md).

    sim/pocket_ds/screens_test.py [--rom build/ds-tests/hello.nds] [--frames 20]

Runs the ROM in tb_ds and in the whole-chip simulation (sim/pocket_ds/run.py)
and compares the Pocket's last frame, pixel for pixel, with tb_ds's frames:
tb_ds places the engines by POWCNT1 bit 15 itself, and the Pocket's video
output (nds_video, the stacked layout) must equal one of them. (The Pocket's
boot also clears memory, about 38 frames that tb_ds skips, and hello.nds
prints a frame counter, so the matching tb_ds frame is searched for.)
"""
import argparse
import concurrent.futures as cf
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
RD = Path.home() / 'Git/NDS_Pocket/roms'


def ppm(path):
    d = path.read_bytes()
    parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]


# planted bugs the comparison must catch (file under rtl/, old, new)
MUTANTS = [
    ('pocket/nds_video.sv', "wire bot_px = px_eng == top_a;", "wire bot_px = px_eng != top_a;"),
    ('pocket/nds_video.sv', "wire de0 = buf_de || live_de || lead_de || pad_de;", "wire de0 = buf_de || live_de || pad_de;"),
    ('pocket/nds_video.sv', "(lead_line ? hc >= 16 && hc < 20 :", "(lead_line ? hc < 4 :"),
    # the SDRAM bus (M1): read words to their owner, VRAM blocks of 32 bytes
    ('pocket/nds_sdram_bus.sv', "w_valid[own[own_r]] <= 1'b1;", "w_valid[own[own_w]] <= 1'b1;"),
    ('pocket/core_top_ds.sv', "nds_sdram_xport #(.QW(8), .SHARED(1)) x_vram", "nds_sdram_xport #(.QW(4), .SHARED(1)) x_vram"),
    # the SRAM's measured access times (sram_model): reads sampled 2 clocks
    # after the address, a 1-clock WE# pulse (the first nds_sram, #211)
    ('pocket/nds_sram.sv', "parameter int RA = 3,", "parameter int RA = 2,"),
    ('pocket/nds_sram.sv', "parameter int WP = 3 ", "parameter int WP = 1 "),
    # the pad line that makes a frame's DE lines even (the APF scaler)
    ('pocket/nds_video.sv', "if (k == 8'd192) obuf <= 0;", "if (k == 8'd191) obuf <= 0;"),
    # the bottom screen's writes through the controller's write FIFO
    ('pocket/core_top_ds.sv', ".bw_addr(bw_q[55:32])", ".bw_addr(bw_q[55:32] ^ 24'd1)"),
    # main RAM straight to the PSRAM: a line's words in order
    ('pocket/nds_psram.sv', "if (!b_write) begin out_n <= 3'd4; out_k <= 2'd0; end", "if (!b_write) begin out_n <= 3'd4; out_k <= 2'd1; end"),
    # the shared read-word FIFOs (M10K): each word to the client that read it
    ('pocket/nds_sdram_bus.sv', "if (SEL[i] && w_valid[i]) id = i[IW-1:0];", "if (SEL[i] && w_valid[i]) id = 0;"),
    # main RAM's PSRAM request fields formed on clk_sys (#317 timing): a read's quad address
    ('pocket/nds_psram.sv', "b_word <= s_we ? s_addr[20:0] : {s_addr[20:2], 2'b00};", "b_word <= s_we ? s_addr[20:0] : {s_addr[20:2], 2'b01};"),
    # the ports' requests as views of their held b_* (port views)
    ('pocket/nds_sdram_bus.sv', "assign m_addr = b_addr; assign m_n = b_we ? 4'd1", "assign m_addr = b_addr ^ 24'd8; assign m_n = b_we ? 4'd1"),
    # (nds_vram's block pipelining has its own randomized test with mutations,
    # sim/ds/vram_test.py: hello.nds rarely overlaps a CPU access with a block)
]


def compare(tbdir, pkdir):
    """None if the Pocket's last frame equals one tb_ds frame (top exact,
    bottom at the RGB565 it is stored in), else a description."""
    shots = sorted(pkdir.glob('f*.ppm'))
    if not shots:
        return 'no Pocket frames'
    w2, h2, pk = ppm(shots[-1])
    q = lambda b, i: b[i] >> (2 if i % 3 == 1 else 3)
    best = None
    for f in sorted(tbdir.glob('f*.ppm')):
        w1, h1, tb = ppm(f)
        if (w1, h1) != (w2, h2):
            return f'sizes differ: tb {w1}x{h1}, Pocket {w2}x{h2}'
        row = 3 * w1
        bad = []
        for y in range(h1):
            a, b = tb[y * row:(y + 1) * row], pk[y * row:(y + 1) * row]
            if y < 192 and a != b or y >= 192 and any(q(a, i) != q(b, i) for i in range(row)):
                bad.append(y)
        if best is None or len(bad) < len(best[1]):
            best = (f.name, bad)
    name, bad = best
    if bad:
        return f'closest tb_ds {name}: {len(bad)} rows differ, first {bad[:8]}'
    return None


def pocket(rom, frames, out, rtl=None):
    shutil.rmtree(out / 'pocket', ignore_errors=True)
    (out / 'pocket').mkdir(parents=True)
    r = subprocess.run([sys.executable, str(ROOT / 'sim/pocket_ds/run.py'), '--rom', rom, '--frames', str(frames),
                        '--shots', str(out / 'pocket'), '--out', str(out / 'build'),
                        *(['--rtl-root', str(rtl)] if rtl else [])], capture_output=True, text=True)
    errs = [l for l in (r.stdout + r.stderr).splitlines() if 'ERROR' in l]
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rom', default=str(ROOT / 'build/ds-tests/hello.nds'))
    ap.add_argument('--frames', type=int, default=60)
    ap.add_argument('--out', default=str(ROOT / 'build/screens'))
    ap.add_argument('--mutate', action='store_true', help='also run the planted bugs (in parallel)')
    ap.add_argument('--only', help='with --mutate: comma-separated mutant numbers')
    a = ap.parse_args()
    out = Path(a.out)
    (out / 'tb').mkdir(parents=True, exist_ok=True)
    subprocess.run(['make', '-s', '-C', str(ROOT), 'ds-sim'], check=True)
    subprocess.run([str(ROOT / 'build/ds/obj/Vnds_top'), '--rom', a.rom, '--bios9', str(RD / 'bios9.bin'),
                    '--bios7', str(RD / 'bios7.bin'), '--firmware', str(RD / 'firmware.bin'),
                    '--frames', str(a.frames), '--shots', str(out / 'tb'), '--shot-every', '1',
                    '--quiet'], check=True, capture_output=True)

    def one(i):
        d = out / ('ref' if i < 0 else f'mut{i}')
        rtl = None
        if i >= 0:
            f, old, new = MUTANTS[i]
            rtl = d / 'rtl'
            shutil.rmtree(rtl, ignore_errors=True)
            shutil.copytree(ROOT / 'rtl', rtl)
            t = (rtl / f).read_text()
            assert t.count(old) == 1, old
            (rtl / f).write_text(t.replace(old, new))
        errs = pocket(a.rom, a.frames, d, rtl)
        return i, (errs[0] if errs else compare(out / 'tb', d / 'pocket'))

    sel = [int(x) for x in a.only.split(',')] if a.only else list(range(len(MUTANTS)))
    runs = [-1] + (sel if a.mutate else [])
    fail = 0
    with cf.ThreadPoolExecutor(len(runs)) as ex:
        for i, res in ex.map(one, runs):
            if i < 0:
                print('reference:', 'PASS' if res is None else 'FAIL ' + res)
                fail += res is not None
            else:
                print(f'mutation {i} [{MUTANTS[i][2][:50]}]:', 'MISSED' if res is None else 'caught: ' + res)
                fail += res is None
    sys.exit(1 if fail else 0)

if __name__ == '__main__':
    main()
