#!/usr/bin/env python3
"""The DS core, whole chip, in Verilator (sim/pocket_ds/tb_ds_pocket.sv).

    run.py --tools DIR [--rom F] [--frames N] [--shots DIR] [--roms-dir D]

Builds core_top (rtl/pocket/core_top_ds.sv) with the APF firmware model and
the memory pin models, loads the BIOS/firmware from --roms-dir and runs a DS
test ROM (default build/ds-tests/hello.nds). Exit 0 if the ROM's result
block says every check passed and the models saw no errors.
"""
import argparse
import fcntl
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
RTL = ['arm/arm_pkg.sv', 'arm/arm_regfile.sv', 'arm/arm_mul.sv', 'arm/arm_thumb.sv', 'arm/arm_core.sv', 'arm/arm7_ds.sv',
       'arm/arm9_ram.sv', 'arm/arm9_mem.sv', 'arm/arm_cpu.sv', 'arm/cdc_req.sv', 'arm/cdc_fifo.sv', 'arm/cdc_a7.sv', 'arm/cpu_domain.sv',
       'sys/sys_ram.sv', 'sys/sys_irq.sv', 'ds/nds_dsp_add.sv', 'sys/sys_timers.sv', 'sys/sys_ipc.sv', 'sys/sys_math.sv', 'sys/sys_dma.sv',
       'sys/nds_sys.sv', 'gpu2d/gpu2d_pkg.sv', 'gpu2d/gpu2d_ram.sv', 'gpu2d/gpu2d_cache.sv', 'gpu2d/gpu2d_bg.sv',
       'gpu2d/gpu2d_obj.sv', 'gpu2d/gpu2d.sv', 'sound/sound_ram.sv', 'sound/sound.sv',
       'ds/nds_ram.sv', 'ds/nds_lcache.sv', 'ds/nds_arm7_port.sv', 'ds/nds_arm7_port_min.sv', 'ds/nds_fabric.sv', 'ds/nds_vram.sv', 'ds/nds_io.sv', 'ds/nds_disp_refs.sv', 'ds/nds_disp.sv',
       'gpu3d/gpu3d_pkg.sv', 'gpu3d/gpu3d_div4.sv', 'gpu3d/gpu3d_ram.sv', 'gpu3d/gpu3d_edge.sv', 'gpu3d/gpu3d_front.sv', 'gpu3d/gpu3d_fpass.sv', 'gpu3d/gpu3d_raster.sv',
       'gpu3d/gpu3d_gxu_pkg.sv', 'gpu3d/gpu3d_gxrom.sv', 'gpu3d/gpu3d_gxrom_us.sv', 'gpu3d/gpu3d_gxrom_ul.sv', 'gpu3d/gpu3d_gxrom_uv.sv', 'gpu3d/gpu3d_gxrom_uw.sv', 'gpu3d/gpu3d_gxrom_uf.sv', 'gpu3d/gpu3d_gxlight.sv', 'gpu3d/gpu3d_gxvfin.sv', 'gpu3d/gpu3d_gxdiv.sv', 'gpu3d/gpu3d_gxfront.sv', 'gpu3d/gpu3d_gxeng.sv', 'gpu3d/gpu3d_gxsort.sv', 'gpu3d/gpu3d_geom.sv', 'ds/nds_blk_arb.sv', 'ds/nds_g3d_plane.sv', 'ds/nds_l3d_xscroll.sv', 'ds/nds_fr_arb.sv', 'ds/nds_mr_arb.sv', 'ds/nds_g3d_store.sv', 'ds/nds_g3d_ring.sv', 'ds/nds_gpu3d.sv',
       'ds/nds_cart.sv', 'ds/nds_spi.sv', 'ds/nds_rtc.sv', 'ds/nds_wifi.sv', 'ds/nds_wifi_mc.sv', 'ds/nds_top.sv',
       'pocket/nds_sig.sv', 'pocket/nds_cdc.sv', 'pocket/nds_sdram_mc.sv', 'pocket/nds_sdram_bus.sv', 'pocket/nds_apf_host.sv', 'pocket/nds_save_read.sv',
       'pocket/nds_cart_cache.sv', 'pocket/nds_cart_scpu.sv', 'pocket/nds_bport_share.sv', 'pocket/nds_diag.sv', 'pocket/nds_diag_lat.sv', 'pocket/nds_diag_xmem.sv', 'pocket/nds_bus_tests.sv', 'pocket/nds_log.sv', 'pocket/psx_pocket_pad_combo.sv',
       'pocket/nds_controls.sv', 'pocket/nds_x2b.sv', 'pocket/nds_psram.sv', 'pocket/nds_video.sv', 'pocket/nds_audio_interp.sv', 'pocket/nds_sram.sv', 'pocket/core_top_ds.sv',
       'mem/psx_sdram_ctrl.sv', 'mem/psx_psram_pair.sv', 'mem/psx_pq_psram.sv',
       'apf/core_bridge_cmd_lean.v', 'apf/common.v', 'apf/sound_i2s.sv'] + \
    ['serv/' + f + '.v' for f in ('serv_aligner serv_alu serv_bufreg2 serv_bufreg serv_compdec serv_csr serv_ctrl serv_debug '
                                  'serv_decode serv_immdec serv_mem_if serv_rf_if serv_rf_ram_if serv_rf_ram serv_rf_top serv_state serv_top').split()]
SIM = ['sim/probe/mf_datatable_model.sv', 'sim/phase1/sim_prims.sv', 'sim/pocket_ds/sim_prims_ds.sv',
       'sim/phase1/sdram_chip_model.sv', 'sim/phase1/cram_model.sv', 'sim/phase1/sram_model.sv',
       'sim/pocket_ds/tb_ds_pocket.sv']


def write_hex(path, data):
    data = data + b'\0' * (-len(data) % 4)
    path.write_text(''.join('%08x\n' % int.from_bytes(data[i:i + 4], 'little') for i in range(0, len(data), 4)))


def import_images(d, out):
    """tb_ds_pocket's +imp_* images of a state export: main RAM with the overlay (and its own
    words), VRAM in the VRAM port's layout (nds_vram), the WRAMs as the SRAM holds them"""
    imp = {}
    for l in (d / 'import.txt').read_text().split('\n'):
        p = l.split()
        if p:
            imp[p[0]] = [int(x, 16) for x in p[1:]]
    real = bytearray((d / 'main.bin').read_bytes()[:4 << 20])
    main = bytearray(real)
    ov, ovn = imp['overlay']
    blk, blkn = imp['block']
    o = (d / 'overlay.bin').read_bytes()
    main[ov - 0x02000000:ov - 0x02000000 + len(o)] = o
    b = (d / 'block.bin').read_bytes().ljust(blkn, b'\0')
    main[blk - 0x02000000:blk - 0x02000000 + blkn] = b
    vram = bytearray(0xA4000)
    for i, off in enumerate((0x00000, 0x20000, 0x40000, 0x60000, 0x80000, 0x90000, 0x94000, 0x98000, 0xA0000)):
        v = (d / f'vram_{"abcdefghi"[i]}.bin').read_bytes()
        vram[off:off + len(v)] = v
    sram = (d / 'wram7.bin').read_bytes().ljust(0x10000, b'\0') + (d / 'swram.bin').read_bytes().ljust(0x8000, b'\0')
    for name, data in (('imp_main', main), ('imp_real', real), ('imp_vram', vram), ('imp_sram', sram)):
        write_hex(out / f'{name}.hex', bytes(data))
    w = lambda a: (a - 0x02000000) // 4
    return [f'+imp_main={out / "imp_main.hex"}', f'+imp_real={out / "imp_real.hex"}', f'+imp_vram={out / "imp_vram.hex"}',
            f'+imp_sram={out / "imp_sram.hex"}', f'+imp_ready9={w(imp["ready9"][0]):x}', f'+imp_ready7={w(imp["ready7"][0]):x}',
            f'+imp_vcount={imp["vcount"][0]}', f'+imp_ov={w(ov):x}', f'+imp_ovn={(ovn + 3) // 4:x}',
            f'+imp_blk={w(blk):x}', f'+imp_blkn={(blkn + 3) // 4:x}', f'+imp_stubn={imp.get("stub", [0])[0] // 4:x}']


def main():
    # Disk guard: the shared Desktop disk filled up three times on 2026-11-06.
    # Sim builds take 1-4 GB each; stop here rather than fill the disk.
    free_gb = shutil.disk_usage(ROOT).free / 2**30
    if free_gb < 30 and not os.environ.get('NDS_DISK_GUARD_OFF'):
        sys.exit(f'only {free_gb:.0f} GB free on the disk (need 30): delete finished '
                 'sim builds, or wait for the hourly nds-disk-prune timer')
    ap = argparse.ArgumentParser()
    ap.add_argument('--tools', default=str(Path.cwd() / 'build/tools/oss-cad-suite/bin'))
    ap.add_argument('--rom', default=str(ROOT / 'build/ds-tests/hello.nds'))
    ap.add_argument('--roms-dir', default=str(Path.home() / 'Git/NDS_Pocket/roms'))
    ap.add_argument('--frames', type=int, default=25)
    ap.add_argument('--shots')
    ap.add_argument('--progress', action='store_true')
    ap.add_argument('--out', default=str(ROOT / 'build/pocket_ds'))
    ap.add_argument('--fst', help='FST window file (builds with --trace-fst)')
    ap.add_argument('--fst-from-us', type=int, default=0)
    ap.add_argument('--fst-us', type=int, default=200)
    ap.add_argument('--pctrace', help='ARM9 retired PCs to this file (--pctrace-from N, --pctrace-n M)')
    ap.add_argument('--pctrace-from', type=int, default=0)
    ap.add_argument('--pctrace-n', type=int, default=2000000)
    ap.add_argument('--dump-pc', help='hex PC: dump main RAM when the ARM9 first retires it (--dump-file)')
    ap.add_argument('--dump-file')
    ap.add_argument('--slots', type=int, help='ROM cache slots (default 12288, the Pocket\'s)')
    ap.add_argument('--nodebug', action='store_true', help='core_top without its debug log (NDS_DEBUG=0, as the fit)')
    ap.add_argument('--preload', action='store_true', help='the ROM straight into the ROM cache once it is ready (tb_ds_pocket +preload)')
    ap.add_argument('--import', dest='imp', help='a state export (census --export-state + sim/ds/state_import.py, '
                    'docs/state-import.md): start from it (an IMPORT build; its save.bin as --sav)')
    ap.add_argument('--no-prefetch', action='store_true')
    ap.add_argument('--rtl-root', help='an rtl/ tree to build instead of the repository\'s (mutation runs)')
    ap.add_argument('--threads', type=int, default=1, help='Verilator threads (builds into obj_tN)')
    ap.add_argument('--obj-root', help='the Verilator build directory goes here, not under --out (runs with the same options share it)')
    ap.add_argument('--vmcheck', action='store_true', help='check every VRAM-port read word against a shadow of the words written there')
    ap.add_argument('--ringgen', type=int, metavar='GAP', help='nds_ring_gen on the line ring\'s SDRAM ports (RING_GEN), random gap 0..GAP clocks between blocks')
    ap.add_argument('--vmlat', type=int, help='from this video frame, VRAM block-port latency histograms (tb_ds --vlat/--jitter/--stall)')
    ap.add_argument('--touchtest', type=int, help='DS frame: SELECT+L, then hold RIGHT and DOWN (TOUCH PASS/FAIL)')
    ap.add_argument('--swatch', help='hex SDRAM word address: log bridge data and SDRAM writes of its 8 words')
    ap.add_argument('--line-stats', type=int, help='DS frame: per-line VRAM blocks and busy cycles')
    ap.add_argument('--cwatch', help='hex ROM offset: log card reads of its 64-byte window')
    ap.add_argument('--sav', help='a .sav for slot 10, loaded before the core starts (docs/saves.md)')
    ap.add_argument('--sav-out', help='at the end, quit as the Pocket does and write the exported save here')
    ap.add_argument('--diag-out', help='DIAG=1 builds: at the end, read the NDSDiag log (slot 11) as the Pocket does into this .ndg')
    ap.add_argument('--diag-words', type=int, help='... only its first N words')
    ap.add_argument('--wwatch', help='hex byte address: log main-RAM writes to its 64-byte window')
    ap.add_argument('--core-param', action='append', default=[], metavar='NAME=V',
                    help='a core_top_ds parameter for this build (e.g. --core-param RING=1); repeatable, own obj directory')
    ap.add_argument('--plus', action='append', default=[], help='an extra plusarg for the testbench (e.g. --plus g3dperf); repeatable')
    a = ap.parse_args()
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    obj = (Path(a.obj_root).resolve() if a.obj_root else out) / (('obj_fst' if a.fst else 'obj') + (f'_t{a.threads}' if a.threads != 1 else '') + ('_nodebug' if a.nodebug else '')
                 + ('_import' if a.imp else '') + ''.join('_' + p.replace('=', '') for p in a.core_param))
    rom_aw = max(24, (Path(a.rom).stat().st_size - 1).bit_length() - 2)     # the tb's ROM image: 64 MiB, or larger
    if rom_aw > 24:
        obj = obj.with_name(obj.name + f'_rom{rom_aw}')
    if a.imp and not a.sav and (Path(a.imp) / 'save.bin').exists():
        a.sav = str(Path(a.imp) / 'save.bin')
    obj.mkdir(parents=True, exist_ok=True)
    # the boot ROM image the core's u_boot reads ($readmemh of BOOTROM, relative to the run directory)
    subprocess.run(['make', '-s', '-C', str(ROOT), 'build/boot/bootrom.hex'], check=True)
    shutil.copyfile(ROOT / 'build/boot/bootrom.hex', out / 'bootrom.mif')
    rtl = Path(a.rtl_root) if a.rtl_root else ROOT / 'rtl'
    srcs = [str(rtl / f) for f in RTL] + [str(ROOT / f) for f in SIM]
    cmd = [str(Path(a.tools) / 'verilator'), '--binary', '--timing', '-O3', '-j', '8', '-Wno-fatal', '-Wno-WIDTHEXPAND',
           '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL', '--timescale', '1ns/1ps', '--top-module', 'tb_ds_pocket',
           *(['--trace-fst', '--trace-structs'] if a.fst else []),
           *(['-DRING_GEN'] if a.ringgen is not None else []),
           *([f'-GSLOTS={a.slots}'] if a.slots else []), *(['+define+NODEBUG'] if a.nodebug else []), *(['+define+IMPORT'] if a.imp else []),
           *(['+define+TB_CORE_PARAMS=' + ''.join(f', .{n}({v})' for n, v in (p.split('=', 1) for p in a.core_param))] if a.core_param else []), *(['+define+DIAG_MON'] if 'DIAG=1' in a.core_param else []), *(['+define+NO_SCPU'] if 'SHELL_CPU=0' in a.core_param else []), f'-GROM_AW={rom_aw}', '--threads', str(a.threads), *(['-GPREFETCH=0'] if a.no_prefetch else []),
           '-I' + str(rtl / 'pocket'), '--Mdir', str(obj), *srcs]
    # one build at a time on this machine, with 12 GB free (AGENTS.md: three at once ran the Desktop out of memory)
    lock = Path.home() / '.cache/nds-sim-build.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    with open(lock, 'w') as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        while int(re.search(r'MemAvailable:\s+(\d+)', Path('/proc/meminfo').read_text())[1]) < 12 << 20:
            time.sleep(30)
        r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout[-3000:] + r.stderr[-3000:])
    rom = Path(a.rom).read_bytes()
    write_hex(out / 'rom.hex', rom)
    rd = Path(a.roms_dir)
    for name in ('bios9', 'bios7', 'firmware'):
        write_hex(out / f'{name}.hex', (rd / f'{name}.bin').read_bytes())
    boot = (ROOT / 'sw/boot/bootrom.bin').read_bytes()
    scpu = (ROOT / 'sw/scpu/cache.bin').read_bytes()
    # the boot ROM slot (ID 12, nds_boot.bin as tools/ds/package.py: the boot ROM, then SERV's firmware)
    write_hex(out / 'boot.hex', boot + bytes(8192 - len(boot)) + scpu + bytes(4096 - len(scpu)))
    plus = [f'+rom={out / "rom.hex"}', f'+romsize={len(rom)}', f'+bios9={out / "bios9.hex"}',
            f'+bios7={out / "bios7.hex"}', f'+fw={out / "firmware.hex"}', f'+boot={out / "boot.hex"}',
            f'+fwsize={(rd / "firmware.bin").stat().st_size}', f'+frames={a.frames}']
    if a.sav:
        write_hex(out / 'sav.hex', Path(a.sav).read_bytes())
        plus += [f'+sav={out / "sav.hex"}', f'+savsize={Path(a.sav).stat().st_size}']
    if a.diag_out:
        plus.append(f'+diagout={Path(a.diag_out).resolve()}')
        if a.diag_words:
            plus.append(f'+diagwords={a.diag_words}')
    if a.sav_out:
        plus.append(f'+savout={Path(a.sav_out).resolve()}')
    if a.progress:
        plus.append('+progress')
    if a.preload:
        plus.append('+preload')
    if a.imp:
        plus += import_images(Path(a.imp), out)
    if a.line_stats is not None:
        plus.append(f'+line_stats={a.line_stats}')
    if a.touchtest:
        plus.append(f'+touchtest={a.touchtest}')
    if a.vmcheck:
        plus.append('+vmcheck')
    if a.ringgen is not None:
        plus += ['+ringgen', f'+ringgen_gap={a.ringgen}']
    if a.vmlat is not None:
        plus.append(f'+vmlat={a.vmlat}')
    if a.swatch:
        plus.append(f'+swatch={a.swatch}')
    if a.cwatch:
        plus.append(f'+cwatch={a.cwatch}')
    if a.wwatch:
        plus.append(f'+wwatch={a.wwatch}')
    if a.dump_pc:
        plus += [f'+dump_pc={a.dump_pc}', f'+dump_file={Path(a.dump_file).resolve()}']
    if a.pctrace:
        plus += [f'+pctrace={Path(a.pctrace).resolve()}', f'+pctrace_from={a.pctrace_from}', f'+pctrace_n={a.pctrace_n}']
    if a.fst:
        plus += [f'+fst={Path(a.fst).resolve()}', f'+fst_from_us={a.fst_from_us}', f'+fst_us={a.fst_us}']
    plus += ['+' + p for p in a.plus]
    if a.shots:
        shots = Path(a.shots).resolve()
        shots.mkdir(parents=True, exist_ok=True)
        plus.append(f'+shots={shots}')
    # the output passes through as it comes; a FAIL verdict line (the ROM's result block) fails the run
    p = subprocess.Popen([str(obj / 'Vtb_ds_pocket'), *plus], cwd=out, text=True, stdout=subprocess.PIPE)
    verdict = None
    for line in p.stdout:
        sys.stdout.write(line); sys.stdout.flush()
        if line.strip() in ('PASS', 'FAIL'):
            verdict = line.strip()
    rc = p.wait()
    if rc == 0 and verdict is None and Path(a.rom).resolve().parent == (ROOT / 'build/ds-tests').resolve():
        sys.exit(f'FAIL: the test ROM wrote no verdict in {a.frames} frames (hello needs about 60)')
    sys.exit(rc or (1 if verdict == 'FAIL' else 0))


if __name__ == '__main__':
    main()
