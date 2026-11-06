#!/usr/bin/env python3
"""Stage focused Pocket adapters for existing DS30/35; never build or run."""
import argparse
import ast
import csv
import hashlib
import io
import json
from pathlib import Path
import subprocess
import types

ROOT = Path(__file__).resolve().parents[2]
SOURCE = '9210e0aba922e71c28b3f49ea65452667f7c0418'
HELPERS = '9b1f336439760ecadce66c56913f3164d18f01c0'
A7 = 'ea21e76236dde32bba173122c5ba0200a66013d9'
MEM = 'f90b76ae417f93f3cc1ab10b909733c67cf80f13'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode()


def change(text, before, after):
    require(text.count(before) == 1, 'source precondition changed: ' + before[:80])
    return text.replace(before, after)


def between(text, start, end):
    require(text.count(start) == 1 and text.count(end) == 1, 'source block ambiguous')
    a, b = text.index(start), text.index(end)
    require(a < b, 'source block reversed')
    return text[a:b]


def archived(archive, member):
    return subprocess.check_output(['tar', '--zstd', '-xOf', str(archive), member], cwd=ROOT)


def focused_mem(text):
    start = '    const Row rows[] = {'
    end = '    const int nk'
    old = between(text, start, end)
    text = change(text, old, '''    const Row rows[] = {
        { "LDM8UNC", k_ldm_seq, (u32)s_unc, 0, 16 },
    };
''')
    text = change(text, '#define N1 4\n#define N2 16', '#define N1 256\n#define N2 1024')
    # DS best(): one full-length warm invocation, then five timed samples.
    old = between(text, 'static u32 time_k(', 'static u32 per_x100(')
    text = change(text, old, '''static u32 time_k(Kern k, u32 b, u32 it, int flush)
{
    if (!flush) k(b, it);
    u32 best = ~0u;
    for (int r = 0; r < REPS; r++) {
        if (flush) dc_flush_all();
        u32 t0 = now32();
        k(b, it);
        u32 t = now32() - t0;
        if (t < best) best = t;
    }
    return best;
}
''')
    text = change(text, 'res_begin("UNITMEM", nk + 10);', 'res_begin("DS35LDM", nk + 2);')
    text = change(text, 'r->base, N1, r->flush', 'r->base, N1 / r->per, r->flush')
    text = change(text, 'r->base, N2, r->flush', 'r->base, N2 / r->per, r->flush')
    text = change(text, '(N2 - N1) * r->per', 'N2 - N1')
    text = change(text, 'per_x100(t1, t2, N2 - N1), 1);',
                  'per_x100(t1, t2, N2 - N1), t2 > t1);\n'
                  '        res_record(nk, "SHORT_TICKS", t1, t1 > 0);\n'
                  '        res_record(nk + 1, "LONG_TICKS", t2, t2 > t1);')
    old = between(text, '    int j = nk;', '    res_finish();')
    text = change(text, old, '')
    # Retain the known wrapper's MPU/timer code; the focused data kernel
    # already moves to ITCM through the qualified upstream generator.
    return text


IRQ = '''
typedef u32 ArmIrqState;
static inline ArmIrqState armIrqLockByPsr(void)
{
    u32 old, locked;
    __asm__ volatile("mrs %0, cpsr\\norr %1, %0, #0x80\\nmsr cpsr_c, %1"
                     : "=&r"(old), "=&r"(locked) :: "cc", "memory");
    return old;
}
static inline void armIrqUnlockByPsr(ArmIrqState old)
{
    __asm__ volatile("msr cpsr_c, %0" :: "r"(old) : "cc", "memory");
}
'''


def focused_a7(hardware):
    timer = between(hardware, 'static inline u32 now32(', '#define K ')
    macros = between(hardware, '#define K ', 'K static u32 k_alu(')
    kernels = '\n'.join(line for line in hardware.splitlines()
                        if line.startswith(('K static u32 k_ldr(', 'K static u32 k_str(')))
    require(len(kernels.splitlines()) == 2, 'two hardware scalar kernels required')
    timed = between(hardware, 'static u32 timed(', 'static u32 measure(')
    return ('/* DS30 source-form adapter. Original captured ELF is not archived. */\n'
            '#include "../common/ds.h"\n#include "../common/ipc.h"\n'
            '#define REG16 R16\n#define REG32 R32\n#undef R8 /* hardware repeat macro below */\n' + timer + IRQ + macros + kernels + '\n' + timed + '''
static u32 measure(Kern k, u32 p, int line, unsigned slot)
{
    u32 b1 = ~0u, b2 = ~0u;
    for (int r = 0; r < 5; r++) {
        u32 t1 = timed(k, 4, p, 0, line), t2 = timed(k, 16, p, 0, line);
        if (t1 < b1) b1 = t1;
        if (t2 < b2) b2 = t2;
    }
    MB->val[6 + slot * 2] = b1;
    MB->val[7 + slot * 2] = b2;
    return b2 > b1 ? (b2 - b1) * 100 / (12 * 64) : 0;
}
static u32 wram[16] __attribute__((aligned(32)));
int main(void)
{
    MB->cmd = 0; MB->ack = 0;
    REG16(0x04000102) = 0; REG16(0x04000106) = 0;
    REG16(0x04000104) = 0; REG16(0x04000100) = 0;
    REG16(0x04000106) = (1 << 7) | (1 << 2);
    REG16(0x04000102) = 1 << 7;
    IPCSYNC = A7_READY << 8;
    while (MB->cmd != 1) {}
    const struct { Kern k; u32 p; int line; } rows[] = {
        { k_ldr, (u32)wram, -1 }, { k_str, (u32)wram, -1 },
        { k_ldr, 0x06000100, 192 }, { k_ldr, 0x06000100, 96 },
        { k_str, 0x06000100, 192 }, { k_str, 0x06000100, 96 },
    };
    for (unsigned i = 0; i < 6; i++)
        MB->val[i] = measure(rows[i].k, rows[i].p, rows[i].line, i);
    MB->ack = 1; IPCSYNC = 1 << 8;
    for (;;) ;
}
''')


def prepare(out):
    require(not out.exists(), 'fresh adapter output required')
    a7path, mempath = 'sw/hwref/arm7time/arm7.c', 'sw/hwref/memtime/run.itcm.c'
    hardware = git('show', f'{A7}:{a7path}')
    mem = git('show', f'{MEM}:{mempath}')
    # Establish source continuity, without claiming it identifies the DS ROM.
    require(hardware == git('show', f'{SOURCE}:{a7path}'), 'ARM7 source changed since historical form')
    require(mem == git('show', f'{SOURCE}:{mempath}'), 'memtime kernel source changed since historical form')
    out.mkdir(parents=True)
    upstream = out / 'upstream'
    upstream.mkdir()
    helperpath = upstream / 'probe_memtime.py'
    helperpath.write_text(git('show', f'{HELPERS}:rnd/probe_memtime.py'))
    helper = types.ModuleType('frozen_probe_memtime')
    helper.__file__ = str(helperpath)
    exec(compile(helperpath.read_text(), str(helperpath), 'exec'), helper.__dict__)
    helper.ROOT = ROOT
    memout = out / 'memtime'
    memout.mkdir()
    helper.prepare(memout, SOURCE, MEM)
    target = memout / 'post-itcm/unitmem/arm9.c'
    target.write_text(focused_mem(target.read_text()))
    a7out = out / 'arm7time'
    for name in git('ls-tree', '-r', '--name-only', SOURCE, '--', 'sw/tests/common', 'sw/tests/unita7').splitlines():
        path = a7out / Path(name).relative_to('sw/tests')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(git('show', f'{SOURCE}:{name}'))
    (a7out / 'unita7/arm7.c').write_text(focused_a7(hardware))
    idle = git('show', f'{HELPERS}:rnd/probe_arm7_idle.py')
    (upstream / 'probe_arm7_idle.py').write_text(idle)
    tree = ast.parse(idle)
    poll = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == 'HELPER' for t in node.targets))
    path = a7out / 'unita7/arm9.c'
    text = path.read_text()
    names = ['LDRWRAM', 'STRWRAM', 'LDRVRAMB', 'LDRVRAMD', 'STRVRAMB', 'STRVRAMD']
    allnames = names + [n + suffix for n in names for suffix in ('_T1', '_T2')]
    old = between(text, 'static const char *const s_name[] = {', '#define N ')
    text = change(text, old, 'static const char *const s_name[] = {\n    ' +
                  ', '.join(json.dumps(name) for name in allnames) + '\n};\n')
    text = change(text, 'int main(void)', poll + '\nint main(void)')
    text = '/* Focused DS30 adapter: ITCM helper still generates I/O polls. */\n' + text
    text = change(text, 'if (ok) ok = WAIT_UNTIL((IPCSYNC & 0xF) == 1, 600);',
                  'if (ok) ok = wait_a7_without_main_fetches();')
    text = change(text, 'R8(0x04000242) = 0x82;',
                  'R8(0x04000240) = 0x81;\n    DISPCNT_A = 0x11f00; DISPCNT_B = 0x10000;\n    R8(0x04000242) = 0x82;')
    path.write_text(text)
    sources = out / 'hardware-source'
    sources.mkdir()
    (sources / 'arm7time-arm7.c').write_text(hardware)
    (sources / 'memtime-run.itcm.c').write_text(mem)
    ds = {}
    for label, archive, member, info in [
        ('a7', 'ds-20261025-run30-onetrip.tar.zst', 'arm7time.csv', 'arm7time_info.txt'),
        ('mem', 'ds-20261029-run35-wbuf-memtime2.tar.zst', './memtime.csv', './memtime_info.txt')]:
        archive = ROOT / 'tools/hwref/results' / archive
        data, meta = archived(archive, member), archived(archive, info)
        (sources / (label + '.csv')).write_bytes(data)
        (sources / (label + '-info.txt')).write_bytes(meta)
        rows = list(csv.DictReader(io.StringIO(data.decode())))
        selected = ([r for r in rows if r['kernel'] in ('ldr_wram', 'str_wram', 'ldr_vram_c', 'str_vram_c')]
                    if label == 'a7' else [r for r in rows if
                        (r['test'], r['region'], r['op']) == ('load', 'main_c0b0_seq', 'ldm8')])
        require(len(selected) == (6 if label == 'a7' else 1), 'hardware rows missing/ambiguous')
        ds[label] = dict(archive=str(archive), archive_sha256=sha(archive.read_bytes()),
                         csv_sha256=sha(data), info_sha256=sha(meta), rows=selected)
    # The upstream manifest is historical generation input, not the final
    # adapter identity. The outer manifest binds every transformed file.
    commands = {}
    for name, src, program, code in [('ds30', a7out, 'unita7', 'TSA7'),
                                     ('ds35', memout / 'post-itcm', 'unitmem', 'TSLD')]:
        dest = out / (name + '-rom')
        commands[name] = ['make', '-j1', f'DT_SRC={src}', f'DT={dest}', f'DT_ROMS={program}',
                          f'DT_CODE_{program}={code}', str(dest / (program + '.nds'))]
    record = dict(status='SOURCE STAGED ONLY; no compiler/model worker or new DS trip',
                  source=SOURCE, helper_source=HELPERS, a7_kernel_source=A7, mem_kernel_source=MEM,
                  source_continuity_verified=True, hardware=ds, build_argv=commands,
                  canonical_checks={'ds30': 19, 'ds35': 3},
                  expected_data_operations={'arm7_vram_reads': 14080, 'arm7_vram_stores': 14080,
                                            'arm9_uncached_ldm_word_reads': 61440},
                  suggested_frame_caps={'ds30': 80, 'ds35': 20},
                  files={str(p.relative_to(out)): sha(p.read_bytes()) for p in sorted(out.rglob('*')) if p.is_file()},
                  generator_sha256=sha(Path(__file__).read_bytes()),
                  matched=['A7: fixed-address ARM LDR/STR,64 ops,4/16 loops,independent min5,per-length warm1,phase192/96',
                           'A9: hardware post-index LDM r2-r9,16 per loop,ITCM,256/1024 LDMs,full-length warm+min5,C0B0'],
                  limits=['DS archives contain CSV/info, not the original measured ROM/ELF or executable digest.',
                          'Historical source continuity and declared compiler forms are pinned; original machine-code identity is unavailable.',
                          'ARM9 helper is the qualified ITCM IPCSYNC/VCOUNT poll, still I/O traffic; DS used calico mailbox wait.',
                          'ARM7 calico services/linker/stack are replaced by minimal crt0; DS code/data exact addresses were not captured.',
                          'ARM9 MPU/timer wrapper is unitmem; C0B0 is a separate8KiB region, not a toggled whole-main region.',
                          'Compile/disassemble before simulation: copied kernels/helper must fit1KiB slots and contain no external PC-relative dependencies.',
                          'Native compiled state/cache route and functional/model checks remain required; no current speed closure.'])
    (out / 'manifest.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    record = prepare(args.out.resolve())
    print(json.dumps({k: record[k] for k in ('status', 'canonical_checks', 'build_argv')}, indent=2))


if __name__ == '__main__':
    main()
