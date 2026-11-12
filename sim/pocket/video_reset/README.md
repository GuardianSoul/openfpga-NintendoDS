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
cases, and 36 uninterrupted public-output cycle comparisons. All six existing
scaler slots are covered. The controller model aborts pending memory on global
reset; stale responses after a new request are outside this test's contract.

`--expect-reset-failure` records the original defect: 32 nonzero-slot cases fail
and four Off/stacked controls pass. `--revert` builds the one-expression revert
mutant and requires that same diagnostic ledger. All helpers/source must be
committed before execution. Builds use the shared simulator lock and two workers;
queue time is separate from bounded execution time.

This does not fix or qualify upstream dynamic menu/rotation announcement timing,
full APF integration, physical scaler behavior, synthesis or FPGA capacity.

`--short-pulses` runs only 108 additional mid-DE resets: all nine layout/rotation
combinations, four video phases, and widths one through three system clocks.
The passive observer counts reset-high and post-deassertion DE falls separately;
both categories must occur. It continues until the next VS without resetting
its command history. This test-only extension reuses the prior byte-identical
RTL proof; it does not relabel old executions as runs of new helper bytes.
