# Local Nintendo DS improvements

This branch extends GuardianSoul's `e973fc810663443e67f3efd7e920b3a7df74cf92`.
The core is experimental. The packaged build has not been run on a physical
Pocket; the upstream compatibility limitations still apply.

## Changes

- Square root: keep the complete trial term for 64-bit inputs, reduce the
  proven remainder width to 34 bits, and directly index input nibbles. For
  example, `sqrt(0x4000000000000001)` must return `0x80000000`. Tests check
  the mathematical floor independently of the implementation recurrence.
- Display capture: reuse the existing, aligned opacity flag instead of
  recomputing an eight-bit nonzero comparison on the capture path. Pixel
  data, pipeline latency and register count at the RTL level are unchanged.
- Cartridge controller: keep each memory request stable until the memory
  interface acknowledges it, including when returned data arrives earlier.
  Acknowledgement of returned SERV words remains unchanged. A following
  request waits for acknowledgement of the preceding memory request.
- Packaging: include the required 12 KiB ARM/SERV boot image and third-party
  notices. Reject oversized boot regions before replacing package output.
- Simulation: match burst order to the compiled critical-word-first option,
  drive both fast-profile clocks, rebuild when effective options change,
  and repair current-tool, address-range and reset diagnostics.
- Validation: require actual monitor completion and meaningful mutation
  witnesses. Read byte enables may vary while waiting for acknowledgement;
  valid, address, direction, quad, and write payload checks remain active.

## Build and checks

The selected complete `apf_top` build uses Quartus Standard 25.1std.0
(build 1129), the original `5CEBA4F23C8` board, clocks, pins and SDC, and
seed `1asR`. The build script selects STANDARD FIT and MAXIMUM router timing
effort. No timing requirement was relaxed and no core features were removed.

```sh
# Requires licensed Quartus tools on PATH and Python3 with Pillow.
scripts/build_ds.sh "$PWD/build/pocket" 1asR
```

The completed build passes all 156 baseline timing analyses, including TNS.
Minimum setup slack is +0.160 ns; minimum hold slack is +0.068 ns. Resource
use is 18,272/18,480 ALMs, 20,285 registers, 308/308 RAM blocks, 65/66 DSP
blocks, and 224 physical pins with no virtual pins. Its complete build driver
returned zero and confirmed its source inputs stayed unchanged.

Assembled RBF SHA256: `66a89af1a8c81a6bb015d406f7b5044de02a7298b24b52b4bab8798e51d05a7e`.
The accompanying `build-receipt.json`, package filename and source archive
identify the exact final Git commit and package hashes. The final package is
rechecked against this assembled RBF, required boot bytes, metadata and
licenses. Different seeds/tool versions can give different fitting results.

Useful checks from the repository root, with Verilator/Icarus and a C++20
compiler installed:

```sh
python3 tools/ds/qlint.py
make test-sys TOOLS=/path/to/oss-cad-suite/bin
python3 sim/pocket/bport_contract/run.py
python3 sim/pocket/scpu_eq/scpu_ordering.py --tools /path/to/verilator/bin
python3 sim/pocket_ds/test_run_verdicts.py
```

The controller regression runs seven response schedules plus two deliberate
corruptions that must be detected. Diagnostic checks cover 557 cases. Further
simulation requires separately supplied BIOS/firmware and homebrew test assets;
no Nintendo BIOS, firmware or commercial ROMs are included in the release.

The completed `nds_top` regression records 36/38 passing cases. This model
does not instantiate the Pocket cartridge controller; the separate complete
APF simulations below cover that change. The retained
`plane` and `affdma` golden-image failures produce the same frame bytes as the
corrected upstream model; the goldens were not changed. GPU2D stress deadlines,
two unsupported ARM MPU-abort tests, and device throughput/RTC-policy failures
also remain. CPU timing test completion does not establish native DS timing.

Three complete APF/SERV/SDRAM/PSRAM simulations pass math, DMA/touch and cached
CPU workloads, with zero mismatches over 51,552 sampled VRAM words. These use
the selected functional RTL. Original runs with the older diagnostic retain
their failed verdicts. Ordinary-order ROM values, video completion times and
memory counters match across the controller fix in these three workloads.

Quartus timing covers the existing constraints. Four active input ports and
23 active output ports lack external board timing budgets; SRAM false paths
and SDRAM/PSRAM budget assumptions still need board evidence. Physical Pocket
boot, gameplay, controls, audio, saves and resets, plus native DS arithmetic
observations, remain pending. This build is for local validation.
