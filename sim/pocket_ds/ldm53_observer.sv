// PASSIVE RAW FALLBACK: no instruction IDs or inferred fabric/posted-write PC.
// Optional bind for next changed model; source-ready, not elaborated.
// +ldm53_observe=CSV +ldm53_roi=742_BIT_HEX_FILE, both frozen before run.
`define L53D $root.tb_ds_pocket.dut
`define L53A `L53D.ds.u_cpud.g_one.u_cpu
`define L53C `L53A.u_core
`define L53M `L53A.u_mem9
`define L53F `L53D.ds.u_fab
module nds_ldm53_observer;
  timeunit 1ns; timeprecision 1ps;
  localparam int BEGIN_CALL=1,END_CALL=2,PIPE=3,DATA=4,PERMIT=5,DP_CAPTURE=6,
    BUS=7,GRANT=8,RAW=9,FAB_ACK=10,CPU_ACK=11,WB=12,RF=13,RETIRE=14,
    HOLD=15,WORK=16,ISSUE=17,CONFIG=18,RESET=19,FINISH=255;
  localparam logic[31:0] COPY_PC=32'h01ff8020,ANCHOR_PC=32'h01ffb1d4,MAIN=32'h0202c5a0;
  bit enabled=0,armed=0,active=0,detail=0,permission_seen=0,work_due=0,reset_seen=0;
  logic roi[0:741];
  string path,roi_path;integer fd=0,call_index=-1,completed=0,selected=0;
  longint unsigned tick=0,record_seq=0,begin_tick=0,body_words=0;
  logic[63:0] digest=64'd1469598103934665603,word_hash=0,roi_hash=64'd1469598103934665603;
  logic[63:0] old_hold='1,old_bus='1;
  function automatic logic[63:0] mix(input logic[63:0] h,v);
    return (h^v)*64'd1099511628211;
  endfunction
  function automatic bit scoped(input logic[31:0] pc);
    return (pc>=COPY_PC && pc<COPY_PC+584) || (pc>=ANCHOR_PC && pc<ANCHOR_PC+124);
  endfunction
  function automatic int form(input int n);return n/7<104?(n/7)/8:13;endfunction
  function automatic int context_index(input int n);return n/7<104?(n/7)%8:(n/7)-104;endfunction
  function automatic int words(input int n);
    case(form(n))
      0,4:return 1;1,5:return 2;2,6:return 4;13:return 0;default:return 8;
    endcase
  endfunction
  function automatic int bytes(input int n);
    case(form(n))
      4,5,6,7,8:return 188;9:return 316;10:return 572;11,12:return 380;default:return 124;
    endcase
  endfunction
  function automatic logic[31:0] entry(input int n);
    return form(n)==3 && n%7<6?ANCHOR_PC:COPY_PC;
  endfunction
  function automatic logic[31:0] last_pc(input int n);
    // Signature tail adds12 bytes, but its last word is a DATA literal.
    // BX LR moves by8 bytes; it is not the appended literal at+12.
    return entry(n)+32'(bytes(n)-4+(n%7==6?8:0));
  endfunction
  function automatic int expected(input int n);return (context_index(n)%2?64:16)*16*words(n);endfunction
  function automatic logic[31:0] data_base(input int n);
    return MAIN+32'((context_index(n)/2)*4+(form(n)>=4 && form(n)<=7?512:0));
  endfunction
  // seq,tick,kind,source,native_PC,eight raw payloads.
  // source0 control,1 core,2 arm9_mem,3 fabric. PC0=unqualified owner.
  task automatic emit(input int kind,source,input logic[31:0] pc,
    input logic[63:0] a,b,c,d,e,f,g,h);
    record_seq++;
    $fdisplay(fd,"%0d,%0d,%0d,%0d,%08x,%016x,%016x,%016x,%016x,%016x,%016x,%016x,%016x",
      record_seq,tick,kind,source,pc,a,b,c,d,e,f,g,h);
    digest=mix(digest,record_seq);digest=mix(digest,tick);digest=mix(digest,64'(kind));
    digest=mix(digest,64'(source));digest=mix(digest,64'(pc));
    digest=mix(digest,a);digest=mix(digest,b);digest=mix(digest,c);digest=mix(digest,d);
    digest=mix(digest,e);digest=mix(digest,f);digest=mix(digest,g);digest=mix(digest,h);
  endtask
  initial begin
    enabled=$value$plusargs("ldm53_observe=%s",path);
    if(enabled)begin
      if(`L53D.CPU_FAST!=0 || `L53D.A9_SOLO!=5 || !`L53A.SLOW ||
        !`L53A.A7_DS || `L53A.A9_OPT!=461366243 || `L53A.ARM9_WAYS!=4 ||
        `L53A.A9_XD!=0 || `L53A.A9_XI!=0 || !`L53A.ARM9_LDM_BASE_FORWARD ||
        `L53F.LDM_SERVICE!=3)$fatal(1,"LDM53_RAW_PROFILE");
      if(!$value$plusargs("ldm53_roi=%s",roi_path))$fatal(1,"LDM53_ROI_MUST_BE_FROZEN");
      for(int i=0;i<742;i++)roi[i]=1'bx;
      $readmemh(roi_path,roi);
      for(int i=0;i<742;i++)begin
        if($isunknown(roi[i]))$fatal(1,"LDM53_ROI_INCOMPLETE");
        selected+=int'(roi[i]);roi_hash=mix(roi_hash,64'(roi[i]));
      end
      fd=$fopen(path,"w");if(!fd)$fatal(1,"LDM53_RAW_OPEN");
      $fdisplay(fd,"#LDM53RAW,1");
      emit(CONFIG,0,0,64'(selected),roi_hash,742,0,0,0,0,0);
    end
  end
  // Observer-local assignments only; no delay, clock or producer drive.
  always @(posedge `L53C.clk)begin : capture
    logic[63:0] h,b;
    if(enabled)begin
      tick++;
      if(`L53C.rst)begin
        if(!reset_seen)emit(RESET,0,0,0,0,0,0,0,0,0,0);
        reset_seen=1;
        if(armed)$fatal(1,"LDM53_RESET_DURING_CALL_WINDOW");
      end else begin
        reset_seen=0;
        if(`L53C.ce && `L53C.u.valid && `L53C.fresh &&
           (`L53C.u.pc==COPY_PC || `L53C.u.pc==ANCHOR_PC))begin
          if(active || `L53C.c_ins!=32'he92d03f0 || call_index>=741)$fatal(1,"LDM53_RAW_ENTRY");
          call_index++;
          if(`L53C.u.pc!=entry(call_index))$fatal(1,"LDM53_RAW_CALL_ORDER");
          armed=1;active=1;detail=roi[call_index];permission_seen=0;work_due=0;
          body_words=0;word_hash=64'd1469598103934665603;begin_tick=tick;
          old_hold='1;old_bus='1;
          emit(BEGIN_CALL,1,`L53C.u.pc,64'(call_index),64'(`L53C.c_ins),64'(expected(call_index)),
            64'(detail),64'(last_pc(call_index)),64'(data_base(call_index)),64'(form(call_index)),64'(`L53C.mode1));
        end
        if(active)begin
          if(`L53M.b_req && `L53M.b_ack && !`L53M.b_we &&
             `L53M.b_addr>=MAIN && `L53M.b_addr<MAIN+32'd98304)begin
            body_words++;word_hash=mix(mix(mix(word_hash,64'(`L53M.b_addr)),
              64'(`L53M.b_rdata)),64'(`L53M.b_ldm_meta));
          end
          h={44'd0,`L53M.busy_d,`L53M.dp_v,`L53M.st,`L53C.ce,`L53M.cpu_hold,
            `L53M.ldm_slot,`L53C.have,`L53C.sbub,`L53C.sb_cause};
          if(detail)begin
            if(`L53C.ce || h!=old_hold || (`L53M.wd_need && !`L53M.dp_v && !`L53M.busy_d))
              emit(PIPE,1,0,64'(`L53C.e1.pc),64'(`L53C.e2.pc),64'(`L53C.e3.pc),
                64'(`L53C.w_pc),64'(`L53C.x_pc),
                {51'd0,`L53C.d_kill,`L53C.x2_rdr,`L53C.wb_kill,`L53C.kill_e,`L53C.w_go,
                 `L53C.e3_exec,`L53M.cpu_hold,`L53C.ce,`L53C.x_valid,`L53C.w_valid,
                 `L53C.e3.valid,`L53C.e2.valid,`L53C.e1.valid},
                {10'd0,`L53C.e1.step,`L53C.e1.rl,`L53C.e2.step,`L53C.e2.rl,`L53C.e3.step,`L53C.e3.rl},
                {28'd0,`L53C.w_step,`L53C.w_rl,`L53C.x_step,`L53C.x_rl});
            if(`L53C.ce && `L53C.u.valid && scoped(`L53C.u.pc))
              emit(ISSUE,1,`L53C.u.pc,64'(`L53C.c_ins),64'(`L53C.u.step),64'(`L53C.u.rl),
                64'(`L53C.u.ldm_meta),64'(`L53C.u.mem),64'(`L53C.u.last),64'(`L53C.c1),64'(`L53C.u.thumb));
            if(`L53C.ce && `L53C.d_req && scoped(`L53C.e3.pc))
              emit(DATA,1,`L53C.e3.pc,64'(`L53C.d_addr),64'(`L53C.d_ldm_meta),64'(`L53C.d_we),
                64'(`L53C.d_be),64'(`L53C.d_size),64'(`L53C.d_wdata),64'(`L53C.e3.step),64'(`L53C.e3.rl));
            if(`L53M.wq_e && !permission_seen && scoped(`L53C.w_pc))begin
              emit(PERMIT,2,`L53C.w_pc,64'(`L53M.w_addr),64'(`L53M.w_ldm_meta),64'(`L53M.wd_abort),
                64'(`L53M.wd_kind),64'(`L53M.w_be),64'(`L53M.w_we),64'(`L53C.w_step),64'(`L53C.w_rl));
              permission_seen=1;
            end
            if(`L53M.wd_need && !`L53M.dp_v && !`L53M.busy_d && scoped(`L53C.w_pc))
              emit(DP_CAPTURE,2,`L53C.w_pc,64'(`L53M.w_addr),64'(`L53M.w_ldm_meta),64'(`L53M.wd_kind),
                64'(`L53M.w_block),64'(`L53M.w_we),64'(`L53M.wd_abort),64'(`L53C.w_step),64'(`L53C.w_rl));
            b={18'd0,`L53M.b_req,`L53M.b_we,`L53M.b_be,`L53M.b_addr,`L53M.b_ldm_meta,`L53M.b_ldm};
            if(`L53M.b_req && (b!=old_bus || `L53M.b_ack))
              emit(BUS,2,0,64'(`L53M.b_addr),64'(`L53M.b_ldm_meta),64'(`L53M.b_we),
                64'(`L53M.b_ack),64'(`L53M.st),64'(`L53M.dp_a),64'(`L53M.dp_ldm_meta),64'(`L53M.dp_kind));
            old_bus=b;
            if((`L53F.st==`L53F.S_IDLE && `L53F.grant[1]) || `L53F.ld4_take)
              emit(GRANT,3,0,64'(`L53F.a9_addr),64'(`L53F.a9_ldm_meta),64'(`L53F.grant),
                64'(`L53F.ld4_take),64'(`L53F.ls_start),64'(`L53F.ls_work),64'(`L53F.st),64'(`L53F.mst));
            if(`L53F.a9_raw_ack)emit(RAW,3,0,64'(`L53F.ls_addr),64'(`L53F.ls_meta),64'(`L53F.a9_raw_data),
              64'(`L53F.ls_raw),64'(`L53F.ls_defer),64'(`L53F.ls_work),64'(`L53F.st),64'(`L53F.mst));
            if(`L53F.a9_ack)emit(FAB_ACK,3,0,64'(`L53F.a9_addr),64'(`L53F.a9_ldm_meta),64'(`L53F.a9_rdata),
              64'(`L53F.ls_end_ack),64'(`L53F.ls_work),64'(`L53F.ls_end_addr),64'(`L53F.ls_end_meta),64'(`L53F.ls_end));
            if(`L53M.b_req && `L53M.b_ack)emit(CPU_ACK,2,0,64'(`L53M.b_addr),64'(`L53M.b_ldm_meta),64'(`L53M.b_rdata),
              64'(`L53M.b_ldm),64'(`L53M.b_we),64'(`L53M.dp_a),64'(`L53M.dp_ldm_meta),64'(`L53M.dp_kind));
            if(`L53C.ce && `L53C.w_go && `L53C.w_ismem && scoped(`L53C.w_pc))
              emit(WB,2,`L53C.w_pc,64'(`L53C.d_ok),64'(`L53C.d_abort),64'(`L53C.d_rdata),
                64'(`L53M.w_addr),64'(`L53M.w_ldm_meta),64'(`L53C.w_step),64'(`L53C.w_rl),0);
            if(`L53C.rf_we && scoped(`L53C.x_pc))emit(RF,1,`L53C.x_pc,64'(`L53C.rf_wa),64'(`L53C.rf_wd),0,
              64'(`L53C.x_step),64'(`L53C.x_rl),64'(`L53C.x_last),64'(`L53C.x_replay),64'(`L53C.x_abort));
            if(`L53C.rf_we2 && scoped(`L53C.x_pc))emit(RF,1,`L53C.x_pc,64'(`L53C.rf_wa2),64'(`L53C.rf_wd2),1,
              64'(`L53C.x_step),64'(`L53C.x_rl),64'(`L53C.x_last),64'(`L53C.x_replay),64'(`L53C.x_abort));
            if(`L53C.dbg_retire && scoped(`L53C.dbg_pc))emit(RETIRE,1,`L53C.dbg_pc,64'(`L53C.dbg_cpsr),
              64'(`L53C.x_step),64'(`L53C.x_rl),64'(`L53C.x_last),64'(`L53C.x_exec),64'(`L53C.x_replay),64'(`L53C.x_abort),0);
            if(h!=old_hold)emit(HOLD,1,0,64'(`L53C.ce),64'(`L53M.cpu_hold),64'(`L53M.ldm_slot),
              64'(`L53C.sbub),64'(`L53C.sb_cause),64'(`L53C.have),64'(`L53C.d_wait),64'(`L53M.st));
            if(work_due)emit(WORK,3,0,64'(`L53F.ls_work),64'(`L53F.ls_active),64'(`L53F.ls_count),
              64'(`L53F.ls_seen),64'(`L53F.ls_next),64'(`L53F.ls_end),64'(`L53F.ls_end_addr),64'(`L53F.ls_end_meta));
          end
          old_hold=h;work_due=detail && `L53F.ls_start;
          if(`L53C.ce)permission_seen=0;
          if(`L53C.dbg_retire && `L53C.dbg_pc==last_pc(call_index))begin
            emit(END_CALL,1,`L53C.dbg_pc,64'(call_index),body_words,64'(expected(call_index)),
              word_hash,64'(detail),64'(form(call_index)),begin_tick,tick);
            completed++;active=0;detail=0;
          end
        end
      end
    end
  end
  final if(enabled && fd)begin
    emit(FINISH,0,0,record_seq,digest,64'(call_index+1),64'(completed),64'(active),0,0,0);$fclose(fd);
  end
endmodule
bind tb_ds_pocket nds_ldm53_observer u_ldm53_observer();
`undef L53D
`undef L53A
`undef L53C
`undef L53M
`undef L53F
