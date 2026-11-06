#!/usr/bin/env python3
"""Draw the DS core icon (36x36) for the Pocket.

A DS game card's silhouette, in the style of openfpga-PlayStation's CD icon: black ink
on white, drawn on an 18x18 grid and doubled. The label is left blank (no
logo). tools/ds/package.py converts support/pocket-art/core-icon.png with
tools/ds/pocket_image.py.

  python3 support/pocket-art/draw_icon.py support/pocket-art/core-icon.png
"""
import sys
from PIL import Image
g=[[0]*18 for _ in range(18)]
def fill(x0,x1,y0,y1,v=1):
    for y in range(y0,y1+1):
        for x in range(x0,x1+1): g[y][x]=v
fill(2,15,1,16)                        # the card, 14 x 16 (33 x 35 mm)
g[16][2]=0                             # square corners, but for the lower left one
fill(4,13,3,12,0)                      # the label, blank
g[3][4]=g[3][13]=g[12][4]=g[12][13]=1  # its corners rounded
fill(7,10,14,14,0); fill(8,9,15,15,0)  # the arrow under the label
img=Image.new('L',(18,18),255)
for y in range(18):
    for x in range(18):
        if g[y][x]: img.putpixel((x,y),0)
img.resize((36,36),Image.NEAREST).save(sys.argv[1])
