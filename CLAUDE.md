# RD68021 — SystemVerilog MC68020

A from-scratch SystemVerilog implementation of the Motorola MC68020, targeting FPGA
(short-term priority) and ASIC.

## Goals

1. **100 % software compatibility** with a real MC68020.
2. **Bus-timing compatibility** — the bus-state (S0–S5) behaviour of the original,
   including dynamic bus sizing and misaligned operand transfers.
3. Instruction *cycle* timings need not match, but **every divergence must be measured,
   reported and justified** in `doc/timing-divergences.md`.

## Hard rules

These are not style preferences. Breaking one is a bug.

### `Inputs/` is immutable

Nothing under `Inputs/` may be modified, ever. New inputs may be *added* (as submodules or
new directories), but once added they are frozen too.

This bites in one place already: `Inputs/ref/qemu-sun3/scripts/setup-qemu.sh` clones and
builds QEMU into its own directory, which is inside `Inputs/`. The Makefile copies that
harness to `build/qemu-sun3/` and runs it there.

### A reference implementation is never a source for RTL

`Inputs/ref/Musashi/`, `Inputs/ref/Suska_Configware/`, `Inputs/ref/qemu-sun3/` and the
TME in `Inputs/ref/Run-Sun3-SunOS-4.1.1/` exist here **only** to be run and compared
against. You may **not** read them to work out how to
write our RTL. Anyone (human or agent) writing code in `rtl/` must not open a file in
those directories. (`sim/tme/` is written against TME's element and bus-connection
interfaces, which is what running it inside TME needs. `sim/tme/rd68021_fpu.c` calls
TME's floating-point routines to be the MC68881 on the core's coprocessor interface --
TME used as a device, as its MMU and serial chips are, and the arithmetic both sides of
`make sunos-fpu` share. Nothing in `rtl/` comes from TME.)

The golden reference is the documentation in `Inputs/doc/`. When an oracle disagrees with
this core, the manual is the arbiter and the disagreement is an investigation, not a bug
report against the RTL — Musashi's own MC68020 addressing, bit-field and CAS
implementations are not authoritative, and it does not implement CALLM/RTM or speak the
coprocessor protocol at all.

### No initialisation outside reset

ASIC is a target, so there is no power-on register state. No `initial` blocks in `rtl/`,
no declaration-site initialisers on anything that infers a register, no relying on `'x`
resolving to a useful value. Every register gets its value from the reset branch of its
`always_ff`. `make audit` proves it, in the source *and* in the yosys netlist.

### Split I/O pins

The original's bidirectional and three-state pins become separate `_i` / `_o` / `_oe`
signals, `_oe` active high meaning the core is driving. An external wrapper converts to
real three-state pins where a design needs them. See `doc/pinout.md`.

### Portable SystemVerilog only

The RTL must elaborate under **iverilog, Verilator, yosys, Vivado, Quartus and Questa**.
See `doc/coding-standard.md` for the permitted subset — yosys is the strictest and
therefore defines it. `make lint` is the gate for the three that need no vendor
installation; `make synth`, `make lint-quartus` and `make lint-questa` are the other
three, and they are not in `make check` for that reason.

## Scope

| | |
|---|---|
| In | the full MC68020 integer ISA (116 instructions), all 18 addressing modes, the instruction cache, CALLM/RTM, and the coprocessor interface |
| Out | the MC68EC020 variant |

## Layout

| Path | What |
|---|---|
| `rtl/` | the processor, one module per file, prefix `rd68021_` |
| `rtl/gen/` | generated from `tools/ucode/` — microcode store, decoders, frame package |
| `tools/` | microcode assembler, vector generator, test runners, timing solver, doc generators (Python) |
| `sim/tb/` | testbenches |
| `tools/vectors/` | the per-opcode sweep generator |
| `sim/models/` | bus-slave models, and the scripted coprocessor `make cpif` talks to (doc/coprocessor.md) |
| `sim/programs/` | real code, built by the cross-compiler and run on the core |
| `sim/suska/` | harnesses that run the same code on the Suska VHDL core |
| `sim/tme/` | the core as a CPU element of TME, and an MC68881 for its coprocessor interface -- doc/sun3.md |
| `scripts/` | Vivado and Quartus synthesis, implementation and timing scripts |
| `doc/` | pinout, coding standard, checkpoint, coprocessor, compliance, divergence and implementation reports |
| `Inputs/doc/` | Motorola manuals, split by section, with machine-readable AC specs |
| `Inputs/ref/` | reference implementations used as oracles (not as RTL sources) |

## Documentation map

Everything authoritative lives in `Inputs/doc/MC68030_Doc_More_Readable/`. **Ignore the
`MC68000UM_split` and `MC68030*` directories** — different processors.
`MC68881UM_split/` is the coprocessor's side of our §7 and is the cross-check for it.

| Need | Read |
|---|---|
| Pin behaviour | `MC68020UM_split/07-section-03-signal-description.pdf` |
| Processing states, SR, the three stack pointers | `MC68020UM_split/06-section-02-processing-states.pdf` |
| Instruction cache | `MC68020UM_split/08-section-04-on-chip-cache-memory.pdf` |
| Bus protocol (78 pp) | `MC68020UM_split/09-section-05-bus-operation.pdf` |
| Exceptions, SSW, stack frames | `MC68020UM_split/10-section-06-exception-processing.pdf` |
| Coprocessor interface (61 pp) | `MC68020UM_split/11-section-07-coprocessor-interface.pdf` |
| MC68020 cycle counts | `MC68020UM_split/12-section-08-instruction-execution-timing.pdf` |
| Bus timing figures and AC limits | `MC68020UM_split/figure-10-0*.md` + `ac-electrical-specifications.csv` |
| Addressing modes and extension words | `M68000PRM_split/05-section-02-addressing-capabilities.pdf` |
| Instruction semantics | `M68000PRM_split/07-section-04-integer-instructions.pdf`, `09-section-06-supervisor-instructions.pdf` |
| Opcode encodings | `M68000PRM_split/11-section-08-instruction-format-summary.pdf` |
| Which instructions exist | `M68000PRM_split/instructions-by-cpu.csv` — MC68020 = 116 instructions |
| Condition codes | `M68000PRM_split/CONDITION-CODES.md` |
| Vectors and frame formats | `M68000PRM_split/13-appendix-b-exception-processing-reference.pdf` |

`MC68020UM_split/README.md` documents the manual's own defects, and
`doc/manual-contradictions.md` records the ones found here — read both before "correcting"
a spec that looks wrong.

The PDFs have reconstructed outlines and are best read with
`pdftotext -layout <file> -` for a specific section.

In a comment, `UM` is `MC68020UM_split` and `PRM` is `M68000PRM_split`; specification
numbers refer to `MC68020UM_split/ac-electrical-specifications.csv`.

## Building and checking

```sh
make lint     # elaborate every rtl module under the three always-available tools
make audit    # prove no register initialises outside reset
make ucode    # regenerate the microcode ROMs from tools/ucode/
make sim      # directed testbenches (iverilog)
make cpif     # the coprocessor interface against a scripted coprocessor (part of sim)
make sim COPROCESSOR=1   # every core testbench with the coprocessor interface built
make check    # the gate: ucode-check, lint, audit, sim, AC timing
```

The oracles, none of which is in `check` because each takes minutes:

```sh
make ea               # every addressing mode and extension-word shape
make vectors OP=alu   # one instruction group, against Musashi
make vectors-all      # every group there is
make cosim            # real programs, every register at every instruction
make cache            # the same results with no instruction cache, and only fetches saved
make timing-verbose   # the AC solver, with the binding constraint named
make cycles           # instruction clock counts against UM section 8, each a regression check
make suska            # the data cycles against a second core, the Suska WF68K30L under ghdl
make sun3             # a Sun-3/160 boot PROM on the core, inside TME, to the monitor prompt
make sunos            # SunOS 4.1.1 on that machine, to a single-user shell
make sunos-disk       # an installed SunOS 4.1.1 from a disk image (SUNOS_IMG=), multi-user
make sunos-fpu        # ... with an MC68881 on the coprocessor interface, a cc -f68881 program
```

Implementation, each a vendor run of tens of minutes:

```sh
make impl             # Vivado place and route, xc7a100t, out of context
make paths            # what limits the clock, and proof the unreachable routes are gone
make quartus          # the Cyclone V fit, for a second toolchain's number
make quartus AFAMILY='"MAX 10"' APART=10M50DAF484C6GES   # ... or a MAX 10
```

Every instruction group has microcode now, so `make vectors` with no `OP=` runs
them all (`VECGROUPS := all`) and is the same as `vectors-all`; both are expected
to pass. Name a group with `OP=` to run just that one while working on it.

`make help` lists every target, grouped as above.

## Tooling notes

- iverilog 12.0, Verilator 5.032, yosys 0.52, ghdl 5.0.1, Vivado 2025.2 in
  `/opt/Xilinx`, and Quartus Prime Lite in `/opt/Altera` with Questa Altera Starter
  Edition. Questa's `vlog`/`vopt` need no licence; `vsim` does, and this machine has
  none, so nothing simulates under Questa.
- `m68k-linux-gnu-gcc` / `-as` / `-objcopy` build test programs. Its default `-mcpu` is
  **68020** and its `libgcc` is built for it, so test programs may link `libgcc`.
- No gtkwave — dump VCD and inspect with a text tool or an external viewer.
