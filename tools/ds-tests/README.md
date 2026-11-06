# DS test ROMs

Small direct-boot `.nds` ROMs for bringing up the integrated core in
simulation and on hardware. Written for this project: no libnds, no
devkitPro, no third-party code. GBATEK is the register reference.

```sh
make ds-tests            # build/ds-tests/<rom>.nds and <rom>_m7.nds
make ds-tests-melonds    # run each in the melonDS census runner, decode results
```

Toolchain: `clang` (`--target=armv5te-none-eabi` for the ARM9,
`armv4t-none-eabi` for the ARM7), `ld.lld`, `llvm-objcopy`, `python3`
(Pillow optional, for PNG screenshots).

## Files

| Path | Purpose |
| --- | --- |
| `sw/tests/tests.mk` | Build rules (included by the Makefile) |
| `sw/tests/common/crt0.s` | Shared crt0 (both CPUs), `memcpy`/`memset`, integer divide helpers |
| `sw/tests/common/ds.ld` | Linker script; load address from `--defsym=__base=` |
| `sw/tests/common/ds.h` | Register map, mailbox, BIOS SWI wrappers |
| `sw/tests/common/con.[ch]` | Text console on both engines, printf-lite |
| `sw/tests/common/results.[ch]` | Result block in RAM and on screen |
| `sw/tests/common/ipc.h` | ARM9/ARM7 coordination (mailbox commands, timeouts) |
| `sw/tests/<rom>/arm9.c`, `arm7.c` | The tests |
| `tools/ds-tests/mknds.py` | Writes the header and lays out the ROM |
| `tools/ds-tests/mkfont.py` | 8x8 font (ASCII 0x20-0x5F), drawn here, emitted as C |
| `tools/ds-tests/check.py` | melonDS golden run and result-block decoder |

## Boot contract

The ROMs expect a melonDS-style direct boot:
1. The loader copies the ARM9 and ARM7 binaries from the header's ROM
   offsets to their RAM addresses.
2. It jumps to the entry points with the real BIOSes mapped.

It needs no firmware, and it needs no KEY1 secure area: the ARM9 binary
sits at ROM offset 0x8000 and the ARM7 binary follows it, aligned to 0x200.

| | ARM9 | ARM7 (`<rom>.nds`) | ARM7 (`<rom>_m7.nds`) |
| --- | --- | --- | --- |
| RAM address = entry | 0x02000000 | 0x037F8000 (shared WRAM, like commercial games) | 0x02380000 (main RAM) |
| ROM offset | 0x8000 | hello 0x9800, irq 0x9800, sys 0xB000, cart 0x9A00 | same |

Header (`mknds.py`, GBATEK "DS Cartridge Header"):
- Title, game code `TSHE`/`TSIR`/`TSSY`/`TSCA`, maker `00`, unit code 0.
- Capacity is 128 KiB << n (cart is 256 KiB, the others 128 KiB).
- FNT, FAT and overlays are empty. Port 0x60 is 0x00586000 and 0x64 is
  0x001808F8.
- The Nintendo logo is zeroes. The logo CRC and the header CRC16 at 0x15E
  are computed by mknds.py.

crt0 assumes nothing about CP15 or the stacks:
- **ARM9:**
  - MPU and caches off, so main RAM is uncached and coherent between the
    CPUs.
  - High vectors (BIOS at 0xFFFF0000).
  - DTCM at 0x0B000000 (16 KiB), ITCM at 0.
  - Stacks in DTCM: IRQ at +0x3F80, SVC at +0x3FC0, SYS at +0x3E00.
  - The BIOS IRQ handler pointer is at DTCM+0x3FFC and the IntrWait flags
    at DTCM+0x3FF8.
- **ARM7:**
  - Stacks: IRQ 0x0380FF80, SVC 0x0380FFC0, SYS 0x0380FE00.
  - BIOS IRQ handler pointer at 0x0380FFFC, flags at 0x0380FFF8.
  - The `.iwram` section is copied to 0x0380C000.
- **Both:** clear BSS and run `main` in System mode with IME = 0.

## Result block

The ARM9 writes this block at main RAM physical **0x023F0000**:

| Offset | u32 |
| --- | --- |
| +0x00 | magic `DSTR` = 0x52545344 |
| +0x04 | number of checks N (at most 32) |
| +0x08 | pass bitmask (bit i = check i passed) |
| +0x0C | done flag (1 when all checks are recorded) |
| +0x10 | value[0..N-1]: the measured value of each check |

A test passes when done = 1 and mask = (1 << N) - 1. The ARM7 reports to
the ARM9 through a mailbox at 0x023F1000 (`mailbox_t` in `ds.h`).

The screen shows the same information:
- Top row: the title.
- Row 1: `MASK <got> OF <all-pass>` in hex.
- Row 2: `ALL PASS`, `FAIL` or `RUNNING`.
- From row 4: one line per check, `NN NAME VALUE OK|BAD`. Checks 0-19 are
  on the top screen and checks 20-31 on the bottom screen, from row 4.

## ROMs and checks

**hello.nds** (5 checks, polling only)
- The ARM9 maps VRAM A to BG A (VRAMCNT_A = 0x81) and C to BG B (0x84).
- POWCNT1 = 0x8203 puts engine A on top.
- Both engines use mode 0 with BG0 as 4bpp text, 32x32.
- It prints `HELLO DS` on top, `BOTTOM` on the bottom with the full
  character set, and a frame counter on each screen.
- The ARM7 sends 0x1234ABCD through the IPC FIFO, then idles.

| # | Name | Expected |
| --- | --- | --- |
| 0 | FIFO7TO9 | word received from the ARM7 = 0x1234ABCD |
| 1 | VCOUNTMX | highest VCOUNT over a frame = 262 |
| 2 | POWCNT1 | read back 0x8203 |
| 3 | VBLFLAG | DISPSTAT VBlank-flag rising edges in 10 frames = 10 |
| 4 | ARM7BASE | the ARM7's `_start` = its load address |

**irq.nds** (9 checks)
- Both CPUs take their IRQs through the real BIOS handler.
- They wait with VBlankIntrWait (SWI 5) and IntrWait (SWI 4).

| # | Name | Expected |
| --- | --- | --- |
| 0, 4 | A9VBL60, A7VBL60 | VBlank IRQs counted during 60 VBlankIntrWaits = 60 |
| 1, 5 | A9VCOUNT, A7VCOUNT | VCOUNT just after VBlankIntrWait returns = 192 |
| 2, 6 | A9TIMER, A7TIMER | timer 0 IRQs (F/1024, about 10 ms) during 10 IntrWait(1, TIMER0) calls, with VBlank IRQs also live = 10 |
| 3, 7 | A9MODE, A7MODE | CPSR low byte inside the handler = 0xD2 (IRQ mode, I and F set) |
| 8 | IPCIRQ | ARM7 raises an IPCSYNC IRQ with output 3: (count << 4) \| input = 0x13 |

**sys.nds** (32 checks)

| # | Name | Expected (GBATEK semantics) |
| --- | --- | --- |
| 0 | DIV32Q | 1000 / 7 = 142 |
| 1 | DIV32R | -1000 % 7 = -6 |
| 2 | DIV64/32 | 0x123456789ABC / 0x1000, low word 0x23456789 |
| 3 | DIV64S | -0x123456789AB0 / 16 (64/64), low word 0xBA987655 |
| 4, 5 | DIV0QLO, DIV0QHI | 5 / 0 in 32-bit mode: result = 0x00000000_FFFFFFFF |
| 6 | DIV0REMF | remainder = numerator (5), with the DIVCNT bit 14 divide-by-zero flag in bit 30: 0x40000005 |
| 7, 8 | SQRT32, SQRT64 | sqrt(1000000) = 1000; sqrt(0xFFFFFFFE_00000001) = 0xFFFFFFFF |
| 9-11 | DMA32, DMA16, DMAFILL | DMA3 immediate copy of 64 words, copy of 63 halfwords, fill from DMA3FILL (source fixed): sums match the source or the fill |
| 12 | TIMERS | bit 0: TM1 cascades from TM0; bit 1: TM1 stops when TM0 stops; bit 2: F/64 vs F/1024 ratio is 15-17. Expected 7 |
| 13 | IPCSYNC | ARM9 outputs 5 and the ARM7 answers 10: (ARM9 input << 4) \| ARM7 input = 0xA5 |
| 14 | FIFOEMPT | IPCFIFOCNT & 0xC303 after enable and clear = 0x8101 |
| 15 | FIFOFULL | after 16 sends 0x8102; the 17th send sets the error flag, 0xC102 |
| 16 | FIFO9TO7 | the ARM7's sum of the 16 words = what was sent (the 17th was dropped) |
| 17 | FIFO7FLG | ARM7 flags: full 0x8201, then empty after 16 reads 0x8101 |
| 18 | FIFO7TO9 | sum of the 16 words from the ARM7 |
| 19 | FIFO9FLG | ARM9 receive full 0x8201; read while empty sets the error, 0xC101 |
| 20, 21 | SWI9DIV, SWI9SQRT | ARM9 BIOS: Div(-1234, 10) = -123, Sqrt(1000000) = 1000 |
| 22 | SWI9CPYS | CpuSet copy (32-bit) and fill (16-bit), CpuFastSet copy and fill: hash equals a software copy |
| 23 | SWI9LZ77 | LZ77UnCompWram of a hand-made stream: hash equals the plain text |
| 24-26 | SWI7DIV, SWI7SQRT, SWI7CPYS | the same on the ARM7 BIOS (copies and LZ77 in one hash) |
| 27 | SWI7CRC | ARM7 BIOS GetCRC16(0xFFFF, 64 bytes) = software CRC-16 (poly 0xA001) |
| 28 | WRAMSPLT | ARM9 writes P0 to shared block 0 and P1 to block 1 with WRAMCNT = 0. Low bytes of [ARM9, ARM7] reads of 0x03000000 with WRAMCNT = 1, then 2: 0xB1A0A0B1 |
| 29 | WRAM7 | WRAMCNT = 3: the ARM7 sees P0 at 0x03000000 and P1 at 0x03004000. WRAMCNT = 0: the ARM7's 0x03000000 mirrors ARM7 WRAM. Expected 0x1A0B1 |
| 30 | VRAMMAP | each bank is written via LCDC and read via its mapping. Bits 0-8: B to OBJ A, B to BG A ofs 1, D to OBJ B, E to OBJ A, F to OBJ A, F to OBJ A ofs 1, G to OBJ A ofs 3, H to BG B, I to OBJ B. Bits 9-10: C and D mapped to the ARM7 (0x06000000/0x06020000). Bits 16-23: ARM7 VRAMSTAT = 3. Expected 0x307FF |
| 31 | PALOAMKY | bits 0-3: BG A, OBJ A and BG B palette and OAM read back. Bits 16-25: KEYINPUT, recorded only. Passes when bits 0-3 = 0xF |

The ARM7 handles the WRAMCNT phase from `.iwram`, in ARM7 WRAM, while
the ARM9 moves the shared blocks. In the `<rom>.nds` build the ARM7 image
itself lives in shared WRAM, so the ARM9 saves and restores the two words
it overwrites.

**cart.nds** (15 checks)
- The ROM carries a pattern section at 0x20000-0x2FFFF. Each word is
  `(o * 0x9E3779B1) ^ 0xC3A5F00F`, where o is the word's ROM offset.
- Reads use command 0xB7 with 0x200-byte blocks. ROMCTRL is
  0xA1586000: start, RESB, block size 1, and the header 0x60 bits.
- The ARM9 first takes the slot (EXMEMCNT bit 11 = 0), then hands it to
  the ARM7 (bit 11 = 1).

| # | Name | Expected |
| --- | --- | --- |
| 0 | A9P8000 | polled read at 0x8000 = the ARM9 image at 0x02000000: 128 of 128 words match |
| 1, 2 | A9P20000, A9P2F200 | polled reads of the pattern: 128 |
| 3 | A9D24A00 | card DMA (DMA0, card start, repeat, count 1) of the pattern: 128 |
| 4 | A9D8200 | card DMA at 0x8200 = image at 0x02000200: 128 |
| 5 | CHIPID9 | command 0xB8, recorded. Passes unless the result is 0 or 0xFFFFFFFF |
| 6 | SPISTAT | AUXSPI save-chip "read status" (0x05), recorded only |
| 7, 8 | A7P21000, A7P2FE00 | ARM7 polled reads of the pattern: 128 |
| 9 | CHIPID7 | ARM7 chip ID = ARM9 chip ID |
| 10 | SVBLANK | save chip (EEPROM 8 KiB: melonDS's and the core's choice for an unlisted game) read at 0x100: 16 bytes of 0xFF |
| 11 | SVWRITE | write enable (0x06), write 16 bytes at 0x100 (0x02), read back: 16 match |
| 12 | SVSTAT | status after write enable << 8 \| status after write disable (0x04) = 0x0200 |
| 13 | SVWRDI | a write with write enable off is ignored; read at 0x2100 wraps to 0x100: 16 match |
| 14 | SVOFFS | read from 0x108: the second half of the data, 8 match |

## melonDS golden run (2026-10-23)

`make ds-tests-melonds` runs the census runner on each ROM:
- the pinned melonDS, with the real BIOS and firmware, direct boot
- 120 frames, no input

The runner cannot dump RAM, so `check.py` asks it for a savestate at
frame 119 and reads main RAM from the state's `NDSG` section.

| ROM | Checks | Mask | Result |
| --- | --- | --- | --- |
| hello.nds / hello_m7.nds | 5 | 0000001F | PASS / PASS |
| irq.nds / irq_m7.nds | 9 | 000001FF | PASS / PASS |
| sys.nds / sys_m7.nds | 32 | FFFFFFFF | PASS / PASS |
| cart.nds / cart_m7.nds | 15 | 00007FFF | PASS / PASS |

melonDS recorded these values:
- cart: chip ID 0x000100C2, SPI status 0x00 (no save file).
- sys: KEYINPUT 0x3FF.

Screenshots are in `build/ds-tests/melonds/<rom>/shots/f000030.png` …
`f000120.png`, with the PPM next to each. Each shot is 256x384, top screen
above bottom. `census.log` and the savestate `end.mln` are in the same
directory.

Checking the checker: a copy of cart.nds with one pattern bit flipped at
0x2F208 reports `A9P2F200 = 0x7F BAD`, mask 0x3FB, and `check.py` exits 1.
The first hello build also failed check 3 (9 VBlank edges instead of 10,
a bug in the test's counting window), and the screen and block showed
FAIL. The test was fixed afterwards.
