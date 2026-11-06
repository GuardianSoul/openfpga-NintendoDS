"""Bind actual accepted packets and fixed glyph trace to immutable AC inputs."""
from pathlib import Path
import argparse,json,re,sys
from PIL import Image

sys.path.insert(0,str(Path(__file__).resolve().parent))
import qualify_g3d_import as q

def packets(text,seed):
    h=re.search(r'ACOBS PRIOR_HDR t(\d+) frame(\d+) bank(\d+) pos(\d+) slot(\d+) y(\d+) data([0-9a-f]+)',text)
    assert h,'missing actual accepted prior header'
    t,frame,bank,pos,slot,y=map(int,h.groups()[:6]);data=int(h[7],16)
    prior=seed['prior_render_bank'];poly=prior['polygons'][prior['order'][pos]]
    assert bank==prior['index']==1 and data==q.header(poly)&((1<<107)-1)
    vertices={v['index']:v for v in prior['vertices']}
    got=re.findall(r'ACOBS PRIOR_VTX t(\d+) i(\d+) data([0-9a-f]+)',text)
    assert len(got)==poly['NumVertices']
    for i,(stamp,index,word) in enumerate(got):
        assert int(index)==i and int(word,16)==q.vertex(poly,i,vertices[poly['vertex_indices'][i]])
    c=re.search(r'ACOBS PRIOR_COMMIT t(\d+) pos(\d+) nv(\d+) top(\d+) bot(\d+) yt(\d+) yb(\d+) face(\d+) w(\d+) mask(\d+) toon(\d+) shd(\d+)',text)
    assert c,'first prior polygon never committed'
    values=list(map(int,c.groups()[1:]));mode=(poly['Attr']>>4)&3
    expected=[pos,poly['NumVertices'],poly['VTop'],poly['VBottom'],poly['YTop'],poly['YBottom'],
              int(poly['FacingView']),int(poly['WBuffer']),int(poly['Attr']&0x3f000030==0x30),int(mode==2),int(mode==3)]
    assert values==expected,(values,expected)
    assert y>=poly['YTop'] and (y<poly['YBottom'] or y==poly['YTop']==poly['YBottom'])
    return dict(frame=frame,bank=bank,order_position=pos,slot=slot,source_polygon=poly['index'],line=y,
        header107_hex=f'{data:032x}',header107_exact=True,vertices116_exact=len(got),
        vertices116_hex=[word for _,_,word in got],commit_attributes_exact=True,time_ps=t)

def rgb(c):return [(c>>(6*i))&63 for i in range(3)]
def pocket(c):
    a=rgb(c)
    return [((v>>1)<<3)|((v>>1)>>2) if i!=1 else (v<<2)|(v>>4) for i,v in enumerate(a)]

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for flag in ['stage','log','shots','baseline-shots','out']:
        p.add_argument('--'+flag,type=Path,required=True)
    a=p.parse_args();b=a.stage
    text=a.log.read_text();seed=q.read_seed(b/'payload/ac21/geometry-seed.json.gz');accepted=packets(text,seed)
    assert 'G3D_SEED_READBACK_PASS:' in text and 'AC21_PREFIX_PASS:' in text
    assert 'AC21_COLD_PREP_RELEASED: after readback before CPU release at 116944588000' in text
    assert 'AC21_FIRST_NATURAL215_PASS: original post-release frame start at 130608923000' in text
    assert 'AC21_PREFIX_ARMED: actual CPU/overlay release at 116944596000' in text
    assert 'import: released at 116950563000, video frame 6' in text
    equivalence=[]
    for raw in range(11):
        original=a.baseline_shots/f'f{raw:03d}.ppm';observed=a.shots/f'f{raw:03d}.ppm'
        assert original.read_bytes()==observed.read_bytes(),f'passive observer changed raw{raw}'
        equivalence.append(dict(raw=raw,sha256=q.digest(observed.read_bytes()),byte_exact=True))
    # Mutate the actual recorded header, not a fixture or second native run.
    h=re.search(r'(ACOBS PRIOR_HDR .*? data)([0-9a-f]+)',text)
    bad=text[:h.start(2)]+format(int(h[2],16)^(1<<32),'032x')+text[h.end(2):]
    try:packets(bad,seed)
    except AssertionError:mutant=dict(bit=32,field='TexParam',original=h[2],mutated=format(int(h[2],16)^(1<<32),'032x'),caught=True)
    else:raise AssertionError('recorded accepted-header texture-bit mutation escaped')
    glyph=[]
    pattern=r'ACOBS GLYPH_S4 t(\d+) frame(\d+) y(\d+) x(\d+) top([0-9a-f]+) tf([0-9a-f]+) sec([0-9a-f]+) sf([0-9a-f]+) ka(\d+) kb(\d+) b63(\d+) word([0-9a-f]+) cnt([0-9a-f]+) eva(\d+) evb(\d+) out([0-9a-f]+)'
    for m in re.finditer(pattern,text):
        t,frame,y,x=map(int,m.groups()[:4]);top,tf,sec,sf=[int(m[i],16) for i in [5,6,7,8]]
        ka,kb,b63=map(int,m.groups()[8:11]);word,cnt=[int(m[i],16) for i in [12,13]];eva,evb=map(int,m.groups()[13:15]);out=int(m[16],16)
        calc=[min(63,(v*ka+(63 if b63 else w)*kb+16)>>5) for v,w in zip(rgb(top),rgb(sec))]
        assert rgb(out)==calc,'production mixer output disagrees with its actual inputs'
        glyph.append(dict(time_ps=t,frame=frame,x=x,y=y,top=rgb(top),top_flags=tf,second=rgb(sec),second_flags=sf,
            ka=ka,kb=kb,word=word,blendcnt=cnt,eva=eva,evb=evb,out=rgb(out),PocketRGB=pocket(out)))
    assert glyph,'missing fixed glyph S4 input'
    f=next(p for p in a.shots.glob('*.ppm') if int(p.stem[1:])==10)
    actual=list(Image.open(f).getpixel((68,291)))
    pin=re.search(r'ACOBS PIN raw10 x68 y291 rgb([0-9a-f]+)',text);assert pin
    pin_rgb=[(int(pin[1],16)>>shift)&255 for shift in [16,8,0]];assert pin_rgb==actual
    # nshot and v_frames advance once together at VS after write_ppm closes;
    # the main-engine line99 S4 in v_frames10 therefore feeds raw10.
    matching=[g for g in glyph if g['frame']==10]
    assert len(matching)==1 and matching[0]['PocketRGB']==actual,'fixed-frame S4 output differs from raw10 pixel'
    outrows=[dict(time_ps=int(t),frame=int(fr),rgb=rgb(int(v,16)),PocketRGB=pocket(int(v,16))) for t,fr,v in
             re.findall(r'ACOBS GLYPH_OUT t(\d+) frame(\d+) y99 x68 rgb([0-9a-f]+)',text)]
    fixedout=[v for v in outrows if v['frame']==10]
    assert len(fixedout)==1 and fixedout[0]['PocketRGB']==actual,'fixed-frame final 2D output differs from raw10 pin pixel'
    boundaries={int(fr):int(t) for t,fr in re.findall(r'\[(\d+)\] video frame (\d+):',text)}
    assert boundaries[10]<matching[0]['time_ps']<fixedout[0]['time_ps']<boundaries[11]
    raw=list(Image.open(b/'reference/acww-title/mel/shots/f000005.ppm').getpixel((68,291)))
    reference=[((v>>3)<<3)|(v>>5) if i!=1 else v for i,v in enumerate(raw)]
    for g in matching:
        fits=[]
        for eva in range(17):
            c=sum(min(63,(s*eva+d*(16-eva)+8)>>4)<<(6*i) for i,(s,d) in enumerate(zip(g['top'],g['second'])))
            if pocket(c)==reference:fits.append([eva,16-eva])
        g['reference_coefficient_fits_with_actual_native_colors']=fits
    writes=[dict(time_ps=int(t),frame=int(fr),engine=int(e),word=int(w,16),eva=(int(w,16)>>16)&31,evb=(int(w,16)>>24)&31) for t,fr,e,w in
            re.findall(r'ACOBS BLEND_WRITE t(\d+) frame(\d+) eng(\d+) word([0-9a-f]+)',text)]
    transitions=[];previous={}
    for w in writes:
        if previous.get(w['engine'])!=w['word']:
            transitions.append(w);previous[w['engine']]=w['word']
    all_pins=[]
    for raw,value in re.findall(r'ACOBS PIN raw(\d+) x68 y291 rgb([0-9a-f]+)',text):
        pin=[(int(value,16)>>shift)&255 for shift in [16,8,0]]
        assert list(Image.open(a.shots/f'f{int(raw):03d}.ppm').getpixel((68,291)))==pin
        all_pins.append(dict(raw=int(raw),RGB=pin))
    report=dict(source='0e977484',production=q.TARGET,first_accepted_prior=accepted,
        recorded_actual_header_texture_bit_mutant_caught=True,fixed_pixel=dict(raw=10,reference=5,x=68,y=291,native=actual,reference_projected=reference,pin_binding=True),
        recorded_input_mutant=mutant,
        observer_equivalence=equivalence,all_pin_pixels=all_pins,
        glyph_events=glyph,matching_native_pixel_events=matching,final_2D_outputs=outrows,blend_state_transitions=transitions,
        blend_writes=writes,blend_write_scope='Actual 2D line-state port word18 writes, not individual CPU MMIO bus transactions',
        log_sha256=q.digest(a.log.read_bytes()),native_PPM_sha256=q.digest(f.read_bytes()),
        scope='One12frame diagnostic, actual packet and native-input/pin binding only; no whole-game PASS or phase change')
    a.out.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k in ['first_accepted_prior','fixed_pixel','matching_native_pixel_events','recorded_actual_header_texture_bit_mutant_caught']},indent=2))
