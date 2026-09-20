#!/usr/bin/env python3
"""The microcode program, and the opcode patterns that reach it.

A microword may not both FLUSH and DECODE. The pipe operation is gated on the
microword retiring, and a DECODE stalls it until stage D is valid -- which is
what the flush has just made false. Written as one microword it deadlocks; the
flush and the decode are always two.

    python3 tools/ucode/program.py      # the listing

Fall-through is the default: a microword with no `next` runs the one after it, so
an unset field cannot silently mean micro-address zero. `seq` is what breaks the
fall-through, and `u()` refuses a field name it does not know.

As of M5 this is the walking skeleton -- reset, NOP, MOVEQ, MOVE.L Dn,Dn and both
shapes of BRA. It exists to prove the engine, the pipe and the bus contract fit
together; the instruction set arrives in M6 and M7.
"""

import sys
from collections import OrderedDict

import isa

WORDS = []          # [(fields, comment)]
LABELS = OrderedDict()
PATTERNS = []       # [(pattern, target, mnemonic)]


def label(name):
    if name in LABELS:
        raise SystemExit('program: duplicate label %r' % name)
    LABELS[name] = len(WORDS)


def u(comment='', **fields):
    for k in fields:
        if k not in isa.FIELDS:
            raise SystemExit('program: microword %d has no field %r -- the field '
                             'list is in isa.py' % (len(WORDS), k))
    WORDS.append((dict(fields), comment))


def goto(name):
    """The last microword continues at `name` instead of falling through."""
    WORDS[-1][0]['next'] = name


def opcode(pattern, target, mnemonic):
    if len(pattern) != 16 or any(c not in '01-' for c in pattern):
        raise SystemExit('program: %r is not sixteen of 0, 1 and -' % pattern)
    PATTERNS.append((pattern, target, mnemonic))


# ==========================================================================
# Reset -- UM 6.1.1
#
# "The reset exception ... fetches the initial interrupt stack pointer from the
# first long word of the vector table and the initial program counter from the
# second." The vector base register is zero at reset, so both come from absolute
# addresses, and the supervisor bit is already set: rd68021_seq resets SR to
# $2700, which UM 2.1.1 calls the interrupt mode of the supervisor level.
# ==========================================================================
label('reset')
u('the initial interrupt stack pointer, from $0',
  bus='READ', fc='DATA', asel='ZERO', bytes=4)
u('... into the active stack pointer',
  asrc='RDATA', alu='A', dst='SP')
u('the initial program counter, from $4',
  bus='READ', fc='DATA', asel='FOUR', bytes=4)
u('... and start fetching there',
  asrc='RDATA', alu='A', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')

# ==========================================================================
# An opcode with no pattern. Exception processing is M8; until then it stops,
# which a testbench can see and no test relies on.
# ==========================================================================
label('illegal')
u('no pattern for this opcode; exception processing is M8')
goto('illegal')

# ==========================================================================
# NOP -- PRM 4, "no operation"
# ==========================================================================
label('nop')
opcode('0100111001110001', 'nop', 'NOP')
u('nothing but the pipe', pf='ADV', seq='DECODE')

# ==========================================================================
# MOVEQ -- PRM 4. The byte in the instruction word, sign extended to a long word.
# ==========================================================================
label('moveq')
opcode('0111---0--------', 'moveq', 'MOVEQ')
u('sign extend the immediate into the data register',
  asrc='IMM8', alu='A', dst='DREG', size='LONG', ccr='LOGIC',
  pf='ADV', seq='DECODE')

# ==========================================================================
# MOVE.L Dn,Dn -- the register-to-register case only, which is all the walking
# skeleton needs; the addressing modes are M6.
# ==========================================================================
label('move_l_dd')
opcode('0010---000000---', 'move_l_dd', 'MOVE.L Dn,Dn')
u('one register to another',
  asrc='DREG', alu='A', dst='DREG', size='LONG', ccr='LOGIC',
  pf='ADV', seq='DECODE')

# ==========================================================================
# BRA -- PRM 4. The displacement is relative to the address of the instruction
# word plus two, which is `pc_d + 2` whatever the pipe has done since.
# ==========================================================================
# The word form comes FIRST, because first match wins and the byte form's
# pattern covers every displacement including the zero that selects this one.
# Writing them the other way round completely shadows this pattern, which
# assemble.py refuses to build. (The $FF displacement that selects BRA.L is
# M7, with the rest of the 32-bit branches.)
label('bra_w')
opcode('0110000000000000', 'bra_w', 'BRA.W')
u('take the displacement from the word after the instruction',
  asrc='STG_C', alu='A', dst='XW', size='WORD', pf='CONSUME')
u('the branch base',
  asrc='PC_D', bsrc='TWO', alu='ADD', dst='T0')
u('... plus the displacement',
  asrc='T0', bsrc='XW', alu='ADD', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')

label('bra_b')
opcode('01100000--------', 'bra_b', 'BRA.B')
u('the branch base: the instruction address plus two',
  asrc='PC_D', bsrc='TWO', alu='ADD', dst='T0')
u('... plus the displacement in the instruction word',
  asrc='T0', bsrc='DISP8', alu='ADD', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')


# ==========================================================================
def entry(name):
    if name not in LABELS:
        raise SystemExit('program: no label %r' % name)
    return LABELS[name]


def main():
    print('%d microwords, %d labels, %d opcode patterns'
          % (len(WORDS), len(LABELS), len(PATTERNS)))
    rev = {}
    for n, a in LABELS.items():
        rev.setdefault(a, []).append(n)
    for i, (f, c) in enumerate(WORDS):
        for n in rev.get(i, []):
            print('%s:' % n)
        bits = ' '.join('%s=%s' % (k, v) for k, v in sorted(f.items()))
        print('  %4d  %-62s %s' % (i, bits, ('# ' + c) if c else ''))
    print()
    for p, t, m in PATTERNS:
        print('  %s -> %-12s %s' % (p, t, m))
    return 0


if __name__ == '__main__':
    sys.exit(main())
