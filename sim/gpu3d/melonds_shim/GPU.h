// Shim: the part of melonDS::GPU that GPU3D_Soft.cpp uses -- the flat
// texture and texture-palette VRAM views (same masking as the real
// ReadVRAMFlat_* in references/melonDS/src/GPU.h). The harness fills the
// flat arrays directly, so the coherence calls report "changed".
#pragma once
#include <string.h>
#include "types.h"
namespace melonDS
{
class SoftRenderer {};
class Savestate;

class GPU
{
public:
    struct DirtyTracker
    {
        int DeriveState(int, const GPU&) const { return 0; }
    };

    template<typename T>
    inline T ReadVRAMFlat_Texture(u32 addr) const
    {
        T v; memcpy(&v, &VRAMFlat_Texture[addr & 0x7FFFF], sizeof(T)); return v;
    }
    template<typename T>
    inline T ReadVRAMFlat_TexPal(u32 addr) const
    {
        T v; memcpy(&v, &VRAMFlat_TexPal[addr & 0x1FFFF], sizeof(T)); return v;
    }
    bool MakeVRAMFlat_TextureCoherent(int) { return true; }
    bool MakeVRAMFlat_TexPalCoherent(int) { return true; }

    DirtyTracker VRAMDirty_Texture, VRAMDirty_TexPal;
    int VRAMMap_Texture = 0, VRAMMap_TexPal = 0;

    alignas(u64) u8 VRAMFlat_Texture[512*1024] {};
    alignas(u64) u8 VRAMFlat_TexPal[128*1024] {};
};
}
