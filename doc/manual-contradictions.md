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

**Not yet followed either way — decided in M13.**

§5.4.3 says the coprocessor interface register is selected by **A5–A0**. Figure 5-31,
"MC68020/EC020 CPU Space Address Encoding", draws the `CP REG` field on **A4–A0**, with
A15–A13 carrying the CpID and A12–A5 zero.

§7.3's register map (the eleven CIRs at offsets `$00`–`$1C`) needs five bits to address a
word-granular register set spanning `$00`–`$1F`, which favours the figure. Cross-check
against `MC68881UM_split/11-section-07-coprocessor-interface.pdf`, which is the same
protocol seen from the coprocessor's side, before deciding.

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
