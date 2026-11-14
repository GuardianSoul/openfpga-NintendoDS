// Deterministic physical image shared by the chip setup and independent oracles.
function automatic [7:0] texture_byte(input integer a);
    return 8'((a*13) ^ (a>>5) ^ (a>>11));
endfunction
function automatic [15:0] palette_half(input integer a);
    return 16'(((a>>1)*117) & 32767);
endfunction
function automatic [31:0] image_word(input logic [23:0] a);
    if(a<24'h20000) return {texture_byte(int'(a)*4+3),texture_byte(int'(a)*4+2),texture_byte(int'(a)*4+1),texture_byte(int'(a)*4)};
    if(a<24'h24000) return {palette_half((int'(a)-'h20000)*4+2),palette_half((int'(a)-'h20000)*4)};
    return 32'hc5a90000 ^ (32'(a)*32'h9e3779b9);
endfunction
function automatic integer chip_index(input logic [23:0] a);
    return int'({a[22:21],a[20:8],a[23],a[7:0],1'b0});
endfunction
