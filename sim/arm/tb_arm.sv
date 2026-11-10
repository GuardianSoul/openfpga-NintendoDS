// Testbench for rtl/arm/arm_cpu.sv (Verilator --binary and Icarus).
//
// Each context has its own memory: 16 regions (address bits 27:24) of
// 256 KB, except main RAM (region 2), which has all 4 MB and its mirrors.
// Main RAM beyond the first 256 KB uses additional image slots so existing
// low-address images retain their indices. Loaded from $readmemh. Plusargs:
//   +img0=<hex> +img1=<hex>        memory images (sim/arm/tools/mkhex.py)
//   +pc0=<hex>  +pc1=<hex>         reset PC per context
//   +run=<0..3>                    context enable mask
//   +mode0=<m>  +mode1=<m>         exit | jsmolka | armwrestler
//   +hook0..3=<hex>                armwrestler hooks: DrawResult, CheckKeys,
//                                  _drawresult, _checkkeys
//   +maxcycles=<n>
//   +trace0=<csv> +trace1=<csv>    write pc,cpsr,r0..r14 per retired instruction
//   +ops0=<txt>   +ops1=<txt>      write "pc word cpsr cycle" per retired instruction
//                                  (word from the testbench memory; for the
//                                  throughput model, sim/arm/tools/slotmodel.py)
//   +ref0=<csv>   +ref1=<csv>      compare against such a file (lockstep)
//
// Exit codes: a store to 0x0F000000 ends the context with that value
// (0 = pass). A store to 0x0F000004 drives that context's IRQ line.
// ARM7 halt: the ARM7 halts on its store of 0x80 to HALTCNT (0x04000301, seen
// here on its data port); a store to 0x0F00000C sets the wake line (IE & IF)
// to bit 0, or with bit 31 set raises it N = bits 30:0 cycles later. An ARM7
// that keeps retiring while halted (more than the instructions already in its
// pipeline) fails the run.
module tb_arm #(parameter int ARM9_WAYS = 4, parameter bit A9_SOLO = 1'b0, parameter int A9_OPT = 0, parameter bit EVB = 1'b0, parameter bit EVBW = 1'b0, parameter int A9_XD = 0, parameter int A9_XI = 0, parameter bit SLOW = 1'b0, parameter bit A7_DS = 1'b0, parameter bit EARLYD = 1'b0);   // (obj2: -GARM9_WAYS=2, the DS build's)
  logic clk = 1'b0;
  logic rst = 1'b1;

  logic [31:0] mem0 [0:(1<<21)-1];
  logic [31:0] mem1 [0:(1<<21)-1];

  function automatic int unsigned midx(input logic [31:0] a);
    // swflush's data at 02040000 must not overwrite code at 02000000.
    // Bit22 is still ignored: 02440000 is the uncached mirror of 02040000.
    if (a[27:24] == 4'h2 && a[21:18] != 0)
      return 32'h00100000 | {12'h0, a[21:2]};
    return {12'h0, a[27:24], a[17:2]};
  endfunction

  function automatic logic [31:0] rd_mem(input logic t, input logic [31:0] a);
    if (t) return mem1[midx(a)];
    else   return mem0[midx(a)];
  endfunction

  task automatic wr_mem(input logic t, input logic [31:0] a, input logic [31:0] d,
                        input logic [3:0] be);
    logic [31:0] o;
    o = rd_mem(t, a);
    for (int i = 0; i < 4; i++) if (be[i]) o[i*8 +: 8] = d[i*8 +: 8];
    if (t) mem1[midx(a)] = o;
    else   mem0[midx(a)] = o;
  endtask

  // DUT: arm_cpu = the shared pipeline plus the ARM9 memory system. The ARM7
  // (context 1) is served by mem1 directly with the core's port timing; the
  // ARM9 (context 0) reaches mem0 through its caches/TCMs and the ARM9 bus.
  logic [1:0]  run;
  logic [31:0] pc0, pc1;
  logic [1:0]  irq;
  logic        wake7 = 1'b0, halted7 = 1'b0, halt_err = 1'b0;
  longint      wake_at = -1;
  int          halt_ret = 0;
  int          rwait;
  logic        rp_v = 1'b0;            // an ARM7 data access was refused (rp_a)
  logic [31:0] rp_a;                  // +rwait=<percent>: random "not ready" answers (ARM7)
  int          blat;                   // +blat=<cycles>: ARM9 bus latency per word
  int          dbg_on;                 // +dbg=1: print ports and retirements
  initial if (!$value$plusargs("dbg=%d", dbg_on)) dbg_on = 0;
  logic        a7_i_req, a7_i_ok, a7_d_req, a7_d_we, a7_d_ok;
  logic [31:0] a7_i_addr, a7_i_rdata, a7_d_addr, a7_d_wdata, a7_d_rdata;
  logic [3:0]  a7_d_be;
  logic        b9_req, b9_we, b9_ack;
  logic [31:0] b9_addr, b9_wdata, b9_rdata;
  logic [3:0]  b9_be;
  logic        dbg_wen, dbg_retire, dbg_tid;
  logic [5:0]  dbg_wa;
  logic [31:0] dbg_wd, dbg_pc, dbg_cpsr;

  arm_cpu #(.ARM9_WAYS(ARM9_WAYS), .A9_SOLO(A9_SOLO), .A9_OPT(A9_OPT), .ARM9_EVB(EVB), .ARM9_EVBW(EVBW), .A9_XD(A9_XD), .A9_XI(A9_XI), .SLOW(SLOW), .A7_DS(A7_DS), .ARM9_EARLYD(EARLYD)) dut (
    .clk(clk), .rst(rst), .run(run), .reset_pc0(pc0), .reset_pc1(pc1),
    .hivecs7(1'b0), .irq(irq), .fiq(2'b00), .wake7(wake7),
    .b9_req(b9_req), .b9_we(b9_we), .b9_addr(b9_addr), .b9_wdata(b9_wdata), .b9_be(b9_be),
    .b9_ack(b9_ack), .b9_rdata(b9_rdata),
    .a7_i_req(a7_i_req), .a7_i_addr(a7_i_addr), .a7_i_rdata(a7_i_rdata), .a7_i_ok(a7_i_ok),
    .a7_d_req(a7_d_req), .a7_d_we(a7_d_we), .a7_d_be(a7_d_be), .a7_d_addr(a7_d_addr),
    .a7_d_wdata(a7_d_wdata), .a7_d_rdata(a7_d_rdata), .a7_d_ok(a7_d_ok),
    .dbg_wen(dbg_wen), .dbg_wa(dbg_wa), .dbg_wd(dbg_wd),
    .dbg_retire(dbg_retire), .dbg_tid(dbg_tid), .dbg_pc(dbg_pc), .dbg_cpsr(dbg_cpsr)
  );

  // Test state
  string       img0, img1, mode0, mode1, tr0, tr1, rf0, rf1, op0, op1;
  logic [31:0] hook [0:3];
  longint      maxcycles, cycle;
  int          trf [0:1];
  int          opf [0:1];
  int          reff [0:1];
  logic [31:0] shadow [0:1][0:31];
  logic        done [0:1];
  logic [31:0] result [0:1];
  logic [31:0] last_pc [0:1];
  int          same_cnt [0:1];
  longint      retired [0:1];
  int          aw_step, aw_fail, aw_results;
  logic [15:0] vcount;
  int          errors;

  function automatic logic [31:0] logical_reg(input logic t, input int r, input logic [31:0] cpsr);
    return shadow[t][arm_pkg::phys_reg(r[3:0], cpsr[4:0])];
  endfunction

  function automatic string cstr(input logic t, input logic [31:0] a);
    string s;
    logic [7:0] c;
    s = "";
    for (int i = 0; i < 40; i++) begin
      logic [31:0] w;
      w = rd_mem(t, a + i);
      c = w[((a + i) & 3) * 8 +: 8];
      if (c == 8'h0) break;
      s = {s, string'(c)};
    end
    return s;
  endfunction

  always #5 clk = ~clk;

  initial begin
    int v;
    logic [31:0] hv;
    for (int i = 0; i < (1<<21); i++) begin
      mem0[i] = 32'h0;
      mem1[i] = 32'h0;
    end
    if ($value$plusargs("img0=%s", img0)) $readmemh(img0, mem0);
    if ($value$plusargs("img1=%s", img1)) $readmemh(img1, mem1);
    if (!$value$plusargs("pc0=%h", pc0)) pc0 = 32'h0;
    if (!$value$plusargs("pc1=%h", pc1)) pc1 = 32'h0;
    if (!$value$plusargs("run=%d", v)) v = 3;
    run = v[1:0];
    if (!$value$plusargs("mode0=%s", mode0)) mode0 = "exit";
    if (!$value$plusargs("mode1=%s", mode1)) mode1 = "exit";
    if (!$value$plusargs("hook0=%h", hv)) hv = 32'hFFFFFFFF;
    hook[0] = hv;
    if (!$value$plusargs("hook1=%h", hv)) hv = 32'hFFFFFFFF;
    hook[1] = hv;
    if (!$value$plusargs("hook2=%h", hv)) hv = 32'hFFFFFFFF;
    hook[2] = hv;
    if (!$value$plusargs("hook3=%h", hv)) hv = 32'hFFFFFFFF;
    hook[3] = hv;
    if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 64'd20000000;
    if (!$value$plusargs("rwait=%d", rwait)) rwait = 0;
    if (!$value$plusargs("blat=%d", blat)) blat = 2;
    trf[0] = 0; trf[1] = 0; reff[0] = 0; reff[1] = 0;
    if ($value$plusargs("trace0=%s", tr0)) trf[0] = $fopen(tr0, "w");
    if ($value$plusargs("trace1=%s", tr1)) trf[1] = $fopen(tr1, "w");
    opf[0] = 0; opf[1] = 0;
    if ($value$plusargs("ops0=%s", op0)) opf[0] = $fopen(op0, "w");
    if ($value$plusargs("ops1=%s", op1)) opf[1] = $fopen(op1, "w");
    if ($value$plusargs("ref0=%s", rf0)) reff[0] = $fopen(rf0, "r");
    if ($value$plusargs("ref1=%s", rf1)) reff[1] = $fopen(rf1, "r");
    for (int t = 0; t < 2; t++) begin
      done[t] = !run[t];
      result[t] = 32'h0;
      last_pc[t] = 32'hFFFFFFFF;
      same_cnt[t] = 0;
      retired[t] = 0;
      for (int r = 0; r < 32; r++) shadow[t][r] = 32'h0;
    end
    irq = 2'b00;
    aw_step = 0; aw_fail = 0; aw_results = 0;
    vcount = 16'h0;
    errors = 0;
    cycle = 0;
    repeat (4) @(posedge clk);
    rst = 1'b0;
  end

  // The DUT's request outputs are sampled at the falling edge, so the
  // answers at the rising edge never race the DUT's own register updates.
  logic        q_ireq, q_dreq, q_dwe, q_breq, q_bwe;
  logic [31:0] q_iaddr, q_daddr, q_dwdata, q_baddr, q_bwdata;
  logic [3:0]  q_dbe, q_bbe;
  always @(negedge clk) begin
    q_ireq = a7_i_req; q_iaddr = a7_i_addr;
    q_dreq = a7_d_req; q_dwe = a7_d_we; q_daddr = a7_d_addr; q_dwdata = a7_d_wdata; q_dbe = a7_d_be;
    q_breq = b9_req; q_bwe = b9_we; q_baddr = b9_addr; q_bwdata = b9_wdata; q_bbe = b9_be;
  end

  // Writes to the test-control addresses, from either CPU
  task automatic ctl_write(input logic t, input logic [31:0] a, input logic [31:0] d,
                           input logic [3:0] be);
    if (a == 32'h0F000000) begin
      if (!done[t]) begin
        result[t] = d;
        done[t] = 1'b1;
      end
    end else if (a == 32'h0F000004) begin
      irq[t] = d[0];
    end else if (a == 32'h0F00000C) begin
      if (d[31]) wake_at = cycle + longint'(d[30:0]);
      else wake7 = d[0];
    end else begin
      wr_mem(t, a, d, be);
    end
  endtask

  // ARM7 ports. With +rwait, a request is answered "not ready" at random (a
  // store is then not performed) to exercise the core's replay. (Each random
  // draw goes into a variable first: Verilator may evaluate a condition twice
  // when it lowers if/else-if, and a $urandom in it would then decide
  // differently each time.)
  always @(posedge clk) begin
    int unsigned ri, rd;
    ri = $urandom % 100;
    rd = $urandom % 100;
    a7_i_ok <= 1'b1;
    a7_d_ok <= 1'b1;
    if (q_ireq) begin
      a7_i_rdata <= rd_mem(1'b1, q_iaddr);
      if (rwait != 0 && ri < rwait) a7_i_ok <= 1'b0;
    end
    // A refused data access must be the next one the context issues again
    // (no exception entry in between: the memory may already hold its word)
    if (q_dreq && rp_v && q_daddr != rp_a) begin
      $display("ERROR: ARM7 data access %08x issued before the refused %08x was replayed",
               q_daddr, rp_a);
      errors = errors + 1;
    end
    if (q_dreq) rp_v <= 1'b0;
    if (q_dreq && rwait != 0 && rd < rwait) begin
      a7_d_ok <= 1'b0;
      rp_v <= 1'b1; rp_a <= q_daddr;
    end else if (q_dreq) begin
      if (q_dwe) begin
        if (q_daddr[31:2] == 30'h010000C0 && q_dbe[1] && q_dwdata[15:8] == 8'h80) begin
          halted7 = !wake7; halt_ret = 0;   // HALTCNT: halted until the wake line
        end
        ctl_write(1'b1, q_daddr, q_dwdata, q_dbe);
      end else begin
        if (q_daddr[31:2] == 30'h01000001) begin           // GBA DISPSTAT: toggle VBlank
          vcount <= vcount + 16'd1;
          a7_d_rdata <= {16'h0, 15'h0, vcount[0]};
        end else if (q_daddr[31:2] == 30'h0100004C) begin  // GBA KEYINPUT: nothing pressed
          a7_d_rdata <= 32'h03FF03FF;
        end else begin
          a7_d_rdata <= rd_mem(1'b1, q_daddr);
        end
      end
    end
  end

  // ARM9 bus: one word per transfer, acknowledged after +blat cycles
  int bcnt;
  always @(posedge clk) begin
    b9_ack <= 1'b0;
    if (rst) bcnt <= 0;
    else if (q_breq && !b9_ack) begin
      if (bcnt >= blat) begin
        bcnt <= 0;
        b9_ack <= 1'b1;
        if (q_bwe) ctl_write(1'b0, q_baddr, q_bwdata, q_bbe);
        else if (q_baddr[31:2] == 30'h01000001) begin     // GBA DISPSTAT: toggle VBlank
          vcount <= vcount + 16'd1;
          b9_rdata <= {16'h0, 15'h0, vcount[0]};
        end else if (q_baddr[31:2] == 30'h0100004C)       // GBA KEYINPUT
          b9_rdata <= 32'h03FF03FF;
        else       b9_rdata <= rd_mem(1'b0, q_baddr);
      end else begin
        bcnt <= bcnt + 1;
      end
    end
  end

  // +dbg: print the data port and retirements
  always @(posedge clk) if (dbg_on != 0 && !rst) begin
    if (b9_req && b9_ack) $display("%0d BUS9 %s a=%08x d=%08x", cycle, b9_we ? "WR" : "RD", b9_addr, b9_we ? b9_wdata : b9_rdata);
    if (dbg_retire) $display("%0d RET ctx%0d pc=%08x", cycle, dbg_tid, dbg_pc);
    if (dbg_wen) $display("%0d RF  [%0d] <= %08x", cycle, dbg_wa, dbg_wd);
  end

  // Trace, lockstep compare and test monitors
  always @(posedge clk) begin
    if (!rst) begin
      logic t;
      logic [31:0] cp;
      cycle = cycle + 1;
      if (wake_at >= 0 && cycle >= wake_at) begin wake7 = 1'b1; wake_at = -1; end
      if (wake7) halted7 = 1'b0;
      if (dbg_wen) shadow[dbg_wa[5]][dbg_wa[4:0]] = dbg_wd;
      if (dbg_retire) begin
        t = dbg_tid;
        if (t && halted7) begin
          halt_ret = halt_ret + 1;
          if (halt_ret > 6 && !halt_err) begin
            $display("ctx1: still retiring while halted (pc %08x)", dbg_pc);
            halt_err = 1'b1;
          end
        end
        cp = dbg_cpsr;
        retired[t] = retired[t] + 1;
        if (opf[t] != 0)
          $fwrite(opf[t], "%08x %08x %08x %0d\n", dbg_pc, rd_mem(t, dbg_pc), cp, cycle);
        if (trf[t] != 0) begin
          $fwrite(trf[t], "%08x,%08x", dbg_pc, cp);
          for (int r = 0; r < 15; r++) $fwrite(trf[t], ",%08x", logical_reg(t, r, cp));
          $fwrite(trf[t], "\n");
        end
        if (reff[t] != 0 && !$feof(reff[t])) begin
          logic [31:0] rv [0:16];
          int n;
          n = $fscanf(reff[t], "%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h\n",
                      rv[0], rv[1], rv[2], rv[3], rv[4], rv[5], rv[6], rv[7], rv[8],
                      rv[9], rv[10], rv[11], rv[12], rv[13], rv[14], rv[15], rv[16]);
          if (n == 17) begin
            logic bad;
            bad = (rv[0] != dbg_pc) || (rv[1] != cp);
            for (int r = 0; r < 15; r++) if (rv[r + 2] != logical_reg(t, r, cp)) bad = 1'b1;
            if (bad) begin
              $display("LOCKSTEP MISMATCH ctx%0d at retire %0d: ref pc=%08x cpsr=%08x, dut pc=%08x cpsr=%08x",
                       t, retired[t], rv[0], rv[1], dbg_pc, cp);
              for (int r = 0; r < 15; r++)
                if (rv[r + 2] != logical_reg(t, r, cp))
                  $display("  r%0d ref=%08x dut=%08x", r, rv[r + 2], logical_reg(t, r, cp));
              errors = errors + 1;
              done[0] = 1'b1; done[1] = 1'b1;
              result[t] = 32'hDEAD0001;
            end
          end
        end

        // idle loop (branch to self)
        if (dbg_pc == last_pc[t]) same_cnt[t] = same_cnt[t] + 1;
        else same_cnt[t] = 0;
        last_pc[t] = dbg_pc;

        if ((t ? mode1 : mode0) == "jsmolka" && same_cnt[t] > 8 && !done[t]) begin
          if (dbg_pc[31:24] != 8'h08) $display("ctx%0d: idle loop outside ROM at %08x", t, dbg_pc);
          result[t] = (dbg_pc[31:24] == 8'h08) ? logical_reg(t, 12, cp) : 32'hDEAD0003;
          done[t] = 1'b1;
        end
        if ((t ? mode1 : mode0) == "exit" && same_cnt[t] > 64 && !done[t]) begin
          $display("ctx%0d: stuck in a loop at %08x without an exit code", t, dbg_pc);
          result[t] = 32'hDEAD0002;
          done[t] = 1'b1;
        end

        if ((t ? mode1 : mode0) == "armwrestler" && !done[t]) begin
          if (dbg_pc == hook[0] || dbg_pc == hook[2]) begin
            logic [31:0] mask;
            mask = (dbg_pc == hook[0]) ? (logical_reg(t, 1, cp) & 32'hFF) : logical_reg(t, 6, cp);
            aw_results = aw_results + 1;
            if (mask != 0) begin
              aw_fail = aw_fail + 1;
              $display("armwrestler %s test %0d: %-8s BAD mask=%02x",
                       (dbg_pc == hook[0]) ? "ARM" : "THUMB",
                       (dbg_pc == hook[0]) ? aw_step - 1 : aw_step - 6,
                       cstr(t, logical_reg(t, 0, cp)), mask);
            end
          end
          if (dbg_pc == hook[1]) begin
            // ARM menu loop: run tests 0-4, then the Thumb tests (menu item 3)
            if (aw_step < 5) begin
              wr_mem(t, 32'h03000008, aw_step, 4'hF);
            end else begin
              wr_mem(t, 32'h03000010, 32'd3, 4'hF);
              wr_mem(t, 32'h03000008, 32'd11, 4'hF);
            end
            aw_step = aw_step + 1;
          end
          if (dbg_pc == hook[3]) begin
            if (aw_step < 8) begin
              wr_mem(t, 32'h03000008, aw_step - 5, 4'hF);
              aw_step = aw_step + 1;
            end else begin
              result[t] = aw_fail;
              done[t] = 1'b1;
            end
          end
        end
      end

      if (done[0] && done[1]) begin
        for (int c = 0; c < 2; c++) begin
          if (run[c]) begin
            $display("ctx%0d (%s): %s result=%08x retired=%0d",
                     c, c ? "ARM7" : "ARM9", (result[c] == 0) ? "PASS" : "FAIL",
                     result[c], retired[c]);
            if (result[c] != 0) errors = errors + 1;
          end
        end
        if ((mode0 == "armwrestler" && run[0]) || (mode1 == "armwrestler" && run[1]))
          $display("armwrestler: %0d results checked, %0d bad", aw_results, aw_fail);
        $display("cycles=%0d", cycle);
        if (halt_err) errors = errors + 1;
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
      end
      if (cycle >= maxcycles) begin
        for (int c = 0; c < 2; c++)
          if (run[c] && !done[c])
            $display("ctx%0d: timeout at pc=%08x retired=%0d", c, last_pc[c], retired[c]);
        $display("TEST FAILED (timeout)");
        $finish;
      end
    end
  end
endmodule
