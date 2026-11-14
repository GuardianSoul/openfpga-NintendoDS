#!/usr/bin/env python3
"""tools/fit/timing_summary.py and tools/ds/prequeue.py's ramstyle-array scan on fixtures."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

RECEIPT = """\
SETUP slow_1100mv_85c clkA wns -0.300 tns -1.500 failing 3
WORST SETUP slow_1100mv_85c clkA slack -0.300 req 14.920 launch clkA latch clkA from a|q to core_top:ic|nds_top:ds|nds_fabric:u_fab|st
CONE SETUP slow_1100mv_85c clkA nds_fabric tns -1.200 failing 2
CONE SETUP slow_1100mv_85c clkA nds_vram tns -0.300 failing 1
SETUP slow_1100mv_0c clkA wns -0.100 tns -0.100 failing 1
SETUP slow_1100mv_85c clkB wns 1.000 tns 0.000 failing 0
HOLD fast_1100mv_0c clkA wns 0.050 tns 0.000 failing 0
"""


class TimingReceipt(unittest.TestCase):
    def test_summary_picks_worst_corner_and_cones(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'timing_receipt.txt'
            p.write_text(RECEIPT)
            out = subprocess.run(['python3', str(ROOT / 'tools/fit/timing_summary.py'), str(p)],
                                 text=True, capture_output=True, check=True).stdout
        self.assertIn('TIMING SETUP clkA [slow_1100mv_85c]: wns -0.300 tns -1.500 failing 3; worst clkA -> clkA req 14.920', out)
        self.assertIn('TCONE SETUP clkA nds_fabric: tns -1.200 failing 2', out)
        self.assertLess(out.index('nds_fabric'), out.index('nds_vram'))
        self.assertIn('TIMING SETUP clkB: wns 1.0 tns 0 failing 0 (all corners)', out)
        self.assertIn('TIMING HOLD clkA: wns 0.05 tns 0 failing 0 (all corners)', out)

    def test_ramstyle_arrays(self):
        spec = importlib.util.spec_from_file_location('pq', ROOT / 'tools/ds/prequeue.py')
        pq = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(pq)
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'a.sv').write_text('module m1 (input clk);\n'
                                          '  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] rb [VR_PF ? 16 : 8];\n'
                                          '  logic [7:0] plain [4];\nendmodule\n'
                                          'module m2;\n  (* ramstyle = "M10K" *)\n  reg [15:0] mem [0:255];\nendmodule\n')
            self.assertEqual(pq.ram_arrays(Path(d)), {('m1', 'rb'), ('m2', 'mem')})

    def test_prequeue_stop_block_matches_build_ds(self):
        spec = importlib.util.spec_from_file_location('pq', ROOT / 'tools/ds/prequeue.py')
        pq = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(pq)
        self.assertIn(pq.PQ_BLOCK, (ROOT / 'scripts/build_ds.sh').read_text())
        self.assertIn('exit $rc', pq.PQ_BLOCK)


if __name__ == '__main__':
    unittest.main()
