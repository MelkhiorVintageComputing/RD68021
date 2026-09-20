# What the bus unit does on the pins

The state-by-state behaviour of `rtl/rd68021_biu.sv`, with the citation for each
edge and the test that checks it. This is the document to argue with when a
behaviour is questioned.

As of M1 it covers read and write cycles, wait states, dynamic bus sizing and
misaligned operands. Bus exception control and arbitration are M2; the cache abort
is M11; CPU-space cycles are M2 and M10.

## The ruler

UM 5.3 measures a bus cycle in states, **one per CLK half period**. Even-numbered
states begin on a rising edge, odd-numbered ones on a falling edge, so a cycle with
no wait states is three clocks. The design is two state registers, one per edge,
each computing its next state from the other.

| Edge | What moves | Source |
|---|---|---|
| rising → S0 | ECS asserted, and OCS with it on the first cycle of an operand; A31–A0, FC2–FC0, SIZ1/SIZ0 driven; R/W set; RMC driven | 5.3.1/5.3.2 state 0, specs 6, 6A, 18, 20 |
| falling → S1 | **AS** asserted; **DS** asserted on a read; **DBEN** asserted on a write; ECS and OCS negated | 5.3.1/5.3.2 state 1, 5.1.6, specs 9, 12A, 42, 44 |
| rising → S2 | **DBEN** asserted on a read; write data driven on D31–D0 | 5.3.1 state 2, 5.3.2 state 2, specs 40, 23 |
| falling → S3 | **DSACK1/DSACK0 sampled** — "as long as at least one is recognized by the end of S2"; **DS** asserted on a write | 5.3.1/5.3.2 state 3, specs 47A, 47B, 9 |
| rising → S4 | nothing | 5.3.2 state 4 |
| falling → S5 | **read data latched** — "at the end of state 4, the processor latches the incoming data"; AS and DS negated; DBEN negated on a read | 5.3.1 states 4 and 5, specs 27, 12, 41 |
| rising, ending S5 | address group released; write data released; DBEN negated on a write | 5.3.1/5.3.2 state 5, specs 7, 8, 43 |

A **wait state** is one whole clock inserted between S3 and S4, and the sample
repeats: "if wait states are added, the processor continues to sample the
DSACK1/DSACK0 signals on the falling edges of the clock until an assertion is
recognized" (5.3.1 state 3). *n* waits make the cycle 3 + *n* clocks.

`sim/tb/bus_ruler_tb.sv` asserts every row of that table as a seven-tick pattern
from the rising edge entering S0, and then asserts the widths the pattern implies
in nanoseconds against Section 10's minima at 16.67 MHz — where a half clock is
30 ns, so none of them is a tautology:

| Spec | What | Minimum | This design |
|---|---|--:|--:|
| 10 | ECS width asserted | 20 ns | 30 ns |
| 11 | address valid to AS asserted | 15 ns | 30 ns |
| 14 | AS and DS width asserted (read) | 100 ns | 120 ns |
| 14A | DS width asserted (write) | 40 ns | 60 ns |
| 15 | AS, DS width negated | 40 ns | 60 ns |
| 22 | R/W low to DS asserted (write) | 75 ns | 90 ns |
| 26 | data-out valid to DS asserted | 15 ns | 30 ns |
| 44 | R/W low to DBEN asserted (write) | 15 ns | 30 ns |
| 45 | DBEN width asserted, read | 60 ns | 90 ns |
| 45 | DBEN width asserted, write | 120 ns | 150 ns |

Two of those have no slack to give away. Specification 46, R/W width valid, wants
150 ns and gets exactly 150 — S0 to the end of S5 is 2.5 clocks — and it is only
longer when the next cycle happens to go the same way. Specification 45's write
figure is 120 ns against 150. Neither is a problem at 16.67 MHz; both are worth
remembering if the state machine is ever shortened.

**This is not the AC-timing conformance analysis.** An RTL model has no pad delays,
so Section 10's 520 limits cannot be measured from it — they become a feasibility
question instead, and that is `make timing` in M3. What `bus_ruler_tb` checks is
the part that needs no pad delays: the distances between clock edges.

## The operand, not the bus cycle

The sequencer presents one request per **operand** and stalls until `req_ack`. The
bus unit owns the split into however many cycles Table 5-6 requires for that size,
that alignment and whatever port answers; it drives SIZ1/SIZ0 with the number of
bytes **remaining** (5.1.1, Table 5-2), routes the lanes per Tables 5-4 and 5-5, and
assembles the result. Nothing above this line knows how wide the port was.

Two things fall out of that and are checked:

- **OCS is correct for free.** 5.1.1 asserts ECS at the start of every bus cycle and
  OCS only at the start of the first cycle *of an operand* — and "operand" there is
  exactly this handshake. `bus_sizing_tb` counts one OCS per operand and one AS per
  bus cycle across all 48 combinations of size, alignment and port width.
- **The bus introduces no new condition into the microcode.** Because the split is
  invisible above the handshake, a microword issues exactly one request whatever
  the alignment, so nothing about dynamic bus sizing can reach the micro-address
  path. That property is what the MC68010 project's "only one condition may steer
  the bus" invariant becomes here, and it is why the split lives on this side.

`req_last` is combinational and true throughout S5 of an operand's final cycle: the
operand completes at the rising edge that ends S5, so the sequencer has **half a
clock** to present its next request. That half clock is the design's tightest path
by construction, and it is what the microword's successor previews exist to fill.
`fetch_last` is the same signal for the instruction fetch port — the prefetch source
needs it for the same reason, and without it a prefetch is issued twice.

## Dynamic bus sizing and misalignment

`sim/tb/bus_sizing_tb.sv` reproduces **every row of UM Table 5-6** — the number of
bus cycles for each operand size, each value of A1–A0 and each of the three port
widths — and checks the bytes moved in both directions, against slaves of 8, 16 and
32 bits written from 5.2.1 rather than from this design. 405 checks.

The manual's table has no row for a three-byte operand, because one only ever
arises as the residual of a misaligned long word. The counts this design gives for
it are in the testbench, marked as such.

`DSACK1` and `DSACK0` are captured by the same flop pair on the same edge and
decoded afterwards. Specification 31A allows 15 ns of skew between them at
16.67 MHz; sampling them independently would let a 32-bit port present transiently
as an 8-bit one, and the operand engine would assemble the wrong bytes with no
error anywhere.

## Known gaps at M1

| | |
|---|---|
| Bus exception control — BERR, retry, halt, double bus fault | M2 |
| Arbitration — BR, BG, BGACK, and RMC's inhibit of it | M2 |
| RMC held across a run of cycles | M2, with CAS/CAS2 in M10 |
| CPU-space cycles — interrupt and breakpoint acknowledge, coprocessor | M2, M10, M13 |
| The cycle aborted before AS on a cache hit | M11 |
| One idle clock between operands | see below |

**One idle clock between operands.** A new request is taken at the rising edge that
ends the previous operand only if the sequencer has already presented it, which is
what `req_last` is for. A source that instead waits for `req_ack` costs one clock
between operands. That is a cycle-count divergence and not a protocol one — the bus
cycles themselves are back to back within an operand, which is what Table 5-6
counts — and it will go away when the microcode drives the port through its
previews. It is recorded here so that the measurement in M12 is not a surprise.
