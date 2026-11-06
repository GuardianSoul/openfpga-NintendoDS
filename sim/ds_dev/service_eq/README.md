# Shared peripheral service fixture

Codex, 2026-10-31. **Bounded native pilot and both mutants completed.**
[Results and exact source/model/log hashes](../../../docs/results/shell-service-20261031/README.md).
Production RTL is unchanged by this fixture work. The assigned Desktop worker
was released after the runs; no worker remains reserved.

Generate an immutable source snapshot and explicit build/run argument lists:

```
python3 tools/ds/service_prepare.py --source 63052f05 --out build/service630-ready
```

The generator adapts the existing SPI equivalence bench and wrapper. It uses
`nds_spi` as an independent per-byte reply and interrupt-count reference,
and the existing `nds_spi_mc`/`nds_wifi_mc` engine under contention. The
historical fitted engine cost is 269.3 ALMs (#389), against 697.1 for the
older WiFi implementation (#383). No new subsystem or replacement is added.

The original clock-by-clock comparison remains a diagnostic. After each SPI
byte, both sides must become idle before the next write; settled reply data
must match and IRQ totals must match. This prevents a longer busy interval
from turning later driver writes into artificial dropped bytes. The existing
`DIFFER` summary alone is not the new acceptance result; require
`SERVICE_PASS`, zero reply mismatches, nonzero IRQ coverage and native exit 0.

Independent clients exercise WiFi RAM write/read patterns, enable timer work,
and repeatedly execute EEPROM WREN/RDSR/WRDI/RDSR with literal status checks.
The EEPROM path covers status events, not physical save-memory operations.
The memory model holds responses for 1, 20 or 80 engine clocks. WiFi requests
pulse for one clock while address/data remain held through the reply; this
avoids spuriously queuing duplicate requests. Explicit WiFi/AUX request-start
counters must show overlap with an active SPI byte. Transaction totals alone
do not qualify overlap. A deterministic 16-byte fastest-baud firmware READ
control precedes random traffic; fastest-baud event age and hold ticks are
reported separately. Timer request
and dispatch counters reject backlog beyond one event. SPI engine-event age,
WiFi/AUX response age and timer counts use engine clocks; busy extensions
are counted separately in DS-enable ticks (`*_hold_ticks`). Do not add the
engine and firmware hold counts: they may overlap.

The 16 prepared cases cover two seeds each for isolated SPI, WiFi, AUX and
combined traffic, including the WiFi/combined memory-delay variants. A fixed
seed is not a claim that every case makes the same number of transactions
inside its cycle cap. Compare settled values and explicit service intervals;
do not infer a game-speed ratio from total transaction counts.

The bounded execution order, after allocation, is: build with one job/one thread, run the
isolated control then combined latency 1. Record native model/source hashes,
PID and logs. Prove the checker catches a dropped SPI completion or corrupted
WiFi read; then expand the matrix only if the pilot leaves a useful question.
If no service response extends, report the observed bound. If contention
extends busy or loses a timer event, preserve that case and measure the DS
before choosing hardware-visible timing changes. Existing standalone SPI
behaviour and the DS remain separate references.

The generator contains the complete explicit build/run commands in its
`plan.json`; it never executes them. Do not substitute a native binary built
on another machine. Use main's absolute Laptop helper if the coordinator
assigns the Laptop, and clean this session's finished mirror afterwards.

## Exact executed pilot commands

The current authoritative prepared snapshots are `service12e-qualified`,
`service12e-qualified-no-done` and `service12e-qualified-corrupt-read` under this worktree's build directory. The three positive controls and both negative controls have now run;
these preserved commands describe the source-specific pilot.
After a worker is assigned, the baseline pilot is:

```
nice -n 10 python3 /home/user/Git/NDS_Pocket-codex-shell/tools/ds/service_run.py --plan /home/user/Git/NDS_Pocket-codex-shell/build/service12e-qualified/plan.json --case isolated-s1 --case both-s1 --allocation "record actual coordinator worker"
```

The two explicit negative controls use the same selected case:

```
nice -n 10 python3 /home/user/Git/NDS_Pocket-codex-shell/tools/ds/service_run.py --plan /home/user/Git/NDS_Pocket-codex-shell/build/service12e-qualified-no-done/plan.json --case both-s1 --baseline-proof /home/user/Git/NDS_Pocket-codex-shell/build/service12e-qualified/both-s1/manifest.json --allocation "record actual coordinator worker"
nice -n 10 python3 /home/user/Git/NDS_Pocket-codex-shell/tools/ds/service_run.py --plan /home/user/Git/NDS_Pocket-codex-shell/build/service12e-qualified-corrupt-read/plan.json --case both-s1 --baseline-proof /home/user/Git/NDS_Pocket-codex-shell/build/service12e-qualified/both-s1/manifest.json --allocation "record actual coordinator worker"
```

The first disconnects the SPI event completion from its receiving front end;
its expected rejection is the bench watchdog. The second corrupts actual
memory-model read data; the WiFi round-trip checker must reject it. Both
mutants were caught in simulation against the corrected passing control. Their plan/source hashes
are distinct; no baseline snapshot was modified.

`service_run.py` records compiler/model PIDs, allocation, hostname, source-plan,
runner, model and log hashes. It refuses changed inputs, existing case output,
and native binaries from another host. It stops the selected sequence on the
first unexplained failure. The log parser requires native completion,
`SERVICE_PASS`, actual configured overlap, complete counters and reply/IRQ
coverage. Four lightweight acceptance/provenance checks pass, including rejection of missing
coverage and corrupt/mistargeted summaries. The native pilot and caught mutants are recorded separately in the result link above.

The concrete hypothesis is nonpreemptive WiFi register/timer work postponing
fast-baud SPI or AUX events. Busy may extend after 128 engine clocks despite
correct final data. Engine-vs-firmware hold ticks and timer due/dispatch counts
separate queue contention from firmware-memory starvation. Neither the unit
clock period nor these counters assert new DS hardware timing.

The snapshots pin combined `12e1c032` (the shared engine is byte-identical
with the earlier `63052f05` fixture). All three native variants built with one job/thread and nice10; the
isolated/combined latency1 and targeted combined latency80 controls passed
settled data/IRQs, and both negative controls were caught. Earlier service630/service12e-pilot snapshots
are retained historical preparations; use the bounded snapshots above.

The runner requires each mutant to reference the successful unchanged
`both-s1` manifest. It verifies that baseline's plan/log/source hashes and
configuration, and permits only the intended wrapper source to differ.
A watchdog or bad read without a qualified positive control cannot close
checker sensitivity.

**Game-visible question:** do firmware SPI bytes, their completion IRQs and
AUX status replies remain correct when retained no-peer WiFi register/RAM
and timer work share the engine? Measure whether a fast SPI busy poll extends
from engine contention or firmware-memory starvation. An observed extension
needs DS timing qualification before any behavior change. This fixture does
not prove save-memory programming/persistence or an entire game's behavior;
AUX status handling and HeartGold's completed unchanged-save comparison are
separate, narrower evidence. The fine US_COUNT prototype remains disabled.

The initialized-ready observer now stays true during every post-reset engine
state, including memory waits. The older IDLE/RUN-only expression dropped IRQ
observations under long memory waits and is retained as an invalid-fixture
witness in the result archive. The fresh qualified snapshots reran all
controls and mutants after that observer correction.
