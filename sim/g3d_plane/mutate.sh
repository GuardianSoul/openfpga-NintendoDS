#!/usr/bin/env bash
# Mutations of rtl/ds/nds_g3d_plane.sv that tb_plane must catch.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd); cd "$root"
V=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
miss=0
while IFS='|' read -r name expr; do
  [ -z "$name" ] && continue
  w=build/g3d_plane_mut/$name; rm -rf $w; mkdir -p $w
  sed -e "$expr" rtl/ds/nds_g3d_plane.sv > $w/p.sv
  cmp -s rtl/ds/nds_g3d_plane.sv $w/p.sv && { echo "$name: mutation did not apply"; miss=1; continue; }
  $V --cc --exe --build -j 4 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module nds_g3d_plane --Mdir $w/obj \
     rtl/gpu2d/gpu2d_pkg.sv rtl/gpu2d/gpu2d_ram.sv $w/p.sv $root/sim/g3d_plane/tb_plane.cpp > $w/v.log 2>&1 || { echo "$name: build failed"; miss=1; continue; }
  if $w/obj/Vnds_g3d_plane --frames 20 > $w/run.log; then echo "NOT CAUGHT: $name"; miss=1; else echo "caught: $name ($(tail -1 $w/run.log))"; fi
done <<'LIST'
colour_round|s/return {v, 1'b0} + {5'd0, v != 5'd0};/return {v, 1'b0};/
no_xoff|s/bx = sx\[7:0\] + d_clr2\[23:16\];/bx = sx[7:0];/
no_yoff|s/f_row <= d_clr2\[31:24\] + vcount\[7:0\];/f_row <= vcount[7:0];/
latch_no_geom|s/line_start \&\& vcount == 9'd192 \&\& powcnt1\[3\]/line_start \&\& vcount == 9'd192/
scroll_fill|s/in_q <= xpos\[8\] ? sx\[9\] : !sx\[8\];/in_q <= xpos[8] ? sx[9] : 1'b1;/
render_215|s/vcount == 9'd215 \&\& powcnt1\[2\]/vcount == 9'd192 \&\& powcnt1[2]/
LIST
exit $miss
