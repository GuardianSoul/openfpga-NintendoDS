// Shim: Vertex, Polygon, the latched render state of melonDS::GPU3D and the
// Renderer3D base class, field-for-field as in references/melonDS/src/GPU3D.h.
// Only what the software renderer reads is kept.
#pragma once
#include <array>
#include "types.h"
#include "GPU.h"
namespace melonDS
{
struct Vertex
{
    s32 Position[4];
    s32 Color[3];
    s16 TexCoords[2];
    bool Clipped;
    s32 FinalPosition[2];
    s32 FinalColor[3];
    s32 HiresPosition[2];
};

struct Polygon
{
    Vertex* Vertices[10];
    u32 NumVertices;
    s32 FinalZ[10];
    s32 FinalW[10];
    bool WBuffer;
    u32 Attr;
    u32 TexParam;
    u32 TexPalette;
    bool Degenerate;
    bool FacingView;
    bool Translucent;
    bool IsShadowMask;
    bool IsShadow;
    int Type;
    u32 VTop, VBottom;
    s32 YTop, YBottom;
    s32 XTop, XBottom;
    u32 SortKey;
};

class GPU3D
{
public:
    explicit GPU3D(melonDS::GPU& gpu) : GPU(gpu) {}
    void DoSavestate(Savestate* file) noexcept;

    melonDS::GPU& GPU;

    u32 RenderDispCnt = 0;
    u8 RenderAlphaRef = 0;
    u16 RenderToonTable[32] {};
    u16 RenderEdgeTable[8] {};
    u32 RenderFogColor = 0;
    u32 RenderFogOffset = 0;
    u32 RenderFogShift = 0;
    u8 RenderFogDensityTable[34] {};
    u32 RenderClearAttr1 = 0;
    u32 RenderClearAttr2 = 0;
    bool RenderFrameIdentical = false;
    u16 RenderXPos = 0;
    bool AbortFrame = false;

    std::array<Polygon*,2048> RenderPolygonRAM {};
    u32 RenderNumPolygons = 0;
};

class Renderer3D
{
public:
    explicit Renderer3D(melonDS::GPU3D& gpu3D) : GPU(gpu3D.GPU), GPU3D(gpu3D) {}
    virtual ~Renderer3D() = default;
    Renderer3D(const Renderer3D&) = delete;
    Renderer3D& operator=(const Renderer3D&) = delete;
    virtual bool Init() { return true; }
    virtual void Reset() = 0;
    virtual void RenderFrame() = 0;
    virtual void FinishRendering() {}
    virtual void RestartFrame() {};
    virtual u32* GetLine(int line) = 0;
    virtual bool NeedsShaderCompile() { return false; }
    virtual void ShaderCompileStep(int& current, int& count) {}
protected:
    melonDS::GPU& GPU;
    melonDS::GPU3D& GPU3D;
};
}
