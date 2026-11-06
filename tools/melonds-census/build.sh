#!/bin/sh
# Builds the census runner: exports the pinned melonDS submodule, applies
# melonds-census.patch and compiles into build/census-melonds.
# MELONDS_SRC: melonDS git checkout to export (default: the submodule; a
# worktree with an empty submodule can point this at the main checkout's).
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
src=${MELONDS_SRC:-$root/references/melonDS}
out="$root/build/census-melonds"
pin=$(git -C "$root" ls-tree HEAD references/melonDS | awk '{print $3}')
have=$(git -C "$src" rev-parse HEAD)
[ "$pin" = "$have" ] || { echo "melonDS at $src is $have, pinned is $pin" >&2; exit 1; }
rm -rf "$out/melonDS"
mkdir -p "$out/melonDS"
git -C "$src" archive HEAD | tar -x -C "$out/melonDS"
git -C "$out/melonDS" init -q
git -C "$out/melonDS" apply "$root/tools/melonds-census/melonds-census.patch"
git -C "$out/melonDS" apply "$root/tools/melonds-census/gx-timing.patch"
# DS-verified rules (AGENTS.md): the real DS wins where hwref pinned a rule
git -C "$out/melonDS" apply "$root/tools/melonds-census/ds-rules.patch"
git -C "$out/melonDS" apply "$root/tools/melonds-census/ds-rules-spu.patch"
git -C "$out/melonDS" apply "$root/tools/melonds-census/ds-rules-geom.patch"
git -C "$out/melonDS" apply "$root/tools/melonds-census/ds-rules-2d.patch"
git -C "$out/melonDS" apply "$root/tools/melonds-census/ds-rules-gxtime.patch"
git -C "$out/melonDS" apply "$root/tools/melonds-census/ds-rules-tmr.patch"
git -C "$out/melonDS" apply "$root/tools/melonds-census/ds-rules-tmrcnt.patch"
cmake -S "$root/tools/melonds-census" -B "$out/build" -DCMAKE_BUILD_TYPE=Release \
    -DMELONDS_DIR="$out/melonDS" >/dev/null
cmake --build "$out/build" -j"$(nproc)"
echo "built $out/build/census"
