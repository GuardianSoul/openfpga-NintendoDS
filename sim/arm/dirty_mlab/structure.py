from pathlib import Path
import subprocess,hashlib,json
R=Path(__file__).resolve().parents[3];s=(R/'rtl/arm/arm9_mem.sv').read_text();old=subprocess.check_output(['git','show','2c4e980c:rtl/arm/arm9_mem.sv'],cwd=R,text=True)
s=s[:s.index('\n// One-write/asynchronous-read MLAB.')]
s=s.replace("  , parameter bit DIRTY_MLAB = 1'b0 // default-off asynchronous dirty-state banks\n", "")
s=s.replace('initial if (!DIRTY_MLAB) for','initial for')
a=s.index('  // S_TAGW owns the cache port');b=s.index('  logic        pf_run;',a);s=s[:a]+s[b:]
s=s.replace('if (!DIRTY_MLAB && MEM1 && wd_store_cache && wd_buf)', 'if (MEM1 && wd_store_cache && wd_buf)').replace("if (!DIRTY_MLAB && MEM1) dirt[dset][vway]", "if (MEM1) dirt[dset][vway]")
s=s.replace('DIRTY_MLAB ? dirty_row[w] : dirt[dset][w]', 'dirt[dset][w]')
assert s==old,'unlisted production delta'
p=R/'build/main-dirty-mlab-proof/structure.json';p.write_text(json.dumps({'status':'PASS_LITERAL_UNCHANGED_EXCEPT_DIRTY_STORAGE_SELECT','before_sha256':hashlib.sha256(old.encode()).hexdigest(),'after_sha256':hashlib.sha256((R/'rtl/arm/arm9_mem.sv').read_bytes()).hexdigest(),'ports_clocks_reset_admission_output_state_bus_deadlines':'literal unchanged'},indent=2)+'\n');print('PASS_LITERAL_BOUNDARY')
