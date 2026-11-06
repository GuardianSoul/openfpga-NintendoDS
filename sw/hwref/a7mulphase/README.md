# a7mulphase v1 — new-only ARM7 multiply discriminator

Four Rs values (`7f`, `7fff`, `7fffff`, `7fffffff`) use **one unchanged
272-byte kernel and one fixed MAIN copy/address**, with the same four
private-WRAM controls. Only Rs changes between multiplier cases. The
kernel has64 `MUL r3,r1,r2`, followed by SUBS/BNE bookkeeping; multiplicand3,
no inserted per-operation checksum instruction, no literal or data access
inside that body. Its4/16 independent minima use denominator768.

This distinguishes internal-cycle/MAIN-fetch overlap hypotheses left open
by DS30's single MAIN MUL32 row and DS39's ALU/branch grid. It does not
assume that an internal cycle becomes a new nonsequential fetch. Source
audit: `docs/results/arm7-main-cycle-boundary-20261102` (46daffba).

Each timed call has a separate warm1 immediately before it, for five
independent4/16 pairs. A fixed ARM wrapper snapshots pre/post r0–r12,SP,LR,
CPSR to private WRAM and returns the multiply result. Those fixed stores
are inside the call but outside the repeated MUL body; no shared output
store or MAIN data polling is inserted into the timed interval. The base
register's pre-snapshot field is saved explicitly after STM, avoiding
dependence on a base-in-list STM value. Preserve complete intervals and
all raw samples; do not subtract a fitted intercept or loop bookkeeping.

The ARM9 GO/wait helper reuses the qualified arm7fetch IRQ-masked ITCM
procedure and polls only IPCSYNC/timer I/O. Both displays are forced blank;
ARM7 sound channels are stopped. Result writes and checksum calculation
occur after each timed interval. ARM7 timer0/1 use F/1/cascade and IRQs are
masked across each sample block. Context reads record raw values, not an
assertion of identical DS boot/prehistory.

Outputs live in a new virtual/physical directory named
`/hwref/a7mulphase-v1` when the ROM is actually run. Each of eight groups
has one4096-byte record:16-word identity/layout/Rs header, before/after
ARM7 context, ten288-byte samples with warm/timed register snapshots,
and before/after512-byte live-code buffers. The80-row CSV duplicates raw
sample fields. The exact16-line START/DONE journal establishes completeness;
an incomplete START is not a timing result. The64-hex source build ID
prevents mixing different producer sources. Use a fresh directory for a
new build; the checker also binds exact linked code/layout and helper bytes.

The completion gate prints **A7MULPHASE SUCCESS** only after all eight
groups have saved, error-free records, ten matching CSV samples and durable
DONE entries. A completed resume revalidates those files and reports eight
resumed groups. A previous START without DONE counts as interrupted; damaged
DONE data counts as failed. Other exits print **A7MULPHASE FAILURE** with
complete/new/resumed/failed/interrupted counts. Generic `hw_done`/`DONE`
text alone is never acceptance. A safe completed session also writes
`a7mulphase_v1_completion.txt`; fatal timeouts/refusals may leave it absent.

ARM7 contexts include CPSR/SP, IME/IE/IF, EXMEMCNT/WRAMSTAT, timers0/1
count/control, VCOUNT, SOUNDCNT, IPCSYNC, BIOSPROT and POWCNT2. ARM9 setup
records CPSR, CP15 c1/cacheability/bufferability, all eight MPU regions,
DTCM/ITCM settings, WRAMCNT/EXMEMCNT, IME/IE and both DISPCNTs. Full runtime
ITCM bytes are saved; initialized code must match the ELF, while runtime
NOBITS/vector contents remain captured observations.

Build and verify linked inputs:

```sh
make -j1 -C sw/hwref/a7mulphase
python3 sw/hwref/a7mulphase/check.py sdk \
  --arm7 build/a7mulphase-v1/a7mulphase7.elf \
  --arm9 build/a7mulphase-v1/a7mulphase.elf \
  --build-id build/a7mulphase-v1/build-id.h --out layout.json
python3 sw/hwref/a7mulphase/check.py outputs RETURN_DIRECTORY \
  --layout layout.json --out checked.json
```

Host qualification uses the pinned Census23 executable, mode guard and
fresh virtual SD folders. Its arithmetic/state/output results are software
checks; **Census timing is not DS truth**. See
[the sealed host packet](../../../docs/results/a7mulphase-host-20261102/README.md).
No RTL/P7 change, historical probe/menu edit, physical card staging or new
deployment script is part of this probe. The coordinator can review it with
the already-built sound probe for one hardware trip.
