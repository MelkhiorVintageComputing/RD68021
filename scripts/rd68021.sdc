# Quartus timing constraints. Mirrors scripts/rd68021.xdc.
#
# derive_clock_uncertainty is added explicitly because Quartus adds none by default
# where Vivado does; without it the two tools are not reporting the same thing.

create_clock -period 40.000 -name clk -waveform {0.000 20.000} [get_ports clk]
derive_clock_uncertainty

set_false_path -from [get_ports rst_n]
