"""Process-guard checks only; no emulator, compiler or native model launched."""
import os,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from sound_process_identity import identity,require_same_identity

class ProcessIdentity(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name);self.pid=31415;self.p=self.root/str(self.pid);self.p.mkdir()
  self.cwd=self.root/'NDS_Pocket-job';self.cwd.mkdir();self.exe=self.root/'cc1plus';self.exe.touch()
  self.stat();(self.p/'exe').symlink_to(self.exe);(self.p/'cwd').symlink_to(self.cwd)
 def stat(self,comm='cc1plus',start='123',ppid='42',state='R'):
  fields=[state,ppid]+['0']*17+[start]+['0']*30
  (self.p/'stat').write_text(f'{self.pid} ({comm}) '+ ' '.join(fields))
 def read(self,**kw):return identity(self.pid,proc_root=self.root,**kw)
 def test_stable_identity(self):
  self.assertEqual(self.read(expected_comm='cc1plus'),dict(starttime='123',executable=str(self.exe),cwd=str(self.cwd)))
 def test_reparenting_keeps_identity(self):
  old=self.read();self.stat(ppid='1');require_same_identity(old,self.read())
 def test_missing_link_old_resolve_fabricates_identity(self):
  (self.p/'exe').unlink();fabricated=str((self.p/'exe').resolve())
  self.assertEqual(fabricated,str(self.p/'exe'))
  with self.assertRaises(FileNotFoundError):self.read()
 def test_inventory_exec_race_rejected(self):
  self.stat(comm='lto1')
  with self.assertRaises(ProcessLookupError):self.read(expected_comm='cc1plus')
 def test_zombie_rejected(self):
  self.stat(state='Z')
  with self.assertRaises(ProcessLookupError):self.read()
 def test_mid_sample_exec_rejected(self):
  real=os.readlink;calls=0
  def changed(path):
   nonlocal calls
   calls+=1
   if calls==3:return '/other/executable'
   return real(path)
  with patch('sound_process_identity.os.readlink',side_effect=changed):
   with self.assertRaises(ProcessLookupError):self.read()
 def test_mid_sample_start_change_rejected(self):
  real=os.readlink;calls=0
  def changed(path):
   nonlocal calls
   calls+=1
   if calls==4:self.stat(start='456')
   return real(path)
  with patch('sound_process_identity.os.readlink',side_effect=changed):
   with self.assertRaises(ProcessLookupError):self.read()
 def test_scheduling_state_change_keeps_identity(self):
  old=self.read();real=os.readlink;calls=0
  def scheduled(path):
   nonlocal calls
   calls+=1
   if calls==4:self.stat(state='S')
   return real(path)
  with patch('sound_process_identity.os.readlink',side_effect=scheduled):
   require_same_identity(old,self.read())
 def test_pid_reuse_records_both_tuples(self):
  old=self.read();self.stat(start='456');new=self.read()
  with self.assertRaises(AssertionError) as e:require_same_identity(old,new)
  self.assertEqual(e.exception.args[0],dict(reason='PID identity changed',old=old,new=new))
 def test_stable_executable_change_still_rejected(self):
  old=self.read();(self.p/'exe').unlink();(self.p/'exe').symlink_to('/usr/bin/python3')
  with self.assertRaises(AssertionError):require_same_identity(old,self.read())
 def test_stable_cwd_change_still_rejected(self):
  old=self.read();(self.p/'cwd').unlink();(self.p/'cwd').symlink_to('/tmp')
  with self.assertRaises(AssertionError):require_same_identity(old,self.read())
if __name__=='__main__':unittest.main()
