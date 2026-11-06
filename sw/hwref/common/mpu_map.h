// Temporary uncached data aperture for standalone ARM9 probe controllers.
// Reuses calico's MPU API. Never replace an enabled region or alter the
// timed ARM7 kernel; restore the exact configuration before file I/O.
#pragma once
#include <calico/arm/mpu.h>

typedef struct {
    int id;
    u32 region, dc, ic, wb, data, code;
} HwUncachedMap;

static bool hw_uncached_begin(HwUncachedMap* s, u32 address, unsigned size)
{
    s->id=-1;
    for(int i=7;i>=0;i--)if(!(armMpuGetRegion(i)&1)){s->id=i;break;}
    if(s->id<0)return false;
    s->region=armMpuGetRegion(s->id);
    s->dc=armMpuGetDCacheConfig();s->ic=armMpuGetICacheConfig();
    s->wb=armMpuGetWrBufConfig();s->data=armMpuGetDataPerm();s->code=armMpuGetCodePerm();
    ArmIrqState irq=armIrqLockByPsr();
    armMpuSetRegionDCacheEnable(s->id,false);
    armMpuSetRegionICacheEnable(s->id,false);
    armMpuSetRegionWrBufEnable(s->id,false);
    armMpuSetRegionDataPerm(s->id,CP15_PU_PERM_RW);
    armMpuSetRegionCodePerm(s->id,CP15_PU_PERM_NONE);
    armMpuSetRegionAddrSize(s->id,address,size);
    armIrqUnlockByPsr(irq);
    return true;
}

static bool hw_uncached_end(const HwUncachedMap* s)
{
    if(s->id<0)return false;
    ArmIrqState irq=armIrqLockByPsr();
    armMpuSetRegion(s->id,s->region);
    armMpuSetDCacheConfig(s->dc);armMpuSetICacheConfig(s->ic);
    armMpuSetWrBufConfig(s->wb);armMpuSetDataPerm(s->data);armMpuSetCodePerm(s->code);
    bool ok=armMpuGetRegion(s->id)==s->region && armMpuGetDCacheConfig()==s->dc &&
        armMpuGetICacheConfig()==s->ic && armMpuGetWrBufConfig()==s->wb &&
        armMpuGetDataPerm()==s->data && armMpuGetCodePerm()==s->code;
    armIrqUnlockByPsr(irq);
    return ok;
}
