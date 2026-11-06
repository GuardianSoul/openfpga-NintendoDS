#!/usr/bin/env python3
"""Draw the DS platform image (521x165) for the Pocket.

A silver DS Lite with its stylus, placed like openfpga-PlayStation's PlayStation banner
(support/pocket-art/draw_banner.py there): no logos, no text. The view is an
orthographic one from the front left with clean pixel axes: the width steps
four pixels across for one down, the depth runs at 45 degrees and verticals
stay vertical. tools/ds/package.py converts support/pocket-art/ds-banner.png
with tools/ds/pocket_image.py.

  python3 support/pocket-art/draw_banner.py support/pocket-art/ds-banner.png

The solids are signed distance fields, ray-marched once per pixel centre along
the projection's view direction, so rounded corners, filleted edges, the
hinge's domed knuckles and the recesses all come from one model and one light.
Small marks (speaker holes, microphone) are stamped per pixel so they stay
identical, and the stylus is drawn last in screen space.
"""
import math, sys
import numpy as np
from PIL import Image
# model: X = depth (0 back .. front), Y = width (0 right end .. left end), Z up
# camera: the width steps WS = 3 pixels across for one down and the depth runs at
# 45 degrees, so tan(azimuth) = sin(elevation) = 1/sqrt(WS); 1 pixel per unit
WS=3
TF=1/math.sqrt(WS); SF,CF=TF/math.sqrt(1+TF*TF),1/math.sqrt(1+TF*TF); SE=TF; CE=math.sqrt(1-SE*SE)
M=np.array(((SF,-CF,0),(CF*SE,SF*SE,-CE)))
def P(v): return (400+M[0]@v, 200+M[1]@v)
def unit(v): v=np.asarray(v,float); return v/np.linalg.norm(v)
VIEW=np.array((CF*CE,SF*CE,SE))           # towards the viewer: M @ VIEW = 0
# silver, lit from the upper left; shade = BASE + n.G
BASE,G=130,np.array((40,24,76.0))         # top 206, front 170, left end 154
HALF=unit(unit(G)+VIEW)
S=1.05                                    # model units per mm
mm=lambda v: v*S

# DS Lite, mm: 133 x 74 halves, the base 11.5 thick and the lid 8, 3" screens
W,D,T,TL=mm(133),mm(74),mm(11.5),mm(8)
RC=mm(6)                                  # plan corner radius
FB,FL=mm(1.2),mm(1.0)                     # edge fillets: base, lid
RH=mm(4.4)                                # hinge barrel radius
WF=-mm(1)                                 # the lid's inner face, just behind the hinge axis: the barrel stands in front
HO=np.array((RH,0,T))                     # hinge axis, barrel flush with the back
KL,KR,GAP=mm(15),mm(11),mm(1)             # the base's knuckles: long at the left end, short at the right
# the lid opens near 120 degrees, at the angle where its side edges step
# exactly one pixel across for K up: tan = (cos(az) sin(el) - K sin(az)) / cos(el)
K=min(range(1,20),key=lambda k:abs(math.atan2(-(CF*SE-k*SF),-CE)-math.radians(120)))
ANG=math.atan2(-(CF*SE-K*SF),-CE)
LV=np.array((math.cos(ANG),0,math.sin(ANG)))   # up the lid from the hinge
LN=np.array((math.sin(ANG),0,-math.cos(ANG)))  # lid inner face normal
BC=mm(39.5)                               # lower screen centre, from the back
# closed, the lid's top edge meets the base's front: it reaches D - RH from the axis
LT=D-RH
SC=LT-mm(8+26.25)                         # upper screen centre: the plate 8 mm below the lid's top edge

# ---- distance functions; p is a (3, n) array ----
def rect(u,v,cu,cv,hu,hv,r):
    qu=abs(u-cu)-hu+r; qv=abs(v-cv)-hv+r
    return np.hypot(np.maximum(qu,0),np.maximum(qv,0))+np.minimum(np.maximum(qu,qv),0)-r
def extrude(d2,w,w0,w1,f):
    """A 2D field extruded over w0..w1 with fillet f on both edges."""
    a=d2+f; b=abs(w-(w0+w1)/2)-(w1-w0)/2+f
    return np.hypot(np.maximum(a,0),np.maximum(b,0))+np.minimum(np.maximum(a,b),0)-f
def box(x,y,z,x0,x1,y0,y1,z0,z1,f=0.3):
    return extrude(rect(y,x,(y0+y1)/2,(x0+x1)/2,(y1-y0)/2,(x1-x0)/2,f),z,z0,z1,f)
def lidframe(p):
    r=p-HO[:,None]
    return r[1], LV@r, LN@r               # across, up the lid, out of its face

def parts(p):
    """The solids, and zones: volumes that colour the surface found inside them."""
    x,y,z=p
    d={}; zone={}
    # rounded top edges; the bottom ones sit below z = 0, so the front stays tall enough for the slot
    shell=np.maximum(extrude(rect(y,x,W/2,D/2,W/2,D/2,RC),z,-FB,T,FB),-z)
    base=shell
    # L and R: shoulder buttons along the back corners' full height, under the knuckles (the maintainer's edit)
    sh=np.minimum(*[box(x,y,z,-mm(2),mm(7),yy-mm(18),yy+mm(18),mm(0.8),T+1,mm(0.6)) for yy in (0,W)])
    base=np.maximum(base,-(sh-mm(0.5)))
    d['shoulder']=np.maximum(sh,shell-mm(0.3))                  # standing a little proud of the shell
    # the front: the GBA slot cover, inset in the lower shell (the 57 mm slot
    # measured on the green reference against the lower glass's edges, at
    # W/2 -+ 31). The volume slider and the jack measured on the maintainer's front-on
    # photo of his DS Lite (15.2 px/mm): the slider 12.5-25.3 mm from the left
    # end, 3.1-6.2 mm up, its knob 14.9-20.8 mm; the jack a keyhole, a slot
    # 14.2-23.1 mm from the right end running into a larger round hole at 13.2 mm
    gba=box(x,y,z,D-mm(0.9),D+5,W/2-mm(32),W/2+mm(32),mm(1.2),mm(5.8),mm(0.4))   # centred under the lower glass as seen
    vol=box(x,y,z,D-mm(1.5),D+5,W-mm(25.3),W-mm(12.5),mm(3.1),mm(6.2),mm(0.1))
    base=np.maximum(base,-np.minimum(gba,vol))   # (the jack is a pixel sprite, below)
    zone['gba']=gba-mm(0.5); zone['vol']=vol-mm(0.2)
    d['knob']=box(x,y,z,D-mm(2),D-mm(0.3),W-mm(20.8),W-mm(14.9),mm(3.1),mm(6.2),mm(0.2))
    # the lower screen's plate: flat in the model, its bevel shaded from the
    # distance to its edge (a raised step is under a pixel and breaks up into
    # dots); the glass sits a step down inside it
    glass=extrude(rect(y,x,W/2,BC,mm(31),mm(23),mm(0.5)),z,T-mm(0.4),T+9,0)
    d['base']=np.maximum(base,-glass)
    zone['plate']=np.maximum(rect(y,x,W/2,BC,mm(34.5),mm(26.25),mm(3)),abs(z-T)-mm(1))
    zone['rim']=np.full_like(x,9e9)      # (the upper plate's solid edge, below; the lower one is bevelled)
    zone['glass']=rect(y,x,W/2,BC,mm(31),mm(23),mm(0.5))+0.4   # the glass, not the recess's walls
    # D-pad (A B X Y, START and SELECT are pixel sprites, below)
    dp=(W-mm(17),mm(36.5))                # (y, x)
    cross=np.minimum(rect(y,x,*dp,mm(8),mm(2.9),mm(0.8)),rect(y,x,*dp,mm(2.9),mm(8),mm(0.8)))
    btn=extrude(cross,z,T-1,T+mm(1.6),mm(0.6))
    d['button']=btn
    # hinge: the base's knuckles at both ends with domed outer ends, the lid's between
    hr=np.hypot(x-HO[0],z-HO[2])-RH
    def knuckle(y0,y1,dome):
        """Crisp at the gap, at y0; domed at the device's side, at y1 (when dome)."""
        crisp=extrude(hr,y,min(y0,y1),max(y0,y1),mm(0.8))
        if not dome: return crisp
        k=math.copysign(2*RH,y1-y0)
        body=extrude(hr,y,min(y0,y1-k),max(y0,y1-k),mm(0.8))
        return np.minimum(body,extrude(hr,y,min(y0,y1),max(y0,y1),RH*0.85))
    right=knuckle(KR,mm(0.4),True)
    for g in (mm(3.2),mm(5.2)):           # two grooves round the right knuckle
        right=np.maximum(right,-extrude(hr+mm(0.5),y,g-mm(0.4),g+mm(0.4),0))
    d['hinge']=np.minimum.reduce([right,knuckle(KR+GAP,W-KL-GAP,False),knuckle(W-KL,W-mm(0.4),True)])
    d['hinge']=np.maximum(d['hinge'],T-mm(1)-z)                   # above the shoulder buttons
    # lid: full width down to the barrel, which covers its lower edge
    s,t,w=lidframe(p)
    # above the outer knuckles the lid stops a little short, leaving a gap; between
    # them it runs on down into its own barrel
    t0=RH+mm(0.4)
    LW=W/2-mm(2)                          # half-width: the sides in line with the knuckles' domed ends
    upper=rect(s,t,W/2,(t0+LT)/2,LW,(LT-t0)/2,RC)
    lower=rect(s,t,W/2,(t0+LT)/2,LW,(LT-t0)/2,mm(1))
    panel=np.where(t>LT/2,upper,lower)    # rounded at the top, nearly square above the knuckles
    tongue=rect(s,t,(KR+W-KL)/2,t0/2,(W-KL-KR)/2-GAP,t0/2+mm(1),0)
    lid2=np.minimum(panel,tongue)
    # behind the gap: the lid's body, set back and in shadow, so the gap reads as a dark line
    back=extrude(rect(s,t,W/2,(t0-RC)/2,W/2-mm(4),(t0+RC)/2,0),w,WF-TL,WF-mm(2.5),0)
    zone["gap"]=np.maximum(rect(s,t,W/2,(t0-RC)/2,W/2-mm(4),(t0+RC)/2+0.3,0),w-(WF-mm(2.4)))
    lid=np.minimum(extrude(lid2,w,WF-TL,WF,FL),back)
    # the face sits 0.6 mm inside a lip along the top and sides: 1.5 mm, wider on
    # the right (2.7 mm), where the view would otherwise hide it
    pocket=extrude(rect(s,t,W/2+mm(0.6),(LT-mm(1.5))/2,W/2-mm(4.1),(LT-mm(1.5))/2,RC-mm(1.5)),w,WF-mm(0.6),WF+9,0)
    lid=np.maximum(lid,-pocket)
    # four small square pads beside the screen plate's corners
    for ps in (W/2-mm(48),W/2+mm(48)):
        for pt in (SC+mm(23.5),SC-mm(23.5)):
            lid=np.minimum(lid,extrude(rect(s,t,ps,pt,mm(1.6),mm(1.6),mm(0.4)),w,WF-mm(1),WF-mm(0.6)+mm(0.5),mm(0.15)))
            zone['pad']=np.minimum(zone.get('pad',9e9),rect(s,t,ps,pt,mm(1.6),mm(1.6),mm(0.4))+np.maximum(0,abs(w-WF)-mm(2)))
    uplate=extrude(rect(s,t,W/2,SC,mm(34.5),mm(26.25),mm(1.5)),w,WF-1,WF+mm(0.6),mm(0.2))
    uglass=extrude(rect(s,t,W/2,SC,mm(31),mm(23),mm(0.5)),w,WF,WF+9,0)
    d['lid']=np.maximum(np.minimum(lid,uplate),-uglass)
    zone['plate']=np.minimum(zone['plate'],uplate)
    zone['rim']=np.minimum(zone['rim'],np.maximum(abs(rect(s,t,W/2,SC,mm(34.5),mm(26.25),mm(1.5)))-0.7,abs(w-WF)-mm(1)))
    zone['uglass']=rect(s,t,W/2,SC,mm(31),mm(23),mm(0.5))+0.4
    return d,zone
def scene(p): return np.minimum.reduce(list(parts(p)[0].values()))

# ---- ray march every pixel centre of the drawing area ----
X0,X1,Y0,Y1=150,560,40,330
py,px=np.mgrid[Y0:Y1,X0:X1]
sx=(px+0.5-400).ravel(); sy=(py+0.5-200).ravel()
xy=np.linalg.solve(M[:,:2],np.stack((sx,sy)))
p0=np.vstack((xy,np.zeros_like(sx)))      # each pixel centre's point on z = 0
pos=p0+VIEW[:,None]*200
hit=np.zeros(sx.size,bool); live=np.ones(sx.size,bool)
for _ in range(400):
    i=np.flatnonzero(live)
    if not i.size: break
    dist=scene(pos[:,i])
    pos[:,i]-=VIEW[:,None]*dist
    hit[i[dist<0.01]]=True; live[i[(dist<0.01)|(VIEW@pos[:,i]<-250)]]=False
q=pos[:,hit]
e=0.05; n=np.stack([scene(q+e*np.eye(3)[k][:,None])-scene(q-e*np.eye(3)[k][:,None]) for k in range(3)])
n/=np.linalg.norm(n,axis=0)
d,zone=parts(q); names=list(d); mat=np.argmin(np.stack([d[k] for k in names]),axis=0)
TOP_=BASE+G[2]
shade_front=BASE+G[0]
BTN=186                                   # the buttons' and the D-pad's grey cap, a little darker than the body
col=np.maximum(BASE+G@n,BASE+14)+46*np.clip(HALF@n,0,1)**24   # body, fillet highlight; no dark rims
def where(k): return mat==names.index(k) if k in d else zone[k]<0.05
col[where('plate')]-=7
# round the lower plate: screen, frame, then a broad 4.5 mm slope standing up out
# of the body: lit along the back and left edges (up and left on screen), in
# shadow along the front and right, fading out away from the frame
dy=abs(q[1]-W/2)-mm(34.5); dx=abs(q[0]-BC)-mm(26.25)
edge=rect(q[1],q[0],W/2,BC,mm(34.5),mm(26.25),mm(3))   # round at the corners
bev=(0.5+0.5*np.cos(np.pi*np.clip(edge/mm(4.5),0,1)))*(edge>0)*(abs(q[2]-T)<mm(0.2))*(mat==names.index('base'))
lit=np.where(dx>dy,q[0]<BC,q[1]>W/2)
col+=np.where(lit,24,-34)*bev
# the lid's face sinks inside its lip: a soft 6 mm band inside the lip's edge,
# in shadow along the top and both sides
ls,lt,lw=lidframe(q)
inside=-rect(ls,lt,W/2+mm(0.6),(LT-mm(1.5))/2,W/2-mm(4.1),(LT-mm(1.5))/2,RC-mm(1.5))
face=(mat==names.index('lid'))&(abs(lw-(WF-mm(0.6)))<mm(0.15))
band=(0.5+0.5*np.cos(np.pi*np.clip(inside/mm(6),0,1)))*(inside>0)*face
right=ls-mm(4.7)<inside+0.01                 # the right side is the nearest edge
col-=np.where(right,27,36)*band            # lighter there, where it faces the light more
wall=(mat==names.index('lid'))&(abs(inside)<mm(0.5))&(abs(LN@n)<0.95)&(lw>WF-mm(0.8))
col[wall]=BASE+G@LN                         # the lip's inner wall, under a pixel wide: plain lid colour
col[where('pad')]-=16
col[where('gap')&(mat==names.index('lid'))]=104
col[where('button')]+=BTN-TOP_                 # the D-pad: the buttons' grey
col[where('shoulder')]-=56
col[where('gba')]=shade_front-16                # flat: no lit lip along its foot
col[where('vol')&(mat!=names.index('knob'))]=TOP_-92
col[where('knob')]=BTN+6
for g in ('glass','uglass'):
    k=where(g)
    u,v=(q[1],q[0]) if g=='glass' else lidframe(q)[:2]
    a=np.clip(((u-W/2)/mm(31)+1)/2,0,1); b=np.clip(((v-(BC if g=='glass' else SC))/mm(23)+1)/2,0,1)
    if g=='uglass': b=1-b
    sheen=np.clip((0.55*a+0.45*b-0.35)/0.65,0,1)**1.5   # light towards the near corner
    col[k]=(66+58*sheen)[k]
col[where('rim')&~where('button')]=np.minimum(col,BASE+40)[where('rim')&~where('button')]
img=np.full((400,800),255.0)
img[py.ravel()[hit],px.ravel()[hit]]=np.clip(col,0,255)
img=Image.fromarray(img.astype(np.uint8))

# ---- A B X Y and START, SELECT: one pixel sprite each, stamped at whole-pixel
# centres so every button has the same shape (a highlit rim, the cap, the side) ----
SPRITES={'face':[".aaaaa.","abbbbba","abbbbba","cbbbbbc",".ccccc."],'small':[".aaa.","abbba","cbbbc",".ccc."]}
SHADE={'a':BTN+14,'b':BTN,'c':BTN-40}
AB=(mm(15),mm(34.5))                      # (y, x) of the face buttons' centre
buttons=[('face',AB[1]+mm(dx),AB[0]+mm(dy)) for dy,dx in ((0,-7),(0,7),(-7,0),(7,0))]
buttons+=[('small',BC+mm(22.5-6*k),W/2-mm(34.5+6.5)) for k in (1,0)]   # START, SELECT: right of the screen plate, toward its front corner
for kind,bx,by in sorted(buttons,key=lambda b:P(np.array((b[1],b[2],T)))[1]):   # back to front
    spr=SPRITES[kind]; cx,cy=P(np.array((bx,by,T)))
    x0=round(cx-len(spr[0])/2); y0=round(cy-len(spr)/2)
    for j,row in enumerate(spr):
        for i,ch in enumerate(row):
            if ch!='.': img.putpixel((x0+i,y0+j),SHADE[ch])

# the headphone jack: its round hole is only 4 px across, so it is drawn by hand,
# the slot running down to the left along the front's 3:1 slope
JACK=[".........XX.",                       # a round hole; the slot a 2 px line whose
      "........XXXX",                       # bottom is one straight 3:1 step
      "........XXXX",
      "......XXXXXX",
      "...XXXXXX...",
      "...XXX......"]
cx,cy=P(np.array((D,mm(13.2),mm(5.6))))   # the hole's centre, at sprite (9.5, 1.5)
for j,row in enumerate(JACK):
    for i,ch in enumerate(row):
        if ch=='X': img.putpixel((round(cx-10)+i,round(cy-2)+1+j),52)

# ---- stamped marks: identical speaker holes, two rows of three; the microphone ----
LO=HO+LN*(WF-mm(0.6))                  # the lid face, inside its lip
for yc in (mm(17),W-mm(17)):
    x,y=P(LO+LV*SC+np.array((0,yc,0)))
    for r in (0,1):
        for k in (-1,0,1):                # 2 x 2 px holes: 4 px apart along a row (the
            for i in (0,1):               # width's 4:1 step), rows 4 px apart up the lid
                for j in (0,1):
                    img.putpixel((round(x)-4*k-r+i,round(y)+k-4*r+j),76)
# the microphone: a short slot on the barrel a little right of its middle, centred
# on the barrel's visible height there and tilted with the barrel's curve (on
# screen its circumference steps one pixel across for three up)
x=round(P(HO+np.array((0,W/2-mm(4),0)))[0])
mimg=np.full((400,800),-1); mimg[py.ravel()[hit],px.ravel()[hit]]=mat
rows=np.flatnonzero(mimg[:,x]==names.index('hinge'))
yc=(rows.min()+rows.max())/2
for dx,j in ((0,1),(0,0),(0,-1),(-1,-2)): img.putpixel((x+dx,round(yc+j-0.01)),60)

# ---- stylus: its tip on the lower screen, leaning back to the right; on screen
# it rises exactly three pixels for one across; a wider cap at its top ----
WHITE,TOP=246,BASE+G[2]
TIP=(BC+mm(8),W/2-mm(20),T+mm(0.5))
DIR=(-0.1,-0.6,0.0); DIR=unit((*DIR[:2],(M[1,:2]@DIR[:2]+3*(M[0,:2]@DIR[:2]))/CE))
LEN,RS=mm(87.5),mm(2.3)
def stylus():
    a=P(TIP); b=P(np.array(TIP)+DIR*LEN)
    dx,dy=b[0]-a[0],b[1]-a[1]; l=math.hypot(dx,dy); ux,uy=dx/l,dy/l
    w=RS*0.8                                # screen half-width
    for py_ in range(int(min(a[1],b[1])-w-2),int(max(a[1],b[1])+w+3)):
        for px_ in range(int(min(a[0],b[0])-w-2),int(max(a[0],b[0])+w+3)):
            rx,ry=px_+0.5-a[0],py_+0.5-a[1]
            u=rx*ux+ry*uy; v=-rx*uy+ry*ux       # along, across (positive = left of the axis)
            if u<0 or u>l: continue
            f=u/l
            hw=w*min(1,0.25+f*l/6)              # tapered tip over the first 6 px
            cap=f>0.86                          # the cap: wider, its end cut square
            if cap: hw=w*1.45
            if f>0.985: hw=w*max(0,(1-f)/0.015)**0.3*(1.45 if cap else 1)
            if abs(v)>hw: continue
            k=v/hw                              # -1 .. 1 across, light from the left
            c=WHITE-8-int(48*max(0,-k)**1.4)+int(6*max(0,k))
            if abs(v)>hw-0.8: c=min(c,TOP-50)   # soft outline against the lid
            if f<0.06: c=c-50                   # dark tip
            if 0.855<f<0.875: c=c-30            # the cap's seam
            img.putpixel((px_,py_),max(0,min(255,int(c))))
stylus()

bb=Image.eval(img,lambda v:255-v).getbbox()        # device alone sets the placement
out=Image.new('L',(521,165),255); out.paste(img.crop(bb),(131+(229-(bb[2]-bb[0]))//2,160-(bb[3]-bb[1])))
out.save(sys.argv[1]); print(bb)
