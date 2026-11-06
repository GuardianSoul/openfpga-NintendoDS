// Explicit external filesystem input for the ORIGINAL C19 prefix only.
// Link with --wrap=get_fattime. Emulated RTC/timers and RAM are untouched.
// Original five FAT directory words record 2026-10-31 23:46:50 local FAT time.
#include <cstdint>
extern "C" std::uint32_t __wrap_get_fattime(void)
{
    return UINT32_C(0x5d5fbdd9);
}
