# What limits the frequency

`make impl` reports the worst path static timing analysis finds; `make paths`
reports what is left when the routes the microcode cannot take are excluded, and
groups the rest into families.

| | period | frequency |
|---|--:|--:|
| static, every path | 44.02 ns | **22.72 MHz** |
| with three exclusions, each held by a build check | 37.25 ns | 26.84 MHz |
| the bus unit's worst half-period path | ~31 ns | ~32 MHz |

## The static limit

A data register, into the bit-field unit (as a width or an offset), through the
memory-window multiplexer and the find-first-one, onto the A bus, through the
shifter, onto the result bus, into the Z-flag logic, into a condition, into the
next micro-address and so into the microcode store's address: **42 logic levels,
three quarters of the delay routing.**

Nothing runs it. The result bus reaches the next micro-address by two routes
only -- a condition that reads the microword's own result (RESM1, RESNEG, GTZ),
and a status-register write that the interrupt test sees through `sr_eff` the
same clock -- and no microword on either route takes its result from the
shifter, the bit-field unit, the multiplier or the divider. Nor is the shifter
ever fed from the bit-field unit: it shifts a data register or read data.

## The exclusions, and why they are not in the build

`scripts/paths.tcl` cuts exactly three concatenations, each as a pair of
`-through` points on module pins so that neither half stops being timed:

| exclusion | from | to | held by |
|---|---|---|---|
| shifter-to-upc | shifter outputs | the store's address, `upc`, `irq_taking_q` | `check_live_cond` |
| bitfield-to-upc | bit-field unit outputs | the same | `check_live_cond` |
| bitfield-to-shifter | bit-field unit outputs | shifter inputs | `check_shift_src` |

The checks are in `tools/ucode/assemble.py`, run by `make ucode-check`, which is
in `make check`: a microword that would make an excluded route real fails the
build. The exclusions themselves are deliberately **not** in
`scripts/rd68021.xdc`. They depend on which microwords exist, which a constraint
file has no way to say; written into the build they would stop the routes being
timed the day the microcode changed, and the check that catches that would be the
only thing standing between a microcode edit and a silently wrong netlist. Here
they only shape a report.

The divider is deliberately not excluded: DIVZERO reads it directly and is real.

## What is left

The top families after the exclusions all begin at a data register and go
through the bit-field unit's width and memory-window logic into the ALU:

| period | family |
|--:|---|
| 37.25 ns | data register → condition codes |
| 36.74 ns | data register → the fetch unit's fill point |
| 35.7 ns | data register → the register file and the stack pointers |

These are real enough -- BFFFO with a width from a data register on a memory
operand does put the find-first-one result through the adder -- but only for a
handful of microwords, and separating those from the rest would be an argument
per source and destination pair. The honest numbers are the two above: 22.72 MHz
with no assumption at all, and 26.84 MHz as an estimate of what the logic can do.

## If it has to be faster

The bit-field unit is the lever. Its width and offset come from the extension
word or a data register, and are combinational from the register file into a
40-bit window multiplexer. Registering them -- one microword that computes the
width and offset into a latch before the one that uses them -- takes the register
read and the width logic off every path above, at the cost of one clock on each
bit-field instruction, which `doc/timing-divergences.md` shows those have to
spare (BFFFO is 4 clocks here and 18 in the manual).

The bus unit is not the limit and is not close: its worst path is the late
bus-error term into the operand registers, twelve levels in half a period.
