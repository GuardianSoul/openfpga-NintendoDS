@ CP15 setup shared by the cached test builds (ARM9 only). Memory map, in
@ the style of NitroSDK's crt0 (the higher region number wins):
@   r0 0x00000000 4 GB   background, uncached, read/write
@   r1 0x02000000 4 MB   main RAM: I and D cached, write-back
@   r2 0x02400000 4 MB   main RAM mirror, uncached (the testbench aliases it)
@   r3 0x02020000 4 KB   D cached, write-through
@   r4 0x02030000 4 KB   privileged read/write, no user access
@   r5 0x02031000 4 KB   read-only for everyone
@   r6 0x02032000 4 KB   no access (also no execute)
@   r7 0x08000000 32 MB  GBA ROM area: I and D cached, write-back
@ ITCM 32 KB at 0, DTCM 16 KB at 0x0B000000.
.equ CP15_CTRL_ON, 0x00051005 | 0x78        @ MPU, D-cache, I-cache, DTCM, ITCM

.macro CP15_REGIONS
    ldr     r0, =0x0000003F                 @ r0: 0, 4 GB, on
    mcr     p15, 0, r0, c6, c0, 0
    ldr     r0, =0x0200002B                 @ r1: 4 MB
    mcr     p15, 0, r0, c6, c1, 0
    ldr     r0, =0x0240002B                 @ r2: 4 MB
    mcr     p15, 0, r0, c6, c2, 0
    ldr     r0, =0x02020017                 @ r3: 4 KB
    mcr     p15, 0, r0, c6, c3, 0
    ldr     r0, =0x02030017                 @ r4
    mcr     p15, 0, r0, c6, c4, 0
    ldr     r0, =0x02031017                 @ r5
    mcr     p15, 0, r0, c6, c5, 0
    ldr     r0, =0x02032017                 @ r6
    mcr     p15, 0, r0, c6, c6, 0
    ldr     r0, =0x08000031                 @ r7: 32 MB
    mcr     p15, 0, r0, c6, c7, 0
    mov     r0, #0x8A                       @ D cacheable: r1, r3, r7
    mcr     p15, 0, r0, c2, c0, 0
    mov     r0, #0x82                       @ I cacheable: r1, r7
    mcr     p15, 0, r0, c2, c0, 1
    mov     r0, #0x82                       @ bufferable (write-back): r1, r7
    mcr     p15, 0, r0, c3, c0, 0
    ldr     r0, =0x30613333                 @ D access: r7..r0 = 3,0,6,1,3,3,3,3
    mcr     p15, 0, r0, c5, c0, 2
    mcr     p15, 0, r0, c5, c0, 3           @ same for instructions
    ldr     r0, =0x0B00000A                 @ DTCM at 0x0B000000, 16 KB
    mcr     p15, 0, r0, c9, c1, 0
    mov     r0, #0x0C                       @ ITCM 32 KB
    mcr     p15, 0, r0, c9, c1, 1
.endm

.macro CP15_ENABLE
    mov     r0, #0
    mcr     p15, 0, r0, c7, c5, 0           @ invalidate I-cache
    mcr     p15, 0, r0, c7, c6, 0           @ invalidate D-cache
    ldr     r0, =CP15_CTRL_ON
    mcr     p15, 0, r0, c1, c0, 0
.endm
