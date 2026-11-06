import sys,struct
from collections import Counter
D4,D6,D7=sys.argv[1:4]
def L(d,n): return struct.unpack('<49152H',open(f'{d}/rules3d_{n}_3d.bin','rb').read())
sets=[]
bx=L(D4,'tex_big_x')
for i in range(1,24):
    s0=-32768+i*1237; s1=32767-i*2011
    if i&1: s0,s1=s1,s0
    x0=(i*3)%5; x1=256-(i*7)%9; xd=x1-x0; y=i*8+3
    for k in range(xd):
        if x0+k<=255: sets.append(('bx',s0,s1,k,xd,(bx[y*256+x0+k]&31),0))
by=L(D4,'tex_big_y')
for j in range(1,16):
    t0=-32768+j*3001; t1=32767-j*1733; x0=j*16; y0=(j*3)%7; y1=192-(j*5)%11
    if j&1: t0,t1=t1,t0
    for y in range(y0,min(y1,192)): sets.append(('by',t0,t1,y-y0,y1-y0,(by[y*256+x0+7]>>5)&31,0))
pt=L(D4,'persp_t')
for j in (0,5,10,15):
    t1=(32+j*13)*16
    for y in range(192): sets.append(('pt',0,t1,y,192,(pt[y*256+j*16+7]>>5)&31,1))
ts=L(D4,'toon_span'); spn=L(D4,'span')
w=[1,2,3,4,5,7,8,15,16,17,31,32,33,63,64,65,100,127,128,129,200,240,255,256]
for i in range(24):
    x0=(i*5)%7; x1=x0+w[i]
    if x1>256: x0,x1=0,256
    y=i*8+3
    for x in range(x0,min(x1,256)):
        if ts[y*256+x]&0x8000: sets.append(('toon',0,496,x-x0,x1-x0,ts[y*256+x]&31,2))
        if spn[y*256+x]&0x8000: sets.append(('span',0,511,x-x0,x1-x0,spn[y*256+x]&31,2))
sp=L(D6,'subpix_step')
for r in range(12):
    y0=r*16+2
    for o in range(16):
        x0=o*16+2
        for k in range(9):
            sets.append(('sub',0,2304,k,9,sp[(y0+3)*256+x0+k]&31,0))
            sets.append(('sub',0,2304,k,9,(sp[(y0+k)*256+x0+3]>>5)&31,0))
te=L(D7,'tex_exact')
for i in range(24):
    for c in range(4):
        Ln=3+((i+c*5)%12)*2; m=1+(i*4+c*37)%150
        if Ln*256*m>65000: m=65000//(Ln*256)
        x0=c*64+1; y=i*8+3
        s0=-32768+(i*911+c*4093)%4096*16; s1=s0+Ln*256*m
        if s1>32767: s1=32767-((32767-s0)%(Ln*256))
        for k in range(Ln): sets.append(('tex',s0,s1,k,Ln,te[y*256+x0+k]&31,0))
ty=L(D7,'tex_exact_y')
for j in range(32):
    for r in range(3):
        Ln=3+((j+r*7)%12)*2; m=1+(j*5+r*41)%150
        if Ln*256*m>65000: m=65000//(Ln*256)
        x0=j*8; y0=r*64+1
        t0=-32768+(j*577+r*2111)%4096*16; t1=t0+Ln*256*m
        if t1>32767: t1=32767-((32767-t0)%(Ln*256))
        for k in range(Ln): sets.append(('tey',t0,t1,k,Ln,(ty[(y0+k)*256+x0+3]>>5)&31,0))
def obs(kind,v):
    if kind==0: return (v>>4)&31
    if kind==1:
        i=v>>4; return (31-(i&31)) if (i&32) else (i&31)
    return v>>4
def evalm(fn):
    bad=Counter()
    for tag,a,b,k,d,e,kind in sets:
        dd=abs(b-a); kk=k if a<b else d-k
        v=min(a,b)+fn(dd,kk,d)
        if obs(kind,v)!=e: bad[tag]+=1
    return sum(bad.values()),dict(bad)
res=[]
for K in range(24,36):
    def f1(dd,kk,d,K=K):
        P=max(1,K-dd.bit_length()); return (dd*((kk<<P)//d))>>P
    res.append((evalm(f1),'P=K-bits(d)',K))
for N in range(8,17):
  for P in (17,20,23):
    def f2(dd,kk,d,N=N,P=P):
        s=max(0,dd.bit_length()-N); return ((dd>>s)*((kk<<P)//d)>>P)<<s
    res.append((evalm(f2),'d>>s to N bits, P',(N,P)))
res.sort(key=lambda r:r[0][0]); [print(r) for r in res[:8]]
print('---')
res=[]
for K in range(26,42):
    def g1(dd,kk,d,K=K):
        P=max(1,K-dd.bit_length()); f=kk*(((1<<P)+d//2)//d); return (dd*f)>>P
    def g2(dd,kk,d,K=K):
        P=max(1,K-dd.bit_length()); f=((kk<<P)+d//2)//d; return (dd*f)>>P
    def g3(dd,kk,d,K=K):
        P=max(1,K-dd.bit_length()); f=kk*(-(-(1<<P)//d)); return (dd*f)>>P
    res.append((evalm(g1),'nearest recip, P=K-bits(d)',K))
    res.append((evalm(g2),'nearest per-pixel, P=K-bits(d)',K))
    res.append((evalm(g3),'ceil recip, P=K-bits(d)',K))
for P in range(18,30):
  for N in range(10,17):
    def g4(dd,kk,d,N=N,P=P):
        s=max(0,dd.bit_length()-N); f=kk*(((1<<P)+d//2)//d); return ((dd>>s)*f>>P)<<s
    res.append((evalm(g4),'nearest recip, d to N bits',(P,N)))
res.sort(key=lambda r:r[0][0]); [print(r) for r in res[:10]]
