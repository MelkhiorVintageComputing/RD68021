# Where this core takes a different number of clocks

`CLAUDE.md`: instruction cycle timings need not match a real MC68020, but **every
divergence must be measured, reported and justified**. Bus *timing* is a
different matter and is not negotiable -- that is `doc/bus-timing-compliance.md`
and `doc/ac-timing.md`.

This file is the register of the differences. Until `make cycles` exists in M12
the numbers here are structural -- what the design does by construction -- and
not measured; every row says which it is. M12 replaces the estimates with counts
against UM section 8's tables.

Faster is always acceptable. Slower is acceptable where it is unavoidable for
area or frequency, and each row below says which of those it is.

---

## The structure that decides most of it

The sequencer does not count clocks. A microword with no bus request costs one
clock; a microword with one costs the whole bus cycle, because it stalls on
`req_ack`. So an instruction's cycle count is the length of its microcode plus
the bus cycles it asks for, and nothing else -- there is no table of cycle
counts anywhere in this design and no way to tune one.

That is a deliberate trade. It makes the timing a consequence of the microcode
rather than a thing to be maintained alongside it, and it is why
`doc/checkpoint.md`'s restart rules are expressible at all.

---

## The rows

| What | Direction | Why | Measured? |
|---|---|---|---|
| **One bus cycle per taken branch** | slower | A flush abandons the prefetch in flight. The bus unit has already taken that operand and cannot be called back, so the cycle runs and the word is thrown away. UM 5.2.5's ECS-aborted cycle is the real part's answer and needs the cache to be worth building; it is M11. | structural |
| **No bus/sequencer concurrency** | slower | UM 8.1.3's overlap is a performance feature. Without it the microcode fills the pipe explicitly, which buys exact and countable timings, a trivial checkpoint -- there is never an unrequested fetch in flight -- and no arbitration between operand and prefetch inside `req_last -> req_valid`, the path that sets the clock. | structural |
| **One idle clock between operands for a source that waits for `req_ack`** | slower | Already in `doc/divergences.md`: `req_last` is combinational and true through S5, so a source that presents its next request within that half clock gets a back-to-back cycle and one that waits for the acknowledge does not. | structural |
| **The cache holding register is not restored by RTE** | slower, once per fault | `doc/checkpoint.md`: it is a pure cache, so discarding it costs one bus cycle after a fault and can never give a wrong answer, where keeping it costs 66 bits of frame and adds a way for a restored pipe to disagree with memory. | structural |
| **The shifts and rotates are one clock whatever the count** | **faster** | `rd68021_shifter.sv` is a barrel. A real MC68020 takes roughly a clock per bit -- UM 8 gives ASL a base plus two per shift -- so `LSL.L #31,D0` is one clock here and about thirty there. | structural |
| **The multiply is one clock** | **faster** | 32 by 32 combinationally, which is four DSP blocks on the FPGA and a long path. M12 measures whether that path is the one that sets the clock and, if it is, pipelines it -- at which point this row moves. | structural |
| **The divide is thirty-two clocks whatever the operands** | mixed | One quotient bit per clock, restoring, with no early termination. UM 8 gives DIVU.W a range because a real part stops early on small quotients. | structural |
| **MOVEM costs about three clocks per register looked at** | slower | The loop tests the mask bit, steps the address and steps the counter in separate microwords, so a MOVEM with an empty mask still walks all sixteen positions. Collapsing it would need a priority encoder on the mask in the micro-address path, which is the one place this design does not put anything. | structural |
| **Every effective address costs its routine's microwords** | slower | The mode decoder dispatches to a shared routine rather than to code inlined per instruction. It is what keeps the decode table to one pattern per instruction instead of eighteen. | structural |

---

## What is NOT a divergence

The bus cycles themselves. Every row of UM tables 5-6 and 5-7 is reproduced at
the pins, every AC specification is feasible at all four speed grades, and a
three-clock cycle is a three-clock cycle. An instruction that takes more clocks
here takes them *between* bus cycles, not inside one.
