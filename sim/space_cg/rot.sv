module rot_old(input logic [31:0] b, input logic [4:0] r, output logic [31:0] x);
  always_comb begin
    x = (b >> r) | (b << (6'd32 - {1'b0, r}));
    if (r == 5'd0) x = b;
  end
endmodule
module rot_new(input logic [31:0] b, input logic [4:0] r, output logic [31:0] x);
  always_comb begin
    x = b;
    if (r[4]) x = {x[15:0], x[31:16]};
    if (r[3]) x = {x[7:0],  x[31:8]};
    if (r[2]) x = {x[3:0],  x[31:4]};
    if (r[1]) x = {x[1:0],  x[31:2]};
    if (r[0]) x = {x[0],    x[31:1]};
  end
endmodule
// mutation: the last stage rotates left instead of right
module rot_mut(input logic [31:0] b, input logic [4:0] r, output logic [31:0] x);
  always_comb begin
    x = b;
    if (r[4]) x = {x[15:0], x[31:16]};
    if (r[3]) x = {x[7:0],  x[31:8]};
    if (r[2]) x = {x[3:0],  x[31:4]};
    if (r[1]) x = {x[1:0],  x[31:2]};
    if (r[0]) x = {x[30:0], x[31]};
  end
endmodule
