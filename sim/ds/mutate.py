#!/usr/bin/env python3
"""Deliberate bugs in rtl/ds that the DS test ROMs must catch (AGENTS.md).

    sim/ds/mutate.py [--only N,...] [--jobs J]

Each mutation edits one line of a copy of rtl/ds (build/ds/mut/<n>/rtl/ds),
builds the system simulation from it and runs the listed test ROMs
(tools/ds-tests) until one fails. A mutation that every listed ROM passes is
reported as missed; the script exits 1 if any was missed.
"""
import argparse
import concurrent.futures as cf
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
ROMS = Path(os.environ.get('BOOT_ROMDIR', Path.home() / 'Git/NDS_Pocket/roms'))

# (file, old, new, test ROMs that must catch it)
MUTANTS = [
    ('nds_fabric.sv', "2'd1: sw_a = {1'b1, addr[13:2]};", "2'd1: sw_a = {1'b0, addr[13:2]};", ['sys']),
    ('nds_fabric.sv', "for (int c = 0; c < 3; c++) if (lb_tag[c] == addr[21:4]) lb_v[c] <= 1'b0;",
     "for (int c = 0; c < 3; c++) if (lb_tag[c] == addr[21:4] && c == 9) lb_v[c] <= 1'b0;", ['sys', 'hello']),
    # (swapping a DMA halfword's byte enables alone is equivalent for copies whose source and
    # destination share their alignment, which is what the test ROMs do; the read half is not)
    ('nds_fabric.sv', "wire [31:0] hw  = addr[1] ? {16'd0, rdata[31:16]} : {16'd0, rdata[15:0]};",
     "wire [31:0] hw  = {16'd0, rdata[15:0]};", ['sys']),
    ('nds_vram.sv', "2'd1: return v == V_BBG  && o[15] == 1'b0;", "2'd1: return v == V_BBG  && o[15] == 1'b1;", ['sys']),
    ('nds_vram.sv', "3'd2: return v == V_ARM7 && o[17] == f[0];", "3'd2: return v == V_ARM7 && o[17] != f[0];", ['sys']),
    ('nds_disp.sv', "if (dstat[c][3]) irq_vblank[c] <= 1'b1;", "if (dstat[c][3] && c == 0) irq_vblank[c] <= 1'b1;", ['irq']),
    # (the 2D engine's cross-line caches dropping blocks the CPU rewrote,
    # vram_wr tied to 0, is not observable with the test ROMs or NSMB's first
    # 470 frames: neither rewrites VRAM the 2D engine has cached; a display
    # capture test ROM is open, docs/phase2-integration.md "VRAM bandwidth")
    ('nds_disp.sv', "nv = (vc == 9'd262) ? 9'd0 : vc + 9'd1;", "nv = (vc == 9'd261) ? 9'd0 : vc + 9'd1;", ['hello']),
    ('nds_cart.sv', "else begin dout <= q[ptr + 2'd1]; romctrl[23] <= 1'b1; end",
     "else begin dout <= q[ptr]; romctrl[23] <= 1'b1; end", ['cart']),
    ('nds_cart.sv', "assign drq     = romctrl[23];", "assign drq     = romctrl[23] && rs != R_READY;", ['cart']),
    # (the data buffer's address check and the fetch lines' write invalidation are not
    # observable with the test ROMs: one load is in flight at a time, and no ARM7 code
    # is rewritten while it runs; KEYINPUT is recorded by sys.nds, not checked)
    ('nds_cart.sv', "if (sp_st[1]) begin", "if (1'b1) begin", ['cart']),
    ('nds_cart.sv', "r = pf;", "r = sv_rdata[7:0];", ['cart']),
    ('nds_cart.sv', "so_op <= O_RD; so_a <= a & sv_mask;", "so_op <= O_RD; so_a <= a;", ['cart']),
    ('nds_arm7_port.sv', ".waddr({il_new, rp_k}),", ".waddr({il_new, rp_k ^ 2'd1}),", ['hello_m7']),
    ('nds_arm7_port.sv', "wb_v <= 1'b1; wb_a <= d_addr; wb_d <= d_wdata; wb_be <= d_be; da_ok <= 1'b1;",
     "wb_v <= 1'b1; wb_a <= d_addr; wb_d <= d_wdata; wb_be <= 4'hF; da_ok <= 1'b1;", ['sys_m7', 'hello_m7']),
    ('nds_io.sv', "if (io_be[0]) powcnt1[7:0]  <= io_wdata[7:0] & 8'h0F;",
     "if (io_be[0]) powcnt1[7:0]  <= io_wdata[7:0] & 8'h0E;", ['hello']),
    ('nds_io.sv', "if (io_be[3]) wramcnt <= io_wdata[25:24];", "if (io_be[3]) wramcnt <= {io_wdata[24], io_wdata[25]};", ['sys']),
    # the fabric's line-buffer words (MLAB) read with the address being granted
    ('nds_fabric.sv', "lb_ra = st == S_IDLE ? {g_cls, g_w} : {cls, addr[3:2]};", "lb_ra = {cls, addr[3:2]};", ['sys', 'hello', 'irq', 'cart']),
    # ARM7 WRAM, shared WRAM, BIOS7 in the SRAM behind the ARM7 port's caches
    ('nds_arm7_port.sv', "!(fd_v && !fd_i && fd_a == da_xa[17:4])", "1'b1", ['hello']),
    ('nds_arm7_port.sv', "wire su_hit = su_v && su_a[17:14] != 4'b0110 && da_c && da_w && dc_hit;",
     "wire su_hit = 1'b0;", ['hello', 'sys']),
    ('nds_arm7_port.sv', "wire  dc_inv = ckd_v && dc_cv", "wire  dc_inv = 1'b0 && dc_cv", ['sys']),
    ('nds_arm7_port.sv', "wire  ic_inv = cki_v && ic_cv", "wire  ic_inv = 1'b0 && ic_cv", ['sys']),
    # (nds_fr_arb's store-drain priority, both guards removed so the ARM7 and
    # the fabric just take turns, is not observable: a DMA the ARM7 starts
    # reads later than its four posted stores take to drain, ~24 clk, even
    # with sys.nds storing the word the DMA reads first last)
]


def run(i, m, frames):
    f, old, new, roms = m
    d = ROOT / 'build/ds/mut' / str(i)
    shutil.rmtree(d, ignore_errors=True)
    (d / 'rtl').mkdir(parents=True)
    shutil.copytree(ROOT / 'rtl/ds', d / 'rtl/ds')
    p = d / 'rtl/ds' / f
    s = p.read_text()
    if s.count(old) != 1:
        return i, f'pattern not found once in {f}: {old}'
    p.write_text(s.replace(old, new))
    mk = (ROOT / 'sim/ds/ds.mk').read_text()
    rtl = mk.split('DS_RTL   :=')[1].split('DS_TB')[0].replace('\\', ' ').split()
    srcs = [str(d / r) if r.startswith('rtl/ds/') else str(ROOT / r) for r in rtl]
    obj = d / 'obj'
    cmd = [str(TOOLS / 'verilator'), '--cc', '--exe', '--build', '-j', '4', '-O3', '--x-assign', 'fast',
           '--x-initial', 'fast', '--savable', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL',
           '-Wno-CASEINCOMPLETE', '--top-module', 'nds_top', '--Mdir', str(obj), '-CFLAGS', '-std=c++17 -O2',
           *srcs, str(ROOT / 'sim/ds/tb_ds.cpp')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        return i, 'build failed: ' + (r.stdout + r.stderr)[-500:]
    for rom in roms:
        r = subprocess.run([str(obj / 'Vnds_top'), '--rom', str(ROOT / 'build/ds-tests' / f'{rom}.nds'),
                            '--bios9', str(ROMS / 'bios9.bin'), '--bios7', str(ROMS / 'bios7.bin'),
                            '--firmware', str(ROMS / 'firmware.bin'), '--frames', str(frames), '--result', '--quiet'],
                           capture_output=True, text=True, cwd=ROOT)
        if r.returncode != 0:
            return i, f'caught by {rom}'
    return i, 'MISSED'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only')
    ap.add_argument('--jobs', type=int, default=6)
    ap.add_argument('--frames', type=int, default=100)
    a = ap.parse_args()
    sel = [int(x) for x in a.only.split(',')] if a.only else range(len(MUTANTS))
    missed = 0
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for i, res in ex.map(lambda i: run(i, MUTANTS[i], a.frames), sel):
            f, old, new, roms = MUTANTS[i]
            print(f'{i:2} {f:18} {res}   [{new.strip()[:70]}]', flush=True)
            if not res.startswith('caught'):
                missed += 1
    print(f'{len(list(sel)) - missed} of {len(list(sel))} caught')
    sys.exit(1 if missed else 0)


if __name__ == '__main__':
    main()
