# Implementation

What the design comes to on real FPGA fabric, measured, and how. Every number
here is from one tree -- the M12 commit -- with `ICACHE_ENTRIES = 64` and
`COPROCESSOR = 0`, and from these targets:

```sh
make impl      # Vivado 2025.2 place and route, xc7a100tcsg324-1, out of context
make paths     # what limits the clock, from the checkpoint make impl leaves
make quartus   # Quartus Prime Lite fit and timing, Cyclone V 5CSEMA5F31C6
make audit     # every register's reset, and the one named exception
```

## The numbers

| | Artix-7 xc7a100t-1 (Vivado) | Cyclone V 5CSEMA5 (Quartus) |
|---|--:|--:|
| logic | **6,824 Slice LUTs (10.8 %)** | **9,108 ALMs (28 %)** |
| registers | 1,862 | 2,403 |
| block memory | **11 RAMB36** (the microcode store) | 2 blocks (the instruction cache) -- see below |
| distributed RAM | 76 LUTs (the instruction cache) | -- |
| DSP | 4 (the multiplier) | 3 |
| **frequency, static** | **22.72 MHz** (44.02 ns) | **21.08 MHz** |
| frequency, reachable paths | 26.84 MHz (37.25 ns) | -- |

**Both parts clear the MC68020's 16.67 and 20 MHz speed grades on static timing
alone**, with no assumption about which paths the microcode takes. The 25 and
33.33 MHz grades are not reached.

The plan estimated 14,000–18,000 Slice LUTs and 25–35 block RAMs at 14–18 MHz.
The design came in at under half the logic and a third of the memory, and faster:
most of the saving is the bus unit owning dynamic sizing (no second-word-of-a-long
microcode at all) and a microcode store of 1,529 words where the plan feared
15,000.

A three-clock bus cycle at 22.72 MHz is 7.6 M bus cycles a second, against a
real 16.67 MHz MC68020's 5.6 M.

### Reading a frequency off a slack

The bus unit works on both clock edges, so about half the paths have half a
period to settle in and half have a whole one. Dividing the worst slack into the
period -- what a single-edge design would do, and what this project's own
`impl.tcl` did until M12 -- reads a half-period path as if it had a whole period.
`scripts/fmax.tcl` scales every path by its own requirement instead: a path
needing *d* ns of an *r* ns requirement needs a period of *d* × 60 / *r*. The
figure above is the worst of those. Quartus's Fmax already scales both edges
together, so its number is quoted directly.

### Where the area goes (Artix-7, Slice LUTs)

| | LUTs | FFs | RAMB36 | DSP |
|---|--:|--:|--:|--:|
| sequencer, datapath and register file | 3,436 | 1,055 | | 4 |
| — shifter | 903 | | | |
| — bit-field unit | 742 | | | |
| — divider | 432 | 139 | | |
| — opcode decoder | 237 | | | |
| — microcode store | | | 11 | |
| bus unit | 598 | 388 | | |
| fetch unit and instruction cache | 477 (76 as RAM) | 280 | | |
| **total** | **6,824** | **1,862** | **11** | **4** |

The shifter and the bit-field unit together are a quarter of the design. They
buy the fastest rows in `doc/timing-divergences.md` -- every shift in two clocks,
BFFFO in four -- and they are also the start of the longest path
(`doc/critical-path.md`).

### Quartus does not put the microcode store in block memory

On the Cyclone V the 4096 × 100-bit store is built from logic, which is most of
the difference between the two columns. Quartus Prime Lite infers no ROM from
the generated `case` -- measured on the store alone, with the reset multiplexer
on its address and without it, with `rom_style`, with `romstyle = "M10K"` and
with the attribute on the always block and on the register declaration: zero
block-memory bits every time, and no message saying why. Vivado infers it
from the same source.

It fits in 28 % of the part and makes 21 MHz as it is, so it is recorded here
rather than fixed. The known way round it -- an array initialised from a file --
needs an `initial` block, which `rtl/` does not allow.

## The reset audit

`make audit` proves that every register takes its value from a reset branch, in
the source and in a yosys netlist, at the configured cache size. **2,828
flip-flops, every one reset, and 100 exempted** -- one register, named in
`tools/reset_audit.py`:

**The microcode store's read register.** A block RAM's output register cannot
carry a reset value on every part -- Quartus given one builds the store from
logic, Vivado absorbs it -- and an ASIC ROM macro has none. It is
reset-*equivalent* instead: while reset is asserted its address is forced to the
reset entry point, so it holds the reset word from the first clock edge inside
reset, and the clock runs during reset by requirement: UM 5.8 has RESET asserted
for at least 520 clock periods.

Memories are not registers, and yosys leaves them as memories: the instruction
cache's array is the one, and 64 valid bits that are ordinary reset flip-flops
gate every read of it, so what it powered up holding cannot be observed.

## Six tools, one subset

`make lint` runs iverilog, Verilator and yosys, plus `tools/src_lint.py` for the
two rules those three do not enforce and the other three do: declaration before
use, and no package-scoped name in a port connection. `make lint-quartus` and
`make lint-questa` are the other two front-ends and `make impl` the third. All
six accept the design.
