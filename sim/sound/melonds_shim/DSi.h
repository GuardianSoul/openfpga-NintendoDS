// Shim: SPU::Mix only reaches DSi::I2S when ConsoleType == 1 (never here).
#pragma once
#include "NDS.h"
#include "DSi_I2S.h"
namespace melonDS
{
class DSi : public NDS
{
public:
    DSi_I2S I2S;
};
}
