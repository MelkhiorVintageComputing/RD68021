# AC-specification conformance

**Result: feasible at all four speed grades**, with 5 to 10 ns of room on the
binding constraint and 42 of the manual's 64 numbered specifications measured. The
other 22 are not questions about this processor's pad delays, and each is named
with the reason.

```
 16.67 MHz  feasible, 42 specifications measured, 10.0 ns of room on the binding constraint
            10 ecs.assert->ecs.negate (read, 30 ns apart)
            tightest pad-delay budget: 20.0 ns, 6A ecs.assert
 20.00 MHz  feasible, 42 specifications measured, 10.0 ns of room
            10 ecs.assert->ecs.negate (read, 25 ns apart)
 25.00 MHz  feasible, 42 specifications measured,  5.0 ns of room
            10 ecs.assert->ecs.negate (read, 20 ns apart)
 33.33 MHz  feasible, 42 specifications measured,  5.0 ns of room
            10 ecs.assert->ecs.negate (read, 15 ns apart)
```

`make timing`, and it is in `make check`.

## Why this is decided rather than measured

An RTL model has no pad delays. Every pin in `rd68021_biu` moves exactly on a clock
edge, so a limit of the form "Clock High to Address Valid ≤ 30 ns" cannot be
*measured* from it — there is nothing there to measure.

It can still be answered, because every limit in Section 10 is a statement about
the same unknowns. Each one is either

- a **budget** on one pad delay — `0 ≤ d[as.assert] ≤ 30` — or
- a **separation** between two pins — `(t_b + d_b) − (t_a + d_a) ≥ 15`, where the
  two times come from the simulation and are constants.

Both rearrange to `d_x − d_y ≤ c`, which is a weighted edge in a graph whose
shortest-path problem is feasible exactly when there is no negative cycle.
Bellman-Ford answers that, and its potentials are a pad-delay assignment meeting
every limit at once. So the question is not "how fast is this design" but "is there
any set of pads that makes it legal", and that has an exact answer.

`make timing-verbose` prints one such assignment.

## The binding constraint is ECS, at every grade

Specification 10, **ECS width asserted**, against an ECS pulse that is exactly one
half clock:

| Grade | half clock | specification 10 minimum | room |
|---|--:|--:|--:|
| 16.67 MHz | 30 ns | 20 ns | 10 ns |
| 20 MHz | 25 ns | 15 ns | 10 ns |
| 25 MHz | 20 ns | 15 ns | 5 ns |
| 33.33 MHz | 15 ns | 10 ns | 5 ns |

UM 5.1.1 asks for ECS "for one-half clock", and that is what this design does, so
the margin is whatever the manual left between its own minimum and half of its own
cycle time. It narrows with frequency because specification 10 does not scale with
the clock. Nothing in the design can widen it without making ECS something other
than the half clock the manual describes.

The tightest pad *budget* is specification 6A, Clock High to ECS/OCS asserted: 20,
15, 12 and 10 ns at the four grades. That is the manual's number, not this
design's, and it is reported separately for exactly that reason — see "a bound's
margin is not a margin" in `tools/timing/README.md`.

## One run per grade

The separations are measured in clock edges, so a recording made at one frequency
is evidence about that frequency and nothing else. `make timing` runs the
testbench four times, at each grade's minimum cycle time from specification 1 —
60, 50, 40 and 30 ns — and judges each log against its own column. An earlier
version of this analysis judged one 60 ns recording against all four, which
credited the design at 33.33 MHz with half-clocks twice as long as it would have
there, and reported the wrong binding constraint as a result.

## The pad model

Each pin transition has its own delay variable. Unless they are tied, the solver
may give one pin a large delay when it asserts and a small one when it negates,
which real pads do not do — and it is not a hypothetical: a short pulse can pass a
minimum-width limit only by exploiting exactly that. `PADSKEW` is how far apart one
pin's transition delays may be, and **the analysis defaults to 0**: one delay per
pin.

> **INFEASIBLE is a proof. FEASIBLE is conditional** on that model.

## What is measured, and what is not

42 specifications are anchored to pin transitions. `python3
tools/timing/anchors.py` prints the table; `--unanchored` prints the other 22 with
a reason each. They fall into four groups:

| | |
|---|---|
| The clock itself — 1, 2/3, 4/5, 32 | properties of the stimulus, not of the design. An RTL model has no edge ramps |
| Requirements on the external device — 28, 29A, 31, 31A, 48, 57, 37A | what a slave or an alternate master must do. This design's side of them is in `doc/bus-timing-compliance.md` |
| Input requirements — 27, 27A, 29, 30, 47A, 47B | see below |
| Clock-counted — 35, 37, 56, 58, 59 | counted directly in `bus_arb_tb`, or not yet built (56 is the RESET instruction, M5) |

### The other half: where this design samples its inputs

Six specifications describe what the processor requires of the data and handshake
arriving at it, rather than what it promises about the pins it drives. They are not
pad-delay questions and the solver above says nothing about them.

What this design does is stated and tested elsewhere — DSACK, BERR, HALT and AVEC
are sampled at the falling edge entering S3 and read data is latched at the falling
edge entering S5, both in `doc/bus-timing-compliance.md` and both checked by
`bus_ruler_tb`. Turning that into a measured *requirement* — sweeping the time at
which a slave answers and finding the latest one that still works — is a separate
instrument and is not built. Until it is, the input specifications are covered by
inspection and by the directed testbenches, and this is the gap.

## Trusting the tool

The design is judged by this code, so the code is judged by cases whose answer is
arithmetic: `python3 tools/timing/feasible.py` runs six known-answer tests over the
solver — a satisfiable bound, a self-contradicting one, a separation with room, one
that cannot be met, a width shorter than its own minimum, and both kinds of margin.
It is in `make check` by way of `make timing`.

Two of those exist because they caught real mistakes in this tool:

- The virtual source was wired in as **real** zero-weight edges from a source node
  to every variable. That is not a virtual source; it is the constraint "every pad
  delay is at most zero", which specification 9's 3 ns minimum immediately
  contradicts. Every grade reported INFEASIBLE, and the reported contradiction was
  a single bound against itself, which is what made it obvious.
- The first margin calculation reported the slack of each constraint *in the
  solution found*. Bellman-Ford returns an assignment sitting hard against some
  corner, so it reported 0.0 ns of room at every grade, on a bound, whatever the
  design did.

And one end-to-end check, run by hand: shortening AS from three bus states to one
makes the analysis report INFEASIBLE at all four grades, naming the contradiction
and its round trip in nanoseconds.
