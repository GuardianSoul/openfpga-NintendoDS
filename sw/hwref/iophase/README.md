# Four-case ordinary I/O phase probe

Explicit standalone producer, absent from historical/all/speed-trip menus.
Build `make -C sw/hwref /absolute/worktree/build/hwref/iophase.nds -j1`.
Results are source/code-bound per-case files in `/hwref/iophase-v2`; preserve every raw row even if
all finite timing models fail. Software qualification and the exact leaf are
in [the evidence note](../../../docs/iophase-v2.md).

The reviewed four cases are prefixNOP0/1 × gapNOP0/1, sixteen repetitions.
Every NOP slot is explicit independent `MOV r8,r8`, never literal ARMv5
`nop` (`MOV r0,r0`). The timer runs and settles before the straight-line leaf. TM2 follows the
existing tmcnt save/restore convention; no display register is written.
No hardware return, deployment or timing rule is claimed by this source.
`IOPHASE_DEFS=-DIO_DATA_MUTANT` is a software negative control only and must
never enter a card selection.

Each case closes START, its raw/code/state files, a readback-verified commit,
then DONE. Valid completed cases resume unchanged; START-only cases are
skipped and remain incomplete. Binding/journal/checksum mismatches refuse
without resetting or deleting existing results.
