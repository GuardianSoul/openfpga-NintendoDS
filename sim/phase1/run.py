#!/usr/bin/env python3
"""Phase 1 test core, whole-chip simulation (docs/phase1-foundation.md, "Tests").

    sim/phase1/run.py [--tools DIR] [--no-mutate] [--only N]

Builds tb_phase1 with Verilator, makes a synthetic NDS ROM (header, ARM9 and
ARM7 binaries, a FAT of files of awkward sizes) plus BIOS and firmware files,
and runs several APF host timings. For each run:
  - tools/phase1/decode.py must verify the log against the files (ROM CRC-32,
    both signatures, BIOS/firmware CRC-32s) and every box must be green;
  - every cache fetch the core issued must match, command for command, an
    independent model of the cache (4 KiB blocks, read-ahead capped at four
    blocks within the file, CLOCK replacement) driven by the same accesses;
    with the sequential prefetch on (the "prefetch" runs; its commands depend
    on timing) each fetch must instead be a block-aligned run of at most
    five blocks inside the ROM, and the data checks must pass;
  - pass A must read the file in order in DIRECT_CHUNK commands;
  - the SRAM access lengths must match the SRAM model's 55 ns access time.
Then planted faults must each fail at least one run.
"""
import argparse
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
B = ROOT / 'build/phase1'
sys.path.insert(0, str(ROOT / 'tools/phase1'))
import decode  # noqa: E402

RTL = ['rtl/apf/core_bridge_cmd_lean.v', 'rtl/apf/common.v', 'rtl/apf/sound_i2s.sv',
       'rtl/mem/psx_sdram_ctrl.sv', 'rtl/mem/psx_psram_pair.sv', 'rtl/mem/psx_pq_psram.sv',
       'rtl/pocket/nds_sig.sv', 'rtl/pocket/nds_cdc.sv', 'rtl/pocket/nds_sdram.sv', 'rtl/pocket/nds_apf_host.sv', 'rtl/pocket/nds_save_read.sv',
       'rtl/pocket/nds_cart_cache.sv', 'rtl/pocket/nds_bus_tests.sv', 'rtl/pocket/nds_mem_tests.sv',
       'rtl/pocket/nds_log.sv', 'rtl/pocket/psx_pocket_pad_combo.sv', 'rtl/pocket/nds_controls.sv',
       'rtl/pocket/nds_screens.sv', 'rtl/pocket/core_top.sv']
SIM = ['sim/phase1/sim_prims.sv', 'sim/phase1/sdram_chip_model.sv', 'sim/phase1/cram_model.sv',
       'sim/phase1/sram_model.sv', 'sim/probe/mf_datatable_model.sv']
TB = 'sim/phase1/tb_phase1.sv'
SLOTS = 24                  # tb_phase1 SLOTS
CHUNK = 0x8000              # tb_phase1 DIRECT_CHUNK
BLK = 4096

# (name, extra plusargs, ROM size); names starting "prefetch" run the
# PREFETCH=1 build
# '+ndt' loads the ROM tables (slot 5); '+ndt_other' loads tables made for a
# ROM of another size (must be refused); '+stale_sdram' starts with an earlier
# session's tables and cached entries in SDRAM (must not be taken).
CONFIGS = [
    ('baseline, layouts and controls', ['+lat=60', '+controls', '+timeout_ms=900', '+ndt'], 0x4B3E8),
    ('slow host, gaps, odd size', ['+lat=3000', '+jitter=4000', '+gap=4', '+ndt'], 0x4B3EA),
    ('APF error on a cache fetch', ['+lat=200', '+errat=14', '+ndt'], 0x4B3E8),
    ('APF error in pass A, no tables, stale SDRAM', ['+lat=100', '+errat=3', '+nobios', '+stale_sdram'], 0x46000),
    ('tables for another ROM', ['+lat=60', '+ndt_other'], 0x4B3E8),
    ('tables of a newer version', ['+lat=60', '+ndt_v2'], 0x4B3E8),
    ('prefetch, slow host', ['+lat=3000', '+jitter=4000', '+ndt'], 0x4B3E8),
    ('prefetch, APF error', ['+lat=200', '+errat=14', '+ndt'], 0x4B3E8),
    # docs/saves.md: a .sav loaded into slot 10, written to, and read back on quit
    ('save: 128 KiB EEPROM file', ['+lat=60', '+ndt', '+savefile=131072'], 0x4B3E8),
    ('save: tables say 8 KiB, 512 KiB file', ['+lat=60', '+ndt', '+savefile=524288', '+ndtsave=2'], 0x4B3E8),
    ('save: no file, default type, one piece', ['+lat=60', '+ndt', '+savefile=0', '+savechunk=0'], 0x4B3E8),
]
CHIP_BYTES = {1: 512, 2: 8192, 3: 65536, 4: 131072, 5: 262144, 6: 524288, 7: 1048576}
OUR_ARGS = ('+nobios', '+ndt', '+ndt_other', '+ndt_v2')
OUR_PREFIXES = ('+savefile=', '+ndtsave=')
# Known equivalent under these tests (reported, not required to fail): every
# new block enters with its reference bit set, so while new blocks stream in
# CLOCK sweeps a ring of set bits and acts as FIFO (docs/phase1-foundation.md,
# "Open": insertion policy).
EQUIVALENT = [
    ('CLOCK ignores reference bits', 'rtl/pocket/nds_cart_cache.sv',
     "                if (ref_q) begin\n                    ref_we <= 1; ref_waddr <= hand; ref_wd <= 0;",
     "                if (1'b0) begin\n                    ref_we <= 1; ref_waddr <= hand; ref_wd <= 0;"),
]
# (name, file, original, planted fault)
MUTATIONS = [
    ('fetch fills the wrong slot', 'rtl/pocket/nds_apf_host.sv',
     "3'd1: fslot = fc[27:14];", "3'd1: fslot = fc[13:0];"),
    ('eviction leaves the old block cached', 'rtl/pocket/nds_cart_cache.sv',
     "mem_go(1, 0, {TB, q0[17:0]}, 32'h0, 4'b0111);", "mem_go(1, 0, {TB, q0[17:0]}, 32'h0, 4'b0000);"),
    ('block marked cached before its data (no marker wait)', 'rtl/pocket/nds_cart_cache.sv',
     "L_WAITF: if (mk_valid) begin", "L_WAITF: if (1'b1) begin"),
    ('read-ahead field ignored (always four blocks)', 'rtl/pocket/nds_cart_cache.sv',
     "run_ext <= {15'b0, q0[31:29]} > blocks_after ? blocks_after[2:0] : q0[31:29];",
     "run_ext <= 18'd4 > blocks_after ? blocks_after[2:0] : 3'd4;"),
    ('read-ahead runs over cached blocks', 'rtl/pocket/nds_cart_cache.sv',
     "if (q0[16]) begin run_k <= 0; ref_pending <= 0; st <= L_ALLOC; end   // already cached: stop",
     "if (1'b0) begin end"),
    ('pass A error not rolled back', 'rtl/pocket/nds_apf_host.sv',
     "                    restore <= 1;\n", "\n"),
    ('pass B skips the last word of a quad', 'rtl/pocket/nds_bus_tests.sv',
     "if (wpos < rom_size) words <= words + 1'b1;", "if (wpos < rom_size && w != 2'd3) words <= words + 1'b1;"),
    ('SDRAM arbiter returns a word to the wrong client', 'rtl/pocket/nds_sdram.sv',
     "READ1: if (ch2_ready) begin r_valid[owner] <= 1;", "READ1: if (ch2_ready) begin r_valid[0] <= 1;"),
    ('stacked bottom screen read from the wrong ring half', 'rtl/pocket/nds_screens.sv',
     "ring_q <= ring[{k[0], buf_x[7:1]}];", "ring_q <= ring[{~k[0], buf_x[7:1]}];"),
    ('buffered-screen SDRAM writes one word short per line', 'rtl/pocket/nds_screens.sv',
     "if (wi == 7'd127) begin", "if (wi == 7'd126) begin"),
    ('prefetched blocks marked cached before their data', 'rtl/pocket/nds_cart_cache.sv',
     "P_WAIT: if (pf_mk) begin", "P_WAIT: if (1'b1) begin"),
    ('a demand miss does not wait for the prefetch command', 'rtl/pocket/nds_cart_cache.sv',
     "end else if (!pfm && !q0[16] && pf_fly) begin", "end else if (1'b0) begin"),
    ('ROM tables taken whatever their version', 'rtl/pocket/nds_cart_cache.sv',
     "ndt_magic <= ndt_magic && q0 == 32'd1;", "ndt_magic <= ndt_magic;"),
    ('ROM tables taken whatever ROM they were made for', 'rtl/pocket/nds_cart_cache.sv',
     "S_NDT1: if (ndt_magic && q0 == rom_size) begin", "S_NDT1: if (ndt_magic) begin"),
    ('stale tables in SDRAM: magic not cleared at power-up', 'rtl/pocket/nds_apf_host.sv',
     "if (reset) clr_pend <= 1;", "if (reset) clr_pend <= 0;"),
    ('SELECT+R not held back from the game', 'rtl/pocket/nds_controls.sv',
     ".combo_enable(combo_sel == 2'd2 ? 6'b000000 : 6'b000011)", ".combo_enable(6'b000001)"),
    # APF shell trim: the command fields are views of the held fetch command
    ('trim: fetch offset view one block off', 'rtl/pocket/nds_apf_host.sv',
     "assign tgt_offset = direct ? a_off : fc[104:73];", "assign tgt_offset = direct ? a_off : fc[104:73] + 32'd4096;"),
    ('trim: pass A length view ignores the file end', 'rtl/pocket/nds_apf_host.sv',
     "assign tgt_length = direct ? a_len : {17'b0, fc[119:105]};", "assign tgt_length = direct ? DIRECT_CHUNK : {17'b0, fc[119:105]};"),
    ('trim: fetch command view shifted a bit', 'rtl/pocket/nds_cdc.sv',
     "        assign b_data = a_data;", "        assign b_data = {a_data[W-2:0], 1'b0};"),
    # docs/saves.md
    ('save: load lands one word off', 'rtl/pocket/nds_apf_host.sv',
     "f_data <= {1'b0, SAVE_BASE_W + {6'b0, bridge_addr[19:2]}, bridge_wr_data};",
     "f_data <= {1'b0, SAVE_BASE_W + {6'b0, bridge_addr[19:2]} + 24'd1, bridge_wr_data};"),
    ('save: size word not written', 'rtl/pocket/nds_apf_host.sv',
     "assign dt_data = dt_alt ? {11'b0, save_bytes} : LOG_BYTES;", "assign dt_data = LOG_BYTES;"),
    ('save: tables type ignored', 'rtl/pocket/nds_apf_host.sv',
     "ndt_type <= {bridge_wr_data[31], bridge_wr_data[2:0]};", "ndt_type <= 4'd0;"),
    ('save: ring served one word late', 'rtl/pocket/nds_save_read.sv',
     "always @(posedge clk) q <= ring[a[AW-1:0]];", "always @(posedge clk) q <= ring[a[AW-1:0] - 1'b1];"),
    ('save: ring overwrites unread words', 'rtl/pocket/nds_save_read.sv',
     "wire room = wp - rp_b < AHEAD;", "wire room = 1'b1;"),
    # #265: the Pocket reads each KiB's next word as a dummy and then again
    ('save: only strictly in-order reads served', 'rtl/pocket/nds_save_read.sv',
     "if (a < wp74 && a + BACK[18:0] >= rp) begin", "if (a == rp && a < wp74) begin"),
    ('save: 0x0080 acknowledged at once', 'rtl/pocket/nds_save_read.sv',
     "assign rq_ack = rq && (rq_id != SLOT_ID || acked && rq_d);", "assign rq_ack = 1'b1;"),
]


# ---------------- synthetic ROM ----------------
def make_rom(size, seed):
    rng = random.Random(seed)
    rom = bytearray(rng.getrandbits(8) for _ in range(size))
    files = [(0x1B000, 0x2B000),          # 64 KiB, block aligned
             (0x2B000, 0x2B064),          # 100 bytes
             (0x2B100, 0x2F7F0),          # unaligned both ends
             (0x30000, 0x30000),          # empty
             (0x30004, 0x3A000),          # starts 4 bytes into a block
             (0x3A000, 0x3B000),          # one block
             (0x41234, size + 0x5000)]    # runs past the end (clipped)
    fat_off = 0x1A000
    struct.pack_into('<IIII', rom, 0x20, 0x4000, 0x02000000, 0x02000000, 0x9F00)   # ARM9: offset, entry, ram, size
    struct.pack_into('<IIII', rom, 0x30, 0x14000, 0x02380000, 0x02380000, 0x5004)  # ARM7
    struct.pack_into('<II', rom, 0x48, fat_off, len(files) * 8)
    for i, (s, e) in enumerate(files):
        struct.pack_into('<II', rom, fat_off + 8 * i, s, e)
    return bytes(rom)


def write_hex(path, data):
    pad = data + b'\0' * (-len(data) % 4)
    path.write_text('\n'.join(f'{w:08x}' for (w,) in struct.iter_unpack('<I', pad)) + '\n')


# ---------------- reference cache model ----------------
def read_ahead(rom):
    """The ROM table's read-ahead fields, as the plugin computes them
    (docs/pocket-plugin.md, tools/pocket-plugin/src/rom.rs): ARM9, ARM7, then
    every FAT entry, clipped to the ROM; each block whose first byte lies in a
    span gets min(4, blocks of the span after it), later spans overwriting."""
    size = len(rom)
    nblocks = (size + BLK - 1) // BLK
    ra = [0] * nblocks

    def word(a):
        return struct.unpack_from('<I', rom, a)[0] if a + 4 <= size else 0

    def mark(s, e):
        e = min(e, size)
        if s < e:
            sb, se = (s + BLK - 1) // BLK, (e + BLK - 1) // BLK
            for b in range(sb, se):
                ra[b] = min(4, se - 1 - b)

    for off in (0x20, 0x30):
        mark(word(off), word(off) + word(off + 12))
    fat_off, fat_len = word(0x48), word(0x4C)
    fat_n = 0 if fat_off >= size else min(fat_len, size - fat_off) >> 3
    for i in range(fat_n):
        mark(word(fat_off + 8 * i), word(fat_off + 8 * i + 4))
    return ra


def make_ndt(rom, rom_size_field=None, version=1, save_type=0):
    """<game>.ndt as the plugin writes it: 4 KiB header, then one word per block."""
    ra = read_ahead(rom)
    head = bytearray(0x1000)
    size = 0x1000 + 4 * len(ra)
    struct.pack_into('<8I', head, 0, 0x3154444E, version, size, len(rom) if rom_size_field is None else rom_size_field,
                     12, len(ra), 0x1000, 0)
    if save_type:
        struct.pack_into('<I', head, 0x6C, 0x80000000 | save_type)    # docs/saves.md
    return bytes(head) + b''.join(struct.pack('<I', r << 29) for r in ra)


def expected_fetches(rom, slots, ra):
    """Every fetch the cache issues for pass B, with read-ahead fields ra (the
    loaded ROM table, or all zero when the table was cleared)."""
    size = len(rom)
    nblocks = (size + BLK - 1) // BLK
    valid = [False] * nblocks
    slot_of = [0] * nblocks
    owner = [None] * slots
    ref = [0] * slots
    st = {'hand': 0, 'last': None}
    fetches = []

    def lookup(b):
        if st['last'] and st['last'][0] == b:
            return
        if valid[b]:
            ref[slot_of[b]] = 1
            st['last'] = (b, slot_of[b])
            return
        run = [b]
        ext = min(ra[b], nblocks - 1 - b)
        for j in range(1, ext + 1):
            if valid[b + j]:
                break
            run.append(b + j)
        got = []
        for blk in run:
            while ref[st['hand']]:
                ref[st['hand']] = 0
                st['hand'] = (st['hand'] + 1) % slots
            s = st['hand']
            ref[s] = 1
            st['hand'] = (s + 1) % slots
            if owner[s] is not None:
                valid[owner[s]] = False
                if st['last'] and st['last'][0] == owner[s]:
                    st['last'] = None
            owner[s] = blk
            got.append(s)
        fetches.append((b * BLK, min(len(run) * BLK, size - b * BLK)))
        for blk, s in zip(run, got):
            valid[blk] = True
            slot_of[blk] = s
        st['last'] = (b, got[0])

    # pass B: 64 KiB groups in (i * K) mod P order, chunks bit-reversed, 32 quads each
    groups = (size + 0xFFFF) >> 16
    mask = 0
    while mask + 1 < groups:
        mask = mask << 1 | 1
    g = 0
    for _ in range(mask + 1):
        if g < groups:
            for c in range(128):
                rev = int(f'{c:07b}'[::-1], 2)
                base = (g << 16) | (rev << 9)
                for q in range(32):
                    a = base + 16 * q
                    if a >= size:
                        break
                    lookup(a >> 12)
            lookup(0)                 # the hot header quad after each group
        g = (g + 0x9E3779B1) & mask
    return fetches


def read_trace(path):
    fetch, direct, last = [], [], None
    for line in path.read_text().split('\n'):
        p = line.split()
        if not p:
            continue
        if p[0] == 'error':
            (fetch if last == 'fetch' else direct).pop()
            continue
        last = p[0]
        (fetch if p[0] == 'fetch' else direct).append((int(p[1]), int(p[2])))
    return fetch, direct


# ---------------- build and run ----------------
def build(tools, out, sources, prefetch=False):
    cmd = [str(tools / 'verilator'), '--binary', '--timing', '-O3', '-j', '8', '-Wno-fatal', '-Wno-WIDTHEXPAND',
           '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL', '--timescale', '1ns/1ps', '--top-module', 'tb_phase1',
           *(['-GPREFETCH=1'] if prefetch else []), '--Mdir', str(out), *map(str, sources)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout[-3000:] + r.stderr[-3000:])
    return out / 'Vtb_phase1'


def run_config(sim, name, args, size, d, quiet=False, prefetch=False):
    d.mkdir(parents=True, exist_ok=True)
    rom = make_rom(size, size)
    (d / 'rom.nds').write_bytes(rom)
    write_hex(d / 'rom.hex', rom)
    rng = random.Random(9)
    files = {}
    for fname, n in (('bios9', 4096), ('bios7', 16384), ('fw', 16384)):
        files[fname] = bytes(rng.getrandbits(8) for _ in range(n))
        (d / f'{fname}.bin').write_bytes(files[fname])
        write_hex(d / f'{fname}.hex', files[fname])
    plus = [f'+rom={d / "rom.hex"}', f'+romsize={size}', f'+trace={d / "trace.txt"}', f'+log={d / "log.bin"}']
    opt = {a.split('=')[0]: int(a.split('=')[1]) for a in args if a.startswith(OUR_PREFIXES)}
    if '+ndt' in args or '+ndt_other' in args or '+ndt_v2' in args:
        ndt = make_ndt(rom, size + 0x1000 if '+ndt_other' in args else None, 2 if '+ndt_v2' in args else 1,
                       opt.get('+ndtsave', 0))
        write_hex(d / 'rom.ndt.hex', ndt)
        plus += [f'+ndt={d / "rom.ndt.hex"}', f'+ndtsize={len(ndt)}']
    if '+savefile' in opt:
        n = opt['+savefile']
        sav = bytes(rng.getrandbits(8) for _ in range(n))
        write_hex(d / 'save.hex', sav)
        by_size = {v: k for k, v in CHIP_BYTES.items()}
        want = CHIP_BYTES[opt['+ndtsave'] if '+ndtsave' in opt else by_size.get(n, 2)]
        plus += ['+savetest', f'+savebytes={want}'] + ([f'+save={d / "save.hex"}', f'+savesize={n}'] if n else [])
    if '+nobios' not in args:
        plus += [f'+bios9={d / "bios9.hex"}', f'+bios7={d / "bios7.hex"}', f'+fw={d / "fw.hex"}']
    r = subprocess.run([str(sim), *[a for a in args if a not in OUR_ARGS and not a.startswith(OUR_PREFIXES)], *plus], capture_output=True, text=True, timeout=3600)
    out = r.stdout + r.stderr
    problems = []
    if r.returncode or 'DONE' not in out:
        return [f'simulation failed:\n{out[-2500:]}'], out
    w, _ = decode.load(d / 'log.bin')
    f = decode.fields(w)
    dec = subprocess.run([sys.executable, str(ROOT / 'tools/phase1/decode.py'), str(d / 'log.bin'), '--rom', str(d / 'rom.nds')]
                         + ([f'--bios9={d / "bios9.bin"}', f'--bios7={d / "bios7.bin"}', f'--firmware={d / "fw.bin"}']
                            if '+nobios' not in args else []), capture_output=True, text=True)
    if dec.returncode:
        problems.append('decoder checks:\n' + dec.stdout)
    want_load = 'waiting' if '+nobios' in args else 'PASS'
    for box, state in f['boxes'].items():
        want = want_load if box in ('BIOS9', 'BIOS7', 'firmware') else 'PASS'
        if state != want:
            problems.append(f'{box} box {state}, expected {want}')
    fetch, direct = read_trace(d / 'trace.txt')
    nblk = (size + BLK - 1) // BLK
    exp = expected_fetches(rom, SLOTS, read_ahead(rom) if '+ndt' in args else [0] * nblk)
    bad = [(o, n) for o, n in fetch if o % BLK or n <= 0 or n > 5 * BLK or o + n > size]
    if prefetch:
        if bad:
            problems.append(f'prefetch run: bad fetch commands {bad[:3]}')
    elif fetch != exp:
        k = next((i for i, (a, b) in enumerate(zip(fetch, exp)) if a != b), min(len(fetch), len(exp)))
        problems.append(f'cache fetches differ from the model at command {k} of {len(fetch)} (model {len(exp)}): '
                        f'core {fetch[k:k + 3]}, model {exp[k:k + 3]}')
    exp_direct = [(o, min(CHUNK, size - o)) for o in range(0, size, CHUNK)]
    if direct != exp_direct:
        problems.append(f'pass A commands {direct[:4]}... expected {exp_direct[:4]}...')
    if (f['sram_ok'] & ~f['sram_bad']) != 0xFF80 or f['sram_bad'] != 0x007E:
        problems.append(f"SRAM lengths ok {f['sram_ok']:04x} bad {f['sram_bad']:04x}, expected ff80/007e")
    errs = f['sram_errors_by_len']
    if any(errs[L] for L in range(7, 16)) or not all(errs[L] for L in range(1, 7)):
        problems.append(f"SRAM errors by length {errs}: expected errors at 1-6 only")
    if not quiet:
        print(f'--- {name}: {len(fetch)} fetches, {len(direct)} pass A commands')
        print(dec.stdout.rstrip())
        print('\n'.join(l for l in out.splitlines() if l.startswith(('video', 'models', 'save', 'DONE'))))
    return problems, out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tools', type=Path, default=Path.cwd() / 'build/tools/oss-cad-suite/bin')
    ap.add_argument('--no-mutate', action='store_true')
    ap.add_argument('--only', type=int)
    ap.add_argument('--mutations', help='only the mutations whose name contains this')
    a = ap.parse_args()
    B.mkdir(parents=True, exist_ok=True)
    # the Quartus build must compile the same RTL as this bench
    script = (ROOT / 'scripts/build_phase1.sh').read_text()
    missing = [f for f in RTL if f.startswith('rtl/pocket/') and Path(f).name not in script]
    if missing:
        sys.exit(f'scripts/build_phase1.sh does not list {missing}')
    sims = (build(a.tools, B / 'obj', [ROOT / s for s in SIM + RTL + [TB]]),
            build(a.tools, B / 'obj_pf', [ROOT / s for s in SIM + RTL + [TB]], prefetch=True))
    failed = 0
    for i, (name, args, size) in enumerate(CONFIGS):
        if a.only is not None and i != a.only:
            continue
        pf = name.startswith('prefetch')
        problems, _ = run_config(sims[pf], name, args, size, B / f'run{i}', prefetch=pf)
        for p in problems:
            print('FAIL', name + ':', p)
        failed += bool(problems)
    if failed:
        sys.exit(f'FAIL: {failed} of {len(CONFIGS)} runs')
    print(f'all {len(CONFIGS) if a.only is None else 1} runs pass')
    if a.no_mutate:
        return
    caught = 0
    sel = [m for m in MUTATIONS + EQUIVALENT if not a.mutations or a.mutations in m[0]]
    for name, path, old, new in sel:
        d = B / 'mutant'
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        text = (ROOT / path).read_text()
        if text.count(old) != 1:
            sys.exit(f'mutation anchor not found in {path}: {old}')
        (d / Path(path).name).write_text(text.replace(old, new))
        srcs = [d / Path(s).name if s == path else ROOT / s for s in SIM + RTL + [TB]]
        msims = (build(a.tools, d / 'obj', srcs),
                 build(a.tools, d / 'obj_pf', srcs, prefetch=True) if path.endswith('nds_cart_cache.sv') else None)
        rejected = False
        # save faults try the save runs first
        order = sorted(enumerate(CONFIGS), key=lambda c: not (name.startswith('save') and c[1][0].startswith('save')))
        for i, (cname, args, size) in order:
            pf = cname.startswith('prefetch')
            if pf and msims[1] is None:
                continue
            try:
                problems, _ = run_config(msims[pf], cname, args, size, d / f'run{i}', quiet=True, prefetch=pf)
            except subprocess.TimeoutExpired:
                problems = ['timeout']
            if problems:
                rejected = True
                print(f"mutation '{name}': caught by '{cname}': {problems[0].splitlines()[0][:150]}")
                break
        if not rejected:
            print(f"mutation '{name}': NOT CAUGHT" + (' (known equivalent)' if (name, path, old, new) in EQUIVALENT else ''))
        caught += rejected and (name, path, old, new) not in EQUIVALENT
    want = len([m for m in sel if m not in EQUIVALENT])
    if caught != want:
        sys.exit(f'FAIL: {want - caught} planted faults passed')
    print(f'all {want} planted faults caught')


if __name__ == '__main__':
    main()
