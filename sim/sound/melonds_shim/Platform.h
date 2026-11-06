// Shim: logging and the audio mutex.
#pragma once
#include <algorithm>
#include "types.h"
namespace melonDS::Platform
{
enum class LogLevel { Debug, Info, Warn, Error };
inline void Log(LogLevel, const char*, ...) {}
struct Mutex {};
inline Mutex* Mutex_Create() { return new Mutex; }
inline void Mutex_Free(Mutex* m) { delete m; }
inline void Mutex_Lock(Mutex*) {}
inline void Mutex_Unlock(Mutex*) {}
}
