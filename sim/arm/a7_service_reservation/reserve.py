"""Test-only first-internal/prepared-F reservation of existing P7 service.

The qualified commit still owns logical payload; physical scheduling is
untouched. Actual elapsed SYS edges age only the existing 2/16 budget.
"""

def patch(source,mutation='none'):
    def replace(old,new):
        nonlocal source
        assert source.count(old)==1,old
        source=source.replace(old,new,1)
    replace('module nds_arm7_port_slot_trial #(','module nds_arm7_port_reserve_trial #(')
    replace('    output logic        i_commit_accept,','''    output logic        i_commit_accept,
    input logic i_prepare_valid,
    input logic [31:0] i_prepare_addr,''')
    anchor='    wire slot_old_consume = i_consume && flow_main && flow_ready;'
    replace(anchor,anchor+'''
    logic reserve_v=0;
    logic [31:2] reserve_addr;
    logic [1:0] reserve_gen;
    logic [4:0] reserve_left;
    wire reserve_match=reserve_v && reserve_addr==i_commit_addr[31:2] && reserve_gen==if_gen;
    // The acceptance edge itself is an elapsed service edge. Reservation
    // starts at prepare, so saturate after that edge; no extra wait added.
    wire [4:0] reserve_at_commit=reserve_left==0 ? 5'd0 : reserve_left-5'd1;
    wire [4:0] reserve_price=!(first_s && n_block!=i_prepare_addr[31:5]) ? 5'd2 : 5'd16;
    wire reserve_take=FLOW && i_prepare_valid && i_arm && !rst && !i_redirect
       && i_prepare_addr[31:24]==8'h02 && i_prepare_addr[1:0]==0;
    always_ff @(posedge clk)begin
      if(rst||i_redirect)begin
        reserve_v<=0;reserve_addr<='0;reserve_gen<='0;reserve_left<=0;
      end else begin
        if(reserve_v&&reserve_left!=0)reserve_left<=reserve_left-5'd1;
        if(i_commit_accept&&reserve_match)reserve_v<=0;
        if(reserve_take)begin
          reserve_v<=1;reserve_addr<=i_prepare_addr[31:2];reserve_gen<=if_gen;
          reserve_left<=reserve_price;
        end
      end
    end
''')
    replace("                flow_left <= !(first_s && n_block != i_commit_addr[31:5]) ? 5'd2 : 5'd16;",
            "                flow_left <= reserve_match ? reserve_at_commit : (!(first_s && n_block != i_commit_addr[31:5]) ? 5'd2 : 5'd16);")
    marker='    // simulation (+a7dbg):'
    observer='''    always @(posedge clk)if(!rst)begin
      if(reserve_take)assert(!reserve_v)else $fatal(1,"RESERVE_OVERWRITE");
      if(i_commit_accept&&reserve_v)
        assert(reserve_match)else $fatal(1,"RESERVE_WRONG_COMMIT_OWNER");
      if(i_redirect)assert(!reserve_take&&!i_commit_accept)else $fatal(1,"RESERVE_ON_REDIRECT");
    end
'''
    replace(marker,observer+marker)
    if mutation=='wrong-owner':
        replace('reserve_addr<=i_prepare_addr[31:2];',"reserve_addr<=i_prepare_addr[31:2]^30'd1;")
    elif mutation!='none':raise ValueError(mutation)
    return source
