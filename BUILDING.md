# Building

## Tools

- Quartus Prime Lite 25.1 with Cyclone V device support
- Python 3.10 or newer
- For simulation and tests: Verilator, Icarus Verilog and Yosys (for
  example from the [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build);
  the Makefile looks in `build/tools/oss-cad-suite/bin`, or set `TOOLS=`)
- For the boot program and the CPU test images: clang, ld.lld and
  llvm-objcopy
- For the DS test programs in `sw/hwref` (optional): devkitPro's devkitARM,
  libnds and calico
- For the plugin in `tools/pocket-plugin` (optional): Rust with the
  `wasm32-wasip1` target

## Get the source

```bash
git clone --recurse-submodules https://github.com/GuardianSoul/openfpga-NintendoDS.git
```

For an existing checkout, run `git submodule update --init`. The only
submodule is melonDS (`references/melonDS`). It is the behaviour reference
for the census tool and the golden models; the core itself doesn't use it.

## Build the core

```bash
scripts/build_ds.sh build/ds 1asR
```

This runs `tools/ds/qlint.py`, generates the Quartus project under
`build/ds`, runs synthesis, fitting, assembly and timing analysis, and
packages the result as `build/ds/package/NDS.zip` if timing passes. The
second argument is the fitter seed with optional Quartus setting letters,
documented at the top of the script. `1asR` (seed 1, aggressive area, resource
sharing, aggressive routability) is the usual one. The design is close to
the chip's capacity, so a different seed can fail to fit.

`build/ds/result.txt` summarises the outcome. The core must pass timing at
every corner.

The boot program `sw/boot/bootrom.bin` and the shell firmware
`sw/scpu/cache.bin` are checked in, so a build needs no ARM or RISC-V
compiler. `make bootrom-check` rebuilds the boot program from its sources
and checks that the checked-in copy matches.

## Test

```bash
make test           # the CPU pipeline, 3D, 2D, sound, system and device tests
make fetch-tests    # first: the CPU test ROM sources, into local-assets/
```

Most tests need no BIOS or game data. Some checks compare against melonDS
and need your own BIOS, firmware or games, and some of the scripts under
`sim/` were written for the development machines. They are kept as a record
of how each part was checked, but may need their paths adjusted.

## Repository layout

| Path | Contents |
| --- | --- |
| `rtl/ds`, `rtl/arm`, `rtl/sys`, `rtl/gpu2d`, `rtl/gpu3d`, `rtl/sound` | The DS: CPUs, memory system, DMA, timers, 2D and 3D engines, sound, cartridge, SPI, RTC |
| `rtl/pocket`, `rtl/mem`, `rtl/apf`, `rtl/serv` | The Pocket side: top level, memory controllers, video, audio, controls, data slots, and the shell CPU |
| `sw/boot`, `sw/scpu` | The direct-boot program and the shell CPU's firmware |
| `sw/hwref`, `tools/hwref` | Test programs for a real DS and their analysis tools |
| `sim/` | Testbenches, golden models and equivalence checks |
| `tools/` | The melonDS census, packaging, settings, plugin and analysis tools |
| `scripts/` | Build scripts |
| `support/` | Pocket artwork |
| `references/melonDS` | Pinned melonDS (submodule) |

## Contributing

Issues and pull requests are welcome. Before you change RTL, run
`tools/ds/qlint.py` and the tests for the part you changed. A change that
should keep behaviour the same needs an equivalence check against the
version before it.
