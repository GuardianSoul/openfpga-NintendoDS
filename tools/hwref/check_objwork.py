#!/usr/bin/env python3
"""Eight-case OBJ producer/return checks; no hardware work budget assumed."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import struct
from check_objlimit import require, binary, code

NAMES=['marker_only','wide_baseline','mixed_count','disabled_gap','right_clip','early_control','normal8bpp','identity_affine']

def descriptor(k):
    count=0 if k==0 else 33 if k==2 else 15 if k==7 else 32
    width=0 if k==2 else 64
    first=2 if k==5 else 0
    m0=0 if k==5 else 15 if k==7 else 33 if k in (2,3) else 32
    return count,width,first,m0,m0+1


def expected_oam(k):
    count,width,first,m0,m1=descriptor(k)
    data=[0]*512
    for i in range(128):data[i*4]=0x0200
    for i in range(count):
        w=(64 if i<30 else 32) if k==2 else width
        at=(first+i)*4
        data[at]=96|0x400|(0x2000 if k==6 else 0x100 if k==7 else 0)
        data[at+1]=((3 if w==64 else 2)<<14)|(224 if k==4 else 0)
        data[at+2]=512 if k==6 else 0
    data[m0*4:m0*4+4]=[96,0xc080,0x1008,0]
    data[m1*4:m1*4+4]=[96,0xc0c0,0x2010,0]
    if k==7:data[3]=data[15]=256
    return data


def expected_inputs():
    palette=[(i&31)|(((i>>3)&31)<<5)|(((i>>1)&31)<<10) for i in range(256)]+[0]*256
    palette[257]=0x001f
    for i in range(1,16):palette[272+i]=i|(31<<5);palette[288+i]=i|(31<<10)
    bg=bytearray(65536)
    for i in range(8192):struct.pack_into('<H',bg,i*2,((i%255)+1)|(((i*7%255)+1)<<8))
    for b in range(4):
        for i in range(1024):struct.pack_into('<H',bg,(28+b)*0x800+i*2,(i+b*23)&255)
    obj=bytearray(24576)
    for base in (0,8,16):
        for y in range(64):
            for x in range(64):
                at=(base+(y//8)*32+x//8)*32+(y%8)*4+(x%8)//2
                obj[at]|=(code(x,y) if base else 1)<<(4*(x&1))
    for y in range(64):
        for x in range(64):obj[(512+(y//8)*32+(x//8)*2)*32+(y%8)*8+(x%8)]=1
    return palette,bytes(bg),bytes(obj)


def marker(image,palette,bank,origin,columns=64,lines=8):
    masks=[];prefix=[]
    for row in range(lines):
        mask=sum(1<<x for x in range(columns) if image[(96+row)*256+origin+x]==(0x8000|palette[256+bank*16+code(x,row)]))
        n=0
        while n<columns and mask&(1<<n):n+=1
        masks.append(mask);prefix.append(n)
    return dict(columns=columns,lines=lines,full=all(m==(1<<columns)-1 for m in masks),
                prefix_columns=prefix,line_masks=[f'{m:016x}'for m in masks],matched_pixels=sum(m.bit_count()for m in masks))


def analyze(directory,software=False):
    require((directory/'objwork_v1_info.txt').read_text().startswith('objwork v1; built '),'producer information differs')
    palette,bg,obj=expected_inputs()
    require(binary(directory/'objwork_v1_pal.bin',1024)==struct.pack('<512H',*palette),'palette input differs')
    require(binary(directory/'objwork_v1_bg.bin',65536)==bg,'BG input differs')
    require(binary(directory/'objwork_v1_obj.bin',24576)==obj,'4bpp/8bpp OBJ input or padding differs')
    rows=list(csv.DictReader((directory/'objwork_v1.csv').open()))
    require([int(r['kind'])for r in rows]==list(range(8)),'eight ordered cases required')
    journal=''.join(f'{v} k{k}\n'for k in range(8)for v in ('start','done'))
    require((directory/'objwork_v1_progress.txt').read_text()==journal,'incomplete journal')
    cases=[];images=[]
    for k,row in enumerate(rows):
        count,width,first,m0,m1=descriptor(k)
        require([int(row[n])for n in ['count','ballast_width','ballast_first','eligible','marker0_index','marker1_index']]==[count,width,first,count+2,m0,m1],'input descriptor differs')
        require(int(row['timeout'])==0 and int(row['capture_control_after'],16)>>31==0 and int(row['start_line'])==192 and 0<=int(row['end_line'])<263 and int(row['capture_ticks'])>0,'capture phase/completion differs')
        stem=f'objwork_v1_k{k}'
        image=struct.unpack('<49152H',binary(directory/(stem+'.bin'),98304));images.append(image)
        actual=struct.unpack('<512H',binary(directory/(stem+'_oam.bin'),1024))
        require(list(actual)==expected_oam(k) and int(row['oam_readback_match'])==1,'actual OAM/affine matrix differs')
        regs={r['field']:int(r['value_hex'],16)for r in csv.DictReader((directory/(stem+'_regs.csv')).open())}
        require(regs['dispcnt']==0x11f00 and regs['dispcnt_b']==0x10080,'display configuration differs')
        require([regs[f'bg{i}_cnt']for i in range(4)]==[0x80|((28+i)<<8)|i for i in range(4)],'BG control differs')
        require(regs['bldcnt']==0x0241 and regs['bldalpha']==0x0808 and regs['mosaic']==regs['master_bright']==0,'blend/mosaic/brightness differs')
        require([regs[f'vramcnt{i}']for i in range(9)]==[0x81,0x82,0x84,0x80,0,0,0,0,0],'VRAM mapping differs')
        markers=[marker(image,palette,1,128),marker(image,palette,2,192,columns=32 if k==4 else 64)]
        if k==0:require(all(marker(image,palette,b,x,lines=64)['full']for b,x in [(1,128),(2,192)]),'full-height marker-only control failed')
        if k==5:require(all(m['full']for m in markers),'early control failed')
        if software:require(all(m['full']for m in markers),'Census full ROI functional check failed')
        cases.append(dict(kind=k,name=NAMES[k],markers=markers,count=count,width=width,first=first,marker_indices=[m0,m1],capture_ticks=int(row['capture_ticks']),
                          ROI_limit='Rcolumns32..63 overlap ballast and are excluded'if k==4 else'full64 columns,common lines96..103'))
    if software:
        require(images[6]==images[1],'solid8bpp scene differs from normal4bpp baseline in Census')
        require(images[7]==images[1],'identity-affine solid scene differs from normal baseline in Census')
    return dict(output_complete=True,inputs_qualified=True,cases=cases,software_full_ROI_check=software,
                byte_ranges_checked=dict(palette=1024,BG=65536,OBJ=24576,each_OAM=1024,each_capture=98304),
                artifact_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in sorted(directory.glob('objwork_v1*'))if p.is_file()},
                scope='input/coverage qualification only; no DS cost law or native acceptance')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);p.add_argument('--software-full-markers',action='store_true');a=p.parse_args()
    print(json.dumps(analyze(a.directory,a.software_full_markers),indent=2)+'\n',end='')
