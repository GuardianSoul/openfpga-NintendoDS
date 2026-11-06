#!/usr/bin/env python3
"""Prepare only the new selection/native binding overlay; do not run old suites."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/serv-rf36"
OUT.mkdir(parents=True, exist_ok=True)
RF = ROOT / "rtl/serv/serv_rf_ram.v"
OLD = ROOT / "docs/results/serv-rf-mlab-20261101"


def select(text, defs):
    active, stack, result = True, [], []
    defs = set(defs)
    for line in text.splitlines(True):
        m = re.match(r"\s*`(ifdef|ifndef|elsif|else|endif|define|undef)\b\s*(\w*)", line)
        if not m:
            if active:
                result.append(line)
            continue
        cmd, name = m.groups()
        if cmd in ["ifdef", "ifndef"]:
            yes = (name in defs) == (cmd == "ifdef")
            stack.append([active, yes]); active = active and yes
        elif cmd == "elsif":
            parent, taken = stack[-1]; yes = not taken and name in defs
            active = parent and yes; stack[-1][1] |= yes
        elif cmd == "else":
            parent, taken = stack[-1]; active = parent and not taken; stack[-1][1] = True
        elif cmd == "endif":
            active = stack.pop()[0]
        elif active:
            if cmd == "define": defs.add(name)
            else: defs.discard(name)
    assert not stack
    return "".join(result)


def tokens(s):
    return re.findall(r"\w+|[^\s]", re.sub(r"/\*.*?\*/|//[^\n]*", "", s, flags=re.S))


def change(s, old, new):
    assert s.count(old) == 1, old
    return s.replace(old, new, 1)


def prepare():
    subprocess.run(["python3", OLD / "verify.py"], check=True)  # hashes/receipts only
    s = RF.read_text()
    donor = (OLD / "candidate/serv_rf_ram.v").read_text()
    native = (OLD / "before_serv_rf_ram.v").read_text()
    profiles = {"main": [], "compact_off": ["NDS_SERV_RF_NATIVE36"],
                "explicit_on": ["NDS_SERV_RF_MLAB36"],
                "compact_on": ["NDS_SERV_RF_NATIVE36", "NDS_SERV_RF_MLAB36"]}
    for clear in [False, True]:
        for name, defs in profiles.items():
            defs = defs + (["SERV_CLEAR_RAM"] if clear else [])
            selected = select(s, defs)
            expected = native if name == "compact_off" else donor
            assert tokens(selected) == tokens(select(expected, defs)), (name, clear)
            (OUT / f"{name}-clear{int(clear)}.v").write_text(selected)
    prod = change(select(s, []), "module serv_rf_ram", "module production_rf")
    (OUT / "production.v").write_text(prod)
    (OUT / "original.v").write_text(change(select(native, []), "module serv_rf_ram", "module original_rf"))
    mlab = change(select(s, []), "module serv_rf_ram", "module native_mlab_rf")
    mlab = change(mlab, '   (* ramstyle = "MLAB, no_rw_check" *) reg [width-1:0] memory [0:depth-1];',
        """   wire [width-1:0] physical_q;
   altdpram #(.width(width),.widthad($clog2(depth)),.numwords(depth),
      .ram_block_type("MLAB"),.intended_device_family("Cyclone V"),
      .indata_reg("INCLOCK"),.wraddress_reg("INCLOCK"),.wrcontrol_reg("INCLOCK"),
      .rdaddress_reg("UNREGISTERED"),.rdcontrol_reg("UNREGISTERED"),.outdata_reg("UNREGISTERED"),
      .indata_aclr("OFF"),.wraddress_aclr("OFF"),.wrcontrol_aclr("OFF"),
      .rdaddress_aclr("OFF"),.rdcontrol_aclr("OFF"),.outdata_aclr("OFF")) physical(
      .wren(pending_wen),.data(pending_data),.wraddress(pending_addr),
      .inclock(i_clk),.inclocken(1'b1),.rden(1'b1),.rdaddress(i_raddr),
      .wraddressstall(1'b0),.rdaddressstall(1'b0),.byteena(1'b1),
      .outclock(i_clk),.outclocken(1'b1),.aclr(1'b0),.sclr(1'b0),.q(physical_q));""")
    mlab = change(mlab, "      if (pending_wen)\n        memory[pending_addr] <= pending_data;\n", "")
    mlab = mlab.replace("memory[i_raddr]", "physical_q")
    # Intel's tri-state inputs are coerced to inout by Icarus; declarations
    # must precede the primitive instance so pending signals bind correctly.
    a = mlab.index("   altdpram #(")
    b = mlab.index(".q(physical_q));", a) + len(".q(physical_q));")
    inst = mlab[a:b]
    mlab = mlab[:a] + mlab[b:]
    mlab = change(mlab, "   always @(posedge i_clk) begin", inst + "\n\n   always @(posedge i_clk) begin")
    (OUT / "native_mlab.v").write_text(mlab)
    # The only new fault is in the actual native read-address binding.
    fault = change(mlab, ".rdaddress(i_raddr)", ".rdaddress(i_raddr ^ 9'd1)")
    (OUT / "fault.v").write_text(fault)
    vendor = Path("build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v")
    build = (ROOT / "scripts/build_ds.sh").read_text()
    block = build[build.index("  # Main defaults to its qualified donor."):build.index("  echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY")]
    public = {}
    for name, defs in profiles.items():
        env = dict(os.environ, POCKET_SERV_RF_NATIVE36=str(int("NDS_SERV_RF_NATIVE36" in defs)),
                   POCKET_SERV_RF_MLAB36=str(int("NDS_SERV_RF_MLAB36" in defs)))
        lines = subprocess.check_output(["bash", "-c", block], env=env, text=True).splitlines()
        emitted = [l.split()[-1] for l in lines]
        assert emitted == defs, (name, emitted, defs)
        public[name] = lines
    receipt = {"source_SHA": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "selection_profiles": profiles, "clear_profiles": [0, 1],
        "literal_token_inverse": "PASS all8: main/on=accepted donor; compact_off=literal native",
        "accepted_evidence_reused": "3ac72186 four-state/CPU/forwarding-fault receipts; no suite rerun",
        "binding": "Fixture adapters for previously fitted altdpram512x2 MLAB and altsyncram512x2 M10K; not captured mapped netlists",
        "native_vendor_sha256": hashlib.sha256(vendor.read_bytes()).hexdigest(),
        "source_sha256": hashlib.sha256(s.encode()).hexdigest(),
        "public_build_emissions": public,
        "build_sha256": hashlib.sha256(build.encode()).hexdigest(),
        "fixtures": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in OUT.glob("*.v")}}
    (OUT / "selection.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("SELECT36 PASS8 literal profiles; closed proof receipt verified, no simulation")


if __name__ == "__main__":
    prepare()
