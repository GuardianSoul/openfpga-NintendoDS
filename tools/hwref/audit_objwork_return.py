from pathlib import Path
import json,struct,hashlib,sys,argparse,os
parser=argparse.ArgumentParser(description="All-pixel run38/39/40 finite OBJ-model audit; no simulation")
parser.add_argument('--run38',type=Path,required=True)
parser.add_argument('--run39',type=Path,required=True,help='OBJv2 output directory')
parser.add_argument('--run40',type=Path,required=True,help='directory containing objwork-v1')
parser.add_argument('--models',type=Path,required=True,help='pinned predeclared predictions.json')
args=parser.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10)
r=args.run40
repo=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(repo/'tools/hwref'))
from check_objwork import analyze as work_check
from check_objlimit import analyze as limit_check
work=work_check(r/'objwork-v1')
old39=args.run39
limit=limit_check(old39);assert limit['inputs_qualified']
old38=args.run38
def pixels(path):return struct.unpack('<49152H',path.read_bytes())
background=pixels(old38/'load2d_1_0_0_f0.bin')
# Every pixel outside the two opaque controls independently agrees with the
# measured background; the old run's8 background captures are all identical.
control=pixels(r/'objwork-v1/objwork_v1_k0.bin')
assert all(control[i]==background[i] for i in range(49152) if not(96<=i//256<160 and i%256>=128))
for p in old38.glob('load2d_1_*'):assert pixels(p)==background
cases=[];inputs={}
for root,prefix,run,n in [(old39,'objlimit_v2',39,6),(r/'objwork-v1','objwork_v1',40,8)]:
 for p in root.glob(prefix+'*'):
  if p.is_file():inputs[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
 palette=struct.unpack('<512H',(root/(prefix+'_pal.bin')).read_bytes());texture=(root/(prefix+'_obj.bin')).read_bytes()
 for k in range(n):
  path=root/f'{prefix}_k{k}.bin';oam=struct.unpack('<512H',(root/f'{prefix}_k{k}_oam.bin').read_bytes())
  cases.append(dict(run=run,case=k,path=path,actual=pixels(path),oam=oam,palette=palette,texture=texture))
  for p in [path,root/f'{prefix}_k{k}_oam.bin']:inputs[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
# Run38 is source-programmed all128 normal64 objects, rather than dumped OAM.
oam=[]
for i in range(128):oam.extend([((i%6)*32)|0x400,0xc000|((i*17)&255),0,0])
for p in sorted(old38.glob('load2d_2_*')):
 cases.append(dict(run=38,case=p.name,path=p,actual=pixels(p),oam=oam,palette=None,texture=None))
 inputs[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
for p in old38.glob('load2d_1_*'):inputs[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()

def render(c,disabled=2,ymiss=0,affine_setup=10,affine_pixel=2,budget=2124,full=True):
 image=list(background);aa=c['oam']
 for y in range(192):
  remaining=budget;occupied=0
  for i in range(128):
   a0,a1,a2,_=aa[i*4:i*4+4];affine=bool(a0&0x100)
   if a0&0x200 and not affine:remaining-=disabled;continue
   assert not(a0&0xc000) and a1>>14 in [0,2,3]
   width=[8,16,32,64][a1>>14];dy=(y-(a0&255))&255
   if dy>=width:remaining-=ymiss;continue
   x=a1&511;x=x if x<256 else x-512
   visible=max(0,min(width,256-x)-max(0,-x))
   # On these captures all identity-affine sprites finish before the marker
   # frontier. Both cost138=10+2*64 and138=74+1*64 are admissible.
   setup=affine_setup if affine else 0;per_pixel=affine_pixel if affine else 1
   remaining-=setup;charge_width=width if full else visible
   drawn=max(0,min(width,remaining//per_pixel));remaining-=charge_width*per_pixel
   for dx in range(drawn):
    sx=x+dx
    if not(0<=sx<256)or occupied>>sx&1:continue
    if c['run']==38:color=0x803f
    else:
     if a0&0x2000:
      at=((a2&1023)+(dy//8)*32+(dx//8)*2)*32+(dy%8)*8+dx%8
      index=c['texture'][at];bank=0
     else:
      at=((a2&1023)+(dy//8)*32+dx//8)*32+(dy%8)*4+(dx%8)//2
      index=(c['texture'][at]>>(4*(dx&1)))&15;bank=(a2>>12)&15
     if index==0:continue
     color=0x8000|c['palette'][256+bank*16+index]
    occupied|=1<<sx;image[y*256+sx]=color
   if remaining<=0:break
 return image

def compare(**params):
 observations=[]
 for c in cases:
  predicted=render(c,**params);bad=[i for i,(a,b)in enumerate(zip(predicted,c['actual']))if a!=b]
  observations.append(dict(run=c['run'],case=c['case'],pixels=49152,mismatches=len(bad),first_xy=[[i%256,i//256]for i in bad[:8]]))
 return dict(parameters=params,total_pixels=sum(x['pixels']for x in observations),mismatches=sum(x['mismatches']for x in observations),cases=observations)
variants=[]
for ymiss in (0,2):
 for setup,price in [(10,2),(74,1)]:
  z=compare(ymiss=ymiss,affine_setup=setup,affine_pixel=price);assert z['mismatches']==0,z;variants.append(z)
mutants=[]
for name,params in [('disabled_gap_free',dict(disabled=0)),('charge_visible_only',dict(full=False)),('affine64_cost139',dict(affine_setup=11))]:
 z=compare(**params);assert z['mismatches']>0,name;mutants.append(dict(name=name,**z))
# Preserve rejection of every predeclared model; do not retrofit its scan or
# negative setup to announce a winner.
pred=json.loads(args.models.read_text());rejections=[]
for m in pred['rows']:
 bad=[]
 for c in work['cases']:
  expected=m['predictions'][c['name']]
  for bank in (0,1):
   if c['markers'][bank]['prefix_columns']!=[expected[bank]]*8:bad.append(dict(case=c['kind'],marker=bank,predicted=expected[bank],observed=c['markers'][bank]['prefix_columns']))
 rejections.append(dict(model_id=m['model_id'],parameters={k:m[k]for k in ['full_width_charge','per_eligible_setup','per_scanned_OAM','budget']},bad=bad))
assert all(m['bad']for m in rejections)
assert all(any(b['case']in (2,3,4)for b in m['bad'])for m in rejections)
normalized={}
for name,h in inputs.items():
 p=Path(name)
 label,relative=('run38',p.relative_to(old38))if p.is_relative_to(old38)else ('run39',p.relative_to(old39))if p.is_relative_to(old39)else ('run40',p.relative_to(r))
 normalized[label+'/'+str(relative)]=h
inputs=normalized
answer=dict(scope='All measured pixels:8run38 OBJ captures,6run39 captures,8run40 captures. Simple normal/identity-affine solid scenes only; no blend/window/bitmap/rotation/bit23 generalization.',
 total_cases=len(cases),original113_models_surviving=0,original_model_rejections=rejections,
 exact_expanded_countermodels=variants,actual_mutant_models_caught=mutants,input_sha256=inputs,
 conclusions=dict(normal_full_width=True,disabled_gap_cost=2,active_extra_setup=0,budget=2124,normal8bpp64_cost_equals4bpp64=True,identity_affine64_combined_cost=138,
 units='normal marker pixel work, not measured DS clocks',
 nonunique='Y-nonintersection charge0 or2 and affine74+width or10+2*width both give exact full captures; only identity64 affine total138 is measured. General affine slope/setup and Y-miss charge remain unresolved.'))
print(json.dumps(answer,indent=2)+'\n',end='')
