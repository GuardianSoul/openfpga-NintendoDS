// Experimental bounded ring service. Selected explicitly; legacy stays default.
// Three independently tagged read slots; one physical write/read port, an
// eight-word return skid, and independent posted-write/read-block cursors.
module nds_g3d_ring_deadline #(
    parameter int LEAD = 46,
    parameter int YLAG = 0,
    parameter bit LLR = 0,
    parameter int LC_AT = 3600,
    parameter bit TR3 = 0,
    parameter int RH_AT = 0,
    parameter logic [23:0] BASEW = 24'h080000
) (
    input logic clk, rst, frame_go,
    input logic l3d_go, l3d_done,
    input logic [7:0] l3d_line, l3d_raddr,
    output logic [22:0] l3d_rdata,
    output logic [8:0] y_lim,
    output logic l3d_have,
    output logic [3:0] st_busy,
    input logic [8:0] r_go,
    input logic [7:0] fp_line,
    input logic fp_act,
    output logic ll_rd,
    output logic [1:0] ll_slot,
    output logic [7:0] ll_x,
    input logic ll_ack,
    input logic [22:0] ll_q,
    input logic px_valid,
    input logic [7:0] px_x, px_y,
    input logic [22:0] px_color,
    output logic rg_wreq,
    output logic [23:0] rg_waddr,
    output logic [31:0] rg_wdata,
    input logic rg_wack,
    output logic rg_rreq, rg_hurry,
    output logic [23:0] rg_raddr,
    input logic rg_rack, rg_rvalid,
    input logic [31:0] rg_rdata,
    input logic [6:0] rg_wfill, rg_wpcnt,
    input logic due_valid,
    input logic [7:0] due_line,
    input logic [13:0] due_sys
);
    typedef enum logic [2:0] { EMPTY, READ_BUILD, DIRECT_BUILD, COPY_BUILD, FULL, PARTIAL } slot_state_t;
    slot_state_t state [3];
    logic [7:0] row [3];
    logic [5:0] next_block [3];
    logic [2:0] slot_epoch;
    logic epoch;
    logic [7:0] dline;
    logic d_on, go_q;
    logic [1:0] consumer;
    logic consumer_valid;
    wire [7:0] need = d_on ? dline + 8'd1 : 8'd0;

    logic [3:0] st_full, st_pres;
    logic [7:0] st_y [4];
    logic [8:0] posted, ordered;
    wire [8:0] lead_lim = {1'b0,dline} + 9'(LEAD);
    assign y_lim = lead_lim < posted + 9'(3 + YLAG) ? lead_lim : posted + 9'(3 + YLAG);

    // One pending row ticket suffices: 256 accepted words separate row ends,
    // while at most65 words are unpopped (64 stored plus the prefetched head).
    // The first row-end MUST pass before the next row-end can be accepted.
    logic ticket_valid;
    logic [6:0] ticket;
    logic [7:0] ticket_row;
    wire [6:0] ticket_rem = ticket - rg_wpcnt;
    wire ticket_done = ticket_rem == 0 || ticket_rem[6:5] == 2'b11;

    logic w_active, w_drop;
    logic [7:0] w_row, w_x, w_next;
    logic [22:0] stage_q;
    logic [9:0] stage_ra;
    logic cp_active, cp_late, cp_pv;
    logic [1:0] cp_slot, cp_src;
    logic [7:0] cp_row, cp_px;
    logic [8:0] cp_x;
    wire fp_wait = fp_act && st_full[fp_line[1:0]];
    logic [8:0] fp_done;
    logic fp_act_q;
    logic [11:0] lc_count;

    typedef enum logic [1:0] { R_IDLE, R_REQ, R_DATA, R_DRAIN } read_state_t;
    read_state_t rs;
    logic [1:0] r_slot;
    logic [7:0] r_row;
    logic [4:0] r_block;
    logic [2:0] r_in;
    logic [3:0] r_written;
    logic r_drop;
    (* ramstyle = "logic" *) logic [22:0] skid [8];
    logic [2:0] skid_wp, skid_rp;
    logic [3:0] skid_count;
    wire read_busy = rs != R_IDLE;

    logic direct_active;
    logic [1:0] direct_slot;

    logic hit, hit_full;
    logic [1:0] hit_slot;
    logic free_valid;
    logic [1:0] free_slot;
    logic target_valid, target_stage, target_read, target_late;
    logic [7:0] target;
    logic [1:0] target_slot;
    logic pending_valid;
    logic [1:0] pending_slot;
    logic direct_start;
    logic [1:0] direct_pick;

    function automatic [1:0] m3(input logic [7:0] v);
        logic [3:0] a;
        a = 4'(v[7:6]) + 4'(v[5:4]) + 4'(v[3:2]) + 4'(v[1:0]);
        a = 4'(a[3:2]) + 4'(a[1:0]);
        return a >= 3 ? 2'(a - 4'd3) : a[1:0];
    endfunction

    // Slot lookup is independent of parity. A frame can retire a builder
    // without releasing an old live consumer or its accepted read block.
    always_comb begin
        hit = 0; hit_full = 0; hit_slot = 0;
        free_valid = 0; free_slot = 0;
        for (int i = 2; i >= 0; i--) begin
            if (slot_epoch[i] == epoch && row[i] == l3d_line &&
                (state[i] == FULL || state[i] == PARTIAL)) begin
                hit = 1; hit_full = state[i] == FULL; hit_slot = 2'(i);
            end
            if (!(consumer_valid && consumer == 2'(i)) &&
                !(read_busy && r_slot == 2'(i)) &&
                !(cp_active && cp_slot == 2'(i)) &&
                !(direct_active && direct_slot == 2'(i)) &&
                (state[i] == EMPTY || slot_epoch[i] != epoch || row[i] < need)) begin
                free_valid = 1; free_slot = 2'(i);
            end
        end
    end
    assign l3d_have = hit;

    // A direct row gets its descriptor on the first pixel, including x0.
    always_comb begin
        logic already;
        already = 0;
        for (int i = 0; i < 3; i++)
            if (state[i] != EMPTY && slot_epoch[i] == epoch && row[i] == px_y)
                already = 1;
        direct_pick = free_slot;
        direct_start = px_valid && px_x == 0 && free_valid && !already &&
                       (px_y == need || (need < 191 && px_y == need + 8'd1)) &&
                       !rst && !frame_go && !l3d_go && !go_q;
    end
    wire direct_we = px_valid && !rst && !frame_go && (px_x == 0 ? direct_start : direct_active);
    wire [1:0] direct_dest = px_x == 0 ? direct_pick : direct_slot;

    // Nearest unfinished row first. PARTIAL can be upgraded before it is
    // pinned, but never by a second simultaneous producer of that same row.
    always_comb begin
        logic exists, complete, partial;
        logic [1:0] partial_slot;
        logic [7:0] candidate;
        logic staged, readable, late_ok;
        logic hint_second;
        hint_second = due_valid && need < 191 && due_line == need + 8'd1;
        target_valid = 0; target_stage = 0; target_read = 0; target_late = 0;
        target = need; target_slot = free_slot;
        for (int n = 1; n >= 0; n--) begin
            // A queued skipped-line job is nearer than an unqueued numeric
            // predecessor. Hints change priority, never which bytes are valid.
            candidate = need + 8'(hint_second ? (1-n) : n);
            exists = 0; complete = 0; partial = 0; partial_slot = 0;
            for (int i = 0; i < 3; i++) if (slot_epoch[i] == epoch && row[i] == candidate && state[i] != EMPTY) begin
                if (state[i] == PARTIAL && !(consumer_valid && consumer == 2'(i))) begin
                    partial = 1; partial_slot = 2'(i);
                end else exists = 1;
                if (state[i] == FULL) complete = 1;
            end
            staged = st_pres[candidate[1:0]] && st_y[candidate[1:0]] == candidate;
            readable = {1'b0,candidate} < ordered;
            late_ok = LLR && n == 0 && lc_count >= 12'(LC_AT) &&
                      {1'b0,candidate} < r_go && {1'b0,candidate} + (TR3 ? 9'd3 : 9'd4) >= r_go &&
                      {1'b0,candidate} >= fp_done &&
                      (!fp_act || {1'b0,fp_line} + 9'd1 < {1'b0,candidate}) && !fp_wait;
            if (candidate < 192 && !exists && !complete &&
                (free_valid || partial) && (staged || readable || (late_ok && !partial))) begin
                target_valid = 1; target = candidate; target_slot = partial ? partial_slot : free_slot;
                target_stage = staged && !w_active && !fp_wait;
                target_read = readable && !target_stage;
                target_late = !staged && !readable && late_ok;
            end
        end
        pending_valid = 0; pending_slot = 0;
        for (int i = 2; i >= 0; i--)
            if (state[i] == READ_BUILD && slot_epoch[i] == epoch && row[i] >= need &&
                (!pending_valid ||
                 (due_valid && row[i] == due_line && row[pending_slot] != due_line) ||
                 (!(due_valid && row[pending_slot] == due_line && row[i] != due_line) &&
                  row[i] <= row[pending_slot]))) begin
                pending_valid = 1; pending_slot = 2'(i);
            end
    end

    wire allocate = target_valid && !read_busy && !cp_active && !direct_start &&
                    !rst && !frame_go && !l3d_go && !go_q;
    wire copy_start = allocate && (target_stage || target_late) && !w_active && !fp_wait &&
                      !(target_stage && px_valid && px_x == 0 && px_y[1:0] == target[1:0]);
    wire write_start = !w_active && !cp_active && !copy_start &&
                       st_full[posted[1:0]] && !rst && !frame_go;
    // No source may change the staging read address under a held writer.
    always_comb begin
        stage_ra = {w_row[1:0],w_x};
        if (write_start) stage_ra = {posted[1:0],w_next};
        else if (w_active && rg_wack) stage_ra = {w_row[1:0],w_x + 8'd1};
        else if (copy_start && target_stage) stage_ra = {target[1:0],8'd0};
        else if (cp_active && !cp_late) stage_ra = {cp_src,cp_x[7:0]};
    end
    gpu3d_ram #(.W(23), .AW(10)) u_stage (.clk, .we(px_valid && !rst),
        .waddr({px_y[1:0],px_x}), .wdata(px_color), .raddr(stage_ra), .rdata(stage_q));
    assign rg_wreq = w_active && !rst;
    assign rg_waddr = BASEW + {8'd0,w_row,w_x};
    assign rg_wdata = {9'd0,stage_q};
    assign st_busy = st_full | ((w_active && w_drop) ? (4'b0001 << w_row[1:0]) : 4'b0000);

    assign rg_rreq = rs == R_REQ && !rst;
    assign rg_raddr = BASEW + {8'd0,r_row,r_block,3'd0};
    wire [11:0] read_budget = (12'd32 - {6'd0,next_block[r_slot]}) * 12'd64 + 12'd64;
    assign rg_hurry = !rst && read_busy && !r_drop &&
                      ((due_valid && due_line == r_row && due_sys <= {2'd0,read_budget}) ||
                       (d_on && r_row == need && (RH_AT == 0 || lc_count >= 12'(RH_AT))));

    wire copy_abort = cp_active && (frame_go || direct_we || fp_wait ||
                      (px_valid && px_x == 0 && px_y[1:0] == cp_src && !cp_late) ||
                      (cp_late && ({1'b0,cp_row} + (TR3 ? 9'd3 : 9'd4) < r_go ||
                                   {1'b0,cp_row} < fp_done ||
                                   (fp_act && {1'b0,fp_line} <= {1'b0,cp_row} &&
                                    {1'b0,fp_line} + 9'd1 >= {1'b0,cp_row}))));
    assign ll_rd = cp_active && cp_late && !cp_x[8] && !copy_abort && !rst;
    assign ll_slot = cp_src;
    assign ll_x = cp_x[7:0];
    wire copy_we = cp_active && cp_pv && !copy_abort && !rst;
    wire skid_push = rs == R_DATA && rg_rvalid && !r_drop && !frame_go && !rst;
    wire skid_pop = skid_count != 0 && !direct_we && !frame_go && !rst;
    wire rb_we = direct_we || skid_pop || copy_we;
    wire [9:0] rb_addr = direct_we ? {direct_dest,px_x} :
                              skid_pop ? {r_slot,r_block,r_written[2:0]} : {cp_slot,cp_px};
    wire [22:0] rb_data = direct_we ? px_color : skid_pop ? skid[skid_rp] : cp_late ? ll_q : stage_q;
    wire [1:0] display_slot = go_q && hit ? hit_slot : consumer;
    gpu3d_ram #(.W(23), .AW(10), .STYLE("M10K")) u_rbuf (.clk, .we(rb_we), .waddr(rb_addr), .wdata(rb_data),
        .raddr({display_slot,l3d_raddr}), .rdata(l3d_rdata));

    always_ff @(posedge clk) begin
        go_q <= !rst && l3d_go;
        fp_act_q <= fp_act;
        if (rst) begin
            epoch <= 0; d_on <= 0; dline <= 0; consumer <= 0; consumer_valid <= 0;
            st_full <= 0; st_pres <= 0; posted <= 0; ordered <= 0;
            ticket_valid <= 0; ticket <= 0; ticket_row <= 0;
            w_active <= 0; w_drop <= 0; w_row <= 0; w_x <= 0; w_next <= 0;
            cp_active <= 0; cp_late <= 0; cp_pv <= 0; cp_slot <= 0; cp_src <= 0; cp_row <= 0; cp_px <= 0; cp_x <= 0;
            fp_done <= 0; lc_count <= 0;
            rs <= R_IDLE; r_slot <= 0; r_row <= 0; r_block <= 0; r_in <= 0; r_written <= 0; r_drop <= 0;
            skid_wp <= 0; skid_rp <= 0; skid_count <= 0;
            direct_active <= 0; direct_slot <= 0; slot_epoch <= 0;
            for (int i = 0; i < 3; i++) begin state[i] <= EMPTY; row[i] <= 0; next_block[i] <= 0; end
            for (int i = 0; i < 4; i++) st_y[i] <= 0;
        end else begin
            if (l3d_go) lc_count <= 0;
            else if (lc_count != 12'hfff) lc_count <= lc_count + 12'd1;
            if (fp_act_q && !fp_act) fp_done <= {1'b0,fp_line} + 9'd1;
            if (l3d_done) consumer_valid <= 0;
            if (go_q) begin
                dline <= l3d_line; d_on <= 1;
                consumer <= hit_slot; consumer_valid <= hit;
            end

            if (ticket_valid && ticket_done) begin
                ordered <= {1'b0,ticket_row} + 9'd1;
                ticket_valid <= 0;
            end
            if (write_start) begin
                w_active <= 1; w_drop <= 0; w_row <= st_y[posted[1:0]]; w_x <= w_next;
            end
            if (rg_wreq && rg_wack) begin
                w_x <= w_x + 8'd1;
                if (&w_x[2:0]) begin
                    w_active <= 0;
                    if (w_drop) begin w_drop <= 0; w_next <= 0; end
                    else begin
                        w_next <= w_x + 8'd1;
                        if (&w_x) begin
                            st_full[w_row[1:0]] <= 0;
                            posted <= {1'b0,w_row} + 9'd1;
                            ticket_valid <= 1; ticket <= rg_wpcnt + rg_wfill + 7'd1; ticket_row <= w_row;
                        end
                    end
                end
            end
            if (px_valid && px_x == 0) st_pres[px_y[1:0]] <= 0;
            if (px_valid && px_x == 255) begin
                st_full[px_y[1:0]] <= 1; st_pres[px_y[1:0]] <= 1; st_y[px_y[1:0]] <= px_y;
            end

            if (direct_start) begin
                direct_active <= 1; direct_slot <= direct_pick;
                state[direct_pick] <= DIRECT_BUILD; row[direct_pick] <= px_y;
                slot_epoch[direct_pick] <= epoch; next_block[direct_pick] <= 0;
            end
            if (direct_we && px_x == 255) begin
                state[direct_dest] <= FULL; direct_active <= 0;
            end

            if (allocate && target_read) begin
                state[target_slot] <= READ_BUILD; row[target_slot] <= target;
                slot_epoch[target_slot] <= epoch; next_block[target_slot] <= 0;
            end
            if (copy_start) begin
                cp_active <= 1; cp_late <= target_late; cp_slot <= target_slot;
                cp_src <= target_late && TR3 ? m3(target) : target[1:0]; cp_row <= target;
                state[target_slot] <= COPY_BUILD; row[target_slot] <= target;
                slot_epoch[target_slot] <= epoch; next_block[target_slot] <= 0;
                cp_x <= target_stage ? 9'd1 : 9'd0; cp_pv <= target_stage; cp_px <= 0;
            end else if (cp_active) begin
                cp_pv <= cp_late ? ll_ack : !cp_x[8];
                if ((cp_late && ll_ack) || (!cp_late && !cp_x[8])) begin
                    cp_px <= cp_x[7:0]; cp_x <= cp_x + 9'd1;
                end
                if (copy_we && cp_px == 255) begin
                    if (cp_late) state[cp_slot] <= PARTIAL;
                    else state[cp_slot] <= FULL;
                    cp_active <= 0; cp_pv <= 0;
                end
                if (copy_abort) begin state[cp_slot] <= EMPTY; cp_active <= 0; cp_pv <= 0; end
            end

            if (skid_push) begin skid[skid_wp] <= rg_rdata[22:0]; skid_wp <= skid_wp + 3'd1; end
            if (skid_pop) begin
                skid_rp <= skid_rp + 3'd1; r_written <= r_written + 4'd1;
                if (r_written == 7) begin
                    next_block[r_slot] <= {1'b0,r_block} + 6'd1;
                    if (r_block == 31) state[r_slot] <= FULL;
                    rs <= R_IDLE;
                end
            end
            case ({skid_push,skid_pop})
                2'b10: skid_count <= skid_count + 4'd1;
                2'b01: skid_count <= skid_count - 4'd1;
                default: ;
            endcase
            case (rs)
                R_IDLE: if (pending_valid && !cp_active && !copy_start && !frame_go && !l3d_go && !go_q) begin
                    r_slot <= pending_slot; r_row <= row[pending_slot]; r_block <= next_block[pending_slot][4:0];
                    r_in <= 0; r_written <= 0; r_drop <= 0; skid_wp <= 0; skid_rp <= 0; rs <= R_REQ;
                end
                R_REQ: if (rg_rack) begin rs <= R_DATA; r_in <= 0; end
                R_DATA: if (rg_rvalid) begin
                    r_in <= r_in + 3'd1;
                    if (&r_in) begin
                        if (r_drop) begin rs <= R_IDLE; r_drop <= 0; end
                        else rs <= R_DRAIN;
                    end
                end
                default: ;
            endcase
            if (frame_go) begin
                epoch <= !epoch; d_on <= 0; dline <= 0;
                st_full <= 0; st_pres <= 0; posted <= 0; ordered <= 0; ticket_valid <= 0;
                w_next <= 0; direct_active <= 0; cp_active <= 0; cp_pv <= 0; fp_done <= 0;
                for (int i = 0; i < 3; i++) state[i] <= EMPTY;
                // Keep the old consumer lease until its actual final sample.
                // Its RAM contents stay pinned even though its tag is invalid.
                if (w_active) begin
                    if (rg_wack && (&w_x[2:0])) begin w_active <= 0; w_drop <= 0; end
                    else w_drop <= 1;
                end
                skid_count <= 0; skid_wp <= 0; skid_rp <= 0;
                if (rs == R_REQ || (rs == R_DATA && !(rg_rvalid && (&r_in)))) r_drop <= 1;
                else begin rs <= R_IDLE; r_drop <= 0; end
            end
        end
    end

`ifndef SYNTHESIS
    // synthesis translate_off
`ifdef G3D_RING_DEADLINE_OBSERVE
    // Passive names for the game word-provenance oracle. These describe
    // three physical slots and actual commit sources, never a legacy parity.
    wire [2:0] rb_v, rb_p;
    wire [7:0] rb_y [3];
    genvar obs_slot;
    generate for (obs_slot=0; obs_slot<3; obs_slot=obs_slot+1) begin : g_obs_slot
        assign rb_v[obs_slot] = slot_epoch[obs_slot] == epoch &&
                               (state[obs_slot] == FULL || state[obs_slot] == PARTIAL);
        assign rb_p[obs_slot] = state[obs_slot] == PARTIAL;
        assign rb_y[obs_slot] = row[obs_slot];
    end endgenerate
    wire rb_we_px = direct_we;
    wire cp_we = copy_we && !cp_late;
    wire lc_we = copy_we && cp_late;
    wire [7:0] lc_y = cp_row;
    wire [7:0] cp_y = cp_row;
    wire [9:0] sr_a = {w_row[1:0],w_x};
    wire owner_valid = consumer_valid;
`endif
    always_ff @(posedge clk) if (!rst) begin
        if (rg_wack && rg_wreq && (&w_x) && !w_drop && !frame_go && ticket_valid && !ticket_done)
            $error("deadline ring: previous row-end ticket still pending");
        if (ticket_valid && ticket_rem > 65 && ticket_rem < 96)
            $error("deadline ring: ticket outside FIFO outstanding bound");
        if (skid_push && skid_count == 8 && !skid_pop) $error("deadline ring: return skid overflow");
        if (rb_we && rb_addr[9:8] == 3) $error("deadline ring: unused slot written");
        if (rb_we && consumer_valid && rb_addr[9:8] == consumer && !l3d_done)
            $error("deadline ring: live consumer overwritten");
        if (l3d_go && consumer_valid && !l3d_done) $error("deadline ring: new job before consumer release");
        if (px_valid && px_x == 0 && st_busy[px_y[1:0]]) $error("deadline ring: full staging slot overwritten");
        if (cp_active && w_active) $error("deadline ring: staging reader collision");
        if (copy_we && skid_pop) $error("deadline ring: copy/return write collision");
        if (rs == R_IDLE && skid_count != 0) $error("deadline ring: skid without block owner");
    end
    // synthesis translate_on
`endif
endmodule
