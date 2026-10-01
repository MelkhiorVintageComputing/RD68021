# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68021

# RD68021 timing constraints.
#
# 33.333 ns, 30 MHz. Section 10's clock table has grades at 16.67, 20, 25 and
# 33.33 MHz; this sits between the last two, above the 25 MHz grade's 40 ns, and is
# what the design meets on both parts with margin (doc/implementation.md). The
# constraint is what the tools work to, not only what they check: at the 16.67 MHz
# grade's 60 ns Vivado stopped once it had met it and reported 22 MHz for a design
# that makes 31.
#
# Keep the duty cycle at exactly 50 %. One bus state occupies each half period, so
# the half period is a real timing budget here and not a convention: every critical
# path launches on one edge and captures on the next.

create_clock -period 33.333 -name clk -waveform {0.000 16.667} [get_ports clk]

# rst_n is asynchronous by construction and is not timed.
set_false_path -from [get_ports rst_n]
