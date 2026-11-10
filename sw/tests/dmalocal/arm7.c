int main(void)
{
    /* The shared debug port prioritizes ARM7 register writes in A7_DS
       mode. A branch-only idle loop cannot hide ARM9's R10 writes. */
    __asm__ volatile("1: b 1b");
    __builtin_unreachable();
}
