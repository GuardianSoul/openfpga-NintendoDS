#!/usr/bin/env python3
import array
from pathlib import Path
import tempfile
import json
import unittest
from load2d_run38 import pixels, compare

class Raw555(unittest.TestCase):
    def test_all_sixteen_bits_are_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'a.bin';a=array.array('H',[0x803f]*49152);p.write_bytes(a.tobytes());before=pixels(p)
            a[0]^=0x8000;a[1]^=1;p.write_bytes(a.tobytes());after=pixels(p)
            self.assertEqual(sum(x!=y for x,y in zip(before,after)),2)
    def test_short_capture_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'short.bin';p.write_bytes(b'\0\0')
            with self.assertRaises(ValueError):pixels(p)
class Reporter(unittest.TestCase):
    def setup_case(self,root):
        for d in ['ds','census','captures','obj']:(root/d).mkdir()
        (root/'obj/Vgpu2d').write_bytes(b'unit-test-only model marker')
        ds=array.array('H',[0x8000]*49152).tobytes()
        ref=array.array('H',[0x803f]*49152).tobytes()
        for l in range(3):
            for b in range(2):
                (root/'captures'/f'run38-load{l}-b{b}-rtl.bin').write_bytes(ds)
                (root/'captures'/f'run38-load{l}-b{b}-gold.bin').write_bytes(ref)
                for stress in range(2):
                    for rep in range(2):
                        n=f'load2d_{l}_{b}_{stress}_f{rep}.bin'
                        (root/'ds'/n).write_bytes(ds);(root/'census'/n).write_bytes(ref)
        (root/'plan.json').write_text(json.dumps({'core_source_sha':'test','scope':'synthetic parser test',
            'source_sha256':{},'golden_sha256':{},'ds_sha256':{},'census_sha256':{}}))
        log=root/'native.log';log.write_text('FAIL: 0/6 runs pixel-exact, 1152 lines,\n'+
            ''.join(f'RUN38_CAPTURE name=run38-load{l}-b{b} rtl_unique=49152 gold_unique=49152\n' for l in range(3) for b in range(2)))
        return log
    def test_DS_match_can_differ_from_Census(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d);log=self.setup_case(r);m=compare(r,log)
            self.assertTrue(m['fixture_reference_valid']);self.assertTrue(m['core_matches_DS'])
            self.assertEqual(m['comparisons'][0]['core_vs_Census19_pixels'],49152)
    def test_fixture_parity_and_write_coverage_required(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d);log=self.setup_case(r)
            p=r/'captures/run38-load0-b0-gold.bin';a=bytearray(p.read_bytes());a[1]^=0x80;p.write_bytes(a)
            m=compare(r,log);self.assertFalse(m['fixture_reference_valid']);self.assertFalse(m['core_matches_DS'])
            log.write_text(log.read_text().replace('rtl_unique=49152','rtl_unique=49151'))
            with self.assertRaises(ValueError):compare(r,log)
if __name__=='__main__':unittest.main()
