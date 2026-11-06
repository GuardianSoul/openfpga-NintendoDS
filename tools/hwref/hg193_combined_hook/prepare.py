#!/usr/bin/env python3
"""Source-only combined import overlay for exact main aeaa0cb3/ROM65.

Never compiles, runs, exports, edits production, or pins a model implicitly.
The unpinned generated model contract rejects any requested seed immediately.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
TARGET = 'aeaa0cb386d2fbd6f8d2505f8033015956da54b5'
PREVIOUS_TARGET = 'c445c240e4138f347ea256d98f9f20e3eca68e50'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def source(name):
    return subprocess.check_output(['git', 'show', TARGET + ':' + name])


def predicates():
    root = 'dut'
    cpu = 'dut.ds.u_cpud'
    groups = {}
    groups['cpu_arm9_cache'] = ['arm9_mem_publication_ready()',
        f'({cpu}.g_one.u_cpu.u_mem9.ctrl & 32\'h00001005)==0',
        f'{cpu}.g_one.u_cpu.u_core.fetch_pc[0]>=32\'h02000000+32\'(4*imp_ov)',
        f'{cpu}.g_one.u_cpu.u_core.fetch_pc[0]<32\'h02000000+32\'(4*(imp_ov+imp_stubn))']
    p7 = cpu + '.g_a7c.u_p7'
    groups['cpu_arm7_ports'] = [f'!{p7}.{name}' for name in
        'i_req d_req fl_v xs_busy wb_v rp_v busy su_v w_req x_req f_req'.split()] + [f'{p7}.sf_n==0']
    groups['cpu_domain_requests'] = [f'!{cpu}.{name}' for name in
        'c_b9_req c_x7_req c_x7_stores c_f7_req b9_req x7_req x7_stores f7_req'.split()]
    fabric = 'dut.ds.u_fab'
    groups['fabric'] = [f'{fabric}.st=={fabric}.S_IDLE',
        f'{fabric}.sd_st=={fabric}.SD_IDLE', f'{fabric}.ra_st=={fabric}.RA_IDLE'] + [
        f'!{fabric}.{name}' for name in 'ld4_req ld4_active ld4_pending'.split()]
    groups['internal_wram'] = [f'!dut.ds.u_wram.{name}' for name in 'a_req a_ok b_req b_done'.split()]
    eng='dut.ds.g_3d.u_gpu3d.u_geom.u_eng'
    rom=eng+'.g_romx.u_rom.g_a_dict.u_a'
    groups['rom65_phase_caller']=[f'{eng}.ROM_DICT==1',f'{eng}.a_nx==gpu3d_gxu_pkg::NX_DISP',
        f'{eng}.g_romx.u_rom.A_DICT==1',f'!{rom}.rst',f'!{rom}.reset_q',f'!{rom}.ph',
        f'{rom}.tg=={rom}.tq',f'{rom}.index_q==={rom}.index_mem[{rom}.addr]',
        f'!{eng}.ev_q',f'!{eng}.mrd_main_req',f'{eng}.upc_n==={eng}.upc',f'{rom}.addr==={eng}.upc']
    ps = 'dut.psram'
    groups['main_psram'] = [f'!{ps}.{name}' for name in
        's_req s_ack s_rvalid busy bw_c blk strm m_busy req_valid rsp_valid write_en burst_en config_en g_active g_last_pending'.split()] + [
        f'{ps}.out_n==0', f'{ps}.g_count==0', f'{ps}.stream_left==0',
        f'{ps}.req_t=={ps}.req_seen', f'{ps}.done_t=={ps}.done_seen',
        f'{ps}.state=={ps}.IDLE', f'{ps}.cbusy==0', f'{ps}.avail==0']
    groups['sdram_ports'] = []
    for path in ['x_vram', 'x_sr', 'x_vrd', 'g_ring.x_rg']:
        p = root + '.' + path
        groups['sdram_ports'] += [f'!{p}.{name}' for name in
            'busy s_req s_ack s_rvalid m_valid m_take f_valid'.split()] + [
            f'{p}.req_t=={p}.req_s', f'{p}.req_s=={p}.take_t', f'{p}.take_t=={p}.take_seen']
    for path in ['bp_bridge', 'bp_cache']:
        p = root + '.' + path
        groups['sdram_ports'] += [f'!{p}.{name}' for name in
            'busy c_valid c_ready r_valid m_valid m_take'.split()] + [
            f'{p}.req_t=={p}.req_s', f'{p}.req_s=={p}.take_t', f'{p}.take_t=={p}.take_seen']
    groups['fifo_ownership'] = []
    for path in ['words_sys.words', 'words_bus.words', 'x_vwr', 'wfifo']:
        p = root + '.' + path
        groups['fifo_ownership'] += [f'!{p}.wr', f'!{p}.valid', f'{p}.wempty',
            f'{p}.wbin=={p}.pbin', f'{p}.wbin=={p}.rbin',
            f'{p}.wgray=={p}.wgray_r', f'{p}.rgray=={p}.rgray_w', f'{p}.pgray=={p}.pgray_w']
    s = 'dut.sdram'
    groups['sdram_controller_and_return'] = [f'{s}.m_valid==0', f'{s}.m_take==0',
        f'{s}.w_valid==0', f'!{s}.g_v', f'{s}.own_r=={s}.own_w', f'!{s}.r_valid',
        f'{s}.mc.st=={s}.mc.S_IDLE', f'{s}.mc.rd_tag==0', f'{s}.mc.rd_end==0',
        f'{s}.mc.cmd=={s}.mc.C_NOP', f'{s}.mc.p_cmd=={s}.mc.C_NOP',
        f'!{s}.mc.dq_oe', f'!{s}.mc.p_dq_oe', 'sdram_chip.beat_valid==0', '!sdram_chip.drive']
    groups['shell_capture_cart'] = [f'!dut.{n}' for n in
        'mr_req mr_ack mr_rvalid vm_req sr_req cr_req cap_busy cw_valid rg_wreq rg_rreq rg_rvalid bw_valid vw_req f_valid fc_busy fc_send fc_recv sh_valid bridge_wr bridge_rd'.split()
        if n not in ('bridge_wr', 'bridge_rd')] + ['!bridge_wr', '!bridge_rd', 'dut.bw_empty',
        'dut.rg_k==0', '!dut.x_cart.s_req', '!dut.x_cart.c_valid', '!dut.x_cart.wait_b',
        '!dut.x_cart.ack_b', '!dut.x_cart.s_rvalid', 'dut.keys==0',
        'dut.A9_SOLO==5', 'dut.CPU_FAST==0', 'dut.SHELL_CPU==2', 'dut.DIAG==0',
        'dut.G3D_STORAGE_PAIR==1', 'dut.A7_WRAM==1', 'dut.cache_ready', '!dut.cache_fail',
        'dut.A7_VRAM_IO_READ_SIDE==1', 'dut.VRAM_CUT_WRITE_TURN==1']
    return groups


def bind_wram_inputs(out):
    catalog_name='docs/results/census23-games-20261101/reference23-ready.json'
    catalog=json.loads(source(catalog_name))
    native=Path('/home/user/Git/NDS_Pocket-codex-raster-colour49/build')
    paths={
        'inherited-mkds-heavy-ss':native/'heavy-game59/staged/inputs/imp_sram.hex',
        'inherited-mkds-race-ss':native/'scenes62/race/inputs/imp_sram.hex',
        'inherited-mkds-intro-corner':native/'scenes62/corner/inputs/imp_sram.hex',
        'inherited-mkds-intro-startline':native/'scenes62/startline/inputs/imp_sram.hex',
        'acww-title':native/'scenes62/ac/inputs/imp_sram.hex',
        'hg-title':native/'scenes62/hg/inputs/imp_sram.hex'}
    result={}
    expected=out/'wram-expected'
    expected.mkdir(exist_ok=True)
    for row in catalog['scenes']:
        name=row['name'];root=Path(row['path']);ready=(root/'ready.json').read_bytes()
        assert sha(ready)==row['ready_sha256'],name
        record=json.loads(ready);private=(root/'exp/wram7.bin').read_bytes();shared=(root/'exp/swram.bin').read_bytes()
        assert len(private)==65536 and len(shared)==32768
        assert sha(private)==record['export_sha256']['wram7.bin']
        assert sha(shared)==record['export_sha256']['swram.bin']
        existing=paths[name];image=existing.read_bytes();words=[int(w,16) for w in image.split()]
        original=private+shared
        assert len(words)==24576 and all(words[i]==int.from_bytes(original[4*i:4*i+4],'little') for i in range(24576)),name
        (expected/(name+'.hex')).write_bytes(image)
        result[name]=dict(ready_path=str(root/'ready.json'),ready_sha256=sha(ready),
            private_export_path=str(root/'exp/wram7.bin'),private_sha256=sha(private),
            shared_export_path=str(root/'exp/swram.bin'),shared_sha256=sha(shared),
            existing_imp_sram_path=str(existing),existing_imp_sram_sha256=sha(image),
            expected_file='wram-expected/'+name+'.hex',expected_sha256=sha(image),
            original_little_endian_bytes_sha256=sha(original),words_verified=24576,
            private_words=16384,shared_words=8192,runtime_internal_readback='UNKNOWN_UNTIL_SHARED_CHANGED_MODEL')
    assert set(result)==set(paths)
    (out/'wram-input-contract.json').write_text(json.dumps(dict(
        state='SIX_EXISTING_EXPORT_AND_INPUT_BYTE_MAPS_VERIFIED_RUNTIME_WRAM_EQUALITY_UNKNOWN',
        catalog_source=catalog_name,catalog_sha256=sha(source(catalog_name)),
        hierarchy={'private':'dut.ds.u_wram.u_private.mem[0:16383]','shared':'dut.ds.u_wram.u_shared.mem[0:8191]'},
        mapping='imp_sram[0:16383] from wram7.bin LE32; imp_sram[16384:24575] from swram.bin LE32',
        scenes=result,no_input_replacement=True,no_export_or_model=True),indent=2)+'\n')
    return result


def prepare(out):
    assert subprocess.check_output(['git', 'rev-parse', TARGET], text=True).strip() == TARGET
    out.mkdir(parents=True, exist_ok=True)
    files = ['sim/pocket_ds/tb_ds_pocket.sv', 'sim/pocket_ds/run.py', 'sim/ds/state_import.py',
        'sw/stateload/stateload.s', 'sw/stateload/stateload.bin', 'sw/boot/import.s',
        'sim/pocket_ds/runtime_import_arm9_mem_ready.svh', 'sim/pocket_ds/sim_prims_ds.sv',
        'rtl/pocket/core_top_ds.sv', 'rtl/pocket/nds_psram.sv', 'rtl/pocket/nds_sdram_bus.sv',
        'rtl/pocket/nds_sdram_mc.sv', 'rtl/pocket/nds_cdc.sv', 'rtl/pocket/nds_x2b.sv',
        'rtl/arm/cpu_domain.sv', 'rtl/arm/arm_cpu.sv', 'rtl/arm/arm9_mem.sv',
        'rtl/arm/arm7_ds.sv', 'rtl/arm/arm7_wram.sv', 'rtl/ds/nds_ram.sv', 'rtl/ds/nds_arm7_port.sv', 'rtl/ds/nds_fabric.sv', 'rtl/ds/nds_top.sv',
        'sim/phase1/cram_model.sv', 'sim/phase1/sdram_chip_model.sv', 'sim/phase1/sram_model.sv',
        'rtl/gpu3d/gpu3d_gxrom_adict.sv',
        'docs/results/geometry-rom-dictionary65-proof-20261102/manifest.json',
        'docs/results/geometry-rom-dictionary65-proof-20261102/provenance.json']
    sources = {name: source(name) for name in files}
    for name, data in sources.items():
        path = out / 'source' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    # Existing accepted-history translator, unchanged. Its old exact source
    # binding remains the control; it is NOT relabeled as main aeaa approval.
    spec = importlib.util.spec_from_file_location('history_prepare', HERE.parent / 'hg193_sd_pair/prepare.py')
    history = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(history)
    old_binding = json.loads((history.HERE / 'binding.json').read_text())
    deltas = {}
    for name, bound in old_binding['production'].items():
        data = source(name)
        sources[name] = data
        if sha(data) != bound['sha256']:
            deltas[name] = dict(qualified_sha256=bound['sha256'], target_sha256=sha(data))
    assert set(deltas) == {'rtl/gpu3d/gpu3d_gxvfin.sv','rtl/ds/nds_gpu3d.sv',
        'rtl/gpu3d/gpu3d_geom.sv','rtl/gpu3d/gpu3d_gxeng.sv','rtl/gpu3d/gpu3d_gxrom_ux.sv'}, deltas
    package = out / 'include'
    history.prepare(package)
    (package/'preparation.json').rename(package/'history-control-preparation.json')
    original_profile = (package / 'hg193_profile.svh').read_bytes()
    (package / 'hg193_profile58_control.svh.txt').write_bytes(original_profile)
    (package / 'hg193_profile.svh').write_text(' assert_hg193_shared_model_binding();\n')
    (package / 'hg193_shared_model_binding.svh').write_text(
        '`ifndef COMBINED_SHARED_MODEL_BINDING_SVH\n`define COMBINED_SHARED_MODEL_BINDING_SVH\n'
        '// INTENTIONALLY UNPINNED. Coordinator must bind exact shared build/profile and launch hash.\n'
        'task automatic assert_hg193_shared_model_binding;\n'
        ' $fatal(1,"HG193 combined shared model/profile not pinned; source prep only");\nendtask\n`endif\n')
    (package / 'runtime_import_arm9_mem_ready.svh').write_bytes(sources['sim/pocket_ds/runtime_import_arm9_mem_ready.svh'])
    (package / 'hg193_combined_hook.svh').write_bytes((HERE / 'hook.svh').read_bytes())
    (package / 'runtime_combined_wram.svh').write_bytes((HERE / 'wram.svh').read_bytes())
    groups = predicates()
    drain = []
    for group, terms in groups.items():
        drain += [f'function automatic bit hg193_drain_{group}();', ' return ' + ' &&\n  '.join(terms) + ';', 'endfunction']
    drain += ['function automatic bit hg193_combined_transport_drained();',
              ' return ' + ' &&\n  '.join(f'hg193_drain_{name}()' for name in groups) + ';', 'endfunction',
              'task automatic assert_hg193_combined_drained;',
              ' assert(hg193_combined_held)else $fatal(1,"HG193 CPU/system clocks not held");']
    for group in groups:
        drain += [f' assert(hg193_drain_{group}())else $fatal(1,"HG193 combined drain: {group}");']
    drain += ['endtask', '']
    (package / 'hg193_combined_drain.svh').write_text('\n'.join(drain))
    tb = sources['sim/pocket_ds/tb_ds_pocket.sv'].decode()
    external_wram = '        for (integer w = 0; w < 32\'h6000; w++) begin u_sram.mem[2 * w] = imp_sram[w][15:0]; u_sram.mem[2 * w + 1] = imp_sram[w][31:16]; end'
    wram = ('\n`ifdef COMBINED_STATE_IMPORT\n'
        '        if(combined_wram_present)combined_restore_wram();\n`endif')
    assert tb.count(external_wram)==1
    tb=tb.replace(external_wram,external_wram+wram)
    original = ('        repeat (4000) @(posedge dut.clk_sys);\n'
                '        while (!(dut.line_start && dut.vcount == imp_vc)) @(posedge dut.clk_sys);')
    assert tb.count(original) == 1
    guarded = ('`ifdef HG193_COMBINED_HOOK\n'
        '        if(hg193_combined_present)begin\n'
        '            repeat(3999)@(posedge dut.clk_sys);\n'
        '            @(negedge dut.clk_sys);\n'
        '            while(!(dut.line_start && dut.vcount==imp_vc))begin\n'
        '                @(posedge dut.clk_sys);@(negedge dut.clk_sys);\n'
        '            end\n'
        '            hg193_combined_publish();\n'
        '            @(posedge dut.clk_sys);\n'
        '        end else begin\n`endif\n' + original +
        '\n`ifdef HG193_COMBINED_HOOK\n        end\n`endif')
    tb = tb.replace(original, guarded)
    assert tb.count('endmodule') == 1
    includes='`include "runtime_combined_wram.svh"\n`include "hg193_combined_hook.svh"\n'
    tb = tb.replace('endmodule', includes+'endmodule')
    overlay = out / 'overlay/sim/pocket_ds/tb_ds_pocket.sv'
    overlay.parent.mkdir(parents=True, exist_ok=True)
    overlay.write_text(tb)
    # Structural default-branch check, not a claim of compiler preprocessing.
    assert tb.replace(guarded, original).replace(wram,'').replace(includes,'') == sources['sim/pocket_ds/tb_ds_pocket.sv'].decode()
    wram_contract=bind_wram_inputs(out)
    manifest = dict(state='SOURCE_PREPARED_SHARED_MODEL_UNPINNED_RUNTIME_NOT_RUN', target_source=TARGET,
        previous_source=PREVIOUS_TARGET,source_rebind='Explicit c445→aeaa: accepted ROM65 ports/caller/phase guard; no old model qualification relabeled',
        source_sha256={name: sha(data) for name, data in sources.items()},
        history_control='accepted638 logical history; component74e00e97 is scoped old-source control',
        changed_gpu_sources=deltas, predicates=groups, predicate_count=sum(map(len, groups.values())),
        ordering=['load main/VRAM/SRAM and accepted638 private/shared internal WRAM mirrors with readback', 'both stateload ready words', '3999SYS edges + pre-release falling half-cycle',
                  'same-line FAST phase alignment', 'hold all10clock views at captured levels', 'assert CPU/cache/fabric/transport + GPU drains',
                  'publish/read back GX history without advancing time', 'release clocks', 'same original release SYS edge',
                  'restore overlay except stub + low block', 'KEYINPUT release + imp_stub_pend', '400SYS wait',
                  'stub tails invalidate caches/restore CP15/MOVS', 'stub bytes restored only after first ARM9 retirement outside stub'],
        default_branch_reconstruction_sha256=sha(sources['sim/pocket_ds/tb_ds_pocket.sv']),
        generated_sha256={str(p.relative_to(out)): sha(p.read_bytes())
            for folder in ('source', 'include', 'overlay','wram-expected') for p in (out / folder).rglob('*') if p.is_file()},
        dependencies=['coordinator exact shared changed-model/profile/compiled-input/model-hash pin; placeholder rejects requested seed',
            'current gxvfin signed-Z arithmetic delta and acceptedROM65 must be in shared qualification; storage paths unchanged by inspected deltas',
            'actual all-system predicates must hold at SAME accepted release edge; no readiness polling or extra line permitted',
            'force/release backend + SYS/FAST phase alignment + default-before/full-import ordering compile/runtime controls',
            'ROM65 actual M-captured address/index and post-deposit caller/phase preservation must pass on shared model; no phase reset or forced decoder state'],
        not_run=['compiler', 'model', 'game', 'first-use', 'export', 'probe'], workers=0,
        frame_bounds=dict(frames=85, release=7, first_settled_raw=11, first_settled_reference=5))
    manifest['wram_input_contract']={name:row['existing_imp_sram_sha256'] for name,row in wram_contract.items()}
    manifest['independent_enables']={'all_scene_wram':'COMBINED_STATE_IMPORT +combined_wram_restore +combined_wram_expected=bound-scene.hex',
        'HG_history':'HG193_COMBINED_HOOK +g3d_seed=retained-hg193 +g3d_seed_kind=hg193',
        'negative_controls':'COMBINED_WRAM_FAULTS +combined_wram_fault=missing-private|missing-shared|wrong-private|wrong-shared'}
    audit = json.loads((HERE.parents[2] / 'docs/results/hg-prior-history-host-audit-20261102/dependency.json').read_text())
    manifest['required_unchanged_runtime_inputs_sha256'] = {
        name: item['accepted'] for name, item in audit['common_recorded_runtime_hashes'].items()}
    manifest['shared_model_pin_contract'] = dict(
        source=TARGET, model_sha256=None, compiled_inputs_sha256=None, full_profile=None,
        required_routes={'A7_VRAM_IO_READ_SIDE': 1, 'VRAM_CUT_WRITE_TURN': 1},
        requirement='Coordinator supplies exact shared build manifest/full profile, validates all actual compiled source hashes and generated overlay/include/input hashes, then freezes actual binary hash in launcher before seed execution; no placeholder bypass.',
        geometry_rom_phase='ROM65 source/caller paths explicitly joined at aeaa; combined hook phase/addr preservation runtime NOT YET QUALIFIED')
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    result = prepare(parser.parse_args().out.resolve())
    print(json.dumps({k: result[k] for k in ('state', 'target_source', 'predicate_count', 'changed_gpu_sources', 'dependencies')}, indent=2))
