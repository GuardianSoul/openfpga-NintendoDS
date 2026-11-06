#!/usr/bin/env python3
"""Source-qualified host mapping of the captured clean MKDS GX context.

Adapts the established HG context mapping to captured dirtyClipMatrix=1
and the current clip word banks. This emits import data, never a savestate,
reference timing repair, synthetic SWAP or rendering/device API call.
The consumer separately proves stopped clocks, full-system drain and first
use. The retained atomic capture hash and current layout are mandatory.
"""
import argparse
import gzip
import json
from pathlib import Path
import struct

import runtime_gx_schema as codec

SCHEMA = 'nds-clean-gx-native-context-v1'
NATIVE_TARGET = '46900836+4bedd989'
BINDING = Path(__file__).with_name('runtime_gx_context.sources.json')


def word(v):
    return int(v) & 0xffffffff


def source_binding(source):
    expected = json.loads(BINDING.read_text())
    codec.require(expected['source'] == NATIVE_TARGET, 'wrong mapping source')
    for name, digest in expected['files_sha256'].items():
        codec.require(codec.digest((source / name).read_bytes()) == digest,
                      'unqualified mapping source: ' + name)
    return expected


def outcode(position):
    """Frozen597 g_pu.ocode, with the signed 33-bit comparisons explicit."""
    x, y, z, w = position
    weak = strong = 0
    for axis, c in enumerate((x, y, z)):
        upper, lower = c - w, c + w
        weak |= int(upper > 0) << axis
        weak |= int(lower < 0) << (axis + 3)
        strong |= int(axis != 2 and upper >= 7) << axis
        strong |= int(lower < -6) << (axis + 3)
    if not all(-(1 << 29) <= v < (1 << 29) for v in position):
        strong = 0
    return (strong << 6) | weak


def build(seed, source):
    binding = source_binding(source)
    codec.require(seed['schema'] == codec.SCHEMA and seed['target_core'] == codec.TARGET,
                  'wrong clean context capsule or target')
    codec.require(seed == codec.seal(seed), 'portable digest differs')
    codec.require(seed['ready_for_context_deposit'], 'context capsule not ready for scoped deposit')
    c = seed['current_context']
    expected_fields = set(codec.CONTEXT) | {'TempVertexBuffer', 'LastStripPolygonIndex', 'ZeroDotWLimit'}
    codec.require(set(c) == expected_fields, 'unsupported or missing current_context field')
    # No invented continuation translator: only the captured completed, separate quad.
    exact = {'NumCommands': 0, 'CurCommand': 0, 'ParamCount': 0, 'TotalParams': 0,
             'ExecParamCount': 0, 'NumPushPopCommands': 0, 'NumTestCommands': 0,
             'PolygonMode': 1, 'VertexNum': 4, 'VertexNumInPoly': 0,
             'NumConsecutivePolygons': 1, 'NumOpaquePolygons': 0,
             'LastStripPolygonIndex': None, 'ClipMatrixDirty': True,
             'GeometryEnabled': True, 'RenderingEnabled': True, 'AbortFrame': False}
    for name, value in exact.items():
        codec.require(c[name] == value, 'unsupported context: ' + name)
    codec.require(seed['quiescent_controls'] == dict(CycleCount=0, VertexPipeline=0,
                  NormalPipeline=0, PolygonPipeline=0, VertexSlotCounter=0,
                  VertexSlotsFree=1, NumVertices=0, NumPolygons=0, FlushRequest=0),
                  'unsupported active timing or current-bank state')
    codec.require(seed['current_bank'] == dict(index=1, vertices=[], polygons=[], flush_request=0),
                  'unsupported current bank')
    codec.require(all(v == dict(entries=[], occupied=0) for v in seed['queues'].values())
                  and set(seed['queues']) == {'CmdFIFO', 'CmdPIPE', 'CmdStallQueue'},
                  'unsupported queued command')
    codec.require(0 <= c['PosMatrixStackPointer'] < 64 and
                  c['ProjMatrixStackPointer'] in (0, 1) and c['TexMatrixStackPointer'] in (0, 1),
                  'unsupported stack pointer')
    codec.require(c['GXStat'] & ~0xc0008002 == 0, 'unsupported stored GXSTAT bits')
    codec.require(0 <= c['ZeroDotWLimit'] < (1 << 24), 'unsupported zero-dot width')
    for name, (fmt, n) in codec.CONTEXT.items():
        values = [c[name]] if n == 1 else c[name]
        codec.require(isinstance(values, list) and len(values) == n, 'bad field shape: ' + name)
        # The qualified codec is the type/width authority, including bools.
        try:
            struct.pack('<' + fmt * n, *values)
        except (struct.error, TypeError):
            raise ValueError('bad typed context: ' + name) from None
    rf, state, coverage = {}, {}, {}

    def put(address, values):
        if not isinstance(values, list):
            values = [values]
        for i, v in enumerate(values):
            key = f'{address+i:03x}'
            codec.require(key not in rf, 'overlapping RF mapping: ' + key)
            rf[key] = word(v)

    def reg(path, value):
        codec.require(path not in state, 'duplicate native path: ' + path)
        state[path] = value

    def cover(names, meaning):
        for name in names.split():
            codec.require(name not in coverage, 'duplicate coverage: ' + name)
            coverage[name] = meaning

    for name, base in [('ProjMatrix', 0x000), ('PosMatrix', 0x010), ('VecMatrix', 0x020),
                       ('TexMatrix', 0x030), ('ClipMatrix', 0x040), ('ProjMatrixStack', 0x0b0),
                       ('TexMatrixStack', 0x0c0), ('PosMatrixStack', 0x400), ('VecMatrixStack', 0x600)]:
        put(base, c[name]); cover(name, f'RF {base:03x}; cached mirrors below')
    for name, base in [('MatrixMode', 0x0d0), ('PolygonMode', 0x0d1), ('PolygonAttr', 0x0d2),
                       ('CurPolygonAttr', 0x0d3), ('TexParam', 0x0d4), ('TexPalette', 0x0d6),
                       ('PosMatrixStackPointer', 0x0d7), ('VertexNumInPoly', 0x0d8)]:
        put(base, c[name]); cover(name, f'RF {base:03x}; cached mirrors below')
    tm = c['TexParam'] >> 30
    alpha = (c['CurPolygonAttr'] >> 16) & 31
    trt = int(((c['TexParam'] >> 26) & 7) in (1, 6)); tra = int(0 < alpha < 31)
    for a, v in {0x0d5: tm, 0x0d9: c['NumConsecutivePolygons'] & 1,
                 0x0da: 4, 0x0db: 0, 0x0dd: seed['predecessor_flush_attributes'],
                 0x0de: 0, 0x0df: 0, 0x0e0: 0x200, 0x0e1: int(c['UseShininessTable']),
                 0x0e2: trt, 0x0e3: tra, 0x0e4: 0}.items():
        put(a, v)
    cover('NumConsecutivePolygons', 'RF 0d9 and both front/PU parity carriers; no strip continuation')
    cover('VertexNum', 'require 4: software cumulative submitted vertices, NOT native current-bank NV')
    cover('LastStripPolygonIndex', 'require NULL: RF LSREUSE=0, PU lr=0/cs=0; no reused pair')
    put(0x148, c['CurVertex']); put(0x14b, [(v << 12) | 0xfff for v in c['VertexColor']])
    put(0x14e, c['RawTexCoords']); put(0x150, c['TexCoords']); put(0x152, c['Normal'])
    cover('CurVertex VertexColor RawTexCoords TexCoords Normal', 'signed RF words and FF attribute/vector mirrors')
    for name, base in [('MatDiffuse', 0x158), ('MatAmbient', 0x15b),
                       ('MatSpecular', 0x15e), ('MatEmission', 0x161)]:
        put(base, [v << 9 if name == 'MatAmbient' else v for v in c[name]])
        cover(name, f'RF {base:03x}, lighting cache and derived per-light products')
    put(0x167, [c['Viewport'][k] for k in (0, 3, 4, 5)])
    cover('Viewport', 'RF 167..16a and fin.sn_vp=[Viewport0,3,4,5]; unused complementary bounds retained in seed')
    put(0x16b, [0x200 + 16*k for k in range(6)])
    put(0x180, c['ShininessTable']); put(0x278, c['PosTestResult'])
    vx, vy, vz = [v & 0xffff for v in c['VecTestResult']]
    put(0x27c, [vx | (vy << 16), vz])
    cover('ShininessTable UseShininessTable', 'RF 180..1ff/0e1 and four light shininess memories/ut')
    cover('PosTestResult VecTestResult', 'RF 278..27b; packed XY at 27c, Z at 27d (both RF copies below 400)')
    for i in range(4):
        b = 0x100 + 16*i
        values = c['LightDirection'][3*i:3*i+3] + [c['SpecRecip'][i]] + c['LightColor'][3*i:3*i+3]
        for material, shift in [('MatDiffuse', 0), ('MatSpecular', 0), ('MatAmbient', 9)]:
            values += [(c[material][k]*c['LightColor'][3*i+k]) << shift for k in range(3)]
        put(b, values)
        for k, v in enumerate(values): reg(f'u_eng.g_lup.u_light.lt[{i}][{k}]', word(v) & 0xfffff)
        for k in range(3): reg(f'u_eng.g_lup.u_light.light_color[{i}][{k}]', c['LightColor'][3*i+k])
        for k, v in enumerate(c['ShininessTable']): reg(f'u_eng.g_lup.u_light.g_sh[{i}].u_sh.mem[{k}]', v)
    cover('LightDirection SpecRecip LightColor', 'RF 100+16*light; low20 light cache including captured reciprocal')
    for k, v in enumerate(c['VecMatrix']): reg(f'u_eng.g_lup.u_light.vec[{k}]', word(v) & 0x7fffff)
    for name, values in [('mdif_cache', c['MatDiffuse']), ('mamb_cache', c['MatAmbient']),
                         ('mspe_cache', c['MatSpecular']), ('memi', c['MatEmission'])]:
        for k, v in enumerate(values): reg(f'u_eng.g_lup.u_light.{name}[{k}]', v)
    reg('u_eng.g_lup.u_light.lmask', c['CurPolygonAttr'] & 15)
    reg('u_eng.g_lup.u_light.ut', int(c['UseShininessTable']))
    for k in range(3):
        reg(f'u_eng.at_v[{k}]', c['CurVertex'][k] & 0xffff)
        reg(f'u_eng.g_ff.at_c[{k}]', c['VertexColor'][k])
    reg('u_eng.at_m', tm)
    for k in range(2):
        reg(f'u_eng.g_ff.at_t[{k}]', c['TexCoords'][k] & 0xffff)
        reg(f'u_eng.g_ff.raw_t[{k}]', c['RawTexCoords'][k] & 0xffff)
        generated = (sum(c['CurVertex'][j] * c['TexMatrix'][4*j+k] for j in range(3)) >> 24) + c['RawTexCoords'][k]
        reg(f'u_eng.g_ff.gen_t[{k}]', generated & 0xffff)
        for j in range(4): reg(f'u_eng.g_ff.tcm[{k}][{j}]', word(c['TexMatrix'][4*j+k]))
    for lane in range(4):
        rows = {k: c['ClipMatrix'][4*k+lane] for k in range(4)}
        rows.update({16+k: c['PosMatrix'][4*lane+k] for k in range(4)})
        if lane < 2:
            rows.update({4+k: c['TexMatrix'][4*k+lane] for k in range(3)})
            rows.update({7: c['RawTexCoords'][lane] << 12, 8: c['TexMatrix'][12+lane]})
        for row, v in rows.items(): reg(f'u_eng.g_vx.g_lane[{lane}].u_vm.mem[{row}]', word(v))
    reg('u_eng.dirty', int(c['ClipMatrixDirty'])); reg('u_eng.load_mode', c['MatrixMode'])
    reg('u_eng.g_l44_read.proj_i', sum(int(v == (4096 if k//4 == k%4 else 0)) << k for k, v in enumerate(c['ProjMatrix'])))
    reg('u_eng.g_bw.pattr', c['PolygonAttr']); reg('u_eng.g_pu.ccattr', c['CurPolygonAttr'])
    for name, value in {'pm': 1, 'vn': 0, 'nc': c['NumConsecutivePolygons'] & 1, 'lr': 0, 'cs': 0}.items():
        reg('u_eng.g_pu.' + name, value)
    codec.require(len(c['TempVertexBuffer']) == 4, 'unsupported temporary vertex count')
    for g, v in enumerate(c['TempVertexBuffer']):
        codec.require(set(v) == set(codec.VERTEX), 'unsupported temporary vertex field')
        codec.require(not v['Clipped'] and v['FinalPosition'] == [0, 0] and
                      v['FinalColor'] == [0, 0, 0] and v['HiresPosition'] == [0, 0],
                      'unsupported finalized/clipped temporary vertex')
        # Groups at VNIP=0 are dead until overwritten. Keep raw captured data;
        # derived finish words are neutral, not invented rendered vertices.
        words = v['Position'] + v['Color'] + [v['Position'][3] & 0xffffff] + v['TexCoords'] + [0]*6
        put(0x200+16*g, words)
        reg(f'u_eng.g_pu.s[{g}]', g); reg(f'u_eng.g_pu.pl[{g}]', g)
        oc = outcode(v['Position'])
        reg(f'u_eng.g_pu.oc[{g}]', oc); reg(f'u_eng.u_voc.mem[{g}]', oc)
        for name, component in [('cpx', 0), ('cpy', 1), ('cpw', 3)]:
            reg(f'u_eng.g_pu.{name}[{g}]', word(v['Position'][component]))
        for k, w in enumerate(words):
            reg(f'u_eng.g_fu.u_fin.g_snapshot_word[{k}].u_word.mem[{g}]',word(w))
            for port in range(4): reg(f'u_eng.g_fu.u_fin.g_gc[{port}].u_g.mem[{16*g+k}]', word(w))
            # Current qualified clip banks keep words0..6,8,9 twice,
            # addressed by group; old18 full-group read mirrors are gone.
            if k in [0,1,2,3,4,5,6,8,9]:
                bank=k if k<7 else k-1
                for port in ['u_out','u_in']:reg(f'u_eng.g_cl.u_clip.g_word[{bank}].{port}.mem[{g}]',word(w))
    cover('TempVertexBuffer', 'raw slots 0..3 and all group mirrors; finalized fields must be zero; VNIP=0 forces all slots overwritten')
    fin = {'sn_texpal': c['TexPalette'], 'sn_wbuf': (seed['predecessor_flush_attributes'] >> 1) & 1,
           'sn_trt': trt, 'sn_tra': tra, 'sn_cattr': c['CurPolygonAttr'], 'sn_texp': c['TexParam']}
    for name, v in fin.items(): reg('u_eng.g_fu.u_fin.' + name, v)
    for k, j in enumerate((0, 3, 4, 5)): reg(f'u_eng.g_fu.u_fin.sn_vp[{k}]', c['Viewport'][j])
    reg('u_eng.g_cl.u_clip.sn_far', (c['CurPolygonAttr'] >> 12) & 1)
    reg('u_eng.np_r', 0); reg('u_eng.nv_r', 0); reg('u_eng.box_r', (c['GXStat'] >> 1) & 1)
    front = {'ws_mmode': c['MatrixMode'], 'ws_pmode': 1, 'ws_pattr': c['PolygonAttr'] & 15,
             'ws_cattr': c['CurPolygonAttr'] & 15, 'ws_vnip': 0,
             'ws_ncons': c['NumConsecutivePolygons'] & 1, 'ws_xpc': 0,
             'psp': c['PosMatrixStackPointer'], 'jsp': c['ProjMatrixStackPointer'],
             'tsp': c['TexMatrixStackPointer'], 'irqm': c['GXStat'] >> 30,
             'b15': (c['GXStat'] >> 15) & 1, 'zdot': c['ZeroDotWLimit'],
             'model_npoly': 0, 'model_nvert': 0}
    for name in ('pk_nc', 'pk_cur', 'pk_pc', 'pk_tp', 'st_n', 'st_w', 'st_a', 'st_aq',
                 'act', 'up', 'f', 'p', 'flush', 'flush_t', 'busy', 'b0', 'b14',
                 'npush_in', 'npush_ex', 'ntest_in', 'ntest_ex', 'oq_w', 'oq_r', 'oq_count',
                 'engine_lead', 'ovf_pending', 'pend_strip', 'pend_qs', 'pend_quad', 'oc_skip',
                 'last_l44_m2'):
        front[name] = 0
    for name, value in dict(cyc=0, vp=0, np=0, pp=0, vsc=0, vsf=1, pend=0, pend_e=0).items():
        front['tm.' + name] = value
    for name, value in front.items(): reg('u_front.' + name, value)
    cover('ProjMatrixStackPointer TexMatrixStackPointer GXStat ZeroDotWLimit', 'front jsp/tsp/irqm/b15/zdot and engine BOX result; dynamic GXSTAT bits computed')
    cover('ClipMatrixDirty', 'preserve capturedtrue; RF/vectorcache stay capturedstale until real lazy update')
    cover('GeometryEnabled RenderingEnabled AbortFrame', 'require enabled/enabled/not-aborted; IO POWCNT replay owned by Raster')
    cover('NumCommands CurCommand ParamCount TotalParams ExecParamCount NumPushPopCommands NumTestCommands NumOpaquePolygons',
          'require zero: consumer must fence/reset empty staging, collectors, outcomes and read transactions')
    codec.require(set(coverage) == set(c), 'context field left without a mapping or rejection')
    codec.require(seed['semantic_sha256'] == binding['portable_semantic_sha256'],
                  'context helper requires the qualified clean MKDS capture')
    return {'schema': SCHEMA, 'source': NATIVE_TARGET, 'portable_semantic_sha256': seed['semantic_sha256'],
            'source_binding': binding, 'scope': 'current_context only; no pending polygon/raster records, no release, no native proof',
            'rf_words': dict(sorted(rf.items())), 'native_registers': dict(sorted(state.items())),
            'rf_write_rule': 'u_eng.u_rfa.mem[a] for every word; u_eng.u_rfb.mem[a] only when a<0x400',
            'required_actual_parameters': {'GX_DSX': 1, 'GX_L44_READ': 1, 'GX_FAST': 1,
                'GX_SWAP_OVERLAP': 1,
                'GX_CLIP_PAR': 0, 'GX_MAT_PAR': 1, 'GX_SP_ON': 4096,
                'engine_DIV_P2X': 0, 'front_GATH16': 1,
                'engine_FF': 1, 'engine_LUNIT': 1, 'engine_VFIN': 2, 'engine_USORT': 1},
            'field_coverage': dict(sorted(coverage.items())),
            'consumer_preconditions': ['stop all simulator clocks while loading; no command replay or synthetic SWAP',
                'assert every required_actual_parameters value against elaborated endpoints',
                'reset native engine, then reach an empty NX_DISP with all write/lighting/finish/clip/output pipelines drained',
                'empty front staging, PIPE, FIFO, SPILL, arrival and outcome queues; engine_lead=0; all read fences empty',
                'tm.cyc/vp/np/pp/vsc=0, tm.vsf=1, tm.pend/pend_e=0, no flush or swap acknowledgement',
                'pi=0,pi1=1,ssp=0; no l44 early peek (last_l44_m2=0,lr_state=0); no LU speculation or deferred colour',
                'apply every RF word AND every listed mirror; parked register-file writes do not propagate snoops',
                'Raster separately loads banks/order/Y/buckets, current and latched registers, cold raster epoch and release',
                'read back all assignments before clocks resume; qualify first settled frame with unchanged gate'],
            'unsupported': ['partial or strip primitive', 'live LastStripPolygon/reused pair', 'queued or partial command',
                'nonquiescent timing/pending outcome', 'nonempty current bank', 'finalized/clipped temporary slots',
                'unknown current_context fields', 'different source files or seed schema']}


def verify(seed, mapping, source):
    codec.require(mapping == build(seed, source), 'native context assignments differ')
    return {'schema': SCHEMA, 'status': 'HOST MAPPING PASS', 'rf_words': len(mapping['rf_words']),
            'native_assignments': len(mapping['native_registers']), 'fields': len(mapping['field_coverage']),
            'native_execution': 'not run; Raster owns stopped-clock load/readback and behavioral qualification'}



def seed_from_atomic(path):
    atomic=json.loads(Path(path).read_text())
    codec.require(atomic['clean_line_before_processing']==193 and atomic['SysTimestamp']==2969418090,'wrong qualified source epoch')
    g=atomic['GX']
    context={name:g[name]for name in codec.CONTEXT}
    context.update(TempVertexBuffer=g['TempVertexBuffer'],LastStripPolygonIndex=None if g['LastStripPolygonIndex']==-1 else g['LastStripPolygonIndex'],ZeroDotWLimit=g['ZeroDotWLimit'])
    return codec.seal(dict(schema=codec.SCHEMA,target_core=codec.TARGET,source_atomic_sha256=codec.digest(Path(path).read_bytes()),ready_for_context_deposit=True,current_context=context,
        quiescent_controls={name:g[name]for name in ['CycleCount','VertexPipeline','NormalPipeline','PolygonPipeline','VertexSlotCounter','VertexSlotsFree','NumVertices','NumPolygons','FlushRequest']},
        current_bank=dict(index=g['CurRAMBank'],vertices=[],polygons=[],flush_request=g['FlushRequest']),
        queues={name:dict(entries=[],occupied=g[name]['occupied'])for name in ['CmdFIFO','CmdPIPE','CmdStallQueue']},predecessor_flush_attributes=g['FlushAttributes']))


def context_words(mapping):
    # Must match runtime_import_gx_context.svh generated assignment order.
    values=list(mapping['rf_words'].values())+list(mapping['native_registers'].values())
    codec.require(len(values)==2632,'context field layout requires requalification')
    return values


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('atomic',type=Path)
    parser.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    seed=seed_from_atomic(args.atomic);mapping=build(seed,args.source_root)
    args.out.mkdir(parents=True,exist_ok=True)
    (args.out/'context-seed.json').write_text(json.dumps(seed,indent=2)+'\n')
    (args.out/'mapping.json').write_text(json.dumps(mapping,indent=2)+'\n')
    (args.out/'context.hex').write_text(''.join(f'{v:08x}\n'for v in context_words(mapping)))
    from runtime_gx_records import write_images
    result=write_images(json.loads(args.atomic.read_text())['GX'],args.out)
    print('GX_IMPORT_DATA_READY context2632 source-dirty-preserved records'+str(result['count'])+' stream'+str(result['stream_beats'])+'; no native publication performed')


if __name__=='__main__':
    main()
