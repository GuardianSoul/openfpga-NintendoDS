"""Synthetic decoder tests; raw hardware findings are never normalized away."""
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest

import analyze_speed_return as audit
import check_speed_probes as basic


class ReturnAnalysis(unittest.TestCase):
    def wifi_rows(self):
        rows = [dict(command=3, stress=0, status=0, kind=0, arg=0, rep=0,
                     arm7_ticks=23, before=0, after=0, timeout=0)]
        for rep in range(32):
            for arg in (0, 248, 344):
                before, after = (0, 0) if rep < 2 else (rep * 100, rep * 100 + 99)
                if arg != 248:
                    before = after = 0xc340 if arg == 0 else 255
                rows.append(dict(command=3, stress=0, status=0, kind=3, arg=arg, rep=rep,
                                 arm7_ticks=100, before=before, after=after, timeout=0))
        return rows

    def test_zero_startup_intervals_are_retained_as_behavior(self):
        rows = self.wifi_rows()
        saved = deepcopy(rows)
        result = audit.wifi(rows)
        self.assertTrue(result['output_complete'])
        self.assertEqual(result['zero_delta_reps'], [0, 1])
        self.assertEqual(result['first_advancing_rep'], 2)
        self.assertEqual(result['counter'][0]['delta'], 0)
        self.assertTrue(result['counter_progress_monitor_passed'])
        self.assertFalse(result['power_enable_readback_captured'])
        self.assertEqual(rows, saved)

    def test_flat_counter_is_reported_without_inventing_progress(self):
        rows = self.wifi_rows()
        for row in rows:
            if row['arg'] == 248:
                row['after'] = row['before']
        result = audit.wifi(rows)
        self.assertEqual(result['zero_delta_reps'], list(range(32)))
        self.assertIsNone(result['first_advancing_rep'])
        self.assertFalse(result['counter_progress_monitor_passed'])

    def test_stall_after_first_progress_fails_counter_monitor(self):
        rows = self.wifi_rows()
        row = next(r for r in rows if r['arg'] == 248 and r['rep'] == 10)
        row['after'] = row['before']
        self.assertFalse(audit.wifi(rows)['counter_progress_monitor_passed'])

    def test_missing_duplicate_or_wrong_input_wifi_rows_rejected(self):
        for action in ('missing', 'duplicate', 'wrongarg', 'timeout'):
            with self.subTest(action=action):
                rows = self.wifi_rows()
                if action == 'missing':
                    rows.pop()
                elif action == 'duplicate':
                    rows[6] = rows[3].copy()
                elif action == 'wrongarg':
                    rows[5]['arg'] = 247
                else:
                    rows[4]['timeout'] = 1
                with self.assertRaises(ValueError):
                    audit.wifi(rows)

    def test_strict_counter_failure_still_exists(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            import csv
            rows = self.wifi_rows()
            with (directory / 'perftime_3_0.csv').open('w', newline='') as stream:
                writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
                writer.writeheader()
                writer.writerows(rows)
            with self.assertRaisesRegex(ValueError, 'counter not advancing'):
                basic.check_peripheral_case('perftime2', directory, 3, 0)

    def test_changed_raw_data_and_extra_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            path = directory / 'capture.csv'
            path.write_text('original data\n')
            files = {path.name: audit.sha(path)}
            audit.verify_files(directory, files)
            path.write_text('modified data\n')
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                audit.verify_files(directory, files)
            files[path.name] = audit.sha(path)
            (directory / 'extra.txt').write_text('extra')
            with self.assertRaisesRegex(ValueError, 'inventory'):
                audit.verify_files(directory, files)

    def test_tampered_capture_binary_is_detected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            path = directory / 'perftime_7684_0_cap0.bin'
            path.write_bytes(bytes(2048))
            files = {path.name: audit.sha(path)}
            changed = bytearray(path.read_bytes())
            changed[1000] = 1
            path.write_bytes(changed)
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                audit.verify_files(directory, files)

    def test_wram_kernel_slope_keeps_correct_denominator_and_repeat_pairing(self):
        rows = []
        for store in range(2):
            for state in range(3):
                for size, operations in enumerate((256, 1024)):
                    for rep in range(4):
                        rows.append(dict(command=1 | ((store | (size << 1) | (state << 2)) << 8),
                                         rep=rep, operations=operations, arm7_ticks=100 + operations * (4 + store + state)))
        result = audit.wram(rows)
        self.assertEqual(result[0]['sys_per_access'], [4.0] * 4)
        self.assertEqual(result[1]['sys_per_access'], [5.0] * 4)
        self.assertEqual(result[1]['relative_to_off'], [1.25] * 4)
        rows[0]['operations'] = 255
        with self.assertRaisesRegex(ValueError, 'denominator'):
            audit.wram(rows)


if __name__ == '__main__':
    unittest.main()
