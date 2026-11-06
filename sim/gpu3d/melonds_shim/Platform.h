// Shim: single-threaded stand-ins for the Platform calls GPU3D_Soft.cpp makes.
// The harness never enables the render thread, so these are never waited on.
#pragma once
#include <functional>
#include "types.h"
namespace melonDS::Platform
{
struct Thread {};
struct Semaphore {};
inline Semaphore* Semaphore_Create() { return new Semaphore; }
inline void Semaphore_Free(Semaphore* s) { delete s; }
inline void Semaphore_Reset(Semaphore*) {}
inline void Semaphore_Wait(Semaphore*) {}
inline void Semaphore_Post(Semaphore*, int = 1) {}
inline Thread* Thread_Create(std::function<void()>) { return nullptr; }
inline void Thread_Wait(Thread*) {}
inline void Thread_Free(Thread*) {}
}
