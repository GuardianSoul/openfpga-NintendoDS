# ARM7 nonsequential MAIN-fetch probe kernels

Source/linked-kernel stage for hwref; no DS capture or standalone NDS envelope
yet. Reuse arm7time's custom calico ARM7 and timer method. The hwref owner
supplies SDK integration and a quiet ITCM ARM9 completion helper.

`gen.py` emits18 position-independent ARMv4T kernels, declarations/table and
case metadata:64 ADDs at offsets0/4/8/12;64 adjacent,16-byte-stride and
32-byte-stride taken branches at each offset; two- and three-line revisits.
The linked body symbol supplies the actual first-op address; each function
entry is32-byte aligned. Kernels fit a4096-byte copy slot. All strided sled
branches, including the final one to loop bookkeeping, use the stated
stride. Loop count must be positive. Only caller-saved registers change.

Ring units are whole rounds: one SUBS, one checksum ADD and two or three
branch instructions,64 rounds per loop. Do not report their cost as one
isolated B or silently subtract bookkeeping. Other cases use64 body ops
plus SUBS/BNE per loop, like DS30. ADD/ring checksums are64*loops; branch
sleds return0. The native host observer must count actual branches as well
as checking code bytes, since falling through an adjacent B gives the same
checksum.

Envelope requirements:

- Run identical compiled bytes from WRAM and an aligned MAIN copy. Copy each
  case to a distinct4096-byte slot before timing; record entry/body/end,
  code CRC/hash and compare copied words. Keep data and result buffers away.
- Use IRQ-off ARM7 TM0+TM1 raw timing, per-call warmup1, independent4/16
  calls, minima of5. Preserve all10 raw samples and checksums, not only
  the derived slope. Verify expected checksum for every warm/timed call.
- ARM9 completion waits in ITCM and polls I/O only during each timed block;
  no MAIN instruction fetch or mailbox polling. Reuse the proven quiet
  helper procedure; publish exact helper bytes/addresses and I/O traffic.
- Archive exact ARM7/ARM9 ELF and NDS binaries, source/build hashes,
  disassembly and metadata. Original DS30 placement was not archived;
  this probe must retain it. Use versioned CSV with case, region, sample,
  loops, ticks, checksum and actual code/body addresses.
- Build/stage first. No SD write or hardware trip is authorized here.

`check.py ELF --out layout.json` checks linked offsets/branch targets and
untimed ARM instruction semantics at the linked address and a relocated
MAIN address for loop counts1/4/16. It checks checksums, operation counts,
return and callee-saved registers. Actual ADD/B→NOP mutations are rejected.
It models no memory/cache/prefetch timing and supplies no DS timing rule.
