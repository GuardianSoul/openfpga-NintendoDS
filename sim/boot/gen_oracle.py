#!/usr/bin/env python3
"""Build a host oracle from melonDS's own KEY1 code, for comparing key1_ref.c.

usage: gen_oracle.py MELONDS_DIR OUT.cpp

The KEY1 functions, DecryptSecureArea and the cart-insert re-encryption block
are cut out of MELONDS_DIR/src/NDSCart.cpp unmodified and wrapped in a minimal
stand-in for NDSCartSlot. The generated file lands in the build directory only
(melonDS is GPL-3.0; nothing of it is checked into this repo).

The oracle program: oracle ROM.nds BIOS7.bin DIR. It reproduces what melonDS
does with ROM: re-encrypt the secure area on insert if the dump is decrypted,
then DecryptSecureArea for direct boot. It compares with DIR/enc.bin and
DIR/enc.exp (from key1_ref), and runs DecryptSecureArea on DIR/raw.bin too and
compares with DIR/raw.exp.
"""
import re
import sys


def block(src, start_re):
    """The text from the line matching start_re through its closing brace."""
    m = re.search(start_re, src, re.M)
    if not m:
        sys.exit(f"gen_oracle: '{start_re}' not found in NDSCart.cpp")
    i = src.index("{", m.end())
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[m.start():j + 1]
    sys.exit("gen_oracle: unbalanced braces")


PRE = r"""
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;
enum class LogLevel { Debug, Info, Warn };
static void Log(LogLevel, const char *, ...) {}
namespace Platform { using ::Log; }
static std::vector<u8> g_rom, g_bios7;
static u32 rd32(const u8 *p) { u32 v; memcpy(&v, p, 4); return v; }
struct NDSHeader {
    u32 ARM9ROMOffset;
    u32 gc;
    u32 GameCodeAsU32() const { return gc; }
};
struct ROMListEntry { u32 GameCode; };
struct CartStub {
    NDSHeader h;
    const NDSHeader &GetHeader() const { return h; }
    const u8 *GetROM() const { return g_rom.data(); }
};
struct NDSCartSlot {
    std::array<u32, 0x412> Key1_KeyBuf;
    CartStub cart, *Cart = &cart;
    void Key1_Encrypt(u32 *data) const noexcept;
    void Key1_Decrypt(u32 *data) const noexcept;
    void Key1_ApplyKeycode(u32 *keycode, u32 mod) noexcept;
    void Key1_LoadKeyBuf(bool) noexcept { memcpy(Key1_KeyBuf.data(), g_bios7.data() + 0x30, 0x1048); }
    void Key1_InitKeycode(bool dsi, u32 idcode, u32 level, u32 mod) noexcept;
    void DecryptSecureArea(u8 *out) noexcept;
    void Reencrypt() noexcept;
};
"""

POST = r"""
static std::vector<u8> slurp(const char *p)
{
    FILE *f = fopen(p, "rb");
    if (!f) { perror(p); exit(2); }
    std::vector<u8> d;
    int c;
    while ((c = fgetc(f)) != EOF) d.push_back((u8)c);
    fclose(f);
    return d;
}

static int same(const u8 *a, const char *dir, const char *name)
{
    std::string p = std::string(dir) + "/" + name;
    std::vector<u8> b = slurp(p.c_str());
    if (b.size() != 0x800 || memcmp(a, b.data(), 0x800) != 0) {
        printf("oracle: %s differs from melonDS\n", name);
        return 0;
    }
    return 1;
}

int main(int argc, char **argv)
{
    if (argc != 4) { fprintf(stderr, "usage: oracle ROM BIOS7 DIR\n"); return 2; }
    g_rom = slurp(argv[1]);
    g_bios7 = slurp(argv[2]);
    static NDSCartSlot s;
    s.cart.h.ARM9ROMOffset = rd32(&g_rom[0x20]);
    s.cart.h.gc = rd32(&g_rom[0x0C]);
    s.Reencrypt();
    int ok = same(&g_rom[s.cart.h.ARM9ROMOffset], argv[3], "enc.bin");
    u8 out[0x800];
    s.DecryptSecureArea(out);
    ok &= same(out, argv[3], "enc.exp");
    // DecryptSecureArea on the file's bytes unchanged
    std::vector<u8> raw = slurp((std::string(argv[3]) + "/raw.bin").c_str());
    memcpy(&g_rom[s.cart.h.ARM9ROMOffset], raw.data(), 0x800);
    s.DecryptSecureArea(out);
    ok &= same(out, argv[3], "raw.exp");
    printf("oracle: %s\n", ok ? "melonDS agrees" : "MISMATCH");
    return ok ? 0 : 1;
}
"""


def main():
    src = open(f"{sys.argv[1]}/src/NDSCart.cpp").read()
    parts = [PRE, block(src, r"^constexpr u32 ByteSwap")]
    for fn in ("Key1_Encrypt", "Key1_Decrypt", "Key1_ApplyKeycode", "Key1_InitKeycode",
               "DecryptSecureArea"):
        parts.append(block(src, rf"^void NDSCartSlot::{fn}\("))
    reenc = block(src, r"^\s*if \(\*\(u32\*\)&cartrom\[header\.ARM9ROMOffset\] == 0xE7FFDEFF")
    parts.append("void NDSCartSlot::Reencrypt() noexcept\n{\n"
                 "    const NDSHeader& header = Cart->GetHeader();\n"
                 "    const ROMListEntry romparams = {header.GameCodeAsU32()};\n"
                 "    const u8* cartrom = Cart->GetROM();\n"
                 f"{reenc}\n}}\n")
    parts.append(POST)
    open(sys.argv[2], "w").write("\n".join(parts))


if __name__ == "__main__":
    main()
