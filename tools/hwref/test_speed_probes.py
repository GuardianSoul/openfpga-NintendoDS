#!/usr/bin/env python3
"""Acceptance gate tests with synthetic files, never hardware measurements."""
import csv
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('checks',Path(__file__).with_name('check_speed_probes.py'))
checks=importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class CaptureGate(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d=Path(self.tmp.name)

    def write(self,path,rows):
        with path.open('w',newline='') as f:
            w=csv.DictWriter(f,fieldnames=list(rows[0]))
            w.writeheader(); w.writerows(rows)

    def peripheral(self,aux=False,version2=False):
        commands=[(2,0)] if aux else [(1,0),(3,0)]+[
            (4|((fmt|((load&1)<<2)|((load&2)<<2))<<8),stress)
            for fmt in range(3) for load in range(4) for stress in range(2)]
        if version2:
            (self.d/'perftime_info.txt').write_text('perftime 2; synthetic test only\n')
            commands += [(4|((2|4|16|(fast<<3))<<8),stress)
                         for fast in range(2) for stress in range(2)]
        for command,stress in commands:
            rows=[]
            def add(kind,arg,rep,before=0,after=1):
                rows.append(dict(command=command,stress=stress,status=0,kind=kind,arg=arg,
                                 rep=rep,arm7_ticks=100,before=before,after=after,timeout=0))
            add(0,0,0)
            cmd=command&255
            if cmd in (1,2):
                for baud in range(4):
                    for rep in range(16):
                        for byte in range(2): add(cmd,baud|(byte<<8),rep)
            elif cmd==3:
                for rep in range(32):
                    for arg in (0,0xf8,0x158): add(3,arg,rep)
            else:
                if version2:
                    arg=command>>8; channels=16 if arg&4 else 4
                    for c in range(channels):
                        begin=1000+c*200
                        add(5,arg,c,begin,begin+100)
                        fmt=1 if not(arg&16) and c in (1,3) else arg&3
                        add(7,arg,c,fmt<<29,fmt<<29)
                    begin=1000+channels*200
                    add(6,arg,0,begin,begin+100)
                add(4,command>>8,0)
                for unit in range(2): (self.d/f'perftime_{command}_{stress}_cap{unit}.bin').write_bytes(bytes(2048))
            self.write(self.d/f'perftime_{command}_{stress}.csv',rows)

    def test_complete_peripheral(self):
        self.peripheral(); checks.check('perftime',self.d)

    def test_complete_aux(self):
        self.peripheral(True); checks.check('aux',self.d)

    def test_complete_version2_includes_all16_adpcm(self):
        self.peripheral(version2=True); checks.check('perftime2',self.d)

    def test_old_sound_capture_cannot_claim_version2(self):
        self.peripheral()
        (self.d/'perftime_info.txt').write_text('perftime 2; synthetic test only\n')
        with self.assertRaisesRegex(ValueError,'start timestamps'):
            checks.check('perftime2',self.d)

    def test_missing_all16_case(self):
        self.peripheral(version2=True)
        (self.d/f'perftime_{4|(22<<8)}_0.csv').unlink()
        with self.assertRaises(OSError): checks.check('perftime2',self.d)

    def test_all16_adpcm_cannot_hide_pcm_clock_channels(self):
        self.peripheral(version2=True)
        p=self.d/f'perftime_{4|(22<<8)}_0.csv'; rows=checks.records(p)
        row=next(r for r in rows if r['kind']==7 and r['rep']==1)
        row['before']=row['after']=1<<29; self.write(p,rows)
        with self.assertRaisesRegex(ValueError,'format readback'):
            checks.check('perftime2',self.d)

    def test_sound_timestamp_bracket_corruption(self):
        self.peripheral(version2=True)
        p=self.d/'perftime_4_0.csv'; rows=checks.records(p)
        next(r for r in rows if r['kind']==5)['after']+=1; self.write(p,rows)
        with self.assertRaisesRegex(ValueError,'timestamp bracket'):
            checks.check('perftime2',self.d)

    def test_capture_arm_cannot_precede_channel_start(self):
        self.peripheral(version2=True)
        p=self.d/'perftime_4_0.csv'; rows=checks.records(p)
        row=next(r for r in rows if r['kind']==6)
        row['before']=1000; row['after']=1100; self.write(p,rows)
        with self.assertRaisesRegex(ValueError,'start ordering'):
            checks.check('perftime2',self.d)

    def test_untouched_capture(self):
        self.peripheral()
        (self.d/'perftime_4_0_cap0.bin').write_bytes(struct.pack('<h',0x5a5a)*1024)
        with self.assertRaisesRegex(ValueError,'untouched'): checks.check('perftime',self.d)

    def test_timeout(self):
        self.peripheral(True)
        p=self.d/'perftime_2_0.csv'; rows=checks.records(p); rows[2]['timeout']=1; self.write(p,rows)
        with self.assertRaisesRegex(ValueError,'unsuccessful'): checks.check('aux',self.d)

    def test_stalled_wifi(self):
        self.peripheral()
        p=self.d/'perftime_3_0.csv'; rows=checks.records(p); rows[2]['after']=rows[2]['before']; self.write(p,rows)
        with self.assertRaisesRegex(ValueError,'not advancing'): checks.check('perftime',self.d)

    def test_missing_serial_observation(self):
        self.peripheral(True)
        p=self.d/'perftime_2_0.csv'; self.write(p,checks.records(p)[:-1])
        with self.assertRaisesRegex(ValueError,'missing'): checks.check('aux',self.d)

    def test_missing_capture(self):
        self.peripheral(); (self.d/'perftime_4_0_cap1.bin').unlink()
        with self.assertRaises(OSError): checks.check('perftime',self.d)

    def load2d(self):
        rows=[]
        for load in range(3):
            for sub in range(2):
                for stress in range(2):
                    for rep in range(2):
                        rows.append(dict(load=load,engine_b=sub,stress=stress,rep=rep,start_line=192,
                                         end_line=193,arm9_system_ticks=560190,timeout=0,dma_busy=0))
                        (self.d/f'load2d_{load}_{sub}_{stress}_f{rep}.bin').write_bytes(bytes(98304))
        self.write(self.d/'load2d.csv',rows)

    def test_complete_load2d(self):
        self.load2d(); checks.check('load2d',self.d)

    def test_truncated_load2d(self):
        self.load2d(); (self.d/'load2d_2_1_1_f1.bin').write_bytes(bytes(512))
        with self.assertRaisesRegex(ValueError,'expected 98304'): checks.check('load2d',self.d)


if __name__=='__main__': unittest.main()
