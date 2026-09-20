# Musashi, the instruction-level oracle

```sh
make ea            # every addressing mode and extension-word shape
```

| | |
|---|---|
| `m68kconf.h` | a copy of Musashi's, with **two** switches moved and both written up at the top of the file |
| `musashi_ea.c` | generates one test per addressing mode and extension-word shape, runs it as an MC68020, and prints the address, the accesses it made and the registers it finished with |

## Two instruments

`LEA <ea>,A0` computes an address and does nothing else with it, so the address
itself is the answer and nothing can hide a wrong one. But LEA takes only the
control modes, so `(An)+`, `-(An)` and the operand fetch an effective address
exists to make are out of its reach. `MOVE.L <ea>,D0` reaches those: the
post-increment and pre-decrement show up in the final register state, and the
fetch shows up in the access list next to whatever the address calculation
itself read.

## What is compared

The **operand**, not the bus cycle. Table 5-6 splits one misaligned operand
across up to four cycles and an interpreter has no bus at all, so the two are
not the same quantity; the harness triggers its recorder on `OCS`, which UM
5.1.1 asserts on the first cycle of an operand and no other.

Each access carries its **space**. PRM 2 classifies every program-counter-
relative access as a program reference, so the function code is part of the
answer and not an implementation detail — see `doc/divergences.md` for the one
place Musashi and the manual disagree about it.

Musashi is an **oracle, not a source**. Nothing here was written by reading how it
computes anything; the point is that two independent readings of the manual have
to agree, and where they do not, the manual decides. `CLAUDE.md` makes that a
project rule and `doc/divergences.md` records the places it has been invoked.

## Do not switch a CORE off in m68kconf.h

It looks like turning off the cores this project does not want would make the
oracle more trustworthy. It does the opposite, and quietly. Musashi's CPU-type
predicates are chained:

```c
#if M68K_EMULATE_010 ... #else
    #define CPU_TYPE_IS_010_LESS(A)  CPU_TYPE_IS_EC020_LESS(A)
#endif
#if M68K_EMULATE_EC020 ... #else
    #define CPU_TYPE_IS_EC020_LESS(A)  CPU_TYPE_IS_020_LESS(A)
#endif
```

and `CPU_TYPE_IS_020_LESS` **includes the 68020**. With the 68010 and the EC020
switched off, `m68ki_get_ea_ix` takes its "010 or less" early return for a 68020
and ignores the brief extension word's scale factor and the full extension word
entirely. The oracle becomes a 68000 for the one calculation it is here to check,
and says nothing. See `doc/bugs-found.md`.

## Building it

Musashi generates `m68kops.c` from `m68k_in.c` with its own `m68kmake`, and
`Inputs/` is immutable, so everything is built out of tree into `build/musashi/`.
`m68kconf.h` is force-included with `-include` rather than put on the include
path: Musashi includes its own with quotes, which searches its own directory
first.

Two link-time traps, both measured: `m68kfpu.c` is `#include`d by `m68kcpu.c` and
must not be compiled beside it ("multiple definition of `m68040_fpu_op1`"), while
`softfloat.c` is **not** included and must be.
