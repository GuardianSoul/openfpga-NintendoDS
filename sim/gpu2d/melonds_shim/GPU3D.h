// Shim: GPU2D.cpp forwards BG0HOFS writes to the 3D engine's X scroll.
#pragma once
#include "types.h"
namespace melonDS
{
class GPU3D
{
public:
    void SetRenderXPos(u16, u16) {}
};
}
