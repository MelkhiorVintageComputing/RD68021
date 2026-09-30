# Implementation

What the design comes to on real FPGA fabric, measured, and how. "The numbers"
and "Where the area goes" are from one tree -- the one whose microcode store is
indexed by the address bits the program uses, after the AVEC and RTE fixes --
with `ICACHE_ENTRIES = 64` and `COPROCESSOR = 1`; the sections after them say
which tree and which constraint each of theirs came from. The targets:

```sh
make impl      # Vivado 2025.2 place and route, xc7a100tcsg324-1, out of context
make paths     # what limits the clock, from the checkpoint make impl leaves
make quartus   # Quartus Prime Lite fit and timing, Cyclone V 5CSEMA5F31C6
               # (AFAMILY='"MAX 10"' APART=10M50DAF484C6GES for a MAX 10)
make audit     # every register's reset, and the one named exception
```

## The numbers

Constrained at **33.333 ns, 30 MHz** (`scripts/rd68021.xdc`,
`scripts/rd68021.sdc`), between the manual's 25 and 33.33 MHz grades, with the
coprocessor interface built:

| | Artix-7 xc7a100t-1 (Vivado) | Cyclone V 5CSEMA5 (Quartus) | MAX 10 10M50DAF484C6GES (Quartus) |
|---|--:|--:|--:|
| logic | **7,995 Slice LUTs (12.6 %)** | **7,890 ALMs (25 %)** | **18,974 LEs (38 %)** |
| registers | 1,874 | 5,869 | 5,525 |
| block memory | **6 RAMB36** (the microcode store) | **21 M10K**, 210,944 bits (the store) | **26 M9K**, 210,944 bits (the store) |
| distributed RAM | 76 LUTs (the instruction cache) | -- | -- |
| DSP | 4 (the multiplier) | 3 | 8 9-bit multipliers |
| **frequency, static** | **33.40 MHz** (29.94 ns) | **39.86 MHz** | **32.51 MHz** (slow 1200 mV 85 °C) |

**All three meet 30 MHz on static timing, and the Artix-7 and the Cyclone V the
MC68020's top speed grade, 33.33 MHz**, and there is no other kind of timing to
quote: the routes the microcode cannot take are no longer in the netlist
(`doc/critical-path.md`). The Quartus figures are the fitter's own slow-corner
Fmax; the instruction cache stays in logic on both Intel parts, because its read
is asynchronous. Until the constraint was
tightened from 60 ns (16.67 MHz) to 40 ns, the Artix-7 reported 21.83 MHz:
Vivado stops optimising once a constraint is met, so the 60 ns figure measured
the constraint as much as the design.

**Asked for more**, the Artix-7 gives more: a 30 ns trial of this tree makes
35.94 MHz, and a 25 ns trial of the tree before the AVEC, RTE and store changes
made 41.57 MHz. What limits it there, and what comes next, is in
`doc/critical-path.md`. The manual has no grade above 33.33 MHz, and the bus
unit's own timing is the other half of a speed grade: `make timing`
(`doc/ac-timing.md`) finds all four of the manual's grades feasible.

The plan estimated 14,000–18,000 Slice LUTs and 25–35 block RAMs at 14–18 MHz.
The design came in at under half the logic and a third of the memory, and faster:
most of the saving is the bus unit owning dynamic sizing (no second-word-of-a-long
microcode at all) and a microcode store of 1,529 words where the plan feared
15,000.

A three-clock bus cycle at 33.40 MHz is 11.1 M bus cycles a second, against a
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

| | LUTs | FFs | block RAM | DSP |
|---|--:|--:|--:|--:|
| sequencer, datapath, register file and coprocessor interface | 4,399 | 1,065 | | 4 |
| — shifter | 910 | | | |
| — bit-field unit | 731 | | | |
| — divider | 431 | 139 | | |
| — opcode decoder | 314 | | | |
| — microcode store | | | 6 RAMB36 | |
| bus unit | 600 | 390 | | |
| fetch unit and instruction cache | 612 (76 as RAM) | 280 | | |
| **total** | **7,995** | **1,874** | **6** | **4** |

The shifter and the bit-field unit together are a fifth of the design. They buy
some of the fastest rows in `doc/timing-divergences.md` -- every shift in one
clock, BFFFO in four -- and they used to be the start of the longest paths, until
their results were given routes of their own (`doc/critical-path.md`).

### The microcode store in Quartus: a case dense enough to be a ROM

Quartus infers no ROM from a `case` whose index has fewer than half its values
labelled, whatever attribute it carries. The generated store used to be indexed
by the whole twelve-bit micro-address, 1,906 words of 4,096, and Quartus built it
from logic: 11,690 ALMs on the Cyclone V, 25,592 LEs on a MAX 10, and no message
saying why. So `tools/ucode/assemble.py` indexes it by the bits the program
needs -- eleven today -- and the bits above, which no reachable micro-address
sets, select the illegal entry through a flag registered with the read: the same
function as the full case. Quartus then builds it from block memory with no
attribute at all, choosing the block for the family; Vivado reads it the same way
and needs 6 RAMB36 instead of 11 and a RAMB18. Found downstream, on a Sun-3/60
replica on a MAX 10, where the store as logic failed timing.

A MAX 10 has one more condition: it initialises block memory only in the
configuration mode that carries memory contents,
`INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"` ("Single Uncompressed Image
with Memory Initialization"). In any other mode Quartus says "MIF is not
supported for the selected family" and falls back to logic. `scripts/quartus.tcl`
sets it for that family.

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

The SunOS figure is good to about 0.1 %: the guest's clock starts at the host's
date, and two runs of the same RTL finished 0.13 % apart (`doc/sun3.md`). Every
phase's gain is well clear of that.

All four phases were implemented at the old 60 ns constraint; the MHz column is
comparable across them but not with the figures above. BRAM counts Vivado's block
RAM cells, RAMB36 and RAMB18 alike.

| | Slice LUTs | FF | BRAM cells | MHz | `make cycles` | SunOS clocks |
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
condition multiplexer into the micro-ROM's address. With the unreachable routes
excluded -- which `make paths` did then; they are gone from the RTL now -- Phase 3
is 27.46 MHz, limited by a data register through the ALU and the pipe-advance
commit into the fetch point -- the push into a full queue on the same edge as
the pop, which Phase 3 added -- and Phase 4 is 27.88 MHz, limited by the
micro-ROM's output into the status register.

**Phase 4's half clock.** The early retire starts at a falling-edge register in
the bus unit and has half a period to reach every commit enable and the
micro-ROM's address. Routed, it is 16 levels with 13.75 ns of slack against the
30 ns half period: it would bind only above about 30.8 MHz, well clear of the
full-clock paths. The microword grew a bit to 103, and Vivado mapped the store to
one more block RAM cell than in Phases 1 to 3.

## The reset audit

`make audit` proves that every register takes its value from a reset branch, in
the source and in a yosys netlist, at the configured cache size. **2,950
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
