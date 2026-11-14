/* No IRQ handlers or math users: common crt0 leaves IME=0 and IRQ/FIQ off. */
int main(void)
{
    for (;;)
        __asm__ volatile("nop");
}
