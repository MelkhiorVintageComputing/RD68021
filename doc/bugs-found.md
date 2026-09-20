# Every defect found in this design, and what stops it coming back

One entry per defect: what it was, what found it, and the test that now fails if it
returns. Kept because the *way* each one was found is the useful part — a defect
found by one thing would usually have survived all the others.

---

## M1 · A prefetch was issued twice

**What:** the data request port has `req_last`, combinational and true throughout
S5 of an operand's final cycle, because the operand completes at the rising edge
that ends S5 and the source has that half clock to present its next request or drop
this one. The instruction fetch port had no such signal. A source that dropped
`fetch_valid` on `fetch_ack` — one clock later — was still asserting it at the edge
the operand completed, and the bus unit started a second, identical prefetch.

**Found by:** a testbench reporting that a prefetch had taken **zero** bus cycles.
It had not: it had completed a stale second fetch left in flight by the previous
one.

**Fixed by:** `fetch_last`, the same signal for the same reason.

**Stops it coming back:** `bus_sizing_tb` checks the bus-cycle count of a prefetch
against UM Table 5-6's own first row, 1:2:4, on all three port widths.

---

## M1 · Two conflicting drivers on the operand registers

**What:** `op_addr`, `op_rem` and `op_data` were written from the rising-edge block
(when an operand starts) and from the falling-edge block (when a cycle ends). That
is one register with two clocks.

**Found by:** yosys, which said "multiple conflicting drivers" — and `make lint`
passed anyway, because a warning is not a non-zero exit status.

**Fixed by:** moving every operand register into the rising-edge block. The read
data is latched by the falling edge entering S5, as UM 5.3.1 state 4 requires, and
merged by the rising edge that ends S5.

**Stops it coming back:** `make lint` now fails on "multiple conflicting drivers",
an inferred latch, or an implicit declaration, none of which change yosys's exit
status.

---

## M2 · A retried bus cycle ran at the wrong address, and then moved nothing

**What:** the worst of the three so far, and the one a casual test would have
missed, because the operand still completed with the right data.

A multi-cycle operand advances its residual on the rising edge that ends S5, and
the next cycle's address is latched on that same edge — so the continuation
arithmetic read `op_addr + xfer_done`, the residual *after* the transfer this edge
is applying. That is correct for a cycle that follows another immediately.

A retry does not follow immediately. UM 5.5.2 terminates the cycle, waits for BERR
and HALT to be negated, and only then "retries the previous cycle using the same
access information". By that time `term_rty` has been cleared — it describes the
cycle that produced it, and that cycle is over — so `xfer_done` had gone back to
reporting the full width of the port. The retried cycle was issued at
`op_addr + 4`, with a residual of `4 - 4 = 0`, so it moved no bytes at all; a third
cycle then ran at the right address and completed the operand.

The observable symptoms were a correct answer, three bus cycles instead of two, and
one bus cycle at an address the program never asked for. On a real system that
stray access is a read of the wrong location — or a *write* to it.

**Found by:** `bus_error_tb` checking the bus-cycle count of a retried operand, not
its data. The data check passed throughout.

**Fixed by:** advancing the residual only on the edge that ends S5. Re-entering S0
from anywhere else — which means a retry — carries `op_addr` and `op_rem` forward
untouched.

**Stops it coming back:** `bus_error_tb` asserts exactly two bus cycles for Table
5-8's cases 5 and 6, and `bus_arb_tb` asserts two for relinquish-and-retry.

---

## M2 · The standing arbitration monitor watched for the wrong thing

**What:** not a defect in the design, but in the test for one, which is worth the
same entry.

The MC68010 project's hardest arbitration bug was that the bus state machine
decided whether to *start* a cycle from the arbiter's current state while the
output enables followed its next one, so on the single edge where the arbiter
reached its granting state a cycle began anyway and ran with its address bus in
high impedance. The monitor written here looked for exactly that: AS asserted with
the address released.

It never fired, even with the bug deliberately reintroduced. In *this* design the
control group's output enables follow the same release as the address group, so the
mis-started cycle does not drive AS either. It drives nothing at all: no slave sees
it, nothing answers, and the operand hangs or returns the wrong bytes.

**Found by:** mutating `start_ok` to read the arbiter's current state instead of
its next, and watching the test suite pass.

**Fixed by:** watching ECS instead — it marks the beginning of every bus cycle and
is never three-stated, so it is visible even when everything else has gone away —
and sweeping the phase of BR across all sixteen positions of a four-cycle operand,
because a single fixed delay does not reach the one edge that matters. The mutation
now fails at three phases.

---

## M3 · The AC solver's "virtual source" was a constraint of its own

**What:** a difference-constraint system is solved by Bellman-Ford from a source
that reaches every node. The standard way to get one is to start every distance at
zero — a source with a zero-weight edge to everything, *not present in the graph*.
This implementation added those edges for real.

An edge from the source to `x` of weight 0 asserts `d[x] − d[source] ≤ 0`: every
pad delay is at most zero. Specification 9's minimum of 3 ns contradicts that
immediately, so every grade reported INFEASIBLE.

**Found by:** the answer being wrong in an obvious direction. The reported
contradiction was one bound against itself, which no real design could produce.

**Fixed by:** initialising every distance to zero instead of adding the edges.

**Stops it coming back:** `python3 tools/timing/feasible.py` — the first
known-answer case is a single bound of 3 to 30 ns, which the broken version called
infeasible.

---

## M3 · A margin that was not a margin

**What:** the first version reported, as the binding constraint, the smallest slack
of any constraint *in the solution the solver returned*. Bellman-Ford returns an
assignment sitting hard against some corner, so it reported "0.0 ns to spare" at
every grade, on a pad-delay bound, whatever the design did.

Two things were wrong. A slack in one solution is not a margin — the question is
how far a limit could be tightened before *no* assignment exists, which is
`c + shortest path back` for that constraint and is independent of any solution.
And a **bound's** margin is `hi − lo`, the width the manual printed: it says
nothing about the design, so quoting it as the binding constraint flatters or damns
the design by accident.

**Found by:** the number being suspiciously round and suspiciously constant.

**Fixed by:** computing per-constraint margins with Floyd-Warshall, and reporting
the tightest **separation** as the binding constraint with the tightest pad budget
alongside, labelled as what it is.

**Stops it coming back:** two of the solver's self-test cases check both margins of
the same tiny system and their expected values, 45 ns and 30 ns, are arithmetic.

---

## M3 · One recording judged against four speed grades

**What:** the separations this analysis measures are distances between clock edges,
so they scale with the clock period. The first version simulated once, at 60 ns,
and judged that one recording against all four columns of Section 10 — crediting
the design at 33.33 MHz with half-clocks twice as long as it would have there.

It reported *feasible* at every grade, which is the answer it would also have given
if the design were right, and named the wrong binding constraint at three of the
four.

**Found by:** the binding constraint changing from a separation at 16.67 MHz to a
pad bound at the other three, which made no physical sense.

**Fixed by:** `make timing` running the testbench four times, at each grade's
minimum cycle time from specification 1, and judging each log against its own
column.

**Stops it coming back:** the four runs are the target; there is no single-log
path. The clock period is a plusarg with no default other than 60 ns.
