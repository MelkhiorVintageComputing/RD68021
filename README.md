# RD68021

A from-scratch SystemVerilog implementation of the Motorola **MC68020**, for FPGA
and ASIC.

It runs the whole MC68020 integer instruction set, with the instruction cache,
CALLM/RTM and the coprocessor interface. It boots a Sun-3 PROM and SunOS 4.1.1,
and runs the same programs, with identical output, as the 68020 in the TME
emulator: a single-user shell, an installed system from disk in multi-user mode,
and floating-point programs using an MC68881 on the coprocessor interface.

## Goals

1. **Software compatibility.** Everything a real MC68020 runs, this runs. Where
   the reference emulators disagree with the core, the Motorola manuals in
   `Inputs/doc/` decide.
2. **Bus compatibility.** The pins follow the MC68020's bus states S0–S5,
   including dynamic bus sizing and misaligned operands, so the core can sit on a
   real 68020 board's bus. `make timing` checks the AC specifications at all four
   of the manual's speed grades.
3. **Cycle counts are allowed to differ, but never silently.** Every divergence
   from the manual's instruction timings is measured and explained in
   `doc/timing-divergences.md`.

## What it is

| | |
|---|---|
| Instruction set | the full MC68020 integer ISA, 116 instructions, all 18 addressing modes |
| Also | the on-chip instruction cache, CALLM/RTM with access-level control, and the coprocessor interface (built when `COPROCESSOR=1`) |
| Not included | the MC68EC020 variant |
| Faults | bus errors, address errors and demand paging with full restart: misaligned and part-done operands, RTE reruns, the long fault frame |
| Pins | the original's bidirectional and three-state pins split into `_i` / `_o` / `_oe` (`doc/pinout.md`) |
| Microcode | assembled from Python (`tools/ucode/`) into a ROM of about 1,900 words, with build-time checks of the restart and timing rules the RTL relies on |
| Speed | 1,117 clocks over a mix of one of each instruction, against 1,332 for the manual's cache case; writes are posted, as the MC68020's are (UM 8.1.3) |

On FPGAs, with the coprocessor interface built and a 30 MHz constraint
(`doc/implementation.md`):

| | Logic | Block memory | Frequency |
|---|--:|--:|--:|
| Xilinx Artix-7 xc7a100t | 8,046 LUTs | 6 RAMB36 | 34.0 MHz |
| Intel Cyclone V 5CSEMA5 | 7,890 ALMs | 21 M10K | 39.9 MHz |
| Intel MAX 10 10M50 | 18,974 LEs | 26 M9K | 32.5 MHz |

## Rules the RTL follows

These are hard rules; breaking one is a bug. `CLAUDE.md` has the full text.

- **Nothing under `Inputs/` is modified.** It holds the manuals and the reference
  implementations, as git submodules.
- **The reference implementations are oracles, never sources.** Musashi, the
  Suska core, QEMU and TME are run and compared against. No RTL is written from
  them.
- **No initialisation outside reset.** No `initial` blocks or declaration-site
  register initialisers; every register is set in its reset branch. `make audit`
  proves it, in the source and in the synthesised netlist.
- **Portable SystemVerilog.** The RTL elaborates under iverilog, Verilator,
  yosys, Vivado, Quartus and Questa (`doc/coding-standard.md`).

## Getting started

```sh
git clone --recursive <this repository>
cd RD68021
make check
```

`make check` is the gate. It regenerates and compares the microcode, lints under
iverilog, Verilator and yosys, runs the reset audit and every directed
testbench, and checks the AC timing.

### Tools

| Needed for | Tool |
|---|---|
| everything | Python 3, iverilog, Verilator, yosys |
| test programs | `m68k-linux-gnu-gcc`, `-as`, `-objcopy` |
| `make suska` | ghdl |
| `make impl`, `make paths`, `make synth` | Vivado |
| `make quartus`, `make lint-quartus`, `make lint-questa` | Quartus Prime Lite, with Questa for the last |

The Sun-3 targets build TME from `Inputs/ref/Run-Sun3-SunOS-4.1.1` into
`build/`. `make sunos-disk` and `make sunos-fpu` need an installed SunOS 4.1.1
disk image (`SUNOS_IMG=`).

## Verification

Each of these takes minutes, so none is in `make check`.

| Target | What it checks |
|---|---|
| `make sim COPROCESSOR=1` | every core testbench, with the coprocessor interface built |
| `make ea` | every addressing mode and extension-word shape, against Musashi |
| `make vectors-all` | about 11,000 generated instruction tests, against Musashi |
| `make cosim` | real compiled programs, every register at every instruction |
| `make cache` | the same results with no instruction cache |
| `make cycles` | instruction clock counts against the manual, each a regression check |
| `make suska` | the bus cycles against a second core, the Suska WF68K30L under ghdl |
| `make sun3` | a Sun-3/160 boot PROM, inside TME, to the monitor prompt |
| `make sunos` | SunOS 4.1.1 to a single-user shell |
| `make sunos-disk` | an installed SunOS 4.1.1, multi-user |
| `make sunos-fpu` | the same, compiling and running a program that uses an MC68881 |

The directed testbenches include `core_fault_tb`, `core_paging_tb` (every
operand shape faulted across a page) and `core_cow_tb`. `core_cow_tb` runs a
small kernel and user process through copy-on-write faults, with handlers that
do real work and RTE back to user mode.

Implementation runs: `make impl` (Vivado place and route), `make paths` (what
limits the clock), `make quartus` (Cyclone V, or a MAX 10 with
`AFAMILY='"MAX 10"' APART=10M50DAF484C6GES`).

## Layout

| Path | What |
|---|---|
| `rtl/` | the processor, one module per file, prefix `rd68021_` |
| `rtl/gen/` | generated from `tools/ucode/`: microcode store, decoders, frame package |
| `tools/` | microcode assembler, test-vector generator, test runners, AC timing solver, doc generators |
| `sim/tb/` | testbenches |
| `sim/models/` | bus-slave models and a scripted coprocessor |
| `sim/programs/` | real programs, built with the cross-compiler and run on the core |
| `sim/suska/`, `sim/tme/` | harnesses for the Suska core and for TME |
| `scripts/` | Vivado and Quartus scripts and constraints |
| `doc/` | the design and verification reports |
| `Inputs/` | the Motorola manuals and the reference implementations (submodules, read-only) |

## Documentation

| | |
|---|---|
| `doc/pinout.md` | the pins, and how the split I/O maps onto the original |
| `doc/checkpoint.md` | fault frames and how an instruction is restarted |
| `doc/ssw.md` | the special status word, bit by bit |
| `doc/coprocessor.md` | the coprocessor interface |
| `doc/divergences.md` | where the core's behaviour differs from the manual or a reference, and why |
| `doc/timing-divergences.md` | instruction clock counts against the manual |
| `doc/bus-timing-compliance.md`, `doc/ac-timing.md` | the bus protocol and AC timing |
| `doc/implementation.md`, `doc/critical-path.md` | FPGA results, and what limits the clock |
| `doc/size-and-speed.md` | every change measured for area and clock, kept or not |
| `doc/coding-standard.md` | the SystemVerilog subset all six tools accept, and each tool's quirks |
| `doc/manual-contradictions.md` | places where the manuals disagree with themselves |
| `doc/bugs-found.md` | every bug found, how, and how it was fixed |
| `doc/sun3.md` | running the core inside TME as a Sun-3 |
| `doc/suska-crosscheck.md` | the bus cycles compared with the Suska core |

## Licence

Copyright 2026 Romain Dolbeau.

RD68021 is licensed under the **CERN Open Hardware Licence Version 2 – Strongly
Reciprocal** (SPDX: `CERN-OHL-S-2.0`); the full text is in `LICENSE`. Anyone
who makes or distributes hardware based on it must make its modified sources
available under the same terms.

The submodules under `Inputs/` are separate works under their own terms, as are
the Motorola manuals they contain.
