// Linked-core identity for reference-generation mode guards.
#pragma once
namespace melonDS::Census {
struct RuleModeInfo { const char* mode; const char* const* rules; unsigned count; };
const RuleModeInfo& GetCompiledRuleMode();
#ifdef MELONDS_STOCK
inline constexpr const char* DeclaredMode="stock";
inline constexpr unsigned DeclaredRuleCount=0;
#else
inline constexpr const char* DeclaredMode="ds-rules-23";
inline constexpr unsigned DeclaredRuleCount=23;
#endif
}
