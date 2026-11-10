"""Run with python3 sim/pocket_ds/test_run_verdicts.py."""
import contextlib
import io
import unittest

from run import read_verdicts


class VerdictTests(unittest.TestCase):
    def check_log(self, log, expected, **requirements):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(read_verdicts(log.splitlines(True), **requirements), expected)

    def test_rom_pass(self):
        self.check_log('result: magic 52545344\nPASS\n', ('PASS', True))

    def test_rom_failure_is_sticky(self):
        self.check_log('FAIL\nPASS\n', ('FAIL', True))

    def test_touch_failure_before_rom_pass(self):
        # Reproduces the unsupported onescreen + touchtest run's verdict order.
        self.check_log('TOUCH FAIL\nPASS\n', ('PASS', False), require_touch=True)

    def test_touch_failure_cannot_be_erased(self):
        self.check_log('TOUCH FAIL\nTOUCH PASS\nPASS\n', ('PASS', False))

    def test_requested_touch_must_complete(self):
        self.check_log('PASS\n', ('PASS', False), require_touch=True)

    def test_both_requested_checks_pass(self):
        self.check_log('TOUCH PASS\nPASS\nvmcheck: 1408 words read, 0 mismatches\n',
                       ('PASS', True), require_touch=True, require_vmcheck=True)

    def test_vram_failure_after_rom_pass(self):
        self.check_log('PASS\nvmcheck: 1408 words read, 1 mismatches\n',
                       ('PASS', False), require_vmcheck=True)

    def test_vram_failure_cannot_be_erased(self):
        self.check_log('PASS\nvmcheck: 4 words read, 1 mismatches\n'
                       'vmcheck: 4 words read, 0 mismatches\n', ('PASS', False))

    def test_requested_vram_must_report(self):
        self.check_log('PASS\n', ('PASS', False), require_vmcheck=True)

    def test_diagnostic_text_is_not_a_rom_verdict(self):
        self.check_log('TOUCH PASS\nnot PASS\n', (None, True))

    def test_protocol_error_before_rom_pass(self):
        self.check_log("nds_sdram_bport: ERROR: the client's request changed before c_ready\nPASS\n",
                       ('PASS', False))

    def test_protocol_error_after_rom_pass(self):
        self.check_log('PASS\nnds_sdram_bus: ERROR: the grant bank/row differs\n',
                       ('PASS', False))

    def test_protocol_error_cannot_be_erased_by_clean_monitors(self):
        self.check_log('nds_sdram_bport: ERROR: changed request\nTOUCH PASS\nPASS\n'
                       'vmcheck: 1408 words read, 0 mismatches\n',
                       ('PASS', False), require_touch=True, require_vmcheck=True)

    def test_simulator_errors_are_sticky(self):
        for error in ('[10] %Error: stopped', 'Assertion failed: request', 'ERROR video: short line'):
            with self.subTest(error=error):
                self.check_log(error + '\nPASS\n', ('PASS', False))

    def test_clean_model_summary_is_not_an_error(self):
        self.check_log('models: sdram errors 0, cram errors 0/0\nPASS\n', ('PASS', True))


if __name__ == '__main__':
    unittest.main()
