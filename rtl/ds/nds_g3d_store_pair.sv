// Bounded external-journal/cache prototype. Original list traversal is retained.
module nds_g3d_store_pair #(
    parameter int SL = 11,               // log2 pool slots
    parameter bit READ_DONE = 0,         // SDRAM validates the eight-word record before publication
    parameter bit FULL_WQ = 1,          // reference: queue a complete DS frame before physical writes finish
    parameter bit BANK_META = 1,        // independent geometry/render Y and order ownership
    parameter int CL = 13,             // log2 pool vertex chunks
    // 1: the write queue is filled from geom's output words as they are written (po_w*), so geom's
    // 128-bit po_data register is not needed; 0: from po_data at the push (the first version)
    parameter bit WORDS = 1'b1,
    // 0: ps_data is the RAM data itself (the vertex lanes hold it while a vertex beat waits; cycle-identical);
    // 1: a 128-bit beat register (the first version)
    parameter bit PSREG = 1'b1,
    // WORDS: 1 puts the write queue's lanes in M10K (a registered read at wq_rp, every clock) instead of MLAB
    // (#867: the 4-entry queue took ~113 ALMs of MLAB, ~11 LABs, for 161 bits x 4); the writer reads wh only from
    // the clock after p_busy rises, which comes at least a clock after the entry's last write and after wq_rp moves
    parameter bit WQ_M10K = 1'b1,
    // WQ_M10K: 1 puts the four lanes in one M10K, a word per {lane, entry}: the writer sends one 32-bit word a
    // clock, so the block is read every clock at the word the writer sends next ({lane of wk', wq_rp'}, the
    // registers' next values): 5 -> 2 blocks (docs/phase2-integration.md "Double-pumped RAMs")
    parameter bit WQ_PACK = 1'b1
) (
    input  logic         clk,
    input  logic         rst,
    // geometry engine
    input  logic         po_valid,
    output logic         po_ready,
    input  logic         po_type,
    input  logic [127:0] po_data,
    input  logic [10:0]  po_index,
    input  logic         po_wv,          // geom writes word po_wk of the next record
    input  logic [1:0]   po_wk,
    input  logic [31:0]  po_wd,
    input  logic         so_we,
    input  logic [10:0]  so_pos,
    input  logic [10:0]  so_idx,
    input  logic         so_done,
    input  logic [11:0]  so_count,
    // rasterizer
    output logic         drawing,        // a frame is drawn from the on-chip lists (f_live): a swap's sort output must wait
    input  logic         frame_go,       // a frame starts (line 0 next)
    input  logic         abort,          // the raster restarts unfinished (the clock before its frame_go): this frame stops
    // diagnostics (docs/diag.md): {loader beat, loader granted, loader waiting for the PSRAM grant,
    // fetcher waiting for the loader}
    output logic [3:0]   diag_ld,
    input  logic         ps_line_req,
    input  logic [7:0]   ps_line_y,
    input  logic [8:0]   y_lim,          // the last line it may stream now (3D ring)
    output logic         ps_valid,
    input  logic         ps_ready,
    output logic [1:0]   ps_type,
    output logic [127:0] ps_data,
    // PSRAM: request held until ack; a read returns 4 words (rvalid)
    output logic         p_req,
    output logic         p_we,
    output logic [22:2]  p_addr,
    output logic [31:0]  p_wdata,
    input  logic         p_ack,
    input  logic         p_rvalid,
    input  logic         p_rdone,
    input  logic [31:0]  p_rdata,
    output logic jw_req,
    output logic [23:0] jw_addr,
    output logic [31:0] jw_data,
    input logic jw_ack, jw_drained,
    output logic jr_req,
    output logic [23:0] jr_addr,
    input logic jr_ack,jr_valid,
    input logic [31:0] jr_data
);
    logic wb, building;
    logic [14:0] wq_n,publish_left,publication,committed_tail;
    logic [12:0] next_vertex;
    logic early_stall;
    logic w_req,w_last,w_ack;
    logic [22:2] w_addr;
    logic [31:0] w_data;
    wire po_go=po_valid && po_ready;
    nds_g3d_journal u_journal (
        .clk,.rst,.po_valid,.po_type,.po_index,.po_wv,.po_wk,.po_wd,.so_done,.po_ready,.wb,
        .queued(wq_n),.publish_left,.publication,.committed_tail,.next_vertex,
        .wr_req(w_req),.wr_last(w_last),.wr_addr(w_addr),.wr_data(w_data),.wr_ack(w_ack),
        .jw_req,.jw_addr,.jw_data,.jw_ack,.jw_drained,.jr_req,.jr_addr,.jr_ack,.jr_valid,.jr_data,.early_stall);
    logic [14:0] bank_gen [2];
    logic draw_bank;
    logic [14:0] draw_gen;
    always_ff @(posedge clk) begin
        if(rst)begin bank_gen[0]<='0;bank_gen[1]<='0;draw_bank<=1'b1;draw_gen<='0;end
        else begin
            if(so_done)bank_gen[wb]<=committed_tail+15'(po_go);
            if(frame_go)begin
                draw_bank<=so_done?wb:rb;
                draw_gen<=so_done?committed_tail+15'(po_go):bank_gen[rb];
            end
        end
    end
    logic f_live,f_dead,f_clr,f_clr_go;
    logic [127:0] ps_data_r;
    logic h_fhit,v_fhit;
    logic [127:0] h_fdata,v_fdata,h_ldata,v_ldata;
    logic h_lreq,v_lreq,h_ltake,v_ltake,h_lvalid,v_lvalid,h_lhit,v_lhit;
    logic h_mreq,v_mreq,h_mack,v_mack,h_mvalid,v_mvalid;
    logic [22:2] h_maddr,v_maddr;
    // A producer commit owns a journal version; it has not overwritten the
    // canonical bank yet. Invalidate only when that physical overwrite starts.
    // An unfinished old line keeps its canonical bank and cached generation.
    wire canonical_begin=w_req && w_ack && w_addr[3:2]==2'd0;
    wire [12:0] canonical_index=w_addr[16:4];
    wire canonical_vertex=canonical_index>=13'd2048;
    wire [12:0] invalid_id=canonical_vertex?canonical_index-13'd2048:canonical_index;
    nds_g3d_pair_cache #(.SET_BITS(7),.ID_BITS(11),.VERTEX(0)) u_headers (
        .clk,.rst,.cancel(abort),.f_req(fst==F_SH && !fquiet),.f_bank(draw_bank),.f_id({2'd0,f_slot}),.f_gen(draw_gen),
        .f_hit(h_fhit),.f_data(h_fdata),.l_req(h_lreq),.l_bank(rb),.l_id({2'd0,lidx}),.l_gen(bank_gen[rb]),
        .l_take(h_ltake),.l_valid(h_lvalid),.l_hit(h_lhit),.l_data(h_ldata),
        .inv_valid(canonical_begin && !canonical_vertex),.inv_bank(w_addr[20]),.inv_id(invalid_id),
        .m_req(h_mreq),.m_addr(h_maddr),.m_ack(h_mack),.m_valid(h_mvalid),.m_done(p_busy && owner==P_HEADER && read_complete),.m_data(p_rdata));
    nds_g3d_pair_cache #(.SET_BITS(9),.ID_BITS(13),.VERTEX(1)) u_vertices (
        .clk,.rst,.cancel(abort),.f_req(fst==F_VRD && !fquiet),.f_bank(draw_bank),.f_id(f_c),.f_gen(draw_gen),
        .f_hit(v_fhit),.f_data(v_fdata),.l_req(v_lreq),.l_bank(rb),.l_id(lv),.l_gen(bank_gen[rb]),
        .l_take(v_ltake),.l_valid(v_lvalid),.l_hit(v_lhit),.l_data(v_ldata),
        .inv_valid(canonical_begin && canonical_vertex),.inv_bank(w_addr[20]),.inv_id(invalid_id),
        .m_req(v_mreq),.m_addr(v_maddr),.m_ack(v_mack),.m_valid(v_mvalid),.m_done(p_busy && owner==P_VERTEX && read_complete),.m_data(p_rdata));
    typedef enum logic [1:0] {P_WRITE,P_HEADER,P_VERTEX} owner_t;
    owner_t owner;
    logic p_busy,p_own_l,p_lastw,read_vertex;
    logic [1:0] port_beat;
    wire read_complete=READ_DONE?p_rdone:p_rvalid && port_beat==2'd3;
    wire any_read=h_mreq || v_mreq;
    wire old_line_owns_bank=fst!=F_IDLE && !fquiet && w_addr[20]==draw_bank;
    wire write_admit=w_req && !old_line_owns_bank;
    wire pick_vertex=v_mreq && (!h_mreq || !read_vertex);
    assign p_own_l=owner!=P_WRITE;
    assign p_req=p_busy && (owner==P_WRITE?w_req:owner==P_HEADER?h_mreq:v_mreq);
    assign p_we=owner==P_WRITE;
    assign p_addr=owner==P_WRITE?w_addr:owner==P_HEADER?h_maddr:v_maddr;
    assign p_wdata=w_data;
    assign w_ack=p_busy && owner==P_WRITE && p_ack;
    assign h_mack=p_busy && owner==P_HEADER && p_ack;
    assign v_mack=p_busy && owner==P_VERTEX && p_ack;
    assign h_mvalid=p_busy && owner==P_HEADER && p_rvalid;
    assign v_mvalid=p_busy && owner==P_VERTEX && p_rvalid;
    always_ff @(posedge clk) begin
        if(rst)begin p_busy<=1'b0;owner<=P_WRITE;p_lastw<=1'b0;port_beat<='0;read_vertex<=1'b0;end
        else if(!p_busy)begin
            if(write_admit && !(any_read && p_lastw))begin p_busy<=1'b1;owner<=P_WRITE;p_lastw<=1'b1;end
            else if(any_read)begin
                p_busy<=1'b1;owner<=pick_vertex?P_VERTEX:P_HEADER;p_lastw<=1'b0;
                port_beat<='0;read_vertex<=pick_vertex;
            end
        end else if(owner==P_WRITE)begin
            if(w_ack && w_last)p_busy<=1'b0;
        end else begin
            if(p_rvalid)port_beat<=port_beat+2'd1;
            if(read_complete)p_busy<=1'b0;
        end
    end
    // Y table, render order
    logic [10:0] yt_ra, or_ra, or_q;
    logic [16:0] yt_q;
    localparam int MAW = BANK_META ? 12 : 11;
    logic rb;                          // bank being drawn
    wire [MAW-1:0] yt_wa = MAW'({wb, po_index});
    wire [MAW-1:0] or_wa = MAW'({wb, so_pos});
    wire [MAW-1:0] yt_addr = MAW'({rb, yt_ra});
    wire [MAW-1:0] or_addr = MAW'({rb, or_ra});
    // the header's Y bits (107, 96:89, 104:97): WORDS takes them from the words as written
    logic [6:0]  yw2;                    // word 2 bits 31:25 (header bits 95:89)
    logic [11:0] yw3;                    // word 3 bits 11:0 (header bits 107:96)
    always_ff @(posedge clk) if (po_wv) begin
        if (po_wk == 2'd2) yw2 <= po_wd[31:25];
        if (po_wk == 2'd3) yw3 <= po_wd[11:0];
    end
    wire  [107:89] yh = WORDS ? {yw3, yw2} : po_data[107:89];
    gpu3d_ram #(.W(17), .AW(MAW)) u_ytab (.clk, .we(po_go && !po_type), .waddr(yt_wa),
        .wdata({yh[107], yh[96:89], yh[104:97]}), .raddr(yt_addr), .rdata(yt_q));
    gpu3d_ram #(.W(11), .AW(MAW)) u_ord (.clk, .we(so_we), .waddr(or_wa), .wdata(so_idx), .raddr(or_addr), .rdata(or_q));

    // ================================================================ arrival lists
    // bucket per line {tag, head, tail}; link per position: the next one.
    // One copy for the build and the loader, one for the fetcher.
    logic        tag;
    logic        bk_we, lk_we;
    logic [7:0]  bk_wa, bk_ra, bkf_ra;
    logic [22:0] bk_wd, bk_q, bkf_q;
    logic [10:0] lk_wa, lk_wd, lk_ra, lk_q, lkf_ra, lkf_q;
    gpu3d_ram #(.W(23), .AW(8))  u_bk  (.clk, .we(bk_we), .waddr(bk_wa), .wdata(bk_wd), .raddr(bk_ra),  .rdata(bk_q));
    gpu3d_ram #(.W(23), .AW(8))  u_bkf (.clk, .we(bk_we), .waddr(bk_wa), .wdata(bk_wd), .raddr(bkf_ra), .rdata(bkf_q));
    // the links in one true dual-port RAM: port A the build's writes and the loader's reads (the loader
    // waits for ready, so it never reads while the build writes; checked below), port B the fetcher
    gpu3d_tdp #(.W(11), .AW(11)) u_lk (.clk, .a_addr(lk_we ? lk_wa : lk_ra), .a_we(lk_we), .a_d(lk_wd), .a_q(lk_q),
                                       .b_addr(lkf_ra), .b_q(lkf_q));
    // position -> slot (the loader writes it, the fetcher reads it)
    logic        sp_we;
    logic [10:0] sp_wa, sp_ra;
    logic [SL-1:0] sp_wd, sp_q;
    gpu3d_ram #(.W(SL), .AW(11)) u_sp (.clk, .we(sp_we), .waddr(sp_wa), .wdata(sp_wd), .raddr(sp_ra), .rdata(sp_q));

    logic [11:0] rcount;
    logic        ready;                  // lists built, the bank's records in PSRAM
    typedef enum logic [2:0] { B_IDLE, B_CLR, B_DRAIN, B_ORD, B_YT, B_BK, B_LINK } bst_t;
    bst_t        bst;
    logic [11:0] bpos;
    wire  [7:0]  b_ytop = yt_q[15:8];
    wire         b_take = bst == B_LINK && !yt_q[16] && b_ytop < 8'd192;
    always_ff @(posedge clk) begin
        if (rst) begin
            bst <= B_IDLE; building <= 1'b0; tag <= 1'b0; ready <= 1'b0; rb <= 1'b1; rcount <= 12'd0;
        end else case (bst)
            B_IDLE: if (so_done) begin
                building <= 1'b1; ready <= 1'b0; rb <= wb; rcount <= so_count; tag <= !tag; bpos <= 12'd0;
                bst <= B_CLR;
            end
            // every bucket starts empty: a bucket this frame doesn't write
            // would otherwise keep a tag that matches every second frame
            B_CLR: begin
                bpos <= bpos + 12'd1;
                if (bpos == 12'd191) begin bpos <= 12'd0; bst <= B_DRAIN; end
            end
            B_DRAIN: if (BANK_META ? publish_left == 0 : wq_n == 3'd0 && !(p_busy && !p_own_l)) begin
                if (rcount == 12'd0) begin building <= 1'b0; ready <= 1'b1; bst <= B_IDLE; end
                else bst <= B_ORD;
            end
            B_ORD: bst <= B_YT;                          // order[bpos]
            B_YT:  bst <= B_BK;                          // ytab[index]
            B_BK:  bst <= B_LINK;                        // bucket[ytop]
            default: begin                               // B_LINK: bpos joins its line
                bpos <= bpos + 12'd1;
                if (bpos + 12'd1 == rcount) begin building <= 1'b0; ready <= 1'b1; bst <= B_IDLE; end
                else bst <= B_ORD;
            end
        endcase
    end
    always_comb begin
        bk_we = b_take; bk_wa = b_ytop; lk_we = 1'b0; lk_wa = bk_q[10:0]; lk_wd = bpos[10:0];
        bk_wd = {tag, bpos[10:0], bpos[10:0]};
        if (b_take && bk_q[22] == tag) begin bk_wd = {tag, bk_q[21:11], bpos[10:0]}; lk_we = 1'b1; end
        if (bst == B_CLR) begin bk_we = 1'b1; bk_wa = bpos[7:0]; bk_wd = {!tag, 22'd0}; end
    end

    // Original arrival traversal; slots now carry the immutable original ID.
    // No full-depth payload/free-list copy remains behind the working cache.
    typedef enum logic [3:0] {L_IDLE,L_LINE,L_LINE2,L_POS,L_POS2,L_HREQ,L_HDAT,L_ROOM,
                             L_VREQ,L_VDAT,L_SLOT,L_LINK,L_DONE} lst_t;
    lst_t lst;
    logic [8:0] ly;
    logic lgo,l_drawn,l_re;
    logic [10:0] lpos,ltail,lidx;
    logic [3:0] lnv,lk;
    logic [12:0] lv;
    wire l_through=lgo && lst==L_IDLE;
    wire l_req=h_lreq || v_lreq;
    wire l_ack=(h_lvalid && h_lhit)||(v_lvalid && v_lhit);
    wire l_beat=h_mvalid || v_mvalid;
    assign h_lreq=lst==L_HREQ;
    assign v_lreq=lst==L_VREQ;
    always_ff @(posedge clk) begin
        if(rst || so_done)begin l_drawn<=1'b0;l_re<=1'b0;end
        else begin
            if(frame_go)begin l_drawn<=1'b1;if(l_drawn)l_re<=1'b1;end
            if(l_re && (lst==L_IDLE || lst==L_LINE || lst==L_DONE))l_re<=1'b0;
        end
    end
    always_ff @(posedge clk) begin
        sp_we<=1'b0;
        if(rst || so_done)begin lst<=L_IDLE;ly<=9'd192;lgo<=1'b0;end
        else if(l_re && (lst==L_IDLE || lst==L_LINE || lst==L_DONE))begin lst<=L_IDLE;ly<=9'd192;lgo<=1'b0;end
        else case(lst)
            L_IDLE:if(ready && !lgo && !f_clr)begin lgo<=1'b1;ly<='0;lst<=L_LINE;end
            L_LINE:lst<=L_LINE2;
            L_LINE2:if(bk_q[22]==tag)begin lpos<=bk_q[21:11];ltail<=bk_q[10:0];lst<=L_POS;end else lst<=L_DONE;
            L_POS:lst<=L_POS2;
            L_POS2:begin lidx<=or_q;lst<=L_HREQ;end
            L_HREQ:if(h_ltake)lst<=L_HDAT;
            L_HDAT:if(h_lvalid)begin
                if(h_lhit)begin lv<=h_ldata[127:115];lnv<=h_ldata[80:77];lst<=L_ROOM;end
                else lst<=L_HREQ;
            end
            L_ROOM:begin lk<='0;lst<=L_VREQ;end
            L_VREQ:if(v_ltake)lst<=L_VDAT;
            L_VDAT:if(v_lvalid)begin
                if(v_lhit)begin
                    lk<=lk+4'd1;lv<=lv+13'd1;lst<=lk+4'd1==lnv?L_SLOT:L_VREQ;
                end else lst<=L_VREQ;
            end
            L_SLOT:begin sp_we<=1'b1;sp_wa<=lpos;sp_wd<=lidx;lst<=L_LINK;end
            L_LINK:if(lpos==ltail)lst<=L_DONE;else begin lpos<=lk_q;lst<=L_POS;end
            default:if(ly==9'd191)begin ly<=9'd192;lst<=L_IDLE;end
                    else begin ly<=ly+9'd1;lst<=L_LINE;end
        endcase
    end
    // ================================================================ fetcher
    typedef enum logic [3:0] { F_IDLE, F_WAIT, F_HEADS, F_HEADS2, F_PICK, F_SP, F_SH, F_HDR,
                               F_VRD, F_VOUT, F_ADV, F_ADV2, F_END } fst_t;
    fst_t          fst;
    logic [7:0]    fy;
    assign diag_ld = {l_beat, l_ack, l_req && !l_ack, fst == F_WAIT && {1'b0, fy} <= y_lim};
    assign f_clr_go = f_clr && fst == F_IDLE && lst == L_IDLE;   // the loader holds no slot or chunk
    logic          fquiet;               // draining a frame's leftovers: nothing sent
    logic          fa;                   // the active list read this line
    logic [SL:0]   fa_n, fb_n, fa_i;
    logic          al_we;
    logic [SL:0]   al_wa, al_ra;
    logic [14+SL:0] al_wd, al_q;         // {position, slot}
    gpu3d_ram #(.W(15 + SL), .AW(SL + 1)) u_al (.clk, .we(al_we), .waddr(al_wa), .wdata(al_wd), .raddr(al_ra), .rdata(al_q));
    logic          ha_v, hr_v;           // heads valid: active list, arrivals
    logic [10:0]   hr_p, hr_t;           // arrival head and the line's last arrival
    logic          f_arr;
    logic [10:0]   f_pos;
    logic [SL-1:0] f_slot;
    logic [3:0]    f_k, f_nv;
    logic [CL-1:0] f_c;
    logic          f_keep;
    logic          rq_v;                 // a line asked for, not yet started
    logic [7:0]    rq_y;
    wire           out_free = !ps_valid || ps_ready;
    always_ff @(posedge clk) begin
        if (rst) begin f_live <= 1'b0; f_dead <= 1'b0; f_clr <= 1'b0; end
        else begin
            if (frame_go) begin f_live <= 1'b1; f_dead <= 1'b0; end
            else if (fst == F_END && !fquiet && out_free && fy == 8'd191) f_live <= 1'b0;
            if (((!BANK_META && so_we) || so_done) && f_live && !frame_go) begin f_live <= 1'b0; f_dead <= 1'b1; end
            if (so_done && (f_dead || f_live)) f_clr <= 1'b1;
            else if (f_clr_go) f_clr <= 1'b0;
            // the raster restarts on a frame the store still draws (the DS starts every frame at line 215):
            // its slots and chunks come back as for an abandoned frame, once the loader is back at a state that
            // holds none (the next frame_go redraws the same bank: l_re). An abandoned frame (f_dead) already
            // has its clear from so_done, and the loader may hold the next bank's slots by now
            if (abort && f_live && !so_done) begin f_live <= 1'b0; f_clr <= 1'b1; end
        end
    end
`ifndef ALTERA_RESERVED_QIS
    int ab_n = 0;           // abandoned frames (the first ones are logged)
    always_ff @(posedge clk)
        if (!rst && ((!BANK_META && so_we) || so_done) && f_live && !frame_go) begin
            ab_n <= ab_n + 1;
            if (ab_n < 20) $display("g3d store: frame abandoned at the next swap (line %0d, %0d so far)", fy, ab_n + 1);
        end
    always_ff @(posedge clk)
        if (!rst && abort && (f_live || f_dead))
            $display("g3d store: frame aborted by the raster's restart (line %0d, %s)", fy, f_live ? "drawing" : "abandoned");
`endif
    wire  [10:0]   ha_p = al_q[10+SL:SL];
    wire  [SL-1:0] ha_s = al_q[SL-1:0];
    wire [3:0] ha_nv=al_q[14+SL:11+SL];
    always_comb begin
        // read addresses
        yt_ra  = or_q;
        // the build reads order[bpos] in B_ORD and needs it on the port
        // until B_BK, where it addresses the Y-table read that B_LINK uses
        // (the loader, the other user, never runs while the lists build)
        or_ra  = (bst == B_ORD || bst == B_YT || bst == B_BK || bst == B_LINK) ? bpos[10:0] : lpos;
        bk_ra  = (bst == B_BK || bst == B_LINK) ? b_ytop : ly[7:0];
        lk_ra  = lpos;
        bkf_ra = fy;
        lkf_ra = hr_p;
        sp_ra  = hr_p;
        al_ra  = {fa, fa_i[SL-1:0]};
    end
    assign ps_data = ps_data_r;
    wire [127:0] sh_q=h_fdata;
    wire [115:0] ch_q=v_fdata[115:0];
    wire  [7:0]    f_ybot = sh_q[104:97];
    always_ff @(posedge clk) begin
        al_we <= 1'b0;
        if (ps_valid && ps_ready) ps_valid <= 1'b0;
        if (ps_line_req) begin rq_v <= 1'b1; rq_y <= ps_line_y; end
        if (rst || abort && (f_live || f_dead)) begin
            // abort: the stopped frame's beat, line request and lists go; its slots come back by f_clr
            fst <= F_IDLE; fa <= 1'b0; fa_n <= '0; fb_n <= '0; ps_valid <= 1'b0; fquiet <= 1'b0; rq_v <= 1'b0;
            ha_v <= 1'b0; hr_v <= 1'b0;
        end else case (fst)
            F_IDLE: begin
                if (f_clr) begin fa_n <= '0; fb_n <= '0; end        // the abandoned frame's lists go (f_clr_go)
                else if (frame_go && fa_n != '0) begin fquiet <= 1'b1; fst <= F_HEADS; fa_i <= '0; hr_v <= 1'b0; end
                else if (rq_v && !ps_line_req) begin fy <= rq_y; rq_v <= 1'b0; fquiet <= 1'b0; fst <= f_dead ? F_END : F_WAIT; end
            end
            F_WAIT: begin
                // the line's arrivals loaded and the 3D ring has room
                if (!l_re && (!ready || (lgo && (l_through || ly > {1'b0, fy}) && {1'b0, fy} <= y_lim))) begin
                    fa_i <= '0; fst <= F_HEADS;
                end
            end
            F_HEADS: fst <= F_HEADS2;                                // active head, bucket[fy]
            F_HEADS2: begin
                ha_v <= fa_i < fa_n;
                if (!fquiet) begin
                    hr_v <= ready && lgo && bkf_q[22] == tag;
                    hr_p <= bkf_q[21:11]; hr_t <= bkf_q[10:0];
                end
                fst <= F_PICK;
            end
            F_PICK: begin
                if (!ha_v && !hr_v) fst <= F_END;
                else if (ha_v && (!hr_v || ha_p < hr_p)) begin
                    f_arr <= 1'b0; f_pos <= ha_p; f_slot <= ha_s; f_nv<=ha_nv; fst <= F_SH;
                end else begin
                    f_arr <= 1'b1; f_pos <= hr_p; fst <= F_SP;      // pos -> slot
                end
            end
            F_SP: begin f_slot <= sp_q; fst <= F_SH; end
            F_SH: fst <= F_HDR;                                      // slot header
            F_HDR: if (!fquiet && !h_fhit) fst<=F_SH;
            else if (out_free || fquiet) begin
                if (!fquiet) begin ps_valid <= 1'b1; ps_type <= 2'd0; if (PSREG) ps_data_r <= {21'd0, sh_q[106:0]}; end
                f_k <= fquiet?f_nv:sh_q[80:77]; f_c <= sh_q[127:128-CL];
                if(!fquiet) f_nv<=sh_q[80:77];
                f_keep <= !fquiet && {1'b0, fy} + 9'd1 < {1'b0, f_ybot};
                fst <= F_VRD;
            end
            F_VRD: fst <= F_VOUT;                                    // chunk and its link
            F_VOUT: if (!fquiet && !v_fhit) fst<=F_VRD;
            else if (out_free || fquiet) begin
                if (!fquiet) begin ps_valid <= 1'b1; ps_type <= 2'd1; if (PSREG) ps_data_r <= {12'd0, ch_q}; end
                f_c <= f_c+CL'(1); f_k <= f_k - 4'd1;
                fst <= f_k == 4'd1 ? F_ADV : F_VRD;
            end
            F_ADV: begin
                if (f_keep) begin al_we <= 1'b1; al_wa <= {!fa, fb_n[SL-1:0]}; al_wd <= {f_nv, f_pos, f_slot}; fb_n <= fb_n + 1'b1; end
                if (!f_arr) begin fa_i <= fa_i + 1'b1; fst <= F_ADV2; end
                else if (hr_p == hr_t) begin hr_v <= 1'b0; fst <= F_PICK; end
                else fst <= F_ADV2;                                  // link[hr_p]
            end
            F_ADV2: begin
                if (f_arr) begin hr_p <= lkf_q; fst <= F_PICK; end
                else begin ha_v <= fa_i < fa_n; fst <= F_PICK; end   // the next active entry is read
            end
            default: begin                                           // F_END
                if (fquiet) begin
                    fa <= !fa; fa_n <= '0; fb_n <= '0; fquiet <= 1'b0; fst <= F_IDLE;
                end else if (out_free) begin
                    ps_valid <= 1'b1; ps_type <= 2'd3;
                    fa <= !fa; fa_n <= fb_n; fb_n <= '0; fst <= F_IDLE;
                end
            end
        endcase
    end

`ifndef ALTERA_RESERVED_QIS
    always_ff @(posedge clk) if(!rst)begin
        if(SL!=11 || CL!=13 || !BANK_META || !FULL_WQ || !PSREG || !WORDS)
            $fatal(1,"pair prototype requires full capacities and held output");
        if(early_stall)$fatal(1,"PAIR_EARLY_INGRESS_STALL logical %0d",wq_n);
        if(!fquiet && fst==F_HDR && h_fhit && out_free &&
           (fy<sh_q[96:89] || fy>sh_q[104:97] || sh_q[80:77]<3 || sh_q[80:77]>10))
            $fatal(1,"pair: header/list identity differs");
    end
`endif
endmodule
