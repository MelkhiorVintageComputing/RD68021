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
