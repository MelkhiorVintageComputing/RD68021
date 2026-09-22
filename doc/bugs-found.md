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

---

## M7 · The first instruction after a reset was never executed by the oracle

**What:** the worst kind of oracle defect again, and this one was already in the
M6 sweep without showing.

`m68k_pulse_reset()` leaves `RESET_CYCLES` set, and `m68k_execute` spends its
whole budget on those **before it looks at an instruction**:

```c
int m68k_execute(int num_cycles)
{
    if (RESET_CYCLES) {
        int rc = RESET_CYCLES;
        RESET_CYCLES = 0;
        num_cycles -= rc;
        if (num_cycles <= 0)
            return rc;          /* nothing ran */
    }
```

So `m68k_execute(1)` immediately after a reset returns having run nothing, and
the "after" state recorded for that test is its "before" state.

In the new sweep, which resets per test, **every** vector was affected and the
symptom was obvious: MOVEQ #1,D0 left D0 alone and the program counter at
`$1000`. In `make ea`, which resets once, it silently spoiled exactly one vector
-- number 0, which is `LEA (A0),A0`. That is idempotent, so it passed anyway and
703 of 703 was a true number reached partly by luck.

**Fixed by:** `m68k_execute(0)` after every reset, which absorbs the reset cycles
and executes nothing, in both `tools/vectors/gen.c` and `tools/cosim/musashi_ea.c`.

**Worth saying:** the M6 sweep was green with a defect in it. What found the
defect was a *different* test built on the same oracle, which is the argument
for the plan's four independent oracles rather than one good one.

---

## M7 · Every byte and word operand stepped its address register by four

**What:** `(An)+` and `-(An)` step the register by the operand size. The two
routines are shared by every instruction that uses those modes, and instructions
encode their size in different bits -- bits 7:6 for most, 8:6 for the ALU line,
13:12 for MOVE -- so a shared routine cannot name a selector of its own. Until
M7 every caller was a long-word instruction and the routines used their own
`size` field, which was `LONG`. A comment in `program.py` said so and said what
would have to change.

`MOVE.B (A2)+,D1` then stepped A2 by four and read the wrong byte.

**Fixed by:** `szsel = LATCHED`, a two-bit register the dispatching microword
writes with the size it resolved. It is per-instruction state, so it has a
checkpoint slot at `+$08` bits 8:7, which is the discipline working as intended
rather than an afterthought.

**Found by:** the sweep, on its first run, in 234 vectors at once.

---

## M7 · SUBX had its operands the wrong way round

**What:** `SUBX Dy,Dx` is *Dx minus Dy minus X*. The microcode read the register
named by bits 2:0 into the A side and the one named by bits 11:9 into the B
side, which computes Dy minus Dx.

It was written as one helper shared with ADDX, where the order does not matter
because addition commutes -- so the shared code was right for one of the two
instructions it served and wrong for the other, and the ADDX vectors passed.

**Found by:** three vectors of `SUBX.B D5,D2`. Working the arithmetic by hand is
what identified it: D2 held `$...08b2`, D5 `$...081b`, X was clear, and the core
produced `$69` where the oracle produced `$97` -- and `$69` is exactly
`($1b - $b2) & $ff`.

**Stops it coming back:** the sweep has both instructions at all three sizes in
both forms, and the register form is now written out with a comment saying why
it is not shared.

---

## M7 · A program-counter-relative instruction's WRITE is not a program reference

**What:** the correction M6 made to the oracle -- "this instruction's mode is
PC-relative, so its accesses are program references" -- was applied to every
access the instruction made. That is right for the reads, which is all LEA and
`MOVE <ea>,Dn` make, and wrong as soon as an instruction with a PC-relative
source also writes something.

`PEA (d16,PC)` is the case: the address it computes is a program reference, and
the long word it pushes is an ordinary data write to the stack. The core had it
right and the oracle did not.

**Fixed by:** the override applies to reads only. PRM 2 supports exactly that --
every PC-relative mode is described as "a program reference allowed only for
reads", so an instruction that writes is writing somewhere else by construction.

---

## M7 · The rotates only ever rotated left

**What:** `rd68021_shifter.sv` builds two rings, one of the operand and one of
the operand with X in it, and rotates both **left**. A right rotation is a left
one by the complement of the count -- and the `left` input was never used for
either kind, so ROL and ROXL passed and ROR and ROXR silently rotated the wrong
way.

Three-hundred and seventy-eight vectors, and the shape of the failure is worth
recording: `ROXR.B #1,D4` produced a result that looked like a plausible rotate,
because it *was* a plausible rotate, of the wrong sign.

**Fixed by:** four lines.

```systemverilog
assign rot_amt = left ? rot_n : ((rot_n == 6'd0) ? 6'd0 : (w - rot_n));
assign rox_amt = left ? rox_n : ((rox_n == 6'd0) ? 6'd0 : ((w + 6'd1) - rox_n));
```

The zero cases are not decoration: `opw >> (w - 0)` is a shift by the width,
which is zero for a byte and a word and undefined-looking for a long, and the
complement of a zero rotation is a zero rotation and not a whole turn.

**Worth saying:** writing two rotators would have been the obvious way to do
this and would have cost twice the logic on a unit that is already one of the
widest things in the design. The cheap version was right; not writing the
complement at all was the bug.

---

## M7 · The static bit instructions took their bit number for a displacement

**What:** `BTST #0,(8,A6)` read at A6 instead of at A6+8, and `BTST #0,($2100).W`
read at address 0.

A static bit instruction carries its bit number in the word after the opcode,
and the effective address's extension words come **after** that. The microcode
computed the address first and consumed the bit number last, so the address
routine found the bit-number word sitting in stage C and took it for its
displacement. `BTST #14,(8,A6)` read six bytes past where it should, which is
exactly 14 minus 8.

The register forms were fine, which is why it took a sweep to find: there the
bit number is the only extension word there is.

**Fixed by:** the static forms latch the bit number into `xw` first, with a
CONSUME, and the mask generator reads the latch rather than stage C. Two
microwords fewer, as it happens, because the consume is no longer a separate
step at the end.

**The general shape of it:** stage C is a *position*, not a register. Anything
that has to outlive a pipe advance goes in `xw` -- which is rule 3 of
`doc/checkpoint.md`, written in M4 for exactly this reason and not applied here
until the sweep insisted.

---

## M7 · A false combinational loop through the multiplier

**What:** `MULLO` and `MULHI` are A-bus sources, and the multiplier was fed from
the A bus. That closes a loop: `a_bus` to `mul_a` to `mul_full` back to `a_bus`.

It is a false loop -- only one arm of the source mux is ever selected -- but it
is a real one structurally, and Verilator refuses it with UNOPTFLAT.

**Fixed by:** the multiplier and the divider take their operands from T0, T1,
T2 and T3 rather than from the buses. The microcode puts them there, which it
was doing anyway.

**Worth saying:** the same trap is waiting for every unit whose result is a
source. The divider was written the same way and was saved only by having
registered outputs; it has been changed too, so that the rule is uniform rather
than accidental.

---

## M7 · A bus request went out before the microword that made it was ready

**What:** the most valuable find of the milestone, and not a bug in any
instruction.

`JSR (8,A6)` pushed the address of its own displacement word instead of the
address of the next instruction. So did `BSR.W` and `BSR.L`. `JSR (A1)` and
`BSR.B` were right, which is the shape of the clue: only the forms with an
extension word were wrong.

The push reads `PC_C`, the address of the word in pipe stage C. After the
address routine has eaten the displacement, that is the next instruction -- but
only once the pipe has refilled, because `PC_C` is derived as `stg_b_addr - 2`
and `stg_b_addr` does not move until a word arrives. The microword knew this:
`needs_c` includes the `PC_C` source, so it **stalled** until the pipe was ready.

It stalled, and the write had already gone out.

```systemverilog
assign req_valid = bus_req && !req_last && !req_ack;   // wrong
```

`req_valid` was gated on the bus alone. The bus unit takes an operand the moment
it can and latches its address and its write data then -- so a microword that
asks for a bus cycle *and* reads something not yet valid presents the stale
value, and the stall it is doing for exactly that reason comes too late to help.

A trace of one instruction is what settled it:

```
  upc=558 stg_b_addr=00001004 cnt=0    retire=0   <- the write is already out
  upc=558 stg_b_addr=00001006 cnt=1    retire=0
  upc=558 stg_b_addr=00001006 cnt=2    retire=1   <- PC_C is right only now
```

**Fixed by:** splitting the stall in two. `other_stall` is everything a
microword waits for except the bus, and the request is not presented while it
holds:

```systemverilog
assign req_valid = bus_req && !other_stall && !req_last && !req_ack;
```

**Why it matters beyond JSR:** the class is "a bus request issued with operands
that are not yet valid", and every later milestone adds microwords that both
request a cycle and read something conditional -- the fault frames of M9 most of
all, where a wrong address written to a stack is not a wrong answer but a
corrupted kernel. It would not have been found by looking at the instruction,
because the instruction was right.

**Also fixed, and separate:** BSR.W and BSR.L never consumed their displacement
at all -- the flush would eat it -- so `PC_C` named the displacement even with
the gating fixed. The consume looks redundant and is not, because the return
address is read between the consume and the flush.

---

## M7 · A flush abandoned a prefetch, and the next one took its answer

**What:** the bug a program finds and a sweep cannot.

`make cosim` ran eight instructions of the C runtime's `.bss` clear before the
core and Musashi disagreed, and the divergence was not in the instruction that
failed. Stage D held `$0000` where `$10FC` belonged, and the cache holding
register was carrying a long word from `$12CC` with `$12C0` written on it:

```
t=5700000 chr=4eb90000 chra=000012c0 fill=000012c2 push=1
```

A taken branch flushes the pipe. The flush cleared `fetch_pend_q` -- withdrawing
the prefetch request -- but the bus unit had already **taken** that operand and
there is no way to call it back. It finished the cycle, pulsed `fetch_ack`, and
the IFU, which by then had issued a request for the new stream, accepted that
answer as its own. A word from the abandoned instruction stream went into the
pipe with the new stream's address on it.

Every taken branch was a chance to execute one instruction from the wrong place.

**Fixed by:** not withdrawing. The request is left standing and the WORD is
thrown away when it arrives:

```systemverilog
discard_q <= fetch_pend_q && !fetch_ack;   // on flush
...
if (fetch_ack) begin
  fetch_pend_q <= 1'b0;
  discard_q    <= 1'b0;
  if (!discard_q) begin chr_q <= fetch_rdata; ... end
end
```

It costs one bus cycle per taken branch, which `doc/timing-divergences.md` will
measure. A real MC68020 does better with the ECS-aborted cycle of UM 5.2.5,
which is M11's business.

**Why the sweep could not find it:** the per-opcode sweep runs ONE instruction.
The branch it tests is correct -- the program counter comes out right, which is
all a single-instruction comparison can look at. What is wrong is the
*instruction after* the branch, and there isn't one.

---

## M7 · MOVEM stored a zero in place of its first register

**What:** eleven of twelve registers stored correctly and the first stored zero.

```
   0: write 4 bytes at 0000123c of 00000000      <- D0 is 9abe0400
   1: write 4 bytes at 00001240 of 80900002      <- D1, correct
   2: write 4 bytes at 00001244 of 0000119c      <- D2, correct
```

The register MOVEM's counter names was read through a function:

```systemverilog
function automatic logic [31:0] reg_read(input logic [3:0] n);
  if (!n[3]) reg_read = dreg[n[2:0]]; ...
endfunction
assign regn_val = reg_read(regn);
```

A function that reads module state, called from a continuous assignment, is
re-evaluated when its ARGUMENTS change -- not when the state it reads does.
MOVEM's first register is number zero and the index never changes from the value
it starts at, so the read of D0 was never re-evaluated and kept the value it had
at time zero. Every other register came out right because its index moved.

**Fixed by:** writing the mux out twice, in `always_comb`.

**What makes this one worth reading twice:** the rule was already in
`doc/coding-standard.md`, written before any of this existed, with the reason
given. It is row two of the table. Having the rule written down did not stop it
being broken, and what caught it was a program -- not the lint, not the sweep,
and not the person who wrote the rule.

---

## M7 · The harness lost an instruction boundary to its own settle edge

**What:** not a defect in the design. `step_one` waits for the microword that
ends an instruction, and then waited one more falling edge so that the
non-blocking writes would have landed before anything was compared.

A one-microword instruction following another retires on exactly that edge. So
the settle edge landed ON the next boundary, and the next call to `step_one`
stepped past it -- the core ran one instruction more than the comparison
thought, and every register afterwards was compared against the wrong entry.

It took 1652 instructions of a real program to line up: a `MOVEQ` immediately
after a `MOVE`, in the middle of a loop that had already run correctly.

**Fixed by:** waiting for the RISING edge that commits the writes, and a quarter
period, and no further.

**Stops it coming back:** the reasoning is in the comment above the task, which
is where someone tempted to add another edge will read it.

---

## M7 · The decimal adjust was done digit by digit, and cannot be

**What:** ABCD, SBCD and NBCD were written the way the operation is usually
explained -- correct the low digit, carry into the high one, correct that:

```systemverilog
lo = a[3:0] + b[3:0] + X;
if (lo > 9) begin lo = lo + 6; carry = 1; end
hi = a[7:4] + b[7:4] + carry;
```

It is right for every valid operand and wrong as soon as a digit is greater than
nine. A low-digit sum of twenty-seven plus six is thirty-three -- **two** tens
into the digit above -- and a one-bit carry cannot say so.

`ABCD` of $3E and $4C with X set: this core gave $81 where the whole-byte
correction gives $91.

**Fixed by:** doing the arithmetic on the byte and correcting the byte:

```
    add:       sum = a + b + X;  if the low digits passed nine, add six;
               then if the byte passed $99, subtract $A0 and carry.
```

which is the textbook decimal adjust and is what "store the result in
binary-coded decimal form" means.

**Worth saying:** the digit-by-digit form is not a simplification of the
whole-byte one, it is a different function -- and the two agree on exactly the
inputs the instruction is defined for. `make cosim` ran ABCD and SBCD with valid
digits and passed; it was the sweep, throwing random bytes at them, that found
it. Which is the argument for having both.

---

## M7 · The two sides of the sweep filled memory differently

**What:** with the decimal instructions restricted to decimal operands, half the
sweep still failed -- and the arithmetic was right. Working one case by hand:
the destination byte should have been $80 and the source $70, which gives $10,
and the core produced $04 from operands it had been given and the oracle had
not.

Both sides compute the memory fill independently from the test index -- that is
the point, so that neither has to send the other a copy. The reduction to
decimal digits was added to both, and one of them was wrong:

```c
out |= ((((b >> 4) % 10u) << 4) | (b % 10u)) << (i * 8);
```

`b % 10` takes the whole BYTE modulo ten, not the low nibble. $7C became $74 in
the generator and $72 in the testbench, and every byte with a low digit above
nine differed.

**Found by:** running the two conversions side by side on the same input, in
eleven lines of iverilog and eleven of Python, rather than reading them again.

**The general point:** any value computed independently on both sides of an
oracle comparison is a second implementation, and it can disagree. The fill was
chosen to be two multiplications and an exclusive or precisely because that is
hard to get wrong in two languages; the moment something less trivial was added
to it, it was got wrong.

---

## M7 · Moving the vector table switched off the check that found traps

**What:** the sweep drops any test whose oracle run took an exception, because
exception processing is M8. It recognises one by the addresses the instruction
touched: anything inside the vector table is a vector fetch and nothing else.

Establishing the control registers per test -- which the MOVEC vectors needed,
because UM 6.1.1 does not say what reset leaves in them -- set VBR to `$A000`.
The vector table moved with it, the check was still looking below `$400`, and
**nothing was dropped any more**:

```
  vectors: 7806 tests, 0 dropped     (it had been 82)
```

CHK's trapping cases came straight back in, and eighty of them hung the core on
the microword that stands in for the exception until M8 builds it.

**Fixed by:** two things, because one of them would have been enough and the
other is what stops it recurring.

VBR is set to **zero**, deliberately: UM 6.1.1 step 4 initialises it to zero, so
it is the one control register that does not need establishing. And the check
now reads

```c
if (acc[j].addr >= t->ivbr && acc[j].addr < t->ivbr + 0x400) trapped = 1;
```

against the test's own VBR, so that moving the table cannot silently switch it
off again.

**What made it visible:** the generator prints how many tests it dropped, on
every run. A count that had been 82 for a dozen runs became 0, and that is a
louder signal than eighty failures -- the failures said CHK was broken, and the
count said the test was.

---

## M7 · Three front-ends accepted what three refused

**What:** everything passed -- the sweep, the programs, `make check` -- and then
Quartus, Questa and Vivado all refused the same file for two reasons that
iverilog, Verilator and yosys had not mentioned.

**Used before declared.** The datapath's source multiplexers read the register
MOVEM walks, the control registers, the multiplier and the divider, and every
one of those is produced further down the file. Quartus makes an implicit net
of each and builds a netlist that does not match the source, with a zero exit
code; Vivado's `[Synth 8-6901]` says so; Questa refuses outright with
`Undefined variable`. Fixed by declaring them above the multiplexers and
driving them where they belong.

**A package-scoped name in a port connection**, again:

```systemverilog
.x_in (sr_q[rd68021_pkg::SR_X])
```

Quartus reads `SR_X` as an undeclared identifier and creates an implicit net for
it. This is the *same trap* that took `` `UF(EAPC) `` on `u_eadec` in M6, which
was found then, written into `doc/coding-standard.md` then, and broken again in
the same file two milestones later.

**What is worth taking from it:** two of the six front-ends are not there to
check portability to a part anyone is targeting. Quartus is there because it
disagrees with the others about something that has **no diagnostic in them at
all**, and it has now earned that place three times. The grep that finds this
one is a line long:

```sh
grep -nE "\.[a-z_0-9]+ *\([^)]*::" rtl/*.sv
```

and it is in the coding standard beside the rule.

---

## M8 · The checkpoint check was reading the wrong thing

**What:** not a bug in the design -- a bug in the check that exists to prevent a
class of bug, which is worse, because it had been reporting success.

`doc/checkpoint.md` rule 3 is "every register an instruction accumulates has a
home here or it does not exist". The check enforcing it walked the MICROCODE and
verified that every `dst` a microword uses has a frame slot. A register the
microcode never names as a destination is invisible to that, and five of them
got past it across M6 and M7:

| | how it is written | what it is |
|---|---|---|
| `link_q` | by the microword's `call` bit | the return address of an effective-address routine |
| `eapc_q` | at a `seq = EADEC` dispatch | whether the base is the program counter |
| `size_q` | at a `seq = EAMODE` dispatch | the operand size the shared routines step by |
| `eadst_q` | likewise | which field the address came out of |
| `cnt_q` | by the microword's `cnt` field | MOVEM's register counter |

Each was found by an unrelated investigation. `link_q` would have surfaced in M9
as a wild jump on a demand-paged access: a fault inside an effective-address
subroutine restores `upc` from the frame and then returns through a link
register holding whatever the handler last put there. Reproducible only under a
fault, and nothing before M9 would have shown it.

**Fixed by:** `frames.check_rtl`, which reads every clocked process in `rtl/`,
collects the signal each non-blocking assignment writes, and insists that every
one is either in the frozen set or in `EXEMPT` with a reason. Ninety-one
registers, all accounted for; eight rows are `PENDING` with the milestone that
builds them.

Both directions are checked, and both were negative-tested before this was
believed: adding a plausible `trace_pending_q` to the sequencer fails the build,
and renaming `link_q` fails it twice -- the new name unaccounted for and the old
one missing.

**The lesson is about the shape of the check and not about the registers.** The
rule is stated in terms of registers. The check was written in terms of the
microcode, because that was what the assembler already had in front of it, and
it silently answered a different question for two milestones.

## M8 · A boundary judged against the status register the instruction replaced

**What:** `MOVE #$8700,SR` turns tracing on. The instruction after it is the
first one traced -- UM 6.1.7 and table 6-2 read T1/T0 at the start of an
instruction, so the MOVE itself is not traced and its successor is. This core
traced the one after that.

The trace mode for the instruction about to start was latched at the same clock
edge as the decode that starts it, from `sr_q`. For every instruction that does
not touch the status register that is right. `MOVE #imm,SR` writes it on the
microword that decodes -- one microword, because there is nothing else for the
instruction to do -- so the latch read the register the write was in the act of
replacing.

The same edge has the same problem twice more:

- the change-of-flow bit, which is *set* by a write to the status register, is
  written non-blockingly on that edge, so `T1T0 = 01` never traced a `MOVE` to
  SR at all -- and the decode arm clears the bit, so "one instruction late"
  meant "never";
- the interrupt mask. An instruction that lowers the mask with a request already
  standing must be followed by the interrupt, not by one more instruction.

**Fixed by:** `sr_eff` and `flow_eff` in `rd68021_seq` -- the status register and
the change-of-flow bit *as they will be* once the microword now presented
retires. Three users: the trace-mode latch, the trace condition, and the mask
comparison at the decode arm. `ipend_n_o` deliberately keeps the plain
comparison against `sr_q`, so that no pin is driven through the ALU result.

**How it was found:** by a directed test whose expectations were written from
the manual before the core was run -- `core_exc_tb`'s trace case, which stacked
the address of the instruction after the one it should have. The vector sweep
could not have found it: it runs one instruction per vector, and this is a bug
about the boundary between two.

## M8 · The register scraper could not see a register

**What:** `check_rtl` reads `rtl/` and insists every clocked signal is either
checkpointed or exempt. It found the signal on the left of a non-blocking
assignment by requiring the *whole* left-hand side of the line to be an
identifier, which is what kept `if (a <= b)` out of the answer.

A guarded assignment laid out on one line --

```systemverilog
else if (retire && ... && irq_pending)             irq_taking_q <= irq_level;
```

-- has a condition to the left of the name, so it did not match, so
`irq_taking_q` was not a register as far as the check was concerned. The failure
direction is the dangerous one: an invisible register is an *unreported* one.

**Fixed by:** looking at every `<=` on the line, taking the identifier before it,
and rejecting the ones that stand inside an expression -- unbalanced parentheses
to the left, or a blocking assignment outside parentheses on the same line, which
is `y = a <= b`. Negative-tested on all five shapes: a comparison in an `if`, a
comparison in a `for` header, a case label, a guarded assignment and a
part-select target.

## M8 · The end of a bus cycle was cleared before the sequencer could read it

**What:** an interrupt acknowledge terminated by `AVEC` took the vectored path
and read whatever happened to be on the bus; one terminated by `BERR` did the
same. The autovector and the spurious interrupt were both unreachable, and a
device that supplied a vector number was the only kind that worked.

`req_end` was a continuous assignment over the `term_err` / `term_rty` /
`term_avc` / `term_hlt` registers. Those are cleared on the **falling** edge
that ends S5 -- the verdict belongs to one cycle and must not leak into the
next. `req_ack` is raised on the **rising** edge inside S5, and the sequencer
retires on the rising edge after it sees the acknowledge. The verdict had been
cleared half a clock before that.

It is worse than one lost test. `exc_irq` tests `AVEC` on the microword that
issues the acknowledge and `BERR` on the one after it, which needs the answer to
outlive the cycle by a microword, not by a clock.

**Fixed by:** latching the end code where `req_ack` is raised. The live verdict
is `end_now`, internal to the bus unit; `req_end` is the copy the sequencer is
given, and it holds until the next operand finishes.

**Why nothing caught it earlier:** `sim/tb/bus_error_tb.sv` checks `req_end`
directly and passes, because the bus harness reads it while the acknowledge is
still asserted -- inside the window, where the combinational value is right. The
sequencer is one rising edge later. Two readers, one signal, different clocks.

## M8 · A condition that read the register its own microword was writing

**What:** RTE on a throwaway format `$1` frame became a format error.

The microword that latches the frame's format word into `xw` also carried
`cond = FMT1`. A condition is evaluated against the register as it stands, and
the write is a non-blocking assignment landing on the edge the branch steers --
so the test read the format word of whatever frame the *previous* RTE had
unwound. The `FMT2` and `FMT0` tests sit on later microwords and read it
correctly, which is why every other frame shape worked.

**Fixed by:** a microword of its own for the first test, and by `check_cond_dst`
in `tools/ucode/assemble.py`, which fails the build when a `COND` microword
writes the register its condition reads. The table is small and explicit:
`FMT0`/`FMT1`/`FMT2`/`XW10` read `XW`, `MASK0` reads `T0`, `USER`/`MASTER` read
`SR`. The conditions that read the ALU result -- `RESNEG`, `GTZ`, `RESM1` --
are deliberately not in it: testing what the current microword computes is what
they are for. Negative-tested by putting the bug back.

**This is the third of its family in one milestone**, after the status register
at a decode boundary and the change-of-flow bit. Each is the same mistake:
reading state that the retiring microword is in the act of changing. The other
two needed a bypass because the write and the read genuinely belong on the same
microword; this one did not, and got a microword instead.

## M8 · A traced branch stacked the address of its own target

**What:** with `T1T0 = 01` -- trace on change of flow -- a traced `BRA` built a
format `$2` frame whose `+$08` field, "the address of the instruction that
caused the trace", was the branch *target* rather than the branch.

`pc_prev_q` was latched at the decode that ends an instruction, from `pc_d`,
with the reasoning that the pipe advance which moves `pc_d` on is a non-blocking
write landing on that same edge. That is true for `pf = ADV`, which is always on
the last microword. It is not true for `pf = FLUSH`, which a branch does several
microwords earlier: by the time the branch's decode retires, `pc_d` has been the
new stream for some clocks.

A handler reading `+$08` would have been told that the instruction it was
stopped on had already run.

**Fixed by:** taking `pc_prev_q` at the flush when there is one -- the last
moment at which `pc_d` is still the instruction's own address -- and a one-bit
`pc_kept_q` so the decode does not overwrite it. Both are checkpointed: they are
per-instruction state and a fault in the middle of a traced instruction must not
lose them.

**How it was found:** the trace-on-change-of-flow case of `core_exc_tb`. The
trace-everything case cannot find it, because `T1` traces instructions that do
not branch, and those are exactly the ones for which the old rule was right.

## M9 · The address that could not occur was the one level 7 uses

**What:** not a bug in the core — a bug in the testbench harness, found because
it made a passing test fail.

The bus-error region added for M9 is `berr_base` / `berr_mask`, and it was
switched off by parking it at an address no cycle would ever use:
`$FFFF_FFFF`. That is exactly where a level 7 interrupt acknowledge goes. UM
figure 5-31 synthesises the acknowledge address as every bit set above the
level, the level on A3–A1 and A0 set, so level 7 is `$FFFF_FFFF` precisely.

Every level-7 acknowledge terminated with a bus error, which is the spurious
interrupt, so the frame carried vector 24 instead of autovector 31.

**Fixed by:** an enable bit. A region is switched off by saying so, not by an
address chosen for being unreachable — there was no unreachable address, and the
one picked was load-bearing.
