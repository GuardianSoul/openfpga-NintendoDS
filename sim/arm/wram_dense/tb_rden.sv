`timescale 1ps/1ps
// Primitive-only feasibility gate. No candidate production WRAM RTL yet.
module tb_rden;
    reg clk=0,clk2=0;
    initial begin #14919;forever begin clk=1;#7460;clk=0;#7459;end end
    initial begin #14919;forever begin clk2=1;#3730;clk2=0;#3730;clk2=1;#3730;clk2=0;#3729;end end
    reg epoch=0,seen=0;
    wire mid=epoch!=seen;
    always @(posedge clk)epoch<=!epoch;
    always @(posedge clk2)seen<=epoch;
    reg[3:0] a=0,b=1,aw,bw;
    reg wa=0,wb=0,haw,hbw;
    reg[9:0] da=0,db=0,hda,hdb;
    wire[9:0] qa,qb;
    reg[9:0] gold[0:15];
    reg[9:0] ea,eb,holda,holdb;
    integer n,k,checks=0;
    always @(posedge clk2)if(!mid)begin
        aw<=a;bw<=b;haw<=wa;hbw<=wb;hda<=da;hdb<=db;
    end
    altsyncram #(.operation_mode("BIDIR_DUAL_PORT"),.ram_block_type("M10K"),.intended_device_family("Cyclone V"),
        .width_a(10),.widthad_a(4),.numwords_a(16),.width_b(10),.widthad_b(4),.numwords_b(16),
        .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
        .address_reg_b("CLOCK0"),.indata_reg_b("CLOCK0"),.wrcontrol_wraddress_reg_b("CLOCK0"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),.power_up_uninitialized("FALSE"),.lpm_type("altsyncram")) ram(
        .clock0(clk2),.address_a(mid?aw:a),.address_b(mid?bw:b),
        .data_a(hda),.data_b(hdb),.wren_a(mid&&haw),.wren_b(mid&&hbw),
        .rden_a(!mid),.rden_b(!mid),.q_a(qa),.q_b(qb));
    initial begin
        for(k=0;k<16;k=k+1)gold[k]=0;
        // Two ports read at E and write at M, with input changes after E.
        // Check Q immediately after E, across M, and before the next E.
        for(n=0;n<1024;n=n+1)begin
            @(negedge clk2);if(!mid)begin
                a=4'(n);b=4'(n*7+1);wa=n%3!=0;wb=n%5!=0;
                if(a==b)wb=0;
                da=10'(n*31+9);db=10'(n*97+2);
                ea=gold[a];eb=gold[b];
                @(posedge clk);#1;
                if({qa,qb}!=={ea,eb})$fatal(1,"E read mismatch n=%0d",n);
                holda=qa;holdb=qb;
                if(wa)gold[a]=da;if(wb)gold[b]=db;
                #1;a=4'(n+6);b=4'(n+9);da=0;db=0;wa=0;wb=0;
                @(posedge clk2);#1;
                if({qa,qb}!=={holda,holdb})$fatal(1,"native rden failed M hold n=%0d",n);
                @(negedge clk2);#1;
                if({qa,qb}!=={holda,holdb})$fatal(1,"native rden failed late hold n=%0d",n);
                checks=checks+3;
            end else n=n-1;
        end
        $display("PASS_NATIVE_RDEN E/M/late checks=%0d exact Pocket14919/7460 phase; write survives late input changes",checks);
        $finish;
    end
    initial begin #100000000;$fatal(1,"timeout");end
endmodule
