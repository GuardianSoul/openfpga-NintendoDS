#!/usr/bin/env python3
"""Light source/report fixtures only; mock passes never qualify native mapping."""
import argparse,copy,hashlib,importlib.util,json,os,pathlib,re,shutil,subprocess,tarfile,time
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[2]
spec=importlib.util.spec_from_file_location('tag_gate',HERE/'gate.py');g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--negative-report',type=pathlib.Path);a=ap.parse_args()
os.nice(10);OUT=ROOT/'build/tag-metadata-gate';OUT.mkdir(parents=True,exist_ok=True)
with tarfile.open(HERE/'fixtures/source.tar.gz')as t:
    fixture=json.loads(t.extractfile('manifest.json').read());sources={n:t.extractfile(n).read()for n in fixture['files']}
for n,h in fixture['files'].items():assert g.digest(sources[n])==h
mem=sources['rtl/arm/arm9_mem.sv'].decode();ram=sources['rtl/arm/arm9_ram.sv'].decode();intent=g.source_intent(mem,ram)
PREFIX='core_top:ic|nds_top:ds|cpu_domain:u_cpud|arm_cpu:g_one.u_cpu|arm9_mem:u_mem9|'
def row(bank,sites):
    width=21 if bank=='d'else 25
    return {'Name':PREFIX+'arm9_ram:g_packed_tags.u_packed_'+bank+'|altsyncram:lane[0].one.u_ram|altsyncram_abc:auto_generated|ALTSYNCRAM','Type':'M10K block','Mode':'True Dual Port','Clock Mode':'Single Clock','Port A Depth':'256','Port A Width':'32','Port B Depth':'256','Port B Width':'32','Port A Input Registers':'yes','Port A Output Registers':'no','Port B Input Registers':'yes','Port B Output Registers':'no','Size':'8192','Implementation Port A Depth':'256','Implementation Port A Width':str(width),'Implementation Port B Depth':'256','Implementation Port B Width':str(width),'Implementation Bits':str(width*256),'M10K blocks':'2','MLABs':'0','MIF':'None','Location':', '.join(sites),'Mixed Width RDW Mode':"Don't care",'Port A RDW Mode':'New data','Port B RDW Mode':'New data','ECC Mode':'Off','ECC Pipeline Registers':'No','Fits in MLABs':'No - Unsupported Mode'}
base=[row('d',['M10K_X42_Y15_N0','M10K_X42_Y16_N0']),row('i',['M10K_X42_Y17_N0','M10K_X42_Y18_N0'])]
other=copy.deepcopy(base[0]);other.update(Name='core_top:ic|nds_top:ds|nds_arm7_port:u_p7|nds_lcache:u_dtag|altsyncram:mem_rtl_0|ALTSYNCRAM',Location='M10K_X42_Y19_N0',**{'M10K blocks':'1'})
base.append(other)
def report(rows):
    keys=list(base[0]);return 'MOCK_FIXTURE_NOT_PHYSICAL\nFitter report for apf_top\nQuartus Prime Version MOCK\n; Fitter Status ; Successful ;\n; Fitter RAM Summary ;\n; '+' ; '.join(keys)+' ;\n'+''.join('; '+' ; '.join(r.get(k,'')for k in keys)+' ;\n'for r in rows)
results=[]
def check(name,fn,positive=False):
    try:value=fn()
    except (g.GateError,OSError,ValueError,KeyError,IndexError,subprocess.CalledProcessError)as e:
        assert not positive,(name,str(e));results.append({'case':name,'PASS':True,'rejected':str(e)})
    else:
        assert positive,(name,'fault escaped');results.append({'case':name,'PASS':True,'scope':'MOCK_ONLY'if name.startswith('mock')else'SOURCE_ONLY'})
check('observed_source_intent',lambda:g.source_intent(mem,ram),True)
check('mock_complete_two_banks_four_locations',lambda:g.mapping(report(base),intent,allow_mock=True),True)
hash_name=copy.deepcopy(base);hash_name[2]['Name']=PREFIX+'arm9_ram:dway[0].u_d|altsyncram:g_pack.u_ram|altsyncram_tag9:auto_generated|ALTSYNCRAM'
check('mock_unrelated_data_RAM_hash_contains_tag',lambda:g.mapping(report(hash_name),intent,allow_mock=True),True)
mutants={
 'missing_D':lambda rs:rs.pop(0),
 'missing_I':lambda rs:rs.pop(1),
 'duplicate_row':lambda rs:rs.append(copy.deepcopy(rs[0])),
 'duplicate_bank_distinct_leaf':lambda rs:rs.append({**rs[0],'Name':rs[0]['Name'].replace('abc:','def:'),'Location':'M10K_X42_Y20_N0, M10K_X42_Y21_N0'}),
 'wrong_bank_name':lambda rs:rs[1].update(Name=rs[1]['Name'].replace('u_packed_i','u_packed_q')),
 'different_ARM9_owner':lambda rs:rs[1].update(Name=rs[1]['Name'].replace('arm9_mem:u_mem9','arm9_mem:u_mem9_other')),
 'old_tag_remains':lambda rs:rs.append({**rs[0],'Name':PREFIX+'arm9_ram:g_original_tags.u_dtag|altsyncram:g_fold.u_ram|ALTSYNCRAM','Location':'M10K_X42_Y20_N0, M10K_X42_Y21_N0'}),
 'wrong_native_lane':lambda rs:rs[0].update(Name=rs[0]['Name'].replace('lane[0]','lane[1]')),
 'SDP_instead_of_TDP':lambda rs:rs[0].update(Mode='Simple Dual Port'),
 'two_clocks':lambda rs:rs[0].update(**{'Clock Mode':'Dual Clock'}),
 'wrong_A_width':lambda rs:rs[0].update(**{'Port A Width':'16'}),
 'wrong_B_width':lambda rs:rs[1].update(**{'Port B Width':'16'}),
 'wrong_A_depth':lambda rs:rs[0].update(**{'Port A Depth':'128'}),
 'wrong_B_depth':lambda rs:rs[1].update(**{'Port B Depth':'128'}),
 'unregistered_A_input':lambda rs:rs[0].update(**{'Port A Input Registers':'no'}),
 'unregistered_B_input':lambda rs:rs[0].update(**{'Port B Input Registers':'no'}),
 'registered_A_output':lambda rs:rs[0].update(**{'Port A Output Registers':'yes'}),
 'registered_B_output':lambda rs:rs[0].update(**{'Port B Output Registers':'yes'}),
 'MLAB_spill':lambda rs:rs[0].update(MLABs='1'),
 'one_M10K':lambda rs:rs[0].update(Location='M10K_X42_Y15_N0',**{'M10K blocks':'1'}),
 'three_M10Ks':lambda rs:rs[0].update(Location='M10K_X42_Y15_N0, M10K_X42_Y16_N0, M10K_X42_Y20_N0',**{'M10K blocks':'3'}),
 'unassigned':lambda rs:rs[0].update(Location='Unassigned'),
 'missing_location':lambda rs:rs[0].update(Location=''),
 'location_count_mismatch':lambda rs:rs[0].update(Location='M10K_X42_Y15_N0'),
 'within_bank_collision':lambda rs:rs[0].update(Location='M10K_X42_Y15_N0, M10K_X42_Y15_N0'),
 'D_I_location_collision':lambda rs:rs[1].update(Location='M10K_X42_Y15_N0, M10K_X42_Y18_N0'),
 'other_RAM_location_collision':lambda rs:rs[2].update(Location='M10K_X42_Y15_N0'),
 'ambiguous_location_text':lambda rs:rs[0].update(Location='M10K_X42_Y15_N0, ...'),
 'invalid_N_site':lambda rs:rs[0].update(Location='M10K_X42_Y15_N1, M10K_X42_Y16_N0'),
 'mixed_RDW_old':lambda rs:rs[0].update(**{'Mixed Width RDW Mode':'Old data'}),
 'A_RDW_old':lambda rs:rs[0].update(**{'Port A RDW Mode':'Old data'}),
 'B_RDW_old':lambda rs:rs[0].update(**{'Port B RDW Mode':'Old data'}),
 'unexpected_MIF':lambda rs:rs[0].update(MIF='tag.mif'),
 'D_used_bits_lost':lambda rs:rs[0].update(**{'Implementation Port A Width':'20','Implementation Port B Width':'20','Implementation Bits':'5120'}),
 'I_used_bits_lost':lambda rs:rs[1].update(**{'Implementation Port A Width':'24','Implementation Port B Width':'24','Implementation Bits':'6144'}),
 'implementation_ports_disagree':lambda rs:rs[0].update(**{'Implementation Port B Width':'22'}),
 'implementation_depth_wrong':lambda rs:rs[0].update(**{'Implementation Port B Depth':'128'}),
 'implementation_bits_wrong':lambda rs:rs[0].update(**{'Implementation Bits':'8192'}),
 'missing_required_field':lambda rs:rs[0].pop('Mode'),
}
for name,mutate in mutants.items():
    rows=copy.deepcopy(base);mutate(rows);check(name,lambda rows=rows:g.mapping(report(rows),intent,allow_mock=True))
for name,text in {
 'failed_fit':report(base).replace('Fitter Status ; Successful','Fitter Status ; Failed'),
 'duplicate_success_status':report(base)+'; Fitter Status ; Successful ;\n',
 'duplicate_RAM_summary':report(base)+'; Fitter RAM Summary ;\n',
 'mock_report_live_path':report(base),
 'malformed_other_RAM_cannot_hide_collision':report(base).replace('; '+base[2]['Name']+' ; M10K block ;','; '+base[2]['Name']+' ;'),
 'duplicate_RAM_header_column':report(base).replace(' ; Location ;',' ; Name ;',1),
}.items():check(name,lambda text=text,name=name:g.mapping(text,intent,allow_mock=name!='mock_report_live_path'))
for name,newmem,newram in [
 ('wrong_source_AW',mem.replace('.AW(8),.LANES(1)','.AW(7),.LANES(1)'),ram),
 ('wrong_source_LANES',mem.replace('.LANES(1)','.LANES(2)'),ram),
 ('source_FOLD_enabled',mem.replace('.FOLD(0)','.FOLD(1)'),ram),
 ('source_I_reads_D_address',mem.replace('.b_addr(i_addr[12:5])','.b_addr(d_addr[12:5])'),ram),
 ('source_I_writes_D_bank',mem.replace('.a_addr(it_aa),.a_we(|it_we)','.a_addr(dt_aa),.a_we(|dt_we)'),ram),
 ('source_guard_changed',mem.replace('OPT==1711268835','OPT==1711268834'),ram),
 ('source_selected_generate_missing',mem.replace('begin : g_packed_tags','begin : missing_tags'),ram),
 ('native_RDW_changed',mem,ram.replace('"DONT_CARE"','"OLD_DATA"')),
 ('native_PACK_predicate_changed',mem,ram.replace('LANES == 4 && LANE_W == 8','LANES == 1 && LANE_W == 32')),
]:check(name,lambda m=newmem,r=newram:g.source_intent(m,r))
clockpos=ram.rfind('.clock0');changed=ram[:clockpos]+ram[clockpos:].replace('.clock0','.clock1',1)
check('native_second_clock',lambda:g.source_intent(mem,changed))
# Real git/QSF pin checks use a private tiny repository, never another session's tree.
repo=OUT/'source-repo'
if repo.exists():shutil.rmtree(repo)
(repo/'rtl/arm').mkdir(parents=True)
for n,b in sources.items():(repo/n).write_bytes(b)
subprocess.run(['git','init','-q',str(repo)],check=True)
subprocess.run(['git','add','rtl'],cwd=repo,check=True)
subprocess.run(['git','-c','user.name=Gate fixture','-c','user.email=gate-fixture@invalid.example','commit','-qm','Observed source fixture only'],cwd=repo,check=True)
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()
qsf=''.join('set_global_assignment -name SYSTEMVERILOG_FILE "'+str(repo/n)+'"\n'for n in sources)
check('QSF_commit_exact',lambda:g.qsf_sources(qsf,repo,commit),True)
check('QSF_missing_helper',lambda:g.qsf_sources(qsf.splitlines()[0]+'\n',repo,commit))
check('QSF_duplicate_source',lambda:g.qsf_sources(qsf+qsf.splitlines()[0]+'\n',repo,commit))
remapped=qsf.replace(str(repo),'/archived/build/source')
check('QSF_explicit_archive_root',lambda:g.qsf_sources(remapped,repo,commit,'/archived/build/source'),True)
check('QSF_unmapped_foreign_root',lambda:g.qsf_sources(remapped,repo,commit))
(repo/'rtl/arm/arm9_ram.sv').write_text(ram+'\n// dirty fixture\n')
check('QSF_dirty_source',lambda:g.qsf_sources(qsf,repo,commit))
(repo/'rtl/arm/arm9_ram.sv').write_text(ram)
# Artifact origin, file hashes and intent are independent acceptance guards.
bundle=OUT/'mock-bundle'
if bundle.exists():shutil.rmtree(bundle)
(bundle/'sources').mkdir(parents=True)
for n,b in sources.items():(bundle/'sources'/pathlib.Path(n).name).write_bytes(b)
(bundle/'fit.rpt').write_text(report(base));(bundle/'project.qsf').write_text(qsf)
shutil.copyfile(HERE/'gate.py',bundle/'gate.py');shutil.copyfile(HERE.parent/'resources.py',bundle/'resources.py')
(bundle/'intent.json').write_text(json.dumps(intent,indent=2)+'\n')
bindings={n:g.digest(b)for n,b in sources.items()};g.seal(bundle,'mock',commit,bindings)
check('mock_sealed_packet_internal_only',lambda:g.evaluate(bundle,allow_mock=True),True)
check('mock_origin_rejected_live',lambda:g.evaluate(bundle))
g.seal(bundle,'quartus-fitter-report',commit,bindings)
check('mock_origin_spoof_rejected',lambda:g.evaluate(bundle))
g.seal(bundle,'mock',commit,bindings);(bundle/'fit.rpt').write_text(report(base)+'\nchanged\n')
check('artifact_hash_changed',lambda:g.evaluate(bundle,allow_mock=True))
(bundle/'fit.rpt').write_text(report(base));g.seal(bundle,'mock',commit,bindings)
negative=None
if a.negative_report:
    raw=a.negative_report.read_bytes();check('actual_2170_negative_only',lambda:g.mapping(raw.decode(errors='replace'),intent))
    negative={'path':str(a.negative_report.resolve()),'sha256':g.digest(raw),'physical_acceptance':False,'reason':results[-1]['rejected']}
result={'status':'PASS_SOURCE_REPORT_FIXTURES_ONLY_NOT_PHYSICAL','cases':results,'count':len(results),'observed_source_fixture':fixture,'intent':intent,'negative_2170':negative,'no_Quartus_or_heavy_worker':True}
(OUT/'tests.json').write_text(json.dumps(result,indent=2)+'\n')
for row in results:print(row['case'],row.get('rejected','PASS bounded mock/source check'))
print(result['status'],len(results))
