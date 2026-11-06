#!/usr/bin/env python3
"""Bind selected trampoline to original tables and existing extracted writes.

Reads no raw bus/CPU stream and executes no compiler, native or probe.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
sha=lambda b:hashlib.sha256(b).hexdigest()
def write(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
def table(words,pointer,ready):
 assert pointer%4==0 and 0x02000000<=pointer<0x02400000
 i=(pointer-0x02000000)//4;operations=[];start=i
 for _ in range(4096):
  op=words[i]
  if op==0:break
  assert op in (1,2,3,4,5,6);n={1:2,2:2,3:2,4:3,5:2,6:3}[op]
  operations.append(words[i:i+1+n]);i+=1+n
 else:raise AssertionError('unterminated import table')
 assert operations[-1]==[3,ready,1]
 regs=words[i+1:i+40];assert len(regs)==39 and regs[2]in (0,1)
 return dict(pointer=pointer,operations=len(operations),first_word=start,last_ready_operation=operations[-1],regblock=regs,regblock_address=0x02000000+4*(i+1),halted=regs[2])
def prepare(parent,out):
 assert not out.exists();out.mkdir(parents=True)
 args=json.loads((parent/'diagnostic/argv.json').read_text());image=Path(next(a.split('=',1)[1]for a in args if a.startswith('+imp_main=')))
 words=[int(x,16)for x in image.read_text().split()];assert len(words)==1<<20
 assert words[:4]==[0x444f4c53,0x49534e44,0x02309000,0x02309004]
 t9=table(words,words[4],0x02000018);t7=table(words,words[5],0x0200001c)
 initial=words[0xc2400:0xc2400+137];binary=(parent/'lifecycle-source/sw/stateload/stateload.bin').read_bytes()
 assert b''.join(w.to_bytes(4,'little')for w in initial)==binary and len(binary)==548
 # This prior extraction covers ALL kind56 writes in the stub range, not a
 # new stream scan. Runtime137-word values were not dumped by that host.
 audit_path=ROOT/'docs/results/hg193-actual-caller-20261102/stub-self-write-audit.json'
 audit=json.loads(audit_path.read_text());writes=audit['actual_stub_writes'];replayed=list(initial)
 assert [(r['master'],r['address'],r['byte_enable'])for r in writes]==[(2,'023091ac',15),(1,'023091ac',15)]
 for row in writes:replayed[(int(row['address'],16)-0x02309000)//4]=int(row['data'],16)
 selected=0x02309000+int(audit['symbols']['tail9_halt'if t9['halted']else 'tail9_run'],16)
 assert int(audit['symbols']['tramp'],16)==107*4 and selected==int(audit['expected_running_tail'],16)
 assert initial[107]==0 and replayed[107]==selected
 assert all(a==b for i,(a,b)in enumerate(zip(initial,replayed))if i!=107)
 for name,data in [('initial.hex',initial),('replayed.hex',replayed)]:
  (out/name).write_text(''.join(f'{w:08x}\n'for w in data))
 for name in ['matcher.svh','tb_matcher.sv']:(out/name).write_bytes((HERE/name).read_bytes())
 write(out/'selection.json',dict(source='690b22e8e528f2d55e998967a9fb62b6a82ff333',parent_model='b0fffeeb4a7ec0173f63757fa2a67a6f5b7b0c88b7465003d2a3e74935b51be7',stub_sha256=sha(binary),actual_image_sha256=sha(image.read_bytes()),existing_extraction_sha256=sha(audit_path.read_bytes()),tables={'arm9':t9,'arm7':t7},selected_tail=f'{selected:08x}',tramp_word=107,stub_words=137,captured_writes=writes,fixture='Initial bound548bytes plus ordered retained actual kind56 writes. A reconstruction fixture, not a newly captured live137word dump or full physical write-completion proof.',live_discriminator_missing='Current137paired-chip words at held original point; exact selected match needs that view. RemainingARM7/bridge owners stay unknown.',proposal_enable=0,raw_scans=0,native_game_runs=0))
 write(out/'source-binding.json',{n:sha((out/n).read_bytes())for n in ['matcher.svh','tb_matcher.sv','initial.hex','replayed.hex','selection.json']})
 return dict(selected_tail=f'{selected:08x}',arm9_halted=t9['halted'],arm7_halted=t7['halted'],raw_scans=0,native_game_runs=0)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--parent',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();print(json.dumps(prepare(a.parent.resolve(),a.out.resolve()),indent=2))
