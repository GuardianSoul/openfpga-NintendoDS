"""Run one owned serial component worker at absolute NI10."""
import os,resource,sys
os.setpriority(os.PRIO_PROCESS,0,10)
assert os.getpriority(os.PRIO_PROCESS,0)==10
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
print(f'SOUND_WORKER PID={os.getpid()} NI=10',flush=True)
os.execvp(sys.argv[1],sys.argv[1:])
