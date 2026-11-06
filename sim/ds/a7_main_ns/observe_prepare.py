"""One new passive journal on the retained a540 paired fetch executable."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
OLD = Path("/home/user/Git/NDS_Pocket-codex-a7-if-phase-receiver/build/a7-if-head-controls-v3")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", required=True, type=Path)
args = parser.parse_args()
dest = args.out.resolve()
dest.mkdir(parents=True, exist_ok=False)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
metadata = json.loads((OLD / "fetch/model.json").read_text())
assert sha(OLD / "fetch/obj/Vtb") == metadata["sha256"]
for name, digest in metadata["inputs"].items():
    assert sha(OLD / name) == digest
shutil.copytree(OLD / "fetch-source", dest / "source")
shutil.copytree(OLD / "helpers", dest / "helpers")
shutil.copy2(OLD / "fetch/obj/Vtb", dest / "retained-Vtb")
shutil.copy2(OLD / "fetch/model.json", dest / "model.json")
shutil.copy2(OLD / "fetch-images/b_s32_o8.hex", dest / "image.hex")
for n in [4, 16]:
    for suffix in [".log", ".process.json", *[f"-m{m}.{ext}" for m in [0, 1] for ext in ["csv", "data", "fcomp"]]]:
        shutil.copy2(OLD / f"fetch/b_s32_o8-r1-n{n}{suffix}", dest / f"previous-n{n}{suffix}")
shutil.copy2(__file__, dest / "prepare.py")
shutil.copy2(Path(__file__).with_name("observe_worker.py"), dest / "worker.py")
command = json.loads((dest / "previous-n16.process.json").read_text())["command"]
command[0] = str(dest / "retained-Vtb")
replace = {"+img": str(dest / "image.hex"), "+trace": str(dest / "observed"),
           "+data": str(dest / "observed")}
command = [replace.get(v.split("=", 1)[0], None) and v.split("=", 1)[0] + "=" + replace[v.split("=", 1)[0]] or v
           for v in command]
command.append("+events=" + str(dest / "events"))
(dest / "command.json").write_text(json.dumps(command, indent=2) + "\n")
fields = "cycle ir ia io iseq redirect consume flow_v flow_left fr fa fseq fword ack rv rp_k fab_st fab_hit mr_req mr_ack mr_rvalid phy_busy phy_state phy_n0 phy_n1 phy_out_n phy_wc phy_strm".split()
(dest / "fields.json").write_text(json.dumps(fields, indent=2) + "\n")
(dest / "inputs.json").write_text(json.dumps({
    str(p.relative_to(dest)): sha(p) for p in dest.rglob("*") if p.is_file()
}, indent=2) + "\n")
print(dest)
