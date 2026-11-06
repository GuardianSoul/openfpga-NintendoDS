/* Shared by sys/arm9.c and sys/arm7.c: BIOS SWI inputs and a software
   model of each call (GBATEK "BIOS Functions") to compute the expected
   results. */
#ifndef SWI_DATA_H
#define SWI_DATA_H
#include "../common/ds.h"

/* "NDS POCKET LZ77 TEST: ..." compressed by hand-written greedy LZ77
   (type 0x10, GBATEK "BIOS Decompression Functions") */
static const char lz_plain[] = "NDS POCKET LZ77 TEST: ABCDABCDABCDABCD 0123456789 0123456789 0123456789!!...";
static const u8 lz_data[60] __attribute__((aligned(4))) = {0x10,0x4C,0x00,0x00,0x00,0x4E,0x44,0x53,0x20,0x50,0x4F,0x43,0x4B,0x00,0x45,0x54,0x20,0x4C,0x5A,0x37,0x37,0x20,0x00,0x54,0x45,0x53,0x54,0x3A,0x20,0x41,0x42,0x20,0x43,0x44,0x90,0x03,0x20,0x30,0x31,0x32,0x33,0x03,0x34,0x35,0x36,0x37,0x38,0x39,0xF0,0x0A,0x10,0x0A,0x00,0x21,0x21,0x2E,0x2E,0x2E,0x00,0x00};
#define LZ_LEN 76

static inline u32 hash_bytes(const volatile u8 *p, u32 n, u32 h)
{
    for (u32 i = 0; i < n; i++)
        h = h * 31 + p[i];
    return h;
}

static inline u32 crc16_sw(u32 crc, const u8 *p, u32 n)
{
    for (u32 i = 0; i < n; i++) {
        crc ^= p[i];
        for (int k = 0; k < 8; k++)
            crc = (crc & 1) ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
    return crc & 0xFFFF;
}

static u32 swi_src[32] = {
    0x01234567, 0x89ABCDEF, 0xDEADBEEF, 0x0BADF00D, 0x11111111, 0x22222222, 0x33333333, 0x44444444,
    0x55555555, 0x66666666, 0x77777777, 0x88888888, 0x99999999, 0xAAAAAAAA, 0xBBBBBBBB, 0xCCCCCCCC,
    0xCAFEBABE, 0xFEEDFACE, 0x8BADF00D, 0xC001D00D, 0x00000001, 0x00000002, 0x00000004, 0x00000008,
    0x80000000, 0x40000000, 0x20000000, 0x10000000, 0x0F0F0F0F, 0xF0F0F0F0, 0x5A5A5A5A, 0xA5A5A5A5,
};
static u32 swi_dst[96];   /* .bss: main RAM (or ARM7 RAM), never DTCM */

/* CpuSet copy 32-bit (20 words) + CpuSet fill 16-bit (24 halfwords of
   0x1357) + CpuFastSet copy (32 words) + CpuFastSet fill (16 words of
   0x2468ACE0). Returns the hash of the 96-word destination. */
static inline u32 swi_copies(int use_bios)
{
    static u16 fill16 = 0x1357;
    static u32 fill32 = 0x2468ACE0;
    u16 *d16 = (u16 *)&swi_dst[20];
    for (int i = 0; i < 96; i++)
        swi_dst[i] = 0;
    if (use_bios) {
        swi_cpuset(swi_src, &swi_dst[0], 20 | (1 << 26));
        swi_cpuset(&fill16, d16, 24 | (1 << 24));
        swi_cpufastset(swi_src, &swi_dst[48], 32);
        swi_cpufastset(&fill32, &swi_dst[80], 16 | (1 << 24));
    } else {
        for (int i = 0; i < 20; i++) swi_dst[i] = swi_src[i];
        for (int i = 0; i < 24; i++) d16[i] = fill16;
        for (int i = 0; i < 32; i++) swi_dst[48 + i] = swi_src[i];
        for (int i = 0; i < 16; i++) swi_dst[80 + i] = fill32;
    }
    return hash_bytes((const u8 *)swi_dst, sizeof swi_dst, 0);
}

static u8 lz_out[80] __attribute__((aligned(4)));

static inline u32 swi_lz(int use_bios)
{
    for (int i = 0; i < 80; i++)
        lz_out[i] = 0xEE;
    if (use_bios)
        swi_lz77_wram(lz_data, lz_out);
    else
        for (int i = 0; i < LZ_LEN; i++)
            lz_out[i] = (u8)lz_plain[i];
    return hash_bytes(lz_out, 80, 0);
}

#endif
