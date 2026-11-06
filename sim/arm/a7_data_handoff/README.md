# Owned ARM7 data completion checks

Run one allocated Laptop NI10/j1/t1 worker, sequentially. Use main's absolute
`tools/laptop-run.sh` with this checkout; all compiler/model scratch stays
under `/tmp/nds-a7-data-handoff/<P7 SHA prefix>/`. Use
`FETCH=build/a7-data-handoff` to retrieve compact archives.

```
python3 -u sim/arm/a7_data_handoff/run.py leaf
python3 -u sim/arm/a7_data_handoff/run.py cpu36
python3 -u sim/arm/a7_data_handoff/run.py extra
python3 -u sim/arm/a7_data_handoff/run.py witness
```

Pinned prior receipts supply the existing coupled36, owner and mixed CPU
fixtures. The new leaf driver checks actual ACK ownership and four actual
RTL faults. The data assembly expands the actual CPU path's width/writeback
coverage. The passive observer has no DUT assignments or timing controls;
its ON/OFF run checks state and exact fixture cycles.

The result is retained under `docs/results/arm7-data-ack-20261101/` with its
offline source/model/raw checker. The reference is27340; public defaults
stay off. Enable `A7_DATA_ACK=1` explicitly for the affected native gate.
