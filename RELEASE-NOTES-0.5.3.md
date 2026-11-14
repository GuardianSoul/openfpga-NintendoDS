Fourth release of the Nintendo DS core for Analogue Pocket: a data-cache bug that could make 3D disappear is fixed, the ARM9 runs code faster, and DMA timing is closer to the DS's.

**Fixed**
- 3D models or a whole playfield could disappear after the game updated them in memory. The ARM9's data cache wrote a full cache line back to memory and could overwrite data the game had just changed there. It now writes back half a line at a time, as measured on a real DS.
- 3D lines that were already drawn are no longer shown late. The display now reads the 3D line buffer before the 3D engine writes its next line, as on the DS.
- Code-heavy scenes run faster. The ARM9 now caches the BIOS's code, which games call often, and its instruction cache is 4-way, as on the DS. Scenes that slowed down because the CPU kept refetching code now keep full speed.
- Games that send 3D geometry to the 3D engine by DMA no longer flicker or stutter. While the ARM9 waited on the geometry engine, it held the bus and the DMA stalled; it now lets the DMA through.
- Screens that change their scroll or layout per line with HBlank DMA no longer jump. The HBlank DMA now starts after the line's background reads, as on the DS, so each line uses the values meant for it.
- Sound gets its memory reads ahead of DMA and the CPUs, as on the DS, so a long DMA copy can no longer starve it.
- DMA copies out of video memory read ahead, so effects that copy the screen keep pace.
- DMA copies within main memory and DMA writes to I/O registers take the time a DS takes.
- Touch-mode swipe gestures are twice as fast: a swipe now covers its 96 pixels in 6 frames instead of 12.
- Square roots of very large 64-bit numbers are exact, as on a real DS. The core used to round some of them up. (Jello)
- Cartridge memory requests are held until they are acknowledged. (Jello)
- The clock handles 12-hour mode and invalid dates and times as a real DS does, measured on one. (after Jello's fix)

**Known issues**
- Some 3D effects are still switched off to fit the chip: shadow polygons, toon and highlight shading, fog, edge marking, anti-aliasing and the 2D mosaic.
- **Line glitches:** the busiest 3D scenes can draw too slowly, which shows as grey, black or missing lines.
- The heaviest 3D scenes can run below full speed.
- A short stutter can remain when a game loads a lot of new data at once.

**Thanks** to Jello for the square-root, cartridge and clock fixes, a test fix, and the math and clock test programs, which were run on a real DS for this release.

**Install:** unzip the zip to the root of your SD card. Add your own `bios9.bin`, `bios7.bin` and `firmware.bin` to `Assets/nds/common/`, with your `.nds` games. Quit through the Pocket menu before turning it off, or the save made since the game started is lost. Setup steps are in the [README](https://github.com/GuardianSoul/openfpga-NintendoDS#setup).

`GuardianSoul.NintendoDS_0.5.3_2026-11-14_source.tar.gz` is the complete source this bitstream was built from, with the build command in `BUILD-INFO.txt`. The core is GPL-3.0-or-later; see LICENSE and THIRD_PARTY_NOTICES.md.
