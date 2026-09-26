# Making it smaller, and making it faster

What was measured in M12 and what the measurements led to. Each row is a
before-and-after on the same tree with one change, from `make impl` (Artix-7)
and `make quartus` (Cyclone V).

| change | kept | what it was worth |
|---|:--:|---|
| the microcode store 4096 deep instead of 8192 (`UADDR` 13 → 12 bits) | yes | **25 → 11 RAMB36**. The store is built at its full depth whatever the program uses, and 1,529 words used 8,192. 4,096 leaves room for M13. |
| the store's read register reset-equivalent instead of reset | yes | the store can be block RAM on any part; one named audit exemption (`doc/implementation.md`) |
| `rom_style` on the register declaration, plain `case` | yes | no change on either tool; Vivado honours either placement, Quartus neither |
| `romstyle = "M10K"` for Quartus | no | still no block memory; family-specific |
| the frequency computed per path, both edges | yes | the reported figure became *correct*: 22.46 MHz as first printed was a coincidence of a wrong formula |
| three path exclusions, each held by a build check | report only | 44.02 → 37.25 ns, 22.72 → 26.84 MHz, and the longest path named correctly as the bit-field unit's |
| the clock constrained at 40 ns (25 MHz grade) instead of 60 ns, after the performance phases | yes | Artix-7 21.83 → **25.54 MHz** static, 27.88 → 27.89 MHz reachable, +38 LUTs; Cyclone V 23.73 MHz. Vivado had stopped at what 60 ns asked of it |
| the unreachable routes taken out of the RTL: own-result conditions and a decoding microword's SR from registers, a two-way shifter operand; `check_live_shape` replaces `check_live_cond`, and `make paths` fails if a route comes back | yes | at 40 ns, Artix-7 25.54 → **27.97 MHz** static, +117 LUTs, and a 30 MHz trial now meets timing at 31.34 MHz; Cyclone V 23.73 → **30.55 MHz**, 11,842 → 10,799 ALMs. No clock count changed |

Before M12's first measurement the plan's estimate was 14,000–18,000 LUTs, 25–35
block RAMs and 14–18 MHz. Measured: 6,824 LUTs, 11 block RAMs, 22.72 MHz.
