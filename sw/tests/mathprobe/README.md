# Math hardware probe

Standalone upstream-style test sources using the common CRT, console, and
result block; no libnds dependency. Build/test registration is separate.
Native DS execution has **not** been performed. The root expectations are
mathematical floor values, not recorded silicon observations. Capture the ROM
hash, device/model, and both screens or the raw result block for every run.

The ARM9 executes eight directed 64-bit roots and one 32-bit case with a
deliberately nonzero ignored high parameter word. The common CRT leaves IRQs
and FIQs masked and IME disabled; neither CPU enables them. ARM7 only idles.
Each math wait stops after one million polls. This bounds failure handling;
it does not measure native latency. A timed-out case retains its result read
but clears its readiness bit, so that read must not be treated as completed.

## Checked result slots

The standard result block at `0x023F0000` has `n=11`; its normal pass mask
contains only the following checks. Every root value is the actual MMIO read,
including mismatches. Root checks require readiness as well as equality.

| Slot | Mode/input (high:low) | Expected floor/value |
| --- | --- | --- |
| 0 | 64 / `00000000:00000000` | `00000000` |
| 1 | 64 / `00000000:00000051` | `00000009` |
| 2 | 64 / `3FFFFFFF:FFFFFFFF` | `7FFFFFFF` |
| 3 | 64 / `40000000:00000000` | `80000000` |
| 4 | 64 / `40000000:00000001` | `80000000` |
| 5 | 64 / `FFFFFFFE:00000000` | `FFFFFFFE` |
| 6 | 64 / `FFFFFFFE:00000001` | `FFFFFFFF` |
| 7 | 64 / `FFFFFFFF:FFFFFFFF` | `FFFFFFFF` |
| 8 | 32 / `A5A5A5A5:FFFFFFFF` | `0000FFFF` |
| 9 | Nonoverflow division seed remainder low | `FFFFFFFE`; also checks full Q/R |
| 10 | First timed-out stage, zero if none | `00000000` |

Timeout stages 1–9 identify root slots 0–8; `0x100` is the division seed and
`0x101` is overflow. `done=1` means the bounded probe finished recording,
including any failures; it does not imply every math operation completed.

## Raw division observations

These use the remaining capacity of the **existing** `value[32]` array.
They are excluded from `n` and the pass mask. A decoder that only reads the
first `n` values must additionally fetch slots 11–22 for these raw fields;
slot `i` is at `0x023F0010 + 4*i`. All are displayed except the layout tag.

| Slots | Raw fields, in order |
| --- | --- |
| 11–14 | Seed quotient low/high, remainder low/high |
| 15–18 | Overflow quotient low/high, remainder low/high |
| 19–20 | Seed/overflow DIVCNT after the result reads |
| 21 | Readiness mask: roots bits 0–8, seed bit 9, overflow bit 10 |
| 22 | Layout/version tag `0x4D505231` (`MPR1`) |

The seed is signed mode-0 `INT_MIN / -3`, with quotient `00000000:2AAAAAAA`
and remainder `FFFFFFFF:FFFFFFFE`. After waiting and taking its snapshot,
**only** the denominator low word changes to `FFFFFFFF`, starting
`INT_MIN / -1`. This avoids intervening operand/control writes replacing a
nominal stale-remainder seed. Both snapshots precede console formatting.
No comparison is made against the overflow quotient or remainder: their
observed words remain raw evidence regardless of which policy they suggest.

No 64-bit formatting, floating point, multiplication, or division is used to
derive expected roots at runtime. The console prints raw 64-bit observations
as two `%08X` words, high first. A passing mask establishes only the listed
floor, seed, and completion checks; it does not qualify hardware timing,
division overflow policy, games, or the whole core.
