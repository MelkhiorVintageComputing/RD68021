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
Constrained at **40 ns, the 25 MHz grade** (`scripts/rd68021.xdc`,
`scripts/rd68021.sdc`), with the coprocessor interface built:

| | Artix-7 xc7a100t-1 (Vivado) | Cyclone V 5CSEMA5 (Quartus) |
|---|--:|--:|
| logic | **7,688 Slice LUTs (12.1 %)** | **11,842 ALMs (37 %)** |
| registers | 1,872 | 6,114 |
| block memory | **12 RAMB36** (the microcode store) | none -- see below |
| distributed RAM | 76 LUTs (the instruction cache) | -- |
| DSP | 4 (the multiplier) | 3 |
| **frequency, static** | **25.54 MHz** (39.16 ns) | **23.73 MHz** |
| frequency, reachable paths | 27.89 MHz (35.86 ns) | -- |

**The Artix-7 clears the MC68020's 25 MHz speed grade on static timing alone**,
with no assumption about which paths the microcode takes; the Cyclone V clears
16.67 and 20 MHz. Until the constraint was tightened from 60 ns (16.67 MHz) to
40 ns, the same Artix-7 build reported 21.83 MHz: Vivado stops optimising once a
constraint is met, so the 60 ns figure measured the constraint as much as the
design.

**At 30 MHz** (a 33.33 ns trial, not checked in) the Artix-7 fails by 0.242 ns
on 11 endpoints, 29.78 MHz, all of them the micro-ROM's address pins, and all on
the route from the bit-field unit into the next micro-address that
`tools/ucode/assemble.py`'s `check_live_cond` proves no microword takes. With
that route and the other two `make paths` excludes left out, the build makes
**31.37 MHz**: every route the microcode can take meets 30 MHz. The next walls
are the micro-ROM's output through the ALU and a microword's own-result
condition back to its address (31.4 MHz), and Phase 4's early retire, a
half-clock path with 2.8 ns of slack left at 30 MHz. The 33.33 MHz grade would
need the microcode store's output register duplicated or the own-result
conditions registered.

The plan estimated 14,000–18,000 Slice LUTs and 25–35 block RAMs at 14–18 MHz.
The design came in at under half the logic and a third of the memory, and faster:
most of the saving is the bus unit owning dynamic sizing (no second-word-of-a-long
microcode at all) and a microcode store of 1,529 words where the plan feared
15,000.

A three-clock bus cycle at 25.54 MHz is 8.5 M bus cycles a second, against a
real 16.67 MHz MC68020's 5.6 M.

### Reading a frequency off a slack

The bus unit works on both clock edges, so about half the paths have half a
period to settle in and half have a whole one. Dividing the worst slack into the
period -- what a single-edge design would do, and what this project's own
`impl.tcl` did until M12 -- reads a half-period path as if it had a whole period.
`scripts/fmax.tcl` scales every path by its own requirement instead: a path
needing *d* ns of an *r* ns requirement needs a period of *d* × *T* / *r*, *T*
being the constrained period. The
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

On the Cyclone V the 103-bit-wide store is built from logic, which is most of
the difference between the two columns. Quartus Prime Lite infers no ROM from
the generated `case` -- measured on the store alone, with the reset multiplexer
on its address and without it, with `rom_style`, with `romstyle = "M10K"` and
with the attribute on the always block and on the register declaration: zero
block-memory bits every time, and no message saying why. Vivado infers it
from the same source.

It fits in 37 % of the part and makes 23.7 MHz as it is, so it is recorded here
rather than fixed. The known way round it -- an array initialised from a file --
needs an `initial` block, which `rtl/` does not allow.

## The coprocessor interface (M13)

`make impl` on the M13 tree, both settings of `COPROCESSOR`, Artix-7 xc7a100t-1:

| | M12 | M13, `COPROCESSOR = 1` | M13, `COPROCESSOR = 0` |
|---|--:|--:|--:|
| Slice LUTs | 6,824 | **7,317** (+493, +7.2 %) | 7,321 |
| registers | 1,862 | 1,881 | 1,881 |
| block memory | 11 RAMB36 | 11 RAMB36 + 1 RAMB18 | 11 RAMB36 + 1 RAMB18 |
| DSP | 4 | 4 | 4 |
| **frequency, static** | 22.72 MHz | **22.28 MHz** (44.88 ns) | 22.36 MHz (44.73 ns) |

Where the 493 LUTs went:

| | M12 | M13 | |
|---|--:|--:|--:|
| sequencer, excluding its units | 3,436 | 3,849 | +413 |
| opcode decoder | 237 | 288 | +51 |
| fetch unit and instruction cache | 477 | 511 | +34 |
| bus unit | 598 | 595 | −3 |

The sequencer's share is the primitive decoder, the new conditions -- the
effective-address classes of UM table 7-4, the format words, the byte counter --
the new sources and destinations, and the register the primitive is held in. The
microword grew from 100 to 102 bits (`cond` and `bsrc` a bit each), which is the
extra RAMB18, and the store from 1,529 to 2,043 words, which is free: it was built at
4,096 already.

**`COPROCESSOR = 0` does not take the interface out.** The parameter only decides
what the opcode decoder hands the sequencer for an F-line word; the primitive
decoder, the conditions and the microcode are still there and still reachable from
the rest of the program, so nothing prunes them. The two settings are within four
LUTs and a tenth of a megahertz of each other. A build that needed the area back
would have to put the sequencer's coprocessor datapath behind the parameter as
well; at 7 % of the design and 2 % of the clock it has not been worth it.

**The clock** is 2 % slower, and still clears the 16.67 and 20 MHz speed grades on
static timing alone. The limiting path is the same family as M12's -- a register
through the condition multiplexer into the microcode store's address, 45 levels --
now starting at `xw_q`, which the transfer-main-processor-control-register
primitive's and MOVEC's control-register tests read.

## Catching up with the MC68020

Four phases of performance work, described in `doc/timing-divergences.md`
("Catching up"), each measured on the Artix-7 with `COPROCESSOR = 1`, and on the
same whole-machine benchmark: `make sunos-fpu`, SunOS 4.1.1 booted to a shell
and running an MC68881 program, in clocks to its final report.

All four phases were implemented at the old 60 ns constraint; the MHz column is
comparable across them but not with the 40 ns figures above.

| | Slice LUTs | FF | BRAM | MHz | `make cycles` | SunOS clocks |
|---|--:|--:|--:|--:|--:|--:|
| M13 | 7,317 | | 11 | 22.28 | 1499 | 2,278,439,102 |
| 1: stall, read merge, MOVEM, call/return | 7,451 | 1,870 | 11 | 22.11 | 1316 | 2,037,305,996 |
| 2: fast effective addresses | 7,517 | 1,870 | 11 | 22.48 | 1286 | 1,949,810,333 |
| 3: instruction refill | 7,612 | 1,870 | 11 | 21.94 | 1225 | 1,915,111,867 |
| 4: early retire | 7,650 | 1,872 | 12 | 21.83 | 1182 | 1,872,251,784 |

The manual's cache case for the `make cycles` mix is 1332. Over the four phases
the mix went from 12.5 % slower than the part to 11 % faster, and SunOS from
boot to its result takes 18 % fewer clocks. The clock moved by less than
place-and-route's own run-to-run noise, and the limiting path is the same
family throughout: a data register, or `xw_q` in Phase 2, through the
condition multiplexer into the micro-ROM's address. With the unreachable routes excluded (`make paths`) Phase 3
is 27.46 MHz, limited by a data register through the ALU and the pipe-advance
commit into the fetch point -- the push into a full queue on the same edge as
the pop, which Phase 3 added -- and Phase 4 is 27.88 MHz, limited by the
micro-ROM's output into the status register.

**Phase 4's half clock.** The early retire starts at a falling-edge register in
the bus unit and has half a period to reach every commit enable and the
micro-ROM's address. Routed, it is 16 levels with 13.75 ns of slack against the
30 ns half period: it would bind only above about 30.8 MHz, well clear of the
full-clock paths. The microword grew a bit to 103, which costs the ROM a twelfth
block RAM.

## The reset audit

`make audit` proves that every register takes its value from a reset branch, in
the source and in a yosys netlist, at the configured cache size. **2,948
flip-flops, every one reset, and 103 exempted** -- one register, named in
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
