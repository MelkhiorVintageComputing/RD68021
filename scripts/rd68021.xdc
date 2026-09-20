# RD68021 timing constraints.
#
# 60 ns, 16.67 MHz -- the slowest speed grade the MC68020 manual lists, and therefore
# the number this design has to meet rather than aspire to. Section 10's clock table
# gives 60 ns as the minimum cycle time at that grade.
#
# Keep the duty cycle at exactly 50 %. One bus state occupies each half period, so
# the half period is a real timing budget here and not a convention: every critical
# path launches on one edge and captures on the next.

create_clock -period 60.000 -name clk -waveform {0.000 30.000} [get_ports clk]

# rst_n is asynchronous by construction and is not timed.
set_false_path -from [get_ports rst_n]
