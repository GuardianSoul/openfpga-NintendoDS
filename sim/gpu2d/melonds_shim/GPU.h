// Shim: the part of melonDS::GPU that GPU2D.cpp and GPU2D_Soft.cpp use --
// palette, OAM and the flat 2D VRAM views (references/melonDS/src/GPU.h).
// The arrays are pointers into the harness's memory image (sim/gpu2d/
// state2d.h Mem), which is always coherent, so the coherence calls are
// no-ops and the dirty trackers report nothing.
#pragma once
#include <string.h>
#include "types.h"
#include "GPU2D.h"
#include "GPU3D.h"
namespace melonDS
{
class GPU;
struct DirtyTracker
{
    template<typename T> int DeriveState(T, const GPU&) const { return 0; }
};

class GPU
{
public:
    u16 VCount = 0;
    melonDS::GPU3D GPU3D;

    u8* Palette = nullptr;
    u8* OAM = nullptr;

    u32 VRAMMap_ABG[0x20] {}, VRAMMap_AOBJ[0x10] {}, VRAMMap_BBG[0x8] {}, VRAMMap_BOBJ[0x8] {};
    u32 VRAMMap_ABGExtPal[4] {}, VRAMMap_AOBJExtPal {}, VRAMMap_BBGExtPal[4] {}, VRAMMap_BOBJExtPal {};
    DirtyTracker VRAMDirty_ABG, VRAMDirty_AOBJ, VRAMDirty_BBG, VRAMDirty_BOBJ;
    DirtyTracker VRAMDirty_ABGExtPal, VRAMDirty_BBGExtPal, VRAMDirty_AOBJExtPal, VRAMDirty_BOBJExtPal;
    bool MakeVRAMFlat_ABGCoherent(int) { return true; }
    bool MakeVRAMFlat_BBGCoherent(int) { return true; }
    bool MakeVRAMFlat_AOBJCoherent(int) { return true; }
    bool MakeVRAMFlat_BOBJCoherent(int) { return true; }
    bool MakeVRAMFlat_ABGExtPalCoherent(int) { return true; }
    bool MakeVRAMFlat_BBGExtPalCoherent(int) { return true; }
    bool MakeVRAMFlat_AOBJExtPalCoherent(int) { return true; }
    bool MakeVRAMFlat_BOBJExtPalCoherent(int) { return true; }

    void GetCaptureInfo_ABG(int*) const {}
    void GetCaptureInfo_BBG(int*) const {}
    void GetCaptureInfo_AOBJ(int*) const {}
    void GetCaptureInfo_BOBJ(int*) const {}

    u8 *VRAMFlat_ABG = nullptr, *VRAMFlat_BBG = nullptr, *VRAMFlat_AOBJ = nullptr, *VRAMFlat_BOBJ = nullptr;
    u8 *VRAMFlat_ABGExtPal = nullptr, *VRAMFlat_BBGExtPal = nullptr;
    u8 *VRAMFlat_AOBJExtPal = nullptr, *VRAMFlat_BOBJExtPal = nullptr;
};
}
