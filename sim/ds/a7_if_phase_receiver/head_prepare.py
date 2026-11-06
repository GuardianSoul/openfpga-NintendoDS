"""Passive actual IF head then bounded early publication, same physical control."""
from pathlib import Path
import argparse,hashlib,json,shutil,subprocess
R=Path(__file__).resolve().parents[3];B=R/'build/a7-if-phase-receiver-v2'
p=argparse.ArgumentParser();p.add_argument('--allocated',action='store_true',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();G=a.out.resolve();G.mkdir(parents=True,exist_ok=False);sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for name in['source','inputs','reference','helpers']:shutil.copytree(B/name,G/name)
shutil.copy2(B/'run-inputs.json',G/'run-inputs.json');shutil.copy2(B/'timings.json',G/'phase-only-timings.json')
for ext in['state','data','edge','full','pins','slot']:shutil.copy2(B/('on/u1-n4.'+ext),G/('previous-u1-n4.'+ext))
phy=(R/'rtl/pocket/nds_psram.sv').read_text();old=subprocess.check_output(['git','show','0a5a1cee:rtl/pocket/nds_psram.sv'],cwd=R,text=True)
erased=phy.replace('    parameter bit IF_HEAD_RETURN = 0, // non-destructive already-written SYS-domain typed IF head\n','')
for line in['    output wire s_if_head_valid,\n','    output wire [20:0] s_if_head_word,\n','    output wire [31:0] s_if_head_data,\n']:assert line in erased;erased=erased.replace(line,'')
lo=erased.index('    // Keep the existing two Gray synchronizers');hi=erased.index('    wire gw_on',lo);erased=erased[:lo]+erased[hi:];assert erased==old,'physical control/drain changed'
(G/'source/nds_psram.sv').write_text(phy)
p7=(R/'rtl/ds/nds_arm7_port.sv').read_text();p7=p7.replace('module nds_arm7_port #(','module nds_arm7_port_slot_trial #(',1);marker='    // simulation (+a7dbg):';p7=p7.replace(marker,(R/'sim/arm/a7_logical_slot/p7_ledger.svh').read_text()+'\n'+marker,1);(G/'source/p7.sv').write_text(p7)
tb=(B/'source/tb.sv').read_text().replace('PHASE_SERVICE=1);','PHASE_SERVICE=1, HEAD_RETURN=0);')
tb=tb.replace(' a7_if_phase_t phase_meta;',' a7_if_phase_t phase_meta;\n wire head_valid;wire[20:0]head_word;wire[31:0]head_data;')
tb=tb.replace('.MAIN_IF_PHASE_SERVICE(PHASE_SERVICE),','.MAIN_IF_HEAD_RETURN(HEAD_RETURN),.MAIN_IF_PHASE_SERVICE(PHASE_SERVICE),')
tb=tb.replace('.f_rdata(fq),.wr_mon', '.f_rdata(fq),.f_head_valid(head_valid),.f_head_word(head_word),.f_head_data(head_data),.wr_mon')
tb=tb.replace('.initialized,.idle,.pins,.reads(preads),.writes(pwrites)', '.initialized,.idle,.pins,.reads(preads),.writes(pwrites),.head_valid,.head_word,.head_data')
at=tb.rindex('endmodule');tb=tb[:at]+'''
integer head_fd;
initial begin wait(out!="");head_fd=$fopen({out,".head"},"w");end
always @(posedge clk)if(head_fd&&!rst&&(head_valid||fr||ir||iconsume))begin
 $fdisplay(head_fd,"%0d %h %b %b %h %0d %b %h %h %b %h %b %b %h %b %b %0d %b %b %b %0d %0d",
 cycle,ia,cpu.ph,ir,{p7.flow_a,2'b00},p7.flow_left,head_valid,head_word,head_data,rv,fq,ack,iconsume,fa,
 transport.u_phy.strm,transport.u_phy.b_if4,transport.u_phy.out_k,transport.u_phy.s_rvalid,transport.u_fab.rv7,
 p7.flow_head_arrive,transport.u_phy.tot,transport.u_phy.wc_b);
end
''' +tb[at:];(G/'source/tb.sv').write_text(tb)
tr=(B/'source/transport.sv').read_text();needle='output logic initialized,idle,output wire[79:0]pins,output integer reads=0,writes=0);';assert tr.count(needle)==1
tr=tr.replace(needle,'output logic initialized,idle,output wire[79:0]pins,output integer reads=0,writes=0,output wire head_valid,output wire[20:0]head_word,output wire[31:0]head_data);')
tr=tr.replace('nds_psram #(.T_INIT(100),','nds_psram #(.IF_HEAD_RETURN(1),.T_INIT(100),')
needle='.s_rvalid(mr_rvalid),.s_rdata(mr_rdata),';assert tr.count(needle)==1;tr=tr.replace(needle,needle+'.s_if_head_valid(phy_head_valid),.s_if_head_word(head_word),.s_if_head_data(head_data),')
idx=tr.index(' wire cke;');tr=tr[:idx]+''' wire phy_head_valid;
 // Bind the actual captured IF owner; no other client's prefill is borrowed.
 assign head_valid=phy_head_valid&&u_arb.own==u_arb.O_A&&u_arb.rd&&u_fab.q7
   &&u_fab.mst==2&&u_fab.st==u_fab.S_FILL&&!u_fab.we&&!u_fab.sd_on&&!u_fab.ra_on;
''' +tr[idx:];(G/'source/transport.sv').write_text(tr)
needle="assign s_if_head_data = IF_HEAD_RETURN ? {g1_q, g0_q} : 32'd0;";assert phy.count(needle)==1;(G/'phy-head-fault.sv').write_text(phy.replace(needle,"assign s_if_head_data = IF_HEAD_RETURN ? ({g1_q, g0_q} ^ 32'd1) : 32'd0;"))
shutil.copy2(Path(__file__).with_name('head_worker.py'),G/'worker.py');shutil.copy2(__file__,G/'prepare.py')
(G/'source-audit.json').write_text(json.dumps(dict(previous='0a5a1cee actualPSRAM',physical_complete_erasure=True,receiver_scope='Actual returned typedIF SYS-domain head only; physical packetcontrol/drain/synchronizers/storage unchanged. P7old captured owner/epoch/coherence andlogicaldeadline stillgatepublication.',Root_public_forwarding='Availablehead remains endpoint contract; Root public currenta7e1 producerphaseforward isseparate.'),indent=2)+'\n')
(G/'inputs.json').write_text(json.dumps({str(p.relative_to(G)):sha(p)for p in G.rglob('*')if p.is_file()and p.name!='inputs.json'},indent=2)+'\n')
print('IF_HEAD_PREPARED',G)
