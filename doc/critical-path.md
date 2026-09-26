# What limits the frequency

`make impl` reports the worst path static timing analysis finds. `make paths`
groups the worst paths into families, and checks that the routes below, which
no microword can take, are absent from the netlist -- it fails if one comes back.

Artix-7, with the coprocessor interface:

| constraint | static frequency | slack | Slice LUTs |
|---|--:|--:|--:|
| 40 ns, the 25 MHz grade (`scripts/rd68021.xdc`) | **27.97 MHz** (35.75 ns) | +4.25 ns | 7,805 |
| 33.33 ns, a 30 MHz trial (not checked in) | **31.34 MHz** (31.90 ns) | +1.43 ns | 7,815 |

There are no exclusions: static timing is the real answer. The constraint still
matters -- Vivado stops optimising once it is met, which is why the same RTL
reports 28 MHz asked for 25 and 31 MHz asked for 30.

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

The 40 ns build's top families:

| period | family |
|--:|---|
| 35.75 ns | `xw_q` → the condition codes |
| 35.01 ns | `xw_q` → the address registers |
| 34.98 ns | `xw_q` → the fetch unit's fill point |
| 34.63 ns | `xw_q` → the data registers |

They are one datapath with four ends, and they are real paths:

- `xw_q` is the extension word;
- for a bit-field instruction, bit 5 of it chooses whether the width comes from
  a data register, and bits 2:0 name the register;
- so the register file is read through a mux the extension word steers, into
  the bit-field unit's width logic and 40-bit window, onto the A bus, through
  the ALU, and into the flags or a register.

That is 36 to 42 levels, three quarters of the delay routing.

## If it has to be faster

**The bit-field unit's width and offset are the lever.** Registering them would
take the register read and the width logic off every path above. That means one
microword computes the width and offset into a latch before the one that uses
them.

- The cost is a clock on each bit-field instruction.
- `doc/timing-divergences.md` shows they have clocks to spare: BFFFO is 4 here
  and 18 in the manual.

**After that, the microcode store's output.** It fans out to most of the
sequencer, and its routing is most of the next families' delay; duplicating the
output register would attack it.

**The early retire's half-period path** (`doc/timing-divergences.md`) comes
after both, at about 37 MHz. The bus unit's falling-edge verdict reaches the
fetch unit through the checkpoint-write gating in 15 levels. In the 30 MHz trial
it has 3.1 ns of slack out of 16.7.

**The bus unit's own paths are not the limit.** Its worst is the late bus-error
term into the operand registers, twelve levels in half a period.
