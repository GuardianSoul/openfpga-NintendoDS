"""Pointer-free prior-render records and list images for the qualified importer.

Uses the established packed record layout and polygon-local Z/W. Source state
is read only; inactive native RAM is not inferred from emulator struct padding.
"""
import json


def bits(value,width,name):
    if not isinstance(value,int) or not 0<=value<(1<<width):
        raise ValueError(f'{name} is outside its native{width}-bit field: {value}')
    return value


def header(poly,base):
    value=bits(poly['Attr'],32,'Attr')|bits(poly['TexParam'],32,'TexParam')<<32
    for name,width,shift in [('TexPalette',13,64),('NumVertices',4,77),('VTop',4,81),('VBottom',4,85),('YTop',8,89),('YBottom',8,97)]:
        value|=bits(poly[name],width,name)<<shift
    value|=int(bool(poly['FacingView']))<<105|int(bool(poly['WBuffer']))<<106
    value|=int(bool(poly['Degenerate'])or poly['YBottom']>=193)<<107|bits(base,13,'native vertex occurrence base')<<115
    return value


def vertex(poly,index,source):
    x,y=source['FinalPosition']
    value=bits(x,9,'FinalX')|bits(y,8,'FinalY')<<9|bits(poly['FinalZ'][index],24,'FinalZ')<<17|bits(poly['FinalW'][index],16,'FinalW')<<41
    for color,shift in zip(source['FinalColor'],[57,66,75]):
        value|=bits(color,9,'FinalColor')<<shift
    for coord,shift in zip(source['TexCoords'],[84,100]):
        if not -32768<=coord<=32767:raise ValueError('texture coordinate outside signed16')
        value|=(coord&65535)<<shift
    return value


def write_images(g,out):
    if g['NumVertices']or g['NumPolygons']:raise ValueError('current geometry bank is not empty')
    bank=1-g['CurRAMBank'];count=g['RenderNumPolygons'];offset=bank*2048
    if not 0<=count<=2048:raise ValueError('prior polygon count outside DS capacity')
    vertices={v['index']:v for v in g['vertices']};polys={p['index']-offset:p for p in g['polygons']}
    order=[v-offset for v in g['render_order']]
    if sorted(polys)!=list(range(count))or sorted(order)!=list(range(count)):
        raise ValueError('prior records/order are not one complete captured bank')
    cursor=0;records=[];ytab=[]
    for index in range(count):
        p=polys[index];value=header(p,cursor);records.append((bank*8192+index,value));ytab.append(((value>>107)&1)<<16|p['YTop']<<8|p['YBottom'])
        if len(p['vertex_indices'])!=p['NumVertices']:raise ValueError('polygon vertex count differs')
        for n,vi in enumerate(p['vertex_indices']):
            records.append((bank*8192+2048+cursor,vertex(p,n,vertices[vi])));cursor+=1
    if cursor>6144:raise ValueError('prior vertex occurrences exceed DS capacity')
    records.sort();words=[]
    for address,value in records:
        physical=[value>>(32*n)&0xffffffff for n in [0,1,3,2]]
        if(address%8192)<2048:
            if physical[2]&0x7f000:raise ValueError('header padding not representable by packed RAM')
        elif physical[2]>>20:raise ValueError('vertex padding not representable by packed RAM')
        words+=physical
    buckets=[0]*256;links=[0]*2048
    for position,index in enumerate(order):
        p=polys[index]
        if ytab[index]>>16 or p['YTop']>=192:continue
        y=p['YTop'];old=buckets[y]
        if old>>22:
            links[old&2047]=position;buckets[y]=(1<<22)|(old&(2047<<11))|position
        else:buckets[y]=(1<<22)|(position<<11)|position
    stream=[];heads=0
    for y in range(192):
        for index in order:
            p=polys[index]
            if p['Degenerate']or p['YBottom']>=193 or p['YTop']>y or not(y<p['YBottom']or y==p['YBottom']==p['YTop']):continue
            stream.append((0,header(p,0)&((1<<107)-1)));heads+=1
            for n,vi in enumerate(p['vertex_indices']):stream.append((1,vertex(p,n,vertices[vi])))
        stream.append((3,0))
    images={'record-addresses':([a for a,v in records],4),'record-words':(words,8),'order':(order,8),'ytab':(ytab,8),'buckets':(buckets,8),'links':(links,8),'stream-type':([t for t,v in stream],1),'stream-data':([v for t,v in stream],32)}
    for name,(values,width)in images.items():(out/(name+'.hex')).write_text(''.join(f'{v:0{width}x}\n'for v in values))
    c=g['PosMatrix'];p=g['ProjMatrix'];clip=[(sum(c[(n//4)*4+k]*p[k*4+n%4]for k in range(4))>>12)&0xffffffff for n in range(16)]
    (out/'expected-clip.hex').write_text(''.join(f'{v:08x}\n'for v in clip))
    report=dict(count=len(records),polygons=count,unique_vertices=len(vertices),vertex_occurrences=cursor,stream_beats=len(stream),polygon_line_headers=heads,lines=192,render_bank=bank,current_bank=g['CurRAMBank'],scope='prior input records/stream oracle, not raster framebuffer publication or DS timing law')
    (out/'records.json').write_text(json.dumps(report,indent=2)+'\n')
    return report
