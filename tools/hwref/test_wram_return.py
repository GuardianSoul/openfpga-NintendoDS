"""Synthetic WRAM return triage; no DS measurements or native jobs."""
import csv
from pathlib import Path
import tempfile
import unittest

import check_speed_trip as trip


class WramReturn(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.d = Path(self.temp.name)

    def complete(self):
        rows = []
        for key in trip.wram_keys():
            command, rep, delay = [int(part[1:]) for part in key.split('_')]
            sound = command & 255 == 1
            rows.append(dict(command=command, rep=rep, delay=delay, error=0, cap_timeout=0,
                             arm7_ticks=100, private_addr=0x038029a0,
                             operations=(1024 if (command >> 8) & 2 else 256) if sound else 1024,
                             switched=0 if sound else 1, arm9_loss_ticks=100, arm9_return_ticks=164))
            if sound:
                (self.d / f'wramarb_{command}_r{rep}.bin').write_bytes(bytes(2048))
        with (self.d / 'wramarb.csv').open('w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        (self.d / 'wramarb_progress.txt').write_text(''.join(
            f'{verb} {key}\n' for key in trip.wram_keys() for verb in ('start', 'done')))
        (self.d / 'wramarb_info.txt').write_text('wramarb 1; synthetic fixture only\n')
        (self.d / 'wramarb_active.txt').write_text('complete\n')

    def test_complete_output_only(self):
        self.complete()
        result = trip.wram_status(self.d)
        self.assertTrue(result['complete_output'])
        self.assertEqual(result['complete_counts'], dict(rows=104, sound=48, handover=56))
        self.assertEqual(result['progress']['done'], 104)
        self.assertIn('unqualified', result['ds_timing_status'])

    def test_no_files_is_not_completion_or_a_hang_diagnosis(self):
        result = trip.wram_status(self.d)
        self.assertFalse(result['complete_output'])
        self.assertEqual(result['files'], {})
        self.assertIn('not proof of a hang', result['interpretation'])

    def test_complete_active_marker_does_not_hide_interrupted_case(self):
        self.complete()
        p = self.d / 'wramarb_progress.txt'
        p.write_text(p.read_text().replace('done c1_r0_d0\n', ''))
        result = trip.wram_status(self.d)
        self.assertEqual(result['active'], 'complete\n')
        self.assertEqual(result['csv_rows'], 104)
        self.assertEqual(result['progress']['started_without_done'], ['c1_r0_d0'])
        self.assertFalse(result['complete_output'])

    def test_duplicate_done_and_wrong_order_are_rejected(self):
        self.complete()
        p = self.d / 'wramarb_progress.txt'
        text = p.read_text()
        for bad in (text + 'done c1_r0_d0\n', text.replace('start c1_r0_d0\ndone c1_r0_d0',
                                                            'done c1_r0_d0\nstart c1_r0_d0')):
            with self.subTest(bad=bad[:40]):
                p.write_text(bad)
                self.assertFalse(trip.wram_status(self.d)['complete_output'])

    def test_partial_journal_line_is_preserved(self):
        (self.d / 'wramarb_progress.txt').write_text('start c1_r0_d0\ndone c1_r')
        result = trip.wram_status(self.d)
        self.assertEqual(result['progress']['malformed'], [dict(line=2, text='done c1_r')])
        self.assertEqual(result['progress']['started_without_done'], ['c1_r0_d0'])

    def test_missing_journal_or_info_or_capture_stays_incomplete(self):
        for filename in ('wramarb_progress.txt', 'wramarb_info.txt', 'wramarb_1_r0.bin'):
            with self.subTest(filename=filename):
                self.complete()
                (self.d / filename).unlink()
                self.assertFalse(trip.wram_status(self.d)['complete_output'])

    def test_inspection_does_not_modify_returned_files(self):
        self.complete()
        before = {p.name: p.read_bytes() for p in self.d.iterdir()}
        trip.wram_status(self.d)
        self.assertEqual({p.name: p.read_bytes() for p in self.d.iterdir()}, before)


if __name__ == '__main__':
    unittest.main()
