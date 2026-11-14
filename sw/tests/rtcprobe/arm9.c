#include "../common/con.h"
#include "../common/ipc.h"
#include "probe.h"
int main(void) {
    con_init(); IPCSYNC=9<<8;
    con_puts(TOP,0,0,PAL_YELLOW,"RTC RAW OBSERVATION PROBE");
    con_puts(TOP,0,2,PAL_WHITE,"B: IO WIDTHS ONLY");
    con_puts(TOP,0,3,PAL_WHITE,"A: ALSO CLOCK WRITE TESTS");
    con_puts(TOP,0,5,PAL_YELLOW,"A READS CLEAR STATUS FLAGS");
    con_puts(TOP,0,6,PAL_WHITE,"A RESTORES TIME/WRITABLE MODE");
    con_puts(TOP,0,7,PAL_WHITE,"NO RESET OR ALARM WRITES");
    if(!a7_wait_ready()) { con_puts(TOP,0,9,PAL_RED,"ARM7 TIMEOUT"); for(;;); }
    while((KEYINPUT & 3)!=3) ; /* Require a fresh press. */
    while((KEYINPUT & 3)==3) ;
    MB->cmd=(KEYINPUT & 2) ? 2 : 1;
    con_puts(TOP,0,9,PAL_YELLOW,"RUNNING: KEEP POWER ON");
    while(MB->ack!=MB->cmd) ; /* ARM7 owns restoration even if display stalls. */
    volatile rtc_log *l=(volatile rtc_log *)RTC_LOG_ADDR;
    con_clear(TOP); con_clear(BOTTOM);
    con_puts(TOP,0,0,PAL_YELLOW,"RTC RAW: NO POLICY VERDICT");
    con_printf(TOP,0,1,PAL_WHITE,"MODE %u OUTCOME %u ROWS %u",l->mode,l->outcome,l->count);
    con_printf(TOP,0,2,PAL_WHITE,"S1 %02X/%02X S2 %02X/%02X",l->saved_s1,l->final_s1,l->saved_s2,l->final_s2);
    con_printf(TOP,0,3,PAL_WHITE,"ELAPSED %08X +%u SEC",l->elapsed_ticks,l->added_seconds);
    for(u32 i=0;i<l->count;i++) {
        volatile rtc_observation *r=&l->rows[i];
        int screen=i<8?TOP:BOTTOM, row=5+2*(i%8);
        con_printf(screen,0,row,PAL_WHITE,"%02X %08X %08X",r->kind,r->a,r->b);
        con_printf(screen,0,row+1,PAL_WHITE,"   %08X %08X",r->c,r->d);
    }
    con_printf(BOTTOM,0,0,PAL_WHITE,"EDGE %u RESTORE %u TICKS",l->edge_bracket_ticks,l->restore_ticks);
    con_printf(BOTTOM,0,16,PAL_WHITE,"OLD %02X %02X %02X %02X %02X %02X %02X",l->saved[0],l->saved[1],l->saved[2],l->saved[3],l->saved[4],l->saved[5],l->saved[6]);
    con_printf(BOTTOM,0,17,PAL_WHITE,"SET %02X %02X %02X %02X %02X %02X %02X",l->expected[0],l->expected[1],l->expected[2],l->expected[3],l->expected[4],l->expected[5],l->expected[6]);
    con_printf(BOTTOM,0,18,PAL_WHITE,"GOT %02X %02X %02X %02X %02X %02X %02X",l->restored[0],l->restored[1],l->restored[2],l->restored[3],l->restored[4],l->restored[5],l->restored[6]);
    con_puts(BOTTOM,0,20,PAL_WHITE,"1 DONE 2 CS 3 IRQ 4 BAD DATE");
    con_puts(BOTTOM,0,21,PAL_WHITE,"5 NO RTC EDGE 6 RESTORE DIFF");
    con_puts(BOTTOM,0,22,PAL_YELLOW,"RAM LOG 023F2000 / PHOTO BOTH");
    for(;;) __asm__ volatile("nop");
}
