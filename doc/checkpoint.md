# The checkpoint register set

The MC68020 can recover from a bus error. UM 6.2.3, on what RTE does with a fault
frame:

> If the RC bit is set when the processor executes an RTE instruction, the
> processor may execute a bus cycle to prefetch the instruction word for stage C
> of the pipe ... If the DF bit is set when the processor reads the stack frame,
> it reruns the faulted data access.

That constrains the whole microarchitecture. Every scrap of state an instruction
accumulates has to live somewhere the fault frame can save and RTE can reload,
which means the working registers must be a **fixed, named set** and not whatever
a given piece of microcode finds convenient.

This document freezes that set. It is written now, before a single instruction
exists, because retrofitting it after the datapath is built is the single largest
risk in the plan — and it is the one thing the MC68010 project singles out as
having been worth doing first.

Everything below is generated from `tools/ucode/frames.py`, which is the only
place any of these numbers exists. `make ucode-check` fails the build if the
generated `rtl/gen/rd68021_frame_pkg.sv` has drifted from it, and it is the first
thing `make check` runs.

---

## Which frame, and when

Table 6-5 gives format `$A` for "Address Error or Bus Error — Execution Unit at
Instruction Boundary" and `$B` for "Instruction Execution in Progress". Picking
the rule is the irreversible decision; the frames themselves are bookkeeping.

**This design emits `$A` only for a fault on a prefetch taken with no instruction
in progress. Every data fault produces `$B`.**

That follows from a choice made in M5 and not from the frame format: the microcode
stalls on `req_ack`, so there is no bus/sequencer concurrency in this phase and a
data access always has an instruction in progress. A real MC68020, whose bus
controller runs ahead, can retire an instruction while its write is still
outstanding and so can produce a short frame for a data fault.

The manual licenses this explicitly, UM 6.4:

> The system software should not depend on a particular exception generating a
> particular stack frame. For compatibility with future devices, the software
> should be able to handle any type of stack frame for any type of exception.

It is recorded in `doc/divergences.md` all the same.

---

## Why a private encoding of the internal words is legitimate

UM 6.1.12:

> for the long stack frame, the processor compares the version number in the stack
> with its own version number. The version number is located in the most
> significant nibble (bits 15–12) of the word at location SP + $36 in the long
> stack frame. This validity check is required in a multiprocessor system to
> ensure that the data is properly interpreted by the RTE instruction. ... If the
> frame is invalid or inaccessible, the processor takes a format error or a bus
> error exception, respectively.

So Motorola's own contract is: the internal words are private, they are
version-stamped, and a processor that does not recognise the stamp must refuse the
frame rather than misinterpret it. Software that saves a frame and later restores
it — which is what every operating system does — cannot tell the difference.
Software that synthesises internal words from scratch was already not portable
across implementations.

RD68021 therefore carries its own version number and refuses any other with a
format error, vector 14.

**The short frame has no version field.** UM 6.1.12 validates the stamp only for
the long frame; for a short one "the processor first checks the format value on
the stack for validity" and nothing more. So a short frame this design wrote could
be read by something else with no way to know it should not be.

> **Rule: format `$A` carries no private state at all.** Everything it needs is
> either an architectural field or derivable from one.

`tools/ucode/frames.py` enforces that, and the enforcement is negative-tested.

What makes it possible is that UM 6.2 states the derivation itself:

> For instruction faults, when the short bus fault stack frame applies, the
> address of the pipe stage B word is the value in the PC plus four, and the
> address of the stage C word is the value in the PC plus two. For the long
> format, the long word at SP + $24 contains the address of the stage B word; the
> address of the stage C word is the address of the stage B word minus two.

At an instruction boundary the pipe is sequential, so the short frame needs no
stage B address. That is exactly why the long frame carries one and the short one
does not.

---

## The cache holding register is not saved

UM 1.6's pipe is fed from a 32-bit cache holding register, and that register is
64 bits of state plus its address and validity — a fifth of the budget.

**It is not checkpointed. RTE restores it as invalid and the next prefetch
re-reads the long word.** It is a pure cache of the last long word fetched: the
cost of discarding it is one bus cycle after a fault, and it can never give a
wrong answer. The alternative costs 66 bits and adds a way for a restored pipe to
disagree with memory.

This is a cycle-count divergence, measured and justified in
`doc/timing-divergences.md` when M12 measures it.

---

### The frames

| Format | Words | Name | Layout |
|---|--:|---|---|
| `$0` | 4 | four-word | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec |
| `$1` | 4 | throwaway four-word | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec |
| `$2` | 6 | six-word | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec, `+$08` instr_addr ×2 |
| `$9` | 10 | coprocessor midinstruction | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec, `+$08` instr_addr ×2, `+$0C` internal ×4 |
| `$A` | 16 | short bus fault | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec, `+$08` internal, `+$0A` ssw, `+$0C` stage_c, `+$0E` stage_b, `+$10` dfa ×2, `+$14` internal, `+$16` internal, `+$18` dob ×2, `+$1C` internal, `+$1E` internal |
| `$B` | 46 | long bus fault | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec, `+$08` internal, `+$0A` ssw, `+$0C` stage_c, `+$0E` stage_b, `+$10` dfa ×2, `+$14` internal, `+$16` internal, `+$18` dob ×2, `+$1C` internal ×4, `+$24` stage_b_addr ×2, `+$28` internal ×2, `+$2C` dib ×2, `+$30` internal ×3, `+$36` version, `+$38` internal ×18 |

### The private words of the long frame

| Offset | Bits | Register | What |
|---|---|---|---|
| `+$08` | 2:0 | `bytes` | residual byte count of the faulted operand |
| `+$08` | 3 | `g0` | inside group-0 exception processing |
| `+$08` | 4 | `notrace` | the trace pending for this instruction was cancelled |
| `+$08` | 5 | `rr_pending` | a rerun flag out of the frame is still to be applied |
| `+$14` | 15:0 | `upc` | the micro-address to resume at |
| `+$16` | 15:0 | `stage_d` | the instruction word being decoded |
| `+$1C` | 31:0 | `t0` | working register |
| `+$20` | 31:0 | `t1` | working register |
| `+$28` | 31:0 | `t2` | working register |
| `+$30` | 31:0 | `t3` | working register |
| `+$34` | 15:0 | `xw` | the extension-word latch |
| `+$36` | 0 | `stage_d_f` | stage D came from a faulted prefetch |
| `+$38` | 31:0 | `ea_latch` | the address output buffer |
| `+$3C` | 31:0 | `ea_save` | the copy of it taken at the fault |
| `+$40` | 31:0 | `pc_fetch` | the next long word the pipe will fetch |

**492 bits available, 279 used, 12 words spare** (`+$44`, `+$46`, `+$48`, `+$4A`, `+$4C`, `+$4E`, `+$50`, `+$52`, `+$54`, `+$56`, `+$58`, `+$5A`).

### The frozen set

| Unit | Register | Bits | Lands in | |
|---|---|--:|---|---|
| `ifu` | `stg_d` | 16 | `stage_d` |  |
| `ifu` | `stg_c` | 16 | `stage_c` | frame +$0C |
| `ifu` | `stg_b` | 16 | `stage_b` | frame +$0E |
| `ifu` | `stg_c_fault` | 1 | `ssw` | SSW FC |
| `ifu` | `stg_b_fault` | 1 | `ssw` | SSW FB |
| `ifu` | `stg_c_rerun` | 1 | `ssw` | SSW RC |
| `ifu` | `stg_b_rerun` | 1 | `ssw` | SSW RB |
| `ifu` | `stg_d_fault` | 1 | `stage_d_f` |  |
| `ifu` | `pc_d` | 32 | `pc` | the frame's own program counter |
| `ifu` | `stg_b_addr` | 32 | `stage_b_addr` | long frame +$24; short frame derives it |
| `ifu` | `pc_fetch` | 32 | `pc_fetch` |  |
| `ifu` | `chr` | 32 | `derived` | not saved: invalidated by RTE, re-fetched |
| `ifu` | `chr_addr` | 30 | `derived` | likewise |
| `ifu` | `chr_valid` | 1 | `derived` | likewise -- always restored as invalid |
| `ifu` | `chr_fault` | 1 | `derived` | likewise |
| `biu` | `flt_addr` | 32 | `dfa` | frame +$10 |
| `biu` | `flt_dob` | 32 | `dob` | frame +$18 |
| `biu` | `flt_dib` | 32 | `dib` | long frame +$2C |
| `biu` | `ssw` | 16 | `ssw` | frame +$0A |
| `biu` | `flt_bytes` | 3 | `bytes` | SIZ cannot encode a five-byte residual |
| `biu` | `flt_rmc` | 1 | `ssw` | SSW RM |
| `biu` | `flt_rw` | 1 | `ssw` | SSW RW |
| `biu` | `flt_fc` | 3 | `ssw` | SSW FC2-FC0 |
| `seq` | `upc` | 16 | `upc` |  |
| `seq` | `t0` | 32 | `t0` |  |
| `seq` | `t1` | 32 | `t1` |  |
| `seq` | `t2` | 32 | `t2` |  |
| `seq` | `t3` | 32 | `t3` |  |
| `seq` | `ea_latch` | 32 | `ea_latch` |  |
| `seq` | `ea_save` | 32 | `ea_save` |  |
| `seq` | `xw` | 16 | `xw` |  |
| `seq` | `g0` | 1 | `g0` |  |
| `seq` | `notrace` | 1 | `notrace` |  |
| `seq` | `rr_pending` | 1 | `rr_pending` |  |
| `seq` | `sr` | 16 | `sr` | frame +$00 |

### Not checkpointed, and why

| | |
|---|---|
| D0-D7, A0-A6 | architectural |
| USP, ISP, MSP | architectural; A7 is not a register, it is whichever of these the S and M bits select |
| VBR, SFC, DFC | architectural |
| CACR, CAAR | architectural |
| the instruction cache | a cache; UM 4.1 caches instructions only, so it is architecturally invisible |

---

## The rules this imposes on the microcode

Seven, and the microcode is written to them rather than audited against them
afterwards.

1. **No state outside the set.** A microword may not stash a value anywhere but
   the registers above. If a sequence needs a fifth temporary, the answer is to
   restructure it or to add a register here — with the budget recomputed.
   `assemble.py` will fail the build on a destination with no home.

2. **A faulted microword ends but commits nothing** — no register write, no pipe
   advance, no address-register update, no condition code. The state the frame
   records is therefore the state at the *start* of the faulted access, and
   resuming at the saved micro-address re-executes the microword and reissues
   exactly the same request. There is no separate restart path to get wrong.

3. **The unit of restart is the operand, not the bus cycle.** `rd68021_biu` splits
   an operand into however many cycles the port and the alignment need, and it
   keeps the residual; a microword that issues an operand must be restartable
   from its own first clock with that residual reloaded. This is why the bus unit
   has architectural state and a restore port, which the MC68010 design had no
   need of.

4. **`stg_b`, `stg_c` and the pipe's fault bits are architectural during a
   fault.** They are frame fields and SSW bits, so they may not be used as
   scratch. `xw` exists for an extension word that must outlive a pipe advance.

5. **RMC sequences are atomic to the handler.** UM 6.2.2: if `RM` is set and `DF`
   cleared, RTE expects the whole read-modify-write to have been completed by the
   handler. The microcode therefore needs an entry point reachable from RESUME
   meaning "the read-modify-write is already done, retire the instruction".

6. **Only `DF`, `RB` and `RC` may have been modified** by the handler — UM 6.2.2,
   "the only bits in the SSW that may be modified are DF, RB, and RC". Our RTE
   honours exactly those three and trusts nothing else it reads back.

7. **Recompute the budget on every addition.** The table above is printed from the
   source, so it cannot be out of date; the discipline is that the number is
   looked at.

---

## How this will be verified

The test was fixed by this document before the machinery to run it exists, which
is the point: if the checkpoint set is wrong, these cannot be made to pass by
patching around them.

- `MOVEM.L (A0),D0-D7` faulting on its fifth transfer, handled, and continued with
  every remaining register moved and none moved twice.
- A misaligned `MOVE.L` to an 8-bit port faulting on its third bus cycle: the
  frame must record the **residual** address, size and data output buffer, and RTE
  with `DF` set must transfer only the two remaining bytes.
- A `CAS.L` faulting on its write, handled twice over: once by a handler that
  emulates the whole instruction and clears `DF`, once by leaving `DF` set.
- A prefetch fault discovered two instructions later: format `$A`, `FC` and `RC`
  set, a handler that repairs stage C in the frame and clears `RC`, and RTE
  continuing with no bus cycle.
- The same, unrepaired, with RTE rerunning the prefetch itself.
- An address error, which runs no bus cycle and which UM 6.2.1 says sets the rerun
  bits but not the fault bits.
- A double bus fault driving HALT out.
- `make paging`: a memory model that raises BERR on an unmapped page, a handler
  that maps it and returns, and a program that touches **every combination in
  Table 5-6** — operand size × A1A0 × port size — across a page boundary, in every
  addressing mode. That target is the Sun-3 requirement made checkable, and it is
  the one that must never be allowed to regress.
