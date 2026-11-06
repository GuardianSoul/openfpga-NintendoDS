#!/usr/bin/env python3
"""Check the two additive public forwards and reject disconnected-source faults."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
BASE = 'de6039a5'


def inverse(text, path):
    declaration = '    parameter bit A7_IF_COMMIT = 0 // local held-valid ARM7 MAIN owner, default off\n'
    forwarding = '.A7_IF_COMMIT(A7_IF_COMMIT), '
    assert text.count(declaration) == text.count(forwarding) == 1
    text = text.replace(declaration, '', 1).replace(forwarding, '', 1)
    if path == 'rtl/ds/nds_top.sv':
        text = text.replace('parameter integer DMA_GX = 0, //', 'parameter integer DMA_GX = 0     //', 1)
    else:
        text = text.replace("parameter [31:0] MS_CLOCKS = 32'd74250,", "parameter [31:0] MS_CLOCKS = 32'd74250", 1)
    return text


rows = []
for path in ('rtl/ds/nds_top.sv', 'rtl/pocket/core_top_ds.sv'):
    actual = (ROOT / path).read_text()
    previous = subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT).decode()
    assert inverse(actual, path) == previous, path
    mutant = actual.replace('.A7_IF_COMMIT(A7_IF_COMMIT)', ".A7_IF_COMMIT(1'b0)", 1)
    assert mutant != actual
    try:
        equal = inverse(mutant, path) == previous
    except AssertionError:
        equal = False
    assert not equal, ('escaped actual forwarding mutation', path)
    rows.append(dict(path=path, sha256=hashlib.sha256(actual.encode()).hexdigest(),
                     default0_inverse_exact=True, actual_forward0_mutant_caught=True))
print(json.dumps(dict(base=BASE, files=rows, result='PASS',
    scope='Public appended parameter/forward only; CPU/P7 production runtime and DS timing are separate.'), indent=2))
