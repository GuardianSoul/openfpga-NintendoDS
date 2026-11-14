#!/usr/bin/env python3
"""Regression coverage for Quartus Standard's observed #2192 rejection."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

LINT = pathlib.Path(__file__).with_name('qlint.py')


class HeaderImports(unittest.TestCase):
    def check_source(self, source, bad_line=None):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / 'case.sv'
            p.write_text(source)
            r = subprocess.run([sys.executable, str(LINT), str(p)], text=True, capture_output=True)
        self.assertEqual(r.returncode, int(bad_line is not None), r.stdout + r.stderr)
        if bad_line is not None:
            self.assertIn(f':{bad_line}: second module-header import', r.stdout)

    def test_observed_header(self):
        self.check_source('module m import a::*; import b::*; #(parameter N=1)(); endmodule', 1)

    def test_multiline_comments(self):
        self.check_source('module m import a::*;\n/* gap */\n import b::*;\n(); endmodule', 3)

    def test_single_header(self):
        self.check_source('module m import a::*; #(parameter N=1)(); endmodule')

    def test_header_and_body(self):
        self.check_source('module m import a::*; ();\n import b::*; import c::*;\nendmodule')

    def test_body_only(self):
        self.check_source('module m(); import a::*; import b::*; endmodule')

    def test_one_combined_declaration(self):
        self.check_source('module m import a::*, b::*; (); endmodule')

    def test_noncode(self):
        self.check_source('// module fake import a::*; import b::*;\nmodule m();\n string s="module fake import a::*; import b::*;"; endmodule')

    def test_separate_modules(self):
        self.check_source('module m import a::*; (); endmodule\nmodule n import b::*; (); endmodule')


if __name__ == '__main__':
    unittest.main()
