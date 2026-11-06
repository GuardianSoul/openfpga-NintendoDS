// Shim: GPU2D.cpp logs unknown register accesses.
#pragma once
#include "types.h"
namespace melonDS::Platform
{
enum class LogLevel { Debug, Info, Warn, Error };
inline void Log(LogLevel, const char*, ...) {}
}
