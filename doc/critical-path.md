# What limits the frequency

`make impl` reports the worst path static timing analysis finds. `make paths`
groups the worst paths into families, and checks that the routes below, which
no microword can take, are absent from the netlist -- it fails if one comes back.

Artix-7, with the coprocessor interface:

| constraint | static frequency | slack | Slice LUTs |
|---|--:|--:|--:|
| 40 ns, the 25 MHz grade | 27.97 MHz (35.75 ns) | +4.25 ns | 7,805 |
| **33.333 ns, 30 MHz** (`scripts/rd68021.xdc`) | **31.34 MHz** (31.90 ns) | +1.43 ns | 7,815 |
| 30 ns, the 33.33 MHz grade (a trial, not checked in) | **34.76 MHz** (28.77 ns) | +1.23 ns | 7,838 |

There are no exclusions: static timing is the real answer. The constraint still
matters -- Vivado stops optimising once it is met, which is why the same RTL
reports 28 MHz asked for 25, 31 asked for 30 and 35 asked for 33.33.

## The routes that are gone

Until the change recorded in `doc/size-and-speed.md`, the worst paths were ones
no microword could take, and `scripts/paths.tcl` cut them out of a report:

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

Each of these is only the same as before for a microword of exactly the shape
the RTL assumes, so the assembler holds them there:

- `check_live_shape` in `tools/ucode/assemble.py` covers the conditions and the
  decoding SR writes;
- `check_shift_src` covers the shifter's operand.

Both run in `make ucode-check`, which is in `make check`.

Removing the routes cost 117 Slice LUTs and moved the 40 ns static figure from
25.54 to 27.97 MHz. That is the old "reachable paths" estimate of 27.89 MHz, now
without the assumption.

## What is left

At the checked-in 33.333 ns, the top families all begin at `xw_q` and end in the
condition codes, the registers and the fetch unit -- the same datapath the 40 ns
build showed first:

| period | family |
|--:|---|
| 31.90 ns | `xw_q` → the condition codes |
| 31.88 ns | `xw_q` → the fetch unit's fill point |
| 31.29 ns | `xw_q` → the data registers |
| 30.91 ns | `xw_q` → the address registers |

They are one datapath with four ends, and they are real paths:

- `xw_q` is the extension word;
- for a bit-field instruction, bit 5 of it chooses whether the width comes from
  a data register, and bits 2:0 name the register;
- so the register file is read through a mux the extension word steers, into
  the bit-field unit's width logic and 40-bit window, onto the A bus, through
  the ALU, and into the flags or a register.

That is 33 to 40 levels, three quarters of the delay routing.

Asked for 30 ns, Vivado gets that datapath under 30 ns too, and what is left
at 34.76 MHz is:

| period | family |
|--:|---|
| 28.77 ns | the microcode store's output → the condition codes |
| 28.48 ns | the store's output → the fetch unit's fill point |
| 27.61 ns | the store's output → the data registers |
| 27.35 ns | the early retire (half period) → the fetch unit's holding register |

The first three are the microword's own fields choosing the operands and the
operation, through the ALU, into a register: the store's output fans out to most
of the sequencer, and routing is two thirds of the delay. The fourth is the early
retire's half-period path, 1.3 ns of slack in 15, about 36.6 MHz.

## If it has to be faster

**The bit-field unit's width and offset are the lever.** Registering them would
take the register read and the width logic off every path above. That means one
microword computes the width and offset into a latch before the one that uses
them.

- The cost is a clock on each bit-field instruction.
- `doc/timing-divergences.md` shows they have clocks to spare: BFFFO is 4 here
  and 18 in the manual.

**Past 33.33 MHz, the microcode store's output.** It fans out to most of the
sequencer, and its routing is most of the 30 ns build's worst families;
duplicating the output register would attack it.

**The early retire's half-period path** (`doc/timing-divergences.md`) is close
behind, at about 36.6 MHz. The bus unit's falling-edge verdict reaches the fetch
unit through the checkpoint-write gating in 14 levels. Taking the fetch unit's
cache lookup off the checkpoint-write gate would be the fix.

**The bus unit's own paths are not the limit.** Its worst is the late bus-error
term into the operand registers, twelve levels in half a period.
