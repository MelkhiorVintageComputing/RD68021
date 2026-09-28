# What limits the frequency

`make impl` reports the worst path static timing analysis finds. `make paths`
groups the worst paths into families, and checks that the routes below, which
no microword can take, are absent from the netlist -- it fails if one comes back.

Artix-7, with the coprocessor interface, on today's tree (commit 640a47b):

| constraint | static frequency | slack | Slice LUTs |
|---|--:|--:|--:|
| **33.333 ns, 30 MHz** (`scripts/rd68021.xdc`) | **35.60 MHz** (28.09 ns) | +2.62 ns | 7,762 |
| 25 ns, 40 MHz (a trial, not checked in) | **41.57 MHz** (24.05 ns) | +0.78 ns | 7,777 |

The Cyclone V makes 33.05 MHz at 33.333 ns (`doc/implementation.md`).

There are no exclusions: static timing is the real answer. The constraint still
matters -- Vivado stops optimising once it is met, which is why the same RTL
reports 35.6 MHz asked for 30 and 41.6 asked for 40.

How it got here, each step measured on the Artix-7:

| | constraint | static frequency |
|---|---|--:|
| the M13 tree | 60 ns | 22.28 MHz |
| after the performance phases | 60 ns | 21.83 MHz |
| the same RTL, constrained harder | 40 ns | 25.54 MHz |
| the unreachable routes taken out (commit 23f64a0) | 40 ns | 27.97 MHz |
| the same RTL | 33.333 ns | 31.34 MHz |
| the same RTL, trial | 25 ns | 39.05 MHz, failing by 0.61 ns |
| bit-field results off the A bus (c2a3ba0), trial | 25 ns | 40.79 MHz |
| the multiplier's product off the A bus (640a47b), trial | 25 ns | 41.57 MHz |

## The routes that are gone

The worst paths used to be ones no microword could take, and `scripts/paths.tcl`
could only cut them out of a report:

| route | what it was |
|---|---|
| shifter → next micro-address | the shifter's result, onto the result bus, into the Z-flag logic, into a condition on the microword's own result, into the store's address |
| bit-field unit → next micro-address | the same, from the find-first-one and the field extractor |
| bit-field unit → shifter | the bit-field unit's outputs ride the A bus, and the A bus was the shifter's operand |

The first two had two ways into the next micro-address, and both are now taken
from registers instead of the result bus:

- **The three conditions on a microword's own result**, used by four microwords.
  - `RESM1` is DBcc's `Dn − 1 = $FFFF`, which is `Dn[15:0] = 0`.
  - `RESNEG` and `GTZ` are CHK's sign test and its signed `Dn > bound`, from a
    small comparator of its own.
- **`sr_eff`**, the status register as a decoding microword leaves it, which the
  interrupt and trace tests read at the boundary.
  - Four microwords write SR and decode: MOVE to SR and STOP (T0), and ANDI,
    ORI and EORI to SR (SR with T0).
  - `sr_eff` is computed from those two registers.

The third is gone because the shifter has a two-way operand multiplexer of its
own: a data register or read data.

## The deep units' results off the A bus

With those gone, a 40 MHz trial showed the next layer of the same thing: the
bit-field unit's results, and then the multiplier's product, rode the A bus, so
static timing had to time them through the adder, into the condition codes, into
the prefetch address and into the fetch unit. No microword sends them there.

- **The four bit-field sources** (field, sign-extended field, first-one offset,
  merged word) are only ever copied or complemented into a data register or a T
  register.
- **The multiplier's two halves** are only ever copied, at long size, into a data
  register. The MULx.L condition codes read the product itself.

Both now have a multiplexer of their own, and join the result only at those
register destinations (`y_reg` in `rtl/rd68021_seq.sv`). The bit fields' did most
of the work: the 25 ns trial went from failing by 0.61 ns to 40.79 MHz, and the
design got 199 LUTs smaller.

Each of these narrow routes is only the same as before for a microword of the
shape the RTL assumes, so the assembler holds them there. These checks are in
`tools/ucode/assemble.py`, and all run in `make ucode-check`, which is in
`make check`:

| check | holds |
|---|---|
| `check_live_shape` | the three conditions, and the SR writes that decode |
| `check_shift_src` | the shifter's operand |
| `check_bf_shape` | the bit-field sources |
| `check_mul_shape` | the product and the MUL32/MUL64 codes |

## What is left

At the checked-in 33.333 ns the first families reported are the early retire's
half-period paths, `req_early` into the fetch unit, at 35.60 MHz. Then there are
full-period ones: the microcode store's output into the data registers
(39.2 MHz), and a data register back into the register file (39.7 MHz).

Asked for 40 MHz, Vivado gets the early retire to about 42.6 MHz, and what limits
it at 41.57 MHz is:

| period | family |
|--:|---|
| 24.05 ns | the microcode store's output → the shifter → the result bus → CACR's cache-control pulse → the instruction cache's valid bits |
| 23.84 ns | the store's output → the store's address |
| 23.72 ns | the store's output → the fetch unit's fill point |

The first is one more route no microword takes. `cach_op`, the pulse a MOVEC to
CACR sends the cache when it sets C or CE, is decoded from the result bus, so the
shifter is in front of it; the MOVEC that writes CACR never shifts. The next two
are the store's output fanning out to most of the sequencer, three quarters
routing.

## If it has to be faster

**`cach_op` off the result bus.** Taking the pulse from the operand MOVEC
actually writes -- a data register or read data -- would remove the first family
above, the same way the others went.

**The early retire's half-period path** (`doc/timing-divergences.md`) is next, at
about 42.6 MHz. The bus unit's falling-edge verdict reaches the fetch unit through
the checkpoint-write gating in 17 levels. Taking the fetch unit's cache lookup off
the checkpoint-write gate would be the fix.

**The microcode store's output.** It fans out to most of the sequencer, and its
routing is most of the delay of what remains. Duplicating the output register
would attack it.

**The bus unit's own paths are not the limit.** Its worst is the late bus-error
term into the operand registers, twelve levels in half a period. The manual has
no speed grade above 33.33 MHz, and `make timing` finds all four of its grades
feasible on the bus side.
