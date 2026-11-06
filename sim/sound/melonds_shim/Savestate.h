// Shim: SPU::DoSavestate is compiled but never called.
#pragma once
#include "types.h"
namespace melonDS
{
class Savestate
{
public:
    void Section(const char*) {}
    void Var8(u8*) {}
    void Var16(u16*) {}
    void Var32(u32*) {}
    void Bool32(bool*) {}
    void VarArray(void*, u32) {}
};
}
