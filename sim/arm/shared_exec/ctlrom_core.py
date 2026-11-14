#!/usr/bin/env python3
"""Generate one defaultoff original SYS core with route-template D/E controller."""
import pathlib,subprocess
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';S=D/'source';O=W/'rtl/arm/study'
s=subprocess.check_output(['git','show','232c26ac:rtl/arm/arm9_core.sv'],cwd=W,text=True);s=s.replace('module arm9_core import','module arm9_core_ctlrom import',1).replace('  parameter             RF_STYLE',"  parameter bit CTLROM=1'b0,parameter bit FAULT_TEMPLATE=1'b0,\n  parameter             RF_STYLE",1)
a=s.index('  always_comb begin\n    logic [4:0] bank_ra');b=s.index('  // The instruction has more uops',a);original=s[a:b]
replacement='''generate if(!CTLROM)begin:g_original_decode
'''+original+'''end else begin:g_ctlrom
 logic[300:0]dp,ep;logic[22:0]seq;
 arm9_ctlrom_packet #(.FAULT_TEMPLATE(FAULT_TEMPLATE)) controller(
 .clk,.rst,.hold_e(stall),.d_go,.flush(m_rdr||w_rdr),
 .c_ins,.h_pc,.c_bl2t,.f_hw,.rl_rem,.c_cls,.mode_in(cpsr[4:0]),.rl_r,.c_kind,.ustep,
 .h_th,.h_ab,.h_v,.qpa(q_pa[0]),.c_bl2,.take_fiq,.take_irq,.hivec(hivecs[0]),
 .d_packet(dp),.e_packet(ep),.seq);
 assign u=uop9_t'(dp);assign u0=u;assign eu=uop9_t'(ep);
 assign more=seq[22];assign nstep=seq[21:20];assign nrl=seq[19:4];
end endgenerate
''';s=s[:a]+replacement+s[b:]
for line in ["      eu <= '0;\n","        eu <= u;\n","        if (!d_go) eu.valid <= 1'b0;\n","      if (m_rdr || w_rdr) eu.valid <= 1'b0;\n"]:
 assert s.count(line)==1,(line,s.count(line));s=s.replace(line,'')
s=s.replace('  // ---------------------------------------------------------------- sequential','''generate if(!CTLROM)begin:g_original_e_register
 always_ff @(posedge clk)begin
  if(rst)eu<='0;
  else begin
   if(!stall)begin eu<=u;if(!d_go)eu.valid<=1'b0;end
   if(m_rdr||w_rdr)eu.valid<=1'b0;
  end
 end
end endgenerate
  // ---------------------------------------------------------------- sequential''',1)
(O/'arm9_core_ctlrom.sv').write_text('// Defaultoff STUDY: original232 SYS pipeline, replacing D packet/E store only.\n'+s)
s=subprocess.check_output(['git','show','232c26ac:rtl/arm/arm_cpu.sv'],cwd=W,text=True).replace('module arm_cpu import','module arm_cpu_ctlrom import',1).replace('  parameter logic [31:0] RESET_CTRL9',"  parameter bit CTLROM=1'b0,parameter bit FAULT_TEMPLATE=1'b0,\n  parameter logic [31:0] RESET_CTRL9",1).replace('arm9_core #(.RF_STYLE(A9_RF),','arm9_core_ctlrom #(.CTLROM(CTLROM),.FAULT_TEMPLATE(FAULT_TEMPLATE),.RF_STYLE(A9_RF),',1)
(O/'arm_cpu_ctlrom.sv').write_text('// Defaultoff STUDY: complete native topology; ARM7 and memory untouched.\n'+s)
for n in ['ctlrom_address','ctlrom_reconstruct','arm9_ctlrom_planes','arm9_ctlrom_packet']:(O/(n+'.sv')).write_bytes((S/(n+'.sv')).read_bytes())
print('defaultoff wholeD/E controller study sources emitted')
