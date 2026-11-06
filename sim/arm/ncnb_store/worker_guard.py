import os,subprocess,time
from sim_ownership import belongs_to_nds,pause_own_worker

def census():
 rows={}
 for line in subprocess.check_output(['ps','-eo','pid,ppid,comm,stat,args'],text=True).splitlines()[1:]:
  p,pp,c,s,a=line.strip().split(None,4);rows[int(p)]={'ppid':int(pp),'comm':c,'stat':s,'args':a}
 return rows

def heavy(rows):
 return [p for p,x in rows.items() if not x['stat'].startswith(('T','t','Z')) and (x['comm'].startswith('V') or x['comm'] in ('cc1plus','clang','clang-23','verilator_bin')) and belongs_to_nds(p,rows)]

def guard():
 subprocess.run(['uptime'],check=True)
 while True:
  workers=heavy(census())
  if len(workers)<3:return
  print('NDS capacity full',workers,flush=True);time.sleep(1)

def wait_owned(p):
 while p.poll() is None:
  rows=census();workers=heavy(rows)
  if len(workers)>3 and p.pid in workers:
   pause_own_worker(p.pid,lambda:len(heavy(census()))<3)
  time.sleep(.1)
 return p.returncode
