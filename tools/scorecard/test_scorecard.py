#!/usr/bin/env python3
"""Small evidence-gate regression; no RTL simulation or hardware access."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('scorecard', ROOT / 'scorecard.py')
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)


class EvidenceGate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        for rom, rows in sc.ROWS.items():
            vals = [ds if what else (1 if name == 'DONE' else 0)
                    for name, what, ds, *_ in rows]
            text = ''.join(f'value {i} {v}\n' for i, v in enumerate(vals))
            text += f'result: magic 52545344 checks {len(rows)} mask {(1 << len(rows))-1:08x} done 1\n'
            (self.d / f'{rom}.log').write_text(text)
        self.gx = self.d / 'gx.txt'
        self.gx.write_text(''.join(f'{n} {ds / 50:.2f} clk per body (100/300 bodies)\n'
                                  for n, what, ds, *_ in sc.ROWS['unitgx'] if what))

    def run_gate(self, *extra):
        return subprocess.run([sys.executable, str(ROOT / 'scorecard.py'), '--strict',
                               '--gx', f'combined={self.gx}', *extra, f'combined={self.d}'],
                              text=True, capture_output=True)

    def corrupt(self, rom, old, new):
        p = self.d / f'{rom}.log'
        p.write_text(p.read_text().replace(old, new))
        self.assertNotEqual(self.run_gate().returncode, 0)

    def test_complete(self):
        p = self.run_gate()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('1.00', p.stdout)
        self.assertIn('WiFi and SPI/AUX timing are not covered', p.stdout)

    def test_unfinished(self):
        self.corrupt('unitmem', 'done 1', 'done 0')

    def test_missing_row(self):
        self.corrupt('unitcpu', 'value 0 106\n', '')

    def test_bad_mask(self):
        self.corrupt('unitmem', 'mask ffffffff', 'mask fffffffe')

    def test_timeout(self):
        self.corrupt('unitgx', 'value 12 0', 'value 12 1')

    def test_zero_timing(self):
        self.corrupt('unitcpu', 'value 0 106', 'value 0 0')

    def test_missing_rom(self):
        (self.d / 'unita7.log').unlink()
        self.assertNotEqual(self.run_gate().returncode, 0)

    def test_separate_engines(self):
        other = self.d / 'other-gx.txt'
        other.write_text(self.gx.read_text().replace('129.50', '259.00'))
        p = self.run_gate('--gx', f'other={other}', f'other={self.d}')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('| 64.75 | 129.50 | 2.00 | 64.75 | 1.00 |', p.stdout)

    def test_cpu_visible_mult44_is_not_hidden_by_engine(self):
        def timing_row(output, prefix):
            return next(line for line in output.splitlines() if line.startswith(prefix))
        engine_prefix = '| unitgx | GX engine: MTX_MULT_4x4'
        visible_prefix = '| unitgx CPU-visible | GX CPU-visible: MTX_MULT_4x4'
        baseline = self.run_gate()
        self.assertEqual(baseline.returncode, 0, baseline.stderr)
        self.assertIn('| 64.75 | 64.75 | 1.00 |', timing_row(baseline.stdout, visible_prefix))
        engine_bytes = self.gx.read_bytes()
        p = self.d / 'unitgx.log'
        p.write_text(p.read_text().replace('value 0 6475\n', 'value 0 1600\n'))
        mutant = self.run_gate()
        self.assertEqual(mutant.returncode, 0, mutant.stderr)
        self.assertIn('| 64.75 | 16.00 | 0.25 |', timing_row(mutant.stdout, visible_prefix))
        self.assertEqual(timing_row(baseline.stdout, engine_prefix), timing_row(mutant.stdout, engine_prefix))
        self.assertEqual(engine_bytes, self.gx.read_bytes())
        self.assertIn(str(self.d / 'unitgx.log'), mutant.stdout)
        self.assertIn('system cycles per body', mutant.stdout)

    def test_shared_engine_rejected(self):
        p = self.run_gate('--gx', str(self.gx))
        self.assertNotEqual(p.returncode, 0)

    def test_missing_engine_row(self):
        self.gx.write_text(self.gx.read_text().replace('MULT44M2', 'WRONG'))
        self.assertNotEqual(self.run_gate().returncode, 0)


if __name__ == '__main__':
    unittest.main()
