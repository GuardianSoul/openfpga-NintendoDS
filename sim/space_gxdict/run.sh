#!/usr/bin/env bash
# sim/space_gxdict/run.sh TB TAG: the kh358 census trace through tb_geom binary TB (docs/space-gxdict.md);
# DICT mismatches ($error from g_romd's old-ROM check) and the summary line.
cd "$(dirname "$0")/../.."
tb=$1; tag=$2; out=build/space_gxdict/runs; mkdir -p $out
trace=${TRACE:-/home/user/Git/NDS_Pocket/build/census/kh358/gx.bin}
$tb --trace "$trace" > $out/$tag-kh358.log 2>&1; echo "exit $?" >> $out/$tag-kh358.log
echo "$tag: $(grep -c 'DICT' $out/$tag-kh358.log) DICT errors; $(grep 'frames, ' $out/$tag-kh358.log); $(tail -1 $out/$tag-kh358.log)"
grep -m1 'DICT' $out/$tag-kh358.log
