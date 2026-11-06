#!/usr/bin/env python3
"""Append one passive observer to a copied, source-bound compile argv. No build."""
from pathlib import Path
import argparse
import hashlib
import json
import re

HERE = Path(__file__).resolve().parent
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def compose(argv, root):
    contract = json.loads((HERE / 'source-contract.json').read_text())
    for name, expected in contract['production_RTL_sha256'].items():
        assert sha(root / name) == expected, ('wrong joined52 RTL', name)
    observer = HERE / 'observer.sv'
    assert sha(observer) == contract['observer_sha256'], 'changed observer'
    assert argv[argv.index('--top-module') + 1] == 'tb_ds_pocket'
    for option in ['-j', '--threads']:
        assert argv[argv.index(option) + 1] == '1', option
    for arg in argv:
        p = Path(arg)
        if p.suffix in ['.sv', '.v'] and p.is_file():
            assert not re.search(r'\bmodule\s+memory_io_cause_observer\b', p.read_text()), 'duplicate observer'
    result = list(argv) + [str(observer)]
    assert result[:-1] == argv  # No testbench, flag, source or input substitution.
    return result, dict(source=contract['source'], observer=str(observer),
                        observer_sha256=sha(observer), execution=False,
                        RTL_files_checked=len(contract['production_RTL_sha256']),
                        runtime_plusarg=contract['plusarg'],
                        scope='Source/argv only; actual elaboration and runtime pending')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('incoming', type=Path)
    p.add_argument('source_root', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    before = a.incoming.read_bytes()
    obj = json.loads(before)
    argv = obj['argv'] if isinstance(obj, dict) else obj
    argv, receipt = compose(argv, a.source_root.resolve())
    receipt['incoming_sha256'] = hashlib.sha256(before).hexdigest()
    receipt_path = a.output.with_suffix('.iocause.json')
    assert not a.output.exists() and not receipt_path.exists(), 'fresh outputs required'
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(dict(obj, argv=argv) if isinstance(obj, dict) else argv, indent=2) + '\n')
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    assert a.incoming.read_bytes() == before
    print('IOCAUSE_SOURCE_ONLY_READY one bind file appended; no compile/run/TB write')
