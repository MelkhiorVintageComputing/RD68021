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

**This design emits `$B` for every bus error and every address error, and never
`$A`.** RTE still accepts a format `$A` frame.

Two things decide it:

- **Data faults.** The microcode stalls until its operand completes (an early
  retire happens only on a clean completion), so there is no
  bus/sequencer concurrency and a data access always has an instruction in
  progress. A real MC68020, whose bus controller runs ahead, can retire an
  instruction while its write is still outstanding, and so can produce a short
  frame for a data fault.
- **Prefetch faults.** One is taken by the microword that needs the missing
  word, which is usually the instruction's own last microword -- the one that
  writes its result and advances the pipe. RTE re-executes that microword, so it
  has to find everything it reads where it left it: the working registers, the
  latched operand size, the extension word. The long frame carries all of those;
  the short frame carries none of them, and it cannot, because it has no version
  field (below). A short frame was built for a while, for the case that looked
  like a boundary. It lost the working registers to the fault handler, and SunOS
  found it twice: once as a forked child that could not start, once as a `ps -U`
  whose `MOVEA.L D7,A0` at the end of a page loaded A0 from a T0 the kernel had
  reused. `doc/bugs-found.md`.

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
format error, vector 14 (`rte_check_long`: the word is read into `xw` and the
condition `VERBAD` compares it). Before that, and before anything is restored,
RTE reads the frame's last word, for both bus fault formats: UM 6.1.8 has it
"read from both ends of the stack frame to make sure it is accessible", and a
bus error there is an ordinary data fault on a microword that has committed
nothing (rule 2). A frame refused for either reason is left as it was.

**The short frame has no version field.** UM 6.1.12 validates the stamp only for
the long frame; for a short one "the processor first checks the format value on
the stack for validity" and nothing more. So a short frame this design wrote could
be read by something else with no way to know it should not be.

> **Rule: format `$A` carries no private state at all.** Everything it needs is
> either an architectural field or derivable from one.

`tools/ucode/frames.py` enforces that for the private assignment. This design
satisfies it the simple way: it never builds a short frame (above).

The rule binds RTE too. A short frame RTE meets came from software or from
another processor, so RTE reads none of its internal words
(`check_short_reads` in `tools/ucode/assemble.py` fails the build if it does):
`rte_fault_short` restores the architectural fields and supplies what an
instruction boundary implies. Stage D is read from memory at the program
counter, in the stacked status register's program space; `DF` on a write
becomes a posted write of its own (rule 9), sized by `SIZE`; and it resumes at
`rte_boundary`, a microword that only decodes.

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
| `$9` | 10 | coprocessor midinstruction | `+$00` sr, `+$02` scanpc ×2, `+$06` fmtvec, `+$08` instr_addr ×2, `+$0C` internal, `+$0E` opword, `+$10` ea ×2 |
| `$A` | 16 | short bus fault | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec, `+$08` internal, `+$0A` ssw, `+$0C` stage_c, `+$0E` stage_b, `+$10` dfa ×2, `+$14` internal, `+$16` internal, `+$18` dob ×2, `+$1C` internal, `+$1E` internal |
| `$B` | 46 | long bus fault | `+$00` sr, `+$02` pc ×2, `+$06` fmtvec, `+$08` internal, `+$0A` ssw, `+$0C` stage_c, `+$0E` stage_b, `+$10` dfa ×2, `+$14` internal, `+$16` internal, `+$18` dob ×2, `+$1C` internal ×4, `+$24` stage_b_addr ×2, `+$28` internal ×2, `+$2C` dib ×2, `+$30` internal ×3, `+$36` version, `+$38` internal ×18 |

### The private words of the long frame

| Offset | Bits | Register | What |
|---|---|---|---|
| `+$08` | 2:0 | `bytes` | residual byte count of the faulted operand |
| `+$08` | 4 | `notrace` | the trace pending for this instruction was cancelled |
| `+$08` | 6 | `eapc` | the base of the effective address under way is the PC |
| `+$08` | 8:7 | `opsize` | the operand size the dispatching microword resolved |
| `+$08` | 9 | `eadst` | the effective address under way is a MOVE destination |
| `+$36` | 2:1 | `trmode` | the trace mode this instruction began with |
| `+$36` | 3 | `flow` | this instruction has changed the flow |
| `+$36` | 4 | `pc_kept` | pc_prev was taken at a flush, not at the decode |
| `+$46` | 31:0 | `pc_prev` | the address of the instruction before this one |
| `+$08` | 15 | `dvalid` | stage D holds an instruction word |
| `+$14` | 15:0 | `upc` | the micro-address to resume at |
| `+$16` | 15:0 | `stage_d` | the instruction word being decoded |
| `+$1C` | 31:0 | `t0` | working register |
| `+$20` | 31:0 | `t1` | working register |
| `+$28` | 31:0 | `t2` | working register |
| `+$30` | 31:0 | `t3` | working register |
| `+$34` | 15:0 | `xw` | the extension-word latch |
| `+$38` | 31:0 | `ea_latch` | the address output buffer |
| `+$3C` | 31:0 | `ea_save` | the copy of it taken at the fault |
| `+$40` | 31:0 | `pc_fetch` | the next long word the pipe will fetch |
| `+$44` | 15:0 | `link` | the return address of the subroutine under way |
| `+$4A` | 15:0 | `cprim` | the coprocessor response primitive being served |
| `+$52` | 15:0 | `rmwupc` | the micro-address the read-modify-write under way starts again at |
| `+$08` | 5 | `posted` | the faulted access was a posted write, which RTE reruns by itself |
| `+$08` | 12:10 | `irqlvl` | the level of the interrupt being taken |

**492 bits available, 369 used, 7 words spare** (`+$4C`, `+$4E`, `+$50`, `+$54`, `+$56`, `+$58`, `+$5A`).

### The frozen set

| Unit | Register | Bits | Lands in | |
|---|---|--:|---|---|
| `ifu` | `d_q` | 16 | `stage_d` |  |
| `ifu` | `d_v_q` | 1 | `dvalid` | a prefetch fault taken with the pipe empty -- after a flush -- has no stage D, and the word at +$16 is whatever the last one was. Restoring it as valid ran it: SunOS's forked child executed its parent's RTE |
| `ifu` | `c_q` | 16 | `stage_c` | frame +$0C |
| `ifu` | `b_q` | 16 | `stage_b` | frame +$0E |
| `ifu` | `c_f_q` | 1 | `ssw` | SSW FC |
| `ifu` | `b_f_q` | 1 | `ssw` | SSW FB |
| `ifu` | `pc_d_q` | 32 | `pc` | the frame's own program counter |
| `ifu` | `fill_q` | 32 | `stage_b_addr` | long frame +$24; short frame derives it. The same register as pc_fetch: stage B is two before the fill point. |
| `ifu` | `fill_q` | 32 | `pc_fetch` |  |
| `ifu` | `chr_q` | 32 | `derived` | not saved: invalidated by RTE, re-fetched |
| `ifu` | `chr_addr_q` | 30 | `derived` | likewise |
| `ifu` | `chr_v_q` | 1 | `derived` | likewise -- always restored as invalid |
| `ifu` | `chr_f_q` | 1 | `derived` | likewise |
| `biu` | `flt_addr` | 32 | `dfa` | frame +$10 |
| `biu` | `flt_dib` | 32 | `dib` | long frame +$2C |
| `biu` | `flt_dob` | 32 | `dob` | frame +$18 |
| `biu` | `flt_bytes` | 3 | `bytes` | SIZ cannot encode a five-byte residual |
| `biu` | `flt_rmc` | 1 | `ssw` | SSW RM |
| `biu` | `flt_rw` | 1 | `ssw` | SSW RW |
| `biu` | `flt_fc` | 3 | `ssw` | SSW FC2-FC0 |
| `seq` | `df_q` | 1 | `ssw` | SSW DF -- see biu.flt_df |
| `seq` | `flt_upc` | 16 | `upc` | the faulted microword's own address, latched at the fault: by the time the frame builder writes +$14 its own upc is deep inside itself |
| `seq` | `link_q` | 16 | `link` | seq = RET returns here |
| `seq` | `t_q` | 32 | `t0` | one array of four in the RTL |
| `seq` | `t_q` | 32 | `t1` |  |
| `seq` | `t_q` | 32 | `t2` |  |
| `seq` | `t_q` | 32 | `t3` |  |
| `seq` | `ea_q` | 32 | `ea_latch` |  |
| `seq` | `ea_save` | 32 | `ea_save` | the frame builder's own pointer, so that ea_q -- which is the instruction's and is +$38 -- is not disturbed. RTE ignores what lands in this slot |
| `seq` | `xw_q` | 16 | `xw` |  |
| `seq` | `notrace_q` | 1 | `notrace` | the instruction was never executed, so UM 6.1.7 does not trace it |
| `seq` | `eapc_q` | 1 | `eapc` | seq = EADEC latches it; EABASE reads it |
| `seq` | `size_q` | 2 | `opsize` | seq = EAMODE latches it; the shared EA routines read it |
| `seq` | `eadst_q` | 1 | `eadst` | likewise, and rsel reads it |
| `seq` | `trace_mode_q` | 2 | `trmode` | UM 6.1.7 fixes it at the start of the instruction, so a fault may not lose it |
| `seq` | `flow_q` | 1 | `flow` | likewise: whether the instruction had changed the flow before it faulted |
| `seq` | `pc_prev_q` | 32 | `pc_prev` | a trace frame carries it at +$08 |
| `seq` | `pc_kept_q` | 1 | `pc_kept` | pc_prev_q was taken at a flush, so the decode must not overwrite it |
| `seq` | `sr_q` | 16 | `sr` | frame +$00 |
| `seq` | `rmw_upc_q` | 16 | `rmwupc` | UM 6.2.3: with DF set, RTE "reruns the entire instruction" of a read-modify-write -- CAS, CAS2 or TAS -- so it resumes at the start of the locked sequence, which the microword marked RMW latched, and not at the faulted access |
| `seq` | `cprim_q` | 16 | `cprim` | UM 7.5.2.8: a bus error on any CIR access but the first, or on an operand a primitive moves, is an ordinary bus error, and RTE goes back to the primitive it interrupted |
| `seq` | `post_flt_q` | 1 | `posted` | doc/checkpoint.md rule 9: the faulted access belongs to no microword -- the write was posted and the instruction went on -- so RTE runs it on its own and resumes at the microword that was interrupted |
| `seq` | `irq_taking_q` | 3 | `irqlvl` | the level of the interrupt being taken, from the dispatch to the acknowledge. A posted write's fault can land in between -- doc/checkpoint.md rule 9 -- and the acknowledge after RTE has to ask for the same level |

### Not checkpointed, and why

| | |
|---|---|
| D0-D7, A0-A6 | architectural |
| USP, ISP, MSP | architectural; A7 is not a register, it is whichever of these the S and M bits select |
| VBR, SFC, DFC | architectural |
| CACR, CAAR | architectural |
| the instruction cache | a cache; UM 4.1 caches instructions only, so it is architecturally invisible |
| `stopped_q` | PRM 6 STOP. A stopped processor runs no bus cycle, so no fault can be recognised while it is stopped, and the interrupt that ends the stopped state clears the bit on the clock it enters exception processing |
| `rsto_q`, `rsto_cnt`, `rsto_arm_q` | PRM 6 RESET. The instruction asks for no bus cycle and the sequencer is stalled for its 512 clocks, so the pipe stands still too and nothing can fault in the middle of it |

---

## How the rules are enforced

Rule 3 -- *every register an instruction accumulates has a home here or it does
not exist* -- is about **registers**, so it is checked against the registers.
`tools/ucode/frames.py`'s `check_rtl` reads every clocked process in `rtl/`,
collects the signal each one writes, and insists that every one is either in the
frozen set above or in `EXEMPT` with a reason. `make ucode` runs it and fails.

It is checked in both directions. A register added without a thought about what
a fault does to it is a build failure; so is a register renamed in the RTL and
not in the table, which shows up twice -- the new name unaccounted for and the
old one missing.

`PENDING` holds the rows whose register does not exist yet, each with the
milestone that builds it, so that this table can describe the finished design
while the check still says which parts of it are not there. A pending register
that arrives without being taken off the list is also a failure.

The scraper itself had to be fixed once, and in the direction that matters: it
required the *whole* left-hand side of a line to be an identifier, which kept
`if (a <= b)` out of the answer but also hid `irq_taking_q`, whose assignment
shared a line with the `else if (...)` guarding it. An invisible register is an
unreported one. It now looks at every `<=` on the line and rejects the ones that
stand inside an expression -- unbalanced parentheses to the left, or a blocking
assignment outside parentheses on the same line.

**This replaced a check that read the microcode's DESTINATIONS.** That one could
not see a register the microcode never names as a destination, and five got past
it: `link_q`, `eapc_q`, `size_q`, `eadst_q` and `cnt_q`, every one of them
per-instruction state. The first would have surfaced in M9 as a wild jump on a
demand-paged access -- a fault inside an effective-address subroutine restores
`upc` from the frame and then returns through a link register holding whatever
the handler last put there.

**A home is not enough: it has to be used.** `check_rtl` proves every register
has a slot; `check_frame_fields`, in `tools/ucode/assemble.py`, proves the frame
builder writes each private slot of the long frame from its register and RTE
reads it back. Two slots are exempt with a reason: `ea_save`, which is the
builder's own pointer, and `pc_fetch`, which is the same register as +$24. Until
it existed `cprim` had a slot at +$4A that the builder filled with zero and RTE
skipped. A handler that ran a coprocessor instruction then resumed an
interrupted operand transfer with its own primitive's length
(`doc/bugs-found.md`).

## The rules this imposes on the microcode

Nine, and the microcode is written to them rather than audited against them
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
   need of. What RTE hands back -- the residual with `DF` set, nothing with it
   clear -- belongs to the **resumed microword's own request**: the bus unit
   holds it until that request is presented, and drops it when the resumed
   microword retires without one, which is a prefetch fault taken at a boundary.
   Handing it to whichever request came first gave it to the next instruction
   (`doc/bugs-found.md`).

4. **`stg_b`, `stg_c` and the pipe's fault bits are architectural during a
   fault.** They are frame fields and SSW bits, so they may not be used as
   scratch. `xw` exists for an extension word that must outlive a pipe advance.

5. **RMC sequences are atomic to the handler.** UM 6.2.2: if `RM` is set and `DF`
   cleared, RTE expects the whole read-modify-write to have been completed by the
   handler, "even if the fault occurred on the first read cycle"; RESUME then goes
   to `rte_rmw_done`, which only ends the instruction. UM 6.2.3: with `DF` set,
   RTE "reruns the entire instruction"; RESUME goes to the micro-address at
   `+$52`, `rmwupc`, the start of the locked sequence, which the microword marked
   `mark = RMW` latched. Either way nothing is handed back to the bus unit.

6. **Only `DF`, `RB` and `RC` may have been modified** by the handler — UM 6.2.2,
   "the only bits in the SSW that may be modified are DF, RB, and RC". Our RTE
   honours exactly those three and trusts nothing else it reads back.

7. **A condition reads a register as it stands, never as the microword is about
   to leave it.** The write is a non-blocking assignment landing on the edge the
   branch steers, so a microword that writes a register and branches on it
   branches on the value before it. `check_cond_dst` in `assemble.py` fails the
   build on that pairing, for the conditions that read a register -- the ones
   that read the ALU *result* are excluded, because testing what the current
   microword computes is what they exist for. RTE on a throwaway frame is what
   found it: the format word was latched and tested on one microword, so the
   test saw the frame the previous RTE had unwound.

8. **Recompute the budget on every addition.** The table above is printed from the
   source, so it cannot be out of date; the discipline is that the number is
   looked at.

9. **A posted write belongs to no microword.** UM 8.1.3: a write is queued and
   the bus controller runs it while the sequencer goes on. The microword that
   asked for it retires the clock after the bus unit takes it, and its commits
   stand -- the register step, the pipe advance, the condition codes. One is
   outstanding at most: the bus unit takes nothing else until it is done.
   - Its bus error is taken at whatever microword M is presented when it
     arrives, as a data fault on M's own access would be: M commits nothing,
     `upc` is M, the frame has DF, the residual, DOB and the write's function
     code, and **`posted`** at +$08 bit 5.
   - RTE with `posted` and DF set hands the residual to the bus unit, which
     runs it by itself as a posted write again -- not for M's request -- and
     RESUME goes to M. With DF clear the handler did it (UM 6.2.2), and RTE
     only resumes. If the rerun faults, the new frame describes M with a write
     outstanding, which is UM 6.2.3's "new stack frame after deallocating the
     previous frame".
   - So any microword may be M, and one that reads state no frame carries may
     not: it **waits** for writes posted before it instead. `mark_sync` in
     `tools/ucode/assemble.py` marks them -- readers of `ea_save`, of RTE's
     taken-apart status word, of the divider, of an earlier read's data or end
     code; RESUME, RTE's hand-back, STOP and RESET; and NOP, which PRM 4 makes
     wait. The level of an interrupt being taken is in the frame (+$08 bits
     12:10), so the interrupt entry needs no wait and may be M like any other.
     One more waits in the RTL: a microword about to take a prefetch fault --
     for its own posted write too -- so that the write, which came first,
     faults first; its write's fault is then an ordinary one on its own
     request.
   - Not posted: read-modify-write (indivisible), CPU space other than a
     coprocessor interface register past the first access (its bus errors are
     answers), and anything that waits for some other reason than an earlier
     read's data. `check_posted` holds the marking
     to that, and every core testbench checks that no waiting microword ever
     retires with a write outstanding.

---

## How RTE puts it back

The restore is one microword per field, read straight into the register the
field came from, in an order in which each one is dead by the time it is
written. Three things about it are worth stating, because each is a decision:

- **The read pointer is `ea_save`.** It is the one register in the set RTE does
  not have to put back: the slot it lands in at `+$3C` held the frame builder's
  own pointer and means nothing afterwards.
- **The queue depth is not in the frame.** `RC` and `RB` are, and they say which
  stages RTE still owes a word; the depth comes back from them. A queue with
  room asks the bus unit for the next long word by itself, so UM 6.2.3's "the
  processor may execute a bus cycle to prefetch the instruction word for stage C
  of the pipe (if it is required)" happens with no separate rerun path at all.
- **Resuming is a jump and nothing else.** Rule 2 is what buys that: the faulted
  microword committed nothing, so re-executing it reissues exactly the same
  request. `seq = RESUME` sets the micro-address from the frame and there is no
  restart sequence to get wrong.

The status register is written last and the stack pointer is stepped before it,
for the reason UM 6.1.12 gives the four-word frame: writing the status register
is what decides which of the three stack pointers A7 means.

---

## How this is verified

`sim/tb/core_fault_tb.sv`, 134 checks; `sim/tb/core_paging_tb.sv`, 288 over
72 cases; and `sim/tb/core_cow_tb.sv`, 118, which runs a real kernel and user
process (`sim/programs/cow.S`) through copy-on-write. Every frame is compared as **memory**, field by field at the offsets
UM table 6-5 gives: a frame this core writes and reads back consistently, but
writes in the wrong place, would pass any check made through its own registers.

The list below was written before the machinery to run it existed, which was
the point. What each case is really asking is in the second column, because a
check that cannot fail on the bug it is aimed at is not a check -- and two here
could not, until they were rewritten.

| | what would have to be wrong for it to fail |
|---|---|
| `MOVEM.L (A0)+,D0-D7` faulting on its fifth transfer | the remaining mask -- which names the next register, lowest bit first -- is not restored, and the address register ends somewhere other than eight steps on |
| a misaligned `MOVE.L` to an 8-bit port faulting on its third cycle | the frame records the operand rather than the **residual**. A sentinel is left over the bytes that already went, because both a correct rerun and a wrong one leave the right four bytes in memory |
| a data fault repaired by the handler, `DF` cleared | RTE redoes the access. The handler writes a value the instruction would not have, for the same reason |
| a data read emulated by the handler into `+$2C`, with the page still missing | RTE runs a bus cycle of its own instead of taking the operand out of the frame |
| a prefetch fault discovered two instructions later | the exception is taken when the cycle faults rather than when the word is wanted |
| the same, repaired in the frame and `RC` cleared | RTE refetches instead of accepting the image. The handler writes an instruction that is **not** the one in memory |
| an address error | a bus cycle runs, or the fault bits are set where UM 6.2.1 says only the rerun bits are |
| a double bus fault | `HALT` is not driven, or the processor carries on |
| every combination of operand size, alignment and port width faulted across a page boundary | anything above, in a shape the directed cases did not think of. Half the cases straddle and half do not, and the sweep counts its own faults so that it cannot pass by not faulting |
| a user program writing to shared read-only pages in every shape copy-on-write meets -- plain, `(An)+`, `-(An)`, memory to memory, `ADDQ`, `BSET`, `BFINS`, `CAS`, a misaligned long word part-written, one across two protected pages, `JSR`, `LINK`, `MOVEM` to `-(SP)` part-way down its list, `PEA`, a byte to `-(A7)` -- each handled by a kernel that saves registers with `MOVEM`, copies the page with a `DBF` loop, calls a subroutine that uses the bit-field unit and the multiplier, and returns with `DF` set; one page the kernel writes itself and clears `DF`; and the first handler taking a fault of its own on its page-table read, two frames deep | RTE does not put back what the handler's work overwrote -- the working registers, the extension word, the MOVEM mask -- or reruns more than the faulted access, or returns to the wrong mode. The memory model refuses a faulted write, so each write has to land exactly once; the testbench checks memory, every register, the condition codes each instruction left, the user stack pointer, the frame the kernel logged for each fault, and that the program's last instruction, a privileged one, traps. Mutating RTE to skip T0 or the data output buffer fails it |

`CAS2` is the one row of the original list still without a faulting case.

---

## How this was to be verified

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
