"""Test-only held-valid continuation of the pinned finish/prepare CPU trial.

No production file, service countdown or external interface is changed.
Memory owns p7_trial.py/its ledger; this producer adds only the agreed
three local commit signals. Runtime qualification belongs to the paired gate.
"""
import importlib.util
import hashlib
from pathlib import Path

_path=Path(__file__).resolve().parents[1]/'a7_prepare_finish/trial.py'
assert hashlib.sha256(_path.read_bytes()).hexdigest() == 'a9dc9b35b6c5ebcc260a8b01129306a7cf2f9dd27b5acda9116083f7659f9272'
_spec=importlib.util.spec_from_file_location('qualified_prepare_trial',_path)
_phase=importlib.util.module_from_spec(_spec);_spec.loader.exec_module(_phase)


def patch(source, mutation='none'):
    assert hashlib.sha256(source.encode()).hexdigest() == '662c582fcd2f965185f1018f4adc2eeb12f37dbc7ac4ed6f0b5951ad5c357d4e', 'use the frozen59b/faf CPU leaf, not an older branch leaf'
    source=_phase.patch(source)
    def replace(old,new):
        nonlocal source
        assert source.count(old)==1,old
        source=source.replace(old,new,1)
    replace('module arm7_ds_trial import','module arm7_ds_slot_trial import')
    replace('  input logic phase_trial,','''  input logic phase_trial,
  // Local sequential ARM MAIN subset; phase_trial is fixed until reset.
  output logic i_commit_valid,
  output logic [31:0] i_commit_addr,
  input logic i_commit_accept,''')
    replace('  logic phase_f_done, phase_prepared;','''  logic phase_f_done, phase_prepared;
  logic phase_commit_pending;
  logic [31:0] phase_commit_address;''')
    begin=source.index('  // A later actual F offer remains necessary.')
    end=source.index('  wire if_wait =',begin)
    source=source[:begin]+'''  // First offer bypasses on the architectural consume edge, after
  // internal work. Only the original latched preparation supplies its
  // address; an advanced live i_addr cannot retag a stalled offer.
  wire phase_next_commit = phase_trial && phase_prepared && i_consume &&
       phase_prepared_address[31:24] == 8'h02 && !rst && !i_redirect;
  assign i_commit_valid = phase_trial && !rst && !i_redirect &&
                          (phase_commit_pending || phase_next_commit);
  assign i_commit_addr = phase_commit_pending ? phase_commit_address :
                                                phase_prepared_address;
  always_ff @(posedge clk) begin
    if (rst || i_redirect) begin
      phase_f_done <= 0; phase_f_owner <= '0; phase_f_word <= '0;
      phase_prepared <= 0; phase_prepared_address <= '0;
      phase_commit_pending <= 0; phase_commit_address <= '0;
    end else begin
      // Current completed F remains separate from the next accepted owner.
      if (i_consume) begin
        phase_f_done <= 0; phase_f_owner <= '0; phase_f_word <= '0;
        if (!phase_next_commit && !phase_commit_pending) begin
          phase_prepared <= 0; phase_prepared_address <= '0;
        end
      end else if (phase_f_finish) begin
        phase_f_done <= 1; phase_f_owner <= i_addr[31:2];
        phase_f_word <= i_rdata_in;
      end
      if (phase_prepare) begin
        phase_prepared <= 1;
        // A simultaneous first finish/start uses that matching finish's
        // original address. Later consumption never recomputes F+4.
        phase_prepared_address <= (phase_owner_live ?
            {phase_f_owner,2'b00} : i_addr) + 32'd4;
      end
      if (phase_commit_pending) begin
        if (i_commit_accept) begin
          phase_commit_pending <= 0; phase_commit_address <= '0;
        end
      end else if (phase_next_commit && !i_commit_accept) begin
        phase_commit_pending <= 1;
        phase_commit_address <= phase_prepared_address;
      end
      if (i_commit_accept) begin
        phase_prepared <= 0; phase_prepared_address <= '0;
      end
    end
  end
'''+source[end:]
    # Registered occupancy alone stalls another consume. In particular,
    # accept never feeds current i_consume/if_wait/old-word readiness.
    replace('!i_ok && !e_busy) || phase_first_wait;',
            '!i_ok && !e_busy) || phase_first_wait || phase_commit_pending;')
    if mutation=='drop-unaccepted':
        replace('        phase_commit_pending <= 1;',
                '        phase_commit_pending <= 0;')
    elif mutation=='live-address':
        replace('phase_commit_pending ? phase_commit_address :',
                "phase_commit_pending ? (i_addr + 32'd4) :")
    elif mutation!='none':
        raise ValueError(mutation)
    ledger=Path(__file__).with_name('cpu_ledger.svh').read_text()
    assert source.rstrip().endswith('endmodule')
    return source.rstrip()[:-len('endmodule')]+ledger+'\nendmodule\n'
