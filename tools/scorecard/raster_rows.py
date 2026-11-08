#!/usr/bin/env python3
"""Raster rows for the unit scorecard, from Pocket-model runs with +g3dperf.

    raster_rows.py RUNLOG [RUNLOG ...]

The DS's 3D line budget (docs/ds-rules.md row 56, hwref run 24): about 8.0
system ticks per polygon a line plus 0.99 per pixel. nds_gpu3d's +g3dperf
prints each rendered frame's raster cycles by phase (raster clock = 2 system
ticks), its spans (a span is one polygon on one line) and its pixels. Per
polygon a line: the edge and span phases over the spans; per pixel: the pixel
phase over the pixels, over every frame of every log given, in system ticks
next to the DS's. (Not the stream phase, which also counts the waits for the
line ring's lead, nor the final pass, which runs beside the raster.) It also prints the worst frame's cycles and the
pixel phase's pixels per raster clock.
"""
import re
import sys

PAT = re.compile(r'g3dperf cyc (\d+) idle (\d+) clear (\d+) stream (\d+) edge (\d+) span (\d+) pixel (\d+) '
                 r'final (\d+) spans (\d+) px (\d+)')
DS_POLY, DS_PX = 8.0, 0.99        # system ticks (ds-rules row 56)


def main():
    rows = []
    for f in sys.argv[1:]:
        for l in open(f, errors='replace'):
            m = PAT.search(l)
            if m:
                cyc, idle, clr, stream, edge, span, pixel, final, spans, px = map(int, m.groups())
                if spans:
                    rows.append((edge + span + pixel, spans, px, pixel, cyc, edge + span))
    if len(rows) < 2:
        sys.exit('raster_rows: fewer than two frames with spans (run with --plus g3dperf)')
    # per polygon a line: the edge and span phases over the spans; per pixel:
    # the pixel phase over the pixels (a frame's spans and pixels move
    # together, so a fit of both cannot separate them)
    e_s = sum(r[5] for r in rows); s_n = sum(r[1] for r in rows)
    p_c = sum(r[3] for r in rows); p_n = sum(r[2] for r in rows)
    a = e_s / s_n / 2                          # raster clocks -> system ticks
    b = p_c / p_n / 2
    pxc = p_n / max(1, p_c)
    print(f'frames {len(rows)}; worst frame {max(r[4] for r in rows)} raster clocks (frame: 1,120,380)')
    print(f'| raster: per polygon a line | {DS_POLY:.2f} | {a:.2f} | {a / DS_POLY:.2f} |')
    print(f'| raster: per pixel | {DS_PX:.2f} | {b:.2f} | {b / DS_PX:.2f} |')
    print(f'pixel phase: {pxc:.3f} pixels a raster clock')


if __name__ == '__main__':
    main()
