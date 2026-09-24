# The coprocessor interface

UM section 7, as built in M13. `COPROCESSOR = 1` on `rd68021_top` builds it; with
`COPROCESSOR = 0` every F-line word is an F-line exception, which is also what a
machine with no coprocessor wants (UM 7.5.2.2). The microcode is the same either
way: the parameter only chooses what the opcode decoder hands the sequencer for an
F-line word.

`make cpif` runs it against a scripted coprocessor, 297 checks.

---

## How it is built

A coprocessor instruction is a conversation. The processor starts it with one
access to an interface register (a CIR), reads the response CIR, does what the
primitive there says, and reads it again until a primitive lets it go.

**CIR accesses** are ordinary operand requests in CPU space type $2, with the CpID
from bits 11:9 of the operation word on A15–A13 and the register on A4–A0 (UM
figure 7-3). The microword's `cpuspace` field is one of two values:

| | a bus error on it | used for |
|---|---|---|
| `CPINIT` | an answer: the microcode tests the end code and takes an **F-line** exception -- "the processor assumes that the coprocessor is not present" (UM 7.5.2.8) | the one access that starts each instruction |
| `COPROC` | a **bus error**, with the long frame, and RTE reruns the access | every other one |

The bus unit carries the difference as `req_cpfault`. Before M13 no CPU-space bus
error was a fault, because on an interrupt or breakpoint acknowledge it is an
answer.

**The primitive decoder.** A primitive read from the response CIR decides which
register is read next, which way an operand moves, and whether the effective
address is evaluated. All of those are decisions that steer the bus. So the
primitive is held in `cprim` and decoded in hardware into a micro-address,
`rd68021_cpdec_rom`, reached with `seq = CPDEC`. This is the extension-word
decoder's trick on a different word. Its seventeenth input bit is the
instruction's category, because most primitives with CA clear, and some
primitives at all, are protocol violations in a conditional instruction (UM
table 7-6). Everything the manual leaves undefined is decoded as a protocol
violation.

**The dialogue's state** is four things, and they are the four that the
midinstruction frame (UM figure 7-43) saves. That is what lets an interrupt be
taken in the middle of it and the dialogue resumed after RTE:

| | where it is | frame |
|---|---|---|
| the program counter | `pc_d`: stage D holds the F-line operation word for the whole instruction and nothing advances it | +$08 |
| the scanPC | the address of stage C (UM 7.4.1). Every word the instruction reads from the stream is consumed, which moves it on | +$02 |
| the operation word | stage D | +$0E |
| the evaluated effective address | `EA`, for the write-to-previously-evaluated-address primitive | +$10 |

`+$0C`, the "internal register", carries what the instruction had decided about
tracing: the trace mode it began with, whether it has changed the flow, and
whether it is exempt (bits 1:0, 2, 3 and 4). A resumed dialogue has to trace the
same way.

Within one primitive T0–T3 are scratch, and the primitive itself is in `cprim`,
which the long fault frame carries at +$4A (`doc/checkpoint.md`). A bus error on
an operand a primitive is moving is an ordinary bus error (UM 7.5.2.8), and RTE
goes back into the middle of the primitive.

**The scanPC written by the coprocessor** (UM 7.4.17) refills the queue behind
stage D from the new address and leaves stage D and `pc_d` alone. It goes over
the checkpoint port as `CK_SCAN`, and it is also the last thing RTE puts back out
of a format $9 frame. Written with an odd address, the refill is an address error
at the next use of the pipe, as UM 7.5.2.8 says.

**Operands** move in long words, with the remainder in one transfer of one to
three bytes. The count is a microword constant, so the tail is a branch on the
low two bits of the count. Every part goes to or from offset $10, which puts it
on the top lanes of the operand CIR (UM figure 7-21). The bus unit splits any
part that is misaligned on the memory side, as it does for any operand.

---

## The instructions

| | opcode | effective addresses | starts with |
|---|---|---|---|
| cpGEN | `1111 ccc 000 eeeeee`, command | any: only a primitive looks at it | the command word to the command CIR |
| cpBcc.W / .L | `1111 ccc 01s cccccc` | -- | the operation word to the condition CIR |
| cpScc | `1111 ccc 001 eeeeee`, condition | data alterable | the condition word to the condition CIR |
| cpDBcc | `1111 ccc 001001 rrr`, condition, displacement | -- | likewise |
| cpTRAPcc | `1111 ccc 001111 ooo`, condition, 0–2 words | -- | likewise |
| cpSAVE | `1111 ccc 100 eeeeee` | control alterable, -(An) | a read of the save CIR |
| cpRESTORE | `1111 ccc 101 eeeeee` | control, (An)+, #&lt;frame&gt; | the format word to the restore CIR |

A CpID of 000, a type of 110 or 111, and an effective address the form does not
allow are all F-line exceptions with no CIR access. cpSAVE and cpRESTORE are
privileged, and that is checked before any CIR is touched.

A conditional instruction's dialogue ends with a null primitive with CA clear.
The verdict is TF, and which instruction's tail runs is read off stage D.

**cpSAVE** writes the format word as a long word with its reserved half zero,
then the state from the top down: the first long word read from the operand CIR
goes to the highest address. **cpRESTORE** reads the format word from memory,
writes it to the restore CIR, reads the coprocessor's answer, and then moves the
state in ascending order. The length it uses is the one from memory, and a
length that is not a multiple of four is refused only after the answer has been
read (UM 7.5.2.7). Not ready on cpSAVE restarts the instruction, so a pending
interrupt is taken first with the four-word frame. Not ready on cpRESTORE reads
the restore CIR again at once.

---

## The primitives

UM 7.4, and the test in `sim/tb/core_cpif_tb.sv` that drives each one.

| Primitive | bits 13:8 | served by | tested |
|---|---|---|---|
| busy | `100100` | the instruction starts again from its operation word, through the decode arm, so a pending interrupt is taken first with the four-word frame | yes, with and without an interrupt |
| null | `00100i` | CA=1: read again, servicing an interrupt first if IA; CA=0: release a general instruction (or keep reading while a trace is pending), or finish a conditional one on TF | yes: release, come-again, IA with an interrupt on each stack, trace pending |
| supervisor check | `000100` | at the user level: abort, then a privilege violation | yes |
| transfer operation word | `-00111` | stage D to $08 | yes |
| transfer from instruction stream | `-01111` | the stream to the operand CIR in long words and a word; odd lengths are refused | yes |
| evaluate and transfer effective address | `001010` | control alterable only, or abort and F-line; the address to $1C | yes, both |
| evaluate effective address and transfer data | `d10vvv` | the class check of table 7-4, then a data or address register (one, two or four bytes), an immediate (one byte or even), (An)+ and -(An) stepped by the length, or any other memory mode | yes: every one of those |
| write to previously evaluated effective address | `100000` | the operand CIR to `EA`, in data space | yes |
| take address and transfer data | `d00101` | the address from $1C, then the operand | yes |
| transfer to/from top of stack | `d01110` | (A7)+ or -(A7), a byte stepping by two | yes |
| transfer single main processor register | `d01100` | a long word | yes, both ways |
| transfer main processor control register | `d01101` | the select code from $14 through the same multiplexer as MOVEC; a code not in table 7-5 is a protocol violation | yes |
| transfer multiple main processor registers | `d00110` | the mask from $14, walked D0–D7 then A0–A7 as MOVEM's control form walks it | yes, both ways |
| transfer multiple coprocessor registers | `d00001` | one operand per set bit; -(An) walks the operands down and each operand's bytes up (figure 7-38) | yes, to -(An) |
| transfer status register and scanPC | `d0001s` | out: the scanPC, then the SR; in: the SR, then the scanPC, which refills the queue in the space the new SR says | yes, both ways |
| take preinstruction exception | `-11100` | acknowledge, then the four-word frame with the operation word's address | yes |
| take midinstruction exception | `-11101` | acknowledge, then format $9; RTE reads the response CIR again | yes |
| take postinstruction exception | `-11110` | acknowledge, then format $2 with the scanPC as the program counter | yes |

The PC bit is served before anything else, including an exception the primitive
leads to (UM 7.4.2). A protocol violation the processor detects is not written to
the control CIR (UM 7.5.2.1). The aborts write $0001, and the acknowledge writes
$0002; the fourteen undefined bits are zero.

---

## Exceptions

| | frame | vector | RTE goes |
|---|---|---|---|
| no coprocessor (bus error on the first access) | $0, the instruction | 11 | the instruction again |
| F-line from a primitive | abort, $0, the instruction | 11 | the instruction again |
| privilege: cpSAVE, cpRESTORE, supervisor check | ($0 abort for the check), $0 | 8 | the instruction again |
| format error: invalid format word, bad length | abort, $0 | 14 | the instruction again |
| protocol violation | $9 | 13 | the response CIR |
| take pre-, mid-, postinstruction | $0, $9, $2 | the coprocessor's | the instruction / the response CIR / the scanPC |
| cpTRAPcc true | $2, the next instruction | 7 | on |
| interrupt, null with CA and IA | $9, and a throwaway $1 on the interrupt stack when M is set | the device's | the response CIR |
| interrupt, busy or cpSAVE not ready | $0 | the device's | the instruction again |
| bus error on a CIR access after the first, or on an operand | $B | 2 | the faulted access, then on |

---

## What was chosen where the manual does not say

- **Transfer multiple main processor registers** transfers D0 first. UM 7.4.15
  says "in the order D7–D0 and then A7–A0", which is a statement of which file
  goes first as much as of order within it. The MC68881 never issues this
  primitive, so its manual cannot settle it. `doc/manual-contradictions.md`.
- **cpRESTORE of an immediate** is allowed: UM 7.2.3.4.1 and PRM 6's table allow
  it, and PRM 6's prose does not. `doc/manual-contradictions.md`.
- **The reserved word after the format word** is written as zero. UM figure 7-14
  calls it "unused, reserved", and the MC68881 manual says only that it is there
  for alignment.
- **Primitive encodings 0x27, 0x2F and 0x3C–0x3E in bits 13:8** are neither drawn
  nor listed as undefined in UM 7.6. They are taken as the primitive with the DR
  bit ignored: transfer operation word, transfer from instruction stream, and the
  three take-exception primitives.
- **The frame format of a CIR bus error** is the long one: the fault is always
  mid-instruction.

---

## In a whole machine: `make sunos-fpu`

The installed SunOS 4.1.1 of `make sunos-disk`, on two machines that both have an
MC68881: TME's m68020 with its own, and the core with `sim/tme/rd68021_fpu.c` on its
coprocessor interface at CpID 1. Logged in as root, a C program is written to a file with
`echo`, compiled on the machine with `cc -f68881 -O` -- which emits MC68881 instructions
inline -- and run. The two consoles must be identical once the time stamps are masked,
and the core's report must show coprocessor instructions having run.

`sim/tme/rd68021_fpu.c` is the MC68881's side of the protocol, written from MC68881 UM
section 7: which primitive it answers each instruction class with (its table 7-7), when
it asks for an operand and in which format, the order of FMOVEM's registers, the
format words of FSAVE and FRESTORE. Behind it is TME's own floating-point arithmetic,
reached through a private CPU structure that only ever holds FPU state: an operand that
arrives through the operand CIR is handed to TME's routine as a data register or an
immediate, and a result is taken out before the routine would store it. So both
machines compute alike, and what is compared is everything around the arithmetic:
every operand the core moved, in which size and direction, which registers FMOVEM
walked, what the kernel saved and restored at a context switch.

Two things about TME found on the way, neither the core's:

- TME's predicate evaluator makes predicate $0F, "true", false, so an FBT does not
  branch under TME. The MC68881 here uses the same evaluator, so the two machines
  agree; a program relying on it would see the same wrong answer on both.
- TME's own m68020 with its MC68881 hangs after `awk` does floating-point work: the
  machine goes idle and the shell never prompts again. `make sunos-fpu` does not run
  `awk` for that reason.

What the MC68881 front end does not do -- packed decimal out, arithmetic exceptions
enabled in the FPCR, the PC bit, the busy state frame -- is listed in the file; the
compiled program uses none of it.

## What is not checked

- **There is no oracle.** Musashi emulates a floating-point unit inline and never
  speaks this protocol. TME's MC68020 does the same. The only check is the
  scripted coprocessor, written from UM section 7 and cross-checked against the
  other side of the protocol in `MC68881UM_split/11-section-07-coprocessor-interface.pdf`.
  A misreading shared between the model and the core is invisible. The model is
  deliberately thin, a queue per register and a log, so that each test states the
  protocol it expects rather than inheriting it from the model.
- **Against a real MC68881 part.** The scripted coprocessor and the MC68881 front end
  in TME are both written from the manuals; `make sunos-fpu` checks that a real
  operating system and a real compiler's code get the same answers through the core as
  through TME's own CPU, which is the strongest check there is short of hardware.
- **Concurrency.** This processor never overlaps its own execution with a
  coprocessor's, because the dialogue holds the sequencer. What the manual allows
  a coprocessor to do concurrently, it can still do: the processor is released
  after CA = 0.
- **The breakpoint special case** of UM 7.4.3. When a breakpoint acknowledge
  supplied the coprocessor instruction and the coprocessor answers busy, the
  manual re-runs the acknowledge only if an interrupt is pending. Here busy
  restarts from the operation word's address, which holds the BKPT, so the
  acknowledge is run again every time. Not tested.

## Cycle counts

UM section 8 gives no counts for coprocessor instructions, which depend on the
coprocessor. It gives one for RTE out of a coprocessor frame, 31 clocks; this
design takes 75, including the response CIR read that resumes the dialogue.
`doc/timing-divergences.md`.
