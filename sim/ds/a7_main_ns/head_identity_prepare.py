"""Pin the actual physical IF head identity before changing its address label."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
OLD = Path("/home/user/Git/NDS_Pocket-codex-a7-if-phase-receiver/build/a7-if-head-controls-v3")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", required=True, type=Path)
parser.add_argument("--negative", action="store_true")
args = parser.parse_args()
dest = args.out.resolve()
dest.mkdir(parents=True, exist_ok=False)
for source, target in [("fetch-source", "source"), ("helpers", "helpers"), ("fetch-images", "images")]:
    shutil.copytree(OLD / source, dest / target)
shutil.copy2(OLD / "fetch-cases.json", dest / "cases.json")
shutil.copy2(OLD / "ds39.json", dest / "ds39.json")
shutil.copy2(OLD / "results.json", dest / "previous-results.json")
previous = dest / "previous"
previous.mkdir()
# Preserve all previous state/data/fetch sequences and run counts, with no model rerun.
sources = [OLD, OLD.with_name("a7-if-head-controls-v2")]
for row in json.loads((dest / "previous-results.json").read_text())["fetch39"]:
    for n in [4, 16]:
        stem = f'{row["case"]}-r{row["region"]}-n{n}'
        source = next(p for p in sources if (p / "fetch" / (stem + ".log")).exists())
        for suffix in [".log", *[f"-m{m}.{ext}" for m in [0, 1] for ext in ["csv", "data", "fcomp"]]]:
            shutil.copy2(source / "fetch" / (stem + suffix), previous / (stem + suffix))
if not args.negative:
    shutil.copy2(ROOT / "rtl/pocket/nds_psram.sv", dest / "source/nds_psram.sv")
tb = (dest / "source/tb.sv").read_text()
observer = """
 // A read's raw physical base is captured from the actual main arbiter.
 // The published data index is the existing stream head, including IF8's
 // retained second quad. This check never drives a service/control signal.
 wire[20:0] expected_head_word=transport.u_phy.b_word+{18'd0,transport.u_phy.out_k};
 integer physical_head_checks=0,unaligned_head_checks=0;
 always @(posedge clk)if(!rst&&head_valid)begin
  physical_head_checks++;
  if(transport.u_phy.b_word[2])unaligned_head_checks++;
  assert(head_word==expected_head_word)else
   $fatal(1,"HEAD_PHYSICAL_WORD_IDENTITY mode%0d actual%h expected%h capturedbase%h index%0d payload%h",
    MODE,head_word,expected_head_word,transport.u_phy.b_word,transport.u_phy.out_k,head_data);
  if(({1'b0,expected_head_word}<<2)>=({1'b0,entry}&22'h3fffff)&&
     (({1'b0,expected_head_word}<<2)-({1'b0,entry}&22'h3fffff))<4096)
   assert(head_data==words[((expected_head_word<<2)-(entry&32'h3fffff))>>2])else
    $fatal(1,"HEAD_PHYSICAL_DATA_IDENTITY");
 end
 final $display("HEAD_IDENTITY_COUNTS mode%0d total%0d unaligned%0d",MODE,physical_head_checks,unaligned_head_checks);
"""
at = tb.index("endmodule")
tb = tb[:at] + observer + tb[at:]
assert tb.replace(observer, "", 1) == (OLD / "fetch-source/tb.sv").read_text()
(dest / "source/tb.sv").write_text(tb)
(dest / "configuration.json").write_text(json.dumps(dict(negative=args.negative)) + "\n")
shutil.copy2(__file__, dest / "prepare.py")
shutil.copy2(Path(__file__).with_name("head_identity_worker.py"), dest / "worker.py")
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
(dest / "inputs.json").write_text(json.dumps({
    str(p.relative_to(dest)): sha(p) for p in dest.rglob("*") if p.is_file()
}, indent=2) + "\n")
print(dest)
