#!/usr/bin/env python3
"""Insert the census hooks into a melonDS source tree (used to regenerate
melonds-census.patch; the patch is what gets applied)."""
import re, shutil, sys
from pathlib import Path

src = Path(sys.argv[1])
shutil.copy(Path(__file__).with_name("Census.h"), src / "Census.h")

def edit(name, old, new, count=1):
    p = src / name
    t = p.read_text()
    n = t.count(old)
    if n != count:
        sys.exit(f"{name}: expected {count} of {old!r}, found {n}")
    p.write_text(t.replace(old, new))

def sub(name, pattern, repl, count):
    p = src / name
    t, n = re.subn(pattern, repl, p.read_text(), flags=re.M)
    if n != count:
        sys.exit(f"{name}: expected {count} matches of {pattern!r}, found {n}")
    p.write_text(t)

# ARM9: code fetch and data accesses (CP15.cpp), busy cycles (ARM.cpp)
edit("CP15.cpp", '#include "ARMJIT.h"', '#include "ARMJIT.h"\n#include "Census.h"')
edit("CP15.cpp", "u32 ARMv5::CodeRead32(u32 addr, bool branch)\n{\n",
     "u32 ARMv5::CodeRead32(u32 addr, bool branch)\n{\n    CENSUS_HOOK(MemAccess, 0, Census::Code, addr, 32);\n")
def data_hooks(cpu):
    def repl(m):
        s = m.group(0) + f"    CENSUS_HOOK(MemAccess, {cpu}, Census::{m.group(1)}, addr, {m.group(2)});\n"
        if m.group(1) == "Write":
            s += f"    CENSUS_HOOK(DataWrite, {cpu}, 0, addr, val, {int(m.group(2)) // 8});\n"
        return s
    return repl
sub("CP15.cpp", r"^void ARMv5::Data(Read|Write)(8|16|32)S?\(u32 addr, (u32\*|u8|u16|u32) val\)\n\{\n",
    data_hooks(0), 8)

edit("ARM.h", '#include "MemConstants.h"', '#include "MemConstants.h"\n#include "Census.h"')
edit("ARM.h", "    u16 CodeRead16(u32 addr)\n    {\n",
     "    u16 CodeRead16(u32 addr)\n    {\n        CENSUS_HOOK(MemAccess, 1, Census::Code, addr, 16);\n")
edit("ARM.h", "    u32 CodeRead32(u32 addr)\n    {\n",
     "    u32 CodeRead32(u32 addr)\n    {\n        CENSUS_HOOK(MemAccess, 1, Census::Code, addr, 32);\n")
sub("ARM.cpp", r"^void ARMv4::Data(Read|Write)(8|16|32)S?\(u32 addr, (u32\*|u8|u16|u32) val\)\n\{\n",
    data_hooks(1), 8)
edit("ARM.cpp", "        NDS.ARM9Timestamp += Cycles;\n",
     "        CENSUS_HOOK(Busy, 0, Cycles);\n        NDS.ARM9Timestamp += Cycles;\n")
edit("ARM.cpp", "        NDS.ARM7Timestamp += Cycles;\n",
     "        CENSUS_HOOK(Busy, 1, Cycles);\n        NDS.ARM7Timestamp += Cycles;\n")

# Golden-model traces: retired instructions (both interpreters), IRQ entry,
# DMA writes (CPU writes are hooked with the data accesses above)
edit("ARM.cpp", "        {\n            if (CPSR & 0x20) // THUMB\n",
     "        {\n            u32 censusPC = R[15] - ((CPSR&0x20)?2:4);\n            if (CPSR & 0x20) // THUMB\n", 2)
edit("ARM.cpp", "            // TODO optimize this shit!!!\n",
     "            CENSUS_HOOK(Retire, Num, censusPC, R, CPSR);\n            // TODO optimize this shit!!!\n", 2)
edit("ARM.cpp", "void ARM::TriggerIRQ()\n{\n    if (CPSR & 0x80)\n        return;\n",
     "void ARM::TriggerIRQ()\n{\n    if (CPSR & 0x80)\n        return;\n    CENSUS_HOOK(IRQEntry, Num);\n")
for c in (9, 7):
    for b in (16, 32):
        edit("DMA.cpp", f"            NDS.ARM{c}Write{b}(CurDstAddr, NDS.ARM{c}Read{b}(CurSrcAddr));\n",
             f"            {{\n                u{b} censusV = NDS.ARM{c}Read{b}(CurSrcAddr);\n"
             f"                CENSUS_HOOK(DataWrite, {0 if c == 9 else 1}, 1, CurDstAddr, censusV, {b // 8});\n"
             f"                NDS.ARM{c}Write{b}(CurDstAddr, censusV);\n            }}\n")

# 3D: every executed FIFO entry, and the polygon RAM at each flush
edit("GPU3D.cpp", '#include "GPU3D.h"\n', '#include "GPU3D.h"\n#include "Census.h"\n')
edit("GPU3D.cpp", "    CmdFIFOEntry entry = CmdFIFORead();\n",
     "    CmdFIFOEntry entry = CmdFIFORead();\n    CENSUS_HOOK(GXCommand, entry.Command, entry.Param);\n")
edit("GPU3D.cpp", "        if (FlushRequest)\n        {\n            CurRAMBank = CurRAMBank?0:1;\n",
     "        if (FlushRequest)\n        {\n            CENSUS_HOOK(Flush3D, *this);\n            CurRAMBank = CurRAMBank?0:1;\n")

# DMA starts, cartridge commands, scanlines
edit("DMA.cpp", '#include "Platform.h"\n', '#include "Platform.h"\n#include "Census.h"\n')
edit("DMA.cpp", "        if (!RemCount)\n            RemCount = countmask+1;\n",
     "        if (!RemCount)\n            RemCount = countmask+1;\n"
     "        CENSUS_HOOK(DMAStart, (int)CPU, Num, StartMode, SrcAddr, DstAddr,\n"
     "                    RemCount * ((Cnt & 0x04000000) ? 4 : 2));\n")
edit("NDSCart.cpp", '#include "Utils.h"\n', '#include "Utils.h"\n#include "Census.h"\n')
edit("NDSCart.cpp", "    if (Parent.CartActive && Parent.CPUSelect == Num)\n        Parent.Cart->ROMCommandStart(Parent, ROMCommand);\n",
     "    if (Parent.CartActive && Parent.CPUSelect == Num)\n    {\n        CENSUS_HOOK(CartCommand, ROMCommand, datasize);\n"
     "        Parent.Cart->ROMCommandStart(Parent, ROMCommand);\n    }\n")
# Save chip: a game the list marks NAND without a NAND area in its header
# (0x96 = 0, e.g. Electroplankton) gets EEPROM 8 KiB, as the core's savelist
# does; NDSCartArgs::SaveMemType (census --save-type) overrides the list.
edit("NDSCart.cpp", "    if (romparams.ROMSize != romlen)\n",
     "    // census: the game list marks some carts NAND (8-10) whose header has no\n"
     "    // NAND save area (0x96 = 0), e.g. Electroplankton (ATIx): the NAND cart\n"
     "    // would then return FF for every ROM read. Such a cart gets EEPROM 8 KiB,\n"
     "    // as the core's savelist does (NAND counts as not listed); --save-type wins.\n"
     "    if (romparams.SaveMemType >= 8 && romparams.SaveMemType <= 10 && header.NANDRWStart == 0)\n"
     "    {\n"
     "        Log(LogLevel::Warn, \"census: %.4s listed NAND without a NAND area, using EEPROM 8 KiB\\n\", header.GameCode);\n"
     "        romparams.SaveMemType = 2;\n"
     "    }\n"
     "    if (args && args->SaveMemType)\n"
     "        romparams.SaveMemType = *args->SaveMemType;\n"
     "\n"
     "    if (romparams.ROMSize != romlen)\n")
edit("NDSCart.h", "    u32 SRAMLength = 0;\n};\n",
     "    u32 SRAMLength = 0;\n\n"
     "    /// Save memory type (ROMList SaveMemType, 0-10) to use instead of the\n"
     "    /// game list's entry. If \\c nullopt, the game list decides.\n"
     "    std::optional<u32> SaveMemType = std::nullopt;\n};\n")
edit("GPU.cpp", '#include "GPU.h"\n', '#include "GPU.h"\n#include "Census.h"\n')
edit("GPU.cpp", "void GPU::StartScanline(u32 line) noexcept\n{\n",
     "void GPU::StartScanline(u32 line) noexcept\n{\n    CENSUS_HOOK(Scanline, line);\n")

# 2D soft renderer: wrap every VRAM index so the census sees the offset
def wrap_index(name, array, args, count):
    """Rewrite array[EXPR] as array[Census::VRAMIdx(args, EXPR, bytes)];
    bytes is 2 for '*(u16*)&array[', else 1."""
    p = src / name
    t = p.read_text()
    out, i, n = [], 0, 0
    while (j := t.find(array + "[", i)) >= 0:
        k = j + len(array) + 1
        depth = 1
        while depth:
            depth += {"[": 1, "]": -1}.get(t[k], 0)
            k += 1
        expr = t[j + len(array) + 1:k - 1]
        size = 2 if t[max(0, j - 8):j] == "*(u16*)&" else 1
        out.append(t[i:j] + f"{array}[Census::VRAMIdx({args}, {expr}, {size})]")
        i, n = k, n + 1
    if n != count:
        sys.exit(f"{name}: expected {count} of {array}[, found {n}")
    p.write_text("".join(out) + t[i:])

wrap_index("GPU2D_Soft.cpp", "bgvram", "GPU2D.Num, Census::BG", 14)
wrap_index("GPU2D_Soft.cpp", "objvram", "GPU2D.Num, Census::OBJ", 9)
edit("GPU2D_Soft.cpp", "curpal[color]", "curpal[Census::PalIdx(GPU2D.Num, curpal, color)]", 3)
edit("GPU2D_Soft.cpp", "color = extpal[pixel & 0xFFF];",
     "color = extpal[Census::VRAMIdx(GPU2D.Num, Census::OBJExtPal, pixel & 0xFFF, 2)];")
edit("GPU_Soft.cpp", "        // draw BG/OBJ layers\n",
     "        CENSUS_HOOK(Line2D, line);\n        // draw BG/OBJ layers\n")

# 3D soft rasterizer: texture and palette reads, lines, skipped frames
# (GPU.h includes Census.h, so every GPU source sees the hooks)
edit("GPU.h", '#include "GPU3D.h"\n', '#include "GPU3D.h"\n#include "Census.h"\n')
edit("GPU.h", "        return *(T*)&VRAMFlat_Texture[addr & 0x7FFFF];\n",
     "        CENSUS_HOOK(VRAMRead, 2, Census::Texture, addr & 0x7FFFF, sizeof(T));\n"
     "        return *(T*)&VRAMFlat_Texture[addr & 0x7FFFF];\n")
edit("GPU.h", "        return *(T*)&VRAMFlat_TexPal[addr & 0x1FFFF];\n",
     "        CENSUS_HOOK(VRAMRead, 2, Census::TexPal, addr & 0x1FFFF, sizeof(T));\n"
     "        return *(T*)&VRAMFlat_TexPal[addr & 0x1FFFF];\n")
edit("GPU3D_Soft.cpp", "    FrameIdentical = !(textureChanged || texPalChanged) && GPU3D.RenderFrameIdentical;\n",
     "    FrameIdentical = !(textureChanged || texPalChanged) && GPU3D.RenderFrameIdentical;\n"
     "    CENSUS_HOOK(Frame3D, FrameIdentical);\n")
edit("GPU3D_Soft.cpp", "void SoftRenderer3D::RenderScanline(s32 y, int npolys)\n{\n",
     "void SoftRenderer3D::RenderScanline(s32 y, int npolys)\n{\n    CENSUS_HOOK(Line3D, y);\n")

# Sound: register writes, mixer steps, sample fetches and capture writes
edit("SPU.cpp", '#include "SPU.h"\n', '#include "SPU.h"\n#include "Census.h"\n')
for size, ty in ((8, "u8"), (16, "u16"), (32, "u32")):
    edit("SPU.cpp", f"void SPU::Write{size}(u32 addr, {ty} val)\n{{\n",
         f"void SPU::Write{size}(u32 addr, {ty} val)\n{{\n    CENSUS_HOOK(SPUWrite, {size}, addr, val);\n")
edit("SPU.cpp", "void SPU::SetPowerCnt(u32 val)\n{\n",
     "void SPU::SetPowerCnt(u32 val)\n{\n    CENSUS_HOOK(SPUPower, val);\n")
edit("SPU.cpp", "void SPU::Mix(u32 spucycles)\n{\n",
     "void SPU::Mix(u32 spucycles)\n{\n    CENSUS_HOOK(SPUMix, *this);\n")
edit("SPU.cpp", "    NDS.Mic.Advance(spucycles << 1);\n",
     "    CENSUS_HOOK(SPUMixEnd, output);\n    NDS.Mic.Advance(spucycles << 1);\n")
edit("SPU.cpp", "            FIFO[FIFOWritePos] = NDS.ARM7Read32(SrcAddr + FIFOReadOffset);\n",
     "            FIFO[FIFOWritePos] = NDS.ARM7Read32(SrcAddr + FIFOReadOffset);\n"
     "            CENSUS_HOOK(SPUFetch, SrcAddr + FIFOReadOffset, FIFO[FIFOWritePos]);\n")
edit("SPU.cpp", "        NDS.ARM7Write32(DstAddr + FIFOWriteOffset, FIFO[FIFOReadPos]);\n",
     "        CENSUS_HOOK(SPUCapture, DstAddr + FIFOWriteOffset, FIFO[FIFOReadPos]);\n"
     "        NDS.ARM7Write32(DstAddr + FIFOWriteOffset, FIFO[FIFOReadPos]);\n")

edit("NDS.cpp", "namespace melonDS\n{\n", "namespace melonDS\n{\nCensus::Hooks* Census::Active = nullptr;\n")
edit("NDS.cpp", '#include "NDS.h"\n', '#include "NDS.h"\n#include "Census.h"\n')
print("hooks inserted")
