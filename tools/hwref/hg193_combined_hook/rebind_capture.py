#!/usr/bin/env python3
"""Rebind the frozen capture host to exact accepted main41, not moving main."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from prepare_capture import sha,write
import check_capture

TARGET='690b22e8e528f2d55e998967a9fb62b6a82ff333'


def blob(name):
    return subprocess.check_output(['git','show',TARGET+':'+name])


def rebind(parent,out):
    parent,out=parent.resolve(),out.resolve()
    assert parent!=out and parent not in out.parents
    check_capture.check_source(parent)
    shutil.copytree(parent,out,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
    old=json.loads((parent/'composition.json').read_text())
    old_plan=json.loads((parent/'game-build-plan.json').read_text())
    changed={};production={}
    for path in (out/'snapshot/source').rglob('*'):
        if not path.is_file() or path.suffix not in ('.sv','.svh','.v','.vh','.cpp','.cc'):continue
        name=str(path.relative_to(out/'snapshot/source'))
        if name.startswith('build/'):
            assert sha(path)==sha(parent/'snapshot/source'/name)
            continue  # frozen generated observer include, not a git blob
        data=blob(name);before=sha(path)
        path.write_bytes(data);after=sha(path);production[name]=after
        if before!=after:changed[name]=dict(before=before,current=after)
    required={'rtl/arm/arm_pkg.sv','rtl/arm/arm7_ds.sv','rtl/arm/arm_cpu.sv','rtl/arm/cpu_domain.sv',
        'rtl/gpu3d/gpu3d_gxeng.sv','rtl/gpu3d/gpu3d_gxlight.sv'}
    assert set(changed)==required,changed
    added=out/'snapshot/source/rtl/arm/arm7_stm4_owner.sv';added.write_bytes(blob('rtl/arm/arm7_stm4_owner.sv'))
    production['rtl/arm/arm7_stm4_owner.sv']=sha(added)
    # These old receipt copies are not compiled overrides. Refresh their RTL
    # to the exact same current source and retain old metadata as history.
    for path in (out/'snapshot/host-observer/rtl').rglob('*.sv'):
        path.write_bytes(blob(str(path.relative_to(out/'snapshot/host-observer'))))
    argv=[a.replace(str(parent)+'/',str(out)+'/')for a in old_plan['argv']]
    argv.insert(argv.index(str(out/'snapshot/source/rtl/arm/arm7_ds.sv'))+1,str(added))
    route=out/'observed-overlay/current41_binding.sv'
    launch_guard=out/'observed-overlay/full_game_capture_contract.sv'
    if 'bind tb_ds_pocket nds_full_game_capture_contract'not in launch_guard.read_text():
        launch_guard.write_text(launch_guard.read_text()+
            '\nbind tb_ds_pocket nds_full_game_capture_contract u_full_game_capture_contract();\n')
    route.write_text('''// Exact accepted main41 route/defaults; passive assertions only.
module nds_capture41_binding;
 initial begin
  #1;
  assert($root.tb_ds_pocket.dut.ds.u_cpud.A7_STM4_META==0 &&
   $root.tb_ds_pocket.dut.ds.u_cpud.g_one.u_cpu.A7_STM4_META==0 &&
   $root.tb_ds_pocket.dut.ds.u_cpud.g_one.u_cpu.A7_EXEC_META==0 &&
   $root.tb_ds_pocket.dut.ds.u_cpud.g_one.u_cpu.g_a7ds.u_a7.STM4_META==0 &&
   $root.tb_ds_pocket.dut.ds.u_cpud.g_one.u_cpu.g_a7ds.u_a7.EXEC_META==0)
   else $fatal(1,"CAPTURE41_METADATA_MUST_REMAIN_OFF");
  assert($root.tb_ds_pocket.dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_lup.u_light.SHARED5==1 &&
   $root.tb_ds_pocket.dut.ds.g_3d.u_gpu3d.u_geom.u_eng.g_lup.u_light.MAT_PAR==1)
   else $fatal(1,"CAPTURE41_FIVE_ROUTE_REQUIRED");
  $display("CAPTURE41_ACCEPTED_SOURCE_FIVE1_METADATA0_PASS");
 end
endmodule
bind tb_ds_pocket nds_capture41_binding u_capture41_binding();
''')
    argv.append(str(route))
    plan=dict(old_plan,source=TARGET,state='SOURCE_REBOUND_CURRENT41_READY_FOR_ONE_APPROVED_BUILD',argv=argv,
        cwd=old_plan['cwd'].replace(str(parent),str(out)))
    write(out/'game-build-plan.json',plan)
    # All imported architectural lighting paths remain in the common prefix;
    # none names the retired product instance or private five-lane temporaries.
    context=(out/'include/hg193_context.svh').read_text()
    assert 'g_lup.u_light' in context and '.u_products.' not in context
    light=blob('rtl/gpu3d/gpu3d_gxlight.sv').decode()
    assert 'end else begin : g_five' in light and 'gpu3d_gxlight_five u_products' in light
    eng=blob('rtl/gpu3d/gpu3d_gxeng.sv').decode();assert '.SHARED5(MAT_PAR), .MAT_PAR(MAT_PAR)' in eng
    for path in ['rtl/arm/arm7_ds.sv','rtl/arm/arm_cpu.sv','rtl/arm/cpu_domain.sv']:
        data=blob(path).decode();assert ('STM4_META = 0' in data or "STM4_META = 1'b0" in data)
    receipt=dict(source=TARGET,parent_source=old['source'],parent_composition_sha256=sha(parent/'composition.json'),
        changed_production_files=changed,added_production_file={'rtl/arm/arm7_stm4_owner.sv':sha(added)},
        production_files_sha256=production,metadata='A7_STM4_META/A7_EXEC_META default0; actual route assertions staged',
        lighting='accepted41 g_lup.u_light.g_five.u_products; common imported architectural paths retained; private phase not reset/fabricated',
        inherited_WRAM='7506df0f positive24576+4actualfaults accepted; helper/circuit identity retained; no repeats',
        old_snapshot_receipts='Historical aeaa native60 source/compile receipts, not authority for current41 binary',
        profile_fields=60,default085_reconstruction='unchanged',helpers_and_import='byte identical to frozen parent',
        binary_sha256=None)
    for path in ['include/runtime_combined_wram.svh','include/hg193_combined_drain.svh',
        'include/hg193_combined_hook.svh','include/hg193_context.svh','include/hg193_sd_pair.svh']:
        assert sha(out/path)==sha(parent/path),path
    write(out/'current41-source-rebind.json',receipt)
    pin=out/'include/hg193_shared_model_binding.svh'
    pin.write_text(pin.read_text().replace(old['source'],TARGET))
    folders=['snapshot','include','observed-overlay','capture-bindings','wram-expected','lifecycle-source']
    inputs={str(p.relative_to(out)):sha(p)for folder in folders for p in (out/folder).rglob('*')
        if p.is_file() and p.name!='hg193_shared_model_binding.svh'}
    value=hashlib.sha256(json.dumps(inputs,sort_keys=True).encode()).hexdigest()
    pin.write_text(pin.read_text().replace(old['compiled_input_binding_sha256'],value))
    copies={str(p.relative_to(out)):sha(p)for folder in folders for p in (out/folder).rglob('*')if p.is_file()}
    binding=dict(old,source=TARGET,copies_sha256=copies,staged_binding_inputs_sha256=inputs,
        assertion_bindings_required=['full_game','current41'],
        compiled_input_binding_sha256=value,build_plan_sha256=sha(out/'game-build-plan.json'),
        current41_source_rebind_sha256=sha(out/'current41-source-rebind.json'),binary_sha256=None)
    for name in ['scene-launch-plans.json','hg-history-control-plan.json']:
        text=(parent/name).read_text().replace(str(parent)+'/',str(out)+'/')
        (out/name).write_text(text)
    binding['scene_launch_plans_sha256']=sha(out/'scene-launch-plans.json')
    binding['hg_history_control_plan_sha256']=sha(out/'hg-history-control-plan.json')
    aliases=json.loads((out/'capture-source-rebind.json').read_text())
    aliases['current_alias_source_hashes']={p:sha(out/p)for p in aliases['current_alias_source_hashes']}
    aliases['production_source']=TARGET
    write(out/'capture-source-rebind.json',aliases)
    binding['source_rebind_sha256']=sha(out/'capture-source-rebind.json')
    write(out/'composition.json',binding)
    write(out/'model-pin.pending.json',dict(state='PENDING_ACTUAL_NEXT_GAME_BUILD',source=TARGET,
        composition_sha256=sha(out/'composition.json'),game_build_plan_sha256=binding['build_plan_sha256'],
        actual_compile_argv_sha256=hashlib.sha256(json.dumps(argv).encode()).hexdigest(),
        build_exit=None,binary_path=None,binary_sha256=None))
    check_capture.check_source(out)
    return receipt


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--parent',required=True,type=Path)
    p.add_argument('--out',required=True,type=Path);a=p.parse_args()
    r=rebind(a.parent,a.out);print(json.dumps({k:r[k]for k in ['source','changed_production_files','metadata','lighting']},indent=2))
