#!/usr/bin/env python3
"""Source/report-only packed-tag mapping gate. Never launches Quartus or STA."""
import argparse,csv,hashlib,json,pathlib,re,shutil,subprocess,sys
HERE=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent))
from resources import table

class GateError(Exception):pass
def need(ok,message):
    if not ok:raise GateError(message)
def digest(data):return hashlib.sha256(data).hexdigest()
def compact(text):return re.sub(r'\s+','',text)
def clean(text):return re.sub(r'/\*.*?\*/|//[^\n]*','',text,flags=re.S)
def group(text,start):
    need(text[start]=='(','expected parenthesis');depth=0;quoted=False;escaped=False
    for i in range(start,len(text)):
        c=text[i]
        if quoted:
            if escaped:escaped=False
            elif c=='\\':escaped=True
            elif c=='"':quoted=False
        elif c=='"':quoted=True
        elif c=='(':depth+=1
        elif c==')':
            depth-=1
            if depth==0:return text[start+1:i],i+1
    raise GateError('unterminated source expression')
def named(text):
    values={};i=0
    while i<len(text):
        m=re.match(r'\s*,?\s*\.(\w+)\s*(?=\()',text[i:])
        need(m is not None,'unsupported positional/source binding')
        name=m[1];i+=m.end();value,i=group(text,i)
        need(name not in values,'duplicate named source binding '+name);values[name]=compact(value)
        if not text[i:].strip():break
    return values
def instances(text,module):
    out=[]
    for m in re.finditer(r'\b'+re.escape(module)+r'\s*#\s*(?=\()',text):
        params,end=group(text,m.end());n=re.match(r'\s*(\w+)\s*(?=\()',text[end:]);need(n,'missing instance name')
        ports,stop=group(text,end+n.end());out.append((n[1],named(params),named(ports),m.start(),stop))
    return out
def source_intent(mem,ram):
    mem=clean(mem);ram=clean(ram)
    guard=re.findall(r'\blocalparam\s+bit\s+PACKED_TAGS\s*=([^;]+);',mem)
    expected='WAYS==2&&DSB==8&&ISB==8&&SLOW&&EVB&&!EVBW&&EARLYD&&OPT==1711268835'
    need(len(guard)==1 and compact(guard[0])==expected,'unsupported packed-tag profile guard')
    need(len(re.findall(r'if\s*\(\s*PACKED_TAGS\s*\)\s*begin\s*:\s*g_packed_tags\b',mem))==1,'missing/duplicate selected generate')
    start=mem.index('g_packed_tags');fallback=mem.find('g_original_tags',start)
    need(fallback>start,'missing original-profile fallback')
    banks={}
    for name,params,ports,a,b in instances(mem,'arm9_ram'):
        if name not in ('u_packed_d','u_packed_i'):continue
        need(start<a<b<fallback,'packed bank outside selected branch')
        need(name not in banks,'duplicate source bank '+name)
        need(params=={'AW':'8','LANES':'1','LANE_W':'32','FOLD':'0'},'wrong packed-bank parameters')
        d=name[-1];prefix='dt'if d=='d'else'it';padding=11 if d=='d'else 7
        want={'clk':'clk','a_addr':prefix+'_aa','a_we':'|'+prefix+'_we','a_d':"{"+str(padding)+"'d0,packed_"+d+'_word}', 'a_q':'packed_'+d+'_aq','b_addr':d+'_addr[12:5]','b_q':'packed_'+d+'_bq'}
        need(ports==want,'wrong packed-bank ports '+name)
        banks[d]={'instance':name,'depth':256,'logical_width':32,'minimum_used_width':32-padding,'clock':'clk','source_ports':ports}
    need(set(banks)=={'d','i'},'missing independent D/I source banks')
    need('localparambitPACK=LANES==4&&LANE_W==8&&AW<=9;'in compact(ram),'unsupported arm9_ram PACK selection')
    marker=re.search(r'if\s*\(\s*!PACK\s*&&\s*!\(FOLD\s*&&\s*\(l\s*==\s*0\s*\|\|\s*l\s*==\s*CL\)\)\)\s*begin\s*:\s*one',ram)
    need(marker is not None,'missing selected native nonfolded lane')
    native=instances(ram[marker.end():],'altsyncram');need(len(native)==1 and native[0][0]=='u_ram','ambiguous selected native primitive')
    _,params,ports,_,_=native[0]
    want={'operation_mode':'"BIDIR_DUAL_PORT"','ram_block_type':'"M10K"','intended_device_family':'"CycloneV"','width_a':'LANE_W','widthad_a':'AW','numwords_a':'1<<AW','width_b':'LANE_W','widthad_b':'AW','numwords_b':'1<<AW','width_byteena_a':'1','width_byteena_b':'1','outdata_reg_a':'"UNREGISTERED"','outdata_reg_b':'"UNREGISTERED"','address_reg_b':'"CLOCK0"','indata_reg_b':'"CLOCK0"','wrcontrol_wraddress_reg_b':'"CLOCK0"','read_during_write_mode_port_a':'"NEW_DATA_NO_NBE_READ"','read_during_write_mode_port_b':'"NEW_DATA_NO_NBE_READ"','read_during_write_mode_mixed_ports':'"DONT_CARE"','power_up_uninitialized':'"FALSE"','lpm_type':'"altsyncram"'}
    need(params==want,'native RAM parameters/RDW differ from source intent')
    want_ports={'clock0':'clk','address_a':'a_addr','data_a':'a_d[l*LANE_W+:LANE_W]','wren_a':'a_we[l]','q_a':'a_q[l*LANE_W+:LANE_W]','address_b':'b_addr','data_b':"{LANE_W{1'b0}}",'wren_b':"1'b0",'q_b':'b_q[l*LANE_W+:LANE_W]'}
    need(ports==want_ports,'native RAM ports/clock differ from source intent')
    return {'guard':compact(guard[0]),'banks':banks,'selected_native_branch':'lane[0].one.u_ram','mode':'True Dual Port','clock_mode':'Single Clock','RDW':{'mixed':'dont care','A':'new data','B':'new data'}}
def integer(value):
    need(re.fullmatch(r'\d+',value or '')is not None,'missing/noninteger RAM count');return int(value)
def locations(row):
    text=row.get('Location','');parts=[p.strip()for p in text.split(',')]
    need(parts and all(re.fullmatch(r'M10K_X\d+_Y\d+_N0',p)for p in parts),'unassigned/ambiguous M10K location '+row.get('Name',''))
    need(len(parts)==integer(row.get('M10K blocks','')),'M10K location count differs from block count')
    need(len(set(parts))==len(parts),'duplicate M10K location within RAM')
    return parts
def scope(name):
    parts=name.split('|');owners=[i for i,p in enumerate(parts)if p.startswith('arm9_mem:')]
    if not owners:return None,None
    need(len(owners)==1,'ambiguous ARM9 owner name');i=owners[0];owner='|'.join(parts[:i+1]);tail=parts[i+1:]
    labels=[p.split(':',1)[-1]for p in tail]
    if not any(re.search(r'(?:^|\.)(?:g_packed_tags|g_original_tags|u_[di]tag|u_packed_\w+)(?:[.\[]|$)',p)for p in labels):return owner,None
    matches=[re.fullmatch(r'arm9_ram:g_packed_tags\.u_packed_([di])',p)for p in tail]
    matches=[m for m in matches if m]
    need(len(matches)==1,'old/unrecognized ARM9 tag storage '+name)
    need('altsyncram:lane[0].one.u_ram'in tail,'wrong packed-bank native lane/ports '+name)
    return owner,matches[0][1]
def mapping(report,intent,allow_mock=False):
    statuses=re.findall(r'^;\s*Fitter Status\s*;\s*([^;\n]+)',report,re.M)
    need(len(statuses)==1 and statuses[0].strip().startswith('Successful'),'fitter not uniquely successful; no legal mapping')
    if not allow_mock:
        need(re.search(r'^Fitter report for \S+',report,re.M)and re.search(r'^Quartus Prime Version ',report,re.M),'not a native Quartus fitter report')
        need('MOCK_FIXTURE_NOT_PHYSICAL'not in report,'mock report cannot establish physical acceptance')
    need(len(re.findall(r'^; Fitter RAM Summary ',report,re.M))==1,'missing/duplicate RAM summary')
    rows=table(report,'Fitter RAM Summary','Name');need(rows,'empty RAM summary')
    # resources.table supplies the dictionaries. Audit its complete raw table
    # envelope too: a malformed non-target row must not silently hide a bank,
    # old tag or an allocation collision by being skipped by the shared parser.
    lines=report.splitlines();start=next(i for i,x in enumerate(lines)if x.startswith('; Fitter RAM Summary '))
    headers=None;raw_names=[]
    for line in lines[start+1:]:
        if line.startswith(';'):
            cells=[c.strip()for c in line.split(';')[1:-1]]
            if cells and cells[0]=='Name':
                need(headers is None and len(cells)==len(set(cells)),'duplicate RAM summary header/column');headers=cells
            elif headers and cells and cells[0]:
                need(len(cells)==len(headers),'malformed RAM summary row');raw_names.append(cells[0])
        elif raw_names and not line.startswith('+'):break
    need(raw_names==[r['Name']for r in rows],'incomplete parsed RAM inventory')
    names=[r['Name']for r in rows];need(len(names)==len(set(names)),'duplicate RAM report row')
    allocated={};banks={};parents=set()
    for r in rows:
        count=integer(r.get('M10K blocks',''));mlabs=integer(r.get('MLABs',''))
        if count:
            for p in locations(r):need(p not in allocated,'M10K location collision '+p);allocated[p]=r['Name']
        parent,bank=scope(r['Name'])
        if bank is None:continue
        need(bank not in banks,'duplicate packed bank');parents.add(parent)
        need(count==2 and mlabs==0,'packed bank is not two M10Ks/no MLAB spill')
        fields={'Type':'M10K block','Mode':intent['mode'],'Clock Mode':intent['clock_mode'],'Port A Depth':'256','Port B Depth':'256','Port A Width':'32','Port B Width':'32','Port A Input Registers':'yes','Port B Input Registers':'yes','Port A Output Registers':'no','Port B Output Registers':'no','Size':'8192','ECC Mode':'Off','ECC Pipeline Registers':'No'}
        for k,v in fields.items():need(r.get(k)==v,'wrong packed bank '+bank+' '+k)
        mixed=r.get('Mixed Width RDW Mode','').lower().replace("'",'').replace('’','')
        need(mixed==intent['RDW']['mixed']and r.get('Port A RDW Mode','').lower()==intent['RDW']['A']and r.get('Port B RDW Mode','').lower()==intent['RDW']['B'],'wrong native RDW report')
        need(r.get('MIF')=='None','unexpected packed-tag initialization file')
        aw=integer(r.get('Implementation Port A Width',''));bw=integer(r.get('Implementation Port B Width',''))
        need(aw==bw and intent['banks'][bank]['minimum_used_width']<=aw<=32,'implementation width drops used packed bits')
        need(r.get('Implementation Port A Depth')==r.get('Implementation Port B Depth')=='256'and integer(r.get('Implementation Bits',''))==aw*256,'implementation dimensions differ')
        banks[bank]=r
    need(set(banks)=={'d','i'}and len(parents)==1,'missing independent D/I banks in one ARM9 controller')
    allsites=[p for r in banks.values()for p in locations(r)];need(len(allsites)==len(set(allsites))==4,'not four distinct assigned tag M10Ks')
    return {'ARM9_owner':next(iter(parents)),'banks':banks,'M10K_locations':sorted(allsites),'M10K_blocks':4,'MLABs':0,'scope':'Packed metadata mapping only; no ALM saving, functionality, STA or game qualification.'}
def qsf_sources(text,tree,source,qsf_root=None):
    paths=re.findall(r'^set_global_assignment -name (?:SYSTEMVERILOG_FILE|VERILOG_FILE) "([^"]+)"',text,re.M)
    need(paths,'QSF has no explicit source inventory');bindings={};original=pathlib.Path(qsf_root).resolve()if qsf_root else tree
    for value in paths:
        p=pathlib.Path(value)
        if p.is_absolute():
            try:rel=p.relative_to(original)
            except ValueError:continue
        else:rel=p
        if not rel.parts or rel.parts[0]!='rtl':continue
        n=rel.as_posix();need(n not in bindings,'duplicate QSF source '+n)
        expected=subprocess.check_output(['git','show',source+':'+n],cwd=tree);need((tree/rel).read_bytes()==expected,'QSF source differs from pinned commit '+n);bindings[n]=digest(expected)
    need({'rtl/arm/arm9_mem.sv','rtl/arm/arm9_ram.sv'}<=set(bindings),'QSF does not bind both ARM9 source files')
    return bindings
def seal(out,origin,source,bindings):
    files={str(p.relative_to(out)):digest(p.read_bytes())for p in out.rglob('*')if p.is_file()and p.name not in ('manifest.json','verdict.json')}
    (out/'manifest.json').write_text(json.dumps({'origin':origin,'source':source,'source_bindings':bindings,'files':files},indent=2)+'\n')
def evaluate(out,allow_mock=False):
    m=json.loads((out/'manifest.json').read_text());need(m['origin']=='quartus-fitter-report'or(allow_mock and m['origin']=='mock'),'mock/untrusted origin cannot establish physical acceptance')
    need(re.fullmatch(r'[0-9a-f]{40}',m['source'])is not None,'unpinned source SHA')
    files={str(p.relative_to(out))for p in out.rglob('*')if p.is_file()and p.name not in ('manifest.json','verdict.json')};need(files==set(m['files']),'manifest file set differs')
    for n,h in m['files'].items():need(digest((out/n).read_bytes())==h,'changed report/source evidence '+n)
    for n in ('arm9_mem.sv','arm9_ram.sv'):need(digest((out/'sources'/n).read_bytes())==m['source_bindings'].get('rtl/arm/'+n),'source binding missing/changed '+n)
    need((out/'gate.py').read_bytes()==pathlib.Path(__file__).read_bytes(),'gate implementation changed')
    need((out/'resources.py').read_bytes()==(HERE.parent/'resources.py').read_bytes(),'report parser implementation changed')
    intent=source_intent((out/'sources/arm9_mem.sv').read_text(),(out/'sources/arm9_ram.sv').read_text())
    need(json.loads((out/'intent.json').read_text())==intent,'source intent differs')
    result=mapping((out/'fit.rpt').read_text(errors='replace'),intent,allow_mock=allow_mock and m['origin']=='mock')
    return {'status':'MOCK_MAPPING_PASS_NOT_PHYSICAL'if m['origin']=='mock'else'PASS_PACKED_TAG_REPORT_MAPPING_ONLY','source':m['source'],'origin':m['origin'],'source_bindings':m['source_bindings'],**result}
def collect(a):
    need(not a.out.exists(),'output exists; refuse stale/mixed evidence');tree=a.source_tree.resolve();project=a.project.resolve()
    need(re.fullmatch(r'[0-9a-f]{40}',a.source)is not None,'use a full source SHA')
    qsf=project/(a.revision+'.qsf');report=project/'output_files'/(a.revision+'.fit.rpt')
    bindings=qsf_sources(qsf.read_text(),tree,a.source,a.qsf_source_root)
    mem=(tree/'rtl/arm/arm9_mem.sv').read_text();ram=(tree/'rtl/arm/arm9_ram.sv').read_text();intent=source_intent(mem,ram)
    mapping(report.read_text(errors='replace'),intent) # Reject no-fit before publishing a report bundle.
    a.out.mkdir(parents=True);(a.out/'sources').mkdir()
    for name,p in [('fit.rpt',report),('project.qsf',qsf),('gate.py',pathlib.Path(__file__)),('resources.py',HERE.parent/'resources.py'),('sources/arm9_mem.sv',tree/'rtl/arm/arm9_mem.sv'),('sources/arm9_ram.sv',tree/'rtl/arm/arm9_ram.sv')]:shutil.copyfile(p,a.out/name)
    (a.out/'intent.json').write_text(json.dumps(intent,indent=2)+'\n');seal(a.out,'quartus-fitter-report',a.source,bindings)
def main():
    ap=argparse.ArgumentParser(description=__doc__);sub=ap.add_subparsers(dest='mode',required=True)
    c=sub.add_parser('collect');c.add_argument('--project',type=pathlib.Path,required=True);c.add_argument('--revision',default='apf_top');c.add_argument('--source-tree',type=pathlib.Path,required=True);c.add_argument('--source',required=True);c.add_argument('--qsf-source-root',help='Original source root in archived absolute QSF paths; explicitly remap to --source-tree');c.add_argument('--out',type=pathlib.Path,required=True)
    v=sub.add_parser('check');v.add_argument('out',type=pathlib.Path);a=ap.parse_args()
    try:
        if a.mode=='collect':collect(a)
        result=evaluate(a.out)
    except (GateError,OSError,ValueError,KeyError,IndexError,subprocess.CalledProcessError)as e:result={'status':'FAIL_CLOSED','reason':str(e)}
    if a.out.is_dir():(a.out/'verdict.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2));return 0 if result['status']=='PASS_PACKED_TAG_REPORT_MAPPING_ONLY'else 1
if __name__=='__main__':sys.exit(main())
