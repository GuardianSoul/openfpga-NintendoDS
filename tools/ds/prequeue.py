#!/usr/bin/env python3
"""Pre-queue gate for full-chip fits (docs/plan-full-core.md section 5,
AGENTS.md "Plan and fit process" rule 2).

    /home/user/Git/NDS_Pocket/tools/ds/prequeue.py GIT_REF [--seed 1asR] [--keep]

Run main's copy by its absolute path: the receipt goes to that checkout's
build/prequeue/<sha>.receipt, where tools/jenkins/queue-nds-fit.sh looks for
it before it queues TARGET=ds (a fit without a PASS receipt is refused unless
PREQUEUE_OVERRIDE='<reason>' is set). On the committed source of GIT_REF
(git archive, never the working tree), in order:

  1. qlint (tools/ds/qlint.py): the Quartus Standard source pitfalls.
  2. Verilator: a full-chip --lint-only of sim/pocket_ds/run.py's RTL and SIM
     lists (tb_ds_pocket on top), %Error fails.
  3. Quartus elaboration and synthesis: scripts/build_ds.sh with DS_PREQUEUE=1
     runs quartus_map only (#2171: a megafunction that does not elaborate).
     Refused while a psx-fit build waits in the Jenkins queue (AGENTS.md
     "Fitting machines"), or with under 12 GB of memory free.
  4. RAM inference: "can't infer memory for variable ... with attribute"
     (10999: #2050, nds_vram's read line built from flip-flops) and every
     "RAM logic ... is uninferred" (276007) whose array carries a ramstyle
     attribute in its module fail; Quartus errors on illegal RAM modes fail
     step 3.
  5. SDC endpoints: the SDC read on the post-map netlist (quartus_sta,
     create_timing_netlist -post_map). Its own assertions (#2172 missing
     IO_ROUTE endpoints, #2183 an ambiguous register) and any Quartus error
     fail; ignored filters/assignments (332174, 332049) are listed as warnings.
     The SDC's post_message counts (the fast paths it found) go into the
     receipt.

The receipt is written even on a failure (verdict FAIL), so the queue refuses
the same source until it is fixed. Exit 0 only on PASS.
"""
import argparse
import datetime
import importlib.util
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QUARTUS = Path(os.environ.get('QUARTUS_BIN', Path.cwd() / 'build/tools/quartus-lite/25.1/quartus/bin'))
TOOLS = Path(os.environ.get('TOOLS', Path.cwd() / 'build/tools/oss-cad-suite/bin'))
QUEUE = ROOT / 'tools/jenkins/queue-nds-fit.sh'
# scripts/build_ds.sh's DS_PREQUEUE stop (kept equal to the copy there), for sources from before it
PQ_BLOCK = r'''if [ "${DS_PREQUEUE:-0}" = 1 ]; then
  # pre-queue gate: synthesis (RAM inference in map.log/map.rpt) and the SDC
  # read on the post-map netlist (its own assertions, ignored filters and
  # assignments, every constraint's collection); no fit (tools/ds/prequeue.py)
  set +e
  quartus_map $top > map.log 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    cat > pq_sdc.tcl <<'TCL'
project_open apf_top
create_timing_netlist -post_map
read_sdc
update_timing_netlist
report_clocks -file pq_clocks.txt
TCL
    if [ "${PQ_RECEIPT_TEST:-0}" = 1 ]; then
      echo "source ${PQ_RECEIPT_TCL:-$root/tools/fit/timing_receipt.tcl}" >> pq_sdc.tcl
      echo "timing_receipt pq_timing_receipt.txt" >> pq_sdc.tcl
    fi
    quartus_sta -t pq_sdc.tcl > pq_sdc.log 2>&1
    rc=$((rc | ($? << 4)))
  fi
  echo $rc > pq.rc
  exit $rc
fi
'''


def sh(cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def psx_waiting():
    """The psx-fit builds waiting in the Jenkins queue, or None if the queue can't be read (fail closed)."""
    r = sh(['bash', str(QUEUE), 'status'])
    if r.returncode:
        return None
    # only one that could start on this node (the gate runs on the Desktop): a wait for 'Laptop' alone doesn't count
    node = os.environ.get('PREQUEUE_NODE', 'Desktop')
    return [l for l in r.stdout.splitlines() if 'psx-fit' in l and 'Waiting' in l
            and (node in l or not re.search(r"on ‘[^’]+’", l))]


def mem_avail_gb():
    m = re.search(r'MemAvailable:\s+(\d+)', Path('/proc/meminfo').read_text())
    return int(m[1]) / (1 << 20)


def ram_arrays(rtl):
    """{(module, array)} for arrays declared under a ramstyle attribute."""
    out = set()
    for f in rtl.rglob('*.sv'):
        mod = None
        pend = False
        for line in f.read_text(errors='replace').splitlines():
            code = line.split('//')[0]
            m = re.match(r'\s*module\s+(\w+)', code)
            if m:
                mod = m.group(1)
            if 'ramstyle' in code:
                pend = True
            if pend and mod:
                m = re.search(r'(?:logic|reg|bit)\b[^;]*?\b(\w+)\s*\[[^\]]*\]\s*(?:\[[^\]]*\]\s*)*;', code)
                if m:
                    out.add((mod, m.group(1)))
                    pend = False
                elif code.strip().endswith(';'):
                    pend = False
    return out


def entity_table(rpt):
    """{hierarchy path: (combinational ALUTs, registers, block memory bits)} from map.rpt's 'Analysis & Synthesis
    Resource Utilization by Entity', down to four levels under core_top (the units and their first blocks)."""
    out = {}
    i = rpt.find('; Analysis & Synthesis Resource Utilization by Entity')
    if i < 0:
        return out
    for l in rpt[i:].splitlines()[4:]:
        if not l.startswith(';'):
            break
        c = [x.strip() for x in l.strip(';').split(';')]
        if len(c) < 8:
            continue
        path = c[7].replace(' ', '')
        if path.count('|') > 6 or not path.startswith('|apf_top|core_top:ic'):
            continue
        num = lambda x: int(re.match(r'\d+', x.replace(',', ''))[0]) if re.match(r'\d', x) else 0
        out[path] = (num(c[1]), num(c[2]), num(c[3]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ref')
    ap.add_argument('--seed', default='1asR', help='build_ds.sh seed string (its letters set the Quartus mode)')
    ap.add_argument('--keep', action='store_true', help='keep the exported source and Quartus project')
    ap.add_argument('--no-quartus', action='store_true', help='steps 1-2 only (no receipt: the queue needs all five)')
    ap.add_argument('--base', help='a ref whose PASS receipt (with its entity table) the synthesis is compared with: '
                    'an entity that grows by more than --reg-jump registers or --alut-jump ALUTs fails')
    ap.add_argument('--reg-jump', type=int, default=100)
    ap.add_argument('--alut-jump', type=int, default=150)
    ap.add_argument('--accept-growth', help="a reason: the entity check reports but doesn't fail (an intended growth)")
    a = ap.parse_args()
    sha = sh(['git', '-C', str(ROOT), 'rev-parse', '--verify', a.ref + '^{commit}']).stdout.strip()
    if not sha:
        sys.exit(f'prequeue: {a.ref} is not a commit in {ROOT}')
    base = ROOT / 'build/prequeue'
    work = base / sha[:12]
    receipt = base / f'{sha}.receipt'
    shutil.rmtree(work, ignore_errors=True)
    src = work / 'src'
    src.mkdir(parents=True)
    arc = subprocess.Popen(['git', '-C', str(ROOT), 'archive', sha, 'rtl', 'scripts', 'tools', 'sw/boot', 'sw/scpu', 'sim'],
                           stdout=subprocess.PIPE)
    subprocess.run(['tar', '-x', '-C', str(src)], stdin=arc.stdout, check=True)
    arc.wait()
    lines = [f'sha={sha}', f'ref={a.ref}', f'date={datetime.datetime.now().isoformat(timespec="seconds")}',
             f'seed={a.seed}']
    ok = True

    def step(name, passed, detail=''):
        nonlocal ok
        ok = ok and passed
        lines.append(f'step {name} {"PASS" if passed else "FAIL"}' + (f': {detail}' if detail else ''))
        print(lines[-1], flush=True)

    def finish():
        lines.append(f'verdict={"PASS" if ok else "FAIL"}')
        receipt.write_text('\n'.join(lines) + '\n')
        print(f'prequeue: {"PASS" if ok else "FAIL"}  receipt {receipt}')
        if ok and not a.keep:
            shutil.rmtree(work, ignore_errors=True)
        sys.exit(0 if ok else 1)

    # 1. qlint
    r = sh(['python3', str(src / 'tools/ds/qlint.py')], cwd=src)
    step('qlint', r.returncode == 0, (r.stdout + r.stderr).strip().splitlines()[-1] if r.returncode else '')
    # 2. Verilator lint of the full chip, run.py's lists
    spec = importlib.util.spec_from_file_location('pq_run', src / 'sim/pocket_ds/run.py')
    run = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(run)
    srcs = [str(src / 'rtl' / f) for f in run.RTL] + [str(src / f) for f in run.SIM]
    r = sh([str(TOOLS / 'verilator'), '--lint-only', '--timing', '-Wno-fatal', '-Wno-WIDTHEXPAND', '-Wno-WIDTHTRUNC',
            '-Wno-UNUSEDSIGNAL', '--timescale', '1ns/1ps', '--top-module', 'tb_ds_pocket', '+define+NODEBUG',
            '-I' + str(src / 'rtl/pocket'), *srcs], cwd=src)
    errs = [l for l in (r.stdout + r.stderr).splitlines() if l.startswith('%Error')]
    step('verilator', r.returncode == 0 and not errs, errs[0][:300] if errs else (f'rc {r.returncode}' if r.returncode else ''))
    if a.no_quartus:
        print('prequeue: --no-quartus: steps 1-2 only, no receipt')
        sys.exit(0 if ok else 1)
    # 3. Quartus synthesis, unless a psx-fit build is due on the node or memory is short
    waiting = psx_waiting()
    if waiting is None:
        step('quartus', False, 'cannot read the Jenkins queue (psx-fit check): not starting Quartus')
        finish()
    if waiting:
        step('quartus', False, 'psx-fit queued, Quartus not started (rerun later): ' + waiting[0][:120])
        finish()
    if mem_avail_gb() < 12:
        step('quartus', False, f'{mem_avail_gb():.1f} GB free, under 12: not starting Quartus (rerun later)')
        finish()
    # the source's own build_ds.sh generates the project and SDC; it stops after synthesis only with the
    # DS_PREQUEUE block, so a source from before the gate gets it inserted ahead of its map/fit chain
    bds = src / 'scripts/build_ds.sh'
    text = bds.read_text()
    if 'DS_PREQUEUE' not in text:
        anchor = re.search(r'^quartus_map \$top > map\.log 2>&1 && quartus_fit', text, re.M)
        if not anchor:
            step('quartus', False, "scripts/build_ds.sh has no 'quartus_map ... && quartus_fit' chain to stop before: not run")
            finish()
        text = text[:anchor.start()] + PQ_BLOCK + text[anchor.start():]
        bds.write_text(text)
        lines.append('note: DS_PREQUEUE stop inserted into the source\'s build_ds.sh (a source from before the gate)')
    q = work / 'q'
    env = dict(os.environ, DS_PREQUEUE='1', PATH=f'{QUARTUS}:{os.environ["PATH"]}', TMPDIR=str(work / 'tmp'))
    if os.environ.get('PQ_RECEIPT_TEST') == '1':     # the timing receipt Tcl run on the post-map netlist (its API, not timing)
        env['PQ_RECEIPT_TEST'] = '1'
        env['PQ_RECEIPT_TCL'] = str(ROOT / 'tools/fit/timing_receipt.tcl')
    (work / 'tmp').mkdir(exist_ok=True)
    r = sh(['bash', str(src / 'scripts/build_ds.sh'), str(q), a.seed], cwd=src, env=env)
    rc = int((q / 'pq.rc').read_text()) if (q / 'pq.rc').exists() else -1
    maplog = (q / 'map.log').read_text(errors='replace') if (q / 'map.log').exists() else ''
    merrs = [l for l in maplog.splitlines() if l.startswith('Error (')]
    step('quartus', rc != -1 and (rc & 15) == 0,
         (merrs[0][:300] if merrs else f'build_ds.sh rc {r.returncode}: {(r.stdout + r.stderr).strip()[-300:]}') if rc == -1 or rc & 15 else
         next((l.strip() for l in maplog.splitlines() if 'Elapsed time' in l), ''))
    if rc == -1 or rc & 15:
        finish()
    # 4. RAM inference
    rams = ram_arrays(src / 'rtl')
    bad, info = [], []
    # Candidates: a ramstyle array Quartus gave up on (276007 "uninferred", or 10999 "can't infer memory": #2050,
    # dfd4d338) and also any 10999. Neither message alone is a failure (Quartus can take another inference,
    # 009304d2; an unused array gets 10999 too, nds_lcache's mem in the pumped tag mode). The array fails when its
    # bits are registers in the post-map netlist (get_registers *|<module>:*|<array>[* or <array>~*); map.rpt's
    # tables don't list them (dfd4d338: rb's 256 registers, no "rb[" in map.rpt).
    cand = []                     # (label, module, array, why)
    for m in re.finditer(r'RAM logic "([^"]+)" is uninferred due to ([^.\n]+)', maplog):
        path, why = m[1], m[2].strip()
        parts = path.split('|')
        arr = parts[-1]
        mod = next((p.split(':')[0] for p in reversed(parts[:-1]) if ':' in p), '')   # (generate blocks have no entity)
        if (mod, arr) in rams:
            cand.append((path, mod, arr, why))
        else:
            info.append(f'{path} ({why})')
    for m in re.finditer(r"can't infer memory for variable '([^']+)' with attribute '([^']*)'\.\s*File: (\S+) Line: (\d+)", maplog):
        var, f, ln = m[1], Path(m[3]), int(m[4])
        mods = [mm[1] for mm in (re.match(r'\s*module\s+(\w+)', l) for l in
                                 (f.read_text(errors='replace').splitlines()[:ln] if f.exists() else [])) if mm]
        mod = mods[-1] if mods else f.stem
        cand.append((f'{mod}.{var} at {f.name}:{ln}', mod, var, f'10999, attribute {m[2]}'))
    if cand:
        tcl = q / 'pq_ram.tcl'
        pats = sorted({(mod, arr) for _, mod, arr, _ in cand})
        tcl.write_text('project_open apf_top\ncreate_timing_netlist -post_map\n' + ''.join(
            f'puts "PQRAM {mod} {arr} [get_collection_size [get_registers -nowarn {{*|{mod}:*|{arr}[*}}]]'
            f' [get_collection_size [get_registers -nowarn {{*|{mod}:*|{arr}~*}}]]"\n' for mod, arr in pats))
        rr = sh(['quartus_sta', '-t', str(tcl)], cwd=q, env=env)
        regs = {}
        for l in rr.stdout.splitlines():
            f = l.split()
            if len(f) == 5 and f[0] == 'PQRAM':
                regs[(f[1], f[2])] = int(f[3]) + int(f[4])
        if len(regs) != len(pats):
            step('ram', False, f'post-map register query failed (rc {rr.returncode}): {(rr.stdout + rr.stderr).strip()[-200:]}')
            finish()
        for label, mod, arr, why in cand:
            n = regs[(mod, arr)]
            (bad if n else info).append(f'{label} ({why}; {n} registers in the post-map netlist)')
    for b in bad:
        lines.append(f'ram uninferred (ramstyle): {b}')
    for i in info:
        lines.append(f'ram uninferred (no ramstyle, informative): {i}')
    step('ram', not bad, f'{len(bad)} ramstyle array(s) not inferred' if bad else f'{len(rams)} ramstyle arrays, {len(info)} other uninferred')
    # 5. SDC on the post-map netlist
    slog = (q / 'pq_sdc.log').read_text(errors='replace') if (q / 'pq_sdc.log').exists() else ''
    serrs = [l for l in slog.splitlines() if l.startswith('Error (')]
    swarn = [l for l in slog.splitlines() if re.match(r'Warning \((332174|332049)\)', l)]
    for l in [l for l in slog.splitlines() if l.startswith('Info (332000)') or l.startswith('Info:') and ' paths' in l][:40]:
        lines.append(f'sdc info: {l[:240]}')
    for w in swarn[:40]:
        lines.append(f'sdc warning: {w[:240]}')
    step('sdc', (rc >> 4) == 0 and not serrs, serrs[0][:300] if serrs else f'{len(swarn)} ignored filter/assignment warning(s)')
    # 5b. pinned nodes: every set_location_assignment onto an M10K/MLAB/LAB/FF site must name exactly one cell of the
    # post-map netlist (a renamed RAM or register would silently drop its pin; #2299's I-tag pins)
    qsf = q / 'apf_top.qsf'
    pins = re.findall(r'^set_location_assignment\s+((?:M10K|MLABCELL|LABCELL|FF)_X\d+_Y\d+_N\d+|LAB_X\d+_Y\d+)\s+-to\s+"?([^"\n]+?)"?\s*$',
                      qsf.read_text(errors='replace') if qsf.exists() else '', re.M)
    if pins:
        tcl = q / 'pq_pins.tcl'
        tcl.write_text('project_open apf_top\ncreate_timing_netlist -post_map\n' + ''.join(
            f'puts "PQPIN {i} [get_collection_size [get_cells -nowarn {{{node}}}]]"\n' for i, (_, node) in enumerate(pins)))
        rr = sh(['quartus_sta', '-t', str(tcl)], cwd=q, env=env)
        got = {int(f[1]): int(f[2]) for f in (l.split() for l in rr.stdout.splitlines()) if len(f) == 3 and f[0] == 'PQPIN'}
        badp = [f'{site} -> {node}: {got.get(i, "no answer")} cells' for i, (site, node) in enumerate(pins) if got.get(i) != 1]
        for i, (site, node) in enumerate(pins):
            lines.append(f'pin {site} -> {node}: {got.get(i, "?")} cell(s)')
        step('pins', not badp, f'{len(badp)} pin(s) not on exactly one cell: {badp[0][:200]}' if badp else f'{len(pins)} pinned node(s), each one cell')
    # 6. per-entity synthesis counts (recorded in every receipt; with --base, a jump fails: RC8p d55256c2, nds_vram
    # +164.5 ALMs from a read line built as registers, would have shown as +256 registers here)
    rpt = q / 'output_files/apf_top.map.rpt'
    ents = entity_table(rpt.read_text(errors='replace') if rpt.exists() else '')
    for path, (al, rg, bits) in sorted(ents.items()):
        lines.append(f'entity {path} aluts {al} regs {rg} bits {bits}')
    if a.base:
        bsha = sh(['git', '-C', str(ROOT), 'rev-parse', '--verify', a.base + '^{commit}']).stdout.strip()
        bfile = base / f'{bsha}.receipt'
        bent = {}
        if bfile.exists():
            for l in bfile.read_text().splitlines():
                f = l.split()
                if len(f) == 8 and f[0] == 'entity':
                    bent[f[1]] = (int(f[3]), int(f[5]), int(f[7]))
        if not bent:
            step('entities', False, f'no entity table in the base receipt {bfile} (run the gate on {a.base} first)')
            finish()
        jumps = []
        for path, (al, rg, bits) in sorted(ents.items()):
            if path in bent:
                bal, brg, bbits = bent[path]
                if rg - brg > a.reg_jump or al - bal > a.alut_jump:
                    jumps.append(f'{path}: regs {brg} -> {rg} ({rg - brg:+d}), ALUTs {bal} -> {al} ({al - bal:+d}), '
                                 f'block bits {bbits} -> {bits}')
        jumps.sort(key=lambda j: -j.split(':', 1)[0].count('|'))   # the deepest entity first (its parents follow)
        for j in jumps:
            lines.append(f'entity jump vs {a.base}: {j}')
        lines.append(f'base={bsha}')
        if jumps and a.accept_growth:
            lines.append(f'entity growth accepted: {a.accept_growth}')
        step('entities', not jumps or bool(a.accept_growth),
             f'{len(jumps)} entity jump(s) vs {a.base}: {jumps[0][:200] if jumps else ""}' if jumps else f'none over +{a.reg_jump} regs / +{a.alut_jump} ALUTs vs {a.base}')
    finish()


if __name__ == '__main__':
    main()
