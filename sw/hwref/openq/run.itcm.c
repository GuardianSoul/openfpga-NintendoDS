// openq's prefetch-abort handler, in ITCM (reachable whatever the test does
// to main RAM's code permission). No stack: abort mode's SP is scratch here,
// saved and set back by main.c around the test.
#include "../common/hwref.h"

extern volatile u32 oq_abt_lr, oq_abt_n, oq_hcp;

__attribute__((naked, target("arm"))) void oq_pabt(void)
{
	__asm__ volatile(
		"ldr sp, =oq_abt_lr\n"
		"str lr, [sp]\n"          // the aborted instruction + 4
		"ldr sp, =oq_abt_n\n"
		"ldr lr, [sp]\n"
		"add lr, lr, #1\n"
		"str lr, [sp]\n"
		"cmp lr, #3\n"                  // a third abort in one trial: the
		"mrcge p15, 0, sp, c1, c0, 0\n" // permissions didn't take, so turn
		"bicge sp, sp, #1\n"            // the protection unit off (no loop)
		"mcrge p15, 0, sp, c1, c0, 0\n"
		"ldr sp, =oq_hcp\n"
		"ldr sp, [sp]\n"
		"mcr p15, 0, sp, c5, c0, 3\n"   // code permissions back: the retry fetches
		"ldr sp, =oq_abt_lr\n"
		"ldr lr, [sp]\n"
		"subs pc, lr, #4\n"
		".pool\n");
}
