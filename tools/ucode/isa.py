#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68021

"""The microword: every field, every encoding, and the datapath they drive.

    python3 tools/ucode/isa.py          # the layout

This is the single definition. `rtl/gen/rd68021_ucode_pkg.sv` is generated from
it, so the RTL and the microcode cannot drift apart: a field the microcode writes
and the RTL does not read is a build failure, not a debugging session.

THE DATAPATH, as of M5.

    A source ─┐
              ├─► ALU ─► y[31:0] ─► destination
    B source ─┘

Each microword is one clock. A microword with no bus request costs one clock; one
with a bus request costs the whole bus cycle, because the sequencer stalls on
req_ack and does not count clocks. Instruction cycle counts fall out of that
structure rather than being designed.

THE PIPE. UM 1.6: instruction words enter at stage B and proceed to C and D, and
"an instruction word is completely decoded when it reaches stage D". So stage D is
the instruction register: it holds the opcode for the whole instruction and is not
disturbed by reading extension words, which come from stage C.

    CONSUME   C <- B, B <- next.  D untouched: an extension word has been eaten.
    ADV       D <- C, C <- B, B <- next.  The instruction is over.
    FLUSH     the pipe is emptied and refilled from the ALU result.

`pc_d` is the address of stage D and `stg_b_addr` the address of stage B, both
carried as real registers because CONSUME moves one and not the other. UM 6.2 is
what makes that observable: at an instruction boundary the pipe is sequential and
the short frame derives the stage addresses from the PC, but mid-instruction it is
not, which is exactly why the long frame carries stage B's address at SP+$24.
"""

import sys
from collections import OrderedDict


def enc(*names):
    """An encoding: name -> value, in the order written.

    A repeated name is a build failure and not a silent renumbering. Adding
    SHR8 to the ALU a second time -- it was already there for MOVEP -- left the
    list one shorter than it looked, and what showed it was Verilator noticing
    that two arms of a case statement had become the same one. The encoding is
    where that should be caught.
    """
    dup = [n for i, n in enumerate(names) if n in names[:i]]
    if dup:
        raise SystemExit('isa: %s appears more than once in an encoding'
                         % ', '.join(sorted(set(dup))))
    return OrderedDict((n, i) for i, n in enumerate(names))


# --------------------------------------------------------------------------
# How the next micro-address is chosen.
# --------------------------------------------------------------------------
SEQ = enc(
    'NEXT',      # go to the address in the `next` field
    'DECODE',    # end of instruction: the opcode decoder supplies the address
    'COND',      # `next`, with bit 0 set if the selected condition holds
    'EADEC',     # the extension-word decoder supplies the address
    'EAMODE',    # the mode/register field of stage D supplies the address, so
                 # that one opcode pattern covers every addressing mode instead
                 # of one pattern per mode
    'RET',       # return to the micro-address in the link register
    'RESUME',    # ... or to the one RTE read out of a fault frame, which is the
                 # microword that faulted: doc/checkpoint.md rule 2 makes it
                 # re-executable, so resuming is a jump and nothing else
    # The coprocessor's response primitive decoder supplies the address -- UM
    # 7.4. A primitive read from the response CIR says what the processor does
    # next, and most of what it says steers the bus: which register it reads,
    # which way an operand goes, whether an effective address is evaluated.
    # Resolving it in hardware into a micro-address, as the extension-word
    # decoder does for an effective address, keeps all of that out of the
    # request fan-in.
    'CPDEC',
)

# Conditions the COND arm can test. M5 needs none of them yet; the field exists
# because the sequencer's shape depends on it and adding it later would change
# every microword.
# What seq = COND tests. It branches to `next` when the condition holds and
# falls through when it does not, so no microword needs its two successors to be
# adjacent and the assembler has no alignment rule to enforce.
COND = enc(
    'NEVER',
    'CC',        # the condition bits 11:8 of the opcode name -- PRM table 3-19
    'NCC',       # ... negated, for the instructions that branch the other way
    'RESM1',     # the ALU result is $FFFF at sixteen bits: DBcc's counter,
                 # which PRM 4 stops on when the decrement reaches -1
    # MOVEM's two, on what is left of its register list in T0 -- REGN and
    # REGNR are a priority encoder on the same bits, and cnt = CLRLOW takes the
    # lowest one away. Both polarities, because COND falls through when the
    # condition does not hold.
    'EMPTY',     # T0[15:0] is zero: no register left in the list
    'NOTEMPTY',  # ... and at least one is
    'MDOVF',     # the multiply or divide overflowed
    'XW10',      # bit 10 of the extension word: the long forms' 64-bit selector
    'XW11',      # bit 11 of it: CHK2 rather than CMP2 -- PRM 4
    'XW15',      # bit 15: the register it names is an address register
    # RTE reads a frame's format word into xw and branches on it. UM 6.1.12
    # names three it understands and says the rest are a format error.
    'FMT0',      # the format word in xw says a four-word frame
    'FMT1',      # ... a throwaway four-word frame
    'FMT2',      # ... a six-word frame
    'FMTA',      # ... a short bus fault frame
    'FMTB',      # ... and a long one
    'FMT9',      # ... a coprocessor midinstruction frame -- UM 7.4.19
    'VERBAD',    # xw holds a long frame's +$36 whose version is not this
                 # design's -- UM 6.1.8, a format error
    # UM 6.2.2: the three bits of the special status word a handler is allowed
    # to have changed, plus the two that say what the faulted access was, which
    # RTE needs to know which buffer to rerun it from.
    'SSW_DF', 'SSW_RB', 'SSW_RC', 'SSW_RW', 'SSW_RM',
    'MASTER',    # the M bit is set, so the active supervisor stack is the
                 # master one and an interrupt owes a throwaway frame -- UM 6.1.9
    'USER',      # the S bit is clear: a privileged instruction may not run
    'DIVZERO',   # the divisor was zero. PRM 4: "division by zero causes a
                 # trap", which is a different thing from an overflow -- the
                 # overflow arm returns and this one does not
    # UM 9.7: a module descriptor's first long word, or a module frame's first
    # word moved to the same place, held in T0 -- options in 31:29 and type in
    # 28:24. The processor "recognizes only the options of 000 and 100" and
    # "only descriptors of type $00 and $01; all others cause a format
    # exception".
    'MODBAD',    # anything else: a format error
    'MODTYPE1',  # type $01, which changes the access level
    'MODOPT4',   # option 100: the arguments are reached through a pointer
    # UM table 9-6, the access status register, read into T2. Zero is a refusal
    # and anything above seven is undefined; both are a format error. Four to
    # seven say the stack changes as well.
    'ASTAT_BAD',
    'ASTAT_STACK',
    'T3ZERO',    # T3 has counted down to nothing: the argument copy is done
    'ZSET',      # the zero flag, which is how CAS and CAS2 say the compare
                 # matched -- PRM 4, "if Z, update operand -> destination"
    'CSET',      # the carry flag, which is where CMP2 leaves its verdict
    'VSET',      # the overflow flag. TRAPV tests V and its own condition
                 # field reads as NE, so it cannot use the cc evaluation
    'AVEC',      # the last cycle ended with AVEC: use the autovector
    'BERR',      # ... or with a bus error. On an interrupt acknowledge that is
                 # a spurious interrupt, UM 6.1.9, and not a bus fault
    'RESNEG',    # the ALU result is negative at the effective size
    'GTZ',       # ... and the signed comparison just made came out greater
    # ---- The coprocessor interface, UM section 7 --------------------------
    # The response primitive held in cprim, UM figure 7-22: come again, pass
    # the program counter, direction, and the three bits individual primitives
    # give their own names to -- IA or SP in bit 8, PF in bit 1, TF in bit 0.
    'CPCA', 'CPPC', 'CPDR', 'CPB8', 'CPPF', 'CPTF',
    # Which coprocessor instruction stage D holds -- UM figures 7-6 to 7-13.
    # The category decides how a dialogue ends: a general instruction is over
    # when the coprocessor lets it go, a conditional one when it has a verdict.
    'CPGEN',     # bits 8:6 = 000, cpGEN
    'CPBCC',     # bit 7 set: cpBcc
    'CPDBCC',    # bits 5:3 = 001 in the 001 group: cpDBcc
    'CPTRAP',    # bits 5:3 = 111 in the 001 group: cpTRAPcc
    'IR0', 'IR1', 'IR6',   # single bits of stage D: cpTRAPcc's opmode, cpBcc.L
    # The byte counter an operand transfer runs down, in T1. The bus unit
    # moves one to four bytes per request and the count is fixed in the
    # microword, so the tail of an odd-length operand is a branch.
    'T1GE4', 'T1B1', 'T1B0', 'T1ZERO',
    # A trace will be taken when this instruction ends -- UM 7.5.2.5 keeps the
    # dialogue going until the coprocessor has finished, so that it is.
    'TRACEPEND',
    # Come again: CA set, or a trace pending (UM 7.5.2.5), which holds a
    # dialogue open until the coprocessor says it has finished. The one
    # question at the end of every primitive -- program.py, u().
    'CPAGAIN',
    # An interrupt the mask admits is waiting -- UM 7.5.2.6: a null primitive
    # with CA and IA set services it in the middle of the instruction.
    'IRQPEND',
    # The addressing mode in stage D's effective-address field, for the
    # primitives that evaluate it -- UM 7.4.9 and 7.4.16.
    'EADN', 'EAAN', 'EAPOST', 'EAPRE', 'EAIMM',
    'EAUNALT',   # program-counter relative or immediate: not alterable
    'CPEAOK',    # in the class the primitive's valid-EA field names, table 7-4
    'EACTLALT',  # control alterable, UM 7.4.8
    'CPMEAOK',   # what UM 7.4.16 allows for the primitive's direction
    'CPLEN124',  # the primitive's length is one, two or four bytes
    # A coprocessor format word, read into T0 -- UM table 7-2.
    'FWNOTRDY',  # $01, not ready, come again
    'FWEMPTY',   # $00, empty or reset
    'FWBAD',     # $02, invalid, or $03-$0F, which the processor takes as it
    'FWLEN',     # a valid format whose length is not a multiple of four
    # A control register select code the processor does not have -- UM table
    # 7-5 for the coprocessor, and UM 6.1.5 for MOVEC, where it is an illegal
    # instruction.
    'CREGBAD',
    'CREGBADC',  # ... the same code, read from stage C before it is latched
)

# --------------------------------------------------------------------------
# The bus request. One request per OPERAND, and the microword holding it stalls
# until the bus unit acknowledges -- see doc/bus-timing-compliance.md.
# --------------------------------------------------------------------------
BUS = enc(
    'NONE',
    'READ',
    'WRITE',
)

# Where the address of that operand comes from.
ASEL = enc(
    'ZERO',      # address 0: the reset vector
    'FOUR',      # address 4
    'T0',
    'T1',
    'T2',
    'T3',
    'SP',        # whichever of the three the S and M bits select. RTE reads the
                 # frame it was handed through this, which is what makes the
                 # frame base reachable again after the walk has moved on.
    'EA',        # the address output buffer
    'EA_SAVE',   # ... and the exception's own, which is a second one so that a
                 # fault frame can be built without disturbing the first: a bus
                 # fault is taken MID-INSTRUCTION, and the address buffer the
                 # instruction was using is frame field +$38.
    'PC_D',
    # The fast effective-address paths: the register the EA field names -- bits
    # 11:9 when the microword's own eadst bit is set -- and that register less
    # the operand size, for -(An). No EAMODE dispatch and no EA buffer.
    'AREG',
    'AREG_PRE',
)

# Which address space. UM Table 2-1.
FC = enc(
    'PROG',      # program space at the current privilege level
    'DATA',      # data space likewise
    'CPU',
    # PRM 6, MOVES: "the instruction uses the function code in SFC or DFC to
    # access the operand", which is the only way a program can name an address
    # space rather than have one chosen for it.
    'SFC',
    'DFC',
    # The space the effective address under way belongs to: program if its base
    # is the program counter, data otherwise. PRM 2: "Data items in the
    # instruction stream can be accessed with the program counter relative
    # addressing modes; these accesses classify as program references." The
    # twenty-one full-extension-word routines are shared between the two bases,
    # so the space cannot be written into the microword and has to follow the
    # same latched bit the base does.
    'EASP',
    # Supervisor data, whatever the S bit says. An exception frame is always on
    # the supervisor stack, and the bus-fault frames write the old status
    # register BEFORE S is set, so that the frame holds what it was: at that
    # moment DATA still means user data if the fault came from user code. On a
    # machine whose MMU keeps the two spaces apart -- a Sun-3 -- the frame then
    # went to the user's page, faulted, and halted the processor with a double
    # bus fault. Found by SunOS 4.1.1's first user process (doc/bugs-found.md).
    'SDATA',
    # Program space at the privilege level of the status register a short bus
    # fault frame carries, which RTE holds in xw -- UM 6.2.1.
    'FRAMEPROG',
)

# --------------------------------------------------------------------------
# The datapath.
# --------------------------------------------------------------------------
ASRC = enc(
    'ZERO',
    'STG_C_HI',  # the next word, shifted into bits 31:16: a long displacement
    'XW_HI',     # the extension-word latch, likewise
    'EA',        # the address output buffer
    'PC_C',      # the address of stage C -- "the value of the PC is the address
                 # of the extension word" (PRM 2.5)
    'EABASE',    # the base of an indexed effective address: the program counter
                 # or an address register, as the microword's `eapc` bit says,
                 # and zero when a full extension word suppresses it (BS)
    'T0', 'T1', 'T2', 'T3',
    'RDATA',     # what the last bus read returned
    'STG_D',     # the instruction word
    'STG_C',     # the next word: an extension word, before it is consumed
    'XW',        # the extension-word latch
    'PC_D',      # the address of the instruction being executed
    'SR',
    'DREG',      # the data register bits 2:0 of the opcode name
    'AREG',      # ... or the address register
    'DREGW',     # the data register bits 11:9 name -- the other operand of a
                 # two-register instruction, and the destination of <ea>,Dn
    'AREGW',     # ... or the address register
    'IMM8',      # bits 7:0 of the instruction word, sign extended: MOVEQ
    'DISP8',     # bits 7:0 sign extended, for a short branch
    'SP',        # whichever of USP, ISP and MSP the S and M bits select
    'USP',       # the user stack pointer by name -- MOVE USP again
    'CCRW',      # the condition codes alone, zero extended to a word: PRM 4
                 # leaves the upper byte of a MOVE from CCR reading as zero
    'VECOFF',    # the microword's vector number, times four
    'FMTVEC',
    # The same, but with the vector offset from the microword's own `vec` field
    # instead of from T0. A fault frame has to name its format and its vector
    # before it has written T0 out, and T0 is the instruction's.
    'FMTVECI',    # the format word of a stack frame: the microword's frame code
                 # in bits 15:12 and the vector offset from T0 in bits 11:0
    'VBR',       # the vector base register
    'TRAPVEC',   # TRAP #n: 32 + n, times four, from bits 3:0 of the opcode
    'IRQLEVEL',  # the level of the interrupt being taken, for the status
                 # register's mask and for the acknowledge cycle's address
    'AUTOVEC',   # 24 + that level, times four: the autovector offset
    'IRQVEC',    # the vector the acknowledging device returned, times four
    'PC_PREV',   # the address of the instruction that has just finished, which
                 # is what a trace frame carries at +$08
    # The register MOVEM's counter names: 0 to 7 are D0 to D7 and 8 to 15 are
    # A0 to A7. REGNR counts the other way, because the predecrement form's
    # mask is reversed -- PRM 4, "bit 0 selects A7".
    'REGN',
    'REGNR',
    'MULLO',     # the low thirty-two bits of the product
    'MULHI',     # ... and the high thirty-two
    'DIVQ',      # the quotient
    'DIVR',      # ... and the remainder
    'DREG_XQ',   # the data register the extension word's bits 14:12 name
    'DREG_XR',   # ... and its bits 2:0
    'DREG_XU',   # ... and its bits 8:6, which is where CAS and CAS2 put the
                 # update register -- PRM 4
    # The fault frame's own fields -- doc/ssw.md and doc/checkpoint.md. Each is
    # read exactly once, by the microword that writes it into the frame.
    # PRM 4, the bit field. Offset and width are wires off the extension word,
    # so these are the only things the microcode has to name.
    'BF_FIELD',    # the field, right justified and zero extended
    'BF_SXFIELD',  # ... and sign extended
    'BF_FFO',      # the instruction's offset plus the first one bit's
    'BF_MERGED',   # a data register with the field replaced
    'FLTVEC',    # the vector offset this bus fault takes: 8 or 12
    'FLTFMT',    # ... and the same, packed with the frame format code
    # RTM's register, from bits 3:0 of the opcode, put in the place the
    # extension-word register sources read it from -- D/A in bit 15 and the
    # number in 14:12, which is also where CALLM's module entry word has it.
    'RTM_XW',
    'SSW',       # assembled from the pipe's half and the bus unit's
    'DFA',       # the data fault address: frame +$10
    'DOB',       # the data output buffer: frame +$18
    'DIB',       # the data input buffer: long frame +$2C
    # Stage C as a frame FIELD and not as an extension word. The distinction is
    # load-bearing: reading stage C to use it is what takes a prefetch fault --
    # UM 6.2.1's "the processor attempted to use stage C" -- and reading it to
    # write it into a frame is the opposite of that. Sharing one encoding made
    # the frame builder fault on the very word it was saving, which is a double
    # bus fault and a halted processor.
    'STG_C_RAW',
    'STG_B',     # the pipe word at +$0E
    'STG_B_ADDR',# its address: long frame +$24
    'PC_FETCH',  # the next long word the pipe would have fetched
    'EA_SAVE',   # the exception's own frame pointer
    'LINK',      # the return address of the effective-address routine under way
    'UPC',       # the micro-address to resume at
    'INT08',     # the packed internal word at +$08
    'INT36',     # ... and the one at +$36, which carries the version nibble
    'CREG',      # the control register MOVEC's extension word names
    'XREG',      # the general register it names -- data or address per bit 15
    # ---- The coprocessor interface -----------------------------------------
    'CPLEN',     # the primitive's length field, bits 7:0
    'CPRIM',     # ... and the whole primitive, for the long fault frame's +$4A
    'CPVEC',     # ... read as a vector number, times four: the take-exception
                 # primitives -- UM 7.4.18 to 7.4.20
    'CPREG',     # the general register a transfer-single-register primitive
                 # names: D/A in bit 3 and the number in 2:0 -- UM figure 7-33
    'CPINT',     # the midinstruction frame's internal word at +$0C
    'FWLONG',    # a format word from T0 with its reserved word, as the long word
                 # stored at the head of a coprocessor state frame -- UM 7-14
    'FWLEN',     # ... and its length field alone
    'PC_C_RAW',  # the scanPC as a frame field: the address of stage C, read
                 # without using the word there -- UM 7.4.1
    'UBOUND',    # the micro-address of rte_boundary, an instruction boundary:
                 # where RTE out of a short frame resumes
    'RMWUPC',    # the micro-address a read-modify-write starts again at
)

# A convention, not a field: ASRC.DREG and ASRC.AREG read the register that bits
# 2:0 of the instruction word name, and DST.DREG and DST.AREG write the one bits
# 11:9 name. That is the direction MOVE and MOVEQ both go, and it keeps the
# register select out of the microword.

BSRC = enc(
    'ZERO',
    'STG_C_U',   # the next word, zero extended: the low half of a long word
    'STG_C_S',   # ... or sign extended: a word displacement
    'OPSIZE',    # the operand size in bytes, for (An)+ and -(An)
    'INDEX',     # the index register the extension word names, sized and scaled
    'XWDISP8',   # bits 7:0 of the extension-word latch, sign extended
    'EA',
    'BITMASK',   # one shifted left by the bit number the opcode names, modulo
                 # the operand size: 32 for a register, 8 for a byte in memory
    'TWO',       # the constant 2, for stepping the program counter
    'FOUR',      # ... and 4, for stepping the stack pointer
    'SIX',       # ... 6, the offset of a frame's format word
    'EIGHT',     # ... 8, the length of a four-word frame
    'TWELVE',
    # The two fault frames' sizes in bytes, so that the builder can step the
    # stack down to the frame base in one microword. They come from
    # rd68021_frame_pkg, which comes from frames.py, so they cannot drift from
    # the table the frame is laid out by.
    # How far the field's first byte is from the effective address -- PRM 4,
    # the offset divided by eight, rounding DOWN on both sides of zero.
    'BF_BYTEOFF',
    'FRAME_A_BYTES',
    'FRAME_B_BYTES',    # ... and 12, of a six-word one
    'VEROFF',    # $36, where the long frame's version word is -- UM 6.1.8
    'T0', 'T1', 'T2', 'T3',
    'XW',        # a fetched displacement, sign extended from 16 bits
    'DISP8',     # bits 7:0 of the instruction word, sign extended: a short branch
    'DREG',
    'AREG',
    'DREGW',
    'AREGW',
    'RDATA',
    # The registers CAS and CAS2's extension word names, as the B source: the
    # compare operand is subtracted from what memory held.
    'DREG_XR',
    'ONE',       # the constant 1, for the counted instructions
    'IMMQ',      # bits 11:9 of the opcode, with zero meaning eight: ADDQ, SUBQ
                 # and the immediate shift counts
    'DIVQ',      # the quotient, for assembling the word divide's result
    'IRQLEVEL',  # the level of the interrupt being taken, for the mask
    'THREE',     # the tail of an operand three bytes long
    'PCBIT',     # $4000: the PC bit of a coprocessor primitive -- UM figure 7-22
    'OPBYTES',   # the operand size in bytes with no A7 rule: CMP2's bounds
    # The A7 byte rule (UM 2.2) belongs to whichever register is A7. OPSIZE
    # applies it from the effective address's register (bits 2:0, Ay);
    # OPSIZEW from the one in bits 11:9 (Ax), for the two-register forms.
    'OPSIZEW',
    'BSTEP',     # a byte's step through Ay: 1, or 2 for A7 -- ABCD and SBCD
    'BSTEPW',    # ... and through Ax
    # UM 7.4.9: an (An)+ or -(An) operand steps the register by its length,
    # and by two for a single byte through A7, "to maintain a word-aligned
    # stack".
    'CPSTEP',
    'CPLEN',     # the length alone
    'TWENTY',    # the length of a midinstruction frame -- UM figure 7-43
)

ALU = enc(
    'A',         # pass the A source
    'B',         # pass the B source
    'ADD',
    'SUB',
    # The same adder with the extend bit as its carry in -- ADDX, SUBX, NEGX and
    # the BCD instructions all take it, and it is the only reason the adder has
    # a carry input at all.
    'ADDX',
    'SUBX',
    'AND',
    'OR',
    'EOR',
    'NOT',       # the ones complement of the A source
    'SWAP',      # the two halves of the A source exchanged
    'EXTW',      # bits 7:0 of A, sign extended to 16
    'EXTL',      # bits 15:0 of A, sign extended to 32
    'EXTB',      # bits 7:0 of A, sign extended to 32 -- EXTB.L, new on the 020
    # UM 6.1 step one: "the processor makes an internal copy of the SR, then
    # sets the S-bit ... next, the processor inhibits tracing of the exception
    # handler by clearing the T1 and T0 bits". One operation, because the two
    # halves must not be separable: between them the processor would be in
    # supervisor mode with tracing still on.
    'EXCSR',
    # UM 6.1: "for the reset and interrupt exceptions, the processor also
    # updates the interrupt priority mask". The level replaces I2-I0 and
    # nothing else in the status register moves.
    'SETMASK',
    # UM 6.1.9: "if the M-bit in the SR is set, the processor clears the M-bit
    # and creates a throwaway exception stack frame on top of the interrupt
    # stack". Clearing it is what moves the active stack from MSP to ISP.
    'CLRM',
    # ... and the copy of the status register on that throwaway frame "is
    # exactly the same as that placed on the master stack except that the S-bit
    # is set".
    'SETS',
    # Sign extend from the EFFECTIVE size to all thirty-two bits, and pass a
    # long word through untouched. Every instruction with an address register
    # destination needs it -- PRM 4, "the entire destination address register is
    # used regardless of the operation size" -- and a fixed EXTL would destroy
    # the long-word forms of the same instructions.
    'SX',
    # PRM 4, PACK: "bits 11-8 and 3-0 of the intermediate result are
    # concatenated and placed in bits 7-0 of the destination".
    'PACK',
    # ... and UNPK, the other way: the two nibbles of a byte into the low four
    # bits of two bytes, with zeros above each.
    'UNPK',
    # The two bytes PACK reads, made into the word the manual concatenates them
    # into. The shift that gets UNPK's second byte back out is SHR8, which MOVEP
    # already had.
    'BYTEPAIR',
    # B's low byte put in bits 23:16 of A: the caller's access level, read from
    # the access-control hardware, replacing the called module's in the word
    # that becomes the frame's first -- UM figure 9-12, "saved access level".
    'SETB2',
    'ZXB',       # A's low byte, zero extended: CALLM's argument count
    'SHIFT',     # whatever rd68021_shifter made of the A source
    'ANDNOT',    # A with the bits of B cleared, which is what BCLR does
    'LSR1',      # A shifted right one place, for walking MOVEM's mask
    'XSZ',       # A widened to 32 bits the way the multiply or divide under way
                 # says: sign extended when signed, zero extended when not
    'XSZHI',     # ... and the HIGH half of that widening, for a 64-bit dividend
                 # built from one register
    'SHL16',     # A shifted into the high word: the word divide's remainder
    'ORLOW16',   # the high word of A with the low word of B
    'ABCD',      # A plus B plus X, in binary-coded decimal
    'SBCD',      # A minus B minus X, likewise
    'SHR8',      # A shifted down a byte, for MOVEP
    'SHL8OR',    # A shifted up a byte with a new one at the bottom, likewise
    'ROL8',      # A rotated up a byte, which brings the top one to the bottom
    'SETB7',     # A with bit 7 set, which is all TAS does to its operand
)

DST = enc(
    'NONE',
    'T0', 'T1', 'T2', 'T3',
    'XW',
    'DREG',
    'AREG',
    'SP',
    'SR',
    'EA',
    'EA_SAVE',   # the exception's own frame pointer -- see ASEL
    # RTE putting a fault frame back, one field per microword. The six that name
    # a pipe field go out over the checkpoint port to rd68021_ifu; the two
    # packed words are unpacked here into the registers they came from.
    'STG_D', 'STG_C', 'STG_B', 'PC_D', 'FILL', 'PIPE_F',
    'INT08', 'INT36',
    'LINK', 'PC_PREV',
    'SSW', 'DFA', 'DOB', 'DIB',
    'SSWA',      # the special status word out of a SHORT frame, with what an
                 # instruction boundary implies for the rest -- rule 1
    'RUPC',      # the micro-address to resume at
    'RMWUPC',
    'AREG_EA',
    # The same two, for an ADDRESS rather than a data operand: written whole,
    # with no sign extension, whatever the operand size is. Stepping (An)+ and
    # -(An) is the only thing that needs them, and it needs them because the
    # step is the OPERAND size while the register is an address -- so the
    # microword cannot simply say long.
    'AREG_ADDR',
    'AREG_EA_ADDR',   # the address register the EA field names, for (An)+ and -(An)
    'DREG_R',    # the data register bits 2:0 name -- the destination when the
                 # effective address IS a register, which is every one-operand
                 # instruction in mode 000
    'CCR',       # the low five bits of the status register only
    'REGN',      # the register MOVEM's counter names
    'REGNR',     # ... counting the other way
    'DREG_XQ',   # the data register the extension word's bits 14:12 name
    'DREG_XR',   # ... and its bits 2:0
    'CREG',      # the control register MOVEC's extension word names
    'XREG',      # the general register it names -- data or address per bit 15
    'USP',       # the user stack pointer BY NAME, not whichever A7 means --
                 # which is the whole point of MOVE USP
    # The register the extension word names, written at the OPERAND size: PRM 6
    # puts a byte or word into the low part of a data register and sign-extends
    # it into the whole of an address register. MOVES needs both.
    'XREG_SZ',
    # ---- The coprocessor interface -----------------------------------------
    'CPRIM',     # the response primitive just read, held while it is served
    'CPREG',     # the general register a transfer-single-register primitive
                 # names, written whole
    # UM 7.4.17: the scanPC, written by the coprocessor. The pipe behind stage
    # D is emptied and refilled from here; stage D and the program counter --
    # the coprocessor instruction's own -- stay where they are.
    'SCANPC',
    'CPINT',     # the midinstruction frame's internal word, put back by RTE
    # The address register the effective-address field names, written as a
    # VALUE: sign extended from the operand size -- UM 7.4.9.
    'AREG_R',
)

# How wide the destination write is. A write to a data register of size byte or
# word leaves the rest of the register alone; a write to an address register is
# always the full 32 bits, sign extended if it was a word.
SIZE = enc('BYTE', 'WORD', 'LONG')

# Where the effective size comes from. The size field above is what FIXED means;
# the others read it out of stage D, which is a register, so this steers nothing
# that a bus request depends on discovering.
#
# It is what stops every effective-address routine existing three times.
SZSEL = enc(
    'FIXED',     # the microword's own size field
    'IR76',      # bits 7:6: 00 byte, 01 word, 10 long -- most instructions
    'IR86',      # bits 8:6 modulo 4, the opmode field of ADD, SUB, AND, OR, CMP
    'MOVE',      # bits 13:12: 01 byte, 11 word, 10 long -- MOVE alone
    'IR6',       # bit 6 alone: 0 word, 1 long -- MOVEM, EXT, the address forms
    'IR8',       # bit 8 alone: 0 word, 1 long -- ADDA, CMPA and their relatives
    # The size the dispatching microword resolved, kept in a register. The
    # effective-address routines are shared between instructions that encode
    # their size in different bits, so they cannot name a selector of their own;
    # what they can do is use the one the caller already worked out. (An)+ and
    # -(An) are why it matters -- they step the register by the operand size.
    'LATCHED',
    # A bit-field access is as many bytes as the field touches -- one to five --
    # so it has no size in the ordinary sense. The two say where the field is.
    'BFMEM',
    'BFREG',
    # PRM 8 gives CAS and CAS2 the same bits and a DIFFERENT encoding in them:
    # 01 byte, 10 word, 11 long, with 00 unused. CMP2 and CHK2 number from zero.
    'CAS',
    'IR109',     # bits 10:9: 00 byte, 01 word, 10 long -- CMP2 and CHK2
    'CHK',       # bit 7 alone: 1 word, 0 long. CHK is the only instruction that
                 # encodes its size that way -- PRM 8 gives it opmode 110 and
                 # 100, the second being the MC68020's addition.
    # The primitive's length field: one byte, two, or four -- the only lengths
    # UM 7.4.9 allows for a register operand.
    'CPLEN',
)

# Condition codes -- PRM 3.3 and table 3-18.
#
# Every instruction in the integer set sets the codes in one of a few ways, and
# the field names the WAY rather than the instruction. Two distinctions are
# worth spelling out because getting either wrong is a bug no register
# comparison catches until something branches on it:
#
#   * the X forms (ADDX, SUBX, NEGX and the two BCD adds) CLEAR Z only when the
#     result is non-zero and otherwise leave it alone, so that Z means "every
#     part of a multi-precision result was zero". PRM writes it as
#     "Z -- cleared if the result is non-zero; unchanged otherwise".
#   * CMP and TST set no X at all, where SUB and NEG do.
CCR = enc(
    'NONE',
    'LOGIC',     # N and Z from the result, V and C cleared, X untouched
    'ADD',       # N Z from the result, V overflow, C carry, X = C
    'ADDX',      # the same, but Z is only ever cleared
    'SUB',       # N Z from the result, V overflow, C borrow, X = C
    'SUBX',      # the same, but Z is only ever cleared
    'CMP',       # N Z V C from the subtraction, and X untouched
    'ZN',        # N and Z from the result, V C X all untouched
    'ZBIT',      # Z alone -- the bit instructions move nothing else
    'SHIFT',     # the shifter's own N Z V C X
    'MUL32',     # N and Z from the result, V if the product did not fit, C = 0
    'MUL64',     # N and Z from all sixty-four bits, V and C cleared
    'DIV',       # N and Z from the quotient, V and C cleared
    'DIVV',      # V alone, set: PRM 4 leaves the operands alone on overflow
    'BCD',       # the decimal carry into X and C, Z only ever cleared
    'ALL',       # the low five bits of the result are the codes: MOVE to CCR
    # N Z V C all cleared, X untouched. CHK is the only user: PRM 4 says N is
    # "cleared if the compared value is greater than the upper bound", which is
    # a rule about WHY the trap happened and not about the sign of anything the
    # comparison computed -- and the two differ when the bound is negative and
    # the subtraction overflows.
    'CLRNZVC',
    # PRM 4, CMP2 and CHK2: "Z -- set if Rn is equal to either bound; cleared
    # otherwise. C -- set if Rn is out of bounds". The two equalities are tested
    # by two microwords, so Z is only ever SET here and the microword before
    # cleared it. N and V are undefined and are left where they fell.
    'CMP2',
    'BF',        # the field's most significant bit and whether it is all zero
    'BFINS',     # ... taken from the value being inserted instead
)

# The instruction pipe.
PF = enc(
    'NONE',
    'CONSUME',   # an extension word has been read from stage C
    'ADV',       # the instruction is over: stage C becomes the next opcode
    'FLUSH',     # refill from the ALU result
)

# The multiplier and the divider. The multiply is combinational; the divide
# takes a clock per quotient bit and the microword stalls on it exactly as it
# stalls on a bus cycle.
MDOP = enc('NONE', 'MUL', 'DIV')

# The CPU address spaces of UM figure 5-31. The breakpoint and the module call
# arrive with M10, the coprocessor with M13.
CPUSPACE = enc('NONE', 'IACK', 'BKPT', 'COPROC',
               # UM 9.8: the access-level control hardware CALLM and RTM talk to
               # for a type $01 module. The register offset comes out of the
               # microword's `vec` field, which is otherwise the exception
               # vector and is free on every microword that makes one of these.
               'ACCESS',
               # UM 7.5.2.8: the CIR access that STARTS a coprocessor
               # instruction. A bus error on it means there is no coprocessor,
               # and the microcode takes an F-line exception off the end code;
               # on every other CIR access -- COPROC -- it is a bus error. The
               # CIR offset is in `vec` too, and the CpID comes from stage D.
               'CPINIT')

# Which exception stack frame a microword is building. UM table 6-5 names the
# exceptions that take each; the code below is the value that goes in bits 15:12
# of the format word at +$06.
FRAME = enc('F0', 'F1', 'F2', 'F9', 'FA', 'FB')

# The microword a read-modify-write starts again at when RTE reruns it -- UM
# 6.2.3, "the rerun operation, executed by the RTE instruction with the DF bit
# of the SSW set, reruns the entire instruction". The sequencer latches its
# micro-address whenever it is presented, and the long frame carries it.
MARK = enc('NONE', 'RMW')

# MOVEM's register list: CLRLOW clears the lowest set bit of T0, which is the
# register REGN and REGNR have just named -- a side effect of the microword, so
# that the transfer and the step to the next register are one microword.
CNT = enc('NONE', 'CLRLOW')

# How the shifter is driven.
SHOP = enc(
    'NONE',
    'REG',       # 1110 ccc d ss i tt rrr -- a count of 1..8 in the opcode, or
                 # one modulo 64 in a data register
    'MEM',       # 1110 0tt d 11 eeeeee   -- one bit of a word in memory
)

# --------------------------------------------------------------------------
# The microword, in order. A flat vector with named field selects, not a packed
# struct: yosys and Quartus are happier, and the generated package gives every
# field a position so the RTL cannot disagree about one.
# --------------------------------------------------------------------------
# The micro-address. 4096 words: 1529 are used after M11, and the coprocessor
# interface (M13) is the last large block of microcode still to come. The width
# is the depth of the microcode store, and the store is built at its full depth
# -- 8192 words cost 24.5 block RAMs on the Artix where 4096 cost half that --
# so it is sized to the program, not to the plan's first estimate. The frame
# carries a micro-address in a sixteen-bit word, so it can grow to 16 without
# touching the checkpoint layout.
UADDR_BITS = 12

FIELDS = OrderedDict([
    ('seq',   (3,  SEQ,   'NEXT')),
    ('cond',  (7,  COND,  'NEVER')),
    ('next',  (UADDR_BITS, None, 0)),
    ('bus',   (2,  BUS,   'NONE')),
    ('asel',  (4,  ASEL,  'ZERO')),
    ('fc',    (3,  FC,    'DATA')),
    ('bytes', (3,  None,  0)),      # operand size in bytes, 0 when bus is NONE
    ('asrc',  (7,  ASRC,  'ZERO')),
    ('bsrc',  (6,  BSRC,  'ZERO')),
    ('alu',   (6,  ALU,   'A')),
    ('dst',   (6,  DST,   'NONE')),
    ('size',  (2,  SIZE,  'LONG')),
    ('ccr',   (5,  CCR,   'NONE')),
    ('szsel', (4,  SZSEL, 'FIXED')),
    ('pf',    (2,  PF,    'NONE')),
    # Latch the return address. One level is enough: an effective-address
    # routine is called from an instruction and calls nothing itself.
    ('call',  (1,  None,  0)),
    # Which field of the instruction word the addressing-mode decoder reads.
    # MOVE is the reason: its destination's mode and register sit in bits 8:6
    # and 11:9, in the opposite order from every other effective address, and a
    # second decoder for one instruction would be worse than a mux.
    # Where the shifter takes its count, direction and kind from. PRM 8 gives
    # the register forms and the one-bit memory forms different layouts of the
    # same instruction word, and both are in stage D, so this picks a layout
    # rather than carrying the values.
    ('shop',  (2,  SHOP,  'NONE')),
    # Where a bit instruction's bit number comes from: the word after the
    # opcode when it is static, a data register when it is dynamic.
    ('bitimm', (1, None,  0)),
    # MOVEM's register list.
    ('cnt',   (2,  CNT,   'NONE')),
    ('mdop',  (2,  MDOP,  'NONE')),
    # Where the signedness and the register numbers come from. The word forms
    # of MULU, MULS, DIVU and DIVS carry both in the opcode; the long forms
    # carry them in the extension word -- PRM 8.
    ('mdext', (1,  None,  0)),
    # The vector NUMBER an internally generated exception uses. UM 6.1: "for
    # all other exceptions, internal logic provides the vector number". The
    # ASRC that reads it gives the OFFSET -- the number times four -- because
    # that is what both the format word and the vector address want.
    ('vec',   (8,  None,  0)),
    ('frame', (3,  FRAME, 'F0')),
    # UM 6.1.7: "when tracing is enabled and the processor attempts to execute
    # an illegal or unimplemented instruction, that instruction does not cause
    # a trace exception since it is not executed". The four entry points for
    # instructions that were never executed set this, and nothing else does.
    ('notrace', (1, None,  0)),
    # Which CPU address space a request goes to -- UM figure 5-31. Only the
    # interrupt acknowledge is used before M10.
    ('cpuspace', (3, CPUSPACE, 'NONE')),
    # Hold RMC across the accesses of an indivisible read-modify-write. UM 5.5.2:
    # on this part RMC is a qualifier across a run of ordinary bus cycles, each
    # retried separately, and not one long cycle.
    ('rmc',   (1,  None,  0)),
    # PRM 6 STOP: "stops the fetching and executing of instructions. A trace,
    # interrupt, or reset exception causes the processor to resume". The bit
    # sits on a microword that also decodes, so the trace and interrupt arms
    # are judged first and against the status register STOP has just written.
    ('stop',  (1,  None,  0)),
    # PRM 6 RESET: "asserts the RSTO signal for 512 clock periods". The bus unit
    # owns the pin and the counter; this bit asks for it and stalls until done.
    ('rsto',  (1,  None,  0)),
    # UM 6.2.3: "the faulted data cycle is rerun by the RTE instruction". The
    # bus unit is handed the residual out of the frame and finishes the operand;
    # this bit is what hands it over, and the microword stalls on the
    # acknowledge like any other.
    ('rstop', (1,  None,  0)),
    ('eadst', (1,  None,  0)),
    # Whether the base of an indexed effective address is the program counter or
    # an address register. It is in the OPCODE, not the extension word, so the
    # extension-word decoder cannot see it: this bit is prepended to the word it
    # decodes, which is why its patterns are seventeen characters and not sixteen.
    ('eapc',  (1,  None,  0)),
    # Retire the bus microword on the rising edge that ends S5, when the bus
    # unit has seen the operand finish cleanly, rather than a clock later on the
    # registered acknowledge. Only for a microword that does not take the read
    # data itself: that is latched on the same edge. Set by assemble.py, never
    # by hand -- mark_early.
    ('early', (1,  None,  0)),
    # A posted write -- UM 8.1.3, "the bus cycle is queued and the bus
    # controller runs the cycle when the current cycle is complete". The
    # microword retires when the bus unit takes the operand, and the sequencer
    # goes on while the cycle runs. A fault on it is taken at whatever
    # microword is running then -- doc/checkpoint.md rule 9. Set by assemble.py,
    # never by hand -- mark_posted.
    ('post',  (1,  None,  0)),
    # Wait for a posted write to finish before starting. For a microword that
    # reads state a fault frame does not carry, which a fault landing on it
    # would lose -- mark_sync -- and for NOP, which PRM 4 makes wait for the
    # bus.
    ('sync',  (1,  None,  0)),
    ('mark',  (1,  MARK,  'NONE')),
])


def layout():
    """(lsb, width) for every field, and the total width."""
    out = OrderedDict()
    pos = 0
    for name, (width, _e, _d) in FIELDS.items():
        out[name] = (pos, width)
        pos += width
    return out, pos


UW_LSB, UW_BITS = layout()


def check():
    bad = []
    for name, (width, e, default) in FIELDS.items():
        if e is None:
            continue
        if default not in e:
            bad.append('field %r: default %r is not one of its encodings'
                       % (name, default))
        need = max(e.values()).bit_length()
        if need > width:
            bad.append('field %r: %d encodings need %d bits, %d declared'
                       % (name, len(e), need, width))
    return bad


def main():
    lay, total = layout()
    print('microword: %d bits, %d fields, %d-bit micro-address'
          % (total, len(FIELDS), UADDR_BITS))
    for name, (lsb, width) in lay.items():
        e = FIELDS[name][1]
        vals = ' '.join(e.keys()) if e else '(a number)'
        print('  %-7s %2d:%-3d %s' % (name, lsb + width - 1, lsb, vals[:80]))
    bad = check()
    for b in bad:
        print('FAIL: %s' % b)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
