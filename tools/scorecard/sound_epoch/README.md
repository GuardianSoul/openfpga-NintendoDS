# Original C19 c7684 epoch supplement

This host-only observer extends the qualified original perftime entry hook.
`prepare.py` pins the original799bc51 frontend, exact C19 core/link objects,
headers and shipping ROM. `observer.inc` records raw same-event clocks,
four relevant timer records and the last two SPUMix callbacks. `check.py`
binds the supplement to the original retirement metadata.

The approved private `fat_time_fixture.cpp` is an **external filesystem
input**, linked with `--wrap=get_fattime`, matching the recorded original
FAT directory word. It must not become a generic core timing/RTC override.
No guest RAM edits or hash exceptions are used. Original20entry members
and89outputs are mandatory byte-equality gates before accepting the epoch.

`SOUND_EPOCH_WRONG_BOUNDARY` defers only supplemental observation to the
actual next ARM7 retirement. Its actual execution is rejected while the
original20+89files remain exact. The first unpinned15-byte FAT-time failure
is retained separately. See [qualified results](../../../docs/sound-epoch-c19.md)
for exact source/binary/epoch identities, commands and limits.

Compilation/emulation requires an allocated worker lease; source preparation
does not allocate one. This does not create a native model, new DS probe,
oracle migration, or frame/sample alignment.

The separately assigned bounded follow-up uses `prepare_window.py` and
`run_window.py`. It extends the retained qualified frontend with
`window.inc`: the original entry plus the first subsequent037f80dc and
its next256 ARM7 retirements, post-instruction register snapshots,
pre-access timer MMIO/data writes, and any mixer/SPU-write callbacks
inside that window. It still checks all20+89 original files and the
accepted epoch byte-for-byte, using the same external FAT input.
`check_window.py` checks bounded coverage; `compare_window.py` matches
the actual257-PC prefix of the existing native39 observer. Neither
estimates a timestamp offset. See
[bounded results](../../../docs/sound-window-c19.md).
