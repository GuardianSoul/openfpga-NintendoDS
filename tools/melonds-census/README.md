# melonDS hardware census

Logs which DS hardware a game uses, using melonDS (pinned submodule
`references/melonDS`) with observer hooks added. Plan step 0.1. Nothing here
runs on the Pocket.

```sh
tools/melonds-census/build.sh            # export submodule, apply patch, build
build/census-melonds/build/census \
  --bios9 roms/bios9.bin --bios7 roms/bios7.bin --firmware roms/firmware.bin \
  --rom roms/heartgold.nds --save roms/heartgold-100.sav \
  --script tools/melonds-census/scripts/heartgold.txt \
  --out build/census/heartgold --frames 3600 --shot-every 300
```

`MELONDS_SRC=<melonDS checkout>` makes `build.sh` export from another
checkout at the pinned commit (a worktree's submodule is empty; use the main
checkout's `references/melonDS`). `check_observer.sh` takes `ROMS=<dir>` for
the BIOS and firmware in the same way.

The runner uses the interpreter CPU and the software renderer, boots with the
real BIOS and firmware, and direct-boots the cartridge. It runs at roughly
150–250 frames per second.

## Files

| File | Purpose |
| --- | --- |
| `melonds-census.patch` | Adds `src/Census.h` and hook calls to melonDS (GPL-3.0, like melonDS). |
| `Census.h`, `apply_hooks.py` | Source of the patch: the hook header, and the script that inserts the hook calls into a fresh tree (for repinning melonDS). |
| `census.cpp`, `platform.cpp` | Headless frontend: scripted input, counters, outputs. |
| `gx2scene.cpp` | Turns a `gx.bin` trace into renderer scenes (below). |
| `check_observer.sh` | Shows the hooks don't change emulation (see below). |
| `scripts/*.txt` | Input scripts for each census session. |

## Input scripts

One line per held input: `<first> <last> KEY...` holds keys for frames
`first..last` inclusive. Keys: `A B SELECT START RIGHT LEFT UP DOWN R L X Y`.
`<first> <last> touch <x> <y>` holds a touch at bottom-screen pixel (x, y),
converted through the firmware's touch calibration. The touch is census-only,
for menus that need it; the Pocket core has no touch input. `#` starts a
comment.

## Homebrew SD card

`--sd-dir DIR` gives a homebrew ROM melonDS's DLDI SD card: a 64 MiB FAT
image (`OUT/sd.img`) built from DIR at load and synced back to DIR at exit.
`tools/hwref/run_melonds.sh` uses it for the hardware-reference programs
(docs/hw-reference.md). Without the option the runner is unchanged.

## Savestates

`--save-state F --save-state-at N` writes a melonDS state at the start of
frame N. `--load-state F` starts from a state. Script, screenshot and trace
frame numbers then count from the state. States only load in the same
melonDS savestate major version (14 at the pinned commit), so RetroArch
melonDS states don't load. Round trip: after reloading, the run matches an
uninterrupted run on every frame except the first. The first frame differs
because the displayed picture lags one frame and isn't part of the state.

## Golden-model traces

For instruction-by-instruction comparison with the RTL (`tools/ds-trace`,
formats there):

- `--trace-dir DIR [--trace-insns N=20000000] [--trace-from-frame F=0]`
  writes `arm9.trc`, `arm7.trc` (retired instructions), `arm9.wr`,
  `arm7.wr` (CPU and DMA writes) and `irq9.txt`, `irq7.txt` (IRQ entries).
  With `F = 0` the trace starts at the direct-boot entry. Each CPU stops
  recording after N instructions. The run ends early once both have.
- `--trace-perturb CYCLES`: the ARM9 loses CYCLES (ARM9 clock) just before
  the first traced instruction. This is a deliberate timing change for
  testing the compare tool, and not for normal use.
- `--dump-boot DIR`: the state right after `SetupDirectBoot`, before the
  first instruction:
  - `main.bin` (4 MiB), `swram.bin` (32 KiB), `wram7.bin` (64 KiB),
    `itcm.bin`, `dtcm.bin`
  - `state.txt`: both CPUs' registers with the banked slots and SPSRs, the
    CP15 registers `SetupDirectBoot` writes, and the I/O registers it sets
    (WRAMCNT, POWCNT1/2, EXMEMCNT, POSTFLG, ROMCTRL, AUXSPICNT, RCNT,
    SOUNDBIAS, ...)

melonDS direct boot leaves both CPUs in **SVC mode** (CPSR `0xD3`), not
in System mode. The stack pointers are set up as follows:

| Register | ARM9 | ARM7 |
| --- | --- | --- |
| `r13_svc` | `0x03002F7C` | `0x0380FD80` |
| `r13` user/sys (the `R_SVC` slot) | `0x03003FC0` | `0x0380FFC0` |
| `r13_irq` | `0x03003F80` | `0x0380FF80` |

`r12 = r14 = entry`. The game's crt0 sets its own modes and stacks at once.
An RTL testbench that lockstep-compares from the entry must still load
this exact state, from `state.txt`.

The trace hooks (`Retire`, `DataWrite`, `IRQEntry` in `Census.h`) are only
installed with `--trace-dir`. With them installed, a 1,272-frame HeartGold
smoke run, which stopped at 100M instructions per CPU, matched the
unhooked run's framebuffer hashes on every frame (2026-10-23).
`check_observer.sh` also still passes: the mutation was caught at frame 285.

## Outputs

- `frames.csv`: one row per frame:
  - CPU busy % (cycles executed, not halted)
  - modelled ARM9 cache accesses and misses
  - external-bus bytes per CPU and region
  - 3D polygons and vertices, estimated pixel area
  - DMA bytes
  - cartridge commands and bytes
  - active sound channels
  - OBJs per line and OBJ render cycles per engine (see the budget below)
  - VRAM bytes read per unit (`2da`, `2db`, `3d`, `cap`) and per bank (A–I,
    `x` = unmapped), the worst line, and the frame's 8-byte fetch and
    32-byte block counts
  - polygon line coverage of the frame's flush: `poly_lines` (sum of polygon
    heights) and `line_polys_max` (most polygons on one line), for the
    polygon-stream cost in plan 0.4
  - framebuffer hash (always the last column)
- `summary.json`: per-run percentiles plus histograms:
  - 3D features (`DISP3DCNT`, polygon attributes, texture formats and sizes)
  - geometry commands
  - VRAM bank configurations
  - 2D line configurations and features
  - display capture
  - DMA by mode and route
  - cartridge read sizes
  - sound formats
- `vram_lines.csv` (with `--vram-trace-first F [--vram-trace-frames N=60]`):
  one row per frame, line, unit and bank with nonzero reads:
  `frame,line,unit,bank,bytes,seq8,b32` (meanings below). Bank `-` is
  unmapped space. Rows for a line come in unit order `2da, 2db, 3d, cap`.
  This is the replay input for plan step 0.4: each row is the demand one
  unit puts on one bank during one line (63.5 µs). Cost it as `seq8`
  8-byte reads for a core without a cache, or `b32` 32-byte reads for a
  core with a per-line 32-byte cache. `cap` rows are capture writes, plus capture
  source B's line reads when that source is VRAM.
- `cart_trace.csv` (with `--cart-trace 1`): every cartridge data read (`B7`):
  `frame,line,sys_cycle,addr,len`. `sys_cycle` is the ARM9 clock in DS system
  cycles (33.514 MHz). This is the input for the SD-streaming analysis in
  docs/memory-replay.md.
- `shots/fNNNNNN.ppm`: both screens, every `--shot-every` frames.
- `gx.bin` (with `--gx-first F --gx-frames N`): every executed geometry FIFO
  entry, the 3D registers at each flush, and all nine VRAM banks every
  `--vram-every` flushes (default 30). The record layout is in `census.cpp`
  above `TraceVram`. Geometry-engine state (matrix stacks) from before `F` is
  not saved. Some games reload their matrices every frame (KH does); others
  load the projection once (HeartGold), so start the trace before the scene
  loads.

## Scene replay (`gx2scene`)

`build/census-melonds/build/gx2scene gx.bin OUTDIR [--skip N=2] [--exact-vram]`
replays a `gx.bin` through melonDS's geometry engine and writes one
`G3DSCN01` renderer scene per flush for the 3D rasterizer harness:
- the sorted `RenderPolygonRAM`
- the latched render registers
- the flat texture/palette VRAM, rebuilt from the latest `V` record

It checks each flush's polygon and vertex counts against the trace and
exits 2 on a mismatch. `sim/gpu3d/replay.sh gx.bin DIR` converts a trace
and diffs every scene RTL against melonDS (docs/renderer-3d.md, "Real-game
replay").

## Models and their limits

- **ARM9 caches.** melonDS does not model them, so the census runs its own
  tag-only model on every ARM9 fetch and data access:
  - 8 KiB I-cache and 4 KiB D-cache, 4-way, 32-byte lines, round-robin
  - cacheability from the MPU map
  - read-allocate; writes go to the bus unless they hit a write-back line
  - a miss counts as a 32-byte line fill on the bus
- **VRAM traffic** comes from the renderers' own reads. The patch wraps
  every VRAM index in melonDS's 2D soft renderer (`bgvram[...]`,
  `objvram[...]`, BG and OBJ extended palettes) and hooks the 3D soft
  rasterizer's texture and palette reads (`GPU::ReadVRAMFlat_Texture`,
  `ReadVRAMFlat_TexPal`). Each read is mapped from melonDS's flat VRAM copy
  back to the physical bank(s) through `VRAMMap_*`. Display capture and the
  VRAM display mode read or write whole lines of an LCDC bank and are
  counted per line from the same state `DoCapture` uses. Standard palettes
  and OAM are internal RAM and not counted. Per line, unit and bank:
  - `bytes`: distinct bytes. This is what a core with a per-line cache
    must fetch.
  - `seq8`: changes of 8-byte block in the unit's read stream. This counts
    the 8-byte fetches of a core with no cache, which re-reads a repeated
    tile.
  - `b32`: distinct 32-byte blocks.

  These figures are what melonDS reads, not a hardware bus trace:
  - The renderers skip pixels that a window hides and the off-screen parts
    of sprites. Hardware may still fetch them.
  - The 3D rasterizer fetches texels only for pixels that pass the depth
    test.
  - melonDS skips rendering a 3D frame whose inputs are unchanged. The
    census then repeats the last rendered frame's lines, because the
    hardware would make the same fetches again.
  - 3D line y is counted with 2D line y, although the hardware renders 3D
    up to 48 lines ahead.
  - Reads from unmapped space go in bank `x` and are left out of the totals
    (melonDS reads zeros there).

  "Unique texture bytes" is still the per-flush working set from the
  polygon list.
- **OBJ render time.** This follows GBATEK "LCD OBJ - Overview". GBATEK's
  DS pages add nothing, so the DS is assumed to follow the GBA rule:
  - A normal OBJ costs its width in cycles. An affine OBJ costs
    10 + 2 × width, using the doubled width for double-size OBJs.
  - An OBJ on the line vertically costs cycles even when it is
    horizontally off-screen.
  - The budget is 1,210 cycles per line, or 954 with DISPCNT bit 23 set.
  - OBJs are processed in OAM order. Once the budget runs out, the
    remaining OBJs are not drawn.

  The census reports, per line:
  - cycles asked for
  - cycles through the last OBJ with on-screen pixels ("need")
  - cycles spent, capped at the budget
  - whether the line is over budget, and whether it drops an OBJ with
    on-screen pixels

  melonDS ignores the budget, so on lines that drop an on-screen OBJ it
  draws more than this rule says the hardware would. Mario Kart's character
  select shows these rules are not exact for the DS. Bottom-screen line 52
  carries eleven 64×64 affine portraits, which need 1,518 cycles, and the
  game shows all of them. So either the DS budget is larger or affine OBJs
  cost less. If games never lose a visible OBJ, the largest "need" is a
  lower bound on the DS budget. Disabled OBJs are assumed to cost nothing.
  GBATEK leaves that open, and also whether OBJs not on the line cost
  anything.

## Observer check

`check_observer.sh <rom> <script> <frames> [--save F]` runs the same session
three ways and compares per-frame framebuffer hashes:

1. with the hooks installed
2. with no hooks
3. with a deliberate mutation (one palette bit flipped at line 100)

Runs 1 and 2 must match; run 3 must differ. Result on 2026-10-22 (HeartGold,
smoke script, 1,800 frames): hooked = unhooked on all frames; the mutation
was caught at frame 285. Re-recorded the same day with the VRAM-read hooks
(2D index wrappers, 3D texture reads, line and frame hooks): same result.

To regenerate the patch after changing `Census.h` or `apply_hooks.py`:
export the pinned melonDS into an empty directory, `git init` and commit
it, run `apply_hooks.py <dir>/src`, then `git add -A` and
`git diff --cached > melonds-census.patch`.
