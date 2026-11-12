# Original video reset / scaler-slot regression

The first frame warms up the original direct layout-selection logic; its pixel
rows/commands are checked, but previous-frame scaler agreement starts after its
complete emitted frame. This keeps the unrelated initial mode-switch behavior
explicitly outside the reset comparison.

The passive slot observer continues across global reset. It records every DE
falling edge, including a truncated row, then checks the last emitted command at
the following VS. Only incomplete image checking is abandoned on reset. Test
pixels and SDRAM are synthetic; no private runtime assets are used.

`run.py --out NEW_DIRECTORY` builds the current module alongside exact parent
82d264d and checks 36 stable layout/rotation/phase reset cases, 132 reset boundary
cases, 108 short-pulse reset cases, and 36 uninterrupted public-output cycle
comparisons. All six existing
scaler slots are covered. The controller model aborts pending memory on global
reset; stale responses after a new request are outside this test's contract.

`--expect-reset-failure` records the original defect when run on the original
source: 32 nonzero-slot cases fail and four Off/stacked controls pass.
`--revert` compiles the exact 82d original module, restoring the complete
scheduled-slot-only implementation, and requires that same diagnostic ledger. All helpers/source must be
committed before execution. Builds use the shared simulator lock and two workers;
queue time is separate from bounded execution time.

This does not fix or qualify upstream dynamic menu/rotation announcement timing,
full APF integration, physical scaler behavior, synthesis or FPGA capacity.

`--short-pulses` runs only 108 additional mid-DE resets: all nine layout/rotation
combinations, four video phases, and widths one through three system clocks.
The passive observer counts reset-high and post-deassertion DE falls separately;
both categories must occur. It continues until the next VS without resetting
its command history. The default run includes this suite; `--short-pulses` selects it alone.

The edge-slot candidate announces the current scaler slot directly from the
previous emitted DE level, in the low-DE output branch. The separate scheduled
slot pulse and its register are removed. Pixel/phase/memory oracles remain
unchanged, including blanking RGB in the uninterrupted public-pin miter.
