#!/usr/bin/env python3
"""Scoped low-I/O self-base/RF/Thumb/writeback/precise-abort check."""
from pathlib import Path
exec(compile(Path(__file__).with_name('qualify.py').read_text().split("stem=G/'directed'")[0],str(Path(__file__).with_name('qualify.py')),'exec'))
stem=G/'boundary';img=c.assemble((R/'sim/arm/io_retry_window/boundary.s').read_text(),stem);cut=symbol(stem.with_suffix('.elf'),'compare_end');results={}
for lat in [0,2,9]:
 rows={n:run(n,img,'boundary-'+n+'-b'+str(lat),cut,lat)for n in ['before','off','on']}
 assert rows['before'][:2]==rows['off'][:2]==rows['on'][:2]
 assert re.findall(r'cycles=\d+',rows['before'][2])==re.findall(r'cycles=\d+',rows['off'][2])
 results[str(lat)]=dict(states=len(rows['on'][0]),packets=len(rows['on'][1]),replays=re.findall(r'REPLAY_COUNT (\d+)',rows['on'][2]))
 save(G/'boundary.json',results);print('BOUNDARY',lat,results[str(lat)],flush=True)
print('BOUNDARY_PASS',flush=True)
