#!/usr/bin/env python3
"""Classification/provenance checks; these do not execute a native model."""
import json
from pathlib import Path
import tempfile
import unittest
from load2d_run38_run import classify,verify
from load2d_run38 import sha
class Runner(unittest.TestCase):
    def test_native_difference_is_a_measurement(self):
        self.assertEqual(classify(1,{'fixture_reference_valid':True,'core_matches_DS':False}),'MEASURED_DIFFERENCE_DS')
        self.assertEqual(classify(1,{'fixture_reference_valid':True,'core_matches_DS':True}),'MEASURED_MATCH_DS')
    def test_bad_reference_or_process_failure_rejected(self):
        for rc,result in [(0,{'fixture_reference_valid':False}),(-15,{}),(2,{})]:
            with self.subTest(rc=rc),self.assertRaises(ValueError):classify(rc,result)
    def test_changed_input_and_worker_shape_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d);m={'build_jobs':1,'threads':1,'build_command':['tool','-j','1','--threads','1'],'run_environment':{'RUN38_OUT':str(r/'captures')}}
            for directory,key in [('source','source_sha256'),('golden','golden_sha256'),('ds','ds_sha256'),('census','census_sha256')]:
                (r/directory).mkdir();f=r/directory/'fixture';f.write_bytes(b'pinned');m[key]={'fixture':sha(f)}
            p=r/'preparer.py';p.write_bytes(b'pinned preparer');m['preparer_snapshot_sha256']=sha(p)
            verify(r,m)
            (r/'source/fixture').write_bytes(b'mutant')
            with self.assertRaisesRegex(ValueError,'input changed'):verify(r,m)
            (r/'source/fixture').write_bytes(b'pinned');m['build_command'][2]='2'
            with self.assertRaisesRegex(ValueError,'jobs1/threads1'):verify(r,m)
if __name__=='__main__':unittest.main()
