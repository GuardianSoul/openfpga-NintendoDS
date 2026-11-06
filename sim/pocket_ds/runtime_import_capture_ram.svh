// Simulation-only two-2KiB capture RAM transaction, at a stopped/drained
// import boundary. Define RUNTIME_CRAM0_MEM/RUNTIME_CRAM1_MEM to the actual
// paired CellularRAM models' halfword memories. This restores RAM only;
// pending capture FIFO bytes and engine write offsets are separate state.
task automatic import_capture_main_ram(input logic [31:0] words[0:1023],input logic [31:0] addresses[0:1]);
    for(int u=0;u<2;u++)begin
        assert(addresses[u]>=32'h02000000 && addresses[u]+32'd2048<=32'h02400000 && addresses[u][1:0]==0)
            else $fatal(1,"capture import range unsupported");
        for(int w=0;w<512;w++)begin
            `RUNTIME_CRAM0_MEM[((addresses[u]-32'h02000000)>>2)+32'(w)]=words[u*512+w][15:0];
            `RUNTIME_CRAM1_MEM[((addresses[u]-32'h02000000)>>2)+32'(w)]=words[u*512+w][31:16];
        end
    end
endtask
