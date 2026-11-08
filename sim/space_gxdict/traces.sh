#!/usr/bin/env bash
# sim/space_gxdict/traces.sh TB: the other census traces (heartgold, replay/*) through TB one after another
cd "$(dirname "$0")/../.."
c=/home/user/Git/NDS_Pocket/build/census
for t in heartgold replay/hg-battle replay/hg-ow replay/mkds replay/nsmb replay/platinum-ow; do
  TRACE=$c/$t/gx.bin bash sim/space_gxdict/run.sh "$1" "new-${t//\//-}" | sed 's|/home/user/Git/NDS_Pocket/build/census/||'
done
