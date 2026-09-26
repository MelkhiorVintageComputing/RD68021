# RD68021 timing constraints.
#
# 40 ns, 25 MHz -- the MC68020's 25 MHz speed grade, whose minimum cycle time in
# Section 10's clock table is 40 ns. The constraint is what the tools work to, not
# only what they check: at the 16.67 MHz grade's 60 ns, Vivado stopped once it had
# met it and the same design reported 22 MHz. doc/implementation.md.
#
# Keep the duty cycle at exactly 50 %. One bus state occupies each half period, so
# the half period is a real timing budget here and not a convention: every critical
# path launches on one edge and captures on the next.

create_clock -period 40.000 -name clk -waveform {0.000 20.000} [get_ports clk]

# rst_n is asynchronous by construction and is not timed.
set_false_path -from [get_ports rst_n]
