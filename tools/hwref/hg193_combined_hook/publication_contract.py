"""Source classification only. No drain predicate is weakened by this table."""
import re

MEM = 'dut.ds.u_cpud.g_one.u_cpu.u_mem9'
CORE = 'dut.ds.u_cpud.g_one.u_cpu.u_core'
CLASSES = {
    'live_issue': 'Visible or pipeline-held issue is not itself accepted external ownership; bootstrap fetch/KEYINPUT polling may legitimately keep it asserted. Address, operation and acceptance must be observed.',
    'external_or_queued': 'May own queued/accepted work. Preserve all descriptors/results. Pending GX/MMIO, canonical-record or publication-alias work is forbidden; no address-local exception is qualified.',
    'local_write': 'Delayed CPU-local TCM/cache write history is preserved, never cleared. HG does not deposit into these arrays; source disjointness does not qualify a pending external owner.',
    'completed_return': 'Completed uncached return remains valid until its ordinary replay/consumption rule. Valid does not mean an outstanding physical response. Preserve address/data/valid exactly.',
    'completion_token': 'Completed maintenance replay token is not by itself an outstanding bus operation; preserve opcode/value/valid until ordinary consumption.',
    'local_port': 'CPU-local RAM-port occupancy or previous-cycle hazard; preserve it. It is not by itself ownership of the GPU publication namespace.',
    'lifecycle': 'Checks bootstrap locality/cache-control phase, rather than a physical GPU transport drain. Retained pending actual clause diagnostics.',
}
KINDS = {
    **dict.fromkeys('i_req d_req cp_req f_req w_req w_cp'.split(), 'live_issue'),
    **dict.fromkeys('st b_req dp_v ip_v pf_run wbuf_v nb_owned ev_v'.split(), 'external_or_queued'),
    **dict.fromkeys('qw_v pw_v'.split(), 'local_write'),
    **dict.fromkeys('rbuf_v ibuf_v'.split(), 'completed_return'),
    'cmo_done': 'completion_token',
    **dict.fromkeys('busy_d busy_i col_d col_i'.split(), 'local_port'),
}


def clauses(helper):
    terms=[s.strip().replace('`RUNTIME_MEM9',MEM) for s in
           re.search(r'return (.*?);',helper,re.S).group(1).split('&&')]
    rows=[]
    for expr in terms:
        name=re.search(r'u_mem9\.(\w+)',expr).group(1)
        rows.append(dict(name=name,expression=expr,classification=KINDS[name],
            meaning=CLASSES[KINDS[name]],gate='RETAINED_UNCHANGED',actual_value='UNKNOWN'))
    for name,expr in [('ctrl_cache_mpu_off',f'({MEM}.ctrl & 32\'h00001005)==0'),
        ('stub_pc_lower',f'{CORE}.fetch_pc[0]>=32\'h02000000+32\'(4*imp_ov)'),
        ('stub_pc_upper',f'{CORE}.fetch_pc[0]<32\'h02000000+32\'(4*(imp_ov+imp_stubn))')]:
        rows.append(dict(name=name,expression=expr,classification='lifecycle',
            meaning=CLASSES['lifecycle'],gate='RETAINED_UNCHANGED',actual_value='UNKNOWN'))
    assert len(rows)==26
    return rows


def contract(helper):
    return dict(state='SOURCE_CONTRACT_IDENTIFIED_BEFORE_CAPTURE_COMPOSITION',
        cpu_arm9_cache_clauses=clauses(helper),
        lifecycle=[
            'Table9 installs TCM configuration/load mode with MPU/I/D caches off before replay/copies.',
            'READY9/READY7 are each table\'s last write, before regblock restoration; ready words alone do not prove register restore complete or an idle memory engine.',
            'Stub restores banked/user registers, enters its tail in undefined mode and polls KEYINPUT at0x04000130; fetch/data requests and uncached result-valid flags may be live.',
            'Original4000SYS delay and line193 release remain unchanged; zero-time held publication precedes the original release edge.',
            'After KEYINPUT release, tails clear IF, invalidate both off caches, restore captured control and MOVS to captured PC (or preserve halted state).',
            'Overlay stub bytes return only on first ARM9 retirement outside the stub; no premature erase or fabricated architectural state.'],
        publication_locality=dict(
            writes=['SD physical words0x1a0000..0x1bffff canonical records',
                'GPU context/RF and banks/order/Y/link/bucket tables',
                'GPU cache tags/identities and cold raster/ring publication state'],
            not_written=['CPU architectural/pipeline/cache/TCM/CP15 state',
                'PSRAM main RAM and bootstrap bytes','pending request/return descriptors or completion ownership'],
            required='All clocks held at current levels, zero elapsed time; all consumers/producers and accepted responses that can observe overwritten GPU/SD/cache/context state must be excluded. Ordinary current registers must match replay.',
            disjoint_work='A held unrelated main-RAM fetch or completed KEYINPUT/CPU-local result need not imply a GPU write conflict. This is a source-locality argument only; no current runtime guard is removed.',
            forbidden_unknown='Unknown pending GX/MMIO, canonical-record, cache alias, sort/publication or shared physical response ownership remains forbidden. No blanket claim that CPU work is disjoint.'),
        ABI=dict(event_header='<4I:0x33504453,1,40,mode',event='<Q6IQ:time_ps,kind,port,addr,data,x,y,z',
            streams=['bus.gz (physical/causal/producer/logical/PCM kind40)','cpu.gz (separate CPU endpoints kinds100/101/102)',
                'states.jsonl (frames+1,5 memory hashes,event-derived CPU/register fingerprints)',
                'shots/fNNN.ppm (existing085 actor)','ordinary savout APF save readback'],
            cpu_scope='Event-derived register fingerprints are not a complete architectural register dump.',
            capture_limit='Explicit full-game capture/termination horizon106..256; old24/39/85 prefixes are controls. No actor input, seed, clock or existing raw/reference map is changed. Separate fixed HG-history gate retains85.',
            source_gate='Exact qualified helper bytes and DPI ABI; parent085 reconstructs exactly; shared shots/save tasks match qualified actor3fa; all60 settings and every compiler input/include bound.',
            observable_mutation_gate=['Actual retained107-state AC fixture rejects old24 cutoff',
                'Qualified physical reader rejects changed accepted descriptor in actual event prefix',
                'Qualified gzip/event reader rejects missing footer',
                'Source checks reject changed CPU sampling edge, missing clause diagnostic and changed publication guard']),
        qualification='SOURCE_ONLY; all clause values and extended currentmain40 tap elaboration UNKNOWN; no compiler/model/baseline')


def diagnostics(rows):
    lines=['// Passive per-clause diagnostics only: no waits or DUT writes.',
        'task automatic hg193_publication_diagnostics(input string phase);']
    for row in rows:
        lines.append(f' $display("HG193_CPU_CLAUSE phase=%s name={row["name"]} pass=%0b",phase,({row["expression"]}));')
    fields='ctrl st i_req d_req cp_req f_req w_req w_cp i_addr d_addr f_addr w_addr dp_v dp_a dp_kind ip_v ip_a b_req b_addr b_we w_we rbuf_v rbuf_a rbuf_d ibuf_v ibuf_a ibuf_d cmo_done cmo_op cmo_val'.split()
    for field in fields:
        lines.append(f' $display("HG193_CPU_RAW phase=%s name={field} value=%h",phase,{MEM}.{field});')
    lines.append(f' $display("HG193_CPU_RAW phase=%s name=fetch_pc0 value=%h",phase,{CORE}.fetch_pc[0]);')
    lines+=['endtask','']
    return '\n'.join(lines)
