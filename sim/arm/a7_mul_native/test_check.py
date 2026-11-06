#!/usr/bin/env python3
"""Exercise the dump oracle with DS records and coherent payload faults.

The constructed RAM is an oracle fixture, never a native execution result.
"""
from pathlib import Path
import argparse, importlib.util, json, struct
from check import check, CP15, oracle

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('base', type=Path)
p.add_argument('--dump', type=Path, help='exercise the actual qualified native dump instead of the oracle fixture')
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
ram = bytearray(4*1024*1024)
struct.pack_into('<3I', ram, 0x230000, 0x414d5831, 6, 0)
struct.pack_into('<3I', ram, 0x230000+24*4, 0xe880, 0x02ff000a, 0x20)
struct.pack_into('<5I', ram, 0x3f0000, 0x52545344, 1, 1, 1, 6)
helper = (a.base/'inputs/helper.bin').read_bytes()
for offset in [0x220000, 0x221000]: ram[offset:offset+2024] = helper
for i in range(6):
    case, region = divmod(i, 2)
    raw = (a.base/'inputs'/f'a7mulmix_v1_k{case:02d}_r{region}.bin').read_bytes()
    ram[0x200000+i*0x1800:0x200000+i*0x1800+4128] = raw
    struct.pack_into('<32I', ram, 0x231000+i*128, *(CP15*2))
if a.dump:
    ram = bytearray(a.dump.read_bytes())
baseline = check(a.base, ram)
if not a.dump:
    assert baseline['all_paired_slopes_exact']
caught = {}
def fault(name, mutate):
    b = bytearray(ram)
    mutate(b)
    try: check(a.base, b)
    except ValueError as e: caught[name] = str(e)
    else: raise AssertionError('uncaught actual payload mutation: '+name)

fault('missing60thSample', lambda b: struct.pack_into('<I', b, 0x200000+5*0x1800+224+9*288+4, 0))
def coherent_sp(b):
    start = 0x200000+256
    for offset in [13*4, 64+13*4]:
        struct.pack_into('<I', b, start+offset, 0x0380fce0)
    struct.pack_into('<I', b, 0x200000+224+16, oracle.fnv(b[start:start+128]))
fault('wrongWrapperSP', coherent_sp)
fault('quietHelperInstruction', lambda b: b.__setitem__(0x220000+40, b[0x220000+40]^1))
fault('ARM9Context', lambda b: struct.pack_into('<I', b, 0x231000, 0x55079))
def coherent_rs6(b):
    start = 0x200000+256
    struct.pack_into('<I', b, start+6*4, 0x7fff)
    struct.pack_into('<I', b, start+64+6*4, 0x7fff)
    struct.pack_into('<I', b, 0x200000+224+16, oracle.fnv(b[start:start+128]))
fault('rehashedRs6', coherent_rs6)
def coherent_kernel(b):
    start = 0x200000
    for at in [3104, 3616]: struct.pack_into('<I', b, start+at+4, 0xe1a00000)
    digest = oracle.fnv(b[start+3104:start+3376])
    struct.pack_into('<2I', b, start+48, digest, digest)
fault('rehashedFirstMULtoNOP', coherent_kernel)
# Valid contrary timing must survive the state checker and remain unequal.
b = bytearray(ram)
offset = 0x200000+0x1800+224+9*288+4
value = struct.unpack_from('<I', b, offset)[0]
struct.pack_into('<I', b, offset, value+1)
contrary = check(a.base, b)
assert not contrary['all_paired_slopes_exact']
assert contrary['rows'][1]['native_ticks'][-1] == baseline['rows'][1]['native_ticks'][-1]+1
result = dict(status='PASS oracle fixture and six actual payload faults',
              fixture='Actual qualified native dump' if a.dump else 'DS records plus constructed completion/context; NOT native simulation evidence',
              groups=baseline['groups'], register_words=baseline['register_words'],
              caught=caught, valid_contrary_timing_retained=True)
a.out.write_text(json.dumps(result, indent=2)+'\n')
print(result['status'])
