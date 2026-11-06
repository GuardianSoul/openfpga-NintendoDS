"""Prepare remaining adverse cases, register shifts and captured DS39 fetches."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import tarfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", required=True, type=Path)
parser.add_argument("--head", type=Path, default=ROOT / "build/a7-if-head-v1")
parser.add_argument("--fetch-only", action="store_true")
parser.add_argument("--reuse-fetch", type=Path)
args = parser.parse_args()
dest = args.out.resolve()
dest.mkdir(parents=True, exist_ok=False)
old = args.head.resolve()
for directory in ["source", "inputs", "reference", "helpers"]:
    shutil.copytree(old / directory, dest / directory)
for name in ["run-inputs.json"]:
    shutil.copy2(old / name, dest / name)
shutil.copy2(old / "on/obj/Vtb", dest / "retained-Vtb")
shutil.copy2(old / "on/model.json", dest / "model.json")
shift = dest / "shift-source"
fetch = dest / "fetch-source"
shutil.copytree(old / "source", shift)
shutil.copytree(old / "source", fetch)
cpu_old = Path("/home/user/Git/NDS_Pocket-cpu-a7-i-phase-producer/build/i-phase-producer")
for scenario in [0, 1, 5]:
    previous = cpu_old / ("shift" if scenario == 0 else "shift2")
    for ext in ["state", "data"]:
        target = dest / "shift-reference" / f"s{scenario}.{ext}"
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(previous / f"s{scenario}.{ext}", target)

# These are the same component-only ORR substitutions qualified by CPU.
tb = (shift / "tb.sv").read_text()
tb = tb.replace("if(active&&in_body(cpu.pc)&&(cpu.esub==0||cpu.esub==1))mul_steps++;",
                "if(active&&in_body(cpu.pc)&&cpu.esub==0)mul_steps++;")
tb = tb.replace("if(!cpu_rst&&cpu.pipe_fire&&cpu.e_mul)begin", "if(!cpu_rst&&cpu.pipe_fire&&cpu.e_sr)begin")
tb = tb.replace("assert(cpu.opa==3&&cpu.opb==32'((cpu.ins[11:8]==6)?rs6:rs))",
                "assert(cpu.opa==3&&cpu.opb==3&&(cpu.ins==32'he1813231||cpu.ins==32'he1813631))")
tb = tb.replace("cpu.e_mul", "(cpu.e_mul||cpu.e_sr)")
tb = tb.replace("if((scenario==1||scenario==3)&&cpu.esub==1)begin",
                "if((scenario==1||scenario==3)&&cpu.esub==2&&cpu.phase_prepared)begin")
needle = "$readmemh(kernel_image,words);"
tb = tb.replace(needle, needle + """
  assert(kind==1&&rs==1&&rs6==1)else $fatal(1,"RSHIFT_FIXTURE_ARGUMENTS");
  for(int k=1;k<=64;k++)begin
   assert(words[k]==((k%2)?32'he0030291:32'he0030691))else $fatal(1,"RSHIFT_ORIGINAL_IMAGE");
   words[k]=(k%2)?32'he1813231:32'he1813631;
  end
""")
tb = tb.replace("  $fclose(phase_obs_fd);", """
  assert(phase_obs_starts==320&&phase_obs_advances==320&&phase_obs_accepts==320&&!phase_obs_cancels)
   else $fatal(1,"RSHIFT_CHANNEL_COUNTS");
  $display("RSHIFT_META_PASS oneactualIperoperation");
  $fclose(phase_obs_fd);""")
(shift / "tb.sv").write_text(tb)

with tarfile.open(ROOT / "docs/results/arm7-data-ack-20261101/proof.tar.gz") as archive:
    donor = archive.extractfile("cpu36/tb.sv").read().decode()
lane = donor[donor.index("module cpu_after "):donor.index("module cpu_bad ")]
lane = lane.replace("module cpu_after ", "module fetch_lane ")
lane = lane.replace("parameter int MODE=1", "parameter int MODE=1, parameter bit HEAD_RETURN=1")
lane = lane.replace(" arm7_ds\n", " arm7_ds_slot_trial\n")
lane = lane.replace("#(.MAIN_IF_FLOW(FLOW))", "#(.MAIN_IF_FLOW(FLOW),.MAIN_IF_COMMIT(1),.MAIN_IF_PHASE_META(1))")
lane = lane.replace(" nds_arm7_port #(.DATA_ACK_HANDOFF(1)",
                    " nds_arm7_port_slot_trial #(.MAIN_IF_PHASE_SERVICE(1),.MAIN_IF_HEAD_RETURN(HEAD_RETURN),.MAIN_IF_REJOIN(1),.MAIN_STORE_TURN(1),.DATA_ACK_HANDOFF(0)")
lane = lane.replace(" localparam bit QUAD=1,FLOW=1;", """
 import arm_pkg::*;
 a7_if_phase_t phase_meta;wire cv,ca;wire[31:0]cvaddr;
 wire head_valid;wire[20:0]head_word;wire[31:0]head_data;
 localparam bit QUAD=1,FLOW=1;""")
needle = ".i_req(ir),.i_addr(ia),.i_rdata(iq),.i_ok(io),"
assert lane.count(needle) == 2
cpu_link = needle + ".i_commit_valid(cv),.i_commit_addr(cvaddr),.i_commit_accept(ca),.if_phase(phase_meta),"
p7_link = needle + ".i_commit_valid(cv),.i_commit_addr(cvaddr),.i_commit_accept(ca),.i_phase(phase_meta),"
lane = lane.replace(needle, cpu_link, 1)
pos = lane.index(" nds_arm7_port_slot_trial ")
lane = lane[:pos] + lane[pos:].replace(needle, p7_link, 1)
lane = lane.replace(".f_rvalid(rv),.f_rdata(fq),.wr_mon",
                    ".f_rvalid(rv),.f_rdata(fq),.f_head_valid(head_valid),.f_head_word(head_word),.f_head_data(head_data),.wr_mon")
lane = lane.replace(" physical_after #(", " physical_before #(")
lane = lane.replace(".initialized,.idle,.pins,.reads(preads),.writes(pwrites));",
                    ".initialized,.idle,.pins,.reads(preads),.writes(pwrites),.head_valid,.head_word,.head_data);")
# The donor guard assumed a unique hit. Both banks may coherently contain
# the same quad; the real MLAB read port gives bank1 priority in that case.
# Check the actual selected read bank, on both the before and after lanes.
old_guard = "((port7.il_hit0&&!port7.flow_bank)||(port7.il_hit1&&port7.flow_bank)||(!(port7.il_hit0||port7.il_hit1)&&port7.flow_arrive&&port7.flow_bank==port7.rp_il))"
new_guard = "(((port7.il_hit0||port7.il_hit1)&&port7.u_il.raddr[2]==port7.flow_bank)||(!(port7.il_hit0||port7.il_hit1)&&port7.flow_arrive&&port7.flow_bank==port7.rp_il))"
assert lane.count(old_guard) == 1
lane = lane.replace(old_guard, new_guard)
lane = lane.replace("generate if(MODE!=0)begin:check_live_bank", "generate if(1)begin:check_live_bank")
lane = lane.replace("if(!rst&&MODE!=0&&run&&port7.flow_prefetch", "if(!rst&&run&&port7.flow_prefetch")
lane = lane.replace("if(MODE!=0&&run&&young_n", "if(run&&young_n")
lane = lane.replace("endmodule", """
 always @(posedge clk)if(!rst&&run&&port7.flow_prefetch&&port7.il_hit0&&port7.il_hit1)
  $display("COHERENT_DUPLICATE_BANK mode%0d read%0d replacement%0d",MODE,port7.u_il.raddr[2],port7.flow_bank);
endmodule""")
lane = lane.replace("endmodule", """
 always @(posedge clk)if(!rst&&run)begin
  assert(!phase_meta.owner_valid&&!phase_meta.start&&!phase_meta.advance&&!cv)
   else $fatal(1,"NONMUL_UNEXPECTED_PHASE_OWNER");
  if(iconsume)assert(iq==memory(ia))else $fatal(1,"FETCH39_WORD %h %h %h",ia,iq,memory(ia));
 end
endmodule""")
top = """`timescale 1ps/1ps
`default_nettype none
""" + lane + """
module tb;
 logic clk=0,clk_mem=0,clk_cram=0,rst=1;
 always #4973 clk_mem=~clk_mem;
 initial begin #14919;forever begin clk=1;#7460;clk=0;#7459;end end
 always @(clk_mem)clk_cram<=#6838 clk_mem;
 wire done0,done1;
 fetch_lane #(.MODE(0),.HEAD_RETURN(0)) before_lane(clk,clk_mem,clk_cram,rst,done0);
 fetch_lane #(.MODE(1),.HEAD_RETURN(1)) after_lane(clk,clk_mem,clk_cram,rst,done1);
 initial begin repeat(8)@(negedge clk);rst=0;wait(done0&&done1);$display("FETCH39_FUNCTION_PASS");$finish;end
endmodule
"""
(fetch / "tb.sv").write_text(top)
spec = importlib.util.spec_from_file_location("fetch39", ROOT / "sw/tests/a7fetch39/build.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
blobs, layout = module.captured()
rows = []
images = dest / "fetch-images"
images.mkdir()
for case in layout["cases"]:
    raw = blobs[f'arm7fetch_v1_k{case["id"]:02d}_r0.bin']
    code = raw[348:348 + case["size"]]
    assert hashlib.sha256(code).hexdigest() == case["code_sha256"]
    (images / (case["case"] + ".hex")).write_text("".join(
        f"{word:08x}\n" for word in struct.unpack("<1024I", code + bytes(4096-len(code)))))
    rows.append(dict(case, checksum=struct.unpack_from("<I", raw, 344)[0]))
(dest / "fetch-cases.json").write_text(json.dumps(rows, indent=2) + "\n")
ds = Path("/home/user/Git/NDS_Pocket-cpu-main-contract/docs/results/a7-main-observable-contract-20261102/inputs/ds39.json")
shutil.copy2(ds, dest / "ds39.json")
shutil.copy2(Path(__file__).with_name("controls_worker.py"), dest / "worker.py")
shutil.copy2(__file__, dest / "prepare.py")
(dest / "configuration.json").write_text(json.dumps(dict(main_only=False, fetch_only=args.fetch_only)) + "\n")
if args.reuse_fetch:
    shutil.copy2(args.reuse_fetch, dest / "previous-controls.json")
# Keep the exact common command construction and pinning from the previous worker.
common = Path(__file__).with_name("qualify_worker.py").read_text().split("\ntry:\n", 1)[0]
(dest / "runner_functions.py").write_text(common)
(dest / "inputs.json").write_text(json.dumps({
    str(p.relative_to(dest)): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in dest.rglob("*") if p.is_file()
}, indent=2) + "\n")
print(dest)
