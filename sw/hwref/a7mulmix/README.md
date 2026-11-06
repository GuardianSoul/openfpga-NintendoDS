# a7mulmix v1: same-code mixed-width discriminator source

The SDK pair and Census23 functional/completion gates now pass in the
[SDK/software packet](../../../docs/results/a7mulmix-sdk-20261102/README.md).
This is **not staged or DS-timing-qualified**. It continues the accepted [bounded service proposal](../../../docs/cpu-a7mul-service-proposal-20261102.md).
Root coordinates with hwref before any trip, card or deployment. This directory is separate from `a7mulphase`;
no historical producer, accepted WRAM/Thumb scope, top-level probe menu,
trip list, card path, CPU/P7 RTL or timing default changes.

The existing returned MUL discriminator contains one width per run, so it
cannot choose between per-operation clipped internal work and shared
two-operation windows. These are accounting witnesses, not DS bus laws.
This source changes the register-width ordering at fixed code, with no
instruction inserted between MULs.

| Case | r2 | r6 | 64-operation body |
| --- | --- | --- | --- |
|0: all-small anchor|7f|7f|32 identical opcode pairs|
|1: all-large anchor|7fffffff|7fffffff|The same32 pairs|
|2: alternating-width|7f|7fffffff|The same32 pairs|

Each pair is `MUL r3,r1,r2; MUL r3,r1,r6`. All three cases execute **the
same272-byte kernel** at one unchanged private-WRAM address or one reused
4096-aligned MAIN slot. The first instruction sets r1=3, then64 MULs,
SUBS/BNE bookkeeping and BX LR. The two exact MUL encodings alternate
`e0030291/e0030691`; the body has no loads, literal, setters or checksum
instructions. Final r3/return is `3*r6` modulo32bits; r2 and r6 are preserved.
An independent instruction interpreter checks every decoded source/count,
not only the last overwritten product.

The inherited AAPCS snapshot wrapper now receives r6 as its fifth argument.
After saving ten registers it loads r6 from `[sp,#40]`, **before** the first
snapshot and kernel call. Its100 bytes and exact return offset+60 are
independently checked. It restores the caller's original r6 on return.
The extra constant wrapper instruction stays inside the captured interval;
it is not subtracted. The SDK qualification binds its actual linked placement, ARM/Thumb call
veneer and source bytes. The original kernel-only object test remains a
separate source proof; the linked/runtime gates are in the packet.

## Matched measurements and known conditional predictions

Run all three cases in each region: six groups, five independent4/16-loop
pairs each. Every timed call has its own warm1. Preserve all60 raw times,
120 invocations and3,840 snapshot words, full intervals and denominator768.
Do not use old `a7mulphase` absolute times or assume old linker addresses.
The new image's all-small/all-large anchors establish its own slope and
wrapper/placement effects, using the same opcodes as its mixed case.

For the retained local/shared accounting witnesses, conditional on the
matched new anchors:

| Region | Local-clipping mixed prediction | Shared-pair mixed prediction |
| --- | --- | --- |
|MAIN|Mean of new small/large slopes|New small slope|
|Private WRAM|Mean of new small/large slopes|The same mean|

If the anchors retain the old9.234375/10.234375 MAIN and
2.0625/5.0625 WRAM slopes, the predicted MAIN mixed slopes are
**9.734375 versus9.234375**; both WRAM predictions are3.5625.
The corresponding conditional MAIN short/long separation is128/512timer
ticks. These numbers do not select a bus law or certify the new anchors.
The checker reports both predictions and actual results, never fails a
structurally valid return merely because DS timing contradicts a witness.
Different anchors or an intermediate/other mixed result remain evidence.

## Retained quiet/context and completion rules

Reuse `a7mulphase`'s IRQ-masked ARM9 ITCM GO/wait helper, polling only
timer/IPCSYNC I/O. Both display engines are forced blank; ARM7 sound is off.
The ARM7 masks IRQs and uses timer0 F/1 plus timer1 cascade. Context records
retain CPSR/SP, IME/IE/IF, EXMEMCNT/WRAMSTAT, timers/count/control, VCOUNT,
SOUNDCNT, IPCSYNC, BIOSPROT and POWCNT2. ARM9 setup retains CP15/MPU/TCM,
WRAMCNT/EXMEMCNT/IRQ/display settings. Runtime ITCM bytes and initialized
ELF/helper hashes must match. Shared result writes, checksums and SD output
remain outside each timed invocation.

The new magic is `414d5831`, version1. Each4,128-byte record has a24-word
header (both operands and wrapper-return owner, six reserved zeros),
before/after64-byte contexts at96/160, ten288-byte samples at224, and
before/after512-byte code windows at3104/3616. Actual272-byte code must
match in both windows; unused code bytes stay zero. The record's ABI is
asserted in C and independently parsed in Python. Each CSV has17 columns
and duplicates both operand values, identity, all sample metadata and hashes.

Future outputs use only `/hwref/a7mulmix-v1` and `a7mulmix_v1_*` names.
The64-hex build binding prevents mixed producers. The exact12-line ordered
START/DONE journal and60-row CSV are required. `A7MULMIX SUCCESS` and its
completion record require complete6, new+resumed6, failed0, interrupted0.
A finished resume revalidates actual code, full warm/timed register state,
contexts, hashes and every CSV row. START without DONE stays interrupted;
damaged DONE fails; neither silently reruns. Generic DONE text is insufficient.
The independent checker binds actual SDK layout/ITCM, all six records and
all3,840 snapshot words; it accepts no incomplete hardware return.

## Source qualification performed here

Run only the source/object/synthetic gate:

    python3 sw/hwref/a7mulmix/test_source.py --output build/a7mulmix-source/recheck

The gate performs target-GCC syntax checks on all three C translation
units, assembles/links **only** the272-byte kernel and100-byte wrapper,
executes18 independent ISA checks (three cases × lengths1/4/16 × two
placements), and parses synthetic six-group returns. It compiles the actual
C resume/journal/CSV functions extracted without edits and tests them
against the same files. Ten actual payload faults, three opcode faults and
one fifth-argument ABI fault are rejected. A real weakened C r6 predicate
is compiled and caught. A completed resume and a structurally valid return contradicting both timing
witnesses remain accepted as evidence. Synthetic fixture times explicitly
use one witness; they are not emulator or DS measurements.

`source-checks.json` binds the successful source digests, commands, process
receipts and counts. Initial attempts rejected an inherited misleading-
indentation warning and the fixture generator's CRLF CSV header; both were
corrected before the successful check. The source-only1d2fdadb result produced no target SDK pair, NDS ROM,
Census/native model, hardware run, staging or fit; the later SDK/software
gates are now recorded separately in the linked packet. All checks
are serial NI10 with60CPU-second/1GiB caps; child commands have30-second
wall bounds. No heavy worker remains allocated.

The standalone Makefile retains the future producer build recipe; it is
not in the parent `all`, historical menu or trip chain. The exact SDK ARM7/ARM9 link, helper/call/layout audits, fresh-folder
software completion/resume/fault gates now pass in the packet. Any later
hardware staging remains under Root/hwref coordination. Preserve that
packet's exact source/ROM hashes; rebuilds need rebinding. Neither result
closes MAIN timing.
