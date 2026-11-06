#pragma once
#include <string>
#include "NDS.h"
// Frontend observers only; no core members or device class layouts change.
melonDS::NDS* CreateRuntimeHistoryNDS(melonDS::NDSArgs&& args);
void ConfigureRuntimeHistory(melonDS::u64 until, melonDS::u32 window);
void BeginRuntimeHistory(const melonDS::NDS& n);
void RuntimeHistoryIntent(const melonDS::NDS& n, int cpu, melonDS::u32 src, melonDS::u32 addr, melonDS::u32 value, melonDS::u32 bytes);
void RuntimeHistoryCapture(const melonDS::NDS& n, melonDS::u32 addr, melonDS::u32 value);
void RuntimeHistoryMix(const melonDS::NDS& n, bool end);
void ExportRuntimeHistory(const melonDS::NDS& n, const std::string& dir, int cleanLine);
void RuntimeHistoryCompleteTCM(const melonDS::NDS& n);
