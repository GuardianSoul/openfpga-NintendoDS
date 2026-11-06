#!/usr/bin/env python3
"""Build a bare native guest from the returned DS mixed-MUL live bytes."""
from pathlib import Path
import argparse, hashlib, importlib.util, json, os, resource, shutil, struct, subprocess, time

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--capture', type=Path, default=Path('/home/user/Git/NDS_Pocket/build/coordinator/a7mulmix-dslite-20261102'))
p.add_argument('--sdk-elf', type=Path, default=ROOT/'build/a7mulmix-sdk/attempt1/sdk/a7mulmix7.elf')
a = p.parse_args()
D = a.output.resolve()
D.mkdir(parents=True, exist_ok=False)
I = D/'inputs'
I.mkdir()
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_CPU, (60, 60))
resource.setrlimit(resource.RLIMIT_AS, (1024**3, 1024**3))
resource.setrlimit(resource.RLIMIT_FSIZE, (32*1024**2, 32*1024**2))
sha = lambda b: hashlib.sha256(b).hexdigest()
spec = importlib.util.spec_from_file_location('sdk', ROOT/'sw/hwref/arm7fetch/sdk-check.py')
elf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elf)
layout = json.loads((a.capture/'layout.json').read_text())
assert layout['build_id'] == '6950b2ad5884a118953a11c71ee0a6e74b636051c09942f911cfe1597e1c6f62'
assert sha(a.sdk_elf.read_bytes()) == layout['arm7_elf_SHA256']
kernel = elf.elf_symbol(a.sdk_elf, 'mm_mul')['body']
wrapper = elf.elf_symbol(a.sdk_elf, 'mm_invoke')['body']
helper = (a.capture/'raw/a7mulmix_v1_helper_itcm.bin').read_bytes()
assert len(kernel) == 272 and sha(kernel) == layout['code_SHA256']
assert len(wrapper) == 100 and sha(wrapper) == layout['wrapper']['SHA256']
assert len(helper) == 2024 and sha(helper[32:288]) == layout['helper']['SHA256']
assert sha(helper[32:]) == layout['helper']['initialized_SHA256']
for case in range(3):
    for region in range(2):
        name = f'a7mulmix_v1_k{case:02d}_r{region}.bin'
        b = (a.capture/'raw'/name).read_bytes()
        assert len(b) == 4128 and b[3104:3376] == b[3616:3888] == kernel
        (I/name).write_bytes(b)
(I/'layout.json').write_bytes((a.capture/'layout.json').read_bytes())
asm = ['.section .rodata,"a"', '.balign 4']
for name, b in [('kernel', kernel), ('wrapper', wrapper), ('helper', helper)]:
    target = I/(name+'.bin')
    target.write_bytes(b)
    asm += [f'.global captured_{name}', f'captured_{name}:', f'.incbin "{target}"', '.balign 4']
asm += ['.global captured_helper_end', 'captured_helper_end:']
(D/'blobs.S').write_text('\n'.join(asm)+'\n')
for name in ['native.h', 'arm7.c', 'arm9.c', 'invoke.S', 'runtime.c']:
    (D/name).write_bytes((HERE/name).read_bytes())
(D/'protocol.h').write_bytes((ROOT/'sw/hwref/a7mulmix/protocol.h').read_bytes())
(D/'ds.h').write_bytes((ROOT/'sw/tests/common/ds.h').read_bytes())
crt = (ROOT/'sw/tests/common/crt0.s').read_text()
# Keep the adapter stack below the captured wrapper's fixed private stack.
(D/'crt7.s').write_text(crt.replace('add     sp, r4, #0x3E00', 'add     sp, r4, #0x2000'))
(D/'crt9.s').write_text(crt.replace('0x0B00000A', '0x02FF000A').replace('0x0B000000', '0x02FF0000'))
record = dict(source=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              controller=os.getpid(), DS_build=layout['build_id'], commands=[],
              caps=dict(NI=10, jobs=1, threads=1, CPU_seconds=60, AS_bytes=1024**3),
              scope='Exact live kernel272/wrapper100, addresses, fifth arg, wrapper SP and quiet helper2024. Bare boot/dispatch/timestamp/caller replace SDK; raw absolute windows retained, no offset subtraction. No service-policy or native timing acceptance.')
def save():
    (D/'build.json').write_text(json.dumps(record, indent=2)+'\n')
def run(cmd, tag):
    begin = time.monotonic()
    with (D/(tag+'.log')).open('w') as f:
        proc = subprocess.Popen(list(map(str, cmd)), cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
        row = dict(tag=tag, cmd=list(map(str, cmd)), PID=proc.pid,
                   starttime=Path('/proc', str(proc.pid), 'stat').read_text().rsplit(')', 1)[1].split()[19])
        record['commands'].append(row)
        save()
        try:
            row['exit'] = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.terminate()
            row['exit'] = proc.wait(timeout=5)
            row['timeout'] = True
    row.update(reaped=True, wall_seconds=round(time.monotonic()-begin, 3))
    save()
    assert row['exit'] == 0, (tag, (D/(tag+'.log')).read_text()[-3000:])
for cpu, target in [(7, 'armv4t-none-eabi'), (9, 'armv5te-none-eabi')]:
    cc = [shutil.which('clang'), f'--target={target}', f'-mcpu={"arm7tdmi" if cpu == 7 else "arm946e-s"}']
    flags = ['-O2', '-mthumb' if cpu == 7 else '-marm', '-ffreestanding', '-fno-builtin', '-nostdlib', '-fno-pic', '-mfloat-abi=soft', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-Wall', '-Wextra', '-Werror', '-I', D]
    objects = []
    for name in [f'crt{cpu}.s', f'arm{cpu}.c', 'blobs.S', 'runtime.c'] + (['invoke.S'] if cpu == 7 else []):
        obj = D/f'{cpu}-{Path(name).stem}.o'
        options = (['-Wa,-defsym,ARM9=1'] if cpu == 9 and name.startswith('crt') else [])
        run(cc + (flags if name.endswith('.c') else options) + ['-c', D/name, '-o', obj], f'{cpu}-{Path(name).stem}')
        objects.append(obj)
    run([shutil.which('ld.lld'), '-T', ROOT/'sw/tests/common/ds.ld', f'--defsym=__base={"0x037f8000" if cpu == 7 else "0x02000000"}', *objects, '-o', D/f'arm{cpu}.elf'], f'{cpu}-link')
    run([shutil.which('llvm-objcopy'), '-O', 'binary', D/f'arm{cpu}.elf', D/f'arm{cpu}.bin'], f'{cpu}-binary')
    assert (D/f'arm{cpu}.bin').stat().st_size < 32768
run(['python3', ROOT/'tools/ds-tests/mknds.py', D/'a7mulmix-native.nds', '--title', 'A7MULMIX', '--code', 'AMMX', '--arm9', D/'arm9.bin', '--arm7', D/'arm7.bin'], 'ROM')
for cpu in [7, 9]:
    for symbol, expected in [('captured_kernel', kernel), ('captured_wrapper', wrapper), ('captured_helper', helper)]:
        address = elf.elf_symbol(D/f'arm{cpu}.elf', symbol)['address']
        assert elf.allocated_image(D/f'arm{cpu}.elf', address, len(expected)) == expected
    run([shutil.which('llvm-objdump'), '-d', D/f'arm{cpu}.elf'], f'{cpu}-disassembly')
record['dump_pc'] = hex(elf.elf_symbol(D/'arm9.elf', 'native_mul_done')['address'])
record['ROM_SHA256'] = sha((D/'a7mulmix-native.nds').read_bytes())
record['inputs'] = {str(f.relative_to(D)): sha(f.read_bytes()) for f in sorted(D.rglob('*')) if f.is_file() and f.name != 'build.json'}
save()
print('BUILT native mixed-MUL guest', record['ROM_SHA256'], 'dump_pc', record['dump_pc'])
