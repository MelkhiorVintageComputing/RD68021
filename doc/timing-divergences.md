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

Summary, RESET aside: **17 exact, 55 faster, 53 slower; 1316 clocks where the
manual's cache case adds up to 1332** -- 1 % fewer over this mix, from 1499 (12.5 %
more) before the work in "Catching up" below. The mix is one of each instruction,
not a program; weighted by what compiled code executes, the memory-operand rows
dominate, and there this design is still slower than the part.

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

What it costs is measured in the table, and it has one shape: **an operand
costs five clocks here and the manual charges three or four.** A bus microword
is the three-clock bus cycle, one clock for the request to reach the bus unit's
S0, and one because the acknowledge is registered. The MC68020 overlaps all of
that with the instruction around it (UM 8.1.3, bus/sequencer concurrency) and
this design does not: the prefetch queue refills on its own, but an OPERAND
cycle is always waited for. `ADD.L (A0),D4` is the cleanest example -- 8 clocks
against 6: the effective-address dispatch, the `(An)` routine, five on the read,
and the add.

### Catching up

Four changes took the mix from 1499 clocks to 1316, and each is a rule the
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

---

## The rows

| What | Measured | Direction | Why |
|---|---|---|---|
| **Every memory operand** | +2 to +4 per instruction; `MOVE.L (A0),(A2)` +8 | slower | The shape above. What is left is the effective-address call and the two clocks of handshake around each bus cycle. Overlapping operand cycles with microcode needs the bus unit to accept a request before the microword that wants the data -- a queue, and a second outstanding request in `doc/checkpoint.md`'s restart rules. |
| **MOVEM** | +12 storing four registers; exact loading two | slower on stores | Two microwords per register -- the transfer and the address step -- and a prologue; the write's five clocks against the part's four are the rest. |
| **MOVEP** | +13 and +14 | slower | Four byte transfers, each an operand at five clocks. |
| **Exceptions** | TRAP +18, ILLEGAL and line A +23 | slower | A four-word frame is four operand writes and a vector read at five clocks each, plus the pipe refill at the handler. |
| **RTE** | +14 | slower | Four reads, and the format word is decoded in microcode. |
| **RTE out of a coprocessor frame** | +44 | slower | Six frame reads, the format word tested against five other formats first, and the response CIR read that resumes the dialogue -- a bus cycle to the coprocessor that the manual's 31 may not include. The only coprocessor count UM 8 gives. |
| **Control flow** | BRA.S/W +1, BRA.L +4, JSR +6, BSR +6; RTS -1 | slower, RTS faster | A flush abandons the prefetch in flight, and the queue refills from the cache at two words per three clocks. JSR and BSR also write the return address. |
| **The shifts and rotates** | 2 clocks, every count | **faster** (-2 to -10) | `rd68021_shifter.sv` is a barrel. UM 8 charges ROXL 12. |
| **The multiply** | MULU.W 4, MULU.L 7 | **faster** (-23, -38) | 32 by 32 combinationally in four DSP blocks. It is not on the critical path (`doc/critical-path.md`). |
| **The divide** | 44 for .W, 45 for .L | exact for DIVU.W, **faster** otherwise | One quotient bit per clock, restoring, no early termination: DIVU.W matches exactly and the signed and long forms are up to 47 clocks faster. |
| **Bit fields, register forms** | 3 to 5 | **faster** (-3 to -14) | `rd68021_bitfield.sv` does the field in one clock; BFFFO counts in one. |
| **Bit fields, memory forms** | -1 to +3 | either way | One clock more than they could be: everything the bit-field unit produces comes from the read data, so the pipe advance that ends the instruction is a microword of its own -- a prefetch fault on it would otherwise re-run the result on stale data (`doc/bugs-found.md`). |
| **Status register and CCR immediates, MOVEC** | 3 | **faster** (-7 to -9) | UM charges twelve; here they are an ordinary register write and a pipe flush. |
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
| `NOP` | 2 | 2 | 2 |  | 7 |
| `MOVEQ #1,D4` | 2 | 2 | 2 |  | 7 |
| `ADD.L D0,D4` | 2 | 2 + Dn 0 | 2 |  | 7 |
| `ADD.L (A0),D4` | 6 | 2 + (An) 4 | 8 | **+2** | 9 |
| `ADD.L (A0)+,D4` | 6 | 2 + (An)+ 4 | 9 | **+3** | 9 |
| `ADD.L -(A1),D4` | 7 | 2 + -(An) 5 | 9 | **+2** | 9 |
| `ADD.L (8,A0),D4` | 7 | 2 + (d16,An) 5 | 8 | **+1** | 13 |
| `ADD.L ($2000).W,D4` | 6 | 2 + (xxx).W 4 | 8 | **+2** | 13 |
| `ADD.L ($2000).L,D4` | 6 | 2 + (xxx).L 4 | 9 | **+3** | 18 |
| `ADD.L #imm,D4` | 6 | 2 + #.L 4 | 5 | -1 | 15 |
| `ADD.L (4,A0,D3.L),D4` | 9 | 2 + (d8,An,Xn) 7 | 13 | **+4** | 18 |
| `ADD.L ([A0]),D4` | 14 | 2 + ([B],I) 12 | 20 | **+6** | 27 |
| `ADD.L D4,(A0)` | 8 | 4 + (An) 4 | 12 | **+4** | 13 |
| `CMP.L D0,D4` | 2 | 2 | 2 |  | 7 |
| `CMPA.L A0,A2` | 4 | 4 | 3 | -1 | 7 |
| `MULU.W D1,D4` | 27 | 27 | 4 | -23 | 7 |
| `MULU.L D1,D4` | 45 | 43 + #.W,Dn 2 | 7 | -38 | 12 |
| `DIVU.W D1,D4` | 44 | 44 | 44 |  | 44 |
| `DIVS.W D1,D4` | 56 | 56 | 44 | -12 | 44 |
| `DIVU.L D1,D4` | 80 | 78 + #.W,Dn 2 | 45 | -35 | 50 |
| `DIVS.L D1,D4` | 92 | 90 + #.W,Dn 2 | 45 | -47 | 50 |
| `ADDQ.L #1,D4` | 2 | 2 | 2 |  | 7 |
| `ADDQ.L #1,(A0)` | 8 | 4 + (An) 4 | 12 | **+4** | 13 |
| `ADDI.L #imm,D4` | 6 | 2 + #.L,Dn 4 | 5 | -1 | 15 |
| `ADDI.W #1,(A0)` | 8 | 4 + #.W,(An) 4 | 14 | **+6** | 21 |
| `ABCD D0,D4` | 4 | 4 | 2 | -2 | 7 |
| `ABCD -(A1),-(A2)` | 16 | 16 | 19 | **+3** | 20 |
| `ADDX.L D0,D4` | 2 | 2 | 2 |  | 7 |
| `CMPM.L (A0)+,(A1)+` | 9 | 9 | 15 | **+6** | 16 |
| `PACK D0,D4,#0` | 6 | 6 | 4 | -2 | 9 |
| `UNPK D0,D4,#0` | 8 | 8 | 4 | -4 | 9 |
| `CLR.L D4` | 2 | 2 | 2 |  | 7 |
| `CLR.L (A0)` | 6 | 4 + calc (An) 2 | 8 | **+2** | 11 |
| `NEG.L D4` | 2 | 2 | 2 |  | 7 |
| `EXT.L D4` | 4 | 4 | 2 | -2 | 7 |
| `NBCD D4` | 6 | 6 | 2 | -4 | 7 |
| `ST D4` | 4 | 4 | 2 | -2 | 7 |
| `TAS D4` | 4 | 4 | 2 | -2 | 7 |
| `TAS (A0)` | 14 | 12 + calc (An) 2 | 13 | -1 | 14 |
| `TST.L D4` | 2 | 2 + Dn 0 | 2 |  | 7 |
| `TST.L (A0)` | 6 | 2 + (An) 4 | 8 | **+2** | 9 |
| `LSL.L #1,D4` | 4 | 4 | 2 | -2 | 7 |
| `LSL.L D1,D4` | 6 | 6 | 2 | -4 | 7 |
| `ASL.L #1,D4` | 8 | 8 | 2 | -6 | 7 |
| `ASR.L #1,D4` | 6 | 6 | 2 | -4 | 7 |
| `ROL.L #1,D4` | 8 | 8 | 2 | -6 | 7 |
| `ROXL.L #1,D4` | 12 | 12 | 2 | -10 | 7 |
| `LSL.W (A0)` | 9 | 5 + (An) 4 | 13 | **+4** | 14 |
| `BTST #3,D4` | 4 | 4 | 4 |  | 9 |
| `BTST D1,D4` | 4 | 4 | 2 | -2 | 7 |
| `BSET D1,D4` | 4 | 4 | 2 | -2 | 7 |
| `BTST D1,(A0)` | 8 | 4 + (An) 4 | 9 | **+1** | 10 |
| `BSET D1,(A0)` | 8 | 4 + (An) 4 | 14 | **+6** | 15 |
| `BTST #3,(A0)` | 8 | 4 + #.W,(An) 4 | 12 | **+4** | 18 |
| `BFTST D4{0:8}` | 6 | 6 | 3 | -3 | 8 |
| `BFEXTU D4{0:8},D5` | 8 | 8 | 4 | -4 | 9 |
| `BFINS D5,D4{0:8}` | 10 | 10 | 5 | -5 | 10 |
| `BFFFO D4{0:8},D5` | 18 | 18 | 4 | -14 | 9 |
| `BFCHG D4{0:8}` | 12 | 12 | 5 | -7 | 10 |
| `BFEXTU (A0){0:8},D5` | 15 | 13 + #.W,(An) 2 | 14 | -1 | 19 |
| `BFINS D5,(A0){0:8}` | 16 | 14 + #.W,(An) 2 | 19 | **+3** | 24 |
| `BFTST (A0){4:32}` | 17 | 15 (5 bytes) + #.W,(An) 2 | 16 | -1 | 21 |
| `BRA.S (taken)` | 6 | 6 | 7 | **+1** | 14 |
| `BRA.W (taken)` | 6 | 6 | 7 | **+1** | 16 |
| `BRA.L (taken)` | 6 | 6 | 10 | **+4** | 22 |
| `BEQ.S (not taken)` | 4 | 4 | 2 | -2 | 7 |
| `BEQ.W (not taken)` | 6 | 6 | 3 | -3 | 8 |
| `BEQ.L (not taken)` | 6 | 6 | 5 | -1 | 15 |
| `DBF (count not expired)` | 6 | 6 | 7 | **+1** | 11 |
| `DBF (count expired)` | 10 | 10 | 4 | -6 | 8 |
| `DBT (cc true)` | 6 | 6 | 3 | -3 | 8 |
| `EXG D0,D4` | 2 | 2 | 3 | **+1** | 7 |
| `SWAP D4` | 4 | 4 | 2 | -2 | 7 |
| `MOVE SR,D4` | 4 | 4 | 2 | -2 | 7 |
| `MOVE D0,CCR` | 4 | 4 + Dn 0 | 2 | -2 | 7 |
| `MOVE #$2700,SR` | 10 | 8 + #.W 2 | 3 | -7 | 8 |
| `MOVE A0,USP` | 2 | 2 | 2 |  | 7 |
| `MOVEC CACR,D4` | 6 | 6 | 3 | -3 | 8 |
| `MOVEC D4,SFC` | 12 | 12 | 3 | -9 | 8 |
| `MOVEM.L D0-D3,(A2)` | 18 | 4 + 3x4 + #.W,(An) 2 | 30 | **+12** | 36 |
| `MOVEM.L (A0),D4-D5` | 18 | 8 + 4x2 + #.W,(An) 2 | 18 |  | 24 |
| `MOVEP.L D4,(0,A2)` | 17 | 17 | 31 | **+14** | 38 |
| `MOVEP.L (0,A0),D4` | 18 | 18 | 27 | **+9** | 32 |
| `MOVES.L (A0),D4` | 9 | 7 + #.W,(An) 2 | 12 | **+3** | 17 |
| `MOVE.L D0,D4` | 2 | Rn -> Dn | 2 |  | 7 |
| `MOVEA.L A0,A4` | 2 | Rn -> An | 3 | **+1** | 7 |
| `MOVE.W #1,D4` | 4 | #.W -> Dn | 3 | -1 | 8 |
| `MOVE.L #imm,D4` | 6 | #.L -> Dn | 5 | -1 | 15 |
| `MOVE.L D0,(A2)` | 4 | Rn -> (An) | 9 | **+5** | 11 |
| `MOVE.L D0,-(A2)` | 5 | Rn -> -(An) | 10 | **+5** | 11 |
| `MOVE.L (A0),D4` | 6 | (An) -> Dn | 8 | **+2** | 9 |
| `MOVE.L (8,A0),D4` | 7 | (d16,An) -> Dn | 8 | **+1** | 13 |
| `MOVE.L (4,A0,D3.L),D4` | 9 | (d8,An,Xn) -> Dn | 13 | **+4** | 18 |
| `MOVE.L (A0),(A2)` | 7 | (An) -> (An) | 15 | **+8** | 16 |
| `MOVE.L (A0)+,(A2)+` | 7 | (An)+ -> (An)+ | 17 | **+10** | 17 |
| `ORI #0,CCR` | 12 | 12 | 3 | -9 | 8 |
| `ANDI #$FFFF,SR` | 12 | 12 | 3 | -9 | 8 |
| `LEA (A0),A4` | 4 | 2 + calc (An) 2 | 3 | -1 | 7 |
| `LEA (8,A0),A4` | 4 | 2 + calc (d16,An) 2 | 3 | -1 | 8 |
| `PEA (A0)` | 7 | 5 + calc (An) 2 | 9 | **+2** | 11 |
| `LINK.W A4,#-8` | 5 | 5 | 9 | **+4** | 11 |
| `LINK.L A4,#-8` | 6 | 6 | 11 | **+5** | 18 |
| `UNLK A4` | 6 | 6 | 7 | **+1** | 9 |
| `JMP (A5)` | 6 | 4 + jump (An) 2 | 7 | **+1** | 14 |
| `JSR (A3)` | 7 | 5 + jump (An) 2 | 13 | **+6** | 21 |
| `BSR.S` | 7 | 7 | 13 | **+6** | 16 |
| `RTS` | 10 | 10 | 9 | -1 | 9 |
| `RTR` | 14 | 14 | 18 | **+4** | 18 |
| `RTD #4` | 10 | 10 | 13 | **+3** | 13 |
| `RTE (format 0)` | 21 | 21 | 32 | **+11** | 32 |
| `RTE (coprocessor)` | 31 | 31 | 67 | **+36** | 68 |
| `CHK.L D1,D4 (in range)` | 8 | 8 + Dn 0 | 5 | -3 | 7 |
| `CHK2.L (A0),D4` | 22 | 18 + #.W,(An) 4 | 23 | **+1** | 29 |
| `CMP2.L (A0),D4` | 22 | 18 + #.W,(An) 4 | 22 |  | 28 |
| `CAS.L (unsuccessful)` | 14 | 12 + #.W,(An) 2 | 14 |  | 20 |
| `CAS.L (successful)` | 17 | 15 + #.W,(An) 2 | 17 |  | 17 |
| `CAS2.L (successful)` | 25 | 25 | 38 | **+13** | 39 |
| `TRAPV (no trap)` | 4 | 4 | 2 | -2 | 7 |
| `TRAPF` | 4 | 4 | 2 | -2 | 7 |
| `TRAPF.W` | 6 | 6 | 4 | -2 | 9 |
| `TRAPF.L` | 8 | 8 | 5 | -3 | 15 |
| `TRAP #0` | 20 | 20 | 38 | **+18** | 48 |
| `ILLEGAL` | 20 | 20 | 43 | **+23** | 43 |
| `line A` | 20 | 20 | 43 | **+23** | 43 |
| `RESET` | 518 | 518 | 515 | -3 | 515 |
<!-- cycles:end -->

