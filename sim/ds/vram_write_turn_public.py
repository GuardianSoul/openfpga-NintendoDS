"""Actual configured Root/transport elaboration, default identity and wire fault."""
from pathlib import Path
import gzip
import hashlib
import json
import os
import re
import subprocess

R = Path(__file__).resolve().parents[2]
MAIN = R
B = R/'build/vram-write-turn-public'
B.mkdir(parents=True, exist_ok=True)
os.setpriority(os.PRIO_PROCESS, 0, 10)
H = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
J = lambda p: json.loads(p.read_text())
BEFORE_SOURCE = '73cc86ac'
before = subprocess.check_output(['git', 'show', BEFORE_SOURCE+':rtl/pocket/core_top_ds.sv'], cwd=R, text=True)
after = (R/'rtl/pocket/core_top_ds.sv').read_text()
decl = '    parameter bit VRAM_CUT_WRITE_TURN = 0,     // opt-in observed physical-take turnover\n'
route = ', .CUT_WRITE_TURN(VRAM_CUT_WRITE_TURN)'
assert after.count(decl) == after.count(route) == 1
assert after.replace(decl, '').replace(route, '') == before
old = B/'before_core_top.sv'
assert before.count('module core_top #') == 1
old.write_text(before.replace('module core_top #', 'module before_core_top #', 1))
profile = J(MAIN/'docs/results/scenes63-20261102/host/runtime-provenance.json')['profile']
profile.update(A7_VRAM_IO_READ_SIDE=1, CACHE_SLOTS=64)
assignments = ','.join(f'.{k}({v})' for k, v in sorted(profile.items()))
tb = B/'tb_write_turn_route.sv'
tb.write_text('module tb_write_turn_route;\n'
    f'before_core_top #({assignments}) before_dut();\n'
    f'core_top #({assignments},.VRAM_CUT_WRITE_TURN(0)) off_dut();\n'
    f'core_top #({assignments},.VRAM_CUT_WRITE_TURN(1)) on_dut();\nendmodule\n')
args = J(MAIN/'docs/results/a7-vram-data-public58-20261102/args.json')
origin = '/home/user/Git/NDS_Pocket-codex-combined-next'
args = [s.replace(origin, str(R)) for s in args]
args[args.index('tb_data_route58')] = 'tb_write_turn_route'
old_tb = next(s for s in args if s.endswith('tb_data_route58.sv'))
args[args.index(old_tb)] = str(tb)
args.append(str(old))
assert all(Path(s).is_file() for s in args if s.endswith(('.sv', '.v')))

def walk(n):
    if isinstance(n, dict):
        yield n
        for v in n.values():
            yield from walk(v)
    elif isinstance(n, list):
        for v in n:
            yield from walk(v)

def params(module):
    return {v['name']: v['valuep'][0]['name'] for v in module.get('stmtsp', [])
            if v.get('isParam') and len(v.get('valuep', [])) == 1
            and v['valuep'][0].get('type') == 'CONST'}

def number(value):
    m = re.fullmatch(r"\d+'s?([hbd])([0-9a-fA-F]+)", value)
    assert m, value
    return int(m[2], {'h': 16, 'b': 2, 'd': 10}[m[1]])

def inspect(tree):
    modules = {m['name']: m for m in tree['modulesp']}
    def child(module, name):
        cells = [c for c in walk(module.get('stmtsp', []))
                 if c.get('type') == 'CELL' and (c['name'] == name or c['name'].endswith('.'+name))]
        assert len(cells) == 1, name
        return modules[cells[0]['modName']]
    top = modules['tb_write_turn_route']
    result, signatures = {}, {}
    for side in ['before_dut', 'off_dut', 'on_dut']:
        root = child(top, side)
        actual = params(root)
        assert all(number(actual[k]) == v for k, v in profile.items())
        xp = params(child(root, 'x_vram'))
        result[side] = {k: number(xp[k]) for k in ['QW', 'SHARED', 'CUT_TAG', 'CUT_WRITE_TURN']}
        assert [result[side][k] for k in ['QW', 'SHARED', 'CUT_TAG']] == [8, 1, 1]
        if side != 'on_dut':
            signature = {}
            def visit(module, path):
                p = params(module)
                if not path:
                    p.pop('VRAM_CUT_WRITE_TURN', None)
                signature[path] = p
                for c in walk(module.get('stmtsp', [])):
                    if c.get('type') == 'CELL':
                        visit(modules[c['modName']], path+'/'+c['name'])
            visit(root, '')
            signatures[side] = signature
    assert signatures['before_dut'] == signatures['off_dut'], 'disabled hierarchy parameter identity failed'
    result['default_parameter_instances_equal'] = len(signatures['off_dut'])
    result['default_signature_sha256'] = hashlib.sha256(json.dumps(signatures['off_dut'], sort_keys=True).encode()).hexdigest()
    return result

records = []
for kind in ['positive', 'dropped-wire']:
    a = list(args)
    tree = B/(kind+'.tree.json')
    meta = B/(kind+'.meta.json')
    a[a.index('--json-only-output')+1] = str(tree)
    a[a.index('--json-only-meta-output')+1] = str(meta)
    if kind == 'dropped-wire':
        mutant = B/'mutant_core_top.sv'
        mutant.write_text(after.replace('.CUT_WRITE_TURN(VRAM_CUT_WRITE_TURN)', '.CUT_WRITE_TURN(0)', 1))
        a[a.index(str(R/'rtl/pocket/core_top_ds.sv'))] = str(mutant)
    with (B/(kind+'.log')).open('w') as log:
        p = subprocess.Popen(a, cwd=R, stdout=log, stderr=subprocess.STDOUT)
        record = dict(case=kind, PID=p.pid, starttime=Path('/proc',str(p.pid),'stat').read_text().split()[21],
            NI=os.getpriority(os.PRIO_PROCESS,p.pid), jobs=1, threads=1, argv=a)
        (B/'worker.json').write_text(json.dumps(record, indent=2)+'\n')
        record['exit'] = p.wait(timeout=180)
    assert record['exit'] == 0, (B/(kind+'.log')).read_text()[-3000:]
    record['route'] = inspect(J(tree))
    r = record['route']
    assert r['before_dut']['CUT_WRITE_TURN'] == r['off_dut']['CUT_WRITE_TURN'] == 0
    assert r['on_dut']['CUT_WRITE_TURN'] == (1 if kind == 'positive' else 0)
    record['actual_dropped_forward_RTL_mutation_caught'] = kind == 'dropped-wire'
    record['tree_sha256'] = H(tree)
    with tree.open('rb') as src, gzip.open(str(tree)+'.gz', 'wb') as dst:
        while chunk := src.read(1<<20):
            dst.write(chunk)
    tree.unlink()
    records.append(record)
out = dict(status='PASS', results=records, before_root_sha256=hashlib.sha256(before.encode()).hexdigest(),
    before_source=subprocess.check_output(['git','rev-parse',BEFORE_SOURCE],cwd=R,text=True).strip(),
    after_root_sha256=H(R/'rtl/pocket/core_top_ds.sv'), fixture_sha256=H(tb),
    private_transport_sha256=H(R/'rtl/pocket/nds_sdram_bus.sv'),
    scope='Actual configured Root before/off parameter identity and public0/1 physical transport route, plus actual dropped-forward mutation. CACHE_SLOTS64 routing fixture, not native timing/frame/area qualification. Private27-triple proof is separate; no production transport edits.')
(B/'result.json').write_text(json.dumps(out, indent=2)+'\n')
print(json.dumps(dict(status='PASS', parameter_instances=records[0]['route']['default_parameter_instances_equal'],
    before_off_on_CUT=[records[0]['route'][k]['CUT_WRITE_TURN'] for k in ['before_dut','off_dut','on_dut']],
    actual_dropped_forward_mutant_caught=True)))
