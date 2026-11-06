#!/usr/bin/env python3
"""Prepare an immutable shared SPI/WiFi/AUX fixture; never build or run it."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT=Path(__file__).resolve().parents[2]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def prepare(out,source,mutant=None):
    if out.exists():raise ValueError('output exists; preserve original evidence')
    pin=subprocess.check_output(['git','-C',str(ROOT),'rev-parse',source],text=True).strip()
    paths=['rtl/ds/'+n+'.sv' for n in ('nds_dsp_add','nds_spi','nds_spi_mc','nds_wifi_mc')]
    paths+=['sim/ds_dev/spi_eq/tb_spi_eq.sv']
    data=subprocess.check_output(['git','-C',str(ROOT),'archive',pin,*paths])
    src=out/'source';src.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:archive.extractall(src,filter='data')
    wrapper=src/'sim/ds_dev/service_eq/nds_spi_service_sys.sv';wrapper.parent.mkdir()
    shutil.copy2(ROOT/'sim/ds_dev/service_eq/nds_spi_service_sys.sv',wrapper)
    if mutant:
        text=wrapper.read_text()
        old,new={
            'drop-spi-done':('.e_done(done)',".e_done(1'b0)"),
            'corrupt-wifi-read':('wm_rdata<=memory.exists(mem_addr)?memory[mem_addr]:0;',
                                  "wm_rdata<=(memory.exists(mem_addr)?memory[mem_addr]:0)^32'd1;")
        }[mutant]
        if text.count(old)!=1:raise ValueError('mutant anchor changed')
        wrapper.write_text(text.replace(old,new))
    tb=src/'sim/ds_dev/spi_eq/tb_spi_eq.sv';text=tb.read_text()
    def replace_once(old,new):
        nonlocal text
        if text.count(old)!=1:raise ValueError('upstream bench anchor changed: '+old)
        text=text.replace(old,new)
    replace_once('nds_spi_sys u_new','nds_spi_service_sys u_new')
    replace_once('end while (rd_o[7]);','end while (rd_o[7] || rd_n[7]);')
    replace_once('    logic [15:0] cnt;','''    longint reply_bad=0,irq_old=0,irq_new=0;
    always @(posedge clk) if (!rst && ready) begin
        if (irq_o) irq_old++;
        if (irq_n) irq_new++;
    end
    logic [15:0] cnt;''')
    replace_once('        bytes++;','''        // Keep both implementations idle before the next CPU byte. Different
        // busy durations are measured, not converted into dropped writes.
        rdpoll();
        if (rd_o[23:16] !== rd_n[23:16]) reply_bad++;
        bytes++;''')
    replace_once('        while (n < cycles) begin', '''        // Deterministic fastest-baud firmware READ controls before random traffic.
        // Four command/address bytes plus four data bytes, IRQ enabled, twice.
        repeat (2) begin
            cnt=16'hC900;wr(4'b0011,{16'd0,cnt});
            byte_(8'h03,0);byte_(8'h00,0);byte_(8'h00,0);byte_(8'h00,0);
            byte_(8'h00,0);byte_(8'h00,0);byte_(8'h00,0);byte_(8'h00,1);
        end
        while (n < cycles) begin''')
    replace_once('        $finish;','''        $display("SERVICE_REPLY bytes=%0d mismatches=%0d irq_old=%0d irq_new=%0d clock_differences=%0d",bytes,reply_bad,irq_old,irq_new,bad);
        if (reply_bad || irq_old!=irq_new || irq_old==0 || bytes<16) $fatal(1,"SERVICE_FAIL reply/IRQ coverage");
        if (u_new.service_wifi && (u_new.wifi_transactions<4 || u_new.timer_steps==0 || u_new.wifi_spi_overlap==0)) $fatal(1,"SERVICE_FAIL WiFi overlap coverage");
        if (u_new.service_aux && (u_new.aux_transactions<6 || u_new.aux_spi_overlap==0)) $fatal(1,"SERVICE_FAIL AUX overlap coverage");
        if (u_new.spi_fast_events<16) $fatal(1,"SERVICE_FAIL fastest-baud coverage");
        $display("SERVICE_PASS");
        $finish;''')
    replace_once('    initial begin\n        int cycles;','''    initial begin #100ms; $fatal(1,"SERVICE_FAIL watchdog"); end
    initial begin
        int cycles;''')
    tb.write_text(text)
    files=[src/p for p in paths]+[wrapper]
    obj=out/'obj'
    compiler='build/tools/oss-cad-suite/bin/verilator'
    build=[compiler,'--binary','--timing','-j','1','-O2','--threads','1','-Wno-fatal','-Wno-WIDTHEXPAND','-Wno-WIDTHTRUNC',
           '--top-module','tb_spi_eq','--Mdir',str(obj),*[str(p) for p in files]]
    cases=[]
    for name,wifi,aux,lat in [('isolated',0,0,1),('wifi',1,0,1),('wifi-delay20',1,0,20),('wifi-delay80',1,0,80),
                             ('aux',0,1,1),('both',1,1,1),('both-delay20',1,1,20),('both-delay80',1,1,80)]:
        for seed in [1,7]:
            cases.append(dict(name=f'{name}-s{seed}',command=[str(obj/'Vtb_spi_eq'),'+cycles=300000',f'+verilator+seed+{seed}',
                f'+service_wifi={wifi}',f'+service_aux={aux}',f'+service_memlat={lat}']))
    plan=dict(source_sha=pin,mutant=mutant,source_sha256={str(p.relative_to(src)):sha(p) for p in files},
              generator_sha256=sha(Path(__file__)),build_command=build,build_jobs=1,threads=1,cases=cases,
              execution='PREPARED ONLY; obtain a coordinator worker allocation before compilation or simulation',
              reference='existing nds_spi for per-byte replies and IRQ count; literal WiFi RAM round trips and EEPROM WEL/status checks',
              acceptance='native completion, SERVICE_PASS, nonzero required overlap; record every clock difference and timer event loss; no DS timing equivalence claim',
              limitations=['EEPROM status only, no save-memory backend proof','timer due/dispatch counters are architectural service observations, not DS timing captures',
                           'standalone WiFi is not a peer MAC or physical transport','legacy clock-by-clock DIFFER diagnostic is reported; settled bytes/IRQ totals are separate acceptance checks'])
    (out/'plan.json').write_text(json.dumps(plan,indent=2,sort_keys=True)+'\n')
    return plan

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,required=True);p.add_argument('--source',default='63052f05')
    p.add_argument('--mutant',choices=['drop-spi-done','corrupt-wifi-read'])
    a=p.parse_args();plan=prepare(a.out.resolve(),a.source,a.mutant);print('prepared',len(plan['cases']),'cases; no build/run')
if __name__=='__main__':main()
