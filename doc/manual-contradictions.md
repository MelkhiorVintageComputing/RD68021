# Places the MC68020 manual disagrees with itself

Each entry: what the two sources say, which one this design follows, and why. Read this
before "correcting" something in the RTL that looks wrong against one reading of the
manual.

`Inputs/doc/MC68030_Doc_More_Readable/MC68020UM_split/README.md` records a separate set
of defects — ones in the *document*, found while splitting it (the `DSACK≈` glyph used ten
times and defined nowhere, the misprinted `.08 V` note, two outline typos, and Section 11
whose pages are footed `MC68838 USER'S MANUAL` with folios 13-1…13-11). Those are
transcription defects. This file is for places where the manual's own *content*
contradicts itself.

---

## 1. The long bus fault frame's version word is at `SP+$36`, not `SP+$38`

**Followed: `SP+$36`, bits 15–12.**

§6.1.12 says it in words, and it is unambiguous:

> for the long stack frame, the processor compares the version number in the stack with
> its own version number. The version number is located in the most significant nibble
> (bits 15–12) of the word at location SP + $36 in the long stack frame.

Table 6-5's diagram of the format `$B` frame is laid out so that a quick read puts
`VERSION #` on the row labelled `+$38`. Arithmetic settles it in favour of the prose:

| Offset | Field | Words |
|---|---|--:|
| `$2C`–`$2E` | data input buffer | 2 |
| `$30`, `$32`, `$34` | internal registers, 3 words | 3 |
| `$36` | **version number + internal information** | 1 |
| `$38`…`$5A` | internal registers, 18 words | 18 |

`$38` to `$5A` inclusive is `(0x5A − 0x38)/2 + 1 = 18` words, which is what the figure's
own caption for that block says. The frame then ends at `$5C`, i.e. 46 words — which is
what the figure's title says. Putting the version at `$38` makes the last block 17 words
and the frame 45, and neither matches.

**Why it matters:** the version nibble is what lets our own encoding of the internal
words be legitimate — §6.1.12 has RTE refuse a frame whose stamp it does not recognise
with a format error. Writing it one word out would make every one of our own frames fail
its own validity check, or worse, pass by accident while the eighteen internal words are
read one word shifted. It is a silent demand-paging failure.

---

## 2. Coprocessor interface register select: A5–A0 or A4–A0?

**Followed: A4–A0.** Decided in M13.

§5.4.3 says the coprocessor interface register is selected by **A5–A0**. Figure 5-31,
"MC68020/EC020 CPU Space Address Encoding", draws the `CP REG` field on **A4–A0**, with
A15–A13 carrying the CpID and A12–A5 zero.

§7.3's register map (the eleven CIRs at offsets `$00`–`$1C`) needs five bits to address a
word-granular register set spanning `$00`–`$1F`, which favours the figure, and so does
§7 itself: figure 7-3 draws the CIR field on A4–A0 and 7.1.4.3 says "signals A4–A0 of the
MC68020/EC020 address bus select the CIR being accessed". A5 is zero, with A12–A6.
`rd68021_biu.sv` builds the address that way and `sim/models/rd68021_cpmodel.sv` decodes
it independently from figure 7-3.

---

## 3. The write cycle's State 0 says the processor *negates* ECS

**Followed: asserted.** A typo, and an obvious one, but it is in the only paragraph
that describes what a write cycle does first.

UM 5.3.2, State 0:

> MC68020 — The write cycle starts in S0. The processor negates ECS, indicating the
> beginning of an external cycle.

Three things say otherwise, and nothing else agrees with it: the read cycle's own
State 0 ("the processor asserts ECS, indicating the beginning of an external
cycle"), the write cycle flowchart in figure 5-24 ("ASSERT ECS/OCS FOR ONE-HALF
CLOCK"), and specification 6A, "Clock High to ECS, OCS **Asserted**".

---

## 4. Is DBEN a three-state output?

**Followed: yes — it gets an `_oe`, in the same group as AS, DS and R/W.**

§3.6 introduces R/W, RMC, AS and DS as "three-state output signal" and DBEN as merely
"This output signal is an enable signal for external data buffers." Table 3-1 says nothing
either way.

Specification **16** settles it against the prose: "Clock High to AS, DS, R/W, DBEN High
Impedance". A signal with a high-impedance specification is three-stated.

The cost of following the specification and being wrong is a wrapper that drives a pin
which a real MC68020 would also have driven, since `dben_oe` is negated only on bus
relinquish and reset — occasions on which nothing is looking at DBEN anyway. The cost of
following the prose and being wrong is a bus fight with the device that took the bus.

---

## Withdrawn

Kept so that nobody spends the afternoon re-raising them.

**When DBEN moves on a write.** UM 5.1.6 ("in a write operation, DBEN is asserted at
the time AS is asserted and is held active for the duration of the cycle") reads at
first like it disagrees with specifications 42 and 44, which measure DBEN from a
clock edge and from R/W rather than from AS. It does not. AS is asserted on the
falling edge entering S1 (specification 9, "Clock Low to AS, DS Asserted") and so is
DBEN (specification 42, "Clock Low to DBEN Asserted, Write"); they are the same
edge. UM 5.3.2 state 1 says so in words as well.

The same paragraph's read-cycle sentence, "DBEN is asserted one clock cycle after
the beginning of the bus cycle", is also exact rather than loose: S0 begins on a
rising edge and S2 begins on the next rising edge, which is one clock period later,
which is where UM 5.3.1 state 2 puts it.

All four of this design's DBEN edges satisfy specifications 42, 43, 45 and 25A at
the 16.67 MHz grade, and `sim/tb/bus_ruler_tb.sv` measures them.

---

## The format error builds two different frames, depending which page you read

**UM 6.1.8**, in prose:

> If any of the checks previously described determine that the format of the
> stacked data is improper, the instruction generates a format error exception.
> This exception **saves a short bus fault stack frame**, generates exception
> vector number 14, and continues execution at the address in the format
> exception vector.

**UM table 6-5**, which is the definitive list of which exception takes which
frame, puts

> Format Error &nbsp;&nbsp; [RTE or cpRESTORE instruction]

in the box headed **FOUR-WORD STACK FRAME — FORMAT $0**.

A short bus fault frame is format `$A`, sixteen words, and it exists to describe
a faulted bus cycle: a special status word, a fault address, a data output
buffer, the pipe stages. A format error has no bus cycle to describe. Every one
of those fields would be meaningless.

**This design follows the table and builds a format `$0` frame.** The table is
the one the whole of 6.4 is organised around, and the sentence in 6.1.8 reads
like text carried over from a draft where the format error was a bus fault. The
MC68010, whose format error is the direct ancestor of this one, produces a
four-word frame.

**What could differ:** a handler that reads a format error's frame as sixteen
words gets four. It would be reading fifteen words of somebody else's stack.

---

## What BFFFO adds to its scan result, when the field is in a register

**PRM 4**, BFFFO:

> The bit offset of that bit (the bit offset in the instruction plus the offset
> of the first one bit) is placed in Dn.

and, on the offset when it comes from a register:

> If Do = 1, the offset field specifies a data register that contains the
> offset. The value is in the range of –2³¹ to 2³¹ – 1.

For a field in **memory** those two sentences are complete: the offset is a byte
displacement and a bit position within it, nothing is reduced, and the sum is
the obvious one.

For a field in a **data register** the manual never says what happens to an
offset outside 0–31 at all — yet it must say something, because there are only
thirty-two bits to index. Every implementation takes it modulo 32, which is what
makes the field wrap, and this core does too. The question the manual leaves is
which offset then goes into BFFFO's sum: the register's whole value, or the
reduced one the field was actually taken at.

**Both are defensible and they differ.** The two are congruent modulo 32, so
either serves equally as an offset into the same field — feed either back to a
later bit-field instruction on the same register and you address the same bits.
The literal reading of "the bit offset in the instruction" is the whole value;
the reading that matches how the field was located is the reduced one.

**This core used to reduce, and no longer does: it adds the instruction's whole
offset**, reduced modulo 32 only to locate the field. The sentence names "the
bit offset in the instruction", which for a register offset is the register's
value, and nothing in the paragraph reduces it. RD68031, forked from this
design, withdrew the reduced reading first (its own
`doc/manual-contradictions.md`, entry 14): the cputest corpus, whose generator
was validated against real processors, agrees with the literal reading, which
is evidence about the part. `core_insn_tb` checks offsets 37 and -27 and an
empty field.

**The memory case is not affected.** Nothing is reduced there and the sum is the
manual's, unambiguously.

---

## BFINS sets its codes from the field before or after the insert

**PRM 3.1.6**, on all eight bit-field instructions at once:

> NOTE: All bit field instructions set the CCR N and Z bits as shown for BFTST
> before performing the specified operation.

**PRM 4**, on BFINS alone:

> Inserts a bit field taken from the low-order bits of the specified data
> register into a bit field at the effective address location. **The instruction
> sets the condition codes according to the inserted value.**

For the other seven the two agree, because reading the field is the operation.
For BFINS they cannot: the field before the insert and the value being inserted
are different things.

**This core follows the BFINS page** — N is the most significant bit of the value
inserted and Z says that value's low `width` bits are all zero. Three reasons,
in order of weight: the per-instruction page is the detailed specification and
the summary is a summary; the general note says "as shown for BFTST", and
BFTST's N and Z are defined in terms of *the field*, which after a BFINS is the
inserted value; and it is the only reading under which the codes tell the
program something it does not already know — the field before an insert is
about to be destroyed.

`sim/tb/core_bitfield_tb.sv` checks both halves: the other seven against the
field as found, BFINS against the value inserted.

---

## cpRESTORE's addressing modes: three statements, two answers

**Followed: control modes, (An)+, and the immediate.**

- UM 7.2.3.4.1: "All memory addressing modes except the predecrement addressing mode
  are valid." The immediate is a memory mode (PRM table 2-4).
- PRM 6, cpRESTORE, in words: "Only postincrement or control addressing modes can be
  used". The immediate is neither.
- PRM 6, cpRESTORE, the table that sentence introduces: it lists `# <data>` as mode 111,
  register 100 -- valid.

Two of the three allow it, and the one that does not is the one a table contradicts on
the same page. So `cpRESTORE #<frame>` restores a state frame written in the instruction
stream, which comes out of the pipe and moves the scanPC past it. cpSAVE's table and text
agree with each other and with UM 7.2.3.3.1: control alterable or predecrement, no
immediate.

---

## Transfer multiple main processor registers: which register first?

**Followed: D0 first, then D1..D7, then A0..A7** -- the order MOVEM's control form uses.

UM 7.4.15 gives the mask as figure 7-36, A7 in bit 15 down to D0 in bit 0, and says "the
selected registers are transferred in the order D7–D0 and then A7–A0". Read literally
that is D7 first. It can equally be read as naming the two groups the way the rest of the
manual names register ranges -- "D7–D0" is how figure 7-36 labels the data half -- with
the data registers before the address registers. The MC68881 manual cannot settle it: it
never issues this primitive ("the FPCP only uses six of those primitives", MC68881 UM
7.4.2).

A coprocessor that relies on the order has to be told which one this is, so it is here and
in `doc/coprocessor.md`. The mask bit layout, and which registers are transferred, are
unambiguous.

---

## The midinstruction frame: "internal registers" or named fields?

**Followed: figure 7-43's names.** Table 6-5 draws format $9 as the six-word frame plus
"internal registers, 4 words" at `+$0C`–`+$12`. Figure 7-43 names those words: an internal
register at `+$0C`, the operation word at `+$0E` and the effective address at `+$10`. They
are not in conflict -- one is less specific -- but a handler that emulates a coprocessor
instruction needs the named ones, and `tools/ucode/frames.py` lays the frame out by
figure 7-43.

---

## The state frame length: in bytes, or times four?

**Followed: in bytes.** UM 7.2.3.1 says the processor writes the state frame "to
descending memory addresses, beginning with the address specified by the sum of the
effective address and the length field multiplied by four". UM 7.2.3.2 says the length
byte "specifies the size in bytes (which must be a multiple of four)", and 7.2.3.3.2 that
it is "the number of bytes of state information, not including the format word and
associated null word". The MC68881's own frames settle it: its idle frame has length $18
and is "six long words from the operand CIR" (MC68881 UM 7.5.3.1) -- 24 bytes, not 96.


---

## What UNLK A7 leaves in A7

**PRM 4**, UNLK: "Operation: An → SP; (SP) → An; SP + 4 → SP." Read literally
with An = A7, the last step adds four to the long word just loaded. The
description says the other order: "Loads the stack pointer from the specified
address register, then loads the address register with the long word pulled
from the top of the stack". The stack pointer is stepped as part of the pull,
and the address register is loaded last. For any An but A7 the two are the same.

**This core follows the description**: A7 is the long word pulled. It is the
sentence that says what ends up in the address register, and the cputest
corpus that RD68031 ran agrees with it. This core used to give a third
answer, the old stack pointer plus four (`doc/bugs-found.md`).
