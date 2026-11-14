#!/usr/bin/env python3
"""Observe exact full-sound #2209 on the fixed retained game inputs."""
import csv
import io
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

from joint_capture_compare import open_trace, readbacks
from joint_capture_games import CONTROL, ROOT, TAG, FROZEN, load
from run import run

CARRIER = '74f18481fb7644ff201ef618d082814e1be7d333'
WORKTREE = Path(__file__).resolve().parents[3]
OBSERVER = 'sim/pocket_ds/fifo_service_observer.svh'
TB = 'sim/pocket_ds/tb_ds_pocket.sv'
TITLE_WAIT = 'sim/pocket_ds/title_wait_observer.svh'
ARM = ('arm_compact_pkg.sv', 'arm9_mem_fused.sv', 'arm_context_bank.sv',
       'arm_shared_compact.sv', 'arm_dual_fused.sv', 'arm_cpu_fused.sv')
OWNERS = ('video', 'ring', 'capture', 'cpu')
TOOLS = Path('build/tools/oss-cad-suite/bin')

def prepare(out, event_only=False):
    source = out / 'source'
    source.mkdir(parents=True, exist_ok=False)
    sim = ('sim/phase1', 'sim/pocket_ds', 'sim/probe/mf_datatable_model.sv')
    archive = subprocess.check_output(['git', 'archive', CARRIER, 'rtl', *sim], cwd=WORKTREE)
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:') as tar:
        tar.extractall(source, filter='data')
    tb = source / TB
    original = run.sha(tb)
    text = tb.read_text()
    anchor = '    // ---------------- finish ----------------'
    assert text.count(anchor) == 1
    tb.write_text(text.replace(anchor, '    `include "fifo_service_observer.svh"\n' + anchor))
    (source / OBSERVER).write_bytes((WORKTREE / OBSERVER).read_bytes())
    wait_header = source / TITLE_WAIT
    wait_original = run.sha(wait_header)
    if event_only:
        # Preserve the original R offer/ACK counters and V transaction
        # records. Suppress unrelated debug output without driving the DUT.
        text = wait_header.read_text()
        text, removed = re.subn(r'\$fdisplay\(tw_fd,"(?:E|I|FILL|FEND|D|P|Q|PS|PE|DMA|CAP|MO|MT),',
                                lambda match: "if (1'b0) " + match[0], text)
        assert removed == 13
        for statement in ('$fwrite(tw_fd,"W,', 'foreach(tw_wc[i])$fwrite(', '$fwrite(tw_fd,"\\n");tw_write=0;'):
            assert text.count(statement) == 1, statement
            text = text.replace(statement, "if (1'b0) " + statement)
        wait_header.write_text(text)
    files = {str(p.relative_to(source)): run.sha(p) for p in sorted(source.rglob('*')) if p.is_file()}
    run.put(out/'source.json', dict(carrier=CARRIER, profile='full-sound #2209 RTL defaults',
            testbench_original_sha256=original, title_wait_original_sha256=wait_original,
            wait_events_only=event_only, files=files))

def prepare_reservation(out, control):
    source = out / 'source'
    prior = load(control / 'source.json')
    assert prior['carrier'] == CARRIER and prior['wait_events_only']
    for name, digest in prior['files'].items():
        assert run.sha(control / 'source' / name) == digest, name
    shutil.copytree(control / 'source', source)
    edits = []

    def edit(name, old, new):
        path = source / name
        content = path.read_text()
        assert content.count(old) == 1, name
        path.write_text(content.replace(old, new))
        edits.append(dict(file=name, before=old, after=new))

    vram = 'rtl/ds/nds_vram.sv'
    edit(vram, '    output logic        cap_ready,', '''    output logic        cap_ready,
    output logic        cap_pair_assembling, cap_pair_ready,''')
    edit(vram, '    assign cap_ready =', '''    assign cap_pair_assembling = CAP_CHAIN && cap_p;
    assign cap_pair_ready = cw_pair;
    assign cap_ready =''')

    top = 'rtl/ds/nds_top.sv'
    edit(top, '    output logic        cw_valid,', '''    output logic        cap_pair_assembling, cap_pair_ready,
    output logic        cw_valid,''')
    edit(top, '.cap_ready, .cw_valid,', '.cap_ready, .cap_pair_assembling, .cap_pair_ready, .cw_valid,')

    core = 'rtl/pocket/core_top_ds.sv'
    edit(core, '    parameter integer CAP_CHAIN = 1,', '''    parameter bit CAP_PAIR_SLOT = 0,
    parameter integer CAP_CHAIN = 1,''')
    edit(core, '    wire        cw_valid, cw_ack;', '''    wire        cap_pair_assembling, cap_pair_ready;
    wire        cw_valid, cw_ack;''')
    edit(core, '        .cw_valid(cw_valid),', '        .cap_pair_assembling, .cap_pair_ready, .cw_valid(cw_valid),')
    edit(core, '            .video_req(vw_req), .ring_req(RING_I != 0 && rg_wreq),', '''            .cap_slot_tight(CAP_PAIR_SLOT && bw_fill[6]), .cap_pair_assembling, .cap_pair_ready,
            .video_req(vw_req), .ring_req(RING_I != 0 && rg_wreq),''')

    poster = 'rtl/pocket/nds_ring_post_arb.sv'
    edit(poster, '    input logic clk, reset,', '''    input logic clk, reset,
    input logic cap_slot_tight, cap_pair_assembling, cap_pair_ready,''')
    edit(poster, '    wire [2:0] requests = {capture_req,ring_req,video_req};', '''    logic cap_slot_reserved, cap_slot_used;
    wire ring_owned = active && owner == 1;
    wire cap_slot_start = !cap_slot_used && !cap_slot_reserved && cap_slot_tight &&
                          !full && cap_pair_assembling && ring_req && !ring_owned;
    wire cap_slot_needed = cap_slot_tight && (cap_pair_assembling || cap_pair_ready);
    wire hold_ring_start = cap_slot_start || (cap_slot_reserved && cap_slot_needed);
    wire [2:0] requests = {capture_req,ring_req && (ring_owned || !hold_ring_start),video_req};
    always_ff @(posedge clk) begin
        if (reset || ring_ack) begin
            cap_slot_reserved <= 0;
            cap_slot_used <= 0;
        end else if (cap_slot_reserved && (!cap_slot_needed || (capture_ack && cap_pair_ready))) begin
            cap_slot_reserved <= 0;
            cap_slot_used <= 1;
        end else if (cap_slot_start) cap_slot_reserved <= 1;
    end''')
    edit(TB, '    // ---------------- finish ----------------', '''    integer slot_arms = 0, slot_holds = 0, slot_pair_acks = 0;
    always @(posedge dut.clk_sys) if (!dut.rst_sys) begin
        if (dut.g_post_deadline.post_arb.cap_slot_start) slot_arms++;
        if (dut.g_post_deadline.post_arb.hold_ring_start && dut.rg_wreq && !dut.bw_full) slot_holds++;
        if (dut.g_post_deadline.post_arb.cap_slot_reserved && dut.cw_ack && dut.cap_pair_ready)
            slot_pair_acks++;
        if (dut.g_post_deadline.post_arb.ring_owned && dut.rg_wreq && !dut.bw_full && !dut.rg_wack)
            $fatal(1,"CAP_SLOT_SPLIT_STARTED_RING");
    end
    final $display("CAP_SLOT_COVERAGE arms=%0d holdSYS=%0d pairedACK=%0d",slot_arms,slot_holds,slot_pair_acks);
    // ---------------- finish ----------------''')
    files = {name: run.sha(source / name) for name in prior['files']}
    assert {name for name, digest in files.items() if digest != prior['files'][name]} == {
        vram, top, core, poster, TB}
    run.put(out / 'source.json', dict(prior, files=files, reserve_capture_slot=True,
                                    baseline_manifest_sha256=run.sha(control/'source.json'), edits=edits))

def build_command(out):
    source = out / 'source'
    old = load(CONTROL / f'build-{TAG}.process.json')['command']
    command = [arg.replace(str(FROZEN), str(source)) for arg in old if '/rtl/arm/study/' not in arg]
    command[command.index('--Mdir')+1] = str(out / 'obj')
    pkg = command.index(str(source / 'rtl/arm/arm_pkg.sv'))
    command[pkg+1:pkg+1] = [str(source / 'rtl/arm/study' / p) for p in ARM]
    if load(out / 'source.json').get('reserve_capture_slot'):
        command.append('+define+TB_CORE_PARAMS=, .CAP_PAIR_SLOT(1)')
    return command

def compile_model(out):
    source = out / 'source'
    manifest = load(out / 'source.json')
    for name, digest in manifest['files'].items():
        assert run.sha(source / name) == digest, name
    command = build_command(out)
    # The initial #2209 build produced 251 MB of compiler objects and
    # less than 30 MB of retained generated source, executable and receipts.
    rc, log = run.worker(out, 'carrier-build', command, build=True, growth=384 << 20, seconds=1200)
    if rc:
        print(log[-7500:])
        raise SystemExit(rc)
    model = out / 'obj/Vtb_ds_pocket'
    for name, digest in manifest['files'].items():
        assert run.sha(source / name) == digest, name
    run.put(out / 'model.json', dict(carrier=CARRIER, source_sha256=run.sha(out/'source.json'),
                                    binary_sha256=run.sha(model)))

def scene(out, name):
    control = CONTROL / f'{name}-{TAG}-observe'
    baseline = load(control / 'run.json')
    previous = load(control / 'run.process.json')
    cwd = Path(previous['cwd'])
    for entry in load(cwd / 'ready.json')['files']:
        assert run.sha(Path(entry['path'])) == entry['sha256'], entry['path']
    assert run.sha(cwd/'rtl/ds/nds_io_route.hex') == run.sha(out/'source/rtl/ds/nds_io_route.hex')
    dest = out / name
    dest.mkdir(exist_ok=False)
    (dest / 'shots').mkdir()
    model = load(out / 'model.json')
    binary = out / 'obj/Vtb_ds_pocket'
    assert run.sha(binary) == model['binary_sha256']
    old_binary = load(CONTROL / f'model-{TAG}.json')['model']
    assert previous['command'].count(old_binary) == 1
    command = ['env', '--chdir='+str(cwd)]
    command.extend(str(binary) if arg == old_binary else arg.replace(str(control), str(dest))
                   for arg in previous['command'])
    command.append(f'+fifo_service={dest / "fifo.csv"}')
    event_only = load(out/'source.json').get('wait_events_only', False)
    rc, log = run.worker(dest, 'run', command, growth=(128 if event_only else 256) << 20, seconds=5400)
    run.put(dest / 'run.json', dict(baseline, variant='2209-fifo-observer', rc=rc,
                                    carrier=CARRIER, model_sha256=model['binary_sha256'], control=str(control)))
    print(log[-2000:])
    if rc:
        raise SystemExit(rc)
    rc, log = run.worker(dest, 'analysis', ['python3', ROOT/'tools/scorecard/raster_symptom_report.py', dest],
                         growth=32 << 20, seconds=180)
    print(log[-1600:])
    assert rc == 0

def window_rows(path):
    rows = []
    with path.open() as stream:
        for row in csv.DictReader(stream):
            # A prefix may end while the simulator is writing the last row.
            if None in row.values():
                break
            line = {name: int(value) for name, value in row.items()}
            assert line['cap_wait'] == sum(line[key] for key in (
                'cap_pair_full', 'cap_pair_other', 'cap_lone_native', 'cap_lone_admit', 'cap_other'))
            if rows:
                previous = rows[-1]
                assert line['sys'] > previous['sys']
                for owner in OWNERS:
                    assert line[f'tail_{owner}'] == (
                        previous[f'tail_{owner}'] + line[f'post_{owner}'] - line[f'pop_{owner}'])
            rows.append(line)
    return rows

def service_totals(rows):
    counts = ('full_sys', 'd_wait', 'd_full', 'd_inflight', 'd_ack', 'd_done', 'd_late',
              'ring_wait', 'ring_full', 'ring_read_ack', 'ring_read_words', 'cap_wait',
              'cap_pair_full', 'cap_pair_other', 'cap_lone_native', 'cap_lone_admit',
              'cap_other', 'cap_halves', 'quanta')
    counts += tuple(f'{action}_{owner}' for action in ('post', 'pop') for owner in OWNERS)
    if rows and 'reserve_offer' in rows[0]:
        counts += ('reserve_offer', 'reserve_ring_start', 'reserve_urgent_2d', 'reserve_full_pair')
        counts += tuple(f'full_mix_{owner}' for owner in OWNERS)
    totals = {key: sum(row[key] for row in rows) for key in counts}
    totals.update({key: max((row[key] for row in rows), default=0)
                   for key in ('fill_peak', 'native_peak', 'words_peak')})
    return totals

def report(dest):
    result = load(dest/'run.json')
    text = (dest/'run.log').read_text()
    counts = re.search(r'FIFO_SERVICE_SUMMARY posts=(\d+) pops=(\d+) d_ack=(\d+) d_done=(\d+) '
                       r'd_tail_beats=(\d+) quanta=(\d+)', text)
    assert result['rc'] == 0 and counts
    names = ('posts', 'pops', '2d_accepted', '2d_completed', '2d_tail_beats', 'quanta')
    summary = dict(zip(names, map(int, counts.groups())))
    assert 0 <= summary['posts'] - summary['pops'] <= 65
    rows = window_rows(dest/'fifo.csv')
    assert rows
    late = [row for row in rows if row['d_late']]
    direct = 0
    waits = dest/'observer.csv.waits.csv'
    with open_trace(waits, 'rt') as stream:
        for line in stream:
            if line.startswith('V,'):
                _, _, _, state, _, write, block, _ = line.rstrip().split(',')
                if (state, write, block) == ('3', '1', '0'):
                    direct += 1
    data = dict(source=result['carrier'], fifo_sha256=run.sha(dest/'fifo.csv'),
                full_run_verified=summary, line_count=len(rows), line_interval_SYS=[rows[0]['sys'], rows[-1]['sys']],
                capture_lone_xport_accepts=direct,
                observed_lines=service_totals(rows), lines_with_2d_late=service_totals(late))
    if result['scene'] == 'title':
        data['title_dma_readback'] = readbacks(waits)
    run.put(dest/'fifo-summary.json', data)
    print(dest.name, data['observed_lines'])

def prepare_reservation_check(out):
    check = out / 'slot-check'
    check.mkdir(exist_ok=False)
    source = out / 'source/rtl/pocket/nds_ring_post_arb.sv'
    manifest = load(out/'source.json')
    assert run.sha(source) == manifest['files']['rtl/pocket/nds_ring_post_arb.sv']
    original = subprocess.check_output(['git', 'show', CARRIER+':rtl/pocket/nds_ring_post_arb.sv'],
                                       cwd=WORKTREE, text=True)
    baseline = check/'baseline.sv'
    baseline.write_text(original.replace('module nds_ring_post_arb (', 'module nds_ring_post_arb_control ('))
    needle = 'wire hold_ring_start = cap_slot_start || (cap_slot_reserved && cap_slot_needed);'
    text = source.read_text()
    assert text.count(needle) == 1
    fault = check/'fault.sv'
    fault.write_text(text.replace(needle, 'wire hold_ring_start = cap_slot_start;'))
    credit_fault = check/'credit-fault.sv'
    assert text.count('!cap_slot_used && !cap_slot_reserved') == 1
    credit_fault.write_text(text.replace('!cap_slot_used && !cap_slot_reserved', '!cap_slot_reserved'))
    test = WORKTREE/'sim/ds/render_service/fifo_slot_order.sv'
    cases = [('order',source,'FIFO_SLOT_ORDER_PASS'),
             ('hold-fault',fault,'RESERVATION_LOST_AT_PAIR'),
             ('credit-fault',credit_fault,'REPEATED_RESERVATION_WITHOUT_RING_SERVICE')]
    return check, source, baseline, test, cases

def check_reservation(out):
    check, source, baseline, test, definitions = prepare_reservation_check(out)
    cases = {}
    for name, dut, expected in definitions:
        model = check/(name+'.vvp')
        command = [TOOLS/'iverilog','-g2012','-s','fifo_slot_order','-o',model,baseline,dut,test]
        rc, log = run.worker(check,name+'-compile',command,growth=4<<20,seconds=60)
        assert rc == 0, log[-2000:]
        rc, log = run.worker(check,name,[TOOLS/'vvp',model],growth=1<<20,seconds=30)
        passed = expected in log and (rc==0 if name=='order' else rc!=0)
        assert passed, log
        cases[name] = dict(PASS=passed,returncode=rc,expected=expected,log_sha256=run.sha(check/(name+'.log')))
    run.put(check/'result.json',dict(source_sha256=run.sha(source),fixture_sha256=run.sha(test),
                                    baseline_sha256=run.sha(baseline),cases=cases))
    print('SLOT_ORDER_AND_ACTUAL_HOLD_FAULT_PASS')

if __name__ == '__main__':
    action, path, *flags = sys.argv[1:]
    target = Path(path).resolve()
    if action == 'prepare':
        assert flags in ([], ['--event-only'])
        prepare(target, bool(flags))
    elif action == 'prepare-reservation':
        prepare_reservation(target, Path(flags[0]).resolve())
    elif action == 'build':
        compile_model(target)
    elif action == 'report':
        report(target)
    elif action == 'check-reservation':
        check_reservation(target)
    else:
        assert action in ('race', 'title', 'battle')
        scene(target, action)
