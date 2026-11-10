# SDRAM bport diagnostic contract

```sh
python3 sim/pocket/bport_contract/run.py
```

Requires Icarus Verilog (`iverilog` and `vvp`) and Python3. The actual
`nds_sdram_bport` captures requests and checks one changed edge per case;
no assertion is copied into the testbench and no DUT internals are forced.
Logs, commands, source hashes and results go into ignored `build/bport_contract/`.

The 557 cases cover all 16×16 read and write byte-enable transitions,
32 write-data bit changes, and directed valid/address/direction/quad controls.
Read byte enables and write data are irrelevant and may change. Writes retain
BE and full-word data checks, including disabled lanes; quad stability also
remains conservatively checked on writes. Each negative requires one concrete
message from the actual diagnostic. A compiler crash or timeout is a failure.

To compare synthesis-visible bytes against the prior source:

```sh
python3 sim/pocket/bport_contract/run.py --compare-synth /path/to/prior/nds_sdram_bus.sv
```

This preprocesses both complete files with `ALTERA_RESERVED_QIS` and requires
byte-for-byte equality. It is not a new fit or hardware qualification. Historical
pin logs retain their original error verdicts; corrected-checker runs are separate.
