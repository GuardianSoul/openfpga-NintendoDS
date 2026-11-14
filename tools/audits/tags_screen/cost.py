"""Complete changed metadata cone, retaining source writer and saved-row cost."""
from pathlib import Path
import ast,json,fcntl,collections,hashlib
P=Path(__file__).with_name('screen.py');nodes=[]
for n in ast.parse(P.read_text()).body:
 if isinstance(n,ast.Expr)and isinstance(n.value,ast.Call)and isinstance(n.value.func,ast.Name)and n.value.func.id=='status':break
 nodes.append(n)
ns={'__file__':str(P.resolve())};exec(compile(ast.Module(body=nodes,type_ignores=[]),str(P),'exec'),ns);globals().update({k:v for k,v in ns.items()if k not in ['__name__','__file__']})
common='''module CONE(input clk,input[3:0]st,input[2:0]dp_kind,input[15:0]cmo_op,
input[31:0]xw_a,xw_d,dp_a,dp_val,ip_a,b_rdata,f_addr,w_addr,
input[3:0]xw_be,swa_d,swa_i,input xw_way,xw_dc,xw_tag,iline,dline,
input[2:0]k,fsd,fsi,input b_ack,input[11:0]inv_n,
input[40:0]da_raw,db_raw,ia_raw,ib_raw,input[1:0]dirty,
output[40:0]d_data,i_data,output[2:0]mask_d,mask_i,output[7:0]dt_aa,it_aa,
output busy_d,busy_i,output[1:0]d_hits,i_hits,dmva,imva,output[31:0]ev_addr);
'''+const+func+'''
wire[40:0]da=DA,db=DB,ia=IA,ib=IB;
reg vway,tlru,ilru;reg[20:0]ev_lane;reg[1:0]imask;
wire[1:0]d_mva=hf(da,dp_val),i_mva=hf(ia,dp_val);
assign d_hits=hf(db,w_addr);assign i_hits=hf(ib,f_addr);assign dmva=d_mva;assign imva=i_mva;
wire chosen=(dp_kind==DK_LINE)?((cmo_op[2:0]==2)?dp_val[30]:d_mva[1]?1'b1:d_mva[0]?1'b0:da[40]):da[40];
wire[19:0]selected=chosen?da[39:20]:da[19:0];
wire[62:0]dt_ad;wire[59:0]it_ad;wire[2:0]dt_we,it_we;
writer w(.st(st),.dp_kind(dp_kind),.cmo_op(cmo_op),.xw_a(xw_a),.xw_d(xw_d),.dp_a(dp_a),.dp_val(dp_val),.ip_a(ip_a),.b_rdata(b_rdata),.xw_be(xw_be),.swa_d(swa_d),.swa_i(swa_i),.xw_way(xw_way),.xw_dc(xw_dc),.xw_tag(xw_tag),.iline(iline),.vway(vway),.tlru(tlru),.ilru(ilru),.dline(dline),.k(k),.fsd(fsd),.fsi(fsi),.b_ack(b_ack),.inv_n(inv_n),.ev_lane(ev_lane),.imask(imask),.dt_ad(dt_ad),.it_ad(it_ad),.dt_we(dt_we),.it_we(it_we),.dt_aa(dt_aa),.it_aa(it_aa),.busy_d(busy_d),.busy_i(busy_i));
always @(posedge clk)begin
 if(st==S_TAG&&k!=0)begin vway<=chosen;ev_lane<={selected[19],dirty[chosen],selected[18:0]};tlru<=da[40];end
 if(st==S_ITAG&&k!=0)begin
  if(iline)imask<=(cmo_op[2:0]==2)?{ia[39]&&dp_val[30],ia[19]&&!dp_val[30]}:i_mva;
  else begin vway<=ia[40];ilru<=ia[40];end
 end
end
wire[7:0]dset=(dp_kind==DK_LINE&&cmo_op[2:0]==2)?sw_dset(dp_val,swa_d):dp_a[12:5];
assign ev_addr={ev_lane[18:0],dset,k,2'b00};
EXTRA
endmodule
'''
oldextra='''
assign mask_d=dt_we;assign mask_i=it_we;
// Native per-lane write enables make unselected lane data don't-care.
assign d_data={dt_we[2]?dt_ad[42]:1'bx,dt_we[1]?{dt_ad[41],dt_ad[39:21]}:20'bx,dt_we[0]?{dt_ad[20],dt_ad[18:0]}:20'bx};
assign i_data={it_we[2]?it_ad[40]:1'bx,it_we[1]?it_ad[39:20]:20'bx,it_we[0]?it_ad[19:0]:20'bx};
'''
newextra='''
reg[24:0]saved;
always @(posedge clk)begin
 if(st==S_TAG&&k!=0)saved<={4'd0,pd(da)};
 if(st==S_ITAG&&k!=0)saved<=pi(ia);
end
wire[20:0]dw;wire[24:0]iw;
wire[39:0]dn={{dt_ad[41],dt_ad[39:21]},{dt_ad[20],dt_ad[18:0]}};
packed_update update(saved[20:0],saved,dn,it_ad[39:0],dt_we[1:0],it_we[1:0],dt_we[2],it_we[2],dt_ad[42],it_ad[40],dw,iw);
assign mask_d={3{|dt_we}};assign mask_i={3{|it_we}};
assign d_data=(|dt_we)?ed(dw):41'bx;assign i_data=(|it_we)?ei(iw):41'bx;
'''
old=writer_module+common.replace('CONE','before_meta').replace('DA','da_raw').replace('DB','db_raw').replace('IA','ia_raw').replace('IB','ib_raw').replace('EXTRA',oldextra)
new=writer_module+update_module+common.replace('CONE','after_meta').replace('DA','ed(pd(da_raw))').replace('DB','ed(pd(db_raw))').replace('IA','ei(pi(ia_raw))').replace('IB','ei(pi(ib_raw))').replace('EXTRA',newextra)
res={'source':'af2b633e','scope':'Complete source writer/address/busy plus both-port lookup/MVA/setway selection, ev_lane/roundrobin/imask capture, evictionaddr and after25bitRMW state/reconstruction. NativeRAM cells outside cut; meaningful write-data defined by native lane/full-word enables. No ALM/STA or full-controller equivalence.'}
with(Path.home()/'.cache/nds-sim-build.lock').open('a')as lock:
 fcntl.flock(lock,fcntl.LOCK_EX);assert int(next(l.split()[1]for l in Path('/proc/meminfo').read_text().splitlines()if l.startswith('MemAvailable:')))>=12*1024*1024
 for tag,code,top in [('before',old,'before_meta'),('after',new,'after_meta')]:
  rc,log=run(tag+'-metadata-cost',code,'synth_intel_alm -top '+top+' -family cyclonev -nobram -nodsp -noiopad -noclkbuf\nwrite_json '+str(O/(tag+'-metadata.json'))+'\n');assert rc==0,log[-2500:]
  cells=json.loads((O/(tag+'-metadata.json')).read_text())['modules'][top]['cells'];res[tag]=dict(collections.Counter(c['type']for c in cells.values()));print(tag,res[tag],flush=True)
res['summary']={}
for tag in ['before','after']:
 c=res[tag];res['summary'][tag]={'regular_LUT':sum(v for k,v in c.items()if k.startswith('MISTRAL_ALUT')and k!='MISTRAL_ALUT_ARITH'),'arithmetic':c.get('MISTRAL_ALUT_ARITH',0),'FF':c.get('MISTRAL_FF',0)}
res['delta']={k:res['summary']['after'][k]-res['summary']['before'][k]for k in res['summary']['before']};res['tool_mapping_PASS']=True
(O/'cost-result.json').write_text(json.dumps(res,indent=2)+'\n');print('delta',res['delta'],flush=True)
# Native intent uses the current vendor wrapper, unchanged true-dual-port modes.
intent='''module packed_tag_intent(input clk,input[7:0]d_a,d_b,i_a,i_b,input d_we,i_we,input[20:0]d_data,input[24:0]i_data,
output[31:0]d_aq,d_bq,i_aq,i_bq);
arm9_ram #(.AW(8),.LANES(1),.LANE_W(32),.FOLD(0))d(.clk(clk),.a_addr(d_a),.a_we(d_we),.a_d({11'd0,d_data}),.a_q(d_aq),.b_addr(d_b),.b_q(d_bq));
arm9_ram #(.AW(8),.LANES(1),.LANE_W(32),.FOLD(0))i(.clk(clk),.a_addr(i_a),.a_we(i_we),.a_d({7'd0,i_data}),.a_q(i_aq),.b_addr(i_b),.b_q(i_bq));
endmodule
''';(O/'packed-native-intent.sv').write_text(intent)
