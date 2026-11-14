// Scheduled arithmetic for the complete edge/span service prototype.
// E consumes the edge context, M consumes the span context. Geometry,
// lighting, stage1 and the existing dividers remain independent.
// Enabled only by the defaultoff ES2 frontend option.
module gpu3d_es_math2x (
    input logic clk,clk2,
    input logic [26:0] e_ma,e_mb,s_ma,s_mb,
    input logic signed [24:0] e_a,e_b,s_a,s_b,
    input logic [31:0] e_add_a,e_add_b,s_add_a,s_add_b,
    input logic e_carry,
    output logic [31:0] e_sum,s_sum,
    output logic [53:0] e_product,e_registered_product,s_product,
    output logic [24:0] e_difference,e_minimum,s_difference,s_minimum,
    output logic e_less,e_equal,s_less,s_equal
);
    logic epoch=1'b0,seen=1'b0;
    wire middle=epoch!=seen;
    always_ff @(posedge clk)epoch<=!epoch;
    always_ff @(posedge clk2)seen<=epoch;

    wire [26:0] ma=middle?s_ma:e_ma;
    wire [26:0] mb=middle?s_mb:e_mb;
    wire [53:0] product=ma*mb;
    wire signed [24:0] a=middle?s_a:e_a;
    wire signed [24:0] b=middle?s_b:e_b;
    wire less=a<b;
    wire equal_=a==b;
    wire [24:0] difference=less?25'(b-a):25'(a-b);
    wire [24:0] minimum=less?25'(a):25'(b);
    wire [31:0] add_a=middle?s_add_a:e_add_a;
    wire [31:0] add_b=middle?s_add_b:e_add_b;
    wire [31:0] sum_=add_a+add_b+32'(!middle&&e_carry);
    // Qualified before E, when the product belongs to the edge context.
    // X_IL/X_Z2 need this tap in addition to the registered product date.
    assign e_product=product;
    assign e_difference=difference;
    assign e_minimum=minimum;
    assign e_less=less;
    assign e_equal=equal_;
    assign e_sum=sum_;
    always_ff @(posedge clk)e_registered_product<=product;
    always_ff @(posedge clk2)if(middle)begin
        s_product<=product;
        s_difference<=difference;s_minimum<=minimum;
        s_less<=less;s_equal<=equal_;
        s_sum<=sum_;
    end
endmodule

// Span-only alternative to ES2. Raw slope data is already available during
// EPS, one SYS before the original EP consumption. Two reserved middle
// edges replace parallel wide boundary/coverage arithmetic. The edge units,
// their private vertices and both divider handshakes remain unchanged.
module gpu3d_span_params2x (
    input logic clk,clk2,rst,prepare,finish,coverage,
    input logic signed [31:0] raw_dx,
    input logic [26:0] raw_inc,
    input logic [9:0] raw_xlen,
    input logic [7:0] raw_ylen,
    input logic raw_neg,raw_xmaj,side,swap,
    output logic signed [11:0] length_,
    output logic covx,negative,subtract,
    output logic [4:0] cov5,
    output logic [9:0] denominator,
    output logic [31:0] numerator
);
    logic epoch=0,es_fast_seen=0;
    wire middle=epoch!=es_fast_seen;
    always_ff @(posedge clk)epoch<=!epoch;
    always_ff @(posedge clk2)es_fast_seen<=epoch;
    logic [12:0] work_a,work_b;
    logic [7:0] ylen;
    logic crossing,invert_cov,zero_inc,swapped;
    logic [12:0] es_fast_boundary_hi,es_fast_result;
    logic es_fast_crossing;
    logic [20:0] es_fast_product;
    wire minus=prepare&&raw_xmaj&&(side^raw_neg);
    wire [31:0] alu_a=prepare?(raw_xmaj?32'(raw_dx):32'(raw_dx[17:0])):32'(work_a);
    wire [31:0] raw_b=32'(raw_inc);
    wire [31:0] alu_b=prepare?(minus?~raw_b:raw_b):32'(work_b);
    wire [31:0] alu_sum=alu_a+alu_b+32'(minus);
    // cn=(signed startx<<10)+512. Its magnitude is an odd 13-bit
    // integer times512. Register the 13x8 product separately from work
    // addition, and preserve the original 32-bit +/-1 correction exactly.
    wire [11:0] magnitude=es_fast_result[12]?~es_fast_result[11:0]:es_fast_result[11:0];
    wire [12:0] odd_factor={magnitude,1'b1};
    wire [22:0] decremented={2'b0,es_fast_product}-23'd1;
    always_comb begin
        negative=covx&&es_fast_result[12];
        cov5='0;
        if(!covx)begin
            if(zero_inc)cov5=swapped?5'd0:5'd31;
            else if(crossing)cov5=invert_cov?5'd0:5'd31;
            else cov5=invert_cov?~es_fast_result[8:4]:es_fast_result[8:4];
        end
        if(!subtract)numerator={2'b0,es_fast_product,9'b0};
        else if(negative)numerator={2'b0,es_fast_product,8'b0,1'b1};
        else numerator={decremented,9'h1ff};
    end
    always_ff @(posedge clk2)if(middle)begin
        if(prepare)begin
            es_fast_boundary_hi<=alu_sum[30:18];
            es_fast_crossing<=alu_sum>32'h40000||alu_sum==0;
        end
        if(finish)es_fast_result<=alu_sum[12:0];
        if(coverage)es_fast_product<=odd_factor*ylen;
    end
    always_ff @(posedge clk)if(!rst&&prepare)begin
        logic [12:0] dx_hi,len,base;
        dx_hi=13'(raw_dx>>>18);len=13'd1;
        if(raw_xmaj)begin
            if(!swap||side)
                len=(side^raw_neg)?dx_hi-es_fast_boundary_hi:es_fast_boundary_hi-dx_hi;
            base=raw_neg?13'(raw_xlen)-dx_hi:dx_hi;
            work_a<=base;work_b<=side?13'd1-len:13'd0;
        end else begin
            work_a<=13'(raw_dx[17:9]);work_b<=13'(raw_inc[18:10]);
        end
        length_<=raw_xmaj&&!swap?12'(len):12'sd1;
        covx<=raw_xmaj;denominator<=raw_xlen;ylen<=raw_ylen;
        crossing<=es_fast_crossing;invert_cov<=swap?(side^raw_neg):!(side^raw_neg);
        zero_inc<=raw_inc==0;swapped<=swap;subtract<=raw_neg;
    end
`ifndef SYNTHESIS
    // synthesis translate_off
    logic boundary_born=0,work_born=0,product_born=0;
    always @(posedge clk2)begin
        if(rst)begin boundary_born=0;work_born=0;product_born=0;end
        else if(middle)begin
            if(prepare)begin boundary_born=1;work_born=0;product_born=0;end
            if(finish)work_born=1;
            if(coverage)product_born=1;
        end
    end
    always @(posedge clk)if(!rst)begin
        if(prepare&&!boundary_born)$fatal(1,"SPAN_SCHEDULE_UNBORN_BOUNDARY");
        if(finish&&!work_born)$fatal(1,"SPAN_SCHEDULE_UNBORN_WORK");
        if(coverage&&!product_born)$fatal(1,"SPAN_SCHEDULE_UNBORN_PRODUCT");
    end
    // synthesis translate_on
`endif
endmodule

// Compact-profile stage2 controller. Stage1 and the two existing divider
// clients retain their original handshakes. Long-lived numeric state lives
// in context owner 0; product and item metadata retain their original dates.
module gpu3d_es_edge #(
    parameter int HW=432, BKW=2,
    parameter bit VREG=1, PFE=1, TOONR=1, DS_TEXRND=1, YNW=0
) (
    input logic clk,clk2,rst,vm_we,
    input logic [BKW+3:0] vm_waddr,
    input logic [115:0] vm_wdata,
    input logic hi_valid,pfi_v,
    input logic [HW-1:0] hi,
    input logic [BKW+7:0] pfi_idx,
    output logic busy,fin,dv_start,dv_req,dv_hold,dv_mode,
    output logic [31+YNW:0] dv_num,
    output logic [24:0] dv_den,
    input logic dv_gnt,dv_busy,
    input logic [17:0] dv_q,
    output logic xmaj,
    output logic [9:0] xlen,xcovinc,
    output logic [7:0] ylen,
    output logic [15:0] w,
    output logic [23:0] z,
    output logic [4:0][16:0] av,
    output logic [8:0] rt,
    output logic it_we,
    output logic [3:0] it_k,
    output logic [16:0] it_v,
    output logic [26:0] ma,mb,
    input logic [53:0] product,registered_product,
    output logic [31:0] add_a,add_b,
    output logic carry,
    input logic [31:0] sum_,
    output logic signed [24:0] alu_a,alu_b,
    input logic [24:0] difference,minimum,
    input logic less,equal_,middle,
    output logic rf_we,
    output logic [4:0] rf_wa,
    output logic [63:0] rf_wd,
    input logic [63:0] rf_static,rf_factor
);
    // Layout matches the original stage1 handover exactly. Results belonging
    // to stage1 are discarded here, as in the original STAGE=2 instance.
    localparam int HU=BKW+8+10+8+10+1+1+1+1+10+18+23+27+27+1+32+10+9+3;
    wire [BKW+7:0] hi_idx;
    wire [9:0] hi_ix,hi_xlen;
    wire [7:0] hi_ylen;
    wire hi_xmaj,hi_lin,hi_need_lf,hi_pending;
    wire [9:0] hi_yf;
    wire [17:0] hi_lf;
    wire [22:0] hi_recip;
    wire [26:0] hi_r26;
    wire [78:0] unused_result;
    wire hi_wbuf,hi_aa,hi_toon;
    assign {hi_idx,hi_ix,hi_ylen,hi_xlen,hi_xmaj,hi_lin,hi_need_lf,hi_pending,
            hi_yf,hi_lf,hi_recip,hi_r26,unused_result,hi_wbuf,hi_aa,hi_toon}=HU'(hi);
    wire [9:0] ix=rf_static[9:0];
    assign ylen=rf_static[17:10];
    assign xlen=rf_static[27:18];
    wire [17:0] lf=rf_factor[17:0];
    wire [9:0] yf=rf_factor[27:18];
    logic lin,yf_pend,l_wbuf,l_aa,l_toon,cov_pend;
    logic [54:0] es_fast_birth_factor;
    logic es_fast_birth_pending=0;
    typedef enum logic [3:0] {X_IDLE,X_BW,X_BL0,X_BLW,X_BL1,X_BL2,
        X_Z,X_Z3,X_YF,X_IP,X_FIN} state_t;
    state_t xs;
    logic [BKW+7:0] b_idx,ld_idx,pf_have;
    logic [2:0] pf_st;
    logic pf_ok,current_slot=0,load_slot=1;
    logic [BKW+3:0] vm_ra;
    logic [115:0] vm_ram,vm_q;
    wire [115:0] vm_data=VREG?vm_q:vm_ram;
    assign vm_ra={ld_idx[BKW+7:8],(pf_st==1||xs==X_BL0)?ld_idx[7:4]:ld_idx[3:0]};
    gpu3d_ram #(.W(116),.AW(BKW+4),.STYLE("M10K"))u_vtx(
        .clk,.we(vm_we),.waddr(vm_waddr),.wdata(vm_wdata),.raddr(vm_ra),.rdata(vm_ram));
    always_ff @(posedge clk)vm_q<=vm_ram;

    // Every full-record copy occurs on the original BL/PFE write event.
    // The active slot remains immutable until its last scalar operand read.
    wire snap_a=xs==X_BL1||pf_st==3;
    wire snap_b=xs==X_BL2||pf_st==4;
    wire snap_we=!rst&&(snap_a||snap_b);
    logic [1:0][79:0] wz;
    always_ff @(posedge clk)if(snap_we)begin
        if(snap_a)wz[load_slot][79:40]<={vm_data[56:41],vm_data[40:17]};
        else wz[load_slot][39:0]<={vm_data[56:41],vm_data[40:17]};
    end
    wire [15:0] w0=wz[current_slot][79:64];
    wire [23:0] z0=wz[current_slot][63:40],z1=wz[current_slot][23:0];
    logic [3:0] k,next_k;
    logic req;
    wire dv_idle=!dv_busy&&!dv_start;
    wire yf_go=xs==X_YF&&(!yf_pend||dv_idle)&&(!(l_aa&&xmaj)||dv_gnt);
    wire issue=xs==X_IP&&(k<=5||(k==6&&l_wbuf)||(k==7&&l_toon&&!TOONR));
    always_comb begin
        req=issue;next_k=k;
        if(yf_go)begin req=1;next_k=lin?4'd1:4'd0;end
        else if(issue)next_k=(k==5&&!l_wbuf)?4'd7:k+4'd1;
    end
    logic [24:0] a,b;
    logic snap_valid,snap_slot;
    logic [3:0] snap_item;
    gpu3d_es_vertex_snapshot u_snapshot(.clk,.clk2,.rst,
        .we(snap_we),.write_slot(load_slot),.write_side(snap_b),.wdata(vm_data),
        .req,.read_slot(current_slot),.toon_red(TOONR&&l_toon),.item(next_k),
        .a,.b,.valid(snap_valid),.slot_out(snap_slot),.item_out(snap_item));
    // One shared min/difference lane: Z in setup, streamed item in the loop.
    assign alu_a=xs==X_Z?25'(z0):a;
    assign alu_b=xs==X_Z?25'(z1):b;
    wire item_linear=lin&&k!=6;
    wire [17:0] factor=item_linear?(less?lf:18'h20000-lf):
        18'(less?{1'b0,yf}:11'd512-{1'b0,yf});
    logic mw;
    logic c_v,c2_v,c_direct,c2_direct,c_lsh,c2_lsh,c_tb,c2_tb;
    logic [3:0] c_k,c2_k;
    logic [24:0] c_base,c2_base;
    logic [24:0] value_;
    assign add_a=xs==X_Z3?32'(z0<z1?z0:z1):32'(c2_base);
    assign add_b=xs==X_Z3?32'(registered_product>>17):
        (c2_lsh?32'(registered_product>>17):32'(registered_product>>9));
    assign carry=xs==X_IP&&c2_tb&&(&registered_product[16:13]);
    always_comb begin
        it_we=!rst&&xs==X_IP&&c2_v;it_k=c2_k;
        value_=c2_direct?c2_base:25'(sum_);
        it_v=value_[16:0];
    end
    assign fin=xs==X_FIN&&(!cov_pend||dv_idle);
    assign dv_req=xs==X_YF&&l_aa&&xmaj;
    assign dv_hold=yf_pend||cov_pend||dv_start;
    // E: static birth or owned divider return. M: second birth only. No
    // result-return arbitration, and no row is consumed before its birth.
    always_comb begin
        rf_we=0;rf_wa=0;rf_wd=0;
        if(!rst)begin
            if(!middle&&xs==X_IDLE&&hi_valid)begin
                rf_we=1;rf_wd=64'({hi_recip,hi_xlen,hi_ylen,hi_ix});
            end else if(middle&&es_fast_birth_pending)begin
                rf_we=1;rf_wa=1;rf_wd=64'(es_fast_birth_factor);
            end else if(!middle&&yf_go&&yf_pend)begin
                rf_we=1;rf_wa=1;rf_wd={rf_factor[63:28],dv_q[9:0],lf};
            end
        end
    end
    always_ff @(posedge clk2)if(middle)es_fast_birth_pending<=0;
        else if(rst)es_fast_birth_pending<=0;
        else if(xs==X_IDLE&&hi_valid)begin
            es_fast_birth_pending<=1;es_fast_birth_factor<={hi_r26,hi_yf,hi_lf};
        end
    always_ff @(posedge clk)begin
        dv_start<=0;
        if(rst)begin xs<=X_IDLE;busy<=0;pf_st<=0;pf_ok<=0;end
        else begin
            case(xs)
            X_IDLE:if(hi_valid)begin
                busy<=1;mw<=0;dv_mode<=0;
                xmaj<=hi_xmaj;lin<=hi_lin;yf_pend<=hi_pending;
                l_wbuf<=hi_wbuf;l_aa<=hi_aa;l_toon<=hi_toon;b_idx<=hi_idx;
                if(PFE&&pf_st==0&&pf_ok&&pf_have==hi_idx)begin
                    current_slot<=load_slot;pf_ok<=0;xs<=X_Z;
                end else xs<=X_BW;
            end
            X_BW:if(pf_st==0)begin
                pf_ok<=0;
                if(pf_ok&&pf_have==b_idx)begin current_slot<=load_slot;xs<=X_Z;end
                else begin ld_idx<=b_idx;load_slot<=!current_slot;xs<=X_BL0;end
            end
            X_BL0:xs<=VREG?X_BLW:X_BL1;
            X_BLW:xs<=X_BL1;
            X_BL1:xs<=X_BL2;
            X_BL2:begin current_slot<=load_slot;xs<=X_Z;end
            X_Z:begin
                ma<=27'(difference);mb<=27'(less?lf:18'h20000-lf);
                if(l_wbuf)xs<=X_YF;
                else if(ylen==0||equal_)begin z<=z0;xs<=X_YF;end
                else xs<=X_Z3;
            end
            X_Z3:if(!mw)mw<=1;
                else begin mw<=0;z<=24'(sum_);xs<=X_YF;end
            X_YF:if(yf_go)begin
                yf_pend<=0;dv_mode<=0;cov_pend<=l_aa&&xmaj;
                if(l_aa&&xmaj)begin dv_start<=1;dv_num<=32'({ylen,10'b0});dv_den<=25'(xlen);end
                k<=lin?4'd1:4'd0;c_v<=0;c2_v<=0;
                if(lin)w<=w0;
                xs<=X_IP;
            end
            X_IP:begin
                c2_lsh<=c_lsh;c2_tb<=c_tb;c2_v<=c_v;c2_k<=c_k;
                c2_direct<=c_direct;c2_base<=c_base;c_v<=0;
                if(issue)begin
                    ma<=27'(difference);mb<=27'(factor);
                    c_v<=1;c_k<=k;c_lsh<=item_linear;
                    c_tb<=DS_TEXRND&&item_linear&&(k==4||k==5);
                    c_direct<=ylen==0||equal_;
                    c_base<=ylen==0||equal_?a:minimum;k<=next_k;
                end else if(!c_v)xs<=X_FIN;
            end
            X_FIN:if(!cov_pend||dv_idle)begin
                if(cov_pend)xcovinc<=dv_q;
                cov_pend<=0;busy<=0;xs<=X_IDLE;
            end
            default:xs<=X_IDLE;
            endcase
            case(pf_st)
            0:if((xs==X_IDLE||xs==X_FIN||(xs==X_IP&&(!issue||
                    (PFE&&k>=((l_toon&&!TOONR)?(l_wbuf?5:4):(l_wbuf?4:3))))))&&
                    pfi_v&&!(pf_ok&&pf_have==pfi_idx))begin
                ld_idx<=pfi_idx;load_slot<=!current_slot;pf_ok<=0;pf_st<=1;
            end
            1:pf_st<=VREG?2:3;
            2:pf_st<=3;
            3:pf_st<=4;
            default:begin pf_ok<=1;pf_have<=ld_idx;pf_st<=0;end
            endcase
        end
        if(it_we)case(it_k)
            0:w<=value_[15:0];6:z<=value_[23:0];7:rt<=value_[8:0];
            1:av[0]<=it_v;2:av[1]<=it_v;3:av[2]<=it_v;4:av[3]<=it_v;default:av[4]<=it_v;
        endcase
`ifndef SYNTHESIS
        if(!rst&&issue&&(!snap_valid||snap_slot!=current_slot||snap_item!=k))
            $fatal(1,"EDGE_SPAN_ITEM_SNAPSHOT_OWNER");
        if(!rst&&hi_valid&&xs==X_IDLE&&hi_need_lf)
            $fatal(1,"EDGE_SPAN_PROFILE_REQUIRES_LINZ_LIN17");
`endif
    end
endmodule

// Two vertex pairs with an explicit current/prefetch owner. The original
// prefetch events write full records; streaming reads never revisit a
// polygon bank already released by stage1. One FAST read port is reserved
// for current A at E and current B at M. Only an inactive slot may be written.
module gpu3d_es_vertex_snapshot (
    input logic clk,clk2,rst,
    input logic we,write_slot,write_side,req,read_slot,toon_red,
    input logic [3:0] item,
    input logic [115:0] wdata,
    output logic [24:0] a,b,
    output logic valid,slot_out,
    output logic [3:0] item_out
);
    logic epoch=1'b0,seen=1'b0;
    wire middle=epoch!=seen;
    always_ff @(posedge clk)epoch<=!epoch;
    always_ff @(posedge clk2)seen<=epoch;
    logic held_slot,held_toon,held_req=1'b0,held_epoch=1'b0,a_epoch=1'b1;
    logic [3:0] held_item;
    always_ff @(posedge clk)begin
        held_req<=req&&!rst;held_slot<=read_slot;held_item<=item;
        held_toon<=toon_red;held_epoch<=!held_epoch;
    end
    function automatic [24:0] select_item(input logic[115:0]v,input logic[3:0]k,input logic tr);
        logic signed[16:0]value_;
        begin
            value_=0;
            case(k)
                4'd0:select_item=25'(v[56:41]);
                4'd6:select_item=25'(v[40:17]);
                4'd7:select_item=25'(v[65:57]&9'h1f0);
                default:begin
                    case(k)
                        4'd1:value_=17'(tr?(v[65:57]&9'h1f0):v[65:57]);
                        4'd2:value_=17'(v[74:66]);
                        4'd3:value_=17'(v[83:75]);
                        4'd4:value_={v[99],v[99:84]};
                        default:value_={v[115],v[115:100]};
                    endcase
                    select_item=25'($signed(value_));
                end
            endcase
        end
    endfunction
    logic [115:0] q;
    // E captures the next item/owner. M reads and holds A; after M the
    // same read port presents B live until the following E consumer.
    // Only a 25-bit scalar is retained, not another full vertex pair.
    gpu3d_lram #(.W(116),.AW(2))u_records(.clk,.we,
        .waddr({write_slot,write_side}),.wdata,
        .raddr({held_slot,!middle}),.rdata(q));
    always_ff @(posedge clk2)if(middle)begin
        a<=select_item(q,held_item,held_toon);a_epoch<=held_epoch;
    end
    assign b=select_item(q,held_item,held_toon);
    assign valid=held_req&&a_epoch==held_epoch&&!middle;
    assign slot_out=held_slot;assign item_out=held_item;
`ifndef ALTERA_RESERVED_QIS
    always @(posedge clk)if(!rst&&we&&held_req&&write_slot==held_slot)
        $fatal(1,"EDGE_SPAN_SNAPSHOT_WRITES_LIVE_OWNER");
`endif
endmodule

// Two independent contexts, two read replicas per owner, one 64-bit write
// per owner and FAST edge. Bank birth and reset/abort ownership are
// controlled by the two independent issue calendars in the frontend.
module gpu3d_es_context (
    input logic clk2,
    input logic [1:0] we,
    input logic [1:0][4:0] wa,ra,rb,
    input logic [1:0][63:0] wd,
    output logic [1:0][63:0] qa,qb
);
    genvar owner;
    generate for(owner=0;owner<2;owner=owner+1)begin:g_owner
        gpu3d_lram #(.W(64),.AW(5))u_a(.clk(clk2),.we(we[owner]),
            .waddr(wa[owner]),.wdata(wd[owner]),.raddr(ra[owner]),.rdata(qa[owner]));
        gpu3d_lram #(.W(64),.AW(5))u_b(.clk(clk2),.we(we[owner]),
            .waddr(wa[owner]),.wdata(wd[owner]),.raddr(rb[owner]),.rdata(qb[owner]));
    end endgenerate
endmodule
