// nds_video against an earlier revision: DS lines with random pixels, random SDRAM acks, each side's own read
// answers (four words a request, a word of its address); every output compared every clock, the request fields
// while their request is up.
module tb_video_eq #(parameter int SEED = 1, parameter int FRAMES = 6);
    logic clk = 1'b0; always #5 clk = !clk;
    logic rst = 1'b1, vid_t = 1'b0;
    logic px_valid = 1'b0, px_eng = 1'b0, line_start = 1'b0, swap = 1'b0, touch = 1'b0, pen = 1'b0;
    logic [1:0] layout_in = 2'd0, rotation = 2'd0;
    logic [7:0] px_line = 8'd0, px_x = 8'd0, cur_x = 8'd100, cur_y = 8'd80;
    logic [17:0] px_rgb = 18'd0;
    logic [8:0] vcount = 9'd0;
    logic wa_o = 1'b0, wa_n = 1'b0, ra_o = 1'b0, ra_n = 1'b0, rv_o = 1'b0, rv_n = 1'b0;
    logic [31:0] rd_o = 32'd0, rd_n = 32'd0;
    wire wr_o, wr_n, rr_o, rr_n, de_o, de_n, hs_o, hs_n, vs_o, vs_n, fp_o, fp_n;
    wire [23:0] wad_o, wad_n, rad_o, rad_n, rgb_o, rgb_n;
    wire [31:0] wd_o, wd_n;
    wire [1:0] lay_o, lay_n;
    old_nds_video u_old (.clk, .reset(rst), .vid_t, .layout_in, .rotation, .touch, .pen, .cur_x, .cur_y, .px_valid, .px_eng, .px_line, .px_x, .px_rgb,
        .line_start, .vcount, .swap, .frame_pulse(fp_o), .w_req(wr_o), .w_addr(wad_o), .w_data(wd_o), .w_ack(wa_o),
        .r_req(rr_o), .r_addr(rad_o), .r_ack(ra_o), .r_rvalid(rv_o), .r_rdata(rd_o), .underruns(), .layout(lay_o), .rgb(rgb_o), .de(de_o), .hs(hs_o), .vs(vs_o));
    nds_video u_new (.clk, .reset(rst), .vid_t, .layout_in, .rotation, .touch, .pen, .cur_x, .cur_y, .px_valid, .px_eng, .px_line, .px_x, .px_rgb,
        .line_start, .vcount, .swap, .frame_pulse(fp_n), .w_req(wr_n), .w_addr(wad_n), .w_data(wd_n), .w_ack(wa_n),
        .r_req(rr_n), .r_addr(rad_n), .r_ack(ra_n), .r_rvalid(rv_n), .r_rdata(rd_n), .underruns(), .layout(lay_n), .rgb(rgb_n), .de(de_n), .hs(hs_n), .vs(vs_n));
    int unsigned rng = 32'(SEED) * 2654435761 + 7;
    function automatic int unsigned rnd();
        rng = rng ^ (rng << 13); rng = rng ^ (rng >> 17); rng = rng ^ (rng << 5);
        return rng;
    endfunction
    int cyc = 0, hc = 0, vc = 262, errs = 0, frames = 0, wreqs = 0, rreqs = 0;
    int rw_o = -1, rw_n = -1;       // read words left to answer
    logic [23:0] ra_ao = 0, ra_an = 0;
    always @(posedge clk) vid_t <= (cyc % 3) != 0;
    always @(posedge clk) begin
        cyc++;
        if (cyc == 20) rst <= 1'b0;
        // the DS's line timing, the pixels of a line in its HBlank
        line_start <= 1'b0;
        hc = hc == 4259 ? 0 : hc + 1;
        if (hc == 0) begin
            vc = vc == 262 ? 0 : vc + 1;
            if (vc == 0) begin
                frames++;
                if (frames == FRAMES) begin
                    $display("%s frames %0d wreqs %0d rreqs %0d errs %0d", errs == 0 && wreqs > 100 && rreqs > 100 ? "PASS" : "FAIL", frames, wreqs, rreqs, errs);
                    $finish;
                end
                swap <= rnd() % 8 == 0;
                touch <= rnd() % 2 == 0; pen <= rnd() % 2 == 0;
                layout_in <= rnd() % 4 == 0 ? 2'(rnd() % 3) : 2'd0;
            end
            line_start <= 1'b1; vcount <= 9'(vc);
        end
        px_valid <= 1'b0;
        if (vc >= 1 && vc <= 192 && hc >= 16 && hc < 16 + 1024) begin
            px_valid <= (hc & 1) == 0; px_eng <= (hc >> 1) & 1;
            px_x <= 8'(((hc - 16) >> 2)); px_line <= 8'(vc - 1); px_rgb <= 18'(rnd());
        end
        // the SDRAM sides: same accept pattern, each side's data its own address
        wa_o <= wr_o && !wa_o && rnd() % 4 == 0 ? 1'b1 : 1'b0;
        wa_n <= wr_n && !wa_n ? (wr_o && !wa_o ? wa_o : 1'b0) : 1'b0;
        wa_o <= 1'b0; wa_n <= 1'b0;
        begin
            automatic logic take = rnd() % 3 == 0;
            if (wr_o && !wa_o && take) wa_o <= 1'b1;
            if (wr_n && !wa_n && take) wa_n <= 1'b1;
            take = rnd() % 3 == 0;
            ra_o <= 1'b0; ra_n <= 1'b0; rv_o <= 1'b0; rv_n <= 1'b0;
            if (rr_o && !ra_o && take && rw_o < 0) begin ra_o <= 1'b1; rw_o = 3; ra_ao = rad_o; end
            if (rr_n && !ra_n && take && rw_n < 0) begin ra_n <= 1'b1; rw_n = 3; ra_an = rad_n; end
            if (rw_o >= 0 && !ra_o) begin rv_o <= 1'b1; rd_o <= {8'd0, ra_ao} + 32'(3 - rw_o); rw_o--; end
            if (rw_n >= 0 && !ra_n) begin rv_n <= 1'b1; rd_n <= {8'd0, ra_an} + 32'(3 - rw_n); rw_n--; end
        end
        if (wa_o) wreqs++;
        if (ra_o) rreqs++;
        if (!rst && cyc > 30 && ({wr_o, rr_o, de_o, hs_o, vs_o, fp_o, lay_o} !== {wr_n, rr_n, de_n, hs_n, vs_n, fp_n, lay_n} || rgb_o !== rgb_n ||
            (wr_o && {wad_o, wd_o} !== {wad_n, wd_n}) || (rr_o && rad_o !== rad_n))) begin
            if (errs < 6) $display("clk %0d: w %b %b %h %h %h %h r %b %b %h %h rgb %h %h", cyc, wr_o, wr_n, wad_o, wad_n, wd_o, wd_n, rr_o, rr_n, rad_o, rad_n, rgb_o, rgb_n);
            errs++;
        end
    end
endmodule
