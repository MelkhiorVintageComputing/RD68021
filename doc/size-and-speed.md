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

Before M12's first measurement the plan's estimate was 14,000–18,000 LUTs, 25–35
block RAMs and 14–18 MHz. Measured: 6,824 LUTs, 11 block RAMs, 22.72 MHz.
