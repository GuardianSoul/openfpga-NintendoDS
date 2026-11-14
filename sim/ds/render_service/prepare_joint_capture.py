#!/usr/bin/env python3
"""Build a copied-DUT trial of joint scanline and capture admission."""
from pathlib import Path
import hashlib
import json
import shutil
import sys

ROOT = Path('/home/user/Git/NDS_Pocket')
BASE = ROOT / 'build/coordinator/rc053-game-capacity-20261111/capture-cone'

def main():
    out = Path(sys.argv[1]).resolve()
    split_fences = '--split-fences' in sys.argv[2:]
    register_on_finish = '--register-on-finish' in sys.argv[2:]
    attribute_pair_wait = '--attribute-pair-wait' in sys.argv[2:]
    assert not register_on_finish or split_fences
    assert not attribute_pair_wait or (split_fences and not register_on_finish)
    out.mkdir(parents=True, exist_ok=False)
    original = {}
    for path in BASE.iterdir():
        if path.suffix in {'.sv', '.svh'}:
            shutil.copyfile(path, out / path.name)
            original[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    edits = []

    def edit(name, before, after):
        path = out / name
        source = path.read_text()
        assert source.count(before) == 1, (name, before, source.count(before))
        path.write_text(source.replace(before, after))
        edits.append(dict(file=name, before=before, after=after))

    edit('nds_vram.sv', '    input  logic        rst,', '''    input  logic        rst,
    input  logic        joint_capture,
    output logic        cw_is_capture, capture_dependency,''')
    edit('nds_vram.sv', '    wire cw_pair = CAP_CHAIN && cap_v && cap_w;', '''    wire cap_mode = joint_capture && CAP_CHAIN && VR_PH && VR_PASS && VR_PDRAIN && !VR_PF;
    wire [19:5] capture_line = {1'b0, cap_pa[16:3]};
    wire capture_pending = cap_p || cap_v;
    logic capture_posting, read_waits_capture;
    wire capture_older_read = (bw_left != 0 && bt0 == capture_line) ||
        (bw_left > 8 && bt1 == capture_line) ||
        (st == S_GBLK && va[19:5] == capture_line) ||
        (st == S_GRES && !read_waits_capture && res_q[20] && res_q[19:5] == capture_line);
    wire capture_older_cpu = st == S_RBLK || st == S_RFIL || st == S_CPU ||
                             st == S_CPUR || st == S_POST;
    wire capture_cpu_alias = cap_mode && capture_pending && res_q[20] && res_q[19:5] == capture_line;
    wire capture_enqueue = capture_posting && cw_ack;
    wire cw_pair = CAP_CHAIN && cap_v && (cap_mode ? capture_posting : cap_w);
    assign cw_is_capture = cw_pair;
    assign capture_dependency = cap_mode && ((st == S_GRES && read_waits_capture) ||
                                               (st == S_CRES && capture_cpu_alias));
    always_ff @(posedge clk) begin
        if (rst || !cap_mode || capture_enqueue) capture_posting <= 0;
        else if (cap_v && !capture_older_read && !capture_older_cpu) capture_posting <= 1;
        if (rst || !cap_mode) read_waits_capture <= 0;
        else if (g_ack) read_waits_capture <= capture_pending && !capture_enqueue &&
                                               res[20] && res[19:5] == capture_line;
        else if (capture_enqueue) read_waits_capture <= 0;
    end''')
    edit('nds_vram.sv', '    assign cw_he    = !VR_PH || cw_pair ? 2\'b11 : VR_WB && wb_p ? wb_he : {c_be[2], c_be[0]};', '''    wire lone_high = cap_a0 ^ $test$plusargs("fault_joint_capture_mask");
    assign cw_he = !VR_PH ? 2'b11 : cw_pair ?
        (cap_mode && !cap_w ? (lone_high ? 2'b10 : 2'b01) : 2'b11) :
        VR_WB && wb_p ? wb_he : {c_be[2], c_be[0]};''')
    edit('nds_vram.sv', 'cw_pair ? {cap_d, cap_pd} : VR_WB', 'cw_pair ? (cap_mode && !cap_w ? {2{cap_d}} : {cap_d, cap_pd}) : VR_WB')
    edit('nds_vram.sv', 'else if (cap_v && !cw_pair) begin', 'else if (cap_v && !cw_pair && !cap_mode) begin')
    edit('nds_vram.sv', 'if (VR_PASS && res_q[20] && pr_hit) ;', '''if (cap_mode && read_waits_capture && !$test$plusargs("fault_joint_capture_alias")) ;
                else if (VR_PASS && res_q[20] && pr_hit) ;''')
    edit('nds_vram.sv', 'else if (VR_POST && c_we && c_pbe) begin', '''else if (capture_cpu_alias) begin
                    if (VR_YIELD && g_req) st <= S_IDLE;
                end else if (VR_POST && c_we && c_pbe) begin''')
    edit('nds_vram.sv', '&& !VR_PF && res[20] && lv[0]', '''&& !VR_PF && res[20] && !(cap_mode && capture_pending && res[19:5] == capture_line) && lv[0]''')
    if split_fences:
        # A CPU word already acknowledged into WB owns its place before capture.
        # Capture and WB take are exclusive, including simultaneous first offers.
        edit('nds_vram.sv', '&& !c_ack && !wb_v;',
             '&& !c_ack && !wb_v && !(cap_mode && (capture_pending || (cap_we && cap_ready)));')
        edit('nds_vram.sv', 'assign cap_ready = !cap_v &&', 'assign cap_ready = (!cap_mode || !wb_v) && !cap_v &&')
        # The single global span can fence E/F when only D and H have writes.
        # Keep a retirement ticket and span for each producer instead.
        edit('nds_vram.sv', 'wire         pr_hit = post_p && res_q[19:5] >= pr_lo && res_q[19:5] <= pr_hi;', '''logic capture_post_pending;
    logic [19:5] capture_post_low, capture_post_high;
    logic [6:0] capture_post_ticket;
    wire [6:0] capture_post_remaining = capture_post_ticket - cw_pcnt;
    wire capture_post_retired = capture_post_remaining == 0 || capture_post_remaining[6:5] == 2'b11;
    wire capture_range_hit = cap_mode && capture_post_pending &&
        res_q[19:5] >= capture_post_low && res_q[19:5] <= capture_post_high;
    wire pr_hit = (post_p && res_q[19:5] >= pr_lo && res_q[19:5] <= pr_hi) || capture_range_hit;
    always_ff @(posedge clk) begin
        if (rst || !cap_mode) capture_post_pending <= 0;
        else if (capture_enqueue) begin
            capture_post_pending <= 1;
            capture_post_ticket <= cw_pcnt + cw_fill + 7'd1;
            if (!capture_post_pending || capture_post_retired || capture_line < capture_post_low)
                capture_post_low <= capture_line;
            if (!capture_post_pending || capture_post_retired || capture_line > capture_post_high)
                capture_post_high <= capture_line;
        end else if (capture_post_retired) capture_post_pending <= 0;
    end''')
        edit('nds_vram.sv', 'wire         pd_w = VR_PDRAIN ? cw_valid && cw_ack : cw_post && cw_ack;',
             'wire pd_w = (VR_PDRAIN ? cw_valid && cw_ack : cw_post && cw_ack) && !(cap_mode && cw_pair);')
        edit('nds_vram.sv', '&& !post_p &&\n                !cap_v', '&& !post_p && !(cap_mode && capture_post_pending) &&\n                !cap_v')
        edit('nds_vram.sv', 'else if (post_p) begin if (VR_YIELD && g_req) st <= S_IDLE; end',
             'else if (cap_mode ? pr_hit : post_p) begin if (VR_YIELD && g_req) st <= S_IDLE; end')
    if register_on_finish:
        # A low half already owns cap_pa. Completing its pair or timeout
        # need not add another registered ownership edge on that same line.
        edit('nds_vram.sv', '    wire capture_enqueue = capture_posting && cw_ack;', '''    wire capture_slot_finishing = cap_p && !cap_v &&
        ((cap_we && cap_ready) || cap_t == 3'd4);
    wire capture_enqueue = capture_posting && cw_ack;''')
        edit('nds_vram.sv', '        else if (cap_v && !capture_older_read && !capture_older_cpu) capture_posting <= 1;',
             '''        else if (!capture_older_cpu &&
                 ((cap_v && !capture_older_read) ||
                  (capture_slot_finishing && (!capture_older_read ||
                   $test$plusargs("fault_joint_capture_finish_owner")))))
            capture_posting <= 1;''')
    edit('nds_ring_post_arb.sv', '    input logic clk, reset,', '''    input logic clk, reset,
    input logic joint_capture, read_work, read_done, capture_data, capture_dependency,''')
    edit('nds_ring_post_arb.sv', '    wire [2:0] requests = {capture_req,ring_req,video_req};', '''    // Credit represents accepted optional write words, replenished by one
    // completed 32-byte 2D read. A started ring group keeps its reservation.
    logic [3:0] write_credit;
    wire protect_reads = joint_capture && read_work;
    wire [3:0] available_credit = !protect_reads || read_done ? 4'd8 : write_credit;
    wire ring_eligible = !protect_reads || available_credit == 8 || (active && owner == 1);
    wire capture_eligible = !protect_reads || !capture_data || capture_dependency || available_credit != 0;
    wire [2:0] requests = {capture_req && capture_eligible, ring_req && ring_eligible, video_req};
    wire debit = ring_ack || (capture_ack && capture_data);
    always_ff @(posedge clk) begin
        if (reset || !protect_reads) write_credit <= 4'd8;
        else if (debit && available_credit != 0) write_credit <= available_credit - 1'b1;
        else write_credit <= available_credit;
    end''')
    edit('tb.sv', ' wire[71:0]vramcnt=', ''' wire joint_capture = $test$plusargs("joint_capture");
 wire cw_is_capture,capture_dependency;
 wire[71:0]vramcnt=''')
    edit('tb.sv', "  .clk,.rst,.vramcnt,.c_req,.c_cpu(1'b0)", "  .clk,.rst,.joint_capture,.cw_is_capture,.capture_dependency,.vramcnt,.c_req,.c_cpu(1'b0)")
    edit('tb.sv', 'nds_ring_post_arb poster(.clk,.reset(rst),', '''wire current_2d_work = load && d_return_blocks < 64*(1+(syscycles-traffic_at)/4260);
 nds_ring_post_arb poster(.clk,.reset(rst),.joint_capture,.read_work(current_2d_work),
  .read_done(d_rvalid && gbeat==3),.capture_data(cw_is_capture),.capture_dependency,''')
    # Independently compare capture inputs to the actual posted mask/address/data.
    edit('observe.svh', 'integer obs_sys=0,', '''integer joint_capture_reads=0,joint_capture_writes=0;
logic[17:0]capture_expected_addr[8];
logic[15:0]capture_expected_half[8];
integer obs_sys=0,''')
    edit('observe.svh', ' obs_sys++;', ''' obs_sys++;
 if(rst)begin joint_capture_reads=0;joint_capture_writes=0;end
 else if(joint_capture)begin
  if(cw_ack&&cw_is_capture)begin
   integer remaining,index;
   logic [1:0] expected_mask;
   remaining=joint_capture_writes-joint_capture_reads;
   index=joint_capture_reads%8;
   if(remaining<1||remaining>2)$fatal(1,"JOINT_CAPTURE_QUEUE");
   expected_mask=remaining==2?2'b11:(capture_expected_addr[index][0]?2'b10:2'b01);
   if(cw_addr!==24'(capture_expected_addr[index][17:1])||cw_he!==expected_mask)
    $fatal(1,"JOINT_CAPTURE_MASK_OR_ADDRESS");
   if(remaining==2&&capture_expected_addr[(index+1)%8]!==capture_expected_addr[index]+18'd1)
    $fatal(1,"JOINT_CAPTURE_PAIR");
   if((expected_mask[0]&&cw_data[15:0]!==capture_expected_half[index])||
      (expected_mask[1]&&cw_data[31:16]!==capture_expected_half[(index+remaining-1)%8]))
    $fatal(1,"JOINT_CAPTURE_PAYLOAD");
   joint_capture_reads+=remaining;
  end
  if(cap_we&&cap_ready)begin
   capture_expected_addr[joint_capture_writes%8]=cap_addr;
   capture_expected_half[joint_capture_writes%8]=cap_data;
   joint_capture_writes++;
  end
 end''')
    if attribute_pair_wait:
        edit('tb.sv', '  integer cap_wait_join, cap_wait_other, cap_ready_count;', '''  integer cap_wait_join, cap_wait_other, cap_ready_count;
  integer pair_wait[9];''')
        edit('tb.sv', '      cap_wait_pair = 0;', '''      $write("PAIR_BUDGET,%0d",syscycles);
      foreach (pair_wait[i]) begin
        $write(",%0d",pair_wait[i]);
        pair_wait[i] = 0;
      end
      $write("\\n");
      cap_wait_pair = 0;''')
        edit('tb.sv', '      if (vram.cap_v && vram.cap_w) cap_wait_pair++;', '''      if (vram.cap_v && vram.cap_w) begin
        cap_wait_pair++;
        if (!vram.capture_posting) begin
          if (vram.capture_older_read) pair_wait[0]++;
          else if (vram.capture_older_cpu) pair_wait[1]++;
          else pair_wait[2]++;
        end else if (!poster.capture_eligible) pair_wait[3]++;
        else if (full) pair_wait[4]++;
        else if (rg_wack) pair_wait[5]++;
        else if (video_ack) pair_wait[6]++;
        else if (cw_ack) pair_wait[7]++;
        else pair_wait[8]++;
      end''')
    files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}
    manifest = dict(source='e63b5612+retained-controller', original=original,
                    files=files, edits=edits, profile='joint capture runtime off by default')
    if register_on_finish:
        manifest['register_on_finish'] = True
    (out / 'source.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(out, len(edits), 'copied-source edits')

if __name__ == '__main__':
    main()
