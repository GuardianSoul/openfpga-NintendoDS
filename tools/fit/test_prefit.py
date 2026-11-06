#!/usr/bin/env python3
"""Regression controls for source pitfalls and fit publication gates."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PreFitChecks(unittest.TestCase):
    def run_check(self, script, name, text):
        with tempfile.TemporaryDirectory(prefix='nds-prefit-') as directory:
            path = Path(directory) / name
            path.write_text(text)
            return subprocess.run(['python3', str(ROOT / script), str(path)],
                                  text=True, capture_output=True)

    def test_generate_repairs_and_actual_failure_shapes(self):
        fixed = '''module fixture;
          genvar l,k;
          generate for (l=0;l<4;l++) begin : g_light
            for(k=0;k<3;k++) begin : g_component
              wire sample = 1'b0;
            end
          end endgenerate
          always_comb for(int l=0;l<4;l++) begin
            // Procedural int loop remains legal.
          end
        endmodule
        '''
        self.assertEqual(self.run_check('tools/ds/qlint.py', 'good.sv', fixed).returncode, 0)
        # Actual1162 shape: nested genvar loops with no named begin/end.
        unnamed = '''module fixture; genvar l,k;
          generate for (l=0;l<4;l++) for(k=0;k<3;k++)
            wire sample = 1'b0;
          endgenerate endmodule'''
        result = self.run_check('tools/ds/qlint.py', 'unnamed.sv', unnamed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('named begin/end', result.stdout)
        # Actual1163 shape, also wrapped to defeat an indentation-only check.
        for bare in (fixed.replace('generate ', '').replace(' endgenerate', ''),
                     fixed.replace('generate ', '').replace(' endgenerate', '').replace(
                         'for (l=0;l<4;l++)', 'for (\n l=0;\n l<4; l++\n)')):
            result = self.run_check('tools/ds/qlint.py', 'bare.sv', bare)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('outside generate/endgenerate', result.stdout)

    def test_mapped_physical_dsp_demand(self):
        for count, accepted in ((63, True), (66, True), (67, False), (77, False)):
            result = self.run_check('tools/fit/dspcheck.py', 'map.rpt',
                                    f'; Total DSP Blocks ; {count} ;\n')
            self.assertEqual(result.returncode == 0, accepted, result.stdout)
        for malformed in ('', '; Total DSP Blocks ; 66 / 66 (100%) ;\n',
                          '; Total DSP Blocks ; 63 ;\n; Total DSP Blocks ; 77 ;\n'):
            result = self.run_check('tools/fit/dspcheck.py', 'bad.rpt', malformed)
            self.assertNotEqual(result.returncode, 0)

    def test_area_snapshot_never_assembles_failed_dsp_capacity(self):
        # Execute the actual build chain with shell mocks, never Quartus.
        source = (ROOT / 'scripts/build_ds.sh').read_text()
        chain = source.split('set +e\n', 1)[1].split('\nrc=$?;', 1)[0]
        self.assertIn('MAX_BALANCING_DSP_BLOCKS 66', source)

        def run_chain(text, map_rc=0, dsp_rc=0, fit_rc=0):
            mocks = f'''
              calls=()
              quartus_map() {{ calls+=(map); return {map_rc}; }}
              python3() {{ calls+=(dsp); return {dsp_rc}; }}
              quartus_fit() {{ calls+=(fit); return {fit_rc}; }}
              quartus_asm() {{ calls+=(asm); return 0; }}
              quartus_sta() {{ calls+=(sta); return 0; }}
            '''
            with tempfile.TemporaryDirectory(prefix='nds-fit-chain-') as directory:
                result = subprocess.run(['bash', '-c', mocks + '\n' + text +
                                         '\nresult=$?; printf "%s %s\\n" "$result" "${calls[*]}"'],
                                        cwd=directory, text=True, capture_output=True, check=True)
            return result.stdout.strip()

        self.assertEqual(run_chain(chain), '0 map dsp fit asm sta')
        self.assertEqual(run_chain(chain, map_rc=2), '2 map')
        self.assertEqual(run_chain(chain, fit_rc=1), '1 map dsp fit')
        for failure in (1, 2):
            self.assertEqual(run_chain(chain, dsp_rc=failure), '1 map dsp fit')
        # An actual source mutation removing the guard must expose assembly.
        fault = chain.replace('test "$dsp_rc" -eq 0', 'true')
        self.assertNotEqual(fault, chain)
        self.assertEqual(run_chain(fault, dsp_rc=1), '0 map dsp fit asm sta')


if __name__ == '__main__':
    unittest.main()
