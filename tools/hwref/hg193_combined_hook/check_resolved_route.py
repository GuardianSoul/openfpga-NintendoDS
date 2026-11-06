"""Existing-model resolved-five/default-metadata proof; never compile/run."""
import hashlib
import json
from pathlib import Path


def check(base):
    pin=json.loads((base/'model-pin.json').read_text())
    s=base/'snapshot/source'
    names=['rtl/arm/cpu_domain.sv','rtl/arm/arm_cpu.sv','rtl/arm/arm7_ds.sv',
        'rtl/ds/nds_top.sv','rtl/pocket/core_top_ds.sv']
    domain,cpu,a7,top,core=[(s/n).read_text()for n in names]
    assert 'parameter bit A7_STM4_META = 0'in domain and '.A7_STM4_META(A7_STM4_META)'in domain
    assert "parameter bit          A7_STM4_META = 1'b0"in cpu and '.STM4_META(A7_STM4_META)'in cpu
    assert "parameter bit          A7_EXEC_META = 1'b0"in cpu and '.A7_EXEC_META('not in domain
    assert 'parameter bit STM4_META = 0'in a7 and 'g_no_stm4_meta'in a7
    assert 'A7_STM4_META'not in top and 'A7_STM4_META'not in core
    plan=json.loads((base/'game-build-plan.json').read_text())
    assert not any('TB_CORE_PARAMS'in a and ('STM4_META'in a or 'EXEC_META'in a)for a in plan['argv'])
    header=base/'private-game-obj/Vtb_ds_pocket___024root.h'
    text=header.read_text();field='g_lup__DOT__u_light__DOT__g_five__DOT__u_products__DOT__epoch'
    assert field in text and 'g_original_products__DOT__u_products'not in text
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    assert sha(Path(pin['binary_path']))==pin['binary_sha256']
    return dict(model_sha256=pin['binary_sha256'],source=pin['source'],metadata_default_graph_off=True,
        actual_generated_five_route=True,generated_header_sha256=sha(header),actual_field=field,
        source_graph_files_sha256={str((s/n).relative_to(base)):sha(s/n)for n in names},
        verifier_sha256=sha(Path(__file__).resolve()),
        qualification_gap='Two new assertion modules were compiled but unbound. Actual five resolved in generated design; metadata0 proven by exact compiled-source defaults/propagation. Runtime Python enforces launch window/save/outputs. No claim those SV assertions executed; no rebuild.')
