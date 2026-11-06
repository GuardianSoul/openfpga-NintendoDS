import numpy as np, os, sys
S=sys.argv[1]
games=["kh-plaza","kh-halloween","hg-goldenrod","platinum","nsmb","mkds"]
def load(d,cpu):
    p=f"{d}/arm{cpu}.trc"
    n=os.path.getsize(p)//68
    return np.memmap(p,"<u4","r",shape=(n,17))[:,0]
print(f"{'game':14} {'cpu':3} {'insns a/b':>20} {'first PC diff at insn':>22}  context (pc before; then stock vs cheap next PCs)")
for g in games:
    for cpu in (9,7):
        a=load(f"{S}/trc_{g}_stock",cpu); b=load(f"{S}/trc_{g}_cheap",cpu)
        n=min(len(a),len(b))
        d=np.nonzero(a[:n]!=b[:n])[0]
        if len(d)==0:
            print(f"{g:14} {cpu:3} {len(a):9}/{len(b):<9} {'none in '+str(n):>22}")
            continue
        i=int(d[0])
        # tight-loop signature before: distinct PCs in the 64 insns before
        pre=a[max(0,i-64):i]
        loop=sorted(set(int(x) for x in pre))
        print(f"{g:14} {cpu:3} {len(a):9}/{len(b):<9} {i:22}  pc_before={int(a[i-1]):08X} stock_next={int(a[i]):08X} cheap_next={int(b[i]):08X} distinct_pcs_in_prev64={len(loop)}")
