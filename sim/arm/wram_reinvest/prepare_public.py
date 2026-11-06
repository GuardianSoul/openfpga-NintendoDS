#!/usr/bin/env python3
"""Generate settings and a full APF frontend command; never invoke Quartus."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
source = (ROOT / "scripts/build_ds.sh").read_text()
prefix = source[:source.index("\nset +e\n")]
assert not re.search(r"^quartus_", prefix, re.M)
old = 'root=$(cd "$(dirname "$0")/.." && pwd)'
assert prefix.count(old) == 1
generator = out / "generate-settings-only.sh"
generator.write_text(prefix.replace(old, "root=" + shlex.quote(str(ROOT))) + "\n")
for enabled in [0, 1]:
    subprocess.run(["bash", str(generator), str(out / ("settings" + str(enabled))), "1asR"],
                   check=True, env=dict(os.environ, WRAM_REINVEST=str(enabled)), stdout=subprocess.DEVNULL)
qsf = (out / "settings1/apf_top.qsf").read_text()
files = re.findall(r'^set_global_assignment -name (?:SYSTEMVERILOG_FILE|VERILOG_FILE) "([^"]+)"$', qsf, re.M)
defines = re.findall(r"^set_global_assignment -name VERILOG_MACRO (\S+)$", qsf, re.M)
omitted = {"rtl/apf/mf_audio_pll.v", "rtl/apf/mf_audio_pll_0002.v", "rtl/apf/mf_datatable.v", "rtl/pocket/nds_pll_ds.sv"}
packages = ["rtl/arm/arm_pkg.sv", "rtl/gpu2d/gpu2d_pkg.sv", "rtl/gpu3d/gpu3d_pkg.sv", "rtl/gpu3d/gpu3d_gxu_pkg.sv"]
files = [str(ROOT / p) for p in packages] + [f for f in files if str(Path(f).relative_to(ROOT)) not in omitted | set(packages)]
adapters = ["sim/arm/dctrl_public/apf_io_primitive.sv", "sim/phase1/sim_prims.sv", "sim/pocket_ds/sim_prims_ds.sv", "sim/probe/mf_datatable_model.sv"]
files.extend(str(ROOT / p) for p in adapters)
command = ["build/tools/oss-cad-suite/bin/verilator", "--bbox-unsup", "--timing", "--assert", "--threads", "1", "-j", "1", "-Wno-fatal", "--timescale", "1ns/1ps", "--top-module", "apf_top", "--cc", "--Mdir", str(out / "cc")]
command += ["-I" + str(ROOT / "rtl" / p) for p in ["pocket", "sound", "apf"]]
command += ["+define+" + d for d in defines] + files
(out / "public-command.json").write_text(json.dumps(command, indent=2) + "\n")
(out / "frontend-adapters.json").write_text(json.dumps(dict(qsf_omitted=sorted(omitted), simulation_added=adapters), indent=2) + "\n")
print("PASS_SETTINGS_ONLY_NO_QUARTUS", len(files), "frontend files")
