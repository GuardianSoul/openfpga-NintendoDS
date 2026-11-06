# Run39 exact-kernel native adapter

This software-only adapter measures the qualified DS run39 ARM7 fetch
kernels on the combined Pocket model. It does not select an N/S price,
prefetch-retention rule or RTL timing correction.

`captured.tar.gz` freezes all36 original DS result records, their qualified
ELF layout, and the2024-byte ARM9 runtime ITCM helper. Its internal manifest
checks every member. The DS import is the coordinator's validated
`build/coordinator/hwref-run39-20261101/returns/arm7fetch-v1`, HWW checkpoint
`9d5667ae`; original ARM7/ARM9 ELF identities remain in `layout.json`.

Build with `python3 sw/tests/a7fetch39/build.py`. All18 kernels retain their
exact bytes, private-WRAM entries `03800480..03803fc0`, and distinct original
MAIN slots `02fcd000..02fde000`. The ARM9 helper retains all captured bytes
at `01ff8000`, entry `01ff8020`. `build.json` records source/input/ROM hashes,
commands and the ARM9 PC for the existing model's one-shot RAM dump.

Both screens are forced blank and sound is disabled. ARM7 timers0/1 run at
F/1+cascade. Each of36 groups executes five4/16-loop pairs, warming one
complete loop before **every** timed call. IRQs are masked, result writes
are outside the timed interval, and GO/DONE is controlled by the unchanged
captured ITCM helper. Its stack is DTCM; during GO/DONE it fetches from ITCM
and accesses only timer/IPCSYNC I/O and private memory. Result address
`02fdf000` and ARM9 alias `023df000` match DS. Native copies are retained in
36 separate MAIN records outside either code bank.

The native boot, stack addresses and raw FIFO commands replace Calico/SD
services outside timing. The ARM7 timer wrapper is rebuilt rather than
claimed byte-identical, and both CPUs remain IRQ-masked outside timing too.
Before the first group and after the last, ARM9 exports all2024 ITCM bytes
for comparison against the original runtime snapshot. The untimed result
export uses word copies to reduce native simulation time; ARM7 code and
timed operations are unchanged. These execution-context differences remain
qualifications on the timing comparison.

`native.py` reuses an explicitly bound coordinator binary. It verifies the
exact model and ROM hashes, journals its owned PID, keeps NI10/t1, and uses
the frozen project-aware worker guard. Its runtime and guard copies live
under the output directory. Long runs use main's absolute `laptop-run.sh`.

Run `python3 sw/tests/a7fetch39/check.py MAIN.bin --log RUN.log --out comparison.json`.
The checker requires36 completed groups,360 raw timings and warm/timed
checksums, exact kernel snapshots/descriptors and all18 final MAIN slots.
It retains independent min4/min16 values and every raw sample. Slopes use
`(min16-min4)/768` in ARM7 cycles; ring units are whole rounds, with no
bookkeeping subtraction. Five altered result/code/checksum/address inputs
must fail. Native model/video/VM checks are required separately from timing
agreement. No structural RTL change or RTL equivalence claim is made.
