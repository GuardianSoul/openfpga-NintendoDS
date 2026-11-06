#!/usr/bin/env python3
"""Seal component binary hashes, then remove only this run's compiler scratch."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil


def main(base):
    worker = json.loads((base / 'worker.json').read_text())
    qualified = json.loads((base / 'qualification.json').read_text())
    assert worker['state'] == 'CONTROLLER_FINISHED' and worker['child'] is None
    for entry in worker['steps']:
        assert entry['reaped']
        proc = Path('/proc', str(entry['pid']), 'stat')
        if proc.exists():
            assert proc.read_text().split()[21] != entry['start_ticks'], 'owned child still alive'
    models = {}
    for name, sub, binary in [
            ('canonical', 'records', 'Vtb_record_guards'),
            ('publication_default', 'publication-default', 'Vtb_ds_pocket'),
            ('publication_enabled', 'publication-enabled', 'Vtb_ds_pocket')]:
        path = base / 'scratch' / sub / binary
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        assert digest == qualified['model_sha256'][name]
        models[name] = dict(sha256=digest, bytes=path.stat().st_size)
    tree = base / 'full-adapter.tree.json'
    raw = tree.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == qualified['full_elaboration_json_sha256']
    with gzip.GzipFile(filename=str(tree) + '.gz', mode='wb', mtime=0) as output:
        output.write(raw)
    tree.unlink()
    removed = 0
    for name in ('scratch', 'obj_dir'):
        scratch = base / name
        if scratch.exists():
            removed += sum(p.stat().st_size for p in scratch.rglob('*') if p.is_file())
            shutil.rmtree(scratch)
    receipt = dict(state='ALL_COMPONENT_CHILDREN_REAPED_PRIVATE_COMPILER_SCRATCH_REMOVED',
                   models=models, controller=worker['controller'], cleanup_pid=os.getpid(),
                   full_elaboration_gzip_sha256=hashlib.sha256(Path(str(tree) + '.gz').read_bytes()).hexdigest(),
                   compiler_scratch_bytes_removed=removed)
    (base / 'cleanup.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    main(parser.parse_args().base.resolve())
