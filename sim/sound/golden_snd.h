// melonDS's SPU, compiled unmodified (golden_snd.cpp), as the sound golden model.
#pragma once
#include <cstdint>
#include <functional>
#include "spu_trace.h"

namespace gsnd
{
class Golden
{
public:
    // rd/wr: sample fetches and capture writes (byte addresses).
    Golden(std::function<uint32_t(uint32_t)> rd, std::function<void(uint32_t, uint32_t)> wr);
    ~Golden();
    void write(int bits, uint32_t addr, uint32_t val);   // SPU::Write8/16/32
    uint32_t read(int bits, uint32_t addr);              // SPU::Read8/16/32
    void power(uint32_t val);                            // SetPowerCnt
    void step(int16_t out[2]);                           // SPU::Mix(512)
    void load(const spu::Snap& s);                       // state from a census trace
    void save(spu::Snap& s);                             // current state (debugging)
private:
    struct Impl;
    Impl* p;
};
}
