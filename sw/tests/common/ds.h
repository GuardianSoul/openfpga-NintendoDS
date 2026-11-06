/* Minimal DS register map for the test ROMs. Addresses and bit meanings
   from GBATEK; nothing here comes from libnds. */
#ifndef DS_H
#define DS_H

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef signed char s8;
typedef short s16;
typedef int s32;
typedef long long s64;

#define R8(a)  (*(volatile u8 *)(a))
#define R16(a) (*(volatile u16 *)(a))
#define R32(a) (*(volatile u32 *)(a))
#define R64(a) (*(volatile u64 *)(a))

/* display (both CPUs see DISPSTAT/VCOUNT at the same address) */
#define DISPCNT_A   R32(0x04000000)
#define DISPSTAT    R16(0x04000004)
#define VCOUNT      R16(0x04000006)
#define BG0CNT_A    R16(0x04000008)
#define DISPCNT_B   R32(0x04001000)
#define BG0CNT_B    R16(0x04001008)
#define POWCNT1     R16(0x04000304)

/* DMA (ARM9 layout; ARM7 has the same addresses, 3-bit start field is ARM9) */
#define DMA_SAD(n)  R32(0x040000B0 + 12 * (n))
#define DMA_DAD(n)  R32(0x040000B4 + 12 * (n))
#define DMA_CNT(n)  R32(0x040000B8 + 12 * (n))
#define DMA_FILL(n) R32(0x040000E0 + 4 * (n))
#define DMA_ENABLE  (1u << 31)
#define DMA_32BIT   (1u << 26)
#define DMA_REPEAT  (1u << 25)
#define DMA_SRC_FIX (2u << 23)
#define DMA9_START_CARD (5u << 27)
#define DMA7_START_CARD (2u << 28)

/* timers */
#define TM_CNT_L(n) R16(0x04000100 + 4 * (n))
#define TM_CNT_H(n) R16(0x04000102 + 4 * (n))
#define TM_ENABLE   0x80
#define TM_IRQ      0x40
#define TM_CASCADE  0x04

/* keys */
#define KEYINPUT    R16(0x04000130)

/* IPC */
#define IPCSYNC     R16(0x04000180)
#define IPCFIFOCNT  R16(0x04000184)
#define IPCFIFOSEND R32(0x04000188)
#define IPCFIFORECV R32(0x04100000)
#define FIFO_SEND_EMPTY 0x0001
#define FIFO_SEND_FULL  0x0002
#define FIFO_SEND_CLEAR 0x0008
#define FIFO_RECV_EMPTY 0x0100
#define FIFO_RECV_FULL  0x0200
#define FIFO_ERROR      0x4000
#define FIFO_ENABLE     0x8000

/* cartridge */
#define AUXSPICNT   R16(0x040001A0)
#define AUXSPIDATA  R16(0x040001A2)
#define ROMCTRL     R32(0x040001A4)
#define CARDCMD     ((volatile u8 *)0x040001A8)
#define CARDDATA    R32(0x04100010)
#define EXMEMCNT    R16(0x04000204)

/* interrupts */
#define IME         R32(0x04000208)
#define IE          R32(0x04000210)
#define IF          R32(0x04000214)
#define IRQ_VBLANK  (1u << 0)
#define IRQ_TIMER(n) (1u << (3 + (n)))
#define IRQ_IPCSYNC (1u << 16)

/* memory control (ARM9) */
#define VRAMCNT(b)  R8(0x04000240 + ((b) < 7 ? (b) : (b) + 1)) /* A..I = 0..8 */
#define WRAMCNT     R8(0x04000247)
#define VRAMSTAT    R8(0x04000240) /* ARM7 */
#define WRAMSTAT    R8(0x04000241) /* ARM7 */

/* maths (ARM9) */
#define DIVCNT      R16(0x04000280)
#define DIV_NUMER   R64(0x04000290)
#define DIV_DENOM   R64(0x04000298)
#define DIV_RESULT  R64(0x040002A0)
#define DIV_REM     R64(0x040002A8)
#define DIV_NUMER_L R32(0x04000290)
#define DIV_NUMER_H R32(0x04000294)
#define DIV_DENOM_L R32(0x04000298)
#define DIV_DENOM_H R32(0x0400029C)
#define DIV_RES_L   R32(0x040002A0)
#define DIV_RES_H   R32(0x040002A4)
#define DIV_REM_L   R32(0x040002A8)
#define DIV_REM_H   R32(0x040002AC)
#define SQRTCNT     R16(0x040002B0)
#define SQRT_RESULT R32(0x040002B4)
#define SQRT_PARAM_L R32(0x040002B8)
#define SQRT_PARAM_H R32(0x040002BC)

/* Shared main-RAM areas (physical; the ARM9 runs with the MPU off) */
#define RESULT_ADDR  0x023F0000u   /* result block, see results.h */
#define MAILBOX_ADDR 0x023F1000u   /* ARM9 <-> ARM7 command mailbox */

typedef struct {
    volatile u32 ready7;      /* ARM7 sets 1 after its init */
    volatile u32 cmd;         /* ARM9 -> ARM7 command, 0 = none */
    volatile u32 ack;         /* ARM7 copies cmd here when done */
    volatile u32 arg[4];
    volatile u32 val[24];     /* ARM7 results */
    volatile u32 sub;         /* sub-command sequence (WRAM phase) */
    volatile u32 subaddr;
    volatile u32 subval;
    volatile u32 suback;
} mailbox_t;
#define MB ((mailbox_t *)MAILBOX_ADDR)

/* BIOS calls (ARM state: the SWI number lives in bits 16-23) */
static inline s32 swi_div(s32 n, s32 d, s32 *rem, s32 *absq)
{
    register s32 r0 asm("r0") = n;
    register s32 r1 asm("r1") = d;
    register s32 r3 asm("r3");
    asm volatile("svc #0x090000" : "+r"(r0), "+r"(r1), "=r"(r3) : : "r2", "r12", "memory");
    if (rem) *rem = r1;
    if (absq) *absq = r3;
    return r0;
}
static inline u32 swi_sqrt(u32 v)
{
    register u32 r0 asm("r0") = v;
    asm volatile("svc #0x0D0000" : "+r"(r0) : : "r1", "r2", "r3", "r12", "memory");
    return r0;
}
static inline void swi_cpuset(const void *src, void *dst, u32 ctl)
{
    register const void *r0 asm("r0") = src;
    register void *r1 asm("r1") = dst;
    register u32 r2 asm("r2") = ctl;
    asm volatile("svc #0x0B0000" : "+r"(r0), "+r"(r1), "+r"(r2) : : "r3", "r12", "memory");
}
static inline void swi_cpufastset(const void *src, void *dst, u32 ctl)
{
    register const void *r0 asm("r0") = src;
    register void *r1 asm("r1") = dst;
    register u32 r2 asm("r2") = ctl;
    asm volatile("svc #0x0C0000" : "+r"(r0), "+r"(r1), "+r"(r2) : : "r3", "r12", "memory");
}
static inline void swi_lz77_wram(const void *src, void *dst)
{
    register const void *r0 asm("r0") = src;
    register void *r1 asm("r1") = dst;
    asm volatile("svc #0x110000" : "+r"(r0), "+r"(r1) : : "r2", "r3", "r12", "memory");
}
static inline u32 swi_crc16(u32 init, const void *p, u32 len)
{
    register u32 r0 asm("r0") = init;
    register const void *r1 asm("r1") = p;
    register u32 r2 asm("r2") = len;
    asm volatile("svc #0x0E0000" : "+r"(r0), "+r"(r1), "+r"(r2) : : "r3", "r12", "memory");
    return r0 & 0xFFFF;
}
static inline void swi_intrwait(u32 discard, u32 mask)
{
    register u32 r0 asm("r0") = discard;
    register u32 r1 asm("r1") = mask;
    asm volatile("svc #0x040000" : "+r"(r0), "+r"(r1) : : "r2", "r3", "r12", "memory");
}
static inline void swi_vblankintrwait(void)
{
    asm volatile("svc #0x050000" : : : "r0", "r1", "r2", "r3", "r12", "memory");
}

static inline u32 cpsr_read(void)
{
    u32 v;
    asm volatile("mrs %0, cpsr" : "=r"(v));
    return v;
}

/* crt0.s */
void irq_enable_cpu(void);   /* clear CPSR.I */

#endif
