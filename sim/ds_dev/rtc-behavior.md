RTC behavior regression
=======================

`nds_rtc` keeps its existing 16-byte field RAM, serial cadence, LFSR timebase,
and deferred-second/reset machinery. Hours are canonical 24-hour BCD internally.
Serial 12-hour values use 00..11 plus bit 6 for PM, including 00 for midnight/noon.
Mode writes change representation without changing the instant represented.
Date/time writes mask unused bits and map invalid BCD or out-of-range fields to
the field minimum. A sanitized day beyond the current month's length becomes
1 and advances the month using the existing count sequencer. The carry completes
within two clocks after the field write; ARM7 IO writes are four clocks apart.

Behavior source: melonDS `src/RTC.cpp` at
`7d8dea42e221b13521270c423b61add41a741b97`, SHA-256
`9ea66eec8bad7d4065829266a4f3fd869d331b1a6db9399afdb4154956de35a6`.
Relevant functions are BCDSanitize, WriteDateTime, CheckEndOfMonth, CountHour,
and CmdWrite. These are reference semantics, not newly measured native DS
behavior. The independent C++ oracle uses decimal arithmetic and calendar tables.
No reference source or private runtime asset is copied into this test.

Run the isolated regression with:

```
make test-dsdev VERILATOR=verilator DSDEV_ARGS='--only rtc-exhaust'
python3 sim/ds_dev/rtc_behavior_mutate.py --verilator verilator
TOOLS=/path/to/tools sim/ds_dev/equiv/rtc_eq.sh
```

The isolated gate does not require firmware. It exhausts all 256 input bytes for
all seven fields; every day byte for every month in ordinary and leap years;
hour writes and mode changes in both modes; all 24 hour boundaries in each mode;
and every month/year boundary in 2000..2099. It also checks four-clock IO spacing,
partial-field cancellation, a read held across three seconds, release of its one
pending second, reset commands in both modes, a reset with a pending second,
and hardware reset after nonzero state.

The negative-control runner first requires an unmodified passing baseline.
It then independently corrupts digit validation, day carry, PM input,
mode-dependent output, decimal hour carry, leap years, century wrapping, and
CS count deferral. Each must produce a functional failure in `rtc-exhaust`;
a compile error, timeout, or unrelated existing suite failure is not a catch.
Build and run logs remain in separate per-control directories.

The historical equivalence entry point now compares valid 24-hour traffic
against `bbf3e35`. Sanitation and 12-hour behavior intentionally differ from
that reference and are tested against the decimal oracle instead. The default
40 seeds at gaps 3/4/16 compare 360,000 randomized operations and the complete
registered IO output on every cycle. Per-seed logs are retained. The inactive
historical bridge-load generator is not a tested feature.

The original full device suite's high-byte expected values are unchanged and
still produce two explicit failures: RTL reads zero while the pinned reference
retains written high bits. Native DS evidence is needed before changing this
policy. Four separate firmware-throughput assertions also remain outside this
RTC change. Alarm interrupts remain unimplemented. Whole-chip area, placement,
and timing must be measured on the combined candidate; preserving the RAM
array alone does not establish fit or timing closure.
