// Testbench-only DS30 observer. Reads DUT storage; writes host files/local state only.
`define D30CPU dut.ds.u_cpud.g_one.u_cpu
`define D30CORE `D30CPU.u_core
`define D30MEM `D30CPU.u_mem9
`define D30A7 `D30CPU.g_a7ds.u_a7
`include "sim/pocket_ds/ds30_tables.svh"
bit ds30_enabled=0,ds30_done=0,ds30_ping_seen=0;
integer ds30_fd=0,ds30_calls=0,ds30_returns=0;
longint unsigned ds30_clock=0;
string ds30_prefix;
string ds30_expected_path="ds30_expected.hex";
logic [31:0] ds30_expected[0:DS30_BYTES-1];
function automatic logic [31:0] ds30_rf(input integer regno,input logic[31:0] psr);
    return `D30CORE.u_rf.g_dual.regs[arm_pkg::phys_reg(4'(regno),psr[4:0])];
endfunction
function automatic logic [31:0] ds30_itcm(input integer wordno);
    return {`D30MEM.u_itcm.lane[3].mem[wordno],`D30MEM.u_itcm.lane[2].mem[wordno],
            `D30MEM.u_itcm.lane[1].mem[wordno],`D30MEM.u_itcm.lane[0].mem[wordno]};
endfunction
function automatic integer ds30_wram_physical(input logic[31:0] address,input logic[1:0] wc);
    if(address[23] || wc==0)return integer'(address & 32'hffff);
    case(wc)
        1:return 32'h10000+integer'(address & 32'h3fff);
        2:return 32'h14000+integer'(address & 32'h3fff);
        default:return 32'h10000+integer'(address & 32'h7fff);
    endcase
endfunction
function automatic logic [31:0] ds30_wram_word(input integer physical);
    if(dut.A7_WRAM!=0)begin
        if(physical & 32'h10000)return dut.ds.u_wram.u_shared.mem[(physical & 32'h7fff)>>2];
        return dut.ds.u_wram.u_private.mem[(physical & 32'hffff)>>2];
    end
    return {u_sram.mem[(physical>>1)+1],u_sram.mem[physical>>1]};
endfunction
function automatic logic [7:0] ds30_byte(input integer cpu,input logic[31:0] address);
    logic[31:0] wordval;
    if(cpu==9 && address<32'h02000000)wordval=ds30_itcm(integer'((address & 32'h7fff)>>2));
    else if(cpu==7 && address[31:24]==8'h03)
        wordval=ds30_wram_word(ds30_wram_physical(address,dut.ds.wramcnt)&~3);
    else wordval=ram_word(integer'((address & 32'h3fffff)>>2));
    return 8'(wordval>>(8*address[1:0]));
endfunction
function automatic logic[31:0] ds30_cprb(input integer index);
    return `D30MEM.cprb_v[index] ? `D30MEM.cprb[index] : 32'd0;
endfunction
task automatic ds30_context(input string event_name,input string stage,input logic[31:0] pc,input logic[31:0] psr,input logic[31:0] arg);
    logic[31:0] cp[0:15];
    cp[0]=`D30MEM.ctrl;cp[1]={24'd0,`D30MEM.dcb};cp[2]={24'd0,`D30MEM.icb};
    cp[3]={24'd0,`D30MEM.wbb};cp[4]=`D30MEM.dap;cp[5]=`D30MEM.iap;
    cp[6]=ds30_cprb(8);cp[7]=ds30_cprb(9);
    for(integer i=0;i<8;i++)cp[8+i]=ds30_cprb(i);
    $fwrite(ds30_fd,"{\"event\":\"%s\",\"stage\":\"%s\",\"clock\":%0d,\"time_ps\":%0d,\"pc\":%0d,\"cpsr\":%0d,\"sp\":%0d,\"r0\":%0d,\"wramcnt\":%0d,\"A7_WRAM\":%0d,\"EXMEMCNT\":%0d,\"POWCNT1\":%0d,\"VRAMCNT\":\"%018h\",\"IME9\":%0d,\"IE9\":%0d,\"IME7\":%0d,\"IE7\":%0d,\"cp15\":[",
        event_name,stage,ds30_clock,64'($realtime/1ps),pc,psr,ds30_rf(13,psr),arg,
        dut.ds.wramcnt,dut.A7_WRAM,dut.ds.exmemcnt,dut.ds.powcnt1,dut.ds.vramcnt,
        dut.ds.u_sys.i9_ime,dut.ds.u_sys.i9_ie,dut.ds.u_sys.i7_ime,dut.ds.u_sys.i7_ie);
    for(integer i=0;i<16;i++)$fwrite(ds30_fd,"%s%0d",i?",":"",cp[i]);
    $fwrite(ds30_fd,"],\"ARM7_current_pc\":%0d,\"ARM7_cpsr\":%0d,\"ARM7_sp\":%0d}\n",`D30A7.pc,`D30A7.dbg_cpsr,`D30A7.rf[arm_pkg::phys_reg(4'd13,`D30A7.mode)]);
endtask
task automatic ds30_bodies(input string stage,input logic[31:0] pc,input logic[31:0] psr);
    integer fd,offset,physical;
    logic[7:0] value;
    fd=$fopen({ds30_prefix,".",stage,".bodies.bin"},"wb");
    if(!fd)$fatal(1,"DS30_OBSERVER_ERROR body output");
    ds30_context("checkpoint",stage,pc,psr,ds30_rf(0,psr));
    offset=0;
    for(integer i=0;i<25;i++)begin
        if(ds30_cpu(i)==9 && ds30_address(i)<32'h02000000)physical=integer'(ds30_address(i)&32'h7fff);
        else if(ds30_cpu(i)==7 && (ds30_address(i)>>24)==8'h03)physical=ds30_wram_physical(ds30_address(i),dut.ds.wramcnt);
        else physical=integer'(ds30_address(i)&32'h3fffff);
        for(integer n=0;n<ds30_size(i);n++)begin
            value=ds30_byte(ds30_cpu(i),ds30_address(i)+32'(n));
            if(value!==8'(ds30_expected[offset+n]))
                $fatal(1,"DS30_OBSERVER_ERROR stage%s body%0d offset%0d actual%h expected%h wc%0d",stage,i,n,value,ds30_expected[offset+n],dut.ds.wramcnt);
            $fwrite(fd,"%c",value);
        end
        $fwrite(ds30_fd,"{\"event\":\"body\",\"stage\":\"%s\",\"index\":%0d,\"cpu\":%0d,\"address\":%0d,\"bytes\":%0d,\"file_offset\":%0d,\"physical\":%0d,\"wramcnt\":%0d}\n",stage,i,ds30_cpu(i),ds30_address(i),ds30_size(i),offset,physical,dut.ds.wramcnt);
        offset+=ds30_size(i);
    end
    $fclose(fd);$fflush(ds30_fd);
endtask
task automatic ds30_main_dump();
    integer fd;logic[31:0] value;
    fd=$fopen({ds30_prefix,".main.bin"},"wb");if(!fd)$fatal(1,"DS30_OBSERVER_ERROR MAIN output");
    for(integer i=0;i<(1<<20);i++)begin
        value=ram_word(i);$fwrite(fd,"%c%c%c%c",value[7:0],value[15:8],value[23:16],value[31:24]);
    end
    $fclose(fd);
endtask
initial if($value$plusargs("ds30_observe=%s",ds30_prefix))begin
    integer existing;
    if(dut.CPU_FAST!=0 || (dut.A9_SOLO & 7)!=5 || dut.A9_OPT!=461366243 || !`D30CORE.u_rf.DUAL_WRITE)
        $fatal(1,"DS30_OBSERVER_ERROR unsupported CPU hierarchy/profile");
    void'($value$plusargs("ds30_expected=%s",ds30_expected_path));
    $readmemh(ds30_expected_path,ds30_expected);
    existing=$fopen({ds30_prefix,".jsonl"},"r");
    if(existing)begin $fclose(existing);$fatal(1,"DS30_OBSERVER_ERROR existing output prefix");end
    ds30_fd=$fopen({ds30_prefix,".jsonl"},"w");if(!ds30_fd)$fatal(1,"DS30_OBSERVER_ERROR witness output");
    $fwrite(ds30_fd,"{\"event\":\"schema\",\"version\":1,\"evidence\":\"actual_native\",\"body_count\":25,\"body_bytes\":%0d,\"parameters\":{\"CPU_FAST\":%0d,\"A9_SOLO\":%0d,\"A9_OPT\":%0d,\"A7_WRAM\":%0d},\"trigger\":\"direct_ARM9_preposedge_retirement_postNBA1ps_snapshot\"}\n",DS30_BYTES,dut.CPU_FAST,dut.A9_SOLO,dut.A9_OPT,dut.A7_WRAM);
    ds30_enabled=1;
end
always @(posedge dut.clk_sys)begin : ds30_watch
    logic[31:0] pc,psr,arg;
    ds30_clock++;
    if(ds30_enabled && !ds30_done && `D30CORE.dbg_retire && !`D30CORE.dbg_tid)begin
        pc=`D30CORE.dbg_pc;psr=`D30CORE.dbg_cpsr;arg=ds30_rf(0,psr);
        if(pc==32'h02001458 || pc==32'h020014aa)begin
            ds30_calls++;#1ps;ds30_context("command_call","call",pc,psr,arg);
        end else if(pc==32'h0200145c || pc==32'h020014ae)begin
            ds30_returns++;#1ps;ds30_context("command_return","return",pc,psr,arg);
            if(arg==32'h03ffffff)$fatal(1,"DS30_OBSERVER_ERROR actual command timeout/BAD");
            if(pc==32'h0200145c && !ds30_ping_seen)begin
                if(arg!=32'h00123456)$fatal(1,"DS30_OBSERVER_ERROR PING value");
                ds30_ping_seen=1;ds30_bodies("ping",pc,psr);
            end
        end else if(pc==32'h02001f34)begin
            #1ps;
            if(!ds30_ping_seen || ds30_calls!=32 || ds30_returns!=32)$fatal(1,"DS30_OBSERVER_ERROR command coverage");
            ds30_bodies("endpoint",pc,psr);ds30_main_dump();
            $fwrite(ds30_fd,"{\"event\":\"complete\",\"calls\":%0d,\"returns\":%0d,\"clock\":%0d}\n",ds30_calls,ds30_returns,ds30_clock);
            $fclose(ds30_fd);$display("DS30_OBSERVER_ENDPOINT_OK bodies50 calls32 returns32");
            ds30_done=1;
        end
    end
end
final if(ds30_enabled && !ds30_done)$display("DS30_OBSERVER_INCOMPLETE: no complete endpoint; no timing or runtime verdict");
`undef D30CPU
`undef D30CORE
`undef D30MEM
`undef D30A7
