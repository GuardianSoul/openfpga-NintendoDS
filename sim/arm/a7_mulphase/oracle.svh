// Independent semantic/temporal oracle: architectural Rs and accepted steps.
// The held F ledger is not reconstructed from the producer's private flops.
a7_mul_context_t mul_request, fresh_expected, held_expected='0;
a7_mul_advance_t mul_advance;
a7_exec_meta_t full_observer;
bit ref_owned=0;int metadata_faults=0,step_reference=0;
int mul_discards=0,held_drain=0,failed_mul_seen=0,forwarded_seen=0;
logic [4:0]pst;logic[3:0]pk;logic[1:0]pesub;logic pph,pdm,pifwait;
logic[31:0]pins,ppc;logic[4:0]pmode;logic[4095:0]core_state;logic[1023:0]rf_state,rfb_state;
`include "probe.svh"
`PROBE(cpu.g_a7ds.u_a7)
function automatic bit condition_ok(input logic[3:0]cond,input logic[3:0]nzcv);
 bit n,z,c,v;{n,z,c,v}=nzcv;
 case(cond)
  0:return z;1:return !z;2:return c;3:return !c;4:return n;5:return !n;6:return v;7:return !v;
  8:return c&&!z;9:return !c||z;10:return n==v;11:return n!=v;12:return !z&&n==v;13:return z||n!=v;14:return 1;default:return 0;
 endcase
endfunction
function automatic int measured_work(input logic[31:0]value);
 case(value)
  32'h7f:return 1;32'h7fff:return 2;32'h7fffff:return 3;32'h7fffffff:return 4;
  default:$fatal(1,"oracle Rs outside declared fixture %h",value);
 endcase
endfunction
wire raw_mul=cpu.g_a7ds.u_a7.e_v&&((cpu.g_a7ds.u_a7.ins&32'h0fc000f0)==32'h00000090);
wire executed_mul=raw_mul&&condition_ok(cpu.g_a7ds.u_a7.ins[31:28],cpu.g_a7ds.u_a7.cpsr[12:9]);
wire progress=pst==1&&pph&&run&&!pifwait;
wire expected_advance=!cpu_rst&&progress&&executed_mul&&(pesub==0||pesub==1);
always_comb begin
 fresh_expected='0;
 if(executed_mul)begin
  fresh_expected.valid=1;
  fresh_expected.thumb=cpu.g_a7ds.u_a7.cpsr[5];
  fresh_expected.accumulate=pins[21];fresh_expected.set_flags=pins[20];
  fresh_expected.internal_steps=3'(measured_work(shadow[phys_reg(pins[11:8],pmode)])+int'(pins[21]));
 end
end
task automatic metadata_fault(input string why);
 metadata_faults++;if(metadata_faults<=5)$display("MUL_METADATA_FAULT mode%0d cycle%0d %s",MODE,cycle,why);
endtask
always @(posedge clk)begin
 a7_mul_context_t want;
 a7_mul_advance_t event_want;
 want='0;event_want='0;
 if(!cpu_rst&&ir)want=ref_owned?held_expected:fresh_expected;
 if(expected_advance)begin event_want.valid=1;event_want.index=3'(pesub==0?0:step_reference);end
 assert(full_observer=='0)else $fatal(1,"FULL402_OBSERVER_ACTIVATED");
 if(MODE==3)begin
  if(mul_request!==want)metadata_fault("request context/first offer/owner");
  if(mul_advance!==event_want)metadata_fault("actual execution advance/index");
 end else if({mul_request,mul_advance}!='0)metadata_fault("default/off route nonzero");
 if(!cpu_rst&&ref_owned&&held_expected.valid&&!executed_mul&&ir)held_drain++;
 if(!cpu_rst&&raw_mul&&!executed_mul)failed_mul_seen++;
 if(!cpu_rst&&executed_mul&&cpu.g_a7ds.u_a7.opb==32'h7fff&&variant)forwarded_seen++;
 if(!cpu_rst&&iredirect&&ref_owned&&held_expected.valid)mul_discards++;
 if(cpu_rst||iredirect||iconsume)begin ref_owned=0;held_expected='0;end
 else if(ir&&!ref_owned)begin ref_owned=1;held_expected=fresh_expected;end
 if(cpu_rst)step_reference=0;
 else if(expected_advance)begin
  if(pesub==0)step_reference=1;else step_reference++;
  assert(step_reference<=int'(fresh_expected.internal_steps))else $fatal(1,"oracle extra execution advance");
 end else if(progress&&executed_mul&&pesub==2)begin
  assert(step_reference==int'(fresh_expected.internal_steps))else $fatal(1,"oracle missing execution advance");step_reference=0;
 end
end
