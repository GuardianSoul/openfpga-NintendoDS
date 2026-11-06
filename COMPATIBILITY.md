# Compatibility

As of 2026-11-06. These are results from 0.5.0-era
builds on a Pocket (0.5.1's speed, streaming and save fixes may improve them) and from simulation of the core against the patched
melonDS reference. The list will change quickly, so treat it as a snapshot.

## Tested on a Pocket

| Game | Status | Notes |
| --- | --- | --- |
| Super Mario 64 DS | Playable | Full speed with no visible problems |
| Mario Kart DS | Playable | Full speed, race start included |
| Pokémon HeartGold / SoulSilver | Playable | Plays and saves; the clock comes from the Pocket |
| Pokémon Black 2 / White 2 | Minor issues | Slows down walking through cities; the title screen runs slow, sound included, and part of its bottom screen isn't shown; tree vertices glitch in cities |
| Kingdom Hearts 358/2 Days | Minor issues | Most areas run well; heavy scenes with several enemies run at about 50–60% speed |
| Animal Crossing: Wild World | Playable | About 20 frames a second, as the game runs on a DS |
| New Super Mario Bros. | Playable | No problems seen in the latest test |
| Golden Sun: Dark Dawn | Minor issues | The title screen bounces up and down |
| Mario & Luigi: Partners in Time | Minor issues | The title logo line flickers; some row glitches |

## Checked in simulation only

Pokémon Platinum, Kirby Super Star Ultra, Jump Ultimate Stars and Professor
Layton titles showed no glitches in simulated scenes. They have not been
played on a Pocket build yet. Layton and Jump Ultimate Stars rely on the
touchscreen (see the README's [Controls](README.md#controls)).

## Scene checks

Every build is checked in simulation on six saved game scenes before it goes
on a Pocket: four from Mario Kart DS (a heavy race, a race, and two points
in the intro), the HeartGold title and the Animal Crossing: Wild World title.
The core's frames and state must match the patched melonDS reference, at the
expected pace.

## Not supported

- Games that need the microphone, wireless play or Nintendo WFC for anything
  beyond optional features.
- DSi-only games and DSi enhancements.
- Games with 8 MiB NAND saves (WarioWare D.I.Y., Jam with the Band).

| Status | Meaning |
| --- | --- |
| Playable | Played into normal gameplay with no problems seen |
| Minor issues | Playable with small graphics, sound or speed problems |
| Major issues | Starts, but crashes, hangs or is too broken to play |
| Doesn't boot | Black or white screen, or a hang before the title |
