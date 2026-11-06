/* sys.nds, ARM7: answers the ARM9's numbered commands (mailbox in main RAM). */
#include "../common/ds.h"
#include "../common/ipc.h"
#include "swi_data.h"

enum { CMD_SYNC = 1, CMD_FIFO_RX, CMD_FIFO_TX, CMD_SWI, CMD_WRAM, CMD_VRAM, CMD_DMA };

/* Runs from ARM7 WRAM (0x0380C000): while it runs the ARM9 changes WRAMCNT,
   which may unmap the shared WRAM the rest of this program lives in. Only
   the mailbox (main RAM) and the stack (ARM7 WRAM) are touched. */
__attribute__((section(".iwram"), noinline)) static void wram_phase(u32 cmd)
{
    volatile mailbox_t *mb = MB;
    u32 last = 0;
    mb->suback = 0;
    mb->ack = cmd;
    for (;;) {
        u32 s = mb->sub;
        if (s == last)
            continue;
        if (s == 0)
            break;
        mb->subval = *(volatile u32 *)mb->subaddr;
        mb->suback = s;
        last = s;
    }
    mb->ack = 0x5E;
}

int main(void)
{
    MB->cmd = 0;
    MB->ack = 0;
    MB->sub = 0;
    MB->suback = 0;
    IPCFIFOCNT = FIFO_ENABLE | FIFO_ERROR | FIFO_SEND_CLEAR;
    IPCSYNC = A7_READY << 8;

    u32 last = 0;
    for (;;) {
        u32 cmd = MB->cmd;
        if (cmd == last)
            continue;
        last = cmd;
        switch (cmd) {
        case CMD_SYNC: {
            u32 t = 0;
            while ((IPCSYNC & 0xF) != 5 && ++t < 1000000)
                ;
            MB->val[0] = IPCSYNC & 0xF;
            IPCSYNC = 0xA << 8;
            break;
        }
        case CMD_FIFO_RX: {
            MB->val[1] = IPCFIFOCNT & 0xC303;
            u32 s = 0;
            for (int i = 0; i < 16; i++)
                s += IPCFIFORECV;
            MB->val[0] = s;
            MB->val[2] = IPCFIFOCNT & 0xC303;
            break;
        }
        case CMD_FIFO_TX:
            for (u32 i = 0; i < 16; i++)
                IPCFIFOSEND = 0xC0DE0000 + i * 0x111;
            break;
        case CMD_SWI: {
            MB->val[0] = (u32)swi_div(-1234, 10, 0, 0);
            MB->val[1] = swi_sqrt(1000000);
            u32 cp = swi_copies(1), lz = swi_lz(1);
            MB->val[2] = hash_bytes((const u8 *)&cp, 4, lz);
            MB->val[3] = swi_crc16(0xFFFF, swi_src, 64);
            break;
        }
        case CMD_WRAM:
            wram_phase(cmd);
            continue;                       /* wram_phase acknowledges */
        case CMD_DMA: {
            /* ARM7 WRAM read by the CPU, then rewritten by DMA3: the CPU must
               see the DMA's words (the ARM7 port's data cache forgets them) */
            volatile u32 *buf = (volatile u32 *)0x0380D000, *src = (volatile u32 *)0x023F2000;
            u32 s0 = 0, s1 = 0;
            for (u32 i = 0; i < 8; i++) buf[i] = 0x11110000 + i;
            for (u32 i = 0; i < 8; i++) s0 += buf[i];
            for (u32 i = 0; i < 8; i++) src[i] = 0x22220000 + i;
            DMA_SAD(3) = (u32)src;
            DMA_DAD(3) = (u32)buf;
            DMA_CNT(3) = DMA_ENABLE | DMA_32BIT | 8;
            while (DMA_CNT(3) & DMA_ENABLE)
                ;
            for (u32 i = 0; i < 8; i++) s1 += buf[i];
            MB->val[0] = s0;
            MB->val[1] = s1;
            /* words just stored are read by DMA right away (the stores must
               reach the memory before the DMA reads it) */
            volatile u32 *b2 = (volatile u32 *)0x0380D100, *dst = (volatile u32 *)0x023F2100;
            DMA_SAD(3) = (u32)b2;
            DMA_DAD(3) = (u32)dst;
            for (u32 i = 8; i-- > 0; ) b2[i] = 0x33330000 + i;   /* b2[0], read first, stored last */
            DMA_CNT(3) = DMA_ENABLE | DMA_32BIT | 8;
            while (DMA_CNT(3) & DMA_ENABLE)
                ;
            u32 s2 = 0;
            for (u32 i = 0; i < 8; i++) s2 += dst[i];
            MB->val[2] = s2;
            /* code written by the ARM7 and run twice (mov r0, #n; bx lr) */
            volatile u32 *code = (volatile u32 *)0x0380D200;
            u32 (*fn)(void) = (u32 (*)(void))0x0380D200;
            code[0] = 0xE3A00001; code[1] = 0xE12FFF1E;
            u32 r1 = fn();
            code[0] = 0xE3A00002;
            u32 r2 = fn();
            MB->val[3] = r1 << 4 | r2;
            break;
        }
        case CMD_VRAM:
            MB->val[0] = R32(0x06000000 + 0x1FFF0);
            MB->val[1] = R32(0x06020000 + 0x1FFF0);
            MB->val[2] = VRAMSTAT;
            break;
        }
        MB->ack = cmd;
    }
}
