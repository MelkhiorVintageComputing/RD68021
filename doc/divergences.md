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

## The reserved index/indirect encodings stop the processor

PRM table 2-2 leaves two groups of the full extension word's IS and I/IS fields
**Reserved**: `IS = 0, I/IS = 100`, and `IS = 1, I/IS = 100` through `111`. PRM
table 2-1 also reserves a BD SIZE of `00`. The manual says what they are called
and nothing about what the part does with them.

**This design sends all of them to a defined micro-address that stops.** Until
exception processing exists (M8) that is all it can do; afterwards it should
become an illegal-instruction exception, which is what the F-line and A-line
encodings get and the nearest thing the architecture offers.

**What could differ:** whatever a real MC68020 does, which is not written down.

**How it is checked:** it is not. `tools/ucode/assemble.py` forces the decision by
requiring every one of the 131072 extension-word-and-base-bit combinations to
land somewhere named, so the encodings cannot fall through into a routine meant
for something else; and `tools/cosim/musashi_ea.c` deliberately does **not**
generate them, because Musashi's answer for them would be Musashi's guess rather
than the manual's.

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

---

## Musashi calls a program-counter-relative indirection a data reference

Not a divergence in this core: a place where the oracle is wrong and the sweep
had to be told so.

PRM 2.2.14 and 2.2.15, on the two program-counter memory-indirect modes:

> The processor calculates an intermediate indirect memory address by adding a
> base displacement to the PC contents. **The processor accesses a long word at
> that address** and adds the scaled contents of the index register and the
> optional outer displacement to yield the effective address. ... **This is a
> program reference allowed only for reads.**

The sentence covers the whole access, the intermediate long word included. This
core drives the program function code for it, and for the final operand fetch of
every PC-relative mode, which is what section 2's opening paragraph requires:
"Data items in the instruction stream can be accessed with the program counter
relative addressing modes; these accesses classify as program references."

Musashi has no function code pins. What it has is `M68K_SEPARATE_READS`, which
routes the *final* operand fetch of a PC-relative mode to
`m68k_read_pcrelative_xx` and everything else to `m68k_read_memory_xx`. The
intermediate indirection goes through the latter, so taking the space from the
callback would call it a data reference.

**What is done about it:** `tools/cosim/musashi_ea.c` takes the space from the
addressing mode the test was built with, not from the callback Musashi used. The
mode is in the opcode it wrote, so this is our reading of PRM 2 and not
Musashi's silence — and it is worth saying plainly that for this one field the
sweep checks the core against the manual rather than against an independent
implementation.

**What still checks it independently:** nothing yet. `make sun3` is where it
becomes checkable for real, because the Sun-3 MMU maps program and data space
separately and a wrong function code there is a fault rather than a difference
of opinion. Noted in the M12 work.

---

## Musashi splits MOVE.L to a predecrement address the way an MC68000 does

Not a divergence in this core: a second place where the oracle models a
different processor and the sweep had to be told so.

`Inputs/ref/Musashi/m68k_in.c`, for `MOVE.L <ea>,-(An)`:

```c
uint ea = EA_AX_PD_32();
m68ki_write_16(ea+2, res & 0xFFFF );
m68ki_write_16(ea,  (res >> 16) & 0xFFFF );
```

Two word writes, **low half first**, unconditionally -- it is not even behind
`M68K_SIMULATE_PD_WRITES`, which is off. That is the MC68000's behaviour and a
consequence of its sixteen-bit bus: writing the low word first leaves a
recoverable stack if the second write bus-errors.

The MC68020 has no such case. UM 5.2.2 and table 5-6 split an operand by its
**address**, not by the instruction that made it, and 5.1.2 puts the most
significant byte at the address on the bus. So `MOVE.L D3,-(A3)` with A3 landing
on an address whose low bits are `10` is **one long-word operand** that the bus
controller happens to run as two cycles, most significant half first -- the
opposite order from Musashi, and one operand rather than two.

**What is done about it:** `tools/vectors/gen.c` puts the two halves back
together into the one long-word access the MC68020 makes. The merge is gated on
the opcode being exactly `MOVE.L <ea>,-(An)`, because MOVEM to a predecrement
address also writes descending words and must not be merged.

**What still checks it independently:** `sim/tb/bus_sizing_tb.sv` already proves
every row of table 5-6 at the pins, including this one, so what the sweep would
have added is only that this instruction reaches that row -- which it now does.

---

## The condition codes the manual leaves undefined

PRM 4 marks some condition codes **undefined** after some instructions. A real
MC68020 puts *something* there, and what it puts is not written down. So does
this core, and so does Musashi -- and matching Musashi's choice would be reading
a reference implementation as a specification, which `CLAUDE.md` forbids.

What this design does, and what the sweep therefore does not compare:

| Instruction | Undefined | What this core does |
|---|---|---|
| ABCD, SBCD, NBCD | N, V | N from the result's top bit, V cleared |
| DIVU, DIVS **when V is set** | N, Z | left as they were |
| CHK, when it does **not** trap | N, Z, V, C | left as they were |
| MULU.L, MULS.L into one register | — | nothing is undefined; V says whether the product fitted |

The first is the common one, and the choice is the cheap one: N and V fall out of
the same wires every other instruction uses, so making them undefined would cost
logic to produce a *worse* answer.

The third is worth a sentence. PRM 4 defines N for CHK only in the two cases
that trap -- "set if Dn is less than zero, cleared if Dn is greater than the
upper bound" -- and both of those take an exception, so a CHK that returns
normally has no defined codes at all. Leaving them alone is the only behaviour
that costs nothing.

**How it is checked:** `tools/vectors/gen.c` emits a `srmask` per test saying
which bits of the status register are worth comparing, and clears the undefined
ones. The mask for a divide is decided **after** the run, because a divide only
leaves N and Z undefined when it actually overflowed.

**What could differ:** a program that branches on one of these bits. No compiler
emits such a branch, because the manual says not to.

---

## Musashi leaves C alone when a divide overflows

The third place the oracle has to be corrected, and the clearest of the three,
because the manual's own text is asymmetric on purpose.

PRM 4's condition-code table for DIVU and DIVS:

> **N** — Set if the quotient is negative; cleared otherwise; **undefined if
> overflow** or divide by zero occurs.
> **Z** — Set if the quotient is zero; cleared otherwise; **undefined if
> overflow** or divide by zero occurs.
> **V** — Set if division overflow occurs; undefined if divide by zero occurs;
> cleared otherwise.
> **C** — Always cleared.

Three rows carry an overflow qualifier and the fourth does not. "Always cleared"
with nothing after it means cleared on the overflow path too.

`Inputs/ref/Musashi/m68k_in.c` does not:

```c
if(quotient < 0x10000)
{
    ... FLAG_C = CFLAG_CLEAR; ...
    return;
}
FLAG_V = VFLAG_SET;
return;                     /* C is whatever the last instruction left */
```

so an overflowing divide leaves C at whatever it happened to be.

**What is done about it:** `tools/vectors/gen.c` clears C in the state it
records when a divide overflowed. The alternative was to stop comparing C for
those vectors, which would have given up a bit the manual defines in order to
accommodate an oracle that does not implement it.

**What could differ:** a program that branches on C after a divide that
overflowed. The manual says what happens; nothing else does.

---

## The condition codes after reset

UM 6.1.1 says what the reset exception does to the status register: it sets the
supervisor bit, clears the trace bits and puts the interrupt mask at 7. It says
nothing about the condition codes, and neither does anything else.

**This design clears them**, which is what `SR_RESET = $2700` means. Musashi
leaves Z set, because it keeps its flags in separate variables and the one
standing for Z reads back as set when it is zero.

Both are allowed. What is not allowed is a program that depends on either, so
`sim/programs/crt0.S` establishes the codes with `ANDI #0,CCR` before it does
anything else -- which is also what lets `make cosim` compare from a state the
two sides agree on.

**How it is checked:** it is not, and cannot be. What is checked is that nothing
depends on it.

---

## A decimal instruction given a digit above nine

PRM 4 defines ABCD, SBCD and NBCD on **binary-coded decimal** operands: two
decimal digits in a byte. It says nothing about what happens when a nibble holds
$A to $F, because such a byte is not a BCD number.

A real MC68020 produces something definite, and so does this core, and the two
have no reason to agree. What this core does is the textbook correction applied
to the whole byte:

> add the operands and the extend bit; if the low digits summed past nine, add
> six; then if the byte passed $99, subtract $A0 and carry.

with the subtraction mirrored. For valid operands that is exactly decimal
arithmetic. For a digit above nine it is *a* defined answer and not necessarily
the part's: a low-digit sum above fifteen carries two tens into the digit above,
and a single six cannot say so.

Musashi does something different, and differently again for NBCD, which it
computes as `$9A - operand - X` with a fix-up for a low digit that comes out as
$A. That is one reading; it is not one this project may adopt, because a
reference implementation is never a source here.

**What is done about it:** `tools/vectors/gen.c` gives the decimal instructions
decimal operands -- the registers and the whole data block are reduced to digits
-- and does not sweep the undefined region at all. What is compared is the
instruction doing its job.

**What could differ:** a program that feeds invalid BCD to ABCD and depends on
the answer. There is no such program; the operation has no meaning there.

---

## The control registers reset does not name

UM 6.1.1 lists what the reset exception does in nine numbered steps. It
initialises **VBR** to zero and clears **E and F in CACR**, and it says nothing
at all about SFC, DFC, CAAR, MSP or USP.

So those are undefined after a reset, in the same way the condition codes are,
and for the same reason: the manual defines the machine's behaviour, not its
initial state. **This design clears them**; Musashi has its own answer; both are
allowed and neither is checkable.

MOVEC makes the difference visible, because MOVEC Rc,Rn reads them.

**What is done about it:** `tools/vectors/gen.c` gives every test a definite
value for each -- SFC 3, DFC 5, VBR `$0000A000`, CAAR `$12345670`, MSP below the
stack -- and the testbench deposits the same. What is then compared is the
instruction, not what a reset happened to leave behind.

**What could differ:** nothing a program can rely on. A supervisor that reads
SFC before writing it is reading an undefined register on any MC68020.

---

## Musashi stacks the wrong program counter for a format error

UM 6.1.8, on the exception RTE raises when the frame it is handed has a format
code it does not understand:

> **The stacked PC value is the logical address of the instruction that detected
> the format error.**

The instruction that detected it is the RTE. Musashi stacks the address of the
instruction *after* it, which is what every other four-word frame carries -- and
which is right for a TRAP and wrong here, because a format error is not
something the program asked for and the handler's job is to look at the
instruction that hit it.

The same paragraph is also the source of `doc/manual-contradictions.md`'s entry
about which frame a format error builds. This core follows table 6-5 and builds
a four-word one.

**What is done about it:** `tools/vectors/gen.c` corrects the stacked value in
the frame it records. The alternative was to stop comparing the one word the
test exists to check.

**What could differ:** a handler that reports where a bad frame was found would
name the instruction after the RTE. There is no way to recover the right answer
from the frame.

---

## CHK leaves Z, V and C clear, which the manual does not require

PRM 4, CHK, on the condition codes:

> **N** — set if the compared value is less than zero; cleared if it is greater
> than the upper bound; undefined otherwise.
> **Z, V, C** — undefined.

N is defined in exactly the two cases that trap, so it is a statement about what
the handler finds in the stacked status register. This core produces it from the
sign of what each comparison already computes: the register on the first test,
and the register minus the bound on the second, whose sign is clear exactly when
the register is the greater.

The second rule is about *why* the trap happened and not about the sign of
anything: when the upper bound is negative the subtraction overflows and its
sign is the opposite of the answer, so that path clears N outright. Eight of the
8126 vectors were exactly that case.

Z, V and C are zero on both trapping paths, and carry the result of the last
comparison when the instruction does not trap -- the case the manual calls
"undefined otherwise".

**What is done about it:** nothing. `tools/vectors/gen.c` already masks N, Z, V
and C out of the final status register for this group, because they are
undefined; the stacked copy in the frame is compared exactly, and it now agrees.

**What could differ:** a program that reads Z, V or C after a CHK that did not
trap. Nothing may, and the manual says so.

**Before this:** the instruction wrote no condition codes at all, so the frame
carried whatever the previous instruction had left -- including an N that the
manual *defines* for a trapping CHK. That was a bug and not a divergence; 75 of
the 8126 vectors found it.

---

## The instruction being decoded when a prefetch faults does not run first

UM 6.1.2 lets a prefetch fault be taken late: "if the aborted bus cycle is an
instruction prefetch, the processor may delay taking the exception until it
attempts to use the prefetched information."

On this core the *use* is a microword, and for the last microword of an
instruction the use and the instruction are the same microword: it writes the
result **and** advances the pipe, and advancing the pipe is what needs the word
that is not there. `doc/checkpoint.md` rule 2 says a faulted microword commits
nothing, so the instruction in stage D does not complete before the exception is
taken.

It is re-executed by RTE, so it runs exactly **once**, and the stacked program
counter is its own address — which is what UM 6.1.2 asks for in as many words:
"the saved PC value is the logical address of the instruction that was executing
at the time the fault was detected".

**What could differ:** a handler that looked at the registers and concluded that
the instruction at the stacked PC had already run. Nothing may: the manual names
that instruction as the one that was executing, not the one that had finished.

**What is done about it:** nothing, and there is nothing to do — separating the
two would mean a microword that advances the pipe without retiring the
instruction, which is a second commit path and a second thing to get wrong on
every instruction in the machine, to buy a difference no program can observe.

---

## Stage D never holds a word from a faulted prefetch

UM 6.2.1 defines `FC` as "the processor attempted to use stage C and found it to
be marked invalid", and the special status word has no bit for stage D. This
core takes that literally: the check is at stage C, and the pipe will not load a
faulted word into stage D at all — neither by a microword's ADV nor by the
automatic load that fills an empty stage D after a flush.

So the frame never has to describe a faulted stage D, and the internal word does
not carry a bit for one. An earlier version of the frame did; it was removed
when the bit became provably zero.

**What could differ:** nothing a handler can see. The frame it gets is the one
the manual describes, and the stage it is told to repair is the one the manual
names.

---

## Musashi executes from an odd program counter; this core takes an address error

UM 6.1.3:

> An address error exception occurs when the processor attempts to prefetch an
> instruction from an odd address. This exception is similar to a bus error
> exception but is internally initiated. A bus cycle is not executed, and the
> processor begins exception processing immediately.

Musashi models address errors for the MC68000 and MC68010 and not for this part,
where misaligned *data* accesses are legal — and it does not separate the two
cases. Given `JMP (A1)` with an odd A1 it carries on executing from the odd
address; this core raises vector 3 and builds a fault frame.

From that instruction on the two machines are doing different things, so there is
nothing left to compare.

**What is done about it:** `tools/vectors/gen.c` drops any test whose oracle run
ended with an odd program counter. It is a narrow rule and it names exactly the
disagreement: the sweep stops where Musashi stops being authoritative, rather
than anywhere earlier.

**What could differ:** nothing. The manual is unambiguous and `core_fault_tb`
covers the behaviour directly, with the frame checked against UM 6.2.1 —
the rerun bits set, the fault bits clear, vector offset `$00C`.

---

## Musashi concatenates PACK's two source bytes the wrong way round

PRM 4, PACK, on the predecrement form:

> When the predecrement addressing mode is specified, two bytes from the source
> are fetched and concatenated.

and the diagram is explicit about which is which: the byte drawn first supplies
bits 11–8 of the concatenated word, and the byte drawn second supplies bits 3–0.
The first is the one at the **lower** address, because this is a big-endian
family and the concatenated word is just the word at the decremented address.

Musashi makes the byte at the *higher* address the significant one, in both PACK
and UNPK. The two implementations read and write the same addresses in the same
order and disagree only about which byte is which half.

**The instruction's own purpose settles it.** PACK exists to turn two unpacked
digits into one packed byte. The string `"42"` has `'4'` at the lower address;
packing it must give `$42`. With Musashi's order it gives `$24`, and every
multi-digit conversion comes out with its digits reversed.

**What is done about it:** the sweep runs the register forms, where the two
agree, and `sim/tb/core_insn_tb.sv` covers the predecrement forms directly with
the expectations written from the manual's diagram — including the `"42"` case,
which is the one a reader can check without any of this reasoning.

**What could differ:** a program that packs or unpacks through `-(An)` gets the
opposite digit order under Musashi. Nothing else uses the instruction.
