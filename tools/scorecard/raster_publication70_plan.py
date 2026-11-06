#!/usr/bin/env python3
"""Specify one necessary downstream diagnostic from retained metadata/images.

No model, simulation, raw-trace scan, original-host write or RTL modification.
"""
import gzip, hashlib, io, json, os, subprocess, tarfile
from pathlib import Path

R = Path(__file__).resolve().parents[2]
D = R / 'docs/results/raster-publication70-boundary-20261102'
C = R / 'build/turn69r1/candidate-host'
SOURCE = '3a5722f4568c092caa5f4d24a4c0fdff61892884'
MODEL = 'eca673716ac068ef6657c3b8b384fdbf334fd4063e86fba467dcaa3e4bc823ab'
def sha(data): return hashlib.sha256(data).hexdigest()
def J(p): return json.loads(p.read_text())

def main():
    os.setpriority(os.PRIO_PROCESS, 0, 10)
    assert J(C / 'source-relation.json')['source'] == SOURCE
    assert J(C / 'model.json')['sha256'] == MODEL
    base = C / 'results/corner'
    binding = J(base / 'analysis-prefix-binding.json')
    cached = (base / 'streams.json.gz').read_bytes()
    assert sha(cached) == binding['files']['streams.json.gz']
    s = json.loads(gzip.decompress(cached))
    states = [json.loads(x) for x in (base / 'capture/capture.states.jsonl').read_text().splitlines()]
    cap = R / 'docs/results/raster-turn69-restart-20261102'
    packet = J(cap / 'native-packet.json')
    archive = (cap / 'native-evidence.tar.gz').read_bytes()
    assert sha(archive) == packet['archive_sha256']
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tf:
        def ppm(name):
            b = tf.extractfile(name).read().split(b'\n', 3)
            assert b[:3] == [b'P6', b'256 384', b'255']
            return b[3]
        windows = []
        for raw, row, lo, hi, side in [(21,132,357000000000,361000000000,'Record68'),
                                      (37,134,625000000000,628000000000,'baseline'),
                                      (38,134,642000000000,645000000000,'baseline')]:
            a = ppm(f'candidate/shots/f{raw:03}.ppm')
            b = ppm(f'{side}/shots/f{raw:03}.ppm')
            v = ppm(f'reference/shots/f{raw-5:06}.ppm')
            new = []
            for x in range(256):
                i = 3*(row*256+x)
                if a[i:i+3] != v[i:i+3] and b[i:i+3] == v[i:i+3]:
                    new.append(dict(x=x, candidate=list(a[i:i+3]), control_and_Census=list(v[i:i+3])))
            deadlines = [d for d in s['deadlines'] if lo <= d[0] <= hi and d[1] == row]
            assert len(deadlines) == 1
            assert states[raw]['time_ps'] < deadlines[0][0] < states[raw+1]['time_ps']
            groups = {}
            for y in range(row-2,row+3):
                rec = [r for r in s['logical_stream'] if lo <= r[0] <= hi and r[5] == y]
                groups[y] = dict(records=len(rec), identities=sorted({(r[2],r[4]) for r in rec}),
                                 first=rec[0][0] if rec else None, last=rec[-1][0] if rec else None)
            windows.append(dict(raw=raw,reference=raw-5,row=row,bounds_ps=[lo,hi],
                                diagnostic_deadline=deadlines[0],new_wrong_vs=side,new_wrong_pixels=new,
                                cached_record_context=groups,video_state_interval=[states[raw]['time_ps'],states[raw+1]['time_ps']]))
    assert [len(w['new_wrong_pixels']) for w in windows[1:]] == [3,11]
    assert windows[0]['new_wrong_pixels'][0]['x'] == 7
    source_files = ['rtl/ds/nds_g3d_ring.sv','rtl/ds/nds_gpu3d.sv','rtl/ds/nds_top.sv',
                    'rtl/ds/nds_l3d_xscroll.sv','rtl/ds/nds_disp.sv','rtl/gpu3d/gpu3d_raster.sv',
                    'rtl/gpu3d/gpu3d_fpass.sv','rtl/gpu3d/gpu3d_ram.sv',
                    'rtl/gpu2d/gpu2d_bg.sv','rtl/ds/nds_g3d_journal.sv']
    source_bindings = {n:sha(subprocess.check_output(['git','show',SOURCE+':'+n],cwd=R)) for n in source_files}
    import re
    used=set()
    for name,h in J(C/'compiled-inputs.json').items():
        p=Path(name)
        if p.suffix not in ['.sv','.v','.cpp','.cc']:continue
        data=p.read_bytes();assert sha(data)==h
        used.update(int(n)for n in re.findall(rb'pair_capture_emit\(\s*(\d+)',data))
    used=sorted(used);assert not set(range(64,85)) & set(used)
    plan = dict(status='SOURCE_MAPPED_REQUIRED_DIAGNOSTIC_SPECIFICATION_NO_NEW_MODEL',
        source=SOURCE, frozen_model=MODEL, frozen_native_commit='350cd206',
        source_bindings=source_bindings, cached_binding=binding,
        native_capsule_sha256=packet['archive_sha256'], windows=windows,
        current_trace_event_ids=used,
        aliases=dict(CR='$root.tb_ds_pocket',CD='CR.dut',CS='CD.ds',CG='CS.g_3d.u_gpu3d',
                     RG='CG.g_ring.u_ringx',RA='CG.u_raster',FP='RA.u_fpass',
                     BG='CS.u_disp.u_gpu2d.u_bg',XS='CS.g_3d.u_xscroll',J='CG.g_ext.g_pair.u_store.u_journal'),
        missing_ring_inputs=['frame_go','l3d_go','l3d_line','l3d_raddr','r_go','fp_line','fp_act',
                             'll_ack','ll_q','px_valid','px_x','px_y','px_color','rg_wdrained'],
        missing_publication=['rb_v','rb_y','rb_p','st_full','st_pres','st_y','fp_d','lc_pend','lc_cnt',
                             'lc_y','lc_x','lc_px','lc_pv','lc_ab','lc_expired','cp_y','cp_s','cp_x','cp_ab',
                             'dir','rb_we_px','cp_we','lc_we','est','drop','blk','w','rblk','rk','w_resume','w_turn'],
        event_families={
          '59':'Window entry/exit: window ID, original $time, CR.v_frames/nshot, reset/frame_go epoch; force initial snapshots.',
          '60':'Ring input vector on every change: all missing_ring_inputs plus q_wack/q_rack/q_rvalid/rg_rdata. Idle cycles are implied by fixed14919ps SYS clock, never rephased.',
          '61':'Publication/state vector on change: all missing_publication plus wdone/wdone_q/wsafe/sr_a/dline/need/tgt/rd_on/rd_y and eligibility rd_ok/cp_ok/lc_ok/fp_wait/urgent_read/write_turn.',
          '62':'Actual u_rbuf write: we/waddr/wdata, winning direct > staging > LLR > SDRAM source, source line/slot/x, all simultaneous write enables. Actual u_rbuf read request and registered result on change.',
          '63':'Accepted final-pass px_valid/x/y/color into staging/direct paths; actual u_stage writes/read requests/registered result and staging slot reuse.',
          '64':'LLR ll_rd/slot/x/ack, next-cycle ll_q, exact RA.fpt_raddr/fp_act conflict; RA.lbt_we/waddr/wdata[70:0] and old-data read provenance for ll_q.',
          '65':'Final-pass/control changes: FP.fst/fp_x/fp_y/fp_done/fp_run/px_hold, RA.lines_done/y/adv/ll20/lin_hold/pxt_we/clr_we/fp_clr_req/fp_clr_ack and front r_go.',
          '66':'Display read chain: l3d_go/lv_go/line, ring_have/ring_q, l3d_rear/lv_on/lv_lo/lv_fin/rear_q/l3d_q, XS.raddr/xpos/l3d_raddr/in_q/rdata. Preserve pre-edge RAM/latch timing.',
          '67':'Actual BG consumption only: !BG.stall, j_eng/j_line/c_kind, s3.v/x, s3_bg/s3_bgop/wmask for K_3D; s4.v/x and l3d_rdata sampled into s5.c3d for K_COMP.',
          '68':'Actual 2D output out_valid/eng/draw_line/x/rgb and accepted cap_we/cap_ready/addr/data for target rows; tie layer reads to observed top pixels without assuming X scroll or blending.',
          '69':'Passive provenance snapshots at window entry and on a first read of older data: last actual writer time/address/data/source for all relevant top-layer, staging and read-buffer cells. Unknown-before-first-write stays explicit.',
          '70':'Journal producer counters: total SYS cycles, original producer opportunity, po_valid, actual ready/commit, po_wv, early_stall; 64-bit cumulative values at existing frame-state boundaries.',
          '71':'Virtual threshold256/512/768/1024 bins: all-cycle, original opportunity-cycle and actual commit counts at/above threshold; no readiness control.',
          '72':'Journal stall reason-mask histogram: !logical_credit / ingress>=1024 / copy_on / sealed[tail[0]] / sealed[!tail[0]]; include po_valid and construction-beat splits.',
          '73':'Journal writer: jw_req&&!jw_ack total/max streak, request onset to first/eighth ACK max/sum/count; sent-safe7 fence and drained/quiet wait counts.',
          '74':'Ring writer service: first offer to first/eighth ACK, block completion to saved-writer resume, suspended urgent-read/copy/staging waits; completed and outstanding intervals separated.'},
        provenance_contract=[
          'Observe only; no force, deposit, driver, DPI-return feedback, ready/ACK, urgency threshold, clock or production edit.',
          'Track last writes from reset in simulation-only shadow metadata for 1024 top-layer cells,1024 staging cells and512 read-buffer cells. Emit only within selected windows or their bounded entry snapshots.',
          'At each posedge capture pre-NBA signals. Associate registered RAM data with the previous posedge read; read the shadow before updating same-edge writes to honor OLD_DATA. Record source priority exactly from the actual RAM port.',
          'Provenance is diagnostic evidence, not initialization for a claimed reachable fixture. Any unknown prior writer or disagreement with actual RAM data blocks attribution.',
          'Counters run globally in passive overlay; emit summaries at original state boundaries. Do not change the40-byte event format or existing events.'],
        producer_opportunity='J.po_valid && J.logical_credit && !J.copy_on && !J.sealed[J.tail[0]] && !J.sealed[!J.tail[0]]',
        replay_disposition='Retained input records and external bus events cannot uniquely reconstruct the missing actual producer/final-pass/LLR/RBuf history. No native-equivalent coupled fixture can be built honestly from this packet; do not substitute later SDRAM write timestamps for px_valid or synthetic ll_ack.',
        next_model=dict(count=1, candidate_only=True, production_source=SOURCE, profile58='unchanged', actor='original Corner39',
                        frames=39, states=40, fixed_mapping='raw-5', change='private passive capture overlay only',
                        runtime_gate='Actual capacity/ownership check, NI10/j1/t1 D1, one attempt, Root scheduling; no Laptop or fit',
                        qualification=['Compile production/actor/input/clock manifest byte exact to frozenR1; only observer source differs.',
                                       'All39 images,40states,CPU byte stream,PCM values/timestamps,save and printed diagnostics equal frozenR1.',
                                       'One new candidate scan exports boundary windows and existing finite service checks; reuse cached controls, never rescan original raw.',
                                       'Reject exact attribution if any requested row/actual layer read/provenance predecessor/LLR return is missing.',
                                       'Catch a one-cell/one-cycle provenance mutation in offline replay; observer passivity cannot qualify a production repair.']),
        forbidden=['RTL repair','journal depth/layout change','other-owner edits','baseline rerun','unchanged-model rerun','whole old trace scan','native DS speed acceptance'])
    plan['event_families']={str(int(k)+5):v for k,v in plan['event_families'].items()}
    plan['event_namespace']='64..84 after all compiled recorder check; old v1 59..79 namespace INVALID before native'
    D.mkdir(parents=True,exist_ok=True)
    (D / 'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
    print(json.dumps(dict(status=plan['status'],windows=[dict(raw=w['raw'],row=w['row'],new_wrong=len(w['new_wrong_pixels']),deadline=w['diagnostic_deadline'][0])for w in windows],source_bindings=len(source_bindings),unused_event_ids='64..84',no_model=True)))
if __name__ == '__main__': main()
