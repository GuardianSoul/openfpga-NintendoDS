#!/usr/bin/env python3
"""Build the standalone whole-memory-controller microcode experiment.

The pinned controller is the datapath donor. No production file is edited.
Run oracle.py and establish identity PASS + actual mutant catch first.
"""
import pathlib,re,subprocess,json
W=pathlib.Path(__file__).resolve().parents[3];O=W/'build/cpu232-service-ucode'
assert 'PASS cycles=' in (O/'identity-run.log').read_text()
assert 'ORACLE bus cycle=' in (O/'mutant-run.log').read_text()
s=subprocess.check_output(['git','show','232c26ac:rtl/arm/arm9_mem.sv'],cwd=W).decode()
s=s.replace('module arm9_mem import arm_pkg::*;','module arm9_mem_ucode import arm_pkg::*;',1).replace('packed_update','ucode_packed_update')
# The service PC is still4bits. Its single microstore replaces the three
# independently written state dispatch trees. Banked RAM datapaths remain.
names=['IDLE','WDRAIN','READ','TAG','EVRD','EVWR','FILL','COMMIT','ITAG','INV','EVRD2','EVDRN','PFCHK']
rows=[(0,0,0,0),(1,0,0,1),(2,0,0,3),(2,1,0,3),(3,0,1,0),(4,0,1,0),(5,0,1,4),(6,0,1,5),(7,0,1,0),(8,1,2,0),(6,1,2,5),(7,1,2,0),(9,0,3,0),(10,0,1,0),(11,0,0,2),(12,1,0,0)]
micro='''
  // Whole slow-service control store: {flow4,bank1,RAM-owner2,bus-class3}.
  // Asynchronous MLAB request: no added pipeline edge or global RAM port.
  // Legal mapping/area/timing are unmeasured, including address/decode muxes.
  typedef struct packed {logic[3:0] flow;logic bank;logic[1:0] owner;logic[2:0] bus;} service_word_t;
  (* ramstyle = "MLAB, no_rw_check" *) logic [9:0] service_rom [0:15];
  service_word_t u;
'''
for i,n in enumerate(names):micro+=f'  localparam logic[3:0] F_{n} = 4\'d{i};\n'
micro+='  initial begin\n'
for i,(f,b,o,a) in enumerate(rows):micro+=f"    service_rom[{i}] = 10'h{(f<<6)|(b<<5)|(o<<3)|a:03x};\n"
micro+='  end\n  assign u = service_rom[st];\n'
needle='  st_t         st;'
assert s.count(needle)==1;s=s.replace(needle,needle+micro)
# Common read/fill micro-operations share data path selection and sequencing.
a=s.index('        S_RD1: if (b_ack) begin',s.index('// ---- the machine'))
b=s.index('        S_TAG: begin',a)
s=s[:a]+'''        F_READ: if (b_ack) begin
          if (u.bank) begin
            ibuf_v <= 1'b1; ibuf_a <= ip_a; ibuf_d <= b_rdata; ip_v <= 1'b0;
          end else begin
            rbuf_v <= 1'b1; rbuf_a <= dp_a; rbuf_d <= b_rdata; dp_v <= 1'b0;
          end
          st <= S_IDLE;
        end
'''+s[b:]
for name in ['S_FILL','S_IFILL']:
 a=s.index('        '+name+': if (b_ack) begin',s.index('// ---- the machine'))
 b=s.index('        end',a)+len('        end\n')
 if name=='S_FILL':
  s=s[:a]+'''        F_FILL: if (b_ack) begin
          k <= k + 3'd1;
          if (k == 3'd7) begin
            if (u.bank) st <= S_ITAGW; else st <= S_TAGW;
          end
        end
'''+s[b:]
 else:s=s[:a]+s[b:]
# Keep different commit side-effects but dispatch them under one micro-op.
a=s.index('        S_TAGW: begin',s.index('// ---- the machine'));b=s.index('        S_ITAG: begin',a);dcommit=s[a:b].replace('        S_TAGW: begin','          if (!u.bank) begin',1)
a2=s.index('        S_ITAGW: begin',b);b2=s.index('        S_PFCHK: begin',a2);icommit=s[a2:b2].replace('        S_ITAGW: begin','          else begin',1)
s=s[:a]+'        F_COMMIT: begin\n'+dcommit+icommit+'        end\n'+s[b:a2]+s[b2:]
# Main sequencer now dispatches micro-operations, not service PC states.
a=s.index('// ---- the machine');tail=s[a:];tail=tail.replace('case (st)','case (u.flow)',1)
label={'S_IDLE':'F_IDLE','S_WDRAIN':'F_WDRAIN','S_TAG':'F_TAG','S_EVRD':'F_EVRD','S_EVWR':'F_EVWR','S_ITAG':'F_ITAG','S_INV':'F_INV','S_EVRD2':'F_EVRD2','S_EVDRN':'F_EVDRN','S_PFCHK':'F_PFCHK'}
for old,new in label.items():tail=tail.replace(old+':',new+':')
s=s[:a]+tail
# RAMs dispatch only on owner: same data ports, writes, poison and collisions.
a=s.index('    case (st)',s.index('// ---------------------------------------------------------------- WB:'))
b=s.index('  // bus\n',a);part=s[a:b]
part=part.replace('case (st)','case (u.owner)',1)
part=part.replace('S_TAG, S_EVRD, S_EVRD2, S_EVWR, S_FILL, S_TAGW:',"2'd1:")
part=part.replace('S_ITAG, S_IFILL, S_ITAGW:',"2'd2:")
part=part.replace('S_INV:',"2'd3:")
part=part.replace('''      S_PFCHK: begin
        it_aa = ia[ISB+4:5];
      end
''','')
part=part.replace('      default: ;',"      default: if (u.flow == F_PFCHK) it_aa = ia[ISB+4:5];")
s=s[:a]+part+s[b:]
# One shared address constructor for instruction/data single reads and fills.
a=s.index('  // bus\n');b=s.index('  always_ff @(posedge clk) begin\n    // request registers',a)
s=s[:a]+'''  // One bus descriptor and address constructor for every service class.
  logic [31:0] service_base;
  logic [2:0] service_word;
  always_comb begin
    service_base = u.bank ? ia : dp_a;
    // Uncached instruction reads use ip_a, not the maintenance/prefetch ia.
    if (u.bus == 3'd3 && u.bank) service_base = ip_a;
    service_word = k + (u.bank ? fsi : fsd);
    b_req = u.bus != 3'd0;
    b_we = u.bus == 3'd1 || u.bus == 3'd2 || u.bus == 3'd4;
    b_tmr = u.bus == 3'd1 ? wbuf_tmr : 4'd0;
    b_be = u.bus == 3'd1 ? wbuf_be : 4'hf;
    b_wdata = u.bus == 3'd2 ? ev_d[k] : u.bus == 3'd4 ? dc_aq[vway] : wbuf_d;
    b_n8 = (BURST && u.bus == 3'd5) || (EVBW && u.bus == 3'd2);
    b_addr = 32'd0;
    case (u.bus)
      3'd1: b_addr = wbuf_a;
      3'd2: b_addr = EVBW ? {ev_a,5'd0} : {ev_a,k,2'd0};
      3'd3: b_addr = {service_base[31:2],2'd0};
      3'd4: b_addr = {ev_lane[DTW-1:0],dset,k,2'd0};
      3'd5: b_addr = {service_base[31:5],service_word,2'd0};
      default: ;
    endcase
  end

'''+s[b:]
# All observable deadlines and auxiliary bookkeeping use decoded micro-ops.
pred={
'S_IDLE':'u.flow == F_IDLE','S_WDRAIN':'u.flow == F_WDRAIN',
'S_RD1':'u.flow == F_READ && !u.bank','S_IRD1':'u.flow == F_READ && u.bank',
'S_TAG':'u.flow == F_TAG','S_ITAG':'u.flow == F_ITAG',
'S_EVRD':'u.flow == F_EVRD','S_EVWR':'u.flow == F_EVWR',
'S_FILL':'u.flow == F_FILL && !u.bank','S_IFILL':'u.flow == F_FILL && u.bank',
'S_TAGW':'u.flow == F_COMMIT && !u.bank','S_ITAGW':'u.flow == F_COMMIT && u.bank',
'S_INV':'u.flow == F_INV','S_EVRD2':'u.flow == F_EVRD2','S_EVDRN':'u.flow == F_EVDRN','S_PFCHK':'u.flow == F_PFCHK'}
s=re.sub(r'\bst\s*(==|!=)\s*(S_\w+)',lambda m:'('+('!(' if m[1]=='!=' else '')+pred[m[2]]+(')' if m[1]=='!=' else '')+')',s)
assert 'case (st)' not in s
# Quartus requires the struct declaration before generated tag logic reads u.
a=s.index('  typedef enum logic [3:0]')
b=s.index('  assign u = service_rom[st];',a)+len('  assign u = service_rom[st];\n')
decl=s[a:b];s=s[:a]+s[b:]
pos=s.index('  // ---------------------------------------------------------------- CP15')
s=s[:pos]+decl+'\n'+s[pos:]
# Do not rewrite PC assignments: the table encodes service identity, not FIFO state.
p=W/'rtl/arm/study/arm9_mem_ucode.sv';p.parent.mkdir(parents=True,exist_ok=True);p.write_text('\n'.join(x.rstrip() for x in ('// EXPERIMENT: complete controller; not instantiated by production.\n'+s).splitlines())+'\n')
(O/'candidate.sv').write_text(s.replace(' import arm_pkg::*;','').replace('arm9_mem_ucode','candidate_mem',1))
(O/'microcode.json').write_text(json.dumps({'bits':160,'rows':rows,'flows':names,'reference':'232c26ac','native_cost_unknown':True},indent=2)+'\n')
print('Generated complete arm9_mem_ucode:',len(s),'bytes;16x10bit asynchronous control store;13 shared flows;production unchanged')
