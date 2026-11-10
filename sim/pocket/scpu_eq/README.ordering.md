# Cache request-ordering regression

Run from the repository root (requires Verilator, a C++ compiler and Python3):

```sh
python3 sim/pocket/scpu_eq/scpu_ordering.py
```

Use `--tools /path/to/bin` if Verilator is not on PATH. Builds use the existing
simulation lock and two compiler jobs. Each invocation preserves its source
copies, commands, full logs and SHA256 receipts under a new `build/scpu_ordering/run-*`.
The checked-in SERV `sw/scpu/cache.bin` is used without new firmware dependencies.

The default runs seven response schedules: ready before data, or ready 0/1/2/4/8/16
bus cycles after the **last** read word. Each runs 32 client quad reads, firmware
single reads/writes and an idle mid-run reset. Both sides use current RTL and
firmware; the reference side always uses ordinary response ordering. Accepted
transactions are snapshotted, meaningful request fields must remain stable until
ready, and returned client words are checked against an independent ROM formula.
Two negative controls must fail specifically: a premature observed address change
and a corrupted returned cache word. Compiler errors, signals and timeouts never
count as caught mutations. The original `scpu_eq.sh` and its historical-reference
bench are unchanged; the ordering top explicitly ties off reference controls.

For an isolated candidate or a focused witness:

```sh
python3 sim/pocket/scpu_eq/scpu_ordering.py --rtl /path/to/nds_cart_scpu.sv
python3 sim/pocket/scpu_eq/scpu_ordering.py --case early_4
```

RTL without the `!m_valid` request-launch guard fails the gap 4 case when a table
read is replaced before acknowledgement. That expected baseline failure must
remain a failing regression result. This abstract ordering stress does not prove
that actual board CDC reaches the failing schedule, explain unrelated pin-model
warnings, or qualify board timing/native hardware. Reset during a pending request
is outside this test.
