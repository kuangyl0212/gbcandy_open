// Tang Nano 20K: sys_clk=27MHz, fclk=86.4MHz, mclk=21.6MHz, hclk5=126MHz, hclk=25.2MHz
// CPU/PPU now run on mclk (21.6MHz) with cpu_ce gating (mclk/5 = 4.32MHz effective)
// No separate gb_clk — all GB logic is in mclk domain, SDRAM req-ack is mclk↔fclk

// set_multicycle_path: https://docs.xilinx.com/r/en-US/ug903-vivado-using-constraints/set_multicycle_path-Syntax

create_clock -name sys_clk -period 37.037 -waveform {0 18.519} [get_ports {sys_clk}]
create_clock -name fclk -period 11.574 -waveform {0 5.787} [get_nets {fclk}]
create_generated_clock -name mclk -source [get_nets {fclk}] -divide_by 4 [get_nets {mclk}]

create_clock -name hclk5 -period 7.937 -waveform {0 3.968} [get_nets {hclk5}]
create_generated_clock -name hclk -source [get_nets {hclk5}] -master_clock hclk5 -divide_by 5 [get_nets {hclk}]

// see start of sdram_snes.v (sdram_nano.v) for detailed timing of sdram
// CPU to sdram (mclk -> fclk), 3*fclk
set_multicycle_path 3 -setup -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]
set_multicycle_path 2 -hold  -end -from [get_clocks {mclk}] -to [get_clocks {fclk}]

// sdram to CPU (fclk -> mclk)
set_multicycle_path 3 -setup -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]
set_multicycle_path 2 -hold  -start -from [get_clocks {fclk}] -to [get_clocks {mclk}]

// false paths
//set_false_path -from [get_regs {main/SNES/smp/CPUO*}] -to [get_regs {sdram/dq_out*}]
