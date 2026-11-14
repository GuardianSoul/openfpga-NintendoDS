# Standalone timing contract only. Board integration must bind these clocks to
# the existing SYS/clk_2x PLL outputs and retain their exact reported periods.
# No false paths or blanket multicycle exceptions are permitted by this file.
create_clock -name shared_sys -period 14.917 [get_ports {clk_sys}]
create_generated_clock -name shared_engine_2x -source [get_ports {clk_sys}] -multiply_by 2 [get_ports {clk2}]
# SYS->clk2 response/IRQ/wait and clk2->SYS request/ownership paths are related
# crossings. The next 2x capture can be only 7.4585ns away. The original
# clk_cpu (~89MHz) is not the shared execution clock.
