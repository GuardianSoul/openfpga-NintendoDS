# Nintendo DS core for Analogue Pocket

An experimental FPGA core that runs Nintendo DS games on the Analogue Pocket. The DS
itself (both CPUs, the memory system, the 2D and 3D engines, sound and the
other hardware) was written from scratch for this core, against
measurements of a real DS.

> **Status (0.5.2, 2026-11-08): experimental.** Several big 3D games boot
> and play, with sound and saves. Some 3D effects are switched off to fit
> the chip, the heaviest 3D scenes can run a little below full speed, and
> some 3D scenes show line glitches. See [Pocket limitations](#pocket-limitations),
> [Known issues](#known-issues) and [COMPATIBILITY.md](COMPATIBILITY.md)
> before you try it.

## What you need

- An Analogue Pocket with current firmware. The Dock works too.
- Your own DS **BIOS and firmware** files, dumped from your own console.
- Your own DS games as `.nds` files.

No BIOS, firmware or game data is included, and none can be shared.

## Setup

1. **Core:** unzip the core package and copy its contents to the root of the
   SD card, merging with the folders there. It holds
   `Cores/GuardianSoul.NintendoDS/`, the platform files `Platforms/nds.json`
   and `Platforms/_images/nds.bin`, and the core's own boot file in
   `Assets/nds/GuardianSoul.NintendoDS/`. If your card already has a DS
   platform from another core, keep yours.
2. **BIOS and firmware:** copy these to `Assets/nds/common/`, with exactly
   these names:

   | File | What it is | Size |
   | --- | --- | --- |
   | `bios9.bin` | ARM9 BIOS | 4 KiB (4,096 bytes) |
   | `bios7.bin` | ARM7 BIOS | 16 KiB (16,384 bytes) |
   | `firmware.bin` | DS firmware | 256 KiB on a DS or DS Lite (up to 512 KiB accepted) |

   The core reads the user settings (name, language, birthday, touch
   calibration) from the firmware, as a DS does. DSi BIOS and firmware files
   are not used.
3. **Games:** copy your `.nds` files to `Assets/nds/common/`.
4. **Play:** open **openFPGA → Nintendo DS** and pick a game. The game starts
   directly, without the DS start-up menu.

### Saves

Each game's save is kept in `Saves/nds/common/<game>.sav`, a raw save that
works with melonDS and flashcarts. To use an existing save, copy it there
with the game's name. The core supports EEPROM (512 bytes, 8, 64 and
128 KiB) and FLASH (256 KiB, 512 KiB, 1 MiB) saves. Every game's save type
is detected automatically, from the core's built-in list of each game's save
chip. The rare 8 MiB NAND saves (WarioWare D.I.Y., Jam with the Band)
are not supported.

**Quit through the Pocket menu before you turn the Pocket off.** The save is
written to the SD card when you quit, so turning the Pocket off mid-game
loses everything saved since the game started. There is no sleep mode and
there are no save states (Memories).

## Controls

The Pocket's buttons are the DS buttons: D-pad, A, B, X, Y, L, R, Start and
Select. Select still reaches the game on its own; held with another button
it gives the combos below.

| Combo | Does |
| --- | --- |
| Select + L or R | Change the screen layout: both screens stacked, top screen only, bottom screen only (R goes forward, L back) |
| Select + A, B, X or Y | Touch mode on or off |

**Touch:** the Pocket has no touchscreen. In touch mode the D-pad moves a
cursor over the bottom screen and A is the stylus (touching while held).
Each of A, B, X and Y can instead run a gesture from the cursor: a circle,
a big circle, or a swipe up, down, left or right (see [Settings](#settings));
the cursor shows each gesture as it runs. The D-pad and the buttons set to a
touch or gesture don't reach the game while touch mode is on. With an analog controller
in the Dock, the right stick moves the cursor at any time, R3 (pressing the
stick) touches, and the left stick also works as the D-pad. Games that need
fast or precise stylus input (drawing, rubbing, quick taps) are hard or
impossible to play this way. There is no touch in the top-only layout.

## Settings

Under **Core Settings** in the Pocket menu. Defaults are in bold.

| Setting | Choices | What it does |
| --- | --- | --- |
| Screen Rotation | **Off**, Left, Right | Turns the picture for games played with the DS held like a book |
| SELECT + L/R | **Swap Screens**, Off | The layout combos above; Off sends L and R to the game with Select |
| SELECT + A/B/X/Y | **Toggle Touch**, Off | The touch mode combo; Off sends the buttons to the game with Select |
| Touch: Cursor Speed | Slow, **Normal**, Fast | How fast the D-pad moves the touch cursor (1, 3 or 6 pixels a frame) |
| Touch: A Button | None, **Touch**, Circle, Big Circle, Swipe Up, Swipe Left, Swipe Down, Swipe Right | What A does in touch mode: None sends the button to the game; Touch touches while held; the others run a gesture from the cursor |
| Touch: B Button, X Button, Y Button | **None**, Touch, Circle, Big Circle, Swipe Up, Swipe Left, Swipe Down, Swipe Right | The same for B, X and Y |

## Pocket limitations

The Pocket lacks some of the DS's hardware, so these can't work:

- **No touchscreen:** touch is mapped to the buttons; see [Controls](#controls).
  Games that need fast or precise stylus input are hard or impossible.
- **No microphone:** games that ask you to blow or speak hear silence.
- **No wireless:** the Pocket has no WiFi radio. There is no local wireless
  play, download play or Nintendo WFC. The core keeps enough of the DS's
  WiFi hardware (registers, no radio) for games to start and run without a
  "communication error".

## Known issues

As of 0.5.2 (2026-11-08):

- **3D effects are switched off** to fit the chip: shadow polygons, toon and
  highlight shading, fog, edge marking and anti-aliasing. Games draw without
  them. The 2D mosaic effect is off too. These are temporary: the source
  can build them all, and they come back as room is found.
- **The heaviest 3D scenes can still run a little below full speed.**
- **Line glitches:** some busy 3D scenes show black lines, and some models
  show glitching vertices.
- **Loading stutter:** a short stutter can remain when a game loads a lot of
  new data at once.
- **No sleep mode, save states or firmware menu.** Games start directly.
- **DSi:** DSi-only games and DSi enhancements are not supported.

### Known differences from a real DS

The core's rules come from measurements on a real DS. Where the Pocket's
memory or chip budget forces a difference, it is recorded. The main ones as
of 0.5.2:

- The ARM9's caches are larger than the DS's: 16 KiB instruction and
  16 KiB data, 2-way, instead of 8 and 4 KiB, 4-way. This makes up for the
  Pocket's slower external memory. Cache replacement is per set instead of
  the DS's global counter. Games can't see the difference, only its timing.
- The lean ARM7 differs in a detail of its saved status register (SPSR),
  a temporary trade for room.
- Some memory access costs differ from the DS by a cycle or a few: ARM9 I/O
  reads and uncached multi-word loads, some ARM7 stores to VRAM, and ARM7
  multiplies and ALU work running from main RAM.
- The ARM9 write buffer is not modelled.
- 2D registers changed in the middle of a line (scroll, palette, map base,
  mosaic, blending and windows) take effect from a snapshot taken at the
  start of the line. Effects that rewrite these mid-line differ.
- The 3D engine's per-polygon setup is slower than the DS's, and it renders
  6 lines ahead instead of about 43. A late 3D line can show as a missing
  line.
- A `BOX_TEST` command inside an open vertex list locks up a real DS. The
  core doesn't reproduce the lock-up.
- Sound capture of a single channel captures the mix instead. Capture
  levels and a few WiFi register details (start-up counter, baseband reads)
  differ.

## Building from source

See [BUILDING.md](BUILDING.md).

## How this was made

**Development:** started on 2026-10-22. Most of the work so far went into
measurements, accuracy and fitting the design into the Pocket's FPGA.

**AI-assisted:** this core was written with heavy use of AI coding
assistants. OpenAI Codex and Anthropic Claude wrote nearly all of the HDL,
firmware, test programs, tools, tests and documentation, working as several
parallel sessions with a coordinating session. A human maintainer set the
goals, made the design and scope decisions, ran the test programs on a real
DS and tested builds on a Pocket. Review the code with that origin in mind.

**Real hardware first.** The target is the DS hardware, including its
timing, not an emulator's shortcuts:

- The test programs in `sw/hwref` time and check the DS's behaviour:
  instruction and memory costs, caches, DMA, the geometry and 3D engines,
  the 2D engine, sound and more.
- They ran on a DS and a DS Lite from a SuperCard DSTWO and saved their
  results to its SD card, over 43 hardware runs.
- Each measured rule went into a ledger of about 150 rules, with the core's
  status for each one: follows, parked with a reason, or a known
  difference.

**melonDS as the regression reference.** Every game check runs against a
patched melonDS (`tools/melonds-census`): pinned melonDS, plus observer
hooks, plus the rules measured on the real DS. The census build records
what each game does. Simulations of the core then compare frames and CPU
traces against it, from savestates of chosen game scenes. Plain melonDS is
used only where no DS measurement exists.

**Designed for the Pocket's FPGA.** The Pocket has an Intel Cyclone V
5CEBA4: 18,480 logic blocks (ALMs), 308 RAM blocks (M10K) and 66 DSP blocks,
and the core must run at 67 MHz.

- **A full-featured reference first.** A complete reference design with
  every feature on measured about 113,000 ALMs, six times the chip. It
  serves as the accuracy reference.
- **Then a compact core.** The core that ships is a separate, much smaller
  design.
- **How the room was found:**
  - A tiny RISC-V processor (SERV) runs firmware that manages the game ROM
    cache.
  - The DS's slow peripherals (firmware and save chips over SPI, WiFi
    registers) run as microcode on one small engine.
  - The geometry engine is microcoded.
  - The boot program lives in the Pocket's external SRAM.
  - RAM blocks are double-pumped, and logic was moved between RAM blocks,
    LUT RAM and DSP blocks wherever a measured fit showed it saved room.
  - The 3D command FIFO spills into SDRAM.
- **Every saving is measured.** Each change was measured in a full Quartus
  fit, and checked against the version before it with an equivalence test
  that must also catch a deliberate bug.
- **Temporary cuts.** The current builds also leave out the features listed
  under [Known issues](#known-issues) until room is found.

## Credits

- [melonDS](https://github.com/melonDS-emu/melonDS) by Arisotura and the
  melonDS team: the behaviour reference the core was checked against, and
  the base of the census tool.
- [GBATEK](https://problemkaputt.de/gbatek.htm) by Martin Korth: the DS
  hardware documentation.
- [SERV](https://github.com/olofk/serv) by Olof Kindgren: the shell CPU.
- Adam Gastineau (agg23), [MIRLO64](https://github.com/tortugaveloz/MIRLO64)
  by tortuga, [PocketQuake](https://github.com/thinkelastic/PocketQuake) and
  OpenGateware: Pocket platform glue, audio output and PSRAM access.
- [pret](https://github.com/pret)'s Pokémon Platinum and HeartGold
  decompilations: which hardware features those games use.
- Other FPGA cores, studied to size the design. None of their code is in
  this core:
  - [GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer) by Robert Peip
    (FPGAzumSpass) and contributors. Its ARM7 CPU, 2D engine, DMA, timers
    and sound were synthesized for the Pocket's chip at the start, only to
    estimate what the DS's blocks of the same kind would cost. That gave the
    first area budget.
  - [Nitro_DarkSide](https://github.com/MiSTfits-devel/Nitro_DarkSide), a
    MiSTer DS core without 3D. Its published fits (about 41,500 ALMs, over
    twice the Pocket's chip) showed how much denser a Pocket DS had to be.
    They shaped this core's sound engine (one channel at a time, state in
    RAM) and memory layout.
  - [NDS4MiSTer](https://github.com/SplashDev88/NDS4MiSTer), which runs
    Nitro_DarkSide with 2D and 3D in software on the MiSTer's ARM processor.
    The Pocket has no such processor, so it served as a reference only.

Full credits and licences: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

The core is licensed under the [GNU GPL version 3 or later](LICENSE). Files
whose header says MIT are also under the [MIT license](licenses/MIT.txt).
Third-party parts keep their own terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Not affiliated with or endorsed by Nintendo or Analogue. "Nintendo DS" is a
trademark of Nintendo.
