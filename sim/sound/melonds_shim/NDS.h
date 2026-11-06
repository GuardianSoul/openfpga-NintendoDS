// Shim: what SPU.cpp needs from NDS. Sample fetches and capture writes go to
// a Bus the testbench provides; events are scheduled by the testbench, which
// calls SPU::Mix(512) once per output step.
#pragma once
#include <functional>
#include <initializer_list>
#include "types.h"
#include "Platform.h"
#include "SPU.h"

namespace melonDS
{
enum { Event_SPU = 0 };
using EventFunc = void (*)(void*, u32);
using EventFuncList = std::initializer_list<EventFunc>;
#define MakeEventThunk(class, func) [](void* that, u32 param) { static_cast<class*>(that)->func(param); }

struct Mic { void Advance(u32) {} };

class NDS
{
public:
    int ConsoleType = 0;
    melonDS::Mic Mic;
    std::function<u32(u32)> Read32;
    std::function<void(u32, u32)> Write32;
    u32 ARM7Read32(u32 addr) { return Read32(addr); }
    void ARM7Write32(u32 addr, u32 val) { Write32(addr, val); }
    void RegisterEventFuncs(u32, void*, EventFuncList) {}
    void UnregisterEventFuncs(u32) {}
    void ScheduleEvent(u32, bool, s32, u32, u32) {}
};
}
