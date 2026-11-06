// Types shared by the 3D rasterizer's modules.
package gpu3d_pkg;
    // span descriptor: the span stage (gpu3d_front) -> the pixel pipeline
    typedef struct packed {
        logic [31:0]        attr, texparam;
        logic [12:0]        texpal;
        logic               facing, wbuf, lin;
        logic [3:0]         yedge;
        logic signed [11:0] xs;
        logic [2:0]         en;           // segments 1-3 (left edge, inside, right edge)
        logic signed [2:0][11:0] sb, se;  // segment k: [sb[k], se[k])
        logic [15:0]        wl, wr;
        logic [9:0]         xdiff;
        logic [4:0][15:0]   abase;        // r g b s t: min(left, right), modulo 2^16
        logic [4:0][16:0]   ad;           // |right - left|
        logic [4:0]         alt;          // left < right
        logic [4:0][15:0]   aqs;          // linear: ad / xdiff
        logic [4:0][9:0]    ars;          //         ad % xdiff
        logic [23:0]        zbase, dz;
        logic               zlt;
        logic [22:0]        xrecip;
        logic               l_covx, r_covx;
        logic [9:0]         l_cstart, r_cstart, l_cinc, r_cinc;
        logic [4:0]         l_cov5, r_cov5;
        // DS_TOON: toon/highlight polygon, and red without the vertex colours'
        // 0xF fill as a sixth attribute (the toon index)
        logic               toon, talt;
        logic [8:0]         tbase;
        logic [9:0]         tad;
        logic               lp;           // its line's parity (gpu3d_raster LOV)
    } span_t;
endpackage
