"""Extract exact captured caller; compile both sounds behind the same real boundary."""
from pathlib import Path
import re,json,hashlib,sys
root=Path(__file__).resolve().parents[3];src=Path(__file__).parent/'inputs';out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
m=json.loads((src/'manifest.json').read_text())
for p,h in m['files'].items():assert hashlib.sha256((src/Path(p).name).read_bytes()).hexdigest()==h,p
top=(src/'nds_top.sv').read_text();start=top.index('    generate if (SOUND != 0) begin : g_snd');end=top.index('    end else begin : g_nosnd',start)
body=top[start:end].replace('generate if (SOUND != 0)','generate if (1)')+'    end endgenerate\n'
ports='''input logic clk,clk_2x,rst,tick,snd_req,io_we,
 input logic [3:0] io_be,input logic [23:2] io_addr,input logic [31:0] io_wdata,
 input logic [1:0] powcnt2,input logic sn_ack,input logic [31:0] sn_rdata,
 output logic snd_ack,output logic [31:0] snd_rdata,
 output logic sn_req,sn_we,output logic [31:0] sn_addr,sn_wdata,
 output logic aud_valid,output logic [15:0] aud_l,aud_r,
 output logic [31:0] snd_late,output logic [15:0] snd_wait_max,
 output logic engine_overrun,output logic [9:0] dac_l,dac_r'''
for name,old in [('caller89_new',False),('caller89_old',True)]:
 text=body
 if old:
  text=re.sub(r'\bsound\b','old_sound',text).replace('.COMPACT_ENGINE(1), ','')
 (out/(name+'.sv')).write_text('module '+name+'('+ports+');\n'+text+'''assign engine_overrun=g_snd.u_snd.overrun;
 assign dac_l=g_snd.u_snd.dac_l;assign dac_r=g_snd.u_snd.dac_r;
endmodule
''')
# Explicitly tie unused target inputs; selected protocol paths stay actual RTL.
def connections(name,mapping):
 text=(src/(name+'.sv')).read_text();header=text[text.index(') (')+3:text.index('\n);',text.index(') ('))] if ') (' in text else text[text.index('module '+name):text.index('\n);')]
 text=re.sub(r'//[^\n]*','',header);result=[]
 for kind,names in re.findall(r'\b(input|output)\s+logic\s*(?:\[[^\]]+\])?\s*([^\n]+)',text):
  for n in names.strip().rstrip(',').split(','):
   n=n.strip()
   if not n:continue
   result.append('.'+n+'('+mapping.get(n,"'0" if kind=='input' else '')+')')
 return ',\n'.join(result)
fab={k:k for k in ['clk','rst','a7_req','a7_we','a7_addr','a7_be','a7_wdata','a7_ack','a7_rdata','a9_req','a9_we','a9_addr','a9_be','a9_wdata','a9_ack','a9_rdata','dm_req','dm_we','dm_addr','dm_wdata','dm_ack','dm_rdata','sn_req','sn_we','sn_addr','sn_wdata','sn_ack','sn_rdata','io_req','io_cpu','io_we','io_be','io_addr','io_wdata','io_ack','io_rdata','mr_req','mr_we','mr_addr','mr_be','mr_wdata','mr_ack','mr_rvalid','mr_rdata','mr_n8','wramcnt']}
fab.update(exmemcnt9='exmemcnt[7:0]',dm_size32="1'b1",dx_ready="1'b1",dx_idle="1'b1")
io={k:k for k in ['clk','rst','io_req','io_cpu','io_we','io_be','io_addr','io_wdata','io_ack','io_rdata','snd_req','snd_ack','snd_rdata','powcnt2','wramcnt','exmemcnt','irq_key7','irq_key9','gx_irq']};io['snd_real']="1'b1"
text=(Path(__file__).parent/'endpoint.sv.in').read_text().replace('@FABRIC@',connections('nds_fabric',fab)).replace('@IO@',connections('nds_io',io))
(out/'endpoint.sv').write_text(text)
print('CALLER89_SNAPSHOT_EXTRACT_PASS')
