# AC-timing analysis

Judges an event log from `sim/tb/rd68021_timing_tb.sv` against Section 10 of the
user manual. `doc/ac-timing.md` is the account of what it found; this is the map.

```sh
make timing                                        # measure and judge, all four grades
make timing-verbose                                # ... and print a pad assignment
make timing PADSKEW=5                              # loosen the pad model

python3 tools/timing/specs.py --dump --freq 16_67  # the limits, defects resolved
python3 tools/timing/anchors.py                    # what each specification measures
python3 tools/timing/anchors.py --unanchored       # ... and what it does not
python3 tools/timing/events.py build/timing-16_67.log
python3 tools/timing/feasible.py                   # the solver's own self-test
```

| | |
|---|---|
| `specs.py` | Section 10 as data: 64 numbered specifications, four grades. Holds the judgements the CSV cannot — that number 45 is printed twice and is two specifications, that seven rows are in clock periods and need converting, that the manual's minus sign is an en dash |
| `anchors.py` | which two events each specification separates, read off figures 10-3, 10-4 and 10-5; and, for the ones that are not a question about pad delays at all, which and why. It fails if a specification is neither anchored nor explained |
| `events.py` | reads a log; the pairing rule, stated once, that every separation depends on |
| `feasible.py` | the difference-constraint system, Bellman-Ford, the margin calculation, and a known-answer self-test |
| `analyse.py` | the command line and the verdict |

## The three things worth knowing before changing any of it

**The limits live here and not in SystemVerilog.** The testbench emits times and
nothing else; no testbench knows what a specification is. That is what lets a wrong
anchor be fixed with a one-line edit and a re-analysis in milliseconds instead of a
re-simulation, and it is what would let a second core, in another language, be
judged by exactly the same code.

**INFEASIBLE is a proof; FEASIBLE is conditional.** Each pin transition has its own
delay variable, so unless they are tied the solver may give one pin a large delay
when it asserts and a small one when it negates. Real pads do not work that way.
`PADSKEW` is how far apart one pin's transitions may be and defaults to **0** — one
delay per pin.

**A bound's margin is not a margin.** Bellman-Ford returns an assignment sitting
hard against some corner, so whichever bound it landed on reports zero room
whatever the design does; and a bound's true margin is `hi − lo`, which is what the
manual printed and says nothing about this design. The binding constraint is
therefore the tightest **separation**, and the tightest pad budget is reported
separately and labelled as such. An earlier version of this tool quoted the bound
and called it the answer.

## One run per speed grade

The separations are measured in clock edges, so a recording made at one frequency
is evidence about that frequency and nothing else: judging a 60 ns recording
against the 33.33 MHz limits would credit the design with half-clocks it does not
have there. `make timing` runs the testbench four times, at each grade's minimum
cycle time from specification 1, and analyses each log against its own column.
