#!/usr/bin/env python3
"""Exercise actual cache files/locks without building or running an RTL model."""
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

runner = Path(os.environ.get('POCKET_RUNNER_PATH', Path(__file__).with_name('run.py')))
spec = importlib.util.spec_from_file_location('pocket_run', runner)
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)

BUILDER = '''import pathlib,sys
counter=pathlib.Path(sys.argv[1])
counter.write_text(str(int(counter.read_text())+1) if counter.exists() else '1')
out=pathlib.Path(sys.argv[sys.argv.index('--Mdir')+1])
binary=out/'Vtb_ds_pocket'
binary.write_text('#!/bin/sh\\nprintf model-ok\\n')
binary.chmod(0o755)
(out/'temporary.o').write_text('discard')
'''


class ModelCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        self.patch = mock.patch.multiple(run, CACHE=self.d / 'cache', CACHE_KEEP=1)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        run.CACHE.mkdir()
        self.counter = self.d / 'build-count'
        self.cmd = [sys.executable, '-c', BUILDER, str(self.counter)]

    def entry(self, key, stamp):
        d = run.CACHE / key
        d.mkdir()
        (d / '.ok').write_text('old cache format\n')
        (d / 'Vtb_ds_pocket').write_text('legacy model bytes')
        os.utime(d / '.ok', ns=(stamp, stamp))
        return d

    def test_reuse_and_parallel_readers(self):
        obj, first = run.cached_model(self.cmd, [], 'same')
        try:
            self.assertFalse((obj / 'temporary.o').exists())
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(run.cached_model, self.cmd, [], 'same')
                try:
                    other, second = future.result(timeout=3)
                    second.close()
                finally:
                    first.close()
            self.assertEqual(obj, other)
            self.assertEqual(self.counter.read_text(), '1')
        finally:
            first.close()

    def test_lease_protects_preparation_and_run(self):
        obj, lease = run.cached_model(self.cmd, [], 'active')
        try:
            os.utime(obj / '.ok', ns=(1, 1))
            self.entry('newer', 2)
            run.cache_evict()
            self.assertEqual(subprocess.check_output([obj / 'Vtb_ds_pocket']), b'model-ok')
        finally:
            lease.close()
        run.cache_evict()
        self.assertFalse(obj.exists())

    def test_concurrent_misses_build_once(self):
        results = []
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(run.cached_model, self.cmd, [], 'cold') for _ in range(2)]
            try:
                for future in futures:
                    results.append(future.result(timeout=3))
                self.assertEqual(results[0][0], results[1][0])
                self.assertEqual(self.counter.read_text(), '1')
            finally:
                for _, lease in results:
                    lease.close()

    def test_eviction_keeps_waiters_on_one_lock_inode(self):
        old = self.entry('old', 1)
        self.entry('new', 2)
        lock = run.CACHE / 'old.lock'
        with lock.open('a') as waiter:
            run.cache_evict()
            self.assertFalse(old.exists())
            fcntl.flock(waiter, fcntl.LOCK_EX)
            with lock.open('a') as newcomer:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(newcomer, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_marker_disappears_during_eviction_snapshot(self):
        old = self.entry('vanishing', 1)
        self.entry('new', 2)
        original = Path.stat
        vanished = False

        def stat(path, *args, **kwargs):
            nonlocal vanished
            if path == old / '.ok' and not vanished:
                vanished = True
                path.unlink()
            return original(path, *args, **kwargs)

        with mock.patch.object(Path, 'stat', stat):
            run.cache_evict()
        self.assertTrue(vanished)

    def test_missing_binary_is_rebuilt(self):
        old = self.entry('missing', 1)
        (old / 'Vtb_ds_pocket').unlink()
        obj, lease = run.cached_model(self.cmd, [], 'missing')
        try:
            self.assertEqual(subprocess.check_output([obj / 'Vtb_ds_pocket']), b'model-ok')
            self.assertEqual(self.counter.read_text(), '1')
        finally:
            lease.close()

    def test_old_ready_binary_is_unchanged(self):
        old = self.entry('compat', 1)
        before = hashlib.sha256((old / 'Vtb_ds_pocket').read_bytes()).digest()
        obj, lease = run.cached_model(self.cmd, [], 'compat')
        try:
            self.assertEqual(hashlib.sha256((obj / 'Vtb_ds_pocket').read_bytes()).digest(), before)
            self.assertFalse(self.counter.exists())
        finally:
            lease.close()

    def test_failed_build_releases_lock(self):
        with self.assertRaises(RuntimeError):
            run.cached_model([sys.executable, '-c', 'import sys; sys.exit(3)'], [], 'failed')
        self.assertFalse((run.CACHE / 'failed').exists())
        with (run.CACHE / 'failed.lock').open('a') as lk:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_success_without_binary_is_rejected(self):
        with self.assertRaises(RuntimeError):
            run.cached_model([sys.executable, '-c', 'pass'], [], 'empty')
        self.assertFalse((run.CACHE / 'empty').exists())


if __name__ == '__main__':
    unittest.main()
