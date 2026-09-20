#!/usr/bin/env python3
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
    """An encoding: name -> value, in the order written."""
    return OrderedDict((n, i) for i, n in enumerate(names))


# --------------------------------------------------------------------------
# How the next micro-address is chosen.
# --------------------------------------------------------------------------
SEQ = enc(
    'NEXT',      # go to the address in the `next` field
    'DECODE',    # end of instruction: the opcode decoder supplies the address
    'COND',      # `next`, with bit 0 set if the selected condition holds
)

# Conditions the COND arm can test. M5 needs none of them yet; the field exists
# because the sequencer's shape depends on it and adding it later would change
# every microword.
COND = enc(
    'NEVER',
    'CC',        # the condition the opcode's cc field names
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
    'EA',        # the address output buffer
    'PC_D',
)

# Which address space. UM Table 2-1.
FC = enc(
    'PROG',      # program space at the current privilege level
    'DATA',      # data space likewise
    'CPU',
)

# --------------------------------------------------------------------------
# The datapath.
# --------------------------------------------------------------------------
ASRC = enc(
    'ZERO',
    'T0', 'T1', 'T2', 'T3',
    'RDATA',     # what the last bus read returned
    'STG_D',     # the instruction word
    'STG_C',     # the next word: an extension word, before it is consumed
    'XW',        # the extension-word latch
    'PC_D',      # the address of the instruction being executed
    'SR',
    'DREG',      # the data register the opcode's register field names
    'AREG',      # ... or the address register
    'IMM8',      # bits 7:0 of the instruction word, sign extended: MOVEQ
    'DISP8',     # bits 7:0 sign extended, for a short branch
    'SP',        # whichever of USP, ISP and MSP the S and M bits select
)

# A convention, not a field: ASRC.DREG and ASRC.AREG read the register that bits
# 2:0 of the instruction word name, and DST.DREG and DST.AREG write the one bits
# 11:9 name. That is the direction MOVE and MOVEQ both go, and it keeps the
# register select out of the microword.

BSRC = enc(
    'ZERO',
    'TWO',       # the constant 2, for stepping the program counter
    'T0', 'T1',
    'XW',        # a fetched displacement, sign extended from 16 bits
    'DISP8',     # bits 7:0 of the instruction word, sign extended: a short branch
    'DREG',
    'AREG',
    'RDATA',
)

ALU = enc(
    'A',         # pass the A source
    'B',         # pass the B source
    'ADD',
    'SUB',
    'AND',
    'OR',
    'EOR',
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
)

# How wide the destination write is. A write to a data register of size byte or
# word leaves the rest of the register alone; a write to an address register is
# always the full 32 bits, sign extended if it was a word.
SIZE = enc('BYTE', 'WORD', 'LONG')

# Condition codes. UM 3.3 and PRM table 3-18; only what M5 needs.
CCR = enc(
    'NONE',
    'LOGIC',     # N and Z from the result, V and C cleared, X untouched
)

# The instruction pipe.
PF = enc(
    'NONE',
    'CONSUME',   # an extension word has been read from stage C
    'ADV',       # the instruction is over: stage C becomes the next opcode
    'FLUSH',     # refill from the ALU result
)

# --------------------------------------------------------------------------
# The microword, in order. A flat vector with named field selects, not a packed
# struct: yosys and Quartus are happier, and the generated package gives every
# field a position so the RTL cannot disagree about one.
# --------------------------------------------------------------------------
UADDR_BITS = 13

FIELDS = OrderedDict([
    ('seq',   (2,  SEQ,   'NEXT')),
    ('cond',  (2,  COND,  'NEVER')),
    ('next',  (UADDR_BITS, None, 0)),
    ('bus',   (2,  BUS,   'NONE')),
    ('asel',  (3,  ASEL,  'ZERO')),
    ('fc',    (2,  FC,    'DATA')),
    ('bytes', (3,  None,  0)),      # operand size in bytes, 0 when bus is NONE
    ('asrc',  (4,  ASRC,  'ZERO')),
    ('bsrc',  (4,  BSRC,  'ZERO')),
    ('alu',   (3,  ALU,   'A')),
    ('dst',   (4,  DST,   'NONE')),
    ('size',  (2,  SIZE,  'LONG')),
    ('ccr',   (1,  CCR,   'NONE')),
    ('pf',    (2,  PF,    'NONE')),
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
