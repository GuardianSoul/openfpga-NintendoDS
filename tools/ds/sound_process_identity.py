"""Stable read-only process identity for the existing sound job guards."""
import os
from pathlib import Path


def _stat(path):
 text=path.read_text();head,tail=text.rsplit(')',1);fields=tail.split()
 return dict(comm=head.split('(',1)[1],state=fields[0],starttime=fields[19])


def identity(pid,expected_comm=None,proc_root='/proc'):
 """Reject vanished/exec-changing samples; never fabricate unresolved paths.

 A ps inventory may predate exec. Compare its comm before accepting a sample;
 the caller still checks ancestry, project, priority and exact job directory.
 PPID is deliberately not identity: reparenting does not make a new process.
 """
 p=Path(proc_root,str(pid));before=_stat(p/'stat')
 if before['state']=='Z' or (expected_comm is not None and before['comm']!=expected_comm):
  raise ProcessLookupError('vanished or stale executable inventory')
 executable=os.readlink(p/'exe');cwd=os.readlink(p/'cwd')
 executable2=os.readlink(p/'exe');cwd2=os.readlink(p/'cwd');after=_stat(p/'stat')
 if (before['starttime']!=after['starttime'] or before['comm']!=after['comm'] or
     after['state']=='Z' or executable!=executable2 or cwd!=cwd2):
  raise ProcessLookupError('process identity changed during sample')
 if not Path(executable).is_absolute() or not Path(cwd).is_absolute():
  raise ProcessLookupError('nonabsolute process identity')
 # readlink raises on a missing /proc link, unlike non-strict Path.resolve.
 return dict(starttime=before['starttime'],executable=executable,cwd=cwd)


def require_same_identity(old,new):
 """A stable change still fails closed, with both complete tuples retained."""
 if old!=new:
  raise AssertionError(dict(reason='PID identity changed',old=old,new=new))
