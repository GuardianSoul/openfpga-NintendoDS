Third release of the Nintendo DS core for Analogue Pocket: 3D that no longer disappears in heavy scenes, correct textures on tall 3D shapes, and exact screen-swap timing.

**Fixed**
- Heavy 3D scenes no longer drop the whole 3D picture. When many polygons covered the same line, the core could stall and show only the background; it now draws the scene as the DS does.
- Textures on tall 3D shapes are now drawn with the DS's exact perspective rule, measured on a real DS. This removes stretched or misplaced texture corners.
- Swapping the screens mid-frame now takes effect on the exact line, as on the DS, so games that switch screens during a frame no longer flicker or show the wrong picture.
- DMA copies from video memory to main memory are faster, and palette and OAM writes finish sooner.
- 4x4-compressed textures use the DS's palette address.
- The 3D geometry commands take the time a DS takes, as measured on a real DS.

**Known issues**
- Some 3D effects are still switched off to fit the chip: shadow polygons, toon and highlight shading, fog, edge marking, anti-aliasing and the 2D mosaic.
- The busiest 3D scenes can draw too slowly, which shows as grey or flickering lines in the lower part of the screen.
- The heaviest 3D scenes can run below full speed.
- A short stutter can remain when a game loads a lot of new data at once.

**Install:** unzip the zip to the root of your SD card. Add your own `bios9.bin`, `bios7.bin` and `firmware.bin` to `Assets/nds/common/`, with your `.nds` games. Quit through the Pocket menu before turning it off, or the save made since the game started is lost. Setup steps are in the [README](https://github.com/GuardianSoul/openfpga-NintendoDS#setup).

`GuardianSoul.NintendoDS_0.5.2_2026-11-08_source.tar.gz` is the complete source this bitstream was built from, with the build command in `BUILD-INFO.txt`. The core is GPL-3.0-or-later; see LICENSE and THIRD_PARTY_NOTICES.md.
