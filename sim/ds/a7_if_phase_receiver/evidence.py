"""Deduplicate retained public evidence; replay hashes and measured verdicts offline."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[3]
CAPSULES = ["a7-if-phase-receiver-v1", "a7-if-phase-receiver-v2",
            "a7-if-head-v1", "a7-if-head-v2", "a7-if-head-qualify-v1",
            "a7-if-head-qualify-v2", "a7-if-head-controls-v1",
            "a7-if-head-controls-v2", "a7-if-head-controls-v3"]
sha = lambda data: hashlib.sha256(data).hexdigest()


def pack(path):
    manifest = {}
    seen = set()
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w:gz") as archive:
        def add(name, data):
            digest = sha(data)
            manifest[name] = digest
            if digest not in seen:
                info = tarfile.TarInfo("blobs/" + digest)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
                seen.add(digest)
        for capsule in CAPSULES:
            for file in sorted((ROOT / "build" / capsule).rglob("*")):
                if not file.is_file() or file.is_symlink():
                    continue
                relative = file.relative_to(ROOT / "build" / capsule)
                if "obj" in relative.parts and file.name not in ["Vtb", "Vtb__verFiles.dat"]:
                    continue
                add(capsule + "/" + str(relative), file.read_bytes())
        for name in ["rtl/ds/nds_arm7_port.sv", "rtl/pocket/nds_psram.sv"]:
            add("production/after/" + Path(name).name, (ROOT / name).read_bytes())
            add("production/before/" + Path(name).name,
                subprocess.check_output(["git", "show", "0a5a1cee:" + name], cwd=ROOT))
        add("production/p7_ledger.svh", (ROOT / "sim/arm/a7_logical_slot/p7_ledger.svh").read_bytes())
        reference = Path("/home/user/Git/NDS_Pocket-cpu-main-contract/docs/results/a7-main-observable-contract-20261102/inputs")
        for name in ["mul.json", "mixed.json", "ds39.json", "discriminator.json"]:
            add("DS/" + name, (reference / name).read_bytes())
        data = json.dumps(dict(schema=1, files=manifest), sort_keys=True).encode()
        info = tarfile.TarInfo("manifest.json")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    return dict(archive_sha256=sha(path.read_bytes()), logical_files=len(manifest), blobs=len(seen))


def replay(path):
    with tarfile.open(path) as archive:
        manifest = json.load(archive.extractfile("manifest.json"))["files"]
        blobs = {}
        for member in archive:
            if member.name == "manifest.json":
                continue
            assert member.name.startswith("blobs/") and member.isfile()
            digest = member.name[6:]
            data = archive.extractfile(member).read()
            assert sha(data) == digest
            blobs[digest] = data
    assert set(blobs) == set(manifest.values())
    read = lambda name: blobs[manifest[name]]
    js = lambda name: json.loads(read(name))
    elapsed = lambda name: int(re.search(rb"MUL_PHASE_PASS[^\n]*elapsed(\d+)", read(name))[1])
    head = "a7-if-head-v2"
    repeats = "a7-if-head-qualify-v2"
    expected = dict(u1=14184, u2=14184, u3=14184, u4=15720, ms=14184, ml=15720, ma=14952)
    for name, target in expected.items():
        for rep in range(5):
            stem = head + "/on/" + name if rep == 0 else repeats + "/main/" + name + "-r" + str(rep)
            assert elapsed(stem + "-n16.log") - elapsed(stem + "-n4.log") == target
            for n in [4, 16]:
                assert b"PHASE_FUNCTION_PASS errors0" in read(stem + f"-n{n}.log")
                if rep:
                    receipt = js(stem + f"-n{n}.capture-hashes.json")
                    assert receipt["literal_equal"]
                    for ext, digest in receipt["sha256"].items():
                        assert digest == sha(read(head + f"/on/{name}-n{n}.{ext}"))
    for ext in ["state", "data", "edge", "full", "pins", "slot"]:
        assert read(head + "/observe/u1-n4." + ext) == read(head + "/previous-u1-n4." + ext)
    fault = head + "/head-fault/u1"
    assert js(fault + ".process.json")["exit"] != 0
    assert b"MUL_FETCH_WORD" in read(fault + ".log")
    owner = "a7-if-phase-receiver-v2/wrong-owner/c2"
    assert js(owner + ".process.json")["exit"] != 0
    assert b"PHASE_RX_CAPTURE_OWNER" in read(owner + ".log")
    normalized = lambda data: [",".join(line.split(",")[1:]) if not line.startswith("RESET,") else "RESET"
                               for line in data.decode().splitlines()]
    controls = "a7-if-head-controls-v2"
    for scenario in range(1, 6):
        for ext in ["state", "data"]:
            current = normalized(read(controls + f"/adverse/s{scenario}.{ext}"))
            prior = normalized(read(controls + f"/reference/c1-s{scenario}-p1/{ext}"))
            if scenario == 2:
                current = current[current.index("RESET") + 1:]
                prior = prior[prior.index("RESET") + 1:]
            assert current == prior
    for scenario in [0, 1, 5]:
        for ext in ["state", "data"]:
            assert normalized(read(controls + f"/shift/s{scenario}.{ext}")) == normalized(
                read(controls + f"/shift-reference/s{scenario}.{ext}"))
    fetch = js("a7-if-head-controls-v3/results.json")["fetch39"]
    ds = js("DS/ds39.json")["summaries"]
    assert len(fetch) == 36
    for row in fetch:
        target = next(x for x in ds if x["name"] == row["case"] and
                      x["region"] == ("MAIN" if row["region"] else "private_WRAM"))
        expected_delta = 2 * (target["min16"] - target["min4"])
        assert row["DS_delta_core"] == expected_delta
        ticks = {0: {}, 1: {}}
        for n in [4, 16]:
            suffix = f'/fetch/{row["case"]}-r{row["region"]}-n{n}'
            prefix = "a7-if-head-controls-v3" if "a7-if-head-controls-v3" + suffix + ".log" in manifest else controls
            stem = prefix + suffix
            for mode in [0, 1]:
                match = re.search(rb"PHYS_PASS mode" + str(mode).encode() + rb" cycles(\d+)", read(stem + ".log"))
                ticks[mode][n] = int(match[1])
            for ext in ["csv", "data", "fcomp"]:
                assert read(stem + "-m0." + ext) == read(stem + "-m1." + ext)
        before, after = (ticks[m][16] - ticks[m][4] for m in [0, 1])
        assert (before, after) == (row["before_delta_core"], row["actual_delta_core"])
        assert abs(after-expected_delta) <= abs(before-expected_delta)
    for name in ["nds_arm7_port.sv", "nds_psram.sv"]:
        production = read("production/after/" + name)
        if name == "nds_arm7_port.sv":
            fixture = production.replace(b"module nds_arm7_port #(", b"module nds_arm7_port_slot_trial #(", 1)
            marker = b"    // simulation (+a7dbg):"
            fixture = fixture.replace(marker, read("production/p7_ledger.svh") + b"\n" + marker, 1)
            assert fixture == read(head + "/source/p7.sv")
        else:
            assert production == read(head + "/source/nds_psram.sv")
    return dict(status="PASS", logical_files=len(manifest), blobs=len(blobs),
                MAIN_DS_exact_pairs=35, adverse=5, register_shift=3,
                fetch39_functional=36, fetch39_unchanged=32, fetch39_closer=4,
                fetch39_DS_exact=18, area="unmeasured", public_integration="pending")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["pack", "replay"])
    parser.add_argument("packet", type=Path)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    result = pack(args.packet) if args.mode == "pack" else replay(args.packet)
    args.receipt.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
