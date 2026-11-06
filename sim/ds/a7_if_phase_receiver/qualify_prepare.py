"""Reuse the pinned head-return model for timing repeats and adverse controls."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--head", type=Path, default=ROOT / "build/a7-if-head-v1")
parser.add_argument("--main-only", action="store_true")
args = parser.parse_args()
old = args.head.resolve()
dest = args.out.resolve()
dest.mkdir(parents=True, exist_ok=False)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
model = json.loads((old / "on/model.json").read_text())
assert sha(old / "on/obj/Vtb") == model["sha256"]
for path, digest in model["inputs"].items():
    assert sha(old / path) == digest, path
for directory in ["source", "inputs", "reference", "helpers"]:
    shutil.copytree(old / directory, dest / directory)
for name in ["run-inputs.json", "timings.json"]:
    shutil.copy2(old / name, dest / name)
shutil.copy2(old / "on/obj/Vtb", dest / "retained-Vtb")
shutil.copy2(old / "on/model.json", dest / "model.json")
extensions = ["state", "data", "edge", "full", "pins", "slot", "phase", "csv", "head"]
for name in ["u1", "u2", "u3", "u4", "ms", "ml", "ma"]:
    for n in [4, 16]:
        for ext in extensions:
            source = old / "on" / f"{name}-n{n}.{ext}"
            target = dest / "baseline" / source.name
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(source, target)
shutil.copy2(Path(__file__).with_name("qualify_worker.py"), dest / "worker.py")
shutil.copy2(__file__, dest / "prepare.py")
(dest / "configuration.json").write_text(json.dumps(dict(main_only=args.main_only)) + "\n")
(dest / "inputs.json").write_text(json.dumps({
    str(p.relative_to(dest)): sha(p) for p in dest.rglob("*") if p.is_file()
}, indent=2) + "\n")
print(dest)
