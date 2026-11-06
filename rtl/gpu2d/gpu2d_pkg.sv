// NDS 2D engine (docs/2d-engine.md): shared types. One engine, time-shared
// between DS engines A and B line by line.
package gpu2d_pkg;

    // Per-engine line state, as melonDS's GPU2D holds it at the start of a
    // visible line (after UpdateRegistersPreDraw). Written through the state
    // port as 32-bit words; see gpu2d.sv for the word map.
    typedef struct packed {
        logic        enabled;          // POWCNT1 engine enable
        logic        forced_blank;     // ForcedBlank (latched)
        logic        obj_enable;       // OBJEnable (latched)
        logic [4:0]  layer_enable;     // LayerEnable (latched)
        logic [31:0] dispcnt;
        logic [3:0][15:0] bgcnt;
        logic [3:0][15:0] bgxpos;
        logic [3:0][15:0] bgypos;
        logic [1:0][31:0] xref;        // BGXRefInternal[2..3]
        logic [1:0][31:0] yref;
        logic [1:0][15:0] rota;
        logic [1:0][15:0] rotc;
        logic [3:0][7:0]  win0;        // Win0Coords: x1, x2, y1, y2
        logic [3:0][7:0]  win1;
        logic [3:0][7:0]  wincnt;      // in, in1, out, objwin
        logic [1:0]  w0act, w1act;     // Win0Active/Win1Active at line start
        logic [3:0]  bg_mos_w;         // BGMosaicSize[0]
        logic [3:0]  obj_mos_w;        // OBJMosaicSize[0]
        logic [8:0]  bg_mos_line;      // BGMosaicLine
        logic [7:0]  obj_mos_line;     // OBJMosaicLine & 0xFF
        logic [13:0] blendcnt;
        logic [4:0]  eva, evb, evy;    // each <= 16
        logic [15:0] mbright;          // MASTER_BRIGHT
    } eng_state_t;

    // VRAM spaces behind the block port (melonDS's flat views)
    localparam logic [2:0] SP_BG = 3'd0, SP_OBJ = 3'd1, SP_BGEXT = 3'd2,
                           SP_OBJEXT = 3'd3, SP_LCDC = 3'd4,
                           SP_TEX = 3'd5, SP_TPAL = 3'd6;     // 3D texture / texture palette (nds_gpu3d)

    // block address: {space, engine, byte offset[18:5]}
    typedef logic [17:0] blk_t;

    // 18-bit colour as melonDS's renderer keeps it: r[5:0] g[11:6] b[17:12]
    function automatic logic [17:0] c15to18(input logic [15:0] c);
        return {c[14:10], 1'b0, c[9:5], c[15], c[4:0], 1'b0};
    endfunction

endpackage
