/* Cartridge-slot helpers shared by cart/arm9.c and cart/arm7.c
   (GBATEK "DS Cartridge Protocol" / "DS Cartridge I/O Ports"). */
#ifndef CARD_H
#define CARD_H
#include "../common/ds.h"

/* ROMCTRL for normal commands, as written to header 0x60 by mknds.py
   (KEY2 command/data bits and gap2 = 0x18, the usual commercial value). */
#define ROMCTRL_NORMAL 0x00586000u
#define ROMCTRL_START  (1u << 31)
#define ROMCTRL_RESB   (1u << 29)
#define ROMCTRL_READY  (1u << 23)
#define ROMCTRL_BLK(n) ((u32)(n) << 24)   /* 1 = 0x200 bytes, 7 = 4 bytes */

/* word at ROM offset o in the pattern section (tools/ds-tests/mknds.py) */
static inline u32 pattern_word(u32 o)
{
    return (o * 0x9E3779B1u) ^ 0xC3A5F00Fu;
}

static inline void card_cmd(u8 c, u32 addr)
{
    AUXSPICNT = 0x8000;                    /* slot on, ROM mode */
    CARDCMD[0] = c;
    CARDCMD[1] = (u8)(addr >> 24);
    CARDCMD[2] = (u8)(addr >> 16);
    CARDCMD[3] = (u8)(addr >> 8);
    CARDCMD[4] = (u8)addr;
    CARDCMD[5] = 0;
    CARDCMD[6] = 0;
    CARDCMD[7] = 0;
}

/* 0xB7 data read of 0x200 bytes by polling ROMCTRL bit 23 */
static inline void card_read_poll(u32 addr, u32 *dst)
{
    card_cmd(0xB7, addr);
    ROMCTRL = ROMCTRL_START | ROMCTRL_RESB | ROMCTRL_BLK(1) | ROMCTRL_NORMAL;
    u32 n = 0;
    while (ROMCTRL & ROMCTRL_START)
        if (ROMCTRL & ROMCTRL_READY) {
            u32 w = CARDDATA;
            if (n < 128)
                dst[n++] = w;
        }
}

static inline u32 card_chip_id(void)
{
    card_cmd(0xB8, 0);
    ROMCTRL = ROMCTRL_START | ROMCTRL_RESB | ROMCTRL_BLK(7) | ROMCTRL_NORMAL;
    u32 id = 0;
    while (ROMCTRL & ROMCTRL_START)
        if (ROMCTRL & ROMCTRL_READY)
            id = CARDDATA;
    return id;
}

static inline u32 count_pattern(const u32 *buf, u32 addr)
{
    u32 n = 0;
    for (u32 i = 0; i < 128; i++)
        n += buf[i] == pattern_word(addr + 4 * i);
    return n;
}

static inline u32 count_equal(const u32 *buf, const volatile u32 *ref)
{
    u32 n = 0;
    for (u32 i = 0; i < 128; i++)
        n += buf[i] == ref[i];
    return n;
}

#endif
