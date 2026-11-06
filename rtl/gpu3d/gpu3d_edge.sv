// One polygon edge at line y: SetupPolygon{Left,Right}Edge + Slope::Setup,
// and the edge's Interpolator<1> applied to W, Z, colour and texture
// coordinates (melonDS GPU3D_Soft.{h,cpp}). gpu3d_raster runs one unit
// twice per polygon: left slope (side 0), then right slope (side 1).
//
// One 27x27 multiplier (operands registered, product used the next cycle),
// the reciprocal ROM for (1<<18)/ylen and (1<<22)/ylen, and a 2-bit/clock
// divider for the perspective factor and the AA coverage step. About 24
// cycles per edge (27 on the linear path).
module gpu3d_edge #(
    // DS_LIN17 (gpu3d_raster): linear edges interpolate with the factor
    // floor((ix << 17) / ylen) (one division per edge and line) on the item
    // path, instead of melonDS's exact division per item (X_IL)
    parameter bit DS_LIN17 = 1,
    // DS_LINZ (gpu3d_raster): Z along the edge (Z-buffer) is the same 17-bit
    // factor on the full difference; the factor then comes from a reciprocal
    // table, (ix * ceil(2^37/ylen)) >> 20, for every edge (no division)
    parameter bit DS_LINZ = 1,
    // DS_YPERSP (gpu3d_raster): along Y the linear mode needs w bits 0-5
    // clear (not 1-6) and the perspective factor uses the full w (not halved)
    parameter bit DS_YPERSP = 1,
    // DS_TEXRND (gpu3d_raster): linear texcoords (items 4, 5) round with
    // + 2^13 before the >> 17, i.e. a carry when bits 16:13 are all set
    parameter bit DS_TEXRND = 1,
    // EXT_LROM: the ceil(2^37/ylen) table is read through lr_addr / lr_qx
    // (port b of the front's shared gpu3d_lrecip2) instead of an own copy
    parameter bit EXT_LROM = 0,
    // EXT_ROM: the (1<<26)/n table is read through rom_addr / rom_qx (port b
    // of the front's shared gpu3d_recip2) instead of an own copy
    parameter bit EXT_ROM = 0,
    // VREG: the vertex RAM's output registered (one clock more per edge setup,
    // X_LW): the path from its read through rom_addr to dx (nds-fit #589)
    parameter bit VREG = 0,
    // STAGE (gpu3d_front EP2): 0 the whole unit; 1 its first part only
    // (the walk to the slope and the perspective factor's division, X_IDLE ..
    // X_H), handing the edge over (ho_*) when the second part is free (ho_ready);
    // 2 the second part only (Z, the factor, the items, coverage: X_Z ..
    // X_FIN), taking the edge (hi_*). Two copies run two edges at once
    parameter int STAGE = 0,
    parameter int HW = 432,           // the handover's width (gpu3d_front: EW)
    // TOONR (gpu3d_raster): on a toon polygon (toon), item 1 (red) is the red
    // without the vertex colours' 0xF fill, and there is no item 7 (rt)
    parameter bit TOONR = 0
) (
    input  logic         clk,
    input  logic         rst,
    output logic [7:0]   lr_addr,      // EXT_LROM: the table address (ylen), read registered
    output logic [8:0]   rom_ao,       // EXT_ROM: the (1<<26)/n table address, read registered
    input  logic [26:0]  rom_qx,
    input  logic [37:0]  lr_qx,
    // vertex records of both polygon banks, written by the input stage
    input  logic         vm_we,
    input  logic [4:0]   vm_waddr,
    input  logic [115:0] vm_wdata,
    // polygon to set up (bank of the input stage)
    input  logic         start,
    input  logic         side,         // 0 left slope, 1 right slope
    input  logic         bank,
    input  logic [7:0]   y,
    input  logic         wbuf,
    input  logic         aa,           // coverage step needed (DISP3DCNT AA)
    input  logic         facing,
    input  logic         dummy,        // single-line polygon: vertex dv only
    input  logic         toon,         // DS_TOON and a toon/highlight polygon: item 7 too
    input  logic [3:0]   nv, vtop, vbot, dv,
    // the divider, shared with the span stage (gpu3d_front owns it): ask
    // with dv_req, start once dv_gnt; dv_hold until the result is read
    output logic         dv_start,
    output logic [31:0]  dv_num,
    output logic [24:0]  dv_den,
    output logic         dv_req, dv_hold,
    output logic         dv_mode,      // 1: a wide quotient (the linear factor)
    input  logic         dv_gnt, dv_busy,
    input  logic [17:0]  dv_q,
    output logic [3:0]   vys_ra,       // vertex y table (MLAB in the input stage),
    input  logic [7:0]   vys_q,        // read combinationally at vys_ra
    output logic [3:0]   vys_ra_n,     // vys_ra as the next clock has it (a registered read's address)
    output logic         busy,
    // Slope state at y
    output logic [26:0]  inc,
    output logic         neg, xmaj,
    output logic signed [31:0] dx,
    output logic [9:0]   xval, xlen, xcovinc,
    output logic [7:0]   ylen,
    output logic [8:0]   vbx,          // x of the edge's lower vertex
    // interpolated at y
    output logic [15:0]  w,
    output logic [23:0]  z,
    output logic [4:0][16:0] av,       // r g b s t, signed
    output logic [8:0]   rt,           // red without the vertex colours' 0xF fill (toon index)
    // STAGE 1 -> 2: the edge's state at X_H's end
    output logic         ho_valid,
    input  logic         ho_ready,
    output logic [HW-1:0] ho,
    input  logic         hi_valid,
    input  logic [HW-1:0] hi,
    // STAGE 1 -> 2: the edge's vertices {bank, cur, nxt} once its walk is
    // done, which stage 2 reads from its own vertex RAM copy ahead (pfi_*)
    output logic [78:0]  ho_res,       // STAGE 1: {inc, neg, dx, xval, vbx} (gpu3d_front keeps them; stage 2 does not)
    output logic         pfo_v,
    output logic [8:0]   pfo_idx,
    // the item written this clock (k 1-5: av[k-1] = it_v)
    output logic         it_we,
    output logic [3:0]   it_k,
    output logic [16:0]  it_v,
    input  logic         pfi_v,
    input  logic [8:0]   pfi_idx
);
    function automatic [8:0]  v_x(input [115:0] v); v_x = v[8:0];     endfunction
    function automatic [7:0]  v_y(input [115:0] v); v_y = v[16:9];    endfunction
    function automatic [23:0] v_z(input [115:0] v); v_z = v[40:17];   endfunction
    function automatic [15:0] v_w(input [115:0] v); v_w = v[56:41];   endfunction
    // attribute k (0-2 colour, 3 s, 4 t) as a 17-bit signed value
    function automatic signed [16:0] v_a(input [115:0] v, input [2:0] k);
        case (k)
            3'd0: v_a = {8'b0, v[65:57]};
            3'd1: v_a = {8'b0, v[74:66]};
            3'd2: v_a = {8'b0, v[83:75]};
            3'd3: v_a = {v[99], v[99:84]};
            default: v_a = {v[115], v[115:100]};
        endcase
    endfunction
    function automatic [4:0] bitlen25(input [24:0] v);
        bitlen25 = 0;
        for (int i = 0; i < 25; i++) if (v[i]) bitlen25 = 5'(i + 1);
    endfunction
    function automatic [3:0] vstep(input [3:0] i, input plus, input [3:0] n);
        if (plus) vstep = (i + 4'd1 >= n) ? 4'd0 : i + 4'd1;
        else      vstep = (i == 0) ? n - 4'd1 : i - 4'd1;
    endfunction

    // vertex records (a copy per edge unit)
    logic [4:0]   vm_raddr;
    logic [115:0] vm_rdata;
    // M10K (nds-fit #441 had 8 free): an MLAB copy took 6 LABs
    logic [115:0] vm_ram, vm_q;
    gpu3d_ram #(.W(116), .AW(5), .STYLE("M10K")) u_vtx (
        .clk, .we(vm_we), .waddr(vm_waddr), .wdata(vm_wdata),
        .raddr(vm_raddr), .rdata(vm_ram));
    always_ff @(posedge clk) vm_q <= vm_ram;
    assign vm_rdata = VREG ? vm_q : vm_ram;

    logic [8:0]  rom_addr;            // ylen - 1, presented in X_L2
    logic [26:0] rom_q;
    assign rom_ao = rom_addr;
    generate
    if (EXT_ROM) begin : g_xrom
        assign rom_q = rom_qx;
    end else begin : g_rom
        gpu3d_recip u_rom (.clk, .addr(rom_addr), .q(rom_q));
    end
    endgenerate
    logic [37:0] lr_q;                // DS_LINZ: ceil(2^37/ylen), read from X_C on
    // ... registered (the multiply in X_E read the ROM output directly: nds-fit
    // #620); X_D's two clocks between X_C and X_E keep it the same value
    logic [37:0] lr_qr;
    always_ff @(posedge clk) lr_qr <= lr_q;
    assign lr_addr = ylen;
    generate
    if (EXT_LROM) begin : g_xlrom
        assign lr_q = lr_qx;
    end else begin : g_lrom
        gpu3d_lrecip u_lrom (.clk, .addr({2'b0, ylen}), .q(lr_q));
    end
    endgenerate

    logic [26:0] m_a, m_b;
    wire  [53:0] m_p = m_a * m_b;
    // States that add or compare on a product wait a cycle (mw) and use it
    // registered (m_pr), so no path runs multiplier -> adder -> register.
    logic [53:0] m_pr;
    logic        mw;


    typedef enum logic [4:0] {
        X_IDLE, X_WALK, X_L0, X_LW, X_L1, X_L2, X_C, X_D, X_E, X_F, X_G, X_H,
        X_Z, X_Z1, X_Z2, X_Z3, X_YF, X_IP, X_IL, X_FIN, X_HO,
        X_BW, X_BL0, X_BLW, X_BL1, X_BL2       // STAGE 2: its vertices (prefetch wait, reads)
    } xstate_t;
    xstate_t xs;
    // STAGE 1 never reaches X_Z .. X_IL, X_FIN or X_BW .. X_BL2, and STAGE 2
    // never reaches X_WALK .. X_H or X_HO: those case arms are gated off by
    // STAGE (if (STAGE != n)), so synthesis drops their datapath (the items,
    // Z, the walk and slope) from the half that never runs it

    logic       sd;                 // side, latched at start
    logic       sbank;              // STAGE 1: bank, latched at start
    // STAGE 2: the vertices it reads ({bank, cur, nxt}), ahead (pf_*) or at the start
    logic [8:0] ld_idx, b_idx, pf_have;
    logic [2:0] pf_st;
    logic       pf_ok;
    // STAGE 2: the polygon's flags as handed over (the inputs move on)
    logic       l_wbuf, l_aa, l_toon;
    wire        wbuf_e = STAGE == 2 ? l_wbuf : wbuf;
    wire        aa_e   = STAGE == 2 ? l_aa : aa;
    wire        toon_e = STAGE == 2 ? l_toon : toon;
    wire        plus = sd ? ~facing : facing;
    logic [3:0] cur, nxt;
    logic [115:0] va, vb;
    logic [9:0] t_xmin, t_xmax, ix;
    logic       xv_go;               // X_E done: xval is formed next cycle
    logic [9:0] ixp;                    // ix, formed in X_D (the factor's multiply starts from it)
    logic       sp;                 // inc is a special case (no multiply)
    logic       inc_sp1;            // the special inc: 0x40000 (else 0)
    logic       lin, need_yf, yf_pend;
    logic       need_lf, lf_pend;       // DS_LIN17: the linear factor still to divide / pending
    logic [17:0] lf;                    // DS_LIN17: floor((ix << 17) / ylen)
    logic [15:0] w0n, w0d, w1d;
    logic [31:0] t_num, t_den1;
    logic [9:0]  yf;
    logic [22:0] xrecip;
    logic [26:0] r26;
    logic [4:0]  zsh;
    logic [23:0] zdz;               // |z1 - z0|, normalised in X_Z1
    logic        cov_pend;
    // interpolation loop: item k issued this cycle, item k-1 collected
    logic [3:0]  k;
    logic        c_v, c_direct, c2_v, c2_direct, c_lsh;
    logic        c_tb, c2_tb, c2_lsh; // DS_TEXRND: a texcoord item; the item's shift, one stage on
    logic [3:0]  c_k, c2_k;
    logic [24:0] c_base, c2_base;
    logic [2:0]  lop;               // linear path: step within an attribute
    logic [24:0] l_p1;              // d * factor
    logic [16:0] l_q;               // its quotient estimate

    // item k along Y: 0 W, 1-5 r g b s t, 6 Z (W-buffer only), 7 red from
    // the vertex colours without their 0xF fill (toon polygons only, DS rule:
    // the DS takes the toon index from it)
    // item k's end values, registered with k (every assignment to k also
    // loads iab with sel_ab of the same value; va and vb are set before the
    // items): the item select is off the compare -> c_base path (nds-fit #646)
    logic signed [24:0] it_a, it_b;
    logic [49:0] iab;
    function automatic [49:0] sel_ab(input [3:0] kv);
        if (kv == 4'd0)      sel_ab = {25'(v_w(va)), 25'(v_w(vb))};
        else if (kv == 4'd6) sel_ab = {25'(v_z(va)), 25'(v_z(vb))};
        else if (kv == 4'd7 || (TOONR && kv == 4'd1 && toon_e)) sel_ab = {25'(v_a(va, 3'd0) & ~17'hF), 25'(v_a(vb, 3'd0) & ~17'hF)};
        else                 sel_ab = {25'(v_a(va, 3'(kv - 4'd1))), 25'(v_a(vb, 3'(kv - 4'd1)))};
    endfunction
    assign it_a = iab[49:25];
    assign it_b = iab[24:0];
    wire        it_lt   = it_a < it_b;
    wire [24:0] it_d    = it_lt ? 25'(it_b - it_a) : 25'(it_a - it_b);
    wire        it_lsh  = DS_LIN17 && lin && k != 4'd6;   // linear item: the 17-bit factor
    wire [17:0] it_pf   = it_lsh ? (it_lt ? lf : 18'h20000 - lf)
                                 : 18'(it_lt ? {1'b0, yf} : 11'd512 - {1'b0, yf});
    wire [9:0]  it_lf   = it_lt ? ix : 10'({2'b0, ylen} - ix);
    wire        it_dir  = (ylen == 0) || (it_a == it_b);

    // STAGE 1 -> 2 handover: {bank, cur, nxt (stage 2 reads the vertices),
    // ix, ylen, xlen, xmaj, lin, need_lf, yf_pend, yf, lf, xrecip, r26, inc,
    // neg, dx, xval, vbx, wbuf, aa, toon}
    localparam int HU = 9 + 10 + 8 + 10 + 1 + 1 + 1 + 1 + 10 + 18 + 23 + 27 + 27 + 1 + 32 + 10 + 9 + 3;
    assign ho = HW'({sbank, cur, nxt, ix, ylen, xlen, xmaj, lin, need_lf, yf_pend, yf, lf, xrecip, r26,
                     inc, neg, dx, xval, vbx, wbuf, aa, toon});
    assign ho_res  = {inc, neg, dx, xval, vbx};
    assign pfo_v   = STAGE == 1 && busy && xs != X_IDLE && xs != X_WALK;
    assign pfo_idx = {sbank, cur, nxt};
`ifndef SYNTHESIS
    initial if (STAGE != 0 && HW < HU) $error("gpu3d_edge: HW %0d < %0d", HW, HU);
`endif
    always_comb begin
        if (STAGE == 2) vm_raddr = {ld_idx[8], (pf_st == 3'd1 || xs == X_BL0) ? ld_idx[7:4] : ld_idx[3:0]};
        else            vm_raddr = {bank, (xs == X_L0) ? cur : nxt};
        rom_addr = 9'(v_y(vm_rdata) - v_y(va) - 8'd1);
    end
    wire dv_idle = !dv_busy && !dv_start;
    wire [31:0] h_den = t_den1 + m_pr[31:0];       // X_H's denominator
    assign dv_req  = (xs == X_H && mw && h_den != 0) || (xs == X_YF && ((aa_e && xmaj) || need_lf));
    assign dv_hold = yf_pend || cov_pend || dv_start;
    assign vys_ra = nxt;
    // nxt after this clock (the always_ff's two assignments: the start, the walk's step)
    always_comb begin
        vys_ra_n = nxt;
        if (!rst && STAGE != 2) begin
            if (xs == X_IDLE && start) vys_ra_n = dummy ? dv : vstep(vtop, side ? ~facing : facing, nv);
            else if (xs == X_WALK && !dummy && y >= vys_q && cur != vbot) vys_ra_n = vstep(nxt, plus, nv);
        end
    end

    // the interpolated item written this clock: item pk = pv (pw), also the
    // it_* outputs (gpu3d_front EP2 keeps r g b s t from them)
    logic        pw;
    logic [3:0]  pk;
    logic [24:0] pv;
    always_comb begin
        pw = 1'b0; pk = '0; pv = '0;
        if (!rst) case (xs)
        // item k-2 of X_IP: its product is m_pr (registered at the edge that
        // started this stage), shifted by 17 (linear) or 9
        X_IP: if (STAGE != 1 && c2_v) begin
            logic [24:0] p9;
            p9 = c2_lsh ? 25'(m_pr >> 17) : 25'(m_pr >> 9);
            pw = 1'b1; pk = c2_k;
            pv = c2_direct ? c2_base : 25'(c2_base + p9 + 25'(c2_tb && (&m_pr[16:13])));
        end
        X_IL: if (STAGE != 1 && mw) begin
            if (lop == 3'd3) begin
                logic [24:0] rr;
                logic [16:0] q;
                rr = l_p1 - m_pr[24:0];
                q = l_q + 17'(rr >= 25'(ylen));
                pw = 1'b1; pk = k; pv = c_direct ? c_base : 25'(c_base + 25'(q));
            end else if (lop >= 3'd4) begin
                pw = 1'b1; pk = 4'd6; pv = c_direct ? c_base : 25'(c_base + 25'(m_pr >> 9));
            end
        end
        default: ;
        endcase
    end
    assign it_we = pw;
    assign it_k  = pk;
    assign it_v  = pv[16:0];

    always_ff @(posedge clk) begin
        dv_start <= 1'b0;
        m_pr <= m_p;
        // the x at y (Slope's XVal), a cycle after X_E from its registered dx:
        // nothing reads xval before the edge is done, and dx, va, neg and the
        // limits hold until the next edge
        xv_go <= 1'b0;
        if (xv_go) begin
            logic signed [12:0] xv;
            xv = neg ? $signed({4'b0, v_x(va)}) - 13'(dx >>> 18)
                     : $signed({4'b0, v_x(va)}) + 13'(dx >>> 18);
            if (xv < $signed({3'b0, t_xmin}))      xval <= t_xmin;
            else if (xv > $signed({3'b0, t_xmax})) xval <= t_xmax;
            else                                   xval <= xv[9:0];
        end
        ho_valid <= 1'b0;
        if (rst) begin
            xs <= X_IDLE; busy <= 1'b0;
        end else case (xs)
        X_IDLE: if (STAGE == 2) begin
            if (hi_valid) begin
                busy <= 1'b1;
                mw <= 1'b0;
                dv_mode <= 1'b0;
                lf_pend <= 1'b0;
                // (inc, neg, dx, xval, vbx: gpu3d_front keeps them from ho_res)
                begin
                    logic [78:0] res_x;
                    {b_idx, ix, ylen, xlen, xmaj, lin, need_lf, yf_pend, yf, lf, xrecip, r26,
                     res_x, l_wbuf, l_aa, l_toon} <= HU'(hi);
                end
                xs <= X_BW;
            end
        end else if (start) begin
            busy <= 1'b1;
            mw <= 1'b0;
            dv_mode <= 1'b0;
            sd <= side;
            sbank <= bank;
            cur <= dummy ? dv : vtop;
            nxt <= dummy ? dv : vstep(vtop, side ? ~facing : facing, nv);
            xs <= X_WALK;
        end
        // STAGE 2: the vertices, read ahead (the prefetch, below) or now
        X_BW: if (STAGE != 1 && pf_st == 3'd0) begin
            pf_ok <= 1'b0;                       // (va, vb are this edge's from now)
            if (pf_ok && pf_have == b_idx) xs <= X_Z;
            else begin ld_idx <= b_idx; xs <= X_BL0; end
        end
        X_BL0: if (STAGE != 1) xs <= VREG ? X_BLW : X_BL1;
        X_BLW: if (STAGE != 1) xs <= X_BL1;
        X_BL1: if (STAGE != 1) begin va <= vm_rdata; xs <= X_BL2; end
        X_BL2: if (STAGE != 1) begin vb <= vm_rdata; xs <= X_Z; end
        X_WALK: if (STAGE != 2) begin
            if (!dummy && y >= vys_q && cur != vbot) begin
                cur <= nxt;
                nxt <= vstep(nxt, plus, nv);
            end else xs <= X_L0;
        end
        X_L0: if (STAGE != 2) xs <= VREG ? X_LW : X_L1;
        X_LW: if (STAGE != 2) xs <= X_L1;
        X_L1: if (STAGE != 2) begin va <= vm_rdata; xs <= X_L2; end
        X_L2: if (STAGE != 2) begin
            logic [8:0] x0, x1;
            logic [9:0] xmin, xmax, xl;
            logic [7:0] yl;
            vb <= vm_rdata;
            x0 = v_x(va); x1 = v_x(vm_rdata);
            if (x1 > x0)      begin xmin = {1'b0, x0}; xmax = {1'b0, x1} - 10'd1; neg <= 1'b0; end
            else if (x1 < x0) begin xmin = {1'b0, x1}; xmax = {1'b0, x0} - 10'd1; neg <= 1'b1; end
            else              begin xmin = {1'b0, x0}; xmax = {1'b0, x0};         neg <= 1'b0; end
            xl = xmax + 10'd1 - xmin;
            yl = v_y(vm_rdata) - v_y(va);
            t_xmin <= xmin; t_xmax <= xmax;
            xlen <= xl; ylen <= yl;
            vbx <= x1;
`ifndef SYNTHESIS
            if (v_y(vm_rdata) < v_y(va)) $error("gpu3d_edge: edge goes upward (non-monotone polygon)");
`endif
            xs <= X_C;
        end
        X_C: if (STAGE != 2) begin
            // the special cases: 0 (ylen 0) or 0x40000 (ylen == xlen != 1), from
            // the registered lengths (not the vertex RAM's output: nds-fit #466)
            sp <= ylen == 0 || ({2'b0, ylen} == xlen && xlen != 10'd1);
            inc_sp1 <= ylen != 0;
            // (1<<18)/ylen and (1<<22)/ylen from the table
            r26 <= rom_q;
            xrecip <= (ylen != 0 && !wbuf_e) ? 23'(rom_q >> 4) : 23'd0;
            m_a <= 27'((v_x(vb) > v_x(va)) ? v_x(vb) - v_x(va) : v_x(va) - v_x(vb));
            m_b <= 27'(rom_q >> 8);
            xs <= X_D;
        end
        X_D: if (STAGE != 2) begin
            logic [26:0] in;
            logic xm;
            if (!mw) mw <= 1'b1;
            else begin
                mw <= 1'b0;
                in = sp ? (inc_sp1 ? 27'h40000 : 27'd0) : m_pr[26:0];
                inc <= in;
                xm = in > 27'h40000;
                xmaj <= xm;
                m_a <= 27'(y - v_y(va));
                m_b <= in;
                ixp <= 10'(y - v_y(va)) + {9'b0, (in >= 27'h40000) && (sd ^ neg)};
                xs <= X_E;
            end
        end
        X_E: if (STAGE != 2) begin
            logic signed [31:0] d;
            logic io, ln, ny;
            logic [9:0] ixc;
            logic [15:0] a0, a1, n0;
            logic signed [31:0] di;
            // the slope's initial dx (Slope::Setup), formed here from inc and
            // the flags instead of a register set in X_D
            if (sd) begin
                if (xmaj)          di = neg ? 32'sh60000 : $signed({5'b0, inc}) - 32'sh20000;
                else if (inc != 0) di = neg ? 32'sh40000 : 32'sh0;
                else               di = 32'sh0;
            end else begin
                if (xmaj)          di = neg ? $signed({5'b0, inc}) + 32'sh20000 : 32'sh20000;
                else if (inc != 0) di = neg ? 32'sh40000 : 32'sh0;
                else               di = 32'sh0;
            end
            if (!mw) mw <= 1'b1;
            else begin
                mw <= 1'b0;
                d = di + $signed({1'b0, m_pr[30:0]});
                dx <= d;
                xv_go <= 1'b1;                  // xval from dx next cycle (nds-fit #433: d + x + clamp in one was -2.3 ns)
                ixc = ixp;                      // (y - y0) + io, formed in X_D
                ix <= ixc;
`ifndef ALTERA_RESERVED_QIS
                if (ixc > {2'b0, ylen} && ylen != 0)
                    $display("gpu3d_edge: line %0d outside the edge: ix %0d ylen %0d, va (%0d,%0d) vb (%0d,%0d) side %0d cur %0d nxt %0d nv %0d vtop %0d vbot %0d dummy %0d",
                             y, ixc, ylen, v_x(va), v_y(va), v_x(vb), v_y(vb), sd, cur, nxt, nv, vtop, vbot, dummy);
`endif
                a0 = v_w(va); a1 = v_w(vb);
                if (DS_YPERSP) begin
                    // the DS: linear when w bits 0-5 are clear, the full w in the factor
                    ln = (a0 == a1) && ((a0 & 16'h3F) == 0);
                    n0 = a0;
                    w0d <= a0;
                    w1d <= a1;
                end else begin
                    ln = (a0 == a1) && ((a0 & 16'h7E) == 0);
                    n0 = a0 >> 1;
                    w0d <= 16'((17'(a0) + 17'((a0 & ~a1) & 16'h1)) >> 1);
                    w1d <= a1 >> 1;
                end
                lin <= ln;
                w0n <= n0;
                ny = (ylen != 0) && (!ln || wbuf_e);
                need_yf <= ny;
                yf_pend <= 1'b0;
                need_lf <= DS_LIN17 && !DS_LINZ && ln && ylen != 0;
                // DS_LINZ: floor((ix << 17) / ylen) from the table, every edge
                if (DS_LINZ) lf <= 18'((48'(ixp) * 48'(lr_qr)) >> 20);
                lf_pend <= 1'b0;
                m_a <= 27'(ixc); m_b <= 27'(n0);
                xs <= ny ? X_F : (STAGE == 1) ? X_HO : X_Z;
            end
        end
        // perspective factor: num = (x*w0n) << 9, den = x*w0d + (xdiff-x)*w1d
        X_F: if (STAGE != 2) begin
            t_num <= m_p[31:0] << 9;
            m_a <= 27'(ix); m_b <= 27'(w0d);
            xs <= X_G;
        end
        X_G: if (STAGE != 2) begin
            t_den1 <= m_p[31:0];
            m_a <= 27'({2'b0, ylen} - ix); m_b <= 27'(w1d);
            xs <= X_H;
        end
        X_H: if (STAGE != 2) begin
            logic [31:0] den;
            den = h_den;
            if (!mw) mw <= 1'b1;
            else if ((den == 0 || dv_gnt) && (STAGE != 1 || ho_ready)) begin   // (waits while the span stage has the divider; STAGE 1: for stage 2)
                mw <= 1'b0;
                if (den == 0) yf <= '0;
                else begin
                    dv_start <= 1'b1; dv_num <= t_num; dv_den <= den[24:0];
                    yf_pend <= 1'b1;
                end
                if (STAGE == 1) begin
                    // the edge goes to stage 2 (ho is read the next clock, when
                    // yf / yf_pend are set; nothing here moves before X_L1)
                    ho_valid <= 1'b1;
                    busy <= 1'b0;
                    xs <= X_IDLE;
                end else xs <= X_Z;
            end
        end
        // Z along Y, Z-buffer: base + ((((disp >> s) * factor) * xrecip) >> 22) << s
        X_Z: if (STAGE != 1) begin
            logic [23:0] z0, z1, dz;
            logic [4:0]  bl, zs;
            z0 = v_z(va); z1 = v_z(vb);
            dz = (z0 < z1) ? z1 - z0 : z0 - z1;
            bl = bitlen25({1'b0, dz});
            zs = (bl > 10) ? bl - 5'd10 : 5'd0;
            zsh <= zs;
            zdz <= dz;
            m_b <= 27'((z0 < z1) ? ix : 10'({2'b0, ylen} - ix));
            if (DS_LINZ) begin
                // the 17-bit factor on the full difference (DS)
                m_a <= 27'(dz); m_b <= 27'((z0 < z1) ? lf : 18'h20000 - lf);
            end
            if (wbuf_e) xs <= X_YF;                     // Z is perspective then
            else if (ylen == 0 || z0 == z1) begin z <= z0; xs <= X_YF; end
            else xs <= DS_LINZ ? X_Z3 : X_Z1;
        end
        X_Z1: if (STAGE != 1) begin
            // dz >> zs (zs <= 14) as a multiply: (dz * 2^(14-zs)) >> 14
            m_a <= 27'((39'(zdz) * 39'(15'd1 << (5'd14 - zsh))) >> 14);
            xs <= X_Z2;
        end
        X_Z2: if (STAGE != 1) begin
            m_a <= m_p[26:0]; m_b <= 27'(xrecip);
            xs <= X_Z3;
        end
        X_Z3: if (STAGE != 1) begin
            if (!mw) mw <= 1'b1;
            else begin
                mw <= 1'b0;
                if (DS_LINZ) z <= 24'((v_z(va) < v_z(vb) ? v_z(va) : v_z(vb)) + 24'(m_pr >> 17));
                else z <= 24'((v_z(va) < v_z(vb) ? v_z(va) : v_z(vb)) + 24'(32'(m_pr >> 22) * 32'(15'd1 << zsh)));
                xs <= X_YF;
            end
        end
        X_YF: if (STAGE != 1 && (!yf_pend || dv_idle) && (!((aa_e && xmaj) || need_lf) || dv_gnt)) begin
            if (yf_pend) begin
                if (lf_pend) lf <= dv_q;
                else         yf <= dv_q[9:0];
            end
            yf_pend <= 1'b0; lf_pend <= 1'b0;
            dv_mode <= 1'b0;
            if (need_lf) begin
                // DS_LIN17: the linear factor floor((ix << 17) / ylen) next
                // (after the perspective one a W-buffer edge also needs)
                need_lf <= 1'b0;
                dv_start <= 1'b1; dv_num <= 32'({ix, 17'b0}); dv_den <= 25'(ylen); dv_mode <= 1'b1;
                yf_pend <= 1'b1; lf_pend <= 1'b1;
            end else begin
                // AA coverage step (ylen << 10) / xlen, x-major edges only
                cov_pend <= aa_e && xmaj;
                if (aa_e && xmaj) begin
                    dv_start <= 1'b1; dv_num <= {14'b0, ylen, 10'b0}; dv_den <= 25'(xlen);
                end
                k <= 4'd0; iab <= sel_ab(4'd0); c_v <= 1'b0; c2_v <= 1'b0; lop <= 3'd0;
                if (lin) begin
                    // W is constant on a linear edge; Z (W-buffer) is the one
                    // perspective item, done first (on X_IL; X_IP does it in turn)
                    w <= v_w(va);
                    k <= (wbuf_e && !DS_LIN17) ? 4'd6 : 4'd1; iab <= sel_ab((wbuf_e && !DS_LIN17) ? 4'd6 : 4'd1);
                end
                xs <= (lin && !DS_LIN17) ? X_IL : X_IP;
            end
        end
        // perspective: base + ((d * factor) >> 9), one item per cycle
        // item k issued, item k-1's product registered (m_p9), item k-2 written
        X_IP: if (STAGE != 1) begin
            // (item k-2 is written: pw, above)
            c2_lsh <= c_lsh; c2_tb <= c_tb;
            c2_v <= c_v; c2_k <= c_k; c2_direct <= c_direct; c2_base <= c_base;
            c_v <= 1'b0;
            if (k <= 4'd5 || (k == 4'd6 && wbuf_e) || (k == 4'd7 && toon_e && !TOONR)) begin
                m_a <= 27'(it_d); m_b <= 27'(it_pf);
                c_v <= 1'b1; c_k <= k; c_lsh <= it_lsh;
                c_tb <= DS_TEXRND && it_lsh && (k == 4'd4 || k == 4'd5);
                c_direct <= it_dir;
                c_base <= it_dir ? it_a : (it_lt ? it_a : it_b);
                k <= (k == 4'd5 && !wbuf_e) ? 4'd7 : k + 4'd1; iab <= sel_ab((k == 4'd5 && !wbuf_e) ? 4'd7 : k + 4'd1);
            end else if (!c_v) xs <= X_FIN;
        end
        // linear: base + floor(d * factor / ylen), the quotient from the
        // table (q' = (N * floor(2^26/ylen)) >> 26 is q or q-1 for N < 2^26)
        // and one correction
        X_IL: if (STAGE != 1) begin
            case (lop)
                3'd0: begin
                    // the item's base and whether it is a plain copy, registered
                    c_direct <= it_dir;
                    c_base <= it_dir ? it_a : (it_lt ? it_a : it_b);
                    if (k == 4'd6) begin            // W-buffer Z: perspective
                        m_a <= 27'(it_d); m_b <= 27'(it_pf);
                        lop <= 3'd4;
                    end else begin
                        m_a <= 27'(it_d); m_b <= 27'(it_lf);
                        lop <= 3'd1;
                    end
                end
                3'd1: begin
                    l_p1 <= m_p[24:0];
                    m_a <= m_p[26:0]; m_b <= r26;
                    lop <= 3'd2;
                end
                3'd2: begin
                    l_q <= 17'(m_p >> 26);
                    m_a <= 27'(m_p >> 26); m_b <= 27'(ylen);
                    lop <= 3'd3;
                end
                3'd3: begin
                    if (!mw) mw <= 1'b1;
                    else begin
                        mw <= 1'b0;                 // (the item is written: pw, above)
                        lop <= 3'd0;
                        if (k == 4'd7 || (k == 4'd5 && (TOONR || !toon_e))) xs <= X_FIN;
                        k <= (k == 4'd5) ? 4'd7 : k + 4'd1; iab <= sel_ab((k == 4'd5) ? 4'd7 : k + 4'd1);
                    end
                end
                default: begin                     // 4: Z (W-buffer)
                    if (!mw) mw <= 1'b1;
                    else begin
                        mw <= 1'b0;                 // (Z is written: pw, above)
                        lop <= 3'd0;
                        k <= 4'd1; iab <= sel_ab(4'd1);
                    end
                end
            endcase
        end
        // STAGE 1, an edge without the perspective division: handed over as from X_H
        X_HO: if (STAGE != 2 && ho_ready) begin
            ho_valid <= 1'b1;
            busy <= 1'b0;
            xs <= X_IDLE;
        end
        X_FIN: if (STAGE != 1 && (!cov_pend || dv_idle)) begin
            if (cov_pend) xcovinc <= dv_q;
            cov_pend <= 1'b0;
            busy <= 1'b0;
            xs <= X_IDLE;
        end
        default: xs <= X_IDLE;
        endcase
        // STAGE 2's prefetch: stage 1's edge's vertices into va, vb once this
        // edge no longer reads them (its last item issued, or idle)
        if (STAGE == 2) begin
            logic bfree;
            bfree = xs == X_IDLE || xs == X_FIN ||
                    (xs == X_IP && !(k <= 4'd5 || (k == 4'd6 && wbuf_e) || (k == 4'd7 && toon_e && !TOONR)));
            if (rst) begin pf_st <= 3'd0; pf_ok <= 1'b0; end
            else case (pf_st)
                3'd0: if (bfree && pfi_v && !(pf_ok && pf_have == pfi_idx)) begin
                    ld_idx <= pfi_idx; pf_ok <= 1'b0; pf_st <= 3'd1;
                end
                3'd1: pf_st <= VREG ? 3'd2 : 3'd3;   // cur's address out
                3'd2: pf_st <= 3'd3;
                3'd3: begin va <= vm_rdata; pf_st <= 3'd4; end
                default: begin vb <= vm_rdata; pf_ok <= 1'b1; pf_have <= ld_idx; pf_st <= 3'd0; end
            endcase
        end
        if (pw) case (pk)
            4'd0: w <= pv[15:0];
            4'd6: z <= pv[23:0];
            4'd7: rt <= pv[8:0];
            // a constant index per item: Yosys builds av[pk - 1] as a
            // shifter and mask over all 85 bits
            4'd1: av[0] <= pv[16:0];
            4'd2: av[1] <= pv[16:0];
            4'd3: av[2] <= pv[16:0];
            4'd4: av[3] <= pv[16:0];
            default: av[4] <= pv[16:0];
        endcase
    end
endmodule
