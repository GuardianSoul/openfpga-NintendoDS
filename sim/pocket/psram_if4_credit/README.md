# IF4 paired-commit credit checks

These adapt pinned c74/2c620703 fixtures to the exact e704/b4df physical
control. Outputs, models, source hashes and commands go under `/tmp`.
Use one allocated Desktop worker, NI10/j1/t1. Run sequentially:

```
python3 sim/pocket/psram_if4_credit/cpu.py
python3 /tmp/nds-if4-credit-cpu/run.py
python3 sim/pocket/psram_if4_credit/physical.py
python3 sim/pocket/psram_if4_credit/delivery.py
```

Use fresh output directories for a new source. The physical runner can
resume accepted cases only when source/model hashes match; preserve failed
attempts before correcting a fixture. CPU.py freezes sources and generates
the coupled runner; its negative proof is the seven actual physical/delivery
RTL mutations. CPU/P7 semantics are unchanged.

The retained result and offline checker are under
`docs/results/arm7-if4-pair-credit-20261101/`. Its measured source/profile,
phase coverage and unresolved native/DS timing limits apply to that result.
