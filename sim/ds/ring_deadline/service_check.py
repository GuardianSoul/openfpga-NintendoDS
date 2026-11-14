#!/usr/bin/env python3
"""Actual native controller/CDC service, one serialized NI10/j1 worker."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import check

FILES = ['rtl/ds/nds_g3d_ring_deadline.sv', 'rtl/gpu3d/gpu3d_ram.sv',
         'rtl/pocket/nds_ring_post_arb.sv', 'rtl/pocket/nds_cdc.sv',
         'rtl/pocket/nds_sdram_mc.sv', 'rtl/pocket/nds_sdram_bus.sv',
         'sim/phase1/sim_prims.sv', 'sim/phase1/sdram_chip_model.sv',
         'sim/ds/ring_deadline/service.sv']
FAULTS = {
    'fairness': ('nds_sdram_bus.sv', 'if (urgent_count < 2 && fair_urgent != 0)',
                 'if (fair_urgent != 0)', 'CLIENT_STARVED'),
    'refresh': ('nds_sdram_mc.sv', "ref_owed <= ref_owed + 1'b1;", 'ref_owed <= ref_owed;', 'REFRESH_STARVED'),
    'halfmask': ('nds_sdram_mc.sv', "dqm <= {2{ch_hi ? !q_he : !bw_he[0]}};", "dqm <= 2'b00;", 'NATIVE_DATA'),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--fault', choices=FAULTS)
    ap.add_argument('--phase-ps',type=int,default=0)
    args = ap.parse_args()
    os.nice(10)
    B = args.out.resolve()
    assert not B.exists(), B
    check.admission()
    B.mkdir(parents=True)
    manifest = {}
    for p in FILES:
        q = B/Path(p).name
        shutil.copyfile(check.ROOT/p, q)
        manifest[p] = check.sha(q)
    if args.fault:
        f, a, b, marker = FAULTS[args.fault]
        p = B/f
        s = p.read_text()
        assert s.count(a) == 1, (f, a, s.count(a))
        p.write_text(s.replace(a,b))
    (B/'source.json').write_text(json.dumps({'source_files': manifest, 'fault': args.fault,
        'actual_sources': {p.name:check.sha(p) for p in B.glob('*.sv')}}, indent=2)+'\n')
    cmd = [check.BIN/'verilator','--binary','--timing','--assert','--threads','1','-j','1','-O1',
           '-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC','-Wno-TIMESCALEMOD',
           '-Wno-PINMISSING','-Wno-MULTIDRIVEN','--compiler','clang','-CFLAGS','-std=c++20 -O0',
           '-MAKEFLAGS','CXX=clang++ VM_PARALLEL_BUILDS=1','--top-module','ring_service_tb',
           '--Mdir',B/'obj'] + [B/Path(p).name for p in FILES]
    (B/'command.json').write_text(json.dumps([str(x) for x in cmd],indent=2)+'\n')
    try:
        rc = check.run(cmd,B/'build.log',True)
        assert rc == 0, (rc,(B/'build.log').read_text()[-3000:])
        binary=B/'obj/Vring_service_tb'
        rc = check.run([binary,'+phase_ps='+str(args.phase_ps)],B/'run.log')
        log=(B/'run.log').read_text()
        ok=rc!=0 and marker in log if args.fault else rc==0 and 'RING_SERVICE_PASS' in log and 'ERROR' not in log
        (B/'result.json').write_text(json.dumps({'PASS':ok,'returncode':rc,'fault':args.fault,'phase_ps':args.phase_ps,
            'binary_sha256':check.sha(binary),'run_sha256':check.sha(B/'run.log'),
            'source_sha256':check.sha(B/'source.json')},indent=2)+'\n')
        print(log[-2500:],flush=True)
        assert ok,B
    finally:
        check.status()


if __name__=='__main__':
    main()
