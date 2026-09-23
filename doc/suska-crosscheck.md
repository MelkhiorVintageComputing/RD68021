# The bus against a second core

`make suska` runs one probe program, `sim/suska/bus_probe.S`, on this core and on
the Suska WF68K30L -- a 68030-class VHDL design by somebody else, under ghdl --
against the same three memories, and compares what each put on the bus.

The WF68K30L is in `Inputs/ref/Suska_Configware/68K30L/` and is subject to the
rule in `CLAUDE.md`: it is **run**, never read. Its entity declaration is what an
instantiation needs and is all that was looked at.

## Why

Every bus testbench here was written from UM section 5 by the same hands that
wrote the bus unit. If the manual was misread, the tests agree with the misreading
and pass. A second implementation, built by somebody else from the same family's
manual, cannot make the same mistake by accident -- and where it disagrees, the
manual decides, as it does for Musashi (`doc/divergences.md`).

## What is compared

One line per bus cycle, at the negation of AS: function code, address, SIZ,
direction, the write data on all four lanes, and whether RMC was asserted. The
**data** cycles -- function codes 1 and 5 -- are compared in order, one bus cycle
at a time. That is UM tables 5-5, 5-6 and 5-7 in full: how each operand is split
across the port, what SIZ says at every step, and what is on every lane of a
write, including the lanes no port enables.

Instruction fetches are only counted. The two cores fetch differently by design
-- this one a long word at a time through a holding register and a cache, the
WF68K30L a word at a time -- so their order and number mean nothing to each other.
Bus-cycle *timing* is not compared either: it is `doc/bus-timing-compliance.md`'s
business, checked edge by edge against the manual's figures.

The probe writes and reads a byte, a word and a long word at each of the four byte
offsets on a 32-, a 16- and an 8-bit port; then MOVEM to and from the 16- and
8-bit ports; CAS.L, CAS.W and TAS, which hold RMC across their cycles; a long word
across a word boundary on the 16-bit port; and a few stack writes.

## What came of it

**164 data cycles identical**: address, SIZ, direction, RMC and all four write
lanes.

It took two rounds to get there, and the first found a real difference:

- **D7–D0 of a three-byte write at A1A0 = 00.** UM table 5-5 puts OP0 there --
  the byte sent the cycle before, footnoted "output but never used" -- and this
  core drove OP1. No port enables that lane, so nothing could observe it, but the
  pins are the one place this project promises to be exact, and the manual names
  the byte. Fixed; `doc/bugs-found.md` and `doc/divergences.md`.
- **CAS.W to the 16-bit port took an exception here.** Not the core: this side's
  testbench left the 16- and 8-bit memories uninitialised, the compare read X, and
  X steered the micro-address. Both testbenches now start every memory at zero.
