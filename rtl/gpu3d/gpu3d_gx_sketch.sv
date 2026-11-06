// COST SKETCH, NOT FUNCTIONAL. A microcoded DS geometry engine datapath,
// sized for the work melonDS's GPU3D.cpp does per command (matrix stacks and
// multiplies, vertex transform, lighting, clipping, viewport divide, polygon
// setup). The microcode is not written: the control store is a loadable RAM
// so that synthesis keeps the whole datapath, and the figure is what the
// datapath, sequencer and storage cost. See docs/renderer-3d.md.
//
// Storage (register file, 2048 x 32, two read ports as two copies):
//   position + vector matrix stacks 2 x 31 x 16, projection and texture
//   stacks, the five current matrices (proj, pos, vec, tex, clip), lights,
//   material, the 10-vertex clip buffer (position, colour, texcoord) and
//   temporaries.
// Arithmetic:
//   one signed 32x32 multiplier into a 64-bit accumulator (matrix, vertex,
//   lighting and clip MACs; >>12 extraction with saturation), a 64/32
//   radix-2 divider (viewport X/Y, Z = z*0x4000/w, clip interpolation
//   factor), a 32-bit ALU (add/sub/logic/compare/min/max/shift/clamp).
module gpu3d_gx_sketch (
    input  logic         clk,
    input  logic         rst,
    // GX FIFO (command + parameter)
    input  logic         fifo_valid,
    input  logic [7:0]   fifo_cmd,
    input  logic [31:0]  fifo_param,
    output logic         fifo_pop,
    // control-store load
    input  logic         uc_we,
    input  logic [9:0]   uc_waddr,
    input  logic [71:0]  uc_wdata,
    // shininess table load
    input  logic         sh_we,
    input  logic [6:0]   sh_waddr,
    input  logic [7:0]   sh_wdata,
    // vertex / polygon records to the SDRAM writer
    output logic         out_valid,
    output logic [127:0] out_data,
    input  logic         out_ready,
    // MMIO reads (clip matrix, position/vector test results)
    input  logic [10:0]  mmio_addr,
    output logic [31:0]  mmio_rdata
);
    // ---------------- microword ----------------
    // [9:0] branch target, [13:10] condition, [18:14] ALU op,
    // [29:19] src A, [40:30] src B, [51:41] dst, [52] write,
    // [54:53] MAC op (0 none, 1 clear+mul, 2 accumulate, 3 negate-acc),
    // [55] div start, [56] fifo pop, [57] out push, [59:58] out lane,
    // [61:60] base select for A/B/dst (stack pointer / vertex index / loop),
    // [69:62] immediate, [70] call, [71] return
    logic [71:0] uw;
    logic [9:0]  upc;
    logic [71:0] ucode [0:1023];
    always_ff @(posedge clk) begin
        if (uc_we) ucode[uc_waddr] <= uc_wdata;
        uw <= ucode[upc];
    end

    // ---------------- register file ----------------
    logic [31:0] rf_a [0:2047];
    logic [31:0] rf_b [0:2047];
    logic [31:0] ra, rb;
    logic [10:0] a_addr, b_addr, d_addr;
    logic [31:0] wdata;
    logic        we;
    logic [4:0]  sp_pos, sp_vec;
    logic [3:0]  vidx;
    logic [7:0]  loopc;
    function automatic [10:0] based(input [10:0] a, input [1:0] sel, input [4:0] sp, input [3:0] vi, input [7:0] lc);
        case (sel)
            2'd0: based = a;
            2'd1: based = a + {2'b0, sp, 4'b0};
            2'd2: based = a + {3'b0, vi, 4'b0};
            default: based = a + {3'b0, lc};
        endcase
    endfunction
    assign a_addr = based(uw[29:19], uw[61:60], sp_pos, vidx, loopc);
    assign b_addr = based(uw[40:30], uw[61:60], sp_vec, vidx, loopc);
    assign d_addr = based(uw[51:41], uw[61:60], sp_pos, vidx, loopc);
    always_ff @(posedge clk) begin
        if (we) begin rf_a[d_addr] <= wdata; rf_b[d_addr] <= wdata; end
        ra <= rf_a[a_addr];
        rb <= rf_b[(uw[13:10] == 4'hF) ? mmio_addr : b_addr];
    end
    assign mmio_rdata = rb;

    // ---------------- MAC ----------------
    logic signed [63:0] acc;
    wire  signed [31:0] opb = uw[62] ? $signed(fifo_param) : $signed(rb);
    wire  signed [63:0] prod = $signed(ra) * opb;
    always_ff @(posedge clk) begin
        case (uw[54:53])
            2'd1: acc <= prod;
            2'd2: acc <= acc + prod;
            2'd3: acc <= -acc;
            default: ;
        endcase
    end
    // >>12 with saturation to s32, and the raw high word
    wire signed [51:0] acc12 = acc >>> 12;
    wire [31:0] acc_sat = (acc12 > 52'sh7FFFFFFF) ? 32'h7FFFFFFF :
                          (acc12 < -52'sh80000000) ? 32'h80000000 : acc12[31:0];

    // ---------------- divider (64/32 radix-2) ----------------
    logic [63:0] dq, dn;
    logic [32:0] drem;
    logic [31:0] dd;
    logic [6:0]  dcnt;
    logic        dbusy;
    wire  [33:0] dtrial = {drem, dn[63]} - {2'b0, dd};
    always_ff @(posedge clk) begin
        if (rst) dbusy <= 1'b0;
        else if (uw[55]) begin
            dn <= acc; dd <= rb; drem <= '0; dq <= '0; dcnt <= 7'd64; dbusy <= 1'b1;
        end else if (dbusy) begin
            if (!dtrial[33]) begin drem <= dtrial[32:0]; dq <= {dq[62:0], 1'b1}; end
            else begin drem <= {drem[31:0], dn[63]}; dq <= {dq[62:0], 1'b0}; end
            dn <= {dn[62:0], 1'b0};
            dcnt <= dcnt - 7'd1;
            if (dcnt == 7'd1) dbusy <= 1'b0;
        end
    end

    // ---------------- ALU ----------------
    logic [31:0] alu;
    logic        f_z, f_n, f_c;
    always_comb begin
        logic [32:0] sum;
        sum = {1'b0, ra} + {1'b0, rb};
        case (uw[18:14])
            5'd0:  alu = sum[31:0];
            5'd1:  alu = ra - rb;
            5'd2:  alu = ra & rb;
            5'd3:  alu = ra | rb;
            5'd4:  alu = ra ^ rb;
            5'd5:  alu = ($signed(ra) < $signed(rb)) ? ra : rb;
            5'd6:  alu = ($signed(ra) > $signed(rb)) ? ra : rb;
            5'd7:  alu = ra << rb[4:0];
            5'd8:  alu = $signed(ra) >>> rb[4:0];
            5'd9:  alu = ra >> rb[4:0];
            5'd10: alu = acc_sat;
            5'd11: alu = acc[63:32];
            5'd12: alu = dq[31:0];
            5'd13: alu = fifo_param;
            5'd14: alu = {24'b0, uw[69:62]};
            5'd15: alu = ($signed(ra) < 0) ? -ra : ra;
            5'd16: alu = {{16{ra[15]}}, ra[15:0]};
            5'd17: alu = {{16{ra[31]}}, ra[31:16]};
            5'd18: alu = {16'b0, ra[15:0] & {11'b0, 5'h1F}} << {rb[3:0]};
            5'd19: alu = ($signed(ra) < 0) ? 32'd0 : ($signed(ra) > $signed(rb)) ? rb : ra; // clamp
            default: alu = {ra[15:0], rb[15:0]};
        endcase
        f_z = (alu == 0);
        f_n = alu[31];
        f_c = sum[32];
    end
    assign wdata = alu;
    assign we = uw[52];

    // shininess table (lighting)
    logic [7:0] shin [0:127];
    logic [7:0] shin_q;
    always_ff @(posedge clk) begin
        if (sh_we) shin[sh_waddr] <= sh_wdata;
        shin_q <= shin[ra[31:25]];
    end

    // ---------------- sequencer ----------------
    logic [9:0] stack [0:3];
    logic [1:0] ssp;
    logic       cond;
    always_comb begin
        case (uw[13:10])
            4'd0: cond = 1'b0;
            4'd1: cond = 1'b1;
            4'd2: cond = f_z;
            4'd3: cond = !f_z;
            4'd4: cond = f_n;
            4'd5: cond = !f_n;
            4'd6: cond = f_c;
            4'd7: cond = dbusy;
            4'd8: cond = !fifo_valid;
            4'd9: cond = loopc == 0;
            4'd10: cond = out_valid && !out_ready;
            4'd11: cond = shin_q[7];
            default: cond = 1'b0;
        endcase
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            upc <= '0; ssp <= '0; sp_pos <= '0; sp_vec <= '0; vidx <= '0; loopc <= '0;
        end else begin
            if (uw[71]) begin upc <= stack[ssp - 2'd1]; ssp <= ssp - 2'd1; end
            else if (uw[70]) begin stack[ssp] <= upc + 10'd1; ssp <= ssp + 2'd1; upc <= uw[9:0]; end
            else if (fifo_valid && upc == 10'd0) upc <= {fifo_cmd, 2'b0};   // command dispatch
            else if (cond) upc <= uw[9:0];
            else upc <= upc + 10'd1;
            // index registers: stack pointers, vertex index, loop count
            case (uw[69:66])
                4'd1: sp_pos <= alu[4:0];
                4'd2: sp_vec <= alu[4:0];
                4'd3: vidx <= alu[3:0];
                4'd4: loopc <= alu[7:0];
                4'd5: loopc <= loopc - 8'd1;
                4'd6: vidx <= vidx + 4'd1;
                default: ;
            endcase
        end
    end
    assign fifo_pop = uw[56];

    // ---------------- output packing ----------------
    always_ff @(posedge clk) begin
        if (rst) out_valid <= 1'b0;
        else begin
            if (out_valid && out_ready) out_valid <= 1'b0;
            if (uw[57]) begin
                out_data[uw[59:58] * 32 +: 32] <= alu;
                if (uw[59:58] == 2'd3) out_valid <= 1'b1;
            end
        end
    end
endmodule
