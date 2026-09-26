# What limits the frequency

`make impl` reports the worst path static timing analysis finds; `make paths`
reports what is left when the routes the microcode cannot take are excluded, and
groups the rest into families.

Artix-7, constrained at 40 ns (the 25 MHz grade), with the coprocessor interface:

| | period | frequency |
|---|--:|--:|
| static, every path | 39.16 ns | **25.54 MHz** |
| with three exclusions, each held by a build check | 35.86 ns | 27.89 MHz |
| the early retire, a half-period path (3.4 ns of slack in 20) | ~33.2 ns | ~30 MHz |

The last row is only what the 40 ns build left it: asked for 30 MHz, Vivado gives
that path 2.84 ns of slack in 16.67, about 36 MHz.

And a trial constrained at 33.33 ns (30 MHz), not checked in: 29.78 MHz static,
failing by 0.242 ns on 11 endpoints -- all of them the microcode store's address,
all on the bit-field route below -- and **31.37 MHz with the exclusions**, so
every route the microcode takes meets 30 MHz.

The constraint matters as much as the logic. At the 60 ns this design was
constrained to until the performance work, the same netlist reported 21.83 MHz:
Vivado stops optimising once the constraint is met.

## The static limit

A data register, into the bit-field unit (as a width or an offset), through the
memory-window multiplexer and the find-first-one, onto the A bus, through the
shifter, onto the result bus, into the Z-flag logic, into a condition, into the
next micro-address and so into the microcode store's address: **47 logic levels,
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

After the exclusions, the 40 ns build's top families:

| period | family |
|--:|---|
| 35.86 ns | the microcode store's output → the store's address |
| 34.36 ns | the store's output → `irq_taking_q` |
| 33.44 ns | the store's output → `upc` |
| 33.43 ns | data register → the condition codes |

The first three are one loop: a microword's fields select the operands, the
shifter and the adder make the result, the Z-flag logic reads it, a condition
that tests the microword's OWN result (RESM1 for DBcc, RESNEG, GTZ) picks the
next micro-address, and that goes back into the store. 36 levels, 62 % routing:
the store's output fans out to most of the sequencer. The fourth is the same
datapath ending in the status register instead.

These are real -- DBcc's counter test runs this loop every iteration -- so
27.89 MHz is what the logic can do, and 25.54 MHz is what can be promised with
no assumption at all.

## If it has to be faster

For the static number, the bit-field unit is the lever. Its width and offset
come from the extension word or a data register, and are combinational from the
register file into a 40-bit window multiplexer. Registering them -- one
microword that computes the width and offset into a latch before the one that
uses them -- takes the register read and the width logic off the static path, at the cost of one clock on each
bit-field instruction, which `doc/timing-divergences.md` shows those have to
spare (BFFFO is 4 clocks here and 18 in the manual).

Past about 30 MHz the reachable loop above has to be broken, and there are two
ways. The conditions that read a microword's own result can be registered and
tested by the NEXT microword, which takes the adder and the Z-flag logic off the
path into the store's address at the cost of a clock where they are used -- one
per DBcc iteration. And the store's output register can be duplicated, which
attacks the routing that is 62 % of the path. The early retire's half-period
path (`doc/timing-divergences.md`) comes after that, at about 36 MHz: the bus
unit's falling-edge verdict reaches the fetch unit through the checkpoint-write
gating in 16 levels.

The bus unit's own paths are not the limit: its worst is the late bus-error term
into the operand registers, twelve levels in half a period.
