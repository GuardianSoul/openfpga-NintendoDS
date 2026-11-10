#!/usr/bin/env python3
"""Run all three cache mutations; only completed corruption checks count as caught.
  g3dcache_eq_mutate.py VERILATOR BUILD_DIR REF
Logs, source snapshots, commands and results remain in BUILD_DIR.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time

MUTATIONS = [
    ("a fill a flush met kept valid", ".f_ok(p_end ? !pstale : !stale)", ".f_ok(1'b1)", 2),
    ("flushes not passed on", ".inv_all(flush)", ".inv_all(1'b0)", 2),
    ("the lookup's valid read before the fill's last write",
     ".l_v(), .l_vn(vld_q)", ".l_v(vld_q), .l_vn()", 1),
]
FLAGS = ['--binary', '-j', '8', '-O2', '-Wno-fatal', '-Wno-WIDTHEXPAND',
         '-Wno-WIDTHTRUNC', '-Wno-UNUSEDSIGNAL', '-Wno-MULTIDRIVEN',
         '--top-module', 'tb_g3dcache_eq']
CYCLES = 200000


def cache_modules(source):
    return re.findall(r'^module nds_g3d_cache[^\n]*[\s\S]*?^endmodule', source, re.M)


def caught_corruption(output, rc, aw, lw):
    """A build failure or simulator crash is never a mutation-test success."""
    summary = re.search(
        r'^g3dcache_eq AW (\d+) LW (\d+): (\d+) cycles, (\d+) requests, '
        r'(\d+) answers compared .*: (\d+) errors$', output, re.M)
    witness = re.search(
        r"^cache 1: answer \d+ for word [0-9a-fA-F]+: (?:data [0-9a-fA-F]+ is another word's|"
        r'data from [1-9]\d* flushes before its lookup)$', output, re.M)
    # The bench intentionally uses $fatal after its completed FAIL summary.
    # Require that specific termination, not arbitrary nonzero return status.
    stop = re.search(r'^%Error: [^\n]*tb_g3dcache_eq\.sv:\d+: Verilog \$stop$', output, re.M)
    foreign_errors = [line for line in output.splitlines()
                      if line.startswith(('%Error', '%Fatal')) and not (
                          re.fullmatch(r'%Error: [^\n]*tb_g3dcache_eq\.sv:\d+: Verilog \$stop', line)
                          or re.fullmatch(r'%Fatal: [^\n]*tb_g3dcache_eq\.sv:\d+: Assertion failed in tb_g3dcache_eq', line))]
    # Recent Verilator prefixes %Fatal with the simulation timestamp.
    unexpected_fatal = any('%Fatal:' in line and not re.search(
        r'%Fatal: tb_g3dcache_eq\.sv:\d+: Assertion failed in tb_g3dcache_eq$', line)
        for line in output.splitlines())
    if (rc not in (1, -signal.SIGABRT) or not stop or foreign_errors or unexpected_fatal
            or not re.search(r'^FAIL$', output, re.M) or re.search(r'^PASS$', output, re.M)):
        return False, 'missing expected bench termination or other tool/runtime error'
    if not summary or not witness:
        return False, 'missing completed summary or concrete candidate corruption witness'
    got_aw, got_lw, cycles, requests, answers, errors = map(int, summary.groups())
    if ((got_aw, got_lw, cycles) != (aw, lw, CYCLES) or errors == 0 or requests == 0
            or answers < requests // 2):
        return False, 'wrong configuration, incomplete run, or no corruption'
    return True, witness[0]


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    verilator, build_arg, ref = sys.argv[1:]
    build = Path(build_arg).resolve()
    build.mkdir(parents=True, exist_ok=True)
    bench = Path(__file__).with_name('tb_g3dcache_eq.sv').resolve()
    source = Path('rtl/ds/nds_gpu3d.sv').read_text()
    reference = subprocess.run(['git', 'show', f'{ref}:rtl/ds/nds_gpu3d.sv'],
                               capture_output=True, text=True, check=True).stdout
    ref_v1 = next(m for m in cache_modules(reference) if m.startswith('module nds_g3d_cache #('))
    ref_v1 = ref_v1.replace('module nds_g3d_cache ', 'module nds_g3d_cache_ref ', 1) + '\n'
    new = '\n\n'.join(cache_modules(source)) + '\n'
    v1, rest = new.split('endmodule', 1)
    if not v1.startswith('module nds_g3d_cache #('):
        sys.exit('ERROR: first extracted module is not the V1 cache')
    opts = [shlex.split(o.replace(',', ' ')) for o in os.environ.get('EQ_OPTS', '-GWAYS=1').split()]
    if not opts:
        sys.exit('ERROR: EQ_OPTS must include at least one configuration')
    (build / 'ref.sv').write_text(ref_v1)
    files = [Path('rtl/ds/nds_gpu3d.sv'), Path('rtl/ds/nds_lcache.sv'),
             Path('rtl/gpu3d/gpu3d_ram.sv'), bench, Path(__file__)]
    source_hashes = {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    (build / 'inputs.json').write_text(json.dumps(source_hashes, indent=2) + '\n')
    commands, results = [], []

    def run(cmd, log):
        start = time.monotonic()
        try:
            with log.open('w') as f:
                proc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, timeout=600)
            rc = proc.returncode
        except (OSError, subprocess.TimeoutExpired) as exc:
            with log.open('a') as f:
                f.write(f'\nDRIVER ERROR: {exc}\n')
            rc = 124
        commands.append(dict(command=cmd, cwd=str(Path.cwd()), log=str(log), rc=rc,
                             seconds=round(time.monotonic() - start, 3)))
        (build / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        return rc, log.read_text(errors='replace')

    all_ok = True
    for i, (name, old, replacement, expected) in enumerate(MUTATIONS):
        d = build / f'm{i}'
        d.mkdir(exist_ok=True)
        if v1.count(old) != expected:
            print(f'ERROR     {name}: expected {expected} V1 targets, found {v1.count(old)}')
            results.append(dict(mutation=name, caught=False, reason='source-pattern mismatch'))
            all_ok = False
            continue
        mutated = v1.replace(old, replacement) + 'endmodule' + rest
        (d / 'new.sv').write_text(mutated)
        mutation_ok = True
        witnesses = []
        for aw, lw in ((19, 6), (17, 4)):
            for oi, opt in enumerate(opts):
                obj = d / f'aw{aw}-opt{oi}'
                obj.mkdir(exist_ok=True)
                exe = obj / 'Vtb_g3dcache_eq'
                exe.unlink(missing_ok=True)  # a failed build must never run an old binary
                cmd = [verilator, *FLAGS, f'-GAW={aw}', f'-GLW={lw}', *opt, '-Mdir', str(obj),
                       str(Path('rtl/gpu3d/gpu3d_ram.sv').resolve()),
                       str(Path('rtl/ds/nds_lcache.sv').resolve()), str(build / 'ref.sv'),
                       str(d / 'new.sv'), str(bench)]
                rc, output = run(cmd, obj / 'verilator.log')
                if rc != 0 or not exe.is_file():
                    results.append(dict(mutation=name, aw=aw, options=opt, caught=False,
                                        reason='build/tool failure', rc=rc, log=str(obj / 'verilator.log')))
                    mutation_ok = False
                    continue
                for seed, extra in ((1, []), (2, []), (3, ['+flush=8']), (4, ['+alias'])):
                    log = obj / f'seed{seed}.log'
                    rc, output = run([str(exe), f'+cycles={CYCLES}', f'+seed={seed}', *extra], log)
                    caught, detail = caught_corruption(output, rc, aw, lw)
                    results.append(dict(mutation=name, aw=aw, lw=lw, options=opt, seed=seed,
                                        caught=caught, detail=detail, rc=rc, log=str(log)))
                    mutation_ok &= caught
                    if caught:
                        witnesses.append(detail)
                    else:
                        print(f'ERROR     {name}, AW{aw} {opt} seed{seed}: {detail}; {log}')
        all_ok &= mutation_ok
        print(f'{"caught   " if mutation_ok else "ERROR    "} {name}: '
              f'{len(witnesses)}/{8 * len(opts)} cases; '
              f'{witnesses[0] if witnesses else "no qualifying corruption witness"}')
        (build / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    unchanged = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in source_hashes.items())
    all_ok &= unchanged
    (build / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    (build / 'summary.json').write_text(json.dumps(dict(passed=all_ok, inputs_unchanged=unchanged,
        configurations=len(opts), expected_cases=24 * len(opts),
        caught_cases=sum(r['caught'] for r in results), reference=ref), indent=2) + '\n')
    print(f'{"PASS" if all_ok else "FAIL"}: mutation results and full logs: {build}')
    return 0 if all_ok else 1


if __name__ == '__main__':
    sys.exit(main())
