#!/usr/bin/env python3
import os
os.setpriority(os.PRIO_PROCESS,0,10)
import importlib.util,pathlib,sys
W=pathlib.Path(__file__).resolve().parents[2]
s=importlib.util.spec_from_file_location('wait_runner',W/'tools/scorecard/title_waits_runner.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
I=pathlib.Path('/home/user/Git/NDS_Pocket-codex-raster-symptom-observer/build/raster-symptoms/inventory-expanded.json')
if sys.argv[1]=='build':m.build('final-waits-off','Corrected title wait-cause attribution; passive only',True,I)
else:m.run('title','final-waits-off',sys.argv[1],True,I)
