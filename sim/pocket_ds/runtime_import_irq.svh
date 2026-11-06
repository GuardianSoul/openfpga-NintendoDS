// Define RUNTIME_IRQ9/7 to actual sys_irq blocks; caller holds all clocks.
// Deposit after trampoline IF clears and after old accepted writes drain.
task automatic import_irq_pair(input logic[31:0] image[0:5]);
 `RUNTIME_IRQ9.ime=image[0][0];`RUNTIME_IRQ7.ime=image[1][0];
 `RUNTIME_IRQ9.ie=image[2];`RUNTIME_IRQ7.ie=image[3];
 `RUNTIME_IRQ9.iflag=image[4];`RUNTIME_IRQ7.iflag=image[5];
endtask
