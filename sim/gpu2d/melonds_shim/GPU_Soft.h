// Shim: the part of melonDS::SoftRenderer that SoftRenderer2D uses -- the
// 2D output lines and the 3D layer line (references/melonDS/src/GPU_Soft.h).
#pragma once
#include "GPU.h"
#include "GPU2D_Soft.h"
namespace melonDS
{
class SoftRenderer
{
public:
    u32* Output3D = nullptr;
    alignas(8) u32 Output2D[2][256] {};
};
}
