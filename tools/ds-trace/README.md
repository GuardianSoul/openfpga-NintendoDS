# DS golden-model traces

These traces compare the integrated DS RTL, simulated in Verilator, with
melonDS one retired instruction at a time. melonDS writes them through
the census runner (`tools/melonds-census`, `--trace-dir`). The RTL
testbench must write the same files. `compare.py` diffs two trace
directories.

```sh
MELONDS_SRC=<checkout with references/melonDS> tools/melonds-census/build.sh
build/census-melonds/build/census \
  --bios9 roms/bios9.bin --bios7 roms/bios7.bin --firmware roms/firmware.bin \
  --rom roms/nsmb.nds --script tools/melonds-census/scripts/nsmb.txt \
  --out build/trace/nsmb-run --frames 600 --shot-every 0 \
  --trace-dir build/trace/nsmb [--trace-insns 20000000] \
  --dump-boot build/trace/nsmb-boot
tools/ds-trace/compare.py build/trace/nsmb build/trace/rtl [--irq-align] \
  [--collapse-loops] [--ignore-wr 0x04000000-0x04FFFFFF]
tools/ds-trace/compare.py build/trace/nsmb --cpu 9 --dump 0 20   # print records
```

The RTL starts from the `--dump-boot` state: load the memories into the
model and set the registers from `state.txt`.

## Formats

All files are little-endian, with one set per CPU (`N` = 9 or 7).

**`armN.trc`:** 68 bytes per retired instruction, `u32 pc, u32 cpsr,
u32 r[15]`.
- `pc` is the instruction's own address: melonDS `R[15]` − 8 in ARM state,
  − 4 in Thumb.
- `cpsr` and `r0..r14` are the values after the instruction, as seen in
  the mode `cpsr` shows.
- An instruction whose condition fails still gets a record.
- The content is the same as the `tb_arm` CSV lockstep line (`+trace0/1`,
  docs/arm-pipeline.md "Lockstep hook for melonDS"), in binary.
- melonDS has no record for exception entry. The first record of an IRQ
  is the instruction at the vector, already in IRQ mode, with
  `r14_irq` = interrupted pc + 4.

**`armN.wr`:** 12 bytes per data write, `u32 addr, u32 value, u8 size,
u8 source, u16 0`.
- `size` is 1, 2 or 4. `addr` is aligned to `size`, and `value` sits in
  the low bits.
- `source` is 0 for the CPU and 1 for that CPU's DMA channels.
- The records are in issue order and cover every address, including ITCM
  and DTCM, I/O, VRAM, palette and OAM.
- A CPU write is recorded on entry to melonDS's `DataWrite*`. An ARM9
  write that hits an MPU data abort still appears (games don't do this).
- Not recorded: sound-capture writes (they come from the SPU, not a CPU
  or DMA), and memory set up by direct boot (that is in the
  `--dump-boot` images).

**`irqN.txt`:** one line per IRQ exception taken: `<index> <IE&IF hex>`.
`index` is the number of `.trc` records written before the entry, which is
the index of the first excursion record.

**`armN.op`** (only with `--trace-op 1`): 4 bytes per `.trc` record, the
instruction word melonDS executed (`CurInstr`). In Thumb state the
instruction is bits 15:0. `sim/arm/tools/slotmodel.py` uses it to replay real
game code through a timing model of the CPU pipeline.

Recording stops at `--trace-insns` instructions per CPU (default 20M, about
1.36 GB per CPU). Writes and IRQs after that point are not recorded.

## RTL side: exception lines

The RTL retires an IRQ entry as its own line:
- `pc` is the interrupted (next) instruction
- `cpsr` is already in IRQ mode, with `r14` = `pc` + 4
- the next line is at the vector

`compare.py` drops such lines on both sides by default. The test is: the
line has IRQ mode, `r14 == pc + 4`, the next pc is the IRQ vector, and the
line before it was not in IRQ mode. `--keep-exc` keeps them. melonDS
produces no such line. SWI, undefined-instruction and abort entries are
not dropped. For SWI, the trapping instruction is the record on both
sides.

## compare.py

For each CPU, `compare.py` compares the `.trc` streams, then the `.wr`
streams.
- **Divergence report:** the first divergence, with `--context N` records
  (default 10) from both sides. Each record is decoded as record index, pc,
  cpsr (mode, T, I, NZCV) and the registers that changed. `*` marks the
  fields that differ from the other side.
- **Length:** if one stream is a prefix of the other, it is a match.
  `--strict-length` makes a length difference a divergence.
- **Exit code:** 0 on a match, 1 on a divergence.
- **Speed:** 2 × 20M records with no options take 5 s. Inputs are
  memory-mapped and compared in numpy chunks.

Options:
- `--irq-align` splits each stream into the main stream and the IRQ
  excursions.
  - An excursion starts at a record at the IRQ vector (`0xFFFF0018` for
    ARM9, `0x18` for ARM7; `--vec9` and `--vec7` override these).
  - It ends at the instruction that leaves IRQ mode with a jump: `SUBS pc`
    or `LDM ^`. A mode switch by MSR (NitroSDK runs handlers in SYS mode)
    does not end it.
  - Nested entries are counted, so the outermost excursion is removed as
    one unit. A return to a different thread also ends the excursion.
  - The main stream is compared with the excursions removed. The
    excursions are compared in order, by pc and cpsr only. Their
    registers carry the interrupted context. `--irq-regs` compares all
    fields.
- `--collapse-loops` drops every record equal to the record 1–16 places
  before it, on pc, cpsr and r0–r14. A polling loop then keeps one
  period, whatever its iteration count. A loop with a counter changes a
  register in every period and is not collapsed.
- `--ignore-wr LO-HI` (repeatable) leaves writes in that range out of the
  comparison. `--no-wr` skips the writes.
- The write streams are compared in raw order. A write record carries no
  instruction index, so `--irq-align` does not apply to it. With
  different IRQ timing, handler writes interleave differently.

## Validation (2026-10-23)

Every run used trace limits of 20M instructions.
- **Sanity checks (`nsmb.nds` and `mkds.nds`):**
  - The first records are at the header entry addresses: `0x02000800`
    (ARM9) and `0x02380000` (ARM7).
  - The first record has `cpsr` `0xD3`, `r12 = r14 = entry`, and the
    melonDS stacks.
  - The NSMB ARM9 runs in SYS mode from the crt0 onwards.
  - The first ARM7 IRQ appears at record 2,708,071. It is at `0x18`, with
    `r14_irq` = interrupted Thumb pc + 4, matching `irq7.txt`.
  - mkds writes go to main RAM, I/O, palette, OAM and ARM7 WRAM/VRAM.
- **Self-compare (NSMB, 600 frames):**
  - Both CPUs match: ARM9 20M records and 1,995,528 writes, ARM7 19.68M
    records and 2,094,656 writes.
  - mkds matches with `--irq-align --collapse-loops`.
- **Planted faults:** one register bit in ARM9 record 12,345,678 and one
  value bit in ARM7 write 1,000,000. Each was reported at exactly that
  position, with context, and the exit code was 1.
- **Timing-perturbed runs (`--trace-perturb`, NSMB):** the options work,
  but these runs never match through to the end. The streams diverge on
  values read from timing-dependent sources: an IPCSYNC handshake value
  and a timer read inside the ARM7 IRQ handler.

  | Perturbation | Plain compare | `--irq-align --collapse-loops` |
  | --- | --- | --- |
  | 2 cycles, ARM7 | diverges at record 2,708,069 (first IRQ) | main stream to 2,739,416; first 2 excursions match; excursion 2 differs on a timer read |
  | 2 cycles, ARM9 | 5,196,279 | 6,174,223 |
  | 100 cycles, ARM7 | full match | full match, 8,255 excursions |

  The table records how far each comparison got: the record position of
  the first divergence, or the result. Getting past timing-dependent
  values would need a resync option, which does not exist yet.
