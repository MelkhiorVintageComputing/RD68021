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

---

## M5 · The request handshake, three times over

**What:** the same rule, missed in three places, and worth one entry because the
third only became obvious once the first two had been found.

The bus unit accepts a new request **on the very edge the previous operand
finishes** — that is what makes back-to-back cycles possible at all. So a source
must drop its request by that edge, and `req_last` / `fetch_last` are the
combinational signals that say the edge is coming. But the acknowledge is
*registered*, so the request is also still asserted for one clock after it, when
the `*_last` signal has gone back low. Both terms are needed:

```systemverilog
assign req_valid   = bus_req       && !req_last   && !req_ack;
assign fetch_valid = fetch_pend_q  && !fetch_last && !fetch_ack;
```

Miss `*_last` and the operand runs twice back to back; miss `*_ack` and it runs
twice with a clock between. M1 found the first half on the fetch port, with a
prefetch that reported zero bus cycles. M5 found the other half twice: the reset
vector came back as the stack pointer *twice*, because the read of `$0` ran again
while the microword that consumed it was still waiting to advance; and the pipe
was served words from the wrong address, because the duplicate prefetch's data
arrived labelled with wherever the queue had got to by then.

**Found by:** the first by a bus-cycle count, the second by the wrong value in a
register, the third by a trace of the instruction stream that showed the same two
words being decoded over and over.

**Stops it coming back:** `core_fetch_tb` runs a program whose branches skip
instructions that would be visible if executed, so a pipe fed from the wrong
place changes the answer rather than merely the timing.

---

## M5 · The read data was destroyed by the pipe refilling itself

**What:** the bus unit kept the completed read in `op_data`, the accumulator of
the operand in flight. The instruction fetch unit refills the pipe by itself, so
a prefetch starting in the clock after a data read overwrote the data before the
sequencer had read it. The reset sequence flushed the pipe to the *stack pointer*
value rather than the program counter, and ran from there.

**Fixed by:** `rdata_q` and `frdata_q` — one latch per kind of operand, each
holding its result until the next operand of that kind completes.

**Stops it coming back:** the reset sequence itself. Every run of `core_fetch_tb`
reads two vectors and flushes to the second, and the program only runs at all if
the second survived the prefetch that follows it.

---

## M5 · A microword that both flushed the pipe and decoded deadlocked

**What:** the natural way to write a branch is one microword that computes the
target, flushes the pipe to it and decodes what arrives. It hangs: the pipe
operation is gated on the microword retiring, and a DECODE stalls the microword
until stage D is valid — which is what the flush has just made false. The flush
never happens, so the stall never lifts.

**Fixed by:** a rule, written at the top of `tools/ucode/program.py`: a microword
may not both FLUSH and DECODE. Every branch is a flush and then a separate
decode.

---

## M5 · The decoder looked at the instruction that had just finished

**What:** an instruction ends with one microword that advances the pipe and
decodes. The decoder was wired to stage D — which at that instant still holds the
opcode that is finishing, because the advance that replaces it has not happened
yet. Every instruction decoded itself a second time.

**Fixed by:** the decoder reads stage C when the microword also advances, and
stage D otherwise. Stage C is the word the advance is about to move into D, which
is what "decoded when it reaches stage D" means when both happen in one clock.

---

## M5 · The cache holding register was labelled with the wrong address

**What:** `fetch_addr` was combinational from `fill_q`, the address the pipe wants
next. The queue drains while a fetch is in flight, so by the time the long word
came back, `fill_q` had moved on — and the cache holding register recorded *that*
address against the data it had just received. It then answered a hit for an
address it did not hold, and the pipe was served instruction words from somewhere
else.

**Found by:** a clock-by-clock dump showing the holding register's address change
while its contents did not.

**Fixed by:** latching the address when the fetch is issued, and using that
register both to drive the bus and to label the result.

---

## M5 · A branch test that branched over nothing

**What:** not a defect in the design. `core_fetch_tb` tested both shapes of BRA by
branching over a NOP. Mutating the microcode so that the branch base was the
instruction's own address rather than its address plus two — a real error, and one
of the two the branch microcode can make — left the test passing: the branch
landed one instruction short, on the NOP, and everything after it was the same.

**Fixed by:** branching over instructions that would be *visible* if they ran —
`MOVEQ` into registers nothing else touches, checked to be still zero. The
mutation now fails on two of the three port widths.

---

## M6 · Turning off the cores we do not want turned the oracle into a 68000

**What:** the worst kind of defect in a test: one that makes the oracle agree
with a wrong answer, or disagree with a right one, for a reason that has nothing
to do with the design.

`tools/cosim/m68kconf.h` started as a copy of Musashi's with the emulations this
project does not want switched off — the 68010, the EC020, the 68030, the 68040
and the PMMU. That looks like it should make the oracle more trustworthy: only
the MC68020 is built, so a disagreement cannot be blamed on the wrong core being
selected.

It does the opposite. Musashi's CPU-type predicates are **chained**:

```c
#if M68K_EMULATE_010 ... #else
    #define CPU_TYPE_IS_010_LESS(A)  CPU_TYPE_IS_EC020_LESS(A)
#endif
#if M68K_EMULATE_EC020 ... #else
    #define CPU_TYPE_IS_EC020_LESS(A)  CPU_TYPE_IS_020_LESS(A)
#endif
```

and `CPU_TYPE_IS_020_LESS` **includes the 68020**. With both switches off,
`CPU_TYPE_IS_010_LESS(CPU_TYPE_020)` is true — and the first line of
`m68ki_get_ea_ix` is

```c
if(CPU_TYPE_IS_010_LESS(CPU_TYPE)) {
        ...
        return An + Xn + MAKE_INT_8(extension);   /* no SCALE, no full format */
}
```

So the oracle silently ignored the brief extension word's scale factor and the
full extension word entirely — for the one calculation this milestone exists to
check. It reported 391 disagreements, all of them the oracle's.

**Found by:** working out by hand what the answer should be for one failing
vector, and finding that the *core* was right.

**Fixed by:** `tools/cosim/m68kconf.h` is now an unmodified copy, with a comment
at the top saying why nothing in it may be switched off without working out what
else that switches.

**Stops it coming back:** the comment, and the sweep itself — the scaled-index
vectors are the ones that fail if the oracle reverts to a 68000, and there are
512 of them.

---

## M6 · The testbench released reset on the edge the design samples

**What:** `reset_dut()` in `sim/tb/rd68021_core_harness.svh` deasserted `rst_n` on
a rising edge — the same edge on which every register in the design takes its
reset value. Both are non-blocking assignments scheduled for the same time step,
so whether the core saw one more reset cycle or none was decided by the order two
`always` blocks happened to be evaluated in.

The symptom was that the first vector of a sweep behaved differently from the
same vector replayed later, and that **adding a `$display` to the harness made it
go away** — the classic shape of a scheduling race, since the extra statement
changed nothing but the order.

**Found by:** a test that passed and failed on alternate runs of the same binary
after an unrelated edit to a print statement.

**Fixed by:** reset is released on a **falling** edge. Nothing in the design
samples `rst_n` there, so the release is unambiguous and the first rising edge
after it is a normal clock.

**Stops it coming back:** the rule is in `doc/coding-standard.md` — a testbench
changes an input the design samples on a rising edge only on a falling edge.

---

## M6 · Three defects in the oracle generator, each of which faked a design bug

**What:** `tools/cosim/musashi_ea.c` and its replay produced wrong *questions*,
not wrong answers, three times running. All three are worth naming because each
one presented as a plausible RTL bug.

1. **The extension-word patterns were off by one character.** The pattern string
   is the program-counter base bit followed by bits 15 down to 0, so bit *N* is at
   index *16 − N*. Written out by hand, the format bit landed on bit 7 instead of
   bit 8, so every brief extension word was decoded as a full one. Fixed by
   building the patterns from `_brief()` and `_fullpat()` helpers that take the
   bit *numbers*, so the arithmetic is written once.

2. **`tests[512]` with 670 tests.** The generator overran its array and corrupted
   the tail of the vector file, which appeared as a run of failures at the end of
   the sweep — exactly where a real bug in the last-written microcode would be.
   Fixed with `MAXTESTS 2048` and a bounds check that aborts rather than writes.

3. **Full-extension cases built with mode 010.** `(An)` takes no extension word,
   so the generator emitted an opcode whose extension words were never read as
   extension words. Fixed to modes 6 and 7/3, which do.

**Stops it coming back:** the generator now prints the mode and extension-word
shape it intended alongside each vector, so a vector that does not exercise what
it claims to is visible in the file rather than only in the failure.

---

## M6 · Memory that is X in the model and zero in the oracle

**What:** Musashi's memory is a calloc'd array, so every address the vectors do
not write reads back as zero. The testbench slaves are RTL and read back `x`.
Memory-indirect addressing modes *read* memory to compute the address, so the
core's effective address became `x` wherever the oracle's became zero — a
mismatch on every memory-indirect vector, and a mismatch whose message named the
right microcode routine.

The slaves were also 8 KB, so the 64 KB address space wrapped and the data area
aliased onto the vector table, which corrupted the two vectors the reset
exception reads.

**Fixed by:** `ABITS 16` on all three slaves, and `core_ea_tb` zero-fills 64 KB
of every slave before it deposits a vector — the model's memory now starts where
the oracle's starts.

---

## M6 · The full extension word's routines could not tell An from the PC

**What:** the 33 vectors that failed after every defect above was fixed were all
`LEA (PC,Xn,...),A0` with a **full** extension word — mode 111/011. The core used
`A3` as the base where the PC belonged.

The base register is named by the **opcode**, not by the extension word, so the
only microword that knows it is the one that dispatches on the extension word's
shape with `seq = EADEC`. For the brief format that is harmless, because there is
one routine per base (`eab_an`, `eab_pc`). For the full format the twenty-one
routines are deliberately **shared** between the two bases — the full extension
word behaves identically either way (PRM 2.5), and duplicating them would double
the table to carry one bit. So `EABASE` read `` `UF(EAPC) `` out of a microword
that had no reason to set it, found zero, and took the address-register branch.

The arithmetic confirms it exactly. Vector 615, `41fb 8925 0040` — postindexed,
word base displacement, null outer displacement:

| | base | reads | result |
|---|---|---|---|
| Musashi | PC = `$1002` | `M($1042)` = 0 | `0 + A0` = `$2100` |
| this core | A3 = `$21C0` | `M($2200)` = `$3200` | `$3200 + A0` = `$5300` |

**Fixed by:** `eapc_q` in `rd68021_seq.sv`, latched when a `seq = EADEC` microword
retires and read by `EABASE`. One bit, against twenty-one duplicated routines.

**Stops it coming back:** the sweep covers both bases for every full-extension
shape, so the routine can no longer be shared without the bit being carried.

---

## M6 · Two sequencer registers were outside the frozen checkpoint set

**What:** found while fixing the one above. `doc/checkpoint.md` rule 3 is
"every register an instruction accumulates has a home here or it does not
exist", and `check_checkpoint` enforces it — but only over microword
**destinations**. `link_q` is written by the `call` bit and `eapc_q` by the
`seq` field, so neither is a `dst`, and both were invisible to the check while
being exactly the per-instruction state the rule is about.

The consequence would have surfaced first in M9, and as a very expensive bug: a
bus fault taken inside an effective-address subroutine saves `upc` in the frame
and restores it, so RTE resumes in the right routine — and then `seq = RET`
returns to wherever `link_q` last pointed, which after a handler that ran its own
instructions is arbitrary. The failure is a wild jump on a demand-paged access,
reproducible only under a fault, and nothing before M9 would have shown it.

**Fixed by:** `link` at `+$44` and `eapc` at `+$08` bit 6 in `frames.py`, both in
`CHECKPOINT`. The set now uses 296 of 492 bits with 11 internal words spare.

**Stops it coming back:** this is the second time the checkpoint discipline has
been saved by an unrelated investigation rather than by its own check, which is
one time too many. `check_checkpoint` needs to be driven from the *register*
list in `rd68021_seq.sv` rather than from the microword destinations — recorded
as the first thing to do in M8, where the register file stops growing.

---

## M6 · The access recorder counted bus cycles where the oracle counts operands

**What:** with the base fixed, the last failures were not wrong addresses but
wrong *counts* — "Musashi made 1 data accesses, this core made 2".

Both were right. The vector reads a long word at an address ending in `10`, and
table 5-6 splits that into **two** bus cycles on a 32-bit port. The recorder
triggered on the falling edge of `AS`, so it saw two. An interpreter has no bus
at all and reports the operand, so it saw one. Comparing them compares two
different quantities, and it would have gone on being wrong for every misaligned
access in every later milestone.

This is the operand-not-cycle contract showing up in the *testbench* rather than
in the design — the same distinction the sequencer/BIU interface is built on,
missed one level up.

**Fixed by:** UM 5.1.1 draws exactly this line in hardware: `ECS` marks every bus
cycle, `OCS` only the first cycle of an operand. The recorder triggers on `OCS`,
so nothing is inferred from addresses and the comparison is operand against
operand. It also means the sweep now checks `OCS`, which no testbench did before.

**A note on how it is sampled:** `OCS` is asserted for the half clock of S0
only, so there is no clock edge inside it. The harness samples a quarter period
after the rising edge that starts S0 — settled, and nowhere near an edge on which
the bus unit changes state. A delay is legitimate in a testbench and would not be
in the design.

---

## M6 · The oracle's memory and the testbench's disagreed by one word

**What:** the oracle writes a `NOP` after the instruction; the testbench wrote
`BRA.S *` to park the core. Everywhere else the two memories matched, and for
every addressing mode that does not read memory it made no difference.

Memory-indirect modes read memory to *build* an address, and nothing stops one
reading the word just after the instruction. Vector 608, `41fb 8915 0000` — a
null base displacement, so the indirect read is at the extension word itself:

| | reads | result |
|---|---|---|
| Musashi | `M($1002)` = `$8915_4E71` | `+ A0` = `$8915_6F71` |
| this core | `M($1002)` = `$8915_60FE` | `+ A0` = `$8915_81FE` |

Both cores were correct about their own memory. Only the question differed.

**Fixed by:** the testbench writes the same `NOP`. It did not need the park:
`run_until` stops the core at that address, so it is never executed.

**The general rule this is an instance of:** an oracle comparison is only as good
as the *initial state* the two sides share, and initial state includes every byte
either side can reach — not just the ones the test meant to set up. The sweep
zero-fills all of memory for the same reason.

---

## M6 · Every operand was read from data space, including the ones that are not

**What:** found by reading PRM section 2 to settle an unrelated question about
the oracle. The first page of it says, of the program and data address spaces:

> Program space is the section of memory that contains the program instructions
> and any immediate data operands residing in the instruction stream. ... **Data
> items in the instruction stream can be accessed with the program counter
> relative addressing modes; these accesses classify as program references.**

and each PC-relative mode repeats it: "This is a program reference allowed only
for reads."

Every bus request this core made for an operand carried `fc = DATA`. That is
wrong for all four program-counter-relative modes -- `(d16,PC)`, `(d8,PC,Xn)`,
`(bd,PC,Xn)` and the two memory-indirect PC forms -- and wrong for the memory
indirection inside them as well.

It is invisible to a flat memory and fatal to a mapped one: FC2-FC0 are pins,
and an MMU that maps program and data space differently -- which is exactly what
the Sun-3 this project is aimed at does -- faults or fetches the wrong page. No
register comparison would ever have shown it.

**Fixed by:** `fc = PROG` on the operand read of the two PC-relative MOVE.L
modes, and a fourth value of the microword's `fc` field, `EASP`, for the
memory-indirect read inside a full extension word. `EASP` resolves to program or
data space from `eapc_q` -- the same latched bit that chooses the base, for the
same reason: the twenty-one full-extension routines are shared between the two
bases, so the space cannot be written into the microword either.

The classification follows the **mode**, not whether the program counter was
actually added: PRM's ZPC notation suppresses the base and says the point of it
is "to access the program space without using the PC in calculating the
effective address", so a base-suppressed PC-relative mode is still a program
reference. `eapc_q` is set from the mode, so this falls out.

**Stops it coming back:** the sweep now compares the **space** of every access,
not just its address, and it has MOVE.L vectors in both PC-relative modes.

---

## M6 · The reset vectors were read from data space

**What:** the same paragraph, two sentences later, and a separate bug:

> All exception vectors are located in supervisor data space, **except the reset
> vector, which is located in supervisor program space.**

The reset microcode read both long words with `fc = DATA`.

Same consequence, and worse timing: it is the first two bus cycles the processor
ever runs, so on a machine that maps the two spaces differently the core would
fail to boot at all and every later test would be meaningless.

**Fixed by:** `fc = PROG` on both, with the sentence quoted on the line above
them.

**Worth noting:** this one is not reachable by any oracle the project has. An
interpreter has no function code pins and QEMU's Sun-3 model has not been run
yet. It was found by reading the manual, which is the only thing that could have
found it -- and it is the second time in this milestone that reading the manual
to answer a different question turned up a real bug.

---

## M6 · Musashi cannot compile with separate reads and the PMMU together

**What:** not our defect, but ours to work around. `M68K_SEPARATE_READS` is the
switch that makes Musashi say which of its reads are instruction stream and
which are operands -- the only way to build the access list the sweep compares.
Turning it on does not compile:

```
m68kcpu.h:1064:13: error: 'address' undeclared (first use in this function)
m68kcpu.h:1099:13: error: 'address' undeclared (first use in this function)
```

`m68ki_read_imm_16` and `m68ki_read_imm_32` contain a PMMU translation guarded by
`#if M68K_SEPARATE_READS` / `#if M68K_EMULATE_PMMU`, and neither function has an
`address` variable. The combination has never been built.

**Fixed by:** `M68K_EMULATE_PMMU` off in `tools/cosim/m68kconf.h`. Unlike the
`M68K_EMULATE_*` core switches, this one can be *shown* to be harmless rather
than assumed to be: `PMMU_ENABLED` is `m68ki_cpu.pmmu_enabled`, a run-time flag
only the PMMU instructions set, so every site it guards is already `if (0)` in a
run that never executes one; and it feeds no `CPU_TYPE_IS_*` predicate. What
changes is that PMOVE and its relatives become F-line traps, which is what an
MC68020 with no MC68851 attached does with them.

`Inputs/` is immutable, so repairing Musashi was never an option. Both switches
are written up at the top of `tools/cosim/m68kconf.h` with the reasoning, which
is the rule the earlier oracle bug left behind.

---

## M6 · A microword field in a port connection became two implicit nets

**What:** the extension-word decoder is instantiated with the microword's
program-counter-base bit on one of its ports:

```systemverilog
rd68021_eadec_rom u_eadec (.pc_base (`UF(EAPC)), ...);
```

`` `UF(f) `` expands to `uw[rd68021_ucode_pkg::U_``f``_LSB +: rd68021_ucode_pkg::U_``f``_W]``.
The same macro is used everywhere else in the file and is fine. In a **port
connection** Quartus does not resolve the package scope:

```
Warning (10236): created implicit net for "U_EAPC_LSB"
Warning (10236): created implicit net for "U_EAPC_W"
```

so the part-select's bounds became two undriven one-bit wires and the decoder
was addressed with something other than the microword bit. **Exit code zero**,
and iverilog, Verilator, yosys, Vivado and Questa all accepted the line: five
front-ends green and one netlist wrong.

**Found by:** `make lint-quartus`, which promotes `Warning (10236)` to a failure
for exactly this reason. It is the gate RD68011 built after the same class of
defect, and it earned its place again here.

**Fixed by:** a named signal, `ea_pc_base`, assigned from the macro and passed to
the port — the shape `dec_ir` already had one instantiation above.

**Stops it coming back:** the gate, and a row in `doc/coding-standard.md`. Worth
saying plainly what this one demonstrates: the value of the Quartus gate is not
that Quartus is a target, it is that Quartus disagrees with the others about
something that has no diagnostic in them at all.
