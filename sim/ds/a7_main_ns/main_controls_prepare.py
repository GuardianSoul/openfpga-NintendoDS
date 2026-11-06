"""Prepare current-PHY checks against the immutable a540 MAIN/shift evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
OLD = Path("/home/user/Git/NDS_Pocket-codex-a7-if-phase-receiver/build")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", required=True, type=Path)
args = parser.parse_args()
dest = args.out.resolve()
dest.mkdir(parents=True, exist_ok=False)
head = OLD / "a7-if-head-v2"
controls = OLD / "a7-if-head-controls-v2"
for name in ["source", "inputs", "helpers"]:
    shutil.copytree(head / name, dest / name)
shutil.copytree(controls / "shift-source", dest / "shift-source")
for name in ["run-inputs.json"]:
    shutil.copy2(head / name, dest / name)
shutil.copy2(head / "on/model.json", dest / "model.json")
for directory in ["source", "shift-source"]:
    shutil.copy2(ROOT / "rtl/pocket/nds_psram.sv", dest / directory / "nds_psram.sv")
for name in ["u1", "u2", "u3", "u4", "ms", "ml", "ma"]:
    for n in [4, 16]:
        for ext in ["state", "data", "edge", "full", "pins", "slot", "phase", "csv"]:
            target = dest / "previous-main" / f"{name}-n{n}.{ext}"
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(head / "on" / target.name, target)
for role, scenarios in [("adverse", [1, 2, 3, 4, 5]), ("shift", [0, 1, 5])]:
    for scenario in scenarios:
        for ext in ["state", "data", "log"]:
            target = dest / ("previous-" + role) / f"s{scenario}.{ext}"
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(controls / role / target.name, target)
shutil.copy2(__file__, dest / "prepare.py")
shutil.copy2(Path(__file__).with_name("main_controls_worker.py"), dest / "worker.py")
common = (ROOT / "sim/ds/a7_if_phase_receiver/qualify_worker.py").read_text().split("\ntry:\n", 1)[0]
(dest / "runner_functions.py").write_text(common)
(dest / "configuration.json").write_text(json.dumps(dict(main_only=False)) + "\n")
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
(dest / "inputs.json").write_text(json.dumps({
    str(p.relative_to(dest)): sha(p) for p in dest.rglob("*") if p.is_file()
}, indent=2) + "\n")
print(dest)
