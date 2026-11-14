#!/usr/bin/env python3
import os
os.setpriority(os.PRIO_PROCESS,0,10)
import importlib.util,pathlib,sys,fcntl
R=pathlib.Path(__file__).resolve().parents[2]
s=importlib.util.spec_from_file_location('ro',R/'tools/scorecard/raster_symptoms.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.OUT=R/'build/title-pacing';m.STATUS=m.MAIN/'build/coordinator/units/CPUCompression.json'
# The qualified runner's subprocess call is extended only with an observer define.
orig=m.bounded
def bounded(cmd,*a,**kw):
 if a[2].endswith('BUILD'):cmd=cmd[:1]+['+define+TITLE_PACING_OBSERVER']+cmd[1:]
 if a[2].endswith('SIM'):cmd=cmd+['+mrprof','+busprof']
 return orig(cmd,*a,**kw)
m.bounded=bounded
I=pathlib.Path('/home/user/Git/NDS_Pocket-codex-raster-symptom-observer/build/raster-symptoms/inventory-expanded.json')
if sys.argv[1]=='build':m.build('on','55dc title pacing attribution only',False,I)
else:m.run('title','on',sys.argv[1],False,I)
