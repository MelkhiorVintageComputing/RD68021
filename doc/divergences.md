# Where this design does not behave as the part does

Every standing difference between RD68021 and a real MC68020, why it is there, and
how it is checked. Cycle-count differences live in `doc/timing-divergences.md`;
this file is for behaviour.

---

## The bus arbitration state machine has five states, not seven

**UM figure 5-44 draws seven. Two of them cannot be read from the manual.**

Each state bubble in that figure is labelled with its G and T outputs as an
overbarred pair, and the arc labels are overbarred pairs of R and A. The overbars
do not survive the PDF's text layer: every state's label extracts as the bare
string `GT` and every arc as `RA`, `XX`, `RX` or `XA`, with no way to tell which
letters were negated. State 0's outputs are known to be `G̅T̅` from the prose, and
they extract identically to state 1's `GT`. So the figure, as this repository can
read it, does not determine states 5 and 6 or any of the arcs.

What §5.7.1.4's prose *does* determine completely is the normal sequence, and it
is written out state by state:

> State 0 ... in which both G and T are negated, is the state of the bus arbiter
> while the processor is bus master. Request R and acknowledge A keep the arbiter
> in state 0 as long as they are both negated. When a request R is received, both
> grant G and signal T are asserted (in state 1 ...). The next clock causes a
> change to state 2 ... in which G and T are held. The bus arbiter remains in that
> state until acknowledge A is asserted or request R is negated. Once either
> occurs, the arbiter changes to the center state, state 3, and negates grant G.
> The next clock takes the arbiter to state 4 ... in which grant G remains negated
> and signal T remains asserted. With acknowledge A asserted, the arbiter remains
> in state 4 until A is negated or request R is again asserted. When A is negated,
> the arbiter returns to the original state, state 0, and negates signal T.

`rd68021_pkg::arb_state_e` is exactly those five states, with exactly those arcs.

The manual then says only: "Other states apply to other possible sequences of
combinations of R and A." One such sequence is named elsewhere and is implemented:
§5.7.1.3's "if another BR is still pending after the assertion of BGACK, another
BG is asserted within a few clocks of the negation of the first BG", together with
"the processor does not perform any external bus cycle before it reasserts BG" —
which is why state 4 returns to state 1, where T is still asserted, rather than
going through state 0.

**What could differ:** the number of clocks between one grant and the next in the
re-grant case, and the behaviour on R and A combinations that no correctly
behaving bus master produces — BGACK asserted without a grant, for instance.

**How it is checked:** `sim/tb/bus_arb_tb.sv` runs the documented sequence, the
RMC inhibit, a request arriving at each of sixteen phases of a multi-cycle
operand, and relinquish-and-retry. Resolving the two unknown states properly needs
a clean copy of figure 5-44 or a real MC68020.

---

## Format $A is emitted only for a prefetch fault

Table 6-5 gives the short bus fault frame for "Address Error or Bus Error —
Execution Unit at Instruction Boundary". A real MC68020's bus controller runs
ahead of its sequencer, so it can retire an instruction while that instruction's
write is still outstanding, and a *data* fault can then arrive with the execution
unit at an instruction boundary — a short frame for a data access.

**This design emits format `$A` only for a fault on a prefetch, and every data
fault produces format `$B`.** The microcode stalls on `req_ack`, so there is no
bus/sequencer concurrency in this phase and a data access always has an
instruction in progress.

**What could differ:** a handler that branches on the frame format rather than on
the SSW will see `$B` where a real part might have given it `$A`. The frame is
larger and carries strictly more information, so nothing a handler needs is
missing; it is 30 words more stack.

The manual licenses this explicitly, UM 6.4: "The system software should not
depend on a particular exception generating a particular stack frame. For
compatibility with future devices, the software should be able to handle any type
of stack frame for any type of exception."

**How it is checked:** the fault testbenches of M9, which assert the frame format
for each shape of fault.

---

## The cache holding register is not saved in a fault frame

UM 1.6's instruction pipe is fed from a 32-bit cache holding register. It is 64
bits of state once its address and validity are counted — a fifth of the long
frame's private budget.

**It is not checkpointed. RTE restores it as invalid, and the next prefetch
re-reads the long word.** It is a pure cache of the last long word fetched: the
cost of discarding it is one bus cycle after a fault and it can never give a wrong
answer, where keeping it costs 66 bits and adds a way for a restored pipe to
disagree with memory.

**What differs:** one extra bus cycle per RTE from a fault frame. Nothing
architectural.

**How it is checked:** `doc/timing-divergences.md` measures it when M12 measures
the cycle counts. `doc/checkpoint.md` records the budget it bought.

---

## The address group is released between bus cycles

Specification 7, "Clock High to Address, Data, FC, Size, RMC High Impedance",
measures the release at the end of every bus cycle, so that is what this design
does. `ADDR_HIZ_BETWEEN_CYCLES` keeps the group driven for a board that needs it.
This is a parameter rather than a divergence, but it is recorded here because a
system that relies on either behaviour should say which.

---

## One idle clock between operands, for a source that waits for req_ack

`req_last` is combinational and true throughout S5 of an operand's final cycle: the
operand completes at the rising edge that ends S5, and a source that presents its
next request within that half clock gets a back-to-back cycle. A source that
instead waits for `req_ack` costs one clock.

This is a cycle-count difference and not a protocol one — the cycles *within* an
operand are back to back, which is what UM Table 5-6 counts — and it goes away when
the microcode drives the port through its successor previews. Recorded so that the
measurement in M12 is not a surprise.

---

## Two write-data lanes the manual says are never used

UM Table 5-5 footnotes two cells "due to the current implementation, this byte is
output but never used": the D7–D0 lane of a three-byte transfer at A1A0 = 00, and
the D15–D8 lane of a three-byte transfer at A1A0 = 11 and of a long word at
A1A0 = 11. Table 5-7 confirms that no port enables those lanes for those transfers.

The first of them names an operand byte that is not among the bytes still to be
sent, so this design drives the most significant one that is. The other two are
driven as the table names them. Nothing can observe the difference, and if
something did, it would be observing a byte the manual says is meaningless.
