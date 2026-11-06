#!/bin/sh
# Copies the card's /hwref results to ~/hwref-card/results/<time>/ (owned by
# the invoking user), then puts the latest hwref programs on it. Run with sudo.
# Source: tools/hwref/update-card.sh in NDS_Pocket; the Laptop copy is ~/hwref-card/update-card.sh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# the reader's device letter changes with what else is plugged in: find it by model
dev=
for m in /sys/block/sd*/device/model; do
    grep -q "Card *Reader" "$m" 2>/dev/null && { dev=$(basename "$(dirname "$(dirname "$m")")"); break; }
done
[ -n "$dev" ] || { echo "no card reader found, stopping"; exit 1; }
[ -b "/dev/${dev}1" ] || { echo "no card in the reader (/dev/${dev}1 missing), stopping"; exit 1; }
echo "card reader: /dev/$dev"
# a run that stopped early can leave the card mounted (often read-only): unmount it first
for m in $(findmnt -rno TARGET "/dev/${dev}1" 2>/dev/null); do umount "$m" && echo "unmounted a leftover mount at $m"; done
mnt=$(mktemp -d)
# always unmount on the way out, also when a step fails
cleanup() { sync; umount "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null; }
trap cleanup EXIT
mount -t vfat "/dev/${dev}1" "$mnt"
out="$here/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
cp -r "$mnt/hwref/." "$out/" 2>/dev/null || true
rm -rf "$out"/*.nds "$out/replay" "$out"/*mv_main.bin "$out"/*mv_calls.bin
chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$here/results"
# reading works on a read-only card, so the results above are saved; stop before writing
if [ "$(findmnt -rno OPTIONS "$mnt" | cut -d, -f1)" = ro ]; then
    echo "Results copied to $out. The card is read-only (FAT errors), so the programs were not updated."
    echo "Repair it with: sudo fsck.vfat -a /dev/${dev}1   then run this script again."
    exit 1
fi
# results are saved: clear the rand3d corpus so a shorter run leaves no old chunks
rm -f "$mnt/hwref/"rand3d_*.bin
mkdir -p "$mnt/hwref"
# copy only what changed, and count it
updated=""; nup=0; nsame=0
for f in "$here/card/hwref/"*.nds "$here/card/hwref/"*mv_*.bin; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    if cmp -s "$f" "$mnt/hwref/$b"; then nsame=$((nsame + 1))
    else cp "$f" "$mnt/hwref/$b"; nup=$((nup + 1)); updated="$updated $b"; fi
done
if [ -d "$here/card/hwref/replay" ]; then rm -rf "$mnt/hwref/replay"; cp -r "$here/card/hwref/replay" "$mnt/hwref/"; fi
trap - EXIT; sync; umount "$mnt"; rmdir "$mnt"
echo "Results copied to $out ($(ls "$out" | wc -l) files)."
echo "Programs: $nup updated, $nsame unchanged.${updated:+ Updated:$updated}"
echo "Safe to remove."
