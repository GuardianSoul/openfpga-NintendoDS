// Simulation-only DMA working-state deposit. Caller must stop clocks and drain
// all accepted memory traffic before calling; register RAM is restored alongside
// this state, with its original readable CNT, not the import stub's disabled CNT.
// Define RUNTIME_DMA to the real sys_dma instance before including this file.
task automatic import_dma_working_state(input logic [31:0] image [0:79]);
    `RUNTIME_DMA.en = image[0][7:0];
    `RUNTIME_DMA.run = image[1][7:0];
    `RUNTIME_DMA.inprog = image[2][7:0];
    `RUNTIME_DMA.resume = 8'd0;
    for (int n=0;n<8;n++) begin
        `RUNTIME_DMA.mode[n] = image[4+n*9][2:0];
        `RUNTIME_DMA.sctl[n] = image[5+n*9][1:0];
        `RUNTIME_DMA.dctl[n] = image[6+n*9][1:0];
        `RUNTIME_DMA.u_work.mem[n] = {4'd0,image[10+n*9][6:0],image[9+n*9][20:0],image[8+n*9],image[7+n*9]};
    end
    `RUNTIME_DMA.est = `RUNTIME_DMA.E_IDLE;
    `RUNTIME_DMA.lr_v = 1'b0;
    `RUNTIME_DMA.rtag = 2'd0;
    `RUNTIME_DMA.fin_irq = 8'd0;
    `RUNTIME_DMA.mm_out = 1'b0;
    `RUNTIME_DMA.mm_n = 6'h3f;
endtask
