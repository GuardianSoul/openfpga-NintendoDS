/* cart.nds, ARM9: reads its own ROM through the card registers (polling and
   card DMA), chip ID, the save chip (an EEPROM 8 KiB: melonDS's choice for
   an unlisted game, and the core's); then hands the slot to the ARM7
   (EXMEMCNT bit 11) and lets it read too. */
#include "../common/con.h"
#include "../common/results.h"
#include "../common/ipc.h"
#include "card.h"

static u32 buf[128];

static void card_read_dma(u32 addr, u32 *dst)
{
    card_cmd(0xB7, addr);
    DMA_SAD(0) = 0x04100010;
    DMA_DAD(0) = (u32)dst;
    DMA_CNT(0) = DMA_ENABLE | DMA_32BIT | DMA_REPEAT | DMA_SRC_FIX | DMA9_START_CARD | 1;
    ROMCTRL = ROMCTRL_START | ROMCTRL_RESB | ROMCTRL_BLK(1) | ROMCTRL_NORMAL;
    while (ROMCTRL & ROMCTRL_START)
        ;
    DMA_CNT(0) = 0;
}

static void clear(void)
{
    for (int i = 0; i < 128; i++)
        buf[i] = 0;
}

static u32 spi_xfer(u32 v, int hold)
{
    AUXSPICNT = 0xA000 | (hold ? 0x40 : 0);   /* slot on, SPI mode, 4 MHz */
    AUXSPIDATA = (u16)v;
    while (AUXSPICNT & 0x80)
        ;
    return AUXSPIDATA & 0xFF;
}

/* save chip: command, two address bytes, n data bytes in or out */
static void save_cmd(u32 c, u32 a, u8 *d, int n, int wr)
{
    spi_xfer(c, 1);
    spi_xfer(a >> 8, 1);
    spi_xfer(a & 0xFF, n > 0);
    for (int i = 0; i < n; i++) {
        u32 v = spi_xfer(wr ? d[i] : 0, i < n - 1);
        if (!wr)
            d[i] = v;
    }
    AUXSPICNT = 0x8000;
}

static void save_one(u32 c)
{
    spi_xfer(c, 0);
    AUXSPICNT = 0x8000;
}

static u32 save_status(void)
{
    spi_xfer(0x05, 1);
    u32 st = spi_xfer(0x00, 0);
    AUXSPICNT = 0x8000;
    return st;
}

static u8 sb[16];

static u32 save_count(u32 base)
{
    u32 n = 0;
    for (int i = 0; i < 16; i++)
        n += sb[i] == (u8)(base + 7 * i);
    return n;
}

int main(void)
{
    con_init();
    res_begin("CART TEST", 15);
    int a7 = a7_wait_ready();
    EXMEMCNT &= ~0x0800;                       /* NDS slot to the ARM9 */

    clear(); card_read_poll(0x8000, buf);
    res_check(0, "A9P8000", count_equal(buf, (volatile u32 *)0x02000000), 128);
    con_printf(BOTTOM, 0, 1, PAL_WHITE, "ROM 8000: %08X %08X", buf[0], buf[1]);
    clear(); card_read_poll(0x20000, buf);
    res_check(1, "A9P20000", count_pattern(buf, 0x20000), 128);
    con_printf(BOTTOM, 0, 2, PAL_WHITE, "ROM 20000: %08X %08X", buf[0], buf[1]);
    clear(); card_read_poll(0x2F200, buf);
    res_check(2, "A9P2F200", count_pattern(buf, 0x2F200), 128);
    clear(); card_read_dma(0x24A00, buf);
    res_check(3, "A9D24A00", count_pattern(buf, 0x24A00), 128);
    clear(); card_read_dma(0x8200, buf);
    res_check(4, "A9D8200", count_equal(buf, (volatile u32 *)0x02000200), 128);

    u32 id = card_chip_id();
    res_record(5, "CHIPID9", id, id != 0 && id != 0xFFFFFFFF);

    spi_xfer(0x05, 1);                         /* read status register */
    u32 st = spi_xfer(0x00, 0);
    AUXSPICNT = 0x8000;
    res_record(6, "SPISTAT", st, 1);           /* recorded only */

    /* save chip: blank, write enable, write and read back, a write with
       write enable off, the address wrapping at the chip size */
    save_cmd(0x03, 0x0100, sb, 16, 0);
    u32 n = 0;
    for (int i = 0; i < 16; i++)
        n += sb[i] == 0xFF;
    res_check(10, "SVBLANK", n, 16);
    save_one(0x06);
    u32 wst = save_status();
    for (int i = 0; i < 16; i++)
        sb[i] = (u8)(0x40 + 7 * i);
    save_cmd(0x02, 0x0100, sb, 16, 1);
    for (int i = 0; i < 16; i++)
        sb[i] = 0;
    save_cmd(0x03, 0x0100, sb, 16, 0);
    res_check(11, "SVWRITE", save_count(0x40), 16);
    save_one(0x04);
    res_check(12, "SVSTAT", wst << 8 | save_status(), 0x0200);
    for (int i = 0; i < 16; i++)
        sb[i] = 0x11;
    save_cmd(0x02, 0x0100, sb, 16, 1);
    save_cmd(0x03, 0x2100, sb, 16, 0);         /* 8 KiB chip: 0x2100 is 0x0100 */
    res_check(13, "SVWRDI", save_count(0x40), 16);
    save_cmd(0x03, 0x0108, sb, 8, 0);
    n = 0;
    for (int i = 0; i < 8; i++)
        n += sb[i] == (u8)(0x40 + 7 * (i + 8));
    res_check(14, "SVOFFS", n, 8);

    EXMEMCNT |= 0x0800;                        /* NDS slot to the ARM7 */
    if (a7)
        a7_cmd(1);
    res_check(7, "A7P21000", MB->val[0], 128);
    res_check(8, "A7P2FE00", MB->val[1], 128);
    res_check(9, "CHIPID7", MB->val[2], id);
    res_finish();
    con_printf(BOTTOM, 0, 0, PAL_WHITE, "CHIP ID %08X SPI STATUS %02X", id, st);
    for (;;)
        ;
}
