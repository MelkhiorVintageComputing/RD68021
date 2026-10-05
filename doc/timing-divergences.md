# Where this core takes a different number of clocks

`CLAUDE.md`: instruction cycle timings need not match a real MC68020, but **every
divergence must be measured, reported and justified**. Bus *timing* is a
different matter and is not negotiable -- that is `doc/bus-timing-compliance.md`
and `doc/ac-timing.md`.

`make cycles` measures 125 instructions against UM section 8's **cache case** --
"the instruction is in the cache but has no overlap" -- and every row is a
regression check: the count this design takes is frozen in `tools/cycles.py`,
and a change to it in either direction fails the target until someone looks at
it and writes the new number down. The table at the end is generated from the
measurement.

Summary, RESET aside: **23 exact, 70 faster, 32 slower; 1117 clocks where the
manual's cache case adds up to 1332** -- 16 % fewer over this mix, from 1499
(12.5 % more) before the work in "Catching up" below. The mix is one of each instruction,
not a program; weighted by what compiled code executes, the memory-operand rows
dominate, and there this design is still slower than the part.

---

## The structure that decides most of it

The sequencer does not count clocks. A microword with no bus request costs one
clock; a microword with one costs the whole bus cycle, because it stalls until the
operand completes -- on `req_ack`, or on the early retire below. So an instruction's cycle count is the length of its microcode plus
the bus cycles it asks for, and nothing else -- there is no table of cycle
counts anywhere in this design and no way to tune one.

That is a deliberate trade. It makes the timing a consequence of the microcode
rather than a thing to be maintained alongside it, and it is why
`doc/checkpoint.md`'s restart rules are expressible at all.

What it costs is measured in the table, and it has one shape: **an operand
costs four or five clocks here and the manual charges three or four.** A bus
microword is the three-clock bus cycle, one clock for the request to reach the
bus unit's S0, and -- for a read whose data the same microword takes -- one
because the read data is latched on the edge that ends S5 and the microword can
only retire after it. Every other bus microword retires on that edge: the early
retire, below. The MC68020 overlaps all of
that with the instruction around it (UM 8.1.3, bus/sequencer concurrency) and
this design does not: the prefetch queue refills on its own, but an OPERAND
cycle is always waited for -- except a write, which is posted (below).
`MOVE.L D0,(A2)` was the cleanest example -- 5 clocks against 4, four on the
write with the pipe advance folded into it -- and is now 3.

### Catching up

Seven changes took the mix from 1499 clocks to 1182, and each is a rule the
microcode now follows rather than a special case:

- **No wait for stage C at the effective-address dispatch.** The mode decoder
  reads stage D alone; waiting there cost a clock on every memory operand
  whenever the queue was empty. One clock on 27 rows.
- **A read takes its own data.** The read data is valid in the bus microword's
  last clock, so the microword that used to take it afterwards is folded into the
  read -- 162 of them, by a pass in `tools/ucode/program.py`, and only where
  `check_rdata_restart` agrees it is safe: a faulted read commits nothing, and
  RTE's rerun reloads the read data before the re-executed read commits. One clock
  per operand read.
- **MOVEM visits only the registers in its list.** A priority encoder on the
  remaining mask names the register, the transfer clears its bit, and the loop is
  two microwords per register. `MOVEM.L D0-D3,(A2)` 80 to 30, `MOVEM.L
  (A0),D4-D5` 68 to 18, the manual's count.
- **The call and return path.** LINK, JSR and BSR push through the stack pointer
  instead of a working register, one clock each; RTS reads its return address and
  jumps in one microword, 12 to 9, a clock faster than the part.
- **Fast effective-address paths.** For `(An)`, `(An)+`, `-(An)` and
  `(d16,An)` in MOVE (both ends), the `<ea>,Dn` and `<ea>,An` ALU forms, TST,
  CLR, ADDQ, SUBQ and CMPI, the opcode decoder picks the mode and the bus
  microword addresses through the register itself -- no EAMODE dispatch, no
  address routine. A read steps `(An)+`/`-(An)` as its own commit-gated
  destination. `ADD.L (A0),D4` 8 to 6 and `MOVE.L (A0),D4` 8 to 6, the manual's
  counts; `MOVE.L (A0),(A2)` 15 to 10. `check_ea_set` in the assembler proves no
  path reaches a microword that reads the EA buffer before something has set it,
  and a tail-merging pass shares the identical last microwords the new paths
  repeat, which keeps the micro-ROM at 1906 words, under 2048.
- **The instruction queue refills a word a clock.** Three changes in
  `rd68021_ifu.sv`. While the holding register's low word is pushed, the cache is
  looked up at the next long word and a hit reloads the register on the same
  edge, so the cache feeds the queue continuously instead of two words in three
  clocks. A full queue that is giving up a word takes one on the same edge. And
  after a flush the first word goes straight into stage D rather than through
  stage C a clock later. One clock off every taken branch, jump, call and return,
  and off most instructions with extension words -- 60 rows, 1286 to 1225.
- **The early retire.** The bus unit decides, on the falling edge entering S5
  where UM Table 5-8's second sample is taken, whether the data operand is
  finishing cleanly -- no bus error, no retry, nothing left of it -- and a
  microword the assembler marks `early` retires on the rising edge that ends S5
  instead of a clock later on the registered acknowledge, which the sequencer
  then discards. The assembler marks every bus microword that does not take the
  read data itself (writes, and reads whose data the next microword takes) and
  is not in interrupt-acknowledge or breakpoint CPU space: 234 of them. A cycle
  that ends in a bus error or a retry never retires early, so the restart rules
  are untouched; `core_fault_tb` proves it with a bus error that arrives only at
  the second sample. One clock off every write: 26 rows, 1225 to 1182 --
  `MOVEM.L D0-D3,(A2)` 29 to 25, the exception entries 4 each.
- **Posted writes.** UM 8.1.3: "the sequencer may also request a bus cycle that
  the bus controller cannot immediately perform. In this case, the bus cycle
  is queued and the bus controller runs the cycle when the current cycle is
  complete." Every plain write in a data space is now taken by the bus unit and
  the microword retires the clock after, while the cycle runs on beside the
  microcode; the next bus request waits for it, a microword that reads state no
  frame carries waits for it, NOP waits for it (PRM 4), and nothing else does.
  Its bus error is taken wherever the sequencer has got to, and RTE reruns the
  write by itself -- `doc/checkpoint.md` rule 9. 22 rows, 1182 to 1117:
  `MOVE.L D0,(A2)` 5 to 3, `MOVEM.L D0-D3,(A2)` 25 to 17, `TRAP` 33 to 27. Over
  real programs: `arith` 64155 to 61513 clocks, `corners` 10389 to 9272, with
  every write's stall down from about three clocks to one. One row is a clock
  slower for it: `RTS` 8 to 9, because its setup's `PEA` now leaves the push
  still on the bus when RTS reads it back -- the overlap moves the wait, it
  does not add one, and PEA's own row is two faster.

---

## The rows

| What | Measured | Direction | Why |
|---|---|---|---|
| **Every memory operand** | writes exact or faster on the fast modes; reads exact to +2; `MOVE.L (A0),(A2)` exact | slower on reads | The shape above. A write is posted and costs the clock the bus unit takes it in. A read still waits: the clock that gets its request to S0, the bus cycle, and the clock after S5 its data needs, and on the other modes the effective-address call as well. Reads are the next candidate -- issuing one ahead of the microword that wants its data. In `arith` the reads stall 3669 clocks (6 %) against the writes' 1350; it needs every microword between the issue and the use to be restartable on its own, which posting a write did not. |
| **MOVEM** | +7 storing four registers; -1 loading two | slower on stores | Two microwords per register -- the transfer and the address step -- and a prologue. |
| **MOVEP** | +9 storing, +8 loading | slower | Four byte transfers, each an operand: a write at four clocks, a read at five. |
| **Exceptions** | TRAP +13, ILLEGAL and line A +18 | slower | A four-word frame is four operand writes at four clocks and a vector read at five, plus the pipe refill at the handler. |
| **RTE** | +10 | slower | Four reads, and the format word is decoded in microcode. |
| **RTE out of a coprocessor frame** | +36 | slower | Six frame reads, the format word tested against five other formats first, and the response CIR read that resumes the dialogue -- a bus cycle to the coprocessor that the manual's 31 may not include. The only coprocessor count UM 8 gives. |
| **Control flow** | BRA.S/W exact, BRA.L +2, JSR +4, BSR +4; RTS -2 | slower, RTS faster | A flush abandons the prefetch in flight, and the queue needs a clock to load the holding register from the cache before the first word reaches stage D. JSR and BSR also write the return address, four clocks against the part's overlapped push. |
| **The shifts and rotates** | 1 clock, every count | **faster** (-3 to -11) | `rd68021_shifter.sv` is a barrel. UM 8 charges ROXL 12. |
| **The multiply** | MULU.W 4, MULU.L 6 | **faster** (-23, -39) | 32 by 32 combinationally in four DSP blocks. It is not on the critical path (`doc/critical-path.md`). |
| **The divide** | 44 for .W, 45 for .L | exact for DIVU.W, **faster** otherwise | One quotient bit per clock, restoring, no early termination: DIVU.W matches exactly and the signed and long forms are up to 47 clocks faster. |
| **Bit fields, register forms** | 2 to 4 | **faster** (-4 to -15) | `rd68021_bitfield.sv` does the field in one clock; BFFFO counts in one. |
| **Bit fields, memory forms** | -2 to +2 | either way | One clock more than they could be: everything the bit-field unit produces comes from the read data, so the pipe advance that ends the instruction is a microword of its own -- a prefetch fault on it would otherwise re-run the result on stale data (`doc/bugs-found.md`). |
| **Status register and CCR immediates, MOVEC** | 2 or 3 | **faster** (-3 to -10) | UM charges twelve; here they are an ordinary register write and a pipe flush. |
| **CMPM and MOVES** | +1 each (M13) | slower | The read data is copied to a working register before the microword that uses it, because that microword also advances the pipe: a prefetch fault there re-executes it after RTE, and read data is not in the fault frame. `doc/bugs-found.md`; `check_rdata_restart` holds every microword to it. |
| **The cache holding register is not restored by RTE** | one bus cycle per fault | slower | `doc/checkpoint.md`: discarding it costs a refetch and can never give a wrong answer. Not in the table -- it only happens on a fault. |

**Cold counts** -- the first pass, with the cache empty -- are in the table's
last column. They are typically five clocks above the warm count for each long
word of instruction the instruction occupies, which is one bus cycle and the
hand-off.

---

## What is NOT a divergence

The bus cycles themselves. Every row of UM tables 5-6 and 5-7 is reproduced at
the pins, every AC specification is feasible at all four speed grades, and a
three-clock cycle is a three-clock cycle. An instruction that takes more clocks
here takes them *between* bus cycles, not inside one.

The cache is not one either: `make cache` holds a core with no cache to the same
data cycles, and a cache hit never appears on the bus at all
(`doc/divergences.md`).

---

## The measurement

`make cycles`, one row per instruction. The manual's cache case is the right
comparison for the warm count: UM 8.2 defines it as "the instruction is in the
cache but has no overlap". The cold count is the first pass round the loop,
with the cache empty; it is not the manual's worst case, which also assumes no
overlap with the prefetch of the next instruction, but it is close.

<!-- cycles:begin -- generated by tools/cycles.py; do not edit -->
| Instruction | UM 8 cache case | | This core, warm | Δ | cold |
|---|---:|---|---:|---:|---:|
| `NOP` | 2 | 2 | 1 | -1 | 7 |
| `MOVEQ #1,D4` | 2 | 2 | 1 | -1 | 7 |
| `ADD.L D0,D4` | 2 | 2 + Dn 0 | 2 |  | 7 |
| `ADD.L (A0),D4` | 6 | 2 + (An) 4 | 6 |  | 10 |
| `ADD.L (A0)+,D4` | 6 | 2 + (An)+ 4 | 6 |  | 10 |
| `ADD.L -(A1),D4` | 7 | 2 + -(An) 5 | 6 | -1 | 10 |
| `ADD.L (8,A0),D4` | 7 | 2 + (d16,An) 5 | 7 |  | 13 |
| `ADD.L ($2000).W,D4` | 6 | 2 + (xxx).W 4 | 8 | **+2** | 13 |
| `ADD.L ($2000).L,D4` | 6 | 2 + (xxx).L 4 | 9 | **+3** | 18 |
| `ADD.L #imm,D4` | 6 | 2 + #.L 4 | 4 | -2 | 15 |
| `ADD.L (4,A0,D3.L),D4` | 9 | 2 + (d8,An,Xn) 7 | 13 | **+4** | 18 |
| `ADD.L ([A0]),D4` | 14 | 2 + ([B],I) 12 | 20 | **+6** | 27 |
| `ADD.L D4,(A0)` | 8 | 4 + (An) 4 | 9 | **+1** | 10 |
| `CMP.L D0,D4` | 2 | 2 | 2 |  | 7 |
| `CMPA.L A0,A2` | 4 | 4 | 3 | -1 | 7 |
| `MULU.W D1,D4` | 27 | 27 | 4 | -23 | 7 |
| `MULU.L D1,D4` | 45 | 43 + #.W,Dn 2 | 6 | -39 | 12 |
| `DIVU.W D1,D4` | 44 | 44 | 44 |  | 44 |
| `DIVS.W D1,D4` | 56 | 56 | 44 | -12 | 44 |
| `DIVU.L D1,D4` | 80 | 78 + #.W,Dn 2 | 44 | -36 | 50 |
| `DIVS.L D1,D4` | 92 | 90 + #.W,Dn 2 | 44 | -48 | 50 |
| `ADDQ.L #1,D4` | 2 | 2 | 1 | -1 | 7 |
| `ADDQ.L #1,(A0)` | 8 | 4 + (An) 4 | 7 | -1 | 11 |
| `ADDI.L #imm,D4` | 6 | 2 + #.L,Dn 4 | 4 | -2 | 15 |
| `ADDI.W #1,(A0)` | 8 | 4 + #.W,(An) 4 | 10 | **+2** | 18 |
| `ABCD D0,D4` | 4 | 4 | 1 | -3 | 7 |
| `ABCD -(A1),-(A2)` | 16 | 16 | 16 |  | 17 |
| `ADDX.L D0,D4` | 2 | 2 | 1 | -1 | 7 |
| `CMPM.L (A0)+,(A1)+` | 9 | 9 | 15 | **+6** | 16 |
| `PACK D0,D4,#0` | 6 | 6 | 3 | -3 | 9 |
| `UNPK D0,D4,#0` | 8 | 8 | 3 | -5 | 9 |
| `CLR.L D4` | 2 | 2 | 2 |  | 7 |
| `CLR.L (A0)` | 6 | 4 + calc (An) 2 | 2 | -4 | 8 |
| `NEG.L D4` | 2 | 2 | 2 |  | 7 |
| `EXT.L D4` | 4 | 4 | 1 | -3 | 7 |
| `NBCD D4` | 6 | 6 | 2 | -4 | 7 |
| `ST D4` | 4 | 4 | 2 | -2 | 7 |
| `TAS D4` | 4 | 4 | 2 | -2 | 7 |
| `TAS (A0)` | 14 | 12 + calc (An) 2 | 13 | -1 | 14 |
| `TST.L D4` | 2 | 2 + Dn 0 | 2 |  | 7 |
| `TST.L (A0)` | 6 | 2 + (An) 4 | 6 |  | 10 |
| `LSL.L #1,D4` | 4 | 4 | 1 | -3 | 7 |
| `LSL.L D1,D4` | 6 | 6 | 1 | -5 | 7 |
| `ASL.L #1,D4` | 8 | 8 | 1 | -7 | 7 |
| `ASR.L #1,D4` | 6 | 6 | 1 | -5 | 7 |
| `ROL.L #1,D4` | 8 | 8 | 1 | -7 | 7 |
| `ROXL.L #1,D4` | 12 | 12 | 1 | -11 | 7 |
| `LSL.W (A0)` | 9 | 5 + (An) 4 | 9 |  | 10 |
| `BTST #3,D4` | 4 | 4 | 3 | -1 | 9 |
| `BTST D1,D4` | 4 | 4 | 2 | -2 | 7 |
| `BSET D1,D4` | 4 | 4 | 2 | -2 | 7 |
| `BTST D1,(A0)` | 8 | 4 + (An) 4 | 9 | **+1** | 10 |
| `BSET D1,(A0)` | 8 | 4 + (An) 4 | 11 | **+3** | 12 |
| `BTST #3,(A0)` | 8 | 4 + #.W,(An) 4 | 11 | **+3** | 18 |
| `BFTST D4{0:8}` | 6 | 6 | 2 | -4 | 8 |
| `BFEXTU D4{0:8},D5` | 8 | 8 | 3 | -5 | 9 |
| `BFINS D5,D4{0:8}` | 10 | 10 | 4 | -6 | 10 |
| `BFFFO D4{0:8},D5` | 18 | 18 | 3 | -15 | 9 |
| `BFCHG D4{0:8}` | 12 | 12 | 4 | -8 | 10 |
| `BFEXTU (A0){0:8},D5` | 15 | 13 + #.W,(An) 2 | 12 | -3 | 18 |
| `BFINS D5,(A0){0:8}` | 16 | 14 + #.W,(An) 2 | 14 | -2 | 20 |
| `BFTST (A0){4:32}` | 17 | 15 (5 bytes) + #.W,(An) 2 | 14 | -3 | 20 |
| `BRA.S (taken)` | 6 | 6 | 6 |  | 13 |
| `BRA.W (taken)` | 6 | 6 | 6 |  | 15 |
| `BRA.L (taken)` | 6 | 6 | 8 | **+2** | 21 |
| `BEQ.S (not taken)` | 4 | 4 | 2 | -2 | 7 |
| `BEQ.W (not taken)` | 6 | 6 | 3 | -3 | 8 |
| `BEQ.L (not taken)` | 6 | 6 | 5 | -1 | 15 |
| `DBF (count not expired)` | 6 | 6 | 6 |  | 10 |
| `DBF (count expired)` | 10 | 10 | 4 | -6 | 8 |
| `DBT (cc true)` | 6 | 6 | 3 | -3 | 8 |
| `EXG D0,D4` | 2 | 2 | 3 | **+1** | 7 |
| `SWAP D4` | 4 | 4 | 1 | -3 | 7 |
| `MOVE SR,D4` | 4 | 4 | 2 | -2 | 7 |
| `MOVE D0,CCR` | 4 | 4 + Dn 0 | 2 | -2 | 7 |
| `MOVE #$2700,SR` | 10 | 8 + #.W 2 | 3 | -7 | 8 |
| `MOVE A0,USP` | 2 | 2 | 2 |  | 7 |
| `MOVEC CACR,D4` | 6 | 6 | 3 | -3 | 8 |
| `MOVEC D4,SFC` | 12 | 12 | 3 | -9 | 8 |
| `MOVEM.L D0-D3,(A2)` | 18 | 4 + 3x4 + #.W,(An) 2 | 17 | -1 | 24 |
| `MOVEM.L (A0),D4-D5` | 18 | 8 + 4x2 + #.W,(An) 2 | 17 | -1 | 24 |
| `MOVEP.L D4,(0,A2)` | 17 | 17 | 18 | **+1** | 26 |
| `MOVEP.L (0,A0),D4` | 18 | 18 | 26 | **+8** | 32 |
| `MOVES.L (A0),D4` | 9 | 7 + #.W,(An) 2 | 12 | **+3** | 17 |
| `MOVE.L D0,D4` | 2 | Rn -> Dn | 2 |  | 7 |
| `MOVEA.L A0,A4` | 2 | Rn -> An | 3 | **+1** | 7 |
| `MOVE.W #1,D4` | 4 | #.W -> Dn | 2 | -2 | 8 |
| `MOVE.L #imm,D4` | 6 | #.L -> Dn | 4 | -2 | 15 |
| `MOVE.L D0,(A2)` | 4 | Rn -> (An) | 3 | -1 | 8 |
| `MOVE.L D0,-(A2)` | 5 | Rn -> -(An) | 4 | -1 | 7 |
| `MOVE.L (A0),D4` | 6 | (An) -> Dn | 6 |  | 10 |
| `MOVE.L (8,A0),D4` | 7 | (d16,An) -> Dn | 7 |  | 13 |
| `MOVE.L (4,A0,D3.L),D4` | 9 | (d8,An,Xn) -> Dn | 13 | **+4** | 18 |
| `MOVE.L (A0),(A2)` | 7 | (An) -> (An) | 7 |  | 11 |
| `MOVE.L (A0)+,(A2)+` | 7 | (An)+ -> (An)+ | 8 | **+1** | 10 |
| `ORI #0,CCR` | 12 | 12 | 2 | -10 | 8 |
| `ANDI #$FFFF,SR` | 12 | 12 | 3 | -9 | 8 |
| `LEA (A0),A4` | 4 | 2 + calc (An) 2 | 3 | -1 | 7 |
| `LEA (8,A0),A4` | 4 | 2 + calc (d16,An) 2 | 3 | -1 | 8 |
| `PEA (A0)` | 7 | 5 + calc (An) 2 | 6 | -1 | 8 |
| `LINK.W A4,#-8` | 5 | 5 | 6 | **+1** | 8 |
| `LINK.L A4,#-8` | 6 | 6 | 8 | **+2** | 15 |
| `UNLK A4` | 6 | 6 | 7 | **+1** | 9 |
| `JMP (A5)` | 6 | 4 + jump (An) 2 | 6 |  | 13 |
| `JSR (A3)` | 7 | 5 + jump (An) 2 | 9 | **+2** | 17 |
| `BSR.S` | 7 | 7 | 9 | **+2** | 12 |
| `RTS` | 10 | 10 | 9 | -1 | 9 |
| `RTR` | 14 | 14 | 17 | **+3** | 19 |
| `RTD #4` | 10 | 10 | 12 | **+2** | 12 |
| `RTE (format 0)` | 21 | 21 | 31 | **+10** | 31 |
| `RTE (coprocessor)` | 31 | 31 | 63 | **+32** | 64 |
| `CHK.L D1,D4 (in range)` | 8 | 8 + Dn 0 | 5 | -3 | 7 |
| `CHK2.L (A0),D4` | 22 | 18 + #.W,(An) 4 | 22 |  | 29 |
| `CMP2.L (A0),D4` | 22 | 18 + #.W,(An) 4 | 21 | -1 | 28 |
| `CAS.L (unsuccessful)` | 14 | 12 + #.W,(An) 2 | 13 | -1 | 20 |
| `CAS.L (successful)` | 17 | 15 + #.W,(An) 2 | 17 |  | 17 |
| `CAS2.L (successful)` | 25 | 25 | 38 | **+13** | 46 |
| `TRAPV (no trap)` | 4 | 4 | 2 | -2 | 7 |
| `TRAPF` | 4 | 4 | 2 | -2 | 7 |
| `TRAPF.W` | 6 | 6 | 3 | -3 | 9 |
| `TRAPF.L` | 8 | 8 | 4 | -4 | 15 |
| `TRAP #0` | 20 | 20 | 27 | **+7** | 37 |
| `ILLEGAL` | 20 | 20 | 32 | **+12** | 32 |
| `line A` | 20 | 20 | 32 | **+12** | 32 |
| `RESET` | 518 | 518 | 515 | -3 | 515 |
| `FNOP` | 18 | MC68881 8-7 18 | 18 |  | 18 |
| `FBEQ.W (taken)` | 20 | MC68881 8-7 20 | 21 | **+1** | 21 |
| `FBEQ.W (not taken)` | 18 | MC68881 8-7 18 | 18 |  | 18 |
| `FSEQ D0` | 18 | MC68881 8-7 18 | 22 | **+4** | 30 |
| `FMOVE.L D0,FPCR` | 28 | MC68881 8-6 28 | 25 | -3 | 33 |
| `FMOVE.L FPCR,D0` | 31 | MC68881 8-6 31 | 27 | -4 | 35 |
| `FMOVE.L (A0),FPCR` | 35 | MC68881 8-6 33 + (An) 2 | 29 | -6 | 37 |
| `FMOVEM.L FPcr*3,(A0)` | 47 | MC68881 8-6 27+6n + (An) 2 | 45 | -2 | 53 |
| `FMOVEM.X (A0),FP0-FP2` | 130 | MC68881 8-6 35+31n + (An) 2 | 96 | -34 | 104 |
| `FMOVEM.X FP0-FP2,-(A7)` | 118 | MC68881 8-6 37+25n + -(An) 6 | 97 | -21 | 105 |
| `FSAVE -(A7) (idle)` | 58 | MC68881 8-8 52 + -(An) 6 | 63 | **+5** | 65 |
| `FRESTORE (A7)+ (idle)` | 63 | MC68881 8-8 57 + (An)+ 6 | 72 | **+9** | 73 |
<!-- cycles:end -->

