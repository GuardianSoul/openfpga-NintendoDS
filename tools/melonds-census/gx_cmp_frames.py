import csv, sys, glob, os
S=sys.argv[1]
games=["kh-plaza","kh-halloween","hg-goldenrod","platinum","nsmb","mkds"]
print(f"{'game':14} {'frames':>6} {'hash diff':>9} {'first hash':>10} {'insn diff':>9} {'first insn':>10} {'max insn d9':>12} {'max d7':>8}  note")
for g in games:
    a=list(csv.DictReader(open(f"{S}/o_{g}_stock/frames.csv")))
    b=list(csv.DictReader(open(f"{S}/o_{g}_cheap/frames.csv")))
    n=min(len(a),len(b))
    hd=[i for i in range(n) if a[i]["fb_hash"]!=b[i]["fb_hash"]]
    i9=[i for i in range(n) if a[i]["arm9_insns"]!=b[i]["arm9_insns"]]
    i7=[i for i in range(n) if a[i]["arm7_insns"]!=b[i]["arm7_insns"]]
    first_i=min(i9+i7) if i9+i7 else None
    d9=max((abs(int(a[i]["arm9_insns"])-int(b[i]["arm9_insns"])) for i in range(n)), default=0)
    d7=max((abs(int(a[i]["arm7_insns"])-int(b[i]["arm7_insns"])) for i in range(n)), default=0)
    print(f"{g:14} {n:6} {len(hd):9} {str(hd[0] if hd else '-'):>10} {len(set(i9+i7)):9} {str(first_i if first_i is not None else '-'):>10} {d9:12} {d7:8}")
