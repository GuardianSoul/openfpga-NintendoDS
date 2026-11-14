#!/usr/bin/env python3
import os
os.setpriority(os.PRIO_PROCESS,0,10)
import importlib.util,pathlib,sys
W=pathlib.Path(__file__).resolve().parents[2];s=importlib.util.spec_from_file_location('rhit_runner',W/'tools/scorecard/title_waits_runner.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.OUT=W/'build/rhit-title'
I=pathlib.Path('/home/user/Git/NDS_Pocket-codex-raster-symptom-observer/build/raster-symptoms/inventory-expanded.json')
m.OUT.mkdir(exist_ok=True)
data=m.OUT/'inputs-title'
if not data.exists():data.symlink_to('/home/user/Git/NDS_Pocket-codex-raster-symptom-observer/build/raster-symptoms/inputs-title',target_is_directory=True)
if sys.argv[1]=='build':m.build('final-rhit-on','Unit-qualified default-off registered hit; measured title benefit only',True,I)
else:m.run('title','final-rhit-on','observe',True,I)
