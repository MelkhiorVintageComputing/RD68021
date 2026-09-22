# The special status word

UM figure 6-8. One word, at `+$0A` of both the short and the long bus fault
frame, and the only part of either frame a handler is allowed to write — and
then only three of its bits.

```
 15   14   13   12   11   10   9    8    7    6    5    4    3    2    1    0
 FC   FB   RC   RB   0    0    0    DF   RM   RW   SIZE     0    FC2  FC1  FC0
                                              \_______/
```

| | | |
|---|---|---|
| `FC` | 15 | stage C was used and found invalid: a bus error on its prefetch |
| `FB` | 14 | stage B likewise |
| `RC` | 13 | a fault occurred during a prefetch for stage C. **Always set when `FC` is** |
| `RB` | 12 | stage B likewise |
| `DF` | 8 | a data fault caused the exception, and is still to be rerun |
| `RM` | 7 | the data cycle was part of a read-modify-write |
| `RW` | 6 | 1 = read, 0 = write |
| `SIZE` | 5:4 | the size of the data access, as SIZ1/SIZ0 encodes it — UM table 5-2 |
| `FC2–FC0` | 2:0 | the address space of the data cycle |

Bits 11–9 and 3 are reserved. They are written as zero and RTE ignores them.

## Who owns which half

**The high half is the pipe's and the low half is the bus unit's**, and the two
halves are about different things: UM 6.2.1, "the least significant half of the
SSW applies to data cycles only", and "data and instruction stream faults may be
pending simultaneously; the fault handler should be able to recognize any
combination of the FC, FB, RC, RB, and DF bits". So the word is *assembled* when
the frame is built and *taken apart* when RTE reads it back, and there is no
sixteen-bit register anywhere that holds it.

| bits | lives in | as |
|---|---|---|
| `FC`, `FB` | `rd68021_ifu` | `c_f_q`, `b_f_q` — already there, already moved along the pipe with the words they describe |
| `RC`, `RB` | `rd68021_ifu` | `stg_c_rerun`, `stg_b_rerun` |
| `DF`, `RM`, `RW`, `SIZE`, `FC2–FC0` | `rd68021_biu` | the **fault snapshot**, below |

## The fault snapshot

The frame is built by bus cycles. Those cycles run through the same operand
engine that faulted, so by the time the special status word reaches `+$0A` the
registers that would have described the fault have been overwritten four times.
Everything the frame says about the faulted access is therefore **latched on the
clock the fault is recognised** and read from the latch afterwards:

| latch | frame | what |
|---|---|---|
| `flt_addr` | `+$10` | the data fault address, which is the address of the **next** byte still to transfer, not of the operand |
| `flt_dob` | `+$18` | the data output buffer, right justified |
| `flt_dib` | `+$2C` | the data input buffer, long frame only |
| `flt_bytes` | SSW `SIZE`, and an internal word | the residual byte count |
| `flt_fc`, `flt_rw`, `flt_rmc` | SSW | the rest of the low half |

`flt_bytes` is in the frame **twice**, and the second copy is not redundant:
`SIZE` is a two-bit field over UM table 5-2, which encodes 1, 2, 3 and 4 bytes
and cannot say five. Five is what a bit-field operand spanning five bytes leaves,
so the residual goes in an internal word as well and `SIZE` carries what it can.

## The rerun bits are a promise, not a record

UM 6.2.1 defines `RC` and `RB` so that they mean *what RTE will do*, not *what
went wrong* — `FC` and `FB` are the record. Three consequences the microcode is
written to:

1. **`RC` is always set when `FC` is.** The rerun bit is the superset: a stage
   that faulted must be rerun, and a stage that merely has a prefetch pending
   must also be rerun, so `FC = 1, RC = 0` is not a state this core can produce.
2. **An address error sets the rerun bits and not the fault bits.** UM 6.2.1:
   "if an address error exception occurs, the fault bits written to the stack
   frame are not set ... and the rerun bits alone show the cause of the
   exception". No bus cycle ran, so nothing faulted; the words are simply
   missing.
3. **A handler may clear `RC`, `RB` and `DF`, and nothing else.** UM 6.2.2 is
   explicit, and our RTE trusts exactly those three and re-derives everything
   else from the rest of the frame. A handler that repaired stage C writes the
   word into the stage C image at `+$0C` and clears `RC`; RTE then takes the
   image as valid. It is told not to touch `FC`, so `FC` may be set on a stage
   RTE does not rerun, and that is not a contradiction.

## What RTE does with it

UM 6.2.3. The instruction always executes; what it reruns depends on what the
handler left:

| | |
|---|---|
| `DF` set | rerun the faulted data access from `flt_*` restored into the bus unit, and — if `RM` is also set — rerun the whole read-modify-write |
| `DF` clear, `RM` set | UM 6.2.2: "the RTE instruction expects the entire operation to have been completed". Retire the instruction |
| `RC` or `RB` set | run the prefetch for that stage. `FC`/`FB` set as well means the cycle faulted and is rerun; clear means the stage was merely pending. This core expresses it as the **queue depth**: RC and RB say which stages RTE still owes a word, the depth comes back from them, and a queue with room asks the bus unit for the next long word by itself. There is no separate rerun path for a prefetch to get wrong, and no flag carried across the rest of the RTE |
| `RC`, `RB`, `DF` all clear | the images on the stack are taken as valid and nothing is rerun |

"If a fault occurs when the RTE instruction attempts to rerun the bus cycle(s),
the processor creates a new stack frame on the supervisor stack **after
deallocating the previous frame**" — so the rerun happens after the stack pointer
has been stepped, and a fault there is an ordinary bus error and not a double
bus fault.

A fault **while RTE is reading the frame** is a different matter and *is* a
double bus fault — UM 6.1.2, "or while the processor is loading internal state
information from the stack during the execution of an RTE instruction".
