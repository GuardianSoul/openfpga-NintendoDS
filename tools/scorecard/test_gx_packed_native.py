import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

from gx_packed_native import check_log, hex_image, run, sha
import test_gx_packed


class NativeAcceptance(unittest.TestCase):
    def log(self):
        # Synthetic fixture only: validates the acceptance logic without
        # presenting an invented native run or DS timing measurement.
        return '\n'.join([
            'clean-boot: DS main RAM and VRAM zeroed; boot clear skipped',
            'DS_CACHE_ROUTE_OK: ways4 D4KiB I8KiB opt58713059 sound/wifi/3D on',
            *test_gx_packed.PackedProtocol().bus_lines(),
            'result: magic 52545344 checks 2 mask 00000003 done 1',
            'value 0 18', 'value 1 0',
            'video: 10 frames, 0 errors; DS frames 0, retired 9:0 7:0; underruns 0',
            'models: sdram errors 0, cram errors 0/0; cart words 12345, 0 on clk_bus edges',
            'PASS', '- tb_canonical.sv:1020: Verilog $finish',
            'vmcheck: 54321 words read, 0 CPU reads from the block buffer, 0 mismatches'])

    def test_valid_complete_fixture(self):
        result = check_log(self.log(), 0)
        self.assertEqual((len(result['rows']), result['checks'], result['failures']), (18, 2, 0))
        self.assertIn('pending', result['ds_timing_status'])

    def test_selected921_banner_rejects_historical_route(self):
        from gx_packed_current import select_revision
        import gx_packed_current as current
        # Restore module globals after the explicit configuration check.
        import importlib
        try:
            select_revision('921')
            self.assertEqual(current.PROFILE['A9_OPT'], 461366243)
            with self.assertRaisesRegex(ValueError, 'cache/feature route'):
                check_log(self.log(), 0, cache_banner=current.CACHE_BANNER)
            log = self.log().replace('DS_CACHE_ROUTE_OK: ways4 D4KiB I8KiB opt58713059 sound/wifi/3D on',
                                     current.CACHE_BANNER)
            self.assertEqual(len(check_log(log, 0, cache_banner=current.CACHE_BANNER)['rows']), 18)
        finally:
            importlib.reload(current)

    def test_native_completion_and_outcome_guards(self):
        changes = [
            ('PASS', 'FAIL'), ('PASS\n', ''), ('Verilog $finish', 'interrupted'),
            ('clean-boot:', 'boot:'), ('DS_CACHE_ROUTE_OK:', 'NO_ROUTE:'),
            ('checks 2', 'checks 24'), ('mask 00000003', 'mask 00000001'), ('done 1', 'done 0'),
            ('value 0 18', 'value 0 24'), ('value 1 0', 'value 1 1'),
            ('10 frames, 0 errors', '10 frames, 1 errors'), ('underruns 0', 'underruns 1'),
            ('sdram errors 0', 'sdram errors 1'), ('cram errors 0/0', 'cram errors 0/1'),
            ('cart words 12345', 'cart words 0'), ('0 on clk_bus edges', '1 on clk_bus edges'),
            ('54321 words read', '0 words read'), ('0 mismatches', '1 mismatches')]
        for before, after in changes:
            with self.subTest(before=before):
                with self.assertRaises(ValueError):
                    check_log(self.log().replace(before, after), 0)
        for suffix in ('\nTIMEOUT', '\nERROR: corrupt', '\nAssertion failed', '\nPASS'):
            with self.subTest(suffix=suffix):
                with self.assertRaises(ValueError):
                    check_log(self.log() + suffix, 0)
        with self.assertRaisesRegex(ValueError, 'exit'):
            check_log(self.log(), 1)

    def test_missing_write_mutant_caught_by_native_acceptance(self):
        line = 'WW port 3f0108 <= 00000000 be f\n'
        self.assertIn(line, self.log())
        with self.assertRaisesRegex(ValueError, 'incomplete packet'):
            check_log(self.log().replace(line, '', 1), 0)

    def test_bad_data_mutant_caught_by_native_acceptance(self):
        before = 'WW port 3f0138 <= 5157b893 be f'
        self.assertIn(before, self.log())
        with self.assertRaisesRegex(ValueError, 'input'):
            check_log(self.log().replace(before, before.replace('5157b893', '5157b892')), 0)

    def test_expanded_hex_matches_little_endian_and_padding(self):
        self.assertEqual(hex_image(bytes.fromhex('12345678ab')), '78563412\n000000ab\n')

    def test_launcher_refuses_changed_inputs_before_any_process(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            image = out / 'rom.hex'
            image.write_text('01234567\n')
            plan = dict(host=socket.gethostname(), frozen_files={'rom.hex': sha(image)})
            (out / 'plan.json').write_text(json.dumps(plan))
            image.write_text('01234566\n')
            with patch('gx_packed_native.subprocess.Popen') as start:
                with self.assertRaisesRegex(ValueError, 'prepared file changed'):
                    run(out, 'synthetic test allocation; must never launch')
                with self.assertRaisesRegex(ValueError, 'allocation'):
                    run(out, '')
                start.assert_not_called()


if __name__ == '__main__':
    unittest.main()
