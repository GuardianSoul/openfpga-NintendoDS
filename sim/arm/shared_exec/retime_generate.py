#!/usr/bin/env python3
"""Build study donors from immutable original cores; defaultoff shared resources."""
import pathlib,subprocess,re
W=pathlib.Path(__file__).resolve().parents[3];O=W/'rtl/arm/study';BASE='232c26ac'
def donor(n):return subprocess.check_output(['git','show',BASE+':rtl/arm/'+n+'.sv'],cwd=W,text=True)
ports='''
  output logic [31:0] ex_rot_v,
  output logic [4:0] ex_rot_n,
  output logic [31:0] ex_add_x,ex_add_y,
  output logic ex_add_ci,
  output logic [31:0] ex_logic_a,ex_logic_b,
  output logic [3:0] ex_logic_op,
  input logic [31:0] ex_rot_r,ex_logic_r,
  input logic [32:0] ex_add_r,
'''
s=donor('arm9_core').replace('module arm9_core import','module arm9_core_retimed import',1).replace('parameter             RF_STYLE',"parameter bit SHARED_EXEC=1'b0,\n  parameter             RF_STYLE",1).replace('  input  logic        clk,',ports+'  input  logic        clk,',1)
a=s.index('    x_rot = e_b;');b=s.index('    for (int i = 0; i < 32; i++)',a);orig=s[a:b];s=s[:a]+'''    ex_rot_v=e_b;ex_rot_n=sh_rot;
    if(SHARED_EXEC)x_rot=ex_rot_r;
    else begin
'''+orig+'    end\n'+s[b:]
s=s.replace("    s34 = {1'b0, x, 1'b1} + {1'b0, y, ci};\n    sum33 = s34[33:1];",'''    ex_add_x=x;ex_add_y=y;ex_add_ci=ci;
    s34 = '0;
    if(SHARED_EXEC)sum33=ex_add_r;
    else begin
     s34 = {1'b0, x, 1'b1} + {1'b0, y, ci};
     sum33 = s34[33:1];
    end''')
a=s.index('    case (eu.alu)\n      AL_AND, AL_TST: lres');b=s.index('    // the adder',a);orig=s[a:b];s=s[:a]+'''    ex_logic_a=opa;ex_logic_b=sh_out;ex_logic_op=eu.alu[3:0];
    if(SHARED_EXEC)lres=ex_logic_r;
    else begin
'''+orig+'    end\n'+s[b:];# Separate normalized request preparation from response consumers (no false process SCC).
s=s.replace('    ex_rot_v=e_b;ex_rot_n=sh_rot;\n','')
s=s.replace('  logic [31:0] x_rot, sh_out, e_ad;', '  assign ex_rot_v=e_b;assign ex_rot_n=sh_rot;\n  logic [31:0] x_rot, sh_out, e_ad;')
a=s.index('  always_comb begin\n    logic [31:0] x, y;');b=s.index('  // Address mode',a)
q=s[a:b].replace('  always_comb begin\n    logic [31:0] x, y;\n    logic        ci;\n    logic [5:0]  lz;\n    logic [33:0] s34;', '  logic [31:0] share_x,share_y;logic share_ci;logic[5:0]lz;logic[33:0]s34;\n  always_comb begin')
for old,new in [('x','share_x'),('y','share_y'),('ci','share_ci')]:q=re.sub(r'\b'+old+r'\b',new,q)
q=q.replace('    ex_add_x=share_x;ex_add_y=share_y;ex_add_ci=share_ci;', '  end\n  assign ex_add_x=share_x;assign ex_add_y=share_y;assign ex_add_ci=share_ci;\n  assign ex_logic_a=opa;assign ex_logic_b=sh_out;assign ex_logic_op=eu.alu[3:0];\n  always_comb begin')
q=q.replace('    ex_logic_a=opa;ex_logic_b=sh_out;ex_logic_op=eu.alu[3:0];\n','')
s=s[:a]+q+s[b:]
(O/'arm9_core_retimed.sv').write_text('// STUDY: exact232 donor plus defaultoff external integer resources.\n'+s)
s=donor('arm7_ds').replace('module arm7_ds import arm_pkg::*; (',"module arm7_ds_retimed import arm_pkg::*; #(parameter bit SHARED_EXEC=1'b0)(",1).replace('  input  logic        clk,',ports+'  input  logic        clk,',1)
a=s.index('    rv   = shv;');b=s.index('    fill = ',a);orig=s[a:b];s=s[:a]+'''    ex_rot_v=shv;ex_rot_n=rot;
    if(SHARED_EXEC)rv=ex_rot_r;
    else begin
'''+orig+'    end\n'+s[b:]
needle="    s33 = {1'b0, a ^ {32{inva}}} + {1'b0, b ^ {32{invb}}} + {32'h0, cin};";assert s.count(needle)==1;s=s.replace(needle,'''    ex_add_x=a ^ {32{inva}};ex_add_y=b ^ {32{invb}};ex_add_ci=cin;
    if(SHARED_EXEC)s33=ex_add_r;
    else s33={1'b0,ex_add_x}+{1'b0,ex_add_y}+{32'h0,cin};''')
a=s.index('    if (k == K_DP) case (ins[24:21])');b=s.index('\n  end',a);orig=s[a:b];s=s[:a]+'''    ex_logic_a=a;ex_logic_b=sho;ex_logic_op=ins[24:21];
    if(SHARED_EXEC && k==K_DP && (ins[24:21]==4'h0 || ins[24:21]==4'h8 || ins[24:21]==4'h1 || ins[24:21]==4'h9 || ins[24:21]>=4'hc))alu=ex_logic_r;
    else begin
'''+orig+'\n    end'+s[b:];s=s.replace('    ex_rot_v=shv;ex_rot_n=rot;\n','')
s=s.replace('  logic [31:0] sho_u;', "  assign ex_rot_v=shv;\n  assign ex_rot_n=(sht==2'b11 && !shr && shn==0)?5'd1:(sht==0)?5'd0-shn[4:0]:shn[4:0];\n  logic [31:0] sho_u;")
s=s.replace('    ex_add_x=a ^ {32{inva}};ex_add_y=b ^ {32{invb}};ex_add_ci=cin;', '  end\n  assign ex_add_x=a ^ {32{inva}};assign ex_add_y=b ^ {32{invb}};assign ex_add_ci=cin;\n  assign ex_logic_a=a;assign ex_logic_b=sho;assign ex_logic_op=ins[24:21];\n  always_comb begin')
s=s.replace('    ex_logic_a=a;ex_logic_b=sho;ex_logic_op=ins[24:21];\n','')
(O/'arm7_ds_retimed.sv').write_text('// STUDY: exact232 donor plus defaultoff external integer resources.\n'+s)
s=donor('arm_cpu').replace('module arm_cpu import','module arm_cpu_retimed import',1).replace('  parameter logic [31:0] RESET_CTRL9',"  parameter bit SHARED_EXEC=1'b0,\n  parameter bit FAULT_OWNER=1'b0,\n  parameter logic [31:0] RESET_CTRL9",1).replace('  input  logic        clk,','  input logic clk2,\n  input  logic        clk,',1)
extra=[]
for c in [9,7]:
 extra.append(f'''logic[31:0] r{c}v,a{c}x,a{c}y,l{c}a,l{c}b,r{c}r,l{c}r;
logic[4:0]r{c}n;logic a{c}ci;logic[3:0]l{c}op;logic[32:0]a{c}r;''')
def binds(c):return f'''.ex_rot_v(r{c}v),.ex_rot_n(r{c}n),.ex_add_x(a{c}x),.ex_add_y(a{c}y),.ex_add_ci(a{c}ci),.ex_logic_a(l{c}a),.ex_logic_b(l{c}b),.ex_logic_op(l{c}op),.ex_rot_r(r{c}r),.ex_logic_r(l{c}r),.ex_add_r(a{c}r),'''
s=s.replace('  generate if (A9_CORE)', '\n'.join(extra)+'''\ngenerate if(SHARED_EXEC)begin:g_shared_exec
 arm_exec_halfslots #(.FAULT_OWNER(FAULT_OWNER)) u_exec(.clk_sys(clk),.clk2,.rst,
 .r9v,.r9n,.a9x,.a9y,.a9ci,.l9a,.l9b,.l9op,.r9r,.l9r,.a9r,
 .r7v,.r7n,.a7x,.a7y,.a7ci,.l7a,.l7b,.l7op,.r7r,.l7r,.a7r);
`ifndef SYNTHESIS
 initial if(!A9_CORE||!A7_DS)$fatal(1,"shared execution requires original ARM9+ARM7 controllers");
`endif
end else begin:g_local_exec
 assign r9r=0;assign l9r=0;assign a9r=0;assign r7r=0;assign l7r=0;assign a7r=0;
end endgenerate
  generate if (A9_CORE)''',1)
s=s.replace('arm9_core #(.RF_STYLE(A9_RF),','arm9_core_retimed #(.SHARED_EXEC(SHARED_EXEC),.RF_STYLE(A9_RF),',1).replace(' .FETCH_HALF(1\'b1)) u_core9 (',' .FETCH_HALF(1\'b1)) u_core9 ('+binds(9),1)
s=s.replace('    arm7_ds u_a7 (','    arm7_ds_retimed #(.SHARED_EXEC(SHARED_EXEC)) u_a7 ('+binds(7),1)
assert 'u_core9 (.ex_rot_v' in s
(O/'arm_cpu_retimed.sv').write_text('// STUDY: original full CPU/service topology, defaultoff shared integer cone.\n'+s)
