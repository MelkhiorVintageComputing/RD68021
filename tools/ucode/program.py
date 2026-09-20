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
EAPATTERNS = []     # [(pattern, target, what)] -- extension words


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


def extword(pattern, target, what):
    """An extension-word pattern, for the seq = EADEC arm.

    The shape of a full extension word decides how many words of base and outer
    displacement follow and whether a memory indirection happens -- five
    bus-steering decisions taken from a word that has only just been read.
    Branching on them microword by microword would put all five into the request
    fan-in; resolving them once, in hardware, into a micro-address puts none of
    them there. It is the same trick as the opcode decoder, on a different word.
    """
    if len(pattern) != 17 or any(c not in '01-' for c in pattern):
        raise SystemExit('program: %r is not seventeen of 0, 1 and - (the first '
                         'is the program-counter base bit)' % pattern)
    EAPATTERNS.append((pattern, target, what))


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
# UM 2.1.2: "All exception vectors are located in supervisor data space, except
# the reset vector, which is located in supervisor program space."
u('the initial interrupt stack pointer, from $0',
  bus='READ', fc='PROG', asel='ZERO', bytes=4)
u('... into the active stack pointer',
  asrc='RDATA', alu='A', dst='SP')
u('the initial program counter, from $4',
  bus='READ', fc='PROG', asel='FOUR', bytes=4)
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
# LEA -- PRM 4. "The effective address is loaded into the specified address
# register." It computes an address and does nothing else with it, which makes
# it the instrument the effective-address engine is measured with.
#
# LEA takes the control addressing modes: (An), (d16,An), (An,Xn), (xxx).W,
# (xxx).L, (d16,PC) and (PC,Xn). Not (An)+, not -(An), not Dn, not An, not
# immediate.
# ==========================================================================
LEA_MODES = [
    ('010---', 'ea_an_ind', '(An)'),
    ('101---', 'ea_d16_an', '(d16,An)'),
    ('110---', 'ea_idx_an', '(An,Xn)'),
    ('111000', 'ea_abs_w',  '(xxx).W'),
    ('111001', 'ea_abs_l',  '(xxx).L'),
    ('111010', 'ea_d16_pc', '(d16,PC)'),
    ('111011', 'ea_idx_pc', '(PC,Xn)'),
]

for _ea, _routine, _syntax in LEA_MODES:
    label('lea_' + _ea.replace('-', 'r'))
    opcode('0100---111' + _ea, 'lea_' + _ea.replace('-', 'r'), 'LEA ' + _syntax)
    u('compute the effective address', call=1, next=_routine)
    u('... and put it in the address register',
      asrc='EA', alu='A', dst='AREG', size='LONG', pf='ADV', seq='DECODE')

# ==========================================================================
# MOVE.L <ea>,Dn -- the same modes plus the ones LEA does not take, so that an
# effective address is also used to fetch something.
# ==========================================================================
MOVE_MODES = [
    ('010---', 'ea_an_ind',  '(An)'),
    ('011---', 'ea_an_post', '(An)+'),
    ('100---', 'ea_an_pre',  '-(An)'),
    ('101---', 'ea_d16_an',  '(d16,An)'),
    ('110---', 'ea_idx_an',  '(An,Xn)'),
    ('111000', 'ea_abs_w',   '(xxx).W'),
    ('111001', 'ea_abs_l',   '(xxx).L'),
    ('111010', 'ea_d16_pc',  '(d16,PC)'),
    ('111011', 'ea_idx_pc',  '(PC,Xn)'),
]

for _ea, _routine, _syntax in MOVE_MODES:
    # PRM 2: a program-counter-relative operand access "classifies as a program
    # reference", so the operand fetch of the two PC modes is in program space
    # and every other mode's is in data space. It is a property of the mode, not
    # of whether the base was actually added -- PRM's ZPC notation suppresses
    # the PC and the reference stays a program reference.
    _space = 'PROG' if _ea in ('111010', '111011') else 'DATA'
    label('movl_' + _ea.replace('-', 'r'))
    opcode('0010---000' + _ea, 'movl_' + _ea.replace('-', 'r'),
           'MOVE.L ' + _syntax + ',Dn')
    u('compute the effective address', call=1, next=_routine, size='LONG')
    u('read the long word it names',
      bus='READ', fc=_space, asel='EA', bytes=4)
    u('... into the data register',
      asrc='RDATA', alu='A', dst='DREG', size='LONG', ccr='LOGIC',
      pf='ADV', seq='DECODE')


# ==========================================================================
# EFFECTIVE ADDRESSES -- PRM section 2
#
# Each routine leaves the address in EA and returns. `call` latches the address
# of the microword after the caller, and seq = RET goes back to it; one level is
# enough, because an effective-address routine is called from an instruction and
# calls nothing itself.
#
# The opcode carries the mode and register, so the opcode decoder dispatches
# straight to the right routine. What the opcode does NOT carry is the shape of
# an extension word, and that is what seq = EADEC is for.
# ==========================================================================

label('ea_an_ind')                       # (An)
u('the address register itself',
  asrc='AREG', alu='A', dst='EA', seq='RET')

# The step for (An)+ and -(An) is this microword's own `size` field, which is
# the operand size only because every instruction that uses these routines today
# is a long-word one. When MOVE.B and MOVE.W arrive the size has to come from the
# caller instead -- either a field of its own or a routine per size.
label('ea_an_post')                      # (An)+
u('the address register, then stepped on by the operand size',
  asrc='AREG', alu='A', dst='EA')
u('... which for A7 and a byte is two, so the stack stays even',
  asrc='AREG', bsrc='OPSIZE', alu='ADD', dst='AREG_EA', seq='RET')

label('ea_an_pre')                       # -(An)
u('the address register stepped back first',
  asrc='AREG', bsrc='OPSIZE', alu='SUB', dst='AREG_EA')
u('... and that is the address',
  asrc='AREG', alu='A', dst='EA', seq='RET')

label('ea_d16_an')                       # (d16,An)
u('the address register plus the word that follows',
  asrc='AREG', bsrc='STG_C_S', alu='ADD', dst='EA', pf='CONSUME', seq='RET')

label('ea_abs_w')                        # (xxx).W
u('one word, sign extended',
  bsrc='STG_C_S', alu='B', dst='EA', pf='CONSUME', seq='RET')

label('ea_abs_l')                        # (xxx).L
u('the high half of a long word',
  asrc='STG_C_HI', alu='A', dst='T0', pf='CONSUME')
u('... and the low half',
  asrc='T0', bsrc='STG_C_U', alu='OR', dst='EA', pf='CONSUME', seq='RET')

label('ea_d16_pc')                       # (d16,PC)
# PRM 2.5: "the value of the PC is the address of the extension word".
u('the address of the extension word, plus the word itself',
  asrc='PC_C', bsrc='STG_C_S', alu='ADD', dst='EA', pf='CONSUME', seq='RET')

# --------------------------------------------------------------------------
# The indexed modes. The extension word is latched but NOT consumed, so that
# PC_C still names it while the routine runs; each routine consumes it itself.
# --------------------------------------------------------------------------
label('ea_idx_an')                       # (An,Xn,...) -- mode 110
u('latch the extension word and dispatch on its shape',
  asrc='STG_C', alu='A', dst='XW', size='WORD', seq='EADEC')

label('ea_idx_pc')                       # (PC,Xn,...) -- mode 111/011
u('the same, with the program counter as the base',
  asrc='STG_C', alu='A', dst='XW', size='WORD', seq='EADEC', eapc=1)

# The brief extension word -- PRM figure 2-3(b). Base plus the scaled index plus
# a sign-extended byte.
label('eab_an')
u('base plus the scaled index',
  asrc='AREG', bsrc='INDEX', alu='ADD', dst='T0', pf='CONSUME')
u('... plus the displacement byte',
  asrc='T0', bsrc='XWDISP8', alu='ADD', dst='EA', seq='RET')

label('eab_pc')
u('the extension word address plus the scaled index',
  asrc='PC_C', bsrc='INDEX', alu='ADD', dst='T0', pf='CONSUME')
u('... plus the displacement byte',
  asrc='T0', bsrc='XWDISP8', alu='ADD', dst='EA', seq='RET')

# --------------------------------------------------------------------------
# The full extension word -- PRM 2.5 and tables 2-1 and 2-2.
#
#     base = An or PC, or zero if BS
#     bd   = nothing, a word or a long word, per BD SIZE
#     Xn   = the index, scaled, or zero if IS
#     od   = nothing, a word or a long word, per the low two bits of I/IS
#
#   no memory indirect   EA = base + bd + Xn
#   preindexed           EA = M(base + bd + Xn) + od
#   postindexed          EA = M(base + bd) + Xn + od
#
# BS and IS are handled by the EABASE and INDEX sources rather than by separate
# routines, and an index-suppressed memory indirection is the postindexed path
# with an index of zero -- so what is left to dispatch on is the size of the two
# displacements and whether the indirection is before or after the index. That
# is 3 x 7 routines, written by a loop rather than by hand.
# --------------------------------------------------------------------------
BD_SIZES = [('n', 'null'), ('w', 'word'), ('l', 'long')]
OD_SIZES = [('n', 'null'), ('w', 'word'), ('l', 'long')]


def _disp_into_t1(kind):
    """Leave a base or outer displacement of the given size in T1."""
    if kind == 'null':
        u('no displacement', asrc='ZERO', alu='A', dst='T1')
    elif kind == 'word':
        u('a word displacement, sign extended',
          bsrc='STG_C_S', alu='B', dst='T1', pf='CONSUME')
    else:
        u('the high half of a long displacement',
          asrc='STG_C_HI', alu='A', dst='T1', pf='CONSUME')
        u('... and the low half',
          asrc='T1', bsrc='STG_C_U', alu='OR', dst='T1', pf='CONSUME')


def _ea_full(bd, action, od):
    """One full-extension-word routine."""
    name = 'eaf_%s_%s_%s' % (bd[0], action, od[0] if od else 'x')
    label(name)
    # The base, and the index if it goes on before the indirection. The
    # extension word is consumed here, after EABASE has been read from it --
    # PC_C names the extension word only until it is gone.
    if action == 'post':
        u('the base register, or the extension word address',
          asrc='EABASE', alu='A', dst='T0', pf='CONSUME')
    else:
        u('the base plus the scaled index',
          asrc='EABASE', bsrc='INDEX', alu='ADD', dst='T0', pf='CONSUME')
    _disp_into_t1(bd[1])
    u('... plus the base displacement', asrc='T0', bsrc='T1', alu='ADD', dst='T0')
    if action != 'none':
        u('the long word that address names',
          bus='READ', fc='EASP', asel='T0', bytes=4)
        u('... is the address to go on with',
          asrc='RDATA', alu='A', dst='T0')
        if action == 'post':
            u('... plus the scaled index', asrc='T0', bsrc='INDEX', alu='ADD',
              dst='T0')
        _disp_into_t1(od[1])
        u('... plus the outer displacement',
          asrc='T0', bsrc='T1', alu='ADD', dst='T0')
    u('and that is the effective address',
      asrc='T0', alu='A', dst='EA', seq='RET')
    return name


_full = {}
for _bd in BD_SIZES:
    _full[(_bd[0], 'none', 'x')] = _ea_full(_bd, 'none', None)
    for _od in OD_SIZES:
        _full[(_bd[0], 'pre', _od[0])]  = _ea_full(_bd, 'pre', _od)
        _full[(_bd[0], 'post', _od[0])] = _ea_full(_bd, 'post', _od)

# Reserved encodings -- PRM table 2-2 leaves IS=0/I-IS=100 and IS=1/I-IS=100..111
# undefined, and says nothing about what the part does. They land somewhere
# defined rather than falling into whatever follows; doc/divergences.md records
# the choice.
label('ea_reserved')
u('a reserved index/indirect encoding -- PRM table 2-2 does not say')
goto('ea_reserved')

# Extension-word patterns.
#
# The pattern is seventeen characters: the program-counter base bit the microword
# supplies, then bits 15 down to 0 of the extension word. So bit N is at index
# 16 - N, which is easy to get one out by hand -- these are built by a helper.
#
#   bit 8    the format: 0 brief, 1 full
#   bit 7    BS, base suppress
#   bit 6    IS, index suppress
#   bits 5:4 BD SIZE
#   bits 2:0 I/IS


def _brief(pc):
    return pc + '-' * 7 + '0' + '-' * 8


def _fullpat(is_bit, bd, iis):
    return ('-'          # the base bit: the full format works the same either way
            + '-' * 7    # bits 15..9: D/A, the register, W/L and SCALE
            + '1'        # bit 8: full format
            + '-'        # bit 7: BS, handled by the EABASE source
            + is_bit     # bit 6: IS
            + bd         # bits 5:4: BD SIZE
            + '-'        # bit 3
            + iis)       # bits 2:0: I/IS


# The brief format first: its pattern is the more specific of the two in bit 8.
extword(_brief('0'), 'eab_an', 'brief, An base')
extword(_brief('1'), 'eab_pc', 'brief, PC base')

_BD_BITS = [('n', '01'), ('w', '10'), ('l', '11')]
_OD_BITS = [('n', '01'), ('w', '10'), ('l', '11')]

for _bdk, _bdbits in _BD_BITS:
    # No memory indirect action -- PRM table 2-2, I/IS = 000 whatever IS says.
    extword(_fullpat('-', _bdbits, '000'), _full[(_bdk, 'none', 'x')],
            'full, bd %s, no indirection' % _bdk)
    for _odk, _odbits in _OD_BITS:
        # IS = 0: preindexed for I/IS = 0xx, postindexed for 1xx.
        extword(_fullpat('0', _bdbits, '0' + _odbits),
                _full[(_bdk, 'pre', _odk)],
                'full, bd %s, preindexed, od %s' % (_bdk, _odk))
        extword(_fullpat('0', _bdbits, '1' + _odbits),
                _full[(_bdk, 'post', _odk)],
                'full, bd %s, postindexed, od %s' % (_bdk, _odk))
        # IS = 1: the index is suppressed, so pre and post are the same path.
        extword(_fullpat('1', _bdbits, '0' + _odbits),
                _full[(_bdk, 'post', _odk)],
                'full, bd %s, indirect, index suppressed, od %s' % (_bdk, _odk))

# Everything else in the full format is reserved, or a BD SIZE of 00 which
# PRM table 2-1 also reserves.
extword('-' + '-' * 7 + '1' + '-' * 8, 'ea_reserved',
        'reserved, or BD SIZE = 00')



# ==========================================================================
def entry(name):
    if name not in LABELS:
        raise SystemExit('program: no label %r' % name)
    return LABELS[name]


def main():
    print('%d microwords, %d labels, %d opcode patterns, %d extension patterns'
          % (len(WORDS), len(LABELS), len(PATTERNS), len(EAPATTERNS)))
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
        print('  %s -> %-14s %s' % (p, t, m))
    print()
    for p, t, m in EAPATTERNS:
        print('  ext %s -> %-14s %s' % (p, t, m))
    return 0


if __name__ == '__main__':
    sys.exit(main())
