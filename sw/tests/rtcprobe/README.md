# Native RTC observation probe

Build-only preparation for DS/DS Lite homebrew loaders and Pocket. This ROM has
not been executed on physical hardware. It records raw values without declaring
one high-byte policy correct. It uses the existing minimal ARM7/ARM9 CRT and
console; no libnds, BIOS, firmware or commercial ROM is packaged.

```
PATH=/path/to/llvm-and-verilator:$PATH python3 sw/tests/rtcprobe/build.py --out build/rtcprobe-artifacts
```

The build script forces a fresh ROM build using the existing test framework,
runs host checks with ASan/UBSan, runs the same C probe against accelerated
`nds_rtc` RTL, and records commands, tools, input hashes and output hashes in
`build.json`. The `.nds` is standalone. Source files remain under this directory;
no entry is added to the existing automated 38-ROM suite or its goldens.

## Operator modes

After boot, release A/B, then press B for **IO widths only**, or A for **clock
write tests as well**. A running clock test must finish before power-off. Both
screens show raw results; photograph both and record the ROM SHA-256. A debugger
or emulator can also dump the `rtc_log` structure at main RAM `0x023F2000`.
The ROM does not write an SD log. A displayed DONE means the probe completed,
not that the observed device policy has passed a reference expectation.

B leaves RTC clock/status/alarm registers untouched. It exercises byte,
halfword and word accesses to the IO port with chip select low, then restores
the original IO halfword. Both modes skip all experiments if CS was initially
high. IO-port writes are necessary to observe high-byte readback; B is read-only
with respect to the RTC chip registers, not the ARM7 IO latch.

A first reads status2 and skips clock tests for **any nonzero status2**, avoiding
configured periodic/alarm interrupt modes. It never writes status2 or either
alarm, and never issues a reset command. It preserves writable status1 bits
1..3 through all mode changes. Reading status1 intrinsically clears transient
bits 4..7 on the pinned reference; those flags are recorded but **cannot be
restored through this interface**. This is an explicit limit to state
preservation. Use B if consuming those flags is unacceptable.

Before clock writes, A validates the original calendar/hour representation and
waits at most two timer seconds for a second transition. Invalid state or a
stopped clock skips the writes. The newly observed date/time and writable mode
are saved. After the raw cases, the original mode is restored; the saved clock
is advanced by measured elapsed whole seconds and committed at the next measured
second boundary. The final date/time and writable status are read back and
shown beside the saved and restored values. The timer is an ARM7 timer0/1
cascade at F/1024, nominally 32728 ticks per second. The log records the initial
edge bracket and restore-write duration. Phase precision is limited by that
bracket, serial write duration, timer frequency error, and real-chip write
semantics; this is not a claim of subsecond-perfect restoration. If outcome 6
appears, compare OLD/SET/GOT and verify/correct the device clock before use.
Power loss during A's write phase cannot be recovered by this ROM.

## Raw record layout

`probe.h` defines the complete versioned `RTP1` log. Each row contains
`kind,a,b,c,d` as five little-endian 32-bit words. Header fields record mode,
outcome, original IO/status, final status, timing, and saved/expected/restored
seven-byte calendars. A zero status/date field in B or a skipped stage means
that field was not captured.

| Kind | Write before observation | a / b / c / d |
|---|---|---|
| 00 | halfword 0x1250 at 0x138 | byte138 / byte139 / halfword138 / word138 |
| 01 | byte 0x50 at 0x138 | same four raw reads |
| 02 | byte 0xAB at 0x139 | same four raw reads |
| 03 | word 0xA55A3450 at 0x138 | same four raw reads, including reserved upper halfword |
| 04 | halfword 0x0050 at 0x138 | same four raw reads |
| 05 | byte 0xFF at 0x139 | same four raw reads |
| 10 | 24h date `23 04 31 09 25 5A 60` | packed date/time |
| 11 | 24h date `A0 13 00 03 13 07 09` | packed date/time |
| 12 | switch preceding date to 12h | packed date/time |
| 13 | 12h time `47 10 00` | packed date/time |
| 14 | switch preceding time to 24h | packed date/time |
| 15 | 12h time `40 00 00` | packed date/time |
| 16 | 12h time `59 80 80` | packed date/time |

Packed date/time rows: `a` is year/month/day/weekday in little-endian byte order;
`b` is hour/minute/second in its low three bytes; `c,d` are zero. Hours remain raw
chip encodings, including the PM flag. Snapshot timing can legitimately affect
seconds. No row contains a preselected native-policy verdict.

Outcomes: 1 complete, 2 initial CS high, 3 nonzero status2, 4 invalid original
date/time, 5 no second edge, 6 restoration readback differs. This probe covers
neither alarm firing nor every RTC command, and does not qualify board timing.

## Validation scope

`host_test.c` is an independent decimal serial model. It checks zero/retained
high-byte observations, both hour modes, elapsed-time restoration across all
1,200 month ends from 2000..2099, all 255 nonzero-status2 skips, IO-only behavior,
active-CS/invalid-date/stopped-clock skips, and absence of reset/alarm writes.
`rtl_test.cpp` runs the same C logic against actual RTC RTL, with four-clock IO
spacing and accelerated ticks, and verifies raw outputs plus restoration.
Neither executes the ROM's ARM machine code or establishes physical/native
behavior. The native ELF/ROM build verifies the ARM7/ARM9 source and linkage.
