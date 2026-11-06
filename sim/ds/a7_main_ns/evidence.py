"""Thin public proof of the physical IF-head address correction."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[3]
PARENT = ROOT / "docs/results/a7-if-phase-receiver-20261102/evidence.tar.gz"
PARENT_SHA = "7fc1a040b699cca981296a19f75da364128dbd1a64310e0f67eb1b8a26ad40e8"
CAPSULES = ["a7-main-ns-observe-v1", "a7-main-ns-head-fault-v1",
            "a7-main-ns-head-fixed-v1", "a7-main-ns-main-controls-v1"]
sha = lambda data: hashlib.sha256(data).hexdigest()


def pack(path):
    assert sha(PARENT.read_bytes()) == PARENT_SHA
    with tarfile.open(PARENT) as archive:
        inherited = {member.name[6:] for member in archive if member.name.startswith("blobs/")}
    manifest = {}
    seen = set(inherited)
    new = 0
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w:gz") as archive:
        def add(name, data):
            nonlocal new
            digest = sha(data)
            manifest[name] = digest
            if digest not in seen:
                info = tarfile.TarInfo("blobs/" + digest)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
                seen.add(digest)
                new += 1
        for capsule in CAPSULES:
            base = ROOT / "build" / capsule
            for file in sorted(base.rglob("*")):
                if not file.is_file() or file.is_symlink():
                    continue
                relative = file.relative_to(base)
                if "obj" in relative.parts and file.name not in ["Vtb", "Vtb__verFiles.dat"]:
                    continue
                add(capsule + "/" + str(relative), file.read_bytes())
        before = subprocess.check_output(["git", "show", "a5400c9e:rtl/pocket/nds_psram.sv"], cwd=ROOT)
        after = (ROOT / "rtl/pocket/nds_psram.sv").read_bytes()
        # The deliberate inverse is exactly the already-compiled actual old RTL.
        inverse = after.replace(b"    // IF8 starts at the captured quad, which need not be 32-byte aligned.\n"
                                b"    // Its retained second quad still uses this original physical base.\n", b"")
        inverse = inverse.replace(b"IF_HEAD_RETURN ? b_word + {18'd0, out_k} : 21'd0;",
                                  b"IF_HEAD_RETURN ? (b_n8 ? {b_word[20:3], out_k} : {b_word[20:2], out_k[1:0]}) : 21'd0;")
        assert inverse == before
        add("production/before.sv", before)
        add("production/after.sv", after)
        add("production/inverse-mutant.sv", inverse)
        data = json.dumps(dict(schema=1, parent_sha256=PARENT_SHA, files=manifest), sort_keys=True).encode()
        info = tarfile.TarInfo("manifest.json")
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    return dict(archive_sha256=sha(path.read_bytes()), parent_sha256=PARENT_SHA,
                logical_files=len(manifest), new_blobs=new)


def replay(path):
    assert sha(PARENT.read_bytes()) == PARENT_SHA
    blobs = {}
    for packet in [PARENT, path]:
        with tarfile.open(packet) as archive:
            if packet == path:
                metadata = json.load(archive.extractfile("manifest.json"))
            for member in archive:
                if member.name.startswith("blobs/"):
                    data = archive.extractfile(member).read()
                    assert sha(data) == member.name[6:]
                    blobs[member.name[6:]] = data
    assert metadata["parent_sha256"] == PARENT_SHA
    files = metadata["files"]
    read = lambda name: blobs[files[name]]
    js = lambda name: json.loads(read(name))
    for capsule in CAPSULES:
        for name, digest in js(capsule + "/inputs.json").items():
            # Build directories are intentionally excluded, never public inputs.
            assert files[capsule + "/" + name] == digest, (capsule, name)
    before, after = read("production/before.sv"), read("production/after.sv")
    assert read("production/inverse-mutant.sv") == before
    fault = "a7-main-ns-head-fault-v1"
    assert read(fault + "/source/nds_psram.sv") == before
    fault_stem = fault + "/runs/b_s32_o8-r1-n4"
    assert js(fault_stem + ".process.json")["exit"] != 0
    assert b"HEAD_PHYSICAL_WORD_IDENTITY mode1 actual0f6c08 expected0f6c0c" in read(fault_stem + ".log")
    fixed = "a7-main-ns-head-fixed-v1"
    main = "a7-main-ns-main-controls-v1"
    for name in [fixed + "/source/nds_psram.sv", main + "/source/nds_psram.sv", main + "/shift-source/nds_psram.sv"]:
        assert read(name) == after
    rows = js(fixed + "/results.json")
    assert len(rows) == 36
    counts = {"total": 0, "unaligned": 0}
    for row in rows:
        cycles = {0: {}, 1: {}}
        for n in [4, 16]:
            suffix = f'{row["case"]}-r{row["region"]}-n{n}'
            stem = fixed + "/runs/" + suffix
            text = read(stem + ".log")
            assert b"FETCH39_FUNCTION_PASS" in text
            for mode in [0, 1]:
                cycles[mode][n] = int(re.search(rb"PHYS_PASS mode" + str(mode).encode() + rb" cycles(\d+)", text)[1])
                for ext in ["csv", "data", "fcomp"]:
                    assert read(stem + f"-m{mode}." + ext) == read(fixed + "/previous/" + suffix + f"-m{mode}." + ext)
            match = re.search(rb"HEAD_IDENTITY_COUNTS mode1 total(\d+) unaligned(\d+)", text)
            counts["total"] += int(match[1])
            counts["unaligned"] += int(match[2])
            previous_log = read(fixed + "/previous/" + suffix + ".log")
            assert cycles[0][n] == int(re.search(rb"PHYS_PASS mode0 cycles(\d+)", previous_log)[1])
        value = cycles[1][16] - cycles[1][4]
        assert value == row["actual_delta_core"]
        assert abs(value-row["DS_delta_core"]) <= abs(row["before_delta_core"]-row["DS_delta_core"])
    assert counts == dict(total=93952, unaligned=66384)
    assert sum(r["actual_delta_core"] != r["before_delta_core"] for r in rows) == 15
    normalized = lambda data: ["RESET" if line.startswith("RESET,") else ",".join(line.split(",")[1:])
                               for line in data.decode().splitlines()]
    targets = dict(u1=14184, u2=14184, u3=14184, u4=15720, ms=14184, ml=15720, ma=14952)
    for name, target in targets.items():
        for rep in range(5):
            elapsed = {}
            for n in [4, 16]:
                stem = main + f"/on/{name}-r{rep}-n{n}"
                elapsed[n] = int(re.search(rb"MUL_PHASE_PASS[^\n]*elapsed(\d+)", read(stem + ".log"))[1])
                assert b"PHASE_FUNCTION_PASS errors0" in read(stem + ".log")
                if rep:
                    for ext, digest in js(stem + ".capture-hashes.json")["sha256"].items():
                        assert digest == files[main + f"/on/{name}-r0-n{n}.{ext}"]
                else:
                    for ext in ["state", "data", "edge", "full", "pins", "slot", "phase", "csv"]:
                        assert read(stem + "." + ext) == read(main + f"/previous-main/{name}-n{n}.{ext}")
            assert elapsed[16] - elapsed[4] == target
    for role, scenarios in [("adverse", range(1, 6)), ("shift", [0, 1, 5])]:
        for scenario in scenarios:
            for ext in ["state", "data"]:
                current = normalized(read(main + f"/{role}/s{scenario}.{ext}"))
                previous = normalized(read(main + f"/previous-{role}/s{scenario}.{ext}"))
                if role == "adverse" and scenario == 2:
                    current = current[current.index("RESET") + 1:]
                    previous = previous[previous.index("RESET") + 1:]
                assert current == previous
    return dict(status="PASS", logical_files=len(files), fetch39_functional=36,
                closer=15, unchanged=21, wider=0, head_identity_checks=counts,
                MAIN_DS_exact_pairs=35, adverse=5, shift=3, caught_actual_inverse=True,
                area="unmeasured", b_s32_o8="25224 vsDS20328 stillOPEN")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["pack", "replay"])
    parser.add_argument("packet", type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    result = pack(args.packet) if args.mode == "pack" else replay(args.packet)
    args.receipt.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
