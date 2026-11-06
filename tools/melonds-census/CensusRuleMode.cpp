// Compiled as a member of libcore, independently of the CLI translation unit.
#include "CensusRuleMode.h"
namespace melonDS::Census {
static const char* const rules[] = {
#ifndef MELONDS_STOCK
#ifdef DS_RULE_TOON
    "DS_RULE_TOON",
#endif
#ifdef DS_RULE_HILITE
    "DS_RULE_HILITE",
#endif
#ifdef DS_RULE_LIN17
    "DS_RULE_LIN17",
#endif
#ifdef DS_RULE_LINZ
    "DS_RULE_LINZ",
#endif
#ifdef DS_RULE_YPERSP
    "DS_RULE_YPERSP",
#endif
#ifdef DS_RULE_XPERSP16
    "DS_RULE_XPERSP16",
#endif
#ifdef DS_RULE_AACOV
    "DS_RULE_AACOV",
#endif
#ifdef DS_RULE_AAYCOV
    "DS_RULE_AAYCOV",
#endif
#ifdef DS_RULE_TEXRND
    "DS_RULE_TEXRND",
#endif
#ifdef DS_RULE_ZFACE
    "DS_RULE_ZFACE",
#endif
#ifdef DS_RULE_TEX4X4
    "DS_RULE_TEX4X4",
#endif
#ifdef DS_RULE_SPU_CAPTURE
    "DS_RULE_SPU_CAPTURE",
#endif
#ifdef DS_RULE_SPU_CAP8
    "DS_RULE_SPU_CAP8",
#endif
#ifdef DS_RULE_SPU_CAPSRC
    "DS_RULE_SPU_CAPSRC",
#endif
#ifdef DS_RULE_STRIPCLIP
    "DS_RULE_STRIPCLIP",
#endif
#ifdef DS_RULE_FARREJ
    "DS_RULE_FARREJ",
#endif
#ifdef DS_RULE_CLIPRED
    "DS_RULE_CLIPRED",
#endif
#ifdef DS_RULE_GXTIME
    "DS_RULE_GXTIME",
#endif
#ifdef DS_RULE_GXLOAD
    "DS_RULE_GXLOAD",
#endif
#ifdef DS_RULE_GXCLIP
    "DS_RULE_GXCLIP",
#endif
#ifdef DS_RULE_TMRFREE
    "DS_RULE_TMRFREE",
#endif
#ifdef DS_RULE_TMRCNT
    "DS_RULE_TMRCNT",
#endif
#ifdef DS_RULE_OBJWORK
    "DS_RULE_OBJWORK",
#endif
#endif
    nullptr
};
const RuleModeInfo& GetCompiledRuleMode() {
    static constexpr unsigned count=sizeof(rules)/sizeof(rules[0])-1;
#ifdef MELONDS_STOCK
    static const RuleModeInfo info={"stock",rules,count};
#else
    static const RuleModeInfo info={count==23 ? "ds-rules-23" : "ds-rules-partial",rules,count};
#endif
    return info;
}
}
