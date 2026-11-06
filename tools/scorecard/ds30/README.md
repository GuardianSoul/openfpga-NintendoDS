# Retained DS30 ARM7 timing adapter

`../arm7_ds30_adapter.py` wraps the retained stamp-matching original
`arm7time.nds` and its two ELFs. It preserves both complete Calico startup
paths, the original ARM9 mailbox helper/cache-policy instructions, and
the entire ARM7 image. It does not use the canonical unita7 poll helper.

Build to a fresh directory with `--captured DIR --out DIR`. Captured inputs
must have the pinned hashes in the generator. Only a408-byte ARM9 endpoint
is assembled; original kernels/helper code are never recompiled or moved.
The host gate checks25 original bodies and every patch fence, and rejects
a changed byte in the actual original `k_str` body.

Three ARM9 patches replace the FAT initialization call with return-false,
redirect the original first `buf_write` after all31 timing rows, and place
the capture code in an unused FAT routine. The original helper, Calico
runtime, display/timers/PXI/IRQ and stacks execute normally. The endpoint
copies the original CSV and33 completion-context words to023d0000, calls
the original ITCM cache flush, drains stores and loops at02001f34.

No compiler/native model should run without the coordinator's worker
allocation. This adapter is already built in the
[portable packet](../../../docs/results/arm7-ds30-adapter-20261101/README.md).
Use its exact ROM and the manifest's `native_plusargs` in the next approved
native batch. `+dump_pc=02001f34 +dump_file=arm7-ds30-main.bin` emits a4MiB
MAIN dump through the existing testbench. Read it with:

```
python3 tools/scorecard/ds30/check.py arm7-ds30-main.bin MANIFEST.json
```

The reader checks all31 row names/arguments/order and live MAIN-resident
helper/kernel bytes, and reports native versus published DS timing values.
It cannot check shared/private ARM7 WRAM or ITCM from a MAIN-only dump.
Under native boot's WRAMCNT3, original code/data at037f8000 lives in shared
WRAM; only the0380xxxx stacks are private. Use actual WRAMCNT to select
backing memory. The manifest pins the original bytes; eventual native
acceptance needs the actual loaded-memory check through the coordinator's
existing observer. The accepted capsule's earlier private-WRAM shorthand
is corrected by its adjacent `native-expectations.json`; ROM/capsule hashes
are unchanged.

The build stamp matches DSrun30 exactly. The old DS return did not record
a loaded ROM hash or live CP15/stack/cache state, so it cannot prove
bit-exact physical caller/cache prehistory. FAT/card prehistory also differs
in this simulation wrapper. Completion context is not a measurement of DS
context during the timed interval. See [scope and missing observables](../../../docs/arm7-ds30-native-adapter.md).

The next changed-source native can use `prepare_observer.py --root ROOT
--adapter ADAPTER --out FRESH_DIR`. It supplies an exact passive testbench
overlay, expected body data, hook manifest and `check_observer.py`; see the
[ready observer packet](../../../docs/results/arm7-ds30-observer-20261101/README.md).
It reads all25 actual loaded bodies and context at PING/endpoint and uses
the source-derived160-frame/3000ms allocation. Preparation never builds or
runs a model. `selftest_observer.py` checks synthetic reader controls only.
