#!/usr/bin/env python3
"""Assess saved boundary data and cached capture-word attribution only."""
import gzip,json,os
from pathlib import Path
R=Path(__file__).resolve().parents[3];B=R/'build/publication70'
def J(p):return json.loads(p.read_text())
def rgb(c):return[(c>>s&63)*4+((c>>s&63)>>4)for s in [0,6,12]]
def main():
 os.setpriority(os.PRIO_PROCESS,0,10);decoded=J(B/'decoded-boundary.json')
 with gzip.open(B/'decoded-detail.json.gz','rt')as f:detail=json.load(f)
 cap=J(B/'capture-window-pixels.json');st=next(x for x in decoded['stages']if x['line']==131);masks={int(k):n for k,n in st['PS_blocked_pipeline_mask'].items()}
 bits={n:sum(v for k,v in masks.items()if k&(1<<b))for n,b in [('lin_hold',9),('texture_issue_hold15',8),('texture_return_wait17',7),('texture_first_take17',6),('palette_issue_hold17',5),('palette_return_wait19',4),('palette_first_take19',3),('linebuffer_hazard20',2),('LLR_port20',1)]}
 targets={x['raw']:x for x in decoded['targets']};post21={x['x']:x for x in detail['producer_pixels']if x['raw_window']==21}
 assert all(rgb(post21[p['x']]['color'])==p['control_and_Census']for p in targets[21]['new_wrong_pixel_observations'])
 raw37=[]
 for p in targets[37]['new_wrong_pixel_observations']:
  pp=[x for x in detail['producer_pixels']if x['raw_window']==37 and x['x']==p['x']];assert len(pp)==1 and rgb(pp[0]['color'])==p['control_and_Census']
  raw37.append(dict(x=p['x'],partial_copy=p['layer'][0],actual_engineA_output=next(q for q in p['output']if q['engine']==0),later_finalpass=pp[0],later_RGB8=rgb(pp[0]['color']),reference=p['control_and_Census']))
 raw38=[]
 for p in targets[38]['new_wrong_pixel_observations']:
  x=p['x'];cp=[q for q in cap if 625000000000<=q['time']<=628000000000 and q['out_x']==x];bm=[q for q in detail['all_layer_samples']if q['raw_window']==38 and q['engine']==1 and q['x']==x];assert len(cp)==len(bm)==1;cp,bm=cp[0],bm[0];assert bm['kind']==4 and bm['opaque']
  c18=bm['bg']>>8;recovered=0x8000|((c18>>1)&31)|(((c18>>7)&31)<<5)|(((c18>>13)&31)<<10);assert recovered==cp['cap_data'];out=[q for q in p['output']if q['engine']==1];assert len(out)==1 and out[0]['RGB8']==p['candidate']
  raw38.append(dict(x=x,reference=p['control_and_Census'],accepted_prior_capture=cp,actual_bitmap_sample=bm,recovered_opaque_RGB555=recovered,engineB_output=out[0],current_3D_read=p['layer'][0],scope='Bit-exact prior capture/coordinate/bitmap/output data sequence. Actual bitmap physical read address was not captured; address provenance remains an explicit inference.'))
 addresses={x['accepted_prior_capture']['cap_addr']>>1 for x in raw38};bindings=[]
 with gzip.open(R/'build/turn69r1/vram-changed-words.jsonl.gz','rt')as f:
  for s in f:
   w=json.loads(s)
   if w['frame']in[38,39]and w['word_address']in addresses:bindings.append(w)
 assert len(bindings)==14;by={w['word_address']:w for w in bindings if w['frame']==38}
 for p in raw38:
  cp=p['accepted_prior_capture'];word=by[cp['cap_addr']>>1];shift=16*(cp['cap_addr']&1);assert(word['candidate']>>shift)&65535==cp['cap_data'];old=(word['baseline']>>shift)&65535;c=old&32767;c18=((c&31)<<1)|(((c>>5)&31)<<7)|(((c>>10)&31)<<13);assert rgb(c18)==p['reference']
  p.update(cached_VRAM_word_address=word['word_address'],prior_control_capture_halfword=old,prior_control_bitmap_RGB8=rgb(c18),accepted_word_binding=word['candidate_last_write'])
 gl=detail['global_summaries'];time=max(x['time']for x in gl);last=[x for x in gl if x['time']==time];counters={str((x['payload']>>16)&65535):(x['payload']>>32)&((1<<64)-1)for x in last if x['kind']==70};threshold=[dict(threshold=x['payload']&65535,mode=(x['payload']>>16)&65535,value=(x['payload']>>32)&((1<<64)-1))for x in last if x['kind']==71];assert counters['10']==69 and all(x['value']==0 for x in threshold)
 writers={name:{str(x['payload']&0xffffffff):(x['payload']>>32)&((1<<64)-1)for x in last if x['kind']==k and x['subtype']==0}for k,name in [(73,'journal'),(74,'ring')]}
 result=dict(status='MEASURED_PUBLICATION_AND_STAGE_BOUNDARIES_NO_REPAIR',source='3a5722f4568c092caa5f4d24a4c0fdff61892884',model='e7dd2d07552dfcb8b9edc9e8bf0834f920961ad564d80e553458d22c5ee80c03',raw21=dict(latch=targets[21]['latch_observations'][0],copy_pending_observation=next(x for x in detail['timeline']if x['raw_window']==21 and x['time']==359382105153),first_new_pixel=targets[21]['new_wrong_pixel_observations'][0],all219_later_finalpass_pixels_equal_reference=True,first_later_finalpass=post21[7],fact='Active finalpass131 blocks copy eligibility for needed132; no full staging/SDRAM replacement, bank still130. Display latches rear, not stale130. Correct finalpass132 data arrives after composition.'),raw37_three_pixels=raw37,raw38_eleven_pixels=raw38,line131=dict(cycles=8870,target=4260,excess=4610,partition=dict(cache_retry=5786,PS_backpressure=2192,other=892),backpressure_phase=dict(edge=31,span=99,pixel=2062),blocked_pipeline_presence=bits,flags_scope='Presence counts overlap; full joint masks retained. Earlier2020nonEOF backpressure excluded172EOF-held cycles, now removed from prior1064residual.'),journal=dict(final_time=time,counters=counters,thresholds=threshold,writer=writers,scope='Finite original39 traffic only. No depth change/global service/512-depth qualification.'),next_speed_action='Price timely canonical refill/retention for173critical records and texture/palette lead under original physical arbitration, all8guardedwords and current bank/generation semantics; prove combined deadlines. Earlier full finalpass publication can avoid the partial bypass without a second shading path. Retain all14pixel/state/audio gates.',DS_dependency='Run33 pins partial polygons over clear, not the exact AA/fog/lower-layer finalpass treatment here. No unmeasured filter target is adopted. If changing that behavior, an hwref-owned future new-only discriminator is needed.',remaining='Raw38 actual bitmap read address not captured; its data sequence/control capture word/reference match is exact. Other R1 image regressions remain. R1 stays REJECT; no repair/depth/production change.',no_new_model=True)
 (B/'assessment.json').write_text(json.dumps(result,indent=2)+'\n');(B/'propagated-capture-word-bindings.json').write_text(json.dumps(bindings,indent=2)+'\n');print(json.dumps(dict(status=result['status'],line131=result['line131'],raw21=219,raw37=3,raw38=11)))
if __name__=='__main__':main()
