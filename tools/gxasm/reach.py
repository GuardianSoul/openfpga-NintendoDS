"""Control-store reachability (docs/plan-next.md "RC12b 3D room"): which words of a card image no path from
RESET, the DISP handler table and the fixed entries (SUBV, SV1, DPARAM) reaches (asm.py Prog.check's walk), and
which field values only those words use. gpu3d_gxeng builds no u_voc with PU because XS = VOCW / VOCS appear
only in unreached words; this check fails if that stops being true.
    python3 tools/gxasm/reach.py [PAR ...]      (default: 0 1 2, the uf, up1 and up2 images)"""
import collections, importlib, os, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
bad = 0
for par in (sys.argv[1:] or ["0", "1", "2"]):
    os.environ.update(GX_USORT="1", GX_LUNIT="1", GX_VFIN="2", GX_FF="1", GX_PAR=par)
    for m in ("ucode", "asm", "isa"):
        sys.modules.pop(m, None)
    ucode = importlib.import_module("ucode")
    E = ucode.E
    P = ucode.P_
    P.assemble()
    use = {True: collections.defaultdict(set), False: collections.defaultdict(set)}
    for a, it in P.at.items():
        f = dict(it.f)
        if f.get("nx") == E["NX"]["DISP"]:
            f["xs"] = E["XS"]["P"]
        for k, v in f.items():
            if not isinstance(v, str):
                use[a in P.reached][k].add(v)
    unreached = sorted(set(P.at) - P.reached)
    labels = sorted(l for l, a in P.labels.items() if a in unreached)
    voc = {E["XS"]["VOCW"], E["XS"]["VOCS"]} & use[True]["xs"]
    print(f"PAR {par}: {len(P.at)} words, unreached {[hex(a) for a in unreached]} {labels}; "
          f"VOCW/VOCS in reached words: {'YES' if voc else 'no'}")
    bad |= bool(voc)
sys.exit(1 if bad else 0)
