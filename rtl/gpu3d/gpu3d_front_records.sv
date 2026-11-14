// Independent early/late field writes in one native40-bit SDP slice.
// Adapted from gpu3d_ram_be2, with independent data and defined mixed-port
// OLD_DATA. Each10-bit byte enable preserves every unselected field.
module gpu3d_front_record_slice (
    input logic clk,we_early,we_late,
    input logic [2:0] waddr,raddr,
    input logic [19:0] early_data,late_data,
    output logic [19:0] early_q,late_q
);
    logic [39:0] q;
    assign early_q=q[19:0];assign late_q=q[39:20];
`ifdef ALTERA_RESERVED_QIS
    altsyncram #(
        .operation_mode("DUAL_PORT"),.ram_block_type("M10K"),
        .intended_device_family("Cyclone V"),
        .width_a(40),.widthad_a(3),.numwords_a(8),
        .width_b(40),.widthad_b(3),.numwords_b(8),
        .width_byteena_a(4),.byte_size(10),
        .outdata_reg_b("UNREGISTERED"),.address_reg_b("CLOCK0"),
        .rdcontrol_reg_b("CLOCK0"),.address_aclr_b("NONE"),.outdata_aclr_b("NONE"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),
        .power_up_uninitialized("FALSE"),.lpm_type("altsyncram")
    )u_ram(.clock0(clk),.wren_a(we_early||we_late),.address_a(waddr),
        .data_a({late_data,early_data}),.byteena_a({we_late,we_late,we_early,we_early}),
        .address_b(raddr),.q_b(q));
`else
    logic [39:0] mem[0:7];
    always_ff @(posedge clk)begin
        if(we_early)mem[waddr][19:0]<=early_data;
        if(we_late)mem[waddr][39:20]<=late_data;
        q<=mem[raddr];
    end
`endif
endmodule

// Four polygons/eight slope records. Fixed roles on each FAST edge:
// E writes STAGE1 fields and reads LEFT; M writes captured STAGE2 fields
// and reads RIGHT. The preceding LEFT read is held at M, before RAM q
// changes. Both records are qualified at the following SYS edge.
module gpu3d_front_records (
    input logic clk,clk2,rst,
    input logic early_we,late_we,
    input logic [2:0] early_owner,late_owner,
    input logic [47:0] early_data,
    input logic [58:0] late_data,
    input logic [1:0] left_owner,right_owner,
    output logic [106:0] left_record,right_record
);
    logic epoch=0,fr_fast_seen=0;
    wire middle=epoch!=fr_fast_seen;
    always_ff @(posedge clk)epoch<=!epoch;
    always_ff @(posedge clk2)fr_fast_seen<=epoch;
    logic held_late_we=0;
    logic [2:0] held_late_owner;
    logic [58:0] held_late_data;
    always_ff @(posedge clk)begin
        held_late_we<=!rst&&late_we;
        held_late_owner<=late_owner;held_late_data<=late_data;
    end
    wire we_early=!rst&&!middle&&early_we;
    wire we_late=!rst&&middle&&held_late_we;
    wire [2:0] wa=middle?held_late_owner:early_owner;
    wire [2:0] ra=middle?{1'b1,right_owner}:{1'b0,left_owner};
    wire [59:0] early_word={12'd0,early_data};
    wire [59:0] late_word={1'b0,held_late_data};
    logic [59:0] early_q,late_q;
    genvar slice;
    generate for(slice=0;slice<3;slice=slice+1)begin:g_slice
        gpu3d_front_record_slice u_ram(.clk(clk2),.we_early,.we_late,.waddr(wa),.raddr(ra),
            .early_data(early_word[20*slice+:20]),.late_data(late_word[20*slice+:20]),
            .early_q(early_q[20*slice+:20]),.late_q(late_q[20*slice+:20]));
    end endgenerate
    function automatic [106:0] record_(input logic [59:0] e,l);
        record_={e[47:19],e[18:9],l[58:49],e[8:0],l[48:9],l[8:0]};
    endfunction
    logic [106:0] fr_fast_left;
    always_ff @(posedge clk2)if(middle&&!rst)fr_fast_left<=record_(early_q,late_q);
    assign left_record=fr_fast_left;
    assign right_record=record_(early_q,late_q);
endmodule
