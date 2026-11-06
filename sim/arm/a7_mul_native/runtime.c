#include "native.h"
int memcmp(const void*a,const void*b,u32 n){const u8*x=a,*y=b;for(u32 i=0;i<n;i++)if(x[i]!=y[i])return x[i]-y[i];return 0;}
