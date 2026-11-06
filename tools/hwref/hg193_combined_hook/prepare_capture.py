#!/usr/bin/env python3
"""Source-only native60 full-game capture composition; no compiler/model."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from publication_contract import contract, diagnostics

HERE=Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,indent=2)+'\n')


def prepare(parent,host,out):
    parent,host,out=parent.resolve(),host.resolve(),out.resolve()
    assert out!=parent and parent not in out.parents
    previous=json.loads((parent/'composition.json').read_text())
    for name,digest in previous['copies_sha256'].items():assert sha(parent/name)==digest,name
    helper=(parent/'include/runtime_import_arm9_mem_ready.svh').read_text()
    out.mkdir(parents=True,exist_ok=True)
    # Identify the source contract/ABI/mutation gate BEFORE composition.
    api=contract(helper);write(out/'publication-contract.json',api)
    lifecycle=out/'lifecycle-source'
    for name in ['sw/stateload/stateload.s','sw/stateload/stateload.bin','sw/boot/import.s','sim/ds/state_import.py']:
        path=lifecycle/name;path.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(parent/'source'/name,path)
    for name in ['snapshot','include','observed-overlay','wram-expected']:
        shutil.copytree(parent/name,out/name,dirs_exist_ok=True)
    for name in ['composition.json','game-build-plan.json','edits.json','wram-input-contract.json']:
        shutil.copyfile(parent/name,out/('parent-'+name if name in ['composition.json','game-build-plan.json'] else name))
    old_inputs=json.loads((host/'compiled-inputs.json').read_text())
    selected={name:digest for name,digest in old_inputs.items() if '/staged/overlay/sim/pocket_ds/' in name}
    assert len(selected)==6
    capture=out/'capture-bindings';capture.mkdir(exist_ok=True)
    for name,digest in selected.items():
        assert sha(Path(name))==digest,name
        shutil.copyfile(name,capture/Path(name).name)
    old_actor=(capture/'tb_ds_pocket.sv').read_text()
    current_actor=(out/'snapshot/host-overlay/tb_native52.sv').read_text()
    assert sha(capture/'tb_ds_pocket.sv')=='3fa66f90c09138028868e4aa49a58387411318e95f17f84f501bf24c407910d6'
    regions={}
    for name,start,end in [('images','    reg [8*256-1:0] shots;','    // ----------------'),
        ('save','    task automatic save_quit','    endtask')]:
        def region(text):
            a=text.index(start);b=text.index(end,a+len(start))
            return text[a:b+(len(end) if name=='save' else 0)]
        assert region(old_actor)==region(current_actor),name
        regions[name]=hashlib.sha256(region(old_actor).encode()).hexdigest()
    # Keep every existing guard expression. Emit all26 clause values/addresses
    # while clocks are held, before the original first-failure guard executes.
    hook=out/'include/hg193_combined_hook.svh';original=hook.read_text()
    marker='`include "hg193_combined_drain.svh"'
    replacement=marker+'\n`include "hg193_publication_diagnostics.svh"'
    assert original.count(marker)==1
    changed=original.replace(marker,replacement)
    call=' hg193_combined_hold_clocks();\n'
    assert changed.count(call)==1
    changed=changed.replace(call,call+' hg193_publication_diagnostics("before-publication");\n')
    assert changed.replace(replacement,marker).replace(' hg193_publication_diagnostics("before-publication");\n','')==original
    hook.write_text(changed)
    (out/'include/hg193_publication_diagnostics.svh').write_text(diagnostics(api['cpu_arm9_cache_clauses']))
    (out/'include/parent-hg193_combined_hook.svh.txt').write_text(original)
    guard='''// Source-only full-scene launch contract. No DUT writes or waits.
module nds_full_game_capture_contract;
 initial begin
  integer limit,frames,save_words,save_bytes;
  string path;
  if($test$plusargs("scene_capture_prefix="))begin
   assert($value$plusargs("scene_capture_frames=%d",limit) && limit>=106 && limit<=256)
    else $fatal(1,"FULL_GAME_CAPTURE_EXPLICIT_106_WINDOW_REQUIRED");
   assert($value$plusargs("frames=%d",frames) && frames>0 && frames<=limit)
    else $fatal(1,"FULL_GAME_CAPTURE_FRAME_WINDOW_MISMATCH");
   assert($value$plusargs("shots=%s",path) && $value$plusargs("savout=%s",path))
    else $fatal(1,"FULL_GAME_CAPTURE_IMAGE_SAVE_OUTPUT_REQUIRED");
   assert($value$plusargs("scene_save_words=%d",save_words) &&
          $value$plusargs("savsize=%d",save_bytes) && save_words*4==save_bytes)
    else $fatal(1,"FULL_GAME_CAPTURE_COMPLETE_SAVE_REQUIRED");
   assert($test$plusargs("root40_ldm_capture") && $test$plusargs("combined_wram_restore"))
    else $fatal(1,"FULL_GAME_CAPTURE_LDM_WRAM_REQUIRED");
  end
 end
endmodule
bind tb_ds_pocket nds_full_game_capture_contract u_full_game_capture_contract();
'''
    (out/'observed-overlay/full_game_capture_contract.sv').write_text(guard)
    parent_plan=json.loads((parent/'game-build-plan.json').read_text())
    argv=[a.replace(str(parent)+'/',str(out)+'/') for a in parent_plan['argv']]
    argv[1:1]=['+define+SCENE_SD','+define+FULL_GAME_CAPTURE','-LDFLAGS','-lz']
    additions=[str(capture/Path(n).name) for n in selected if not n.endswith('/tb_ds_pocket.sv')]
    argv+=additions+[str(out/'observed-overlay/full_game_capture_contract.sv')]
    # Retain actual60 assertions; old heavy59_profile is not an extra authority.
    plan=dict(parent_plan,state='SOURCE_ONLY_FULL_GAME_CAPTURE_NOT_BUILT',argv=argv,
        cwd=parent_plan['cwd'].replace(str(parent),str(out)),model_sha256=None,
        capture_window_minimum=106,capture_window_maximum=256,
        changes=parent_plan['changes']+['five qualified capture/probe helper inputs unchanged; ABI unchanged',
            'SCENE_SD/full-game launch guard/zlib; existing085 shots/save actors equal3fa',
            'passive26clause diagnostics only; every publication guard retained'])
    write(out/'game-build-plan.json',plan)
    # Canonical bound staged code/input bytes exclude the self-referential pin.
    folders=['snapshot','include','observed-overlay','capture-bindings','wram-expected','lifecycle-source']
    binding_inputs={str(p.relative_to(out)):sha(p) for folder in folders
        for p in (out/folder).rglob('*') if p.is_file() and p.name!='hg193_shared_model_binding.svh'}
    binding_hash=hashlib.sha256(json.dumps(binding_inputs,sort_keys=True).encode()).hexdigest()
    pin=out/'include/hg193_shared_model_binding.svh'
    text=pin.read_text();assert previous['compiled_input_binding_sha256'] in text
    pin.write_text(text.replace(previous['compiled_input_binding_sha256'],binding_hash))
    copies={str(p.relative_to(out)):sha(p) for folder in folders for p in (out/folder).rglob('*') if p.is_file()}
    # Explicit aliases bind unchanged observer macros to actual current source.
    aliases={'CR':'$root.tb_ds_pocket','CD':'$root.tb_ds_pocket.dut','CS':'$root.tb_ds_pocket.dut.ds',
        'CG':'$root.tb_ds_pocket.dut.ds.g_3d.u_gpu3d','CC':'$root.tb_ds_pocket.dut.ds.u_cpud.g_one.u_cpu',
        'PST':'$root.tb_ds_pocket.dut.ds.g_3d.u_gpu3d.g_ext.g_pair.u_store',
        'LC':'$root.tb_ds_pocket','LD':'$root.tb_ds_pocket.dut','LF':'$root.tb_ds_pocket.dut.ds.u_fab'}
    source_names=['rtl/arm/arm_cpu.sv','rtl/arm/arm_core.sv','rtl/arm/arm9_mem.sv','rtl/ds/nds_fabric.sv','rtl/pocket/core_top_ds.sv']
    alias_sources={str(p.relative_to(out)):sha(p) for name in source_names
        for p in [out/'snapshot/host-observer'/name]}
    write(out/'capture-source-rebind.json',dict(qualified_manifest_sha256=sha(host/'compiled-inputs.json'),
        qualified_files=selected,current_main40_aliases=aliases,current_alias_source_hashes=alias_sources,
        inherited_full_profile=previous['profile'],old_actor_role='3fa is a qualified capture/images/save control; never substituted for085 actor',
        unchanged_actor_regions_sha256=regions,all_helper_bytes_unchanged=True,
        namespace='No macro/path rewrite needed for listed main40 aliases. Actual current60 bind elaboration remains UNKNOWN; no compiler invoked.'))
    binding=dict(previous,state='SOURCE_ONLY_FULL_GAME_CAPTURE_WITH_STRICT_HG_DIAGNOSTICS',
        assertion_bindings_required=['full_game'],
        parent_composition_sha256=sha(parent/'composition.json'),copies_sha256=copies,
        compiled_input_binding_sha256=binding_hash,staged_binding_inputs_sha256=binding_inputs,
        build_plan_sha256=sha(out/'game-build-plan.json'),binary_sha256=None,
        publication_contract_sha256=sha(out/'publication-contract.json'),
        source_rebind_sha256=sha(out/'capture-source-rebind.json'),
        runtime_wram_equality='Parent217d9091 scoped HG WRAM restore qualified; this extended host NOT BUILT',
        native60_current_chain='Untouched; no compiler/model/worker started',
        next='Coordinator next required game build only after source ABI/mutation gate; fresh actual binary pin required; retained cpu_arm9_cache failure not waived')
    write(out/'composition.json',binding)
    write(out/'model-pin.pending.json',dict(state='PENDING_ACTUAL_NEXT_GAME_BUILD',source=binding['source'],
        composition_sha256=sha(out/'composition.json'),game_build_plan_sha256=binding['build_plan_sha256'],
        actual_compile_argv_sha256=hashlib.sha256(json.dumps(argv).encode()).hexdigest(),
        build_exit=None,binary_path=None,binary_sha256=None))
    # Extend observation/termination to>=106 without changing actor inputs,
    # restore descriptors, seeds, clocks or any existing fixed reference map.
    # Preserve the original prefix windows as controls; HG history stays85.
    native=Path('/home/user/Git/NDS_Pocket-codex-raster-colour49/build')
    paths={'inherited-mkds-heavy-ss':native/'heavy-game59',
        'inherited-mkds-race-ss':native/'scenes62/race',
        'inherited-mkds-intro-corner':native/'scenes62/corner',
        'inherited-mkds-intro-startline':native/'scenes62/startline',
        'acww-title':native/'scenes62/ac','hg-title':native/'scenes62/hg'}
    scene_plans={}
    for name,path in paths.items():
        original=json.loads((path/'runtime-command.json').read_text())
        args={a[1:].split('=',1)[0]:a.split('=',1)[1] for a in original[1:] if '=' in a}
        limit=max(106,int(args['frames']));assert limit<=256
        target=out/'future-runs'/name
        launch=[str(out/'private-game-obj/Vtb_ds_pocket')]
        for a in original[1:]:
            key=a[1:].split('=',1)[0]
            if key in ('frames','scene_capture_frames','scene_save_words','shots','savout','scene_capture_prefix'):continue
            launch.append(a)
        launch += [f'+frames={limit}',f'+scene_capture_frames={limit}',f'+scene_save_words={int(args["savsize"])//4}',
            f'+scene_capture_prefix={target}/capture/capture',f'+shots={target}/shots',f'+savout={target}/save.bin',
            '+combined_wram_restore',f'+combined_wram_expected={out}/wram-expected/{name}.hex']
        if '+root40_ldm_capture' not in launch:launch.append('+root40_ldm_capture')
        prep=path/'preparation.json'
        scene_plans[name]=dict(argv=launch,cwd=str(Path(args['imp_main']).parent),
            original_runtime_sha256=sha(path/'runtime-command.json'),
            retained_preparation_sha256=sha(prep) if prep.exists() else None,
            original_prefix_frames=int(args['frames']),frames=limit,capture_capacity=limit,
            expected_states=limit+1,expected_images=limit,
            fixed_mapping='Retained original preparation/raw-reference map; no rematching. Extended suffix has no claimed paired reference outside existing catalog coverage.',
            seed_arguments=[a for a in original if a.startswith(('+g3d_seed=','+g3d_seed_kind='))],
            state='SOURCE_ONLY_NOT_AUTHORIZED_TO_RUN')
    write(out/'scene-launch-plans.json',scene_plans)
    hg_args={a[1:].split('=',1)[0]:a.split('=',1)[1]
        for a in scene_plans['hg-title']['argv'][1:] if '=' in a}
    image=Path(hg_args['imp_main'])
    assert sha(image)==previous['scene_import_files']['hg-title']['imp_main.hex']
    words=[int(w,16)for w in image.read_bytes().split()]
    stub=(lifecycle/'sw/stateload/stateload.bin').read_bytes()
    index=int(hg_args['imp_ov'],16)
    actual=b''.join(w.to_bytes(4,'little')for w in words[index:index+len(stub)//4])
    assert actual==stub and len(stub)==4*int(hg_args['imp_stubn'],16)==548
    tables={}
    for cpu,table_word,ready in [('ARM9',4,0x02000018),('ARM7',5,0x0200001c)]:
        cursor=(words[table_word]-0x02000000)//4;ops=[]
        while words[cursor]!=0:
            op=words[cursor];count={1:3,2:3,3:3,4:4,5:3,6:4}[op]
            ops.append(words[cursor:cursor+count]);cursor+=count
        assert ops[-1]==[3,ready,1]
        tables[cpu]=dict(last_operation=ops[-1],register_block_follows_terminator=True)
        if cpu=='ARM9':
            controls=[o[2]for o in ops if o[:2]==[5,0]]
            assert controls and all(v&0x1005==0 for v in controls)
            tables[cpu]['table_control_writes']=controls
    write(out/'stub-lifecycle-binding.json',dict(actual_input_path=str(image),actual_input_sha256=sha(image),
        source_files_sha256={str(p.relative_to(out)):sha(p)for p in lifecycle.rglob('*')if p.is_file()},
        actual_stub_sha256=hashlib.sha256(actual).hexdigest(),actual_stub_bytes=548,
        source_stub_sha256=sha(lifecycle/'sw/stateload/stateload.bin'),tables=tables,
        runtime_scope='Original HG stub bytes/tables proven; individual failed cache clause remains UNKNOWN'))
    write(out/'hg-history-control-plan.json',dict(
        base_scene='hg-title',argv=[a if not a.startswith('+frames=')else '+frames=85'
            for a in scene_plans['hg-title']['argv']]+
            [f'+g3d_seed={out}/include','+g3d_seed_kind=hg193'],
        role='Separate retained HG history gate; strict failed cpu_arm9_cache predicate retained; not a new seed for ordinary named scene',
        expected_first_runtime='26 pass bits plus raw owned request/result addresses; old failure must remain explicit until classified',
        state='SOURCE_ONLY_NOT_AUTHORIZED_TO_RUN'))
    binding['scene_launch_plans_sha256']=sha(out/'scene-launch-plans.json')
    binding['stub_lifecycle_binding_sha256']=sha(out/'stub-lifecycle-binding.json')
    binding['hg_history_control_plan_sha256']=sha(out/'hg-history-control-plan.json')
    write(out/'composition.json',binding)
    pending=json.loads((out/'model-pin.pending.json').read_text())
    pending['composition_sha256']=sha(out/'composition.json')
    write(out/'model-pin.pending.json',pending)
    return binding


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent',required=True,type=Path)
    parser.add_argument('--qualified-host',required=True,type=Path)
    parser.add_argument('--out',required=True,type=Path)
    args=parser.parse_args()
    b=prepare(args.parent,args.qualified_host,args.out)
    print(json.dumps(dict(state=b['state'],source=b['source'],copies=len(b['copies_sha256']),
        compiler_or_model_runs=0),indent=2))
