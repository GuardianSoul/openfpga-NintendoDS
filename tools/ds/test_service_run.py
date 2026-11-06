#!/usr/bin/env python3
"""Acceptance tests for incomplete, mistargeted or vacuous service captures."""
import unittest
import json
from pathlib import Path
import tempfile
from service_run import metrics,baseline_proof,sha

CASE={'command':['model','+service_wifi=1','+service_aux=1','+service_memlat=20']}
GOOD='''DIFFER: 300000 clocks, 32 bytes, 14 differing
SERVICE_REPLY bytes=32 mismatches=0 irq_old=8 irq_new=8 clock_differences=14
SERVICE_PASS
SERVICE wifi=1 aux=1 memlat=20 wifi_transactions=50 aux_transactions=60 timer_due=5 timer_steps=4 spi_events=32 spi_age_max=300 engine_hold_ticks=20 firmware_hold_ticks=0 wifi_latency_max=100 aux_latency_max=120 wifi_spi_overlap=4 aux_spi_overlap=5 spi_fast_events=16 spi_fast_age_max=90 fast_engine_hold_ticks=0
- Verilator: cpu 1s
'''
class ServiceAcceptance(unittest.TestCase):
    def test_clock_differences_are_reported_separately(self):
        self.assertEqual(metrics(GOOD,CASE)['reply']['clock_differences'],14)
    def test_rejects_native_failure_or_incompletion(self):
        for text in [GOOD.replace('Verilator: cpu','unfinished:'),GOOD+'%Error failed\n',
                     GOOD.replace('SERVICE_PASS\n',''),GOOD+'SERVICE_PASS\n',GOOD+'SERVICE_FAIL watchdog\n']:
            with self.subTest(text=text),self.assertRaises(ValueError):metrics(text,CASE)
    def test_rejects_missing_overlap_or_bad_values(self):
        for text in [GOOD.replace('mismatches=0','mismatches=1'),GOOD.replace('irq_new=8','irq_new=7'),
                     GOOD.replace('bytes=32','bytes=1'),GOOD.replace('spi_events=32','spi_events=0'),
                     GOOD.replace('timer_steps=4','timer_steps=2'),GOOD.replace('wifi_transactions=50','wifi_transactions=1'),
                     GOOD.replace('aux_transactions=60','aux_transactions=0'),GOOD.replace('memlat=20','memlat=1'),
                     GOOD.replace('engine_hold_ticks=20',''),GOOD.replace('irq_old=8 irq_new=8','irq_old=0 irq_new=0'),
                     GOOD.replace('wifi_spi_overlap=4','wifi_spi_overlap=0'),GOOD.replace('aux_spi_overlap=5','aux_spi_overlap=0'),GOOD.replace('spi_fast_events=16','spi_fast_events=0')]:
            with self.subTest(text=text),self.assertRaises(ValueError):metrics(text,CASE)

class PositiveControl(unittest.TestCase):
    def test_mutant_needs_matching_unchanged_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);case=dict(CASE,name='both-s1');out=root/'both-s1';out.mkdir()
            (root/'source').mkdir();(root/'source/core').write_text('pinned')
            wrapper='sim/ds_dev/service_eq/nds_spi_service_sys.sv';w=root/'source'/wrapper;w.parent.mkdir(parents=True);w.write_text('original')
            base={'source_sha':'pin','mutant':None,'source_sha256':{'core':sha(root/'source/core'),wrapper:sha(w)}}
            (root/'plan.json').write_text(json.dumps(base));(out/'run.log').write_text(GOOD)
            proof={'exit':0,'case':case,'plan_sha256':sha(root/'plan.json'),'log_sha256':sha(out/'run.log')}
            pp=out/'manifest.json';pp.write_text(json.dumps(proof))
            mutant=dict(base,mutant='drop-spi-done',source_sha256=dict(base['source_sha256'],**{wrapper:'changed'}))
            self.assertEqual(baseline_proof(pp,mutant,['both-s1'])['case'],'both-s1')
            with self.assertRaises(ValueError):baseline_proof(pp,mutant,['other-case'])
            (out/'run.log').write_text(GOOD+'modified')
            with self.assertRaises(ValueError):baseline_proof(pp,mutant,['both-s1'])

if __name__=='__main__':unittest.main()
