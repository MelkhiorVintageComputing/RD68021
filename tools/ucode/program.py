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
MODEPATTERNS = []   # [(pattern, target, what)] -- the mode and register fields


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


def eamode(pattern, target, what):
    """An addressing-mode pattern, for the seq = EAMODE arm.

    Six characters: the mode field and then the register field, exactly as they
    sit in bits 5:0 of the instruction word.
    """
    if len(pattern) != 6 or any(c not in '01-' for c in pattern):
        raise SystemExit('program: %r is not six of 0, 1 and -' % pattern)
    MODEPATTERNS.append((pattern, target, what))


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
u('no pattern for this opcode -- UM 6.1.5, vector 4',
  next='exc_illegal')

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
# BRA -- PRM 4. The displacement is relative to the address of the instruction
# word plus two, which is `pc_d + 2` whatever the pipe has done since.
# ==========================================================================
# The word form comes FIRST, because first match wins and the byte form's
# pattern covers every displacement including the zero that selects this one.
# Writing them the other way round completely shadows this pattern, which
# assemble.py refuses to build. (The $FF displacement that selects BRA.L is
# M7, with the rest of the 32-bit branches.)


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

# The step for (An)+ and -(An) is the operand size, and these two routines are
# shared by instructions that encode their size in different bits of the opcode,
# so it cannot come from a selector of their own. szsel = LATCHED reads what the
# dispatching microword already resolved. Getting this wrong steps every byte
# and word operand by four, which is what it did.
label('ea_an_post')                      # (An)+
u('the address register, then stepped on by the operand size',
  asrc='AREG', alu='A', dst='EA', szsel='LATCHED')
u('... which for A7 and a byte is two, so the stack stays even',
  asrc='AREG', bsrc='OPSIZE', alu='ADD', dst='AREG_EA', szsel='LATCHED',
  seq='RET')

label('ea_an_pre')                       # -(An)
u('the address register stepped back first',
  asrc='AREG', bsrc='OPSIZE', alu='SUB', dst='AREG_EA', szsel='LATCHED')
u('... and that is the address',
  asrc='AREG', alu='A', dst='EA', szsel='LATCHED', seq='RET')

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
# THE ADDRESSING-MODE TABLE
#
# Six bits of the instruction word in, the routine that computes that address
# out. Without it every instruction with an effective address needs one opcode
# pattern per mode -- eighteen of them, times eighty instructions -- and the
# decode table stops being something a person can check against PRM section 8.
#
# Modes 000 and 001 are NOT in it, and neither is 111/100. A register-direct or
# immediate operand touches no memory at all, and whether a bus cycle happens
# may not be decided by a condition -- so those get their own opcode patterns
# and their own two-microword prologue. That is the same rule that put the
# extension-word decoder in hardware, one level down.
# ==========================================================================
for _m, _r, _w in [
        ('010---', 'ea_an_ind',  '(An)'),
        ('011---', 'ea_an_post', '(An)+'),
        ('100---', 'ea_an_pre',  '-(An)'),
        ('101---', 'ea_d16_an',  '(d16,An)'),
        ('110---', 'ea_idx_an',  '(An,Xn)'),
        ('111000', 'ea_abs_w',   '(xxx).W'),
        ('111001', 'ea_abs_l',   '(xxx).L'),
        ('111010', 'ea_d16_pc',  '(d16,PC)'),
        ('111011', 'ea_idx_pc',  '(PC,Xn)')]:
    eamode(_m, _r, _w)


# ==========================================================================
# THE SHAPES
#
# Eighty instructions, half a dozen shapes. Each helper emits one shape; the
# caller writes the opcode patterns, because which encodings reach which entry
# point is the part that has to be read against PRM section 8 by a person.
# ==========================================================================

def src_prologues(stem, szsel, an_ok=True, imm_ok=True, size='LONG',
                  prelude=None):
    """Leave the <ea> source operand in T0, then fall into `stem`_go.

    `size` matters only when szsel is FIXED -- the instructions whose operand
    size is not a field of the opcode at all, like MOVE to CCR.

    `prelude` is emitted at the head of every entry point, for the instructions
    with an extension word of their own BEFORE the effective address's: the long
    forms of MULU, MULS, DIVU and DIVS put their register numbers and their
    signedness there, and it has to be latched before stage C moves on.
    """
    def pre():
        if prelude is not None:
            prelude()
    label(stem + '_dn')
    pre()
    u('the source is a data register',
      asrc='DREG', alu='A', dst='T0', szsel=szsel, size=size)
    goto(stem + '_go')

    if an_ok:
        label(stem + '_an')
        pre()
        u('... or an address register, which is read whole whatever the size',
          asrc='AREG', alu='A', dst='T0', szsel=szsel, size=size)
        goto(stem + '_go')

    if imm_ok:
        # An immediate is already in the pipe and costs no bus cycle. How many
        # words it occupies follows the size, which is in the opcode, so the
        # opcode decoder picks the entry point and no branch has to.
        label(stem + '_immw')
        pre()
        u('... or one word of the instruction stream',
          asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
        goto(stem + '_go')

        label(stem + '_imml')
        pre()
        u('... or two, the first being the high half',
          asrc='STG_C_HI', alu='A', dst='T0', pf='CONSUME')
        u('... and the second the low',
          asrc='T0', bsrc='STG_C_U', alu='OR', dst='T0', pf='CONSUME')
        goto(stem + '_go')

    label(stem + '_mem')
    pre()
    u('... or memory, whose address the mode decoder knows how to build',
      call=1, seq='EAMODE', szsel=szsel, size=size)
    u('read the operand it names',
      bus='READ', fc='EASP', asel='EA', szsel=szsel, size=size)
    u('... into the working register',
      asrc='RDATA', alu='A', dst='T0', szsel=szsel, size=size)
    label(stem + '_go')


def src_patterns(pats, stem, mnem, an_ok=True, imm=None, mem=True):
    """The opcode patterns that reach one set of prologues.

    `pats` is a template with `##` where the six mode and register bits go.
    `imm` is None, 'W' or 'L': how many words an immediate source occupies at
    this instruction's size, which the pattern has already fixed.
    """
    opcode(pats.replace('##', '000---'), stem + '_dn', mnem + ' Dn')
    if an_ok:
        opcode(pats.replace('##', '001---'), stem + '_an', mnem + ' An')
    if imm:
        opcode(pats.replace('##', '111100'),
               stem + ('_immw' if imm == 'W' else '_imml'), mnem + ' #imm')
    if mem:
        opcode(pats.replace('##', '------'), stem + '_mem', mnem + ' <ea>')




# ==========================================================================
# MOVE and MOVEA -- PRM 4
#
# The most-used instruction in the set and the most awkward to encode: the size
# is in bits 13:12 in an order nothing else uses, and the destination's mode and
# register are in bits 8:6 and 11:9, register first.
#
# The destination CLASS -- a data register, an address register or memory --
# decides whether a bus cycle happens, so it comes out of the opcode decoder and
# there are three copies of the source prologues rather than a branch. Within
# the memory class the mode decoder does the rest, reading the destination
# fields through the eadst mux.
# ==========================================================================
def move_family(stem, tail):
    src_prologues(stem, 'MOVE')
    tail()


def _move_to_dn():
    u('the value moved is what sets the codes, not the write',
      asrc='T0', alu='A', dst='DREG', ccr='LOGIC', szsel='MOVE',
      pf='ADV', seq='DECODE')


def _move_to_an():
    # MOVEA. PRM 4: "the entire destination address register is used regardless
    # of the operation size", the word form sign extending to get there, and no
    # condition code is affected at all.
    u('sign extend a word source to the whole register',
      asrc='T0', alu='SX', dst='T0', szsel='MOVE')
    u('... and write all thirty-two bits, touching no condition code',
      asrc='T0', alu='A', dst='AREG', size='LONG', pf='ADV', seq='DECODE')


def _move_to_mem():
    u('the codes come from the value, before anything is written',
      asrc='T0', alu='A', ccr='LOGIC', szsel='MOVE')
    u('the destination address, out of bits 8:6 and 11:9',
      call=1, seq='EAMODE', eadst=1, szsel='MOVE')
    u('... and the write',
      bus='WRITE', fc='DATA', asel='EA', asrc='T0', alu='A', szsel='MOVE',
      pf='ADV', seq='DECODE')


move_family('move_dn',  _move_to_dn)
move_family('move_an',  _move_to_an)
move_family('move_mem', _move_to_mem)

# The patterns. `ss` is 01 byte, 11 word, 10 long, and a byte operation may not
# name an address register at either end -- PRM 4.
for _ss, _szname, _immwords, _an in (('01', 'B', 'W', False),
                                     ('11', 'W', 'W', True),
                                     ('10', 'L', 'L', True)):
    # A data register destination.
    src_patterns('00' + _ss + '---000##', 'move_dn',
                 'MOVE.%s <ea>,Dn <-' % _szname, an_ok=_an, imm=_immwords)
    # An address register destination is MOVEA, and only at word and long.
    if _an:
        src_patterns('00' + _ss + '---001##', 'move_an',
                     'MOVEA.%s <ea>,An <-' % _szname, an_ok=True, imm=_immwords)
    # Everything else. This pattern is written last so that the two above win.
    src_patterns('00' + _ss + '------##', 'move_mem',
                 'MOVE.%s <ea>,<ea> <-' % _szname, an_ok=_an, imm=_immwords)


# ==========================================================================
# The one-operand group: CLR, NEG, NEGX, NOT and TST -- PRM 4
#
# CLR does NOT read its operand. PRM 4 and the MC68010 onwards: "in the MC68000
# and MC68008 a memory destination is read before it is cleared", and on this
# part it is not. One bus cycle, and a difference a bus trace shows.
# ==========================================================================
def unary(stem, body, ccr, reads=True, writes=True):
    label(stem + '_dn')
    body('DREG')
    if writes:
        u('... back into the register the effective address names',
          asrc='T1', alu='A', dst='DREG_R', szsel='IR76', pf='ADV', seq='DECODE')
    else:
        u('nothing is written back', pf='ADV', seq='DECODE')

    label(stem + '_mem')
    u('the address',
      call=1, seq='EAMODE', szsel='IR76')
    if reads:
        u('what is there',
          bus='READ', fc='EASP', asel='EA', szsel='IR76')
        body('RDATA')
    else:
        body('ZERO')
    if writes:
        u('... and the result goes back',
          bus='WRITE', fc='DATA', asel='EA', asrc='T1', alu='A', szsel='IR76',
          pf='ADV', seq='DECODE')
    else:
        u('nothing is written back', pf='ADV', seq='DECODE')


unary('clr',  lambda src: u('zero, without reading what was there',
                            asrc='ZERO', alu='A', dst='T1', ccr='LOGIC',
                            szsel='IR76'),
      'LOGIC', reads=False)
unary('neg',  lambda src: u('zero minus the operand',
                            asrc='ZERO', bsrc=('DREG' if src == 'DREG' else 'RDATA'),
                            alu='SUB', dst='T1', ccr='SUB', szsel='IR76'), 'SUB')
unary('negx', lambda src: u('zero minus the operand and the extend bit',
                            asrc='ZERO', bsrc=('DREG' if src == 'DREG' else 'RDATA'),
                            alu='SUBX', dst='T1', ccr='SUBX', szsel='IR76'), 'SUBX')
unary('not',  lambda src: u('the ones complement',
                            asrc=src, alu='NOT', dst='T1', ccr='LOGIC',
                            szsel='IR76'), 'LOGIC')
unary('tst',  lambda src: u('the operand itself, for its condition codes alone',
                            asrc=src, alu='A', ccr='LOGIC', szsel='IR76'),
      'LOGIC', writes=False)

for _op, _stem, _mnem in (('0100001000', 'clr',  'CLR'),
                          ('0100010000', 'neg',  'NEG'),
                          ('0100000000', 'negx', 'NEGX'),
                          ('0100011000', 'not',  'NOT'),
                          ('0100101000', 'tst',  'TST')):
    for _sz, _n in (('00', 'B'), ('01', 'W'), ('10', 'L')):
        _pat = _op[:8] + _sz + '##'
        opcode(_pat.replace('##', '000---'), _stem + '_dn',
               '%s.%s Dn' % (_mnem, _n))
        opcode(_pat.replace('##', '------'), _stem + '_mem',
               '%s.%s <ea>' % (_mnem, _n))




# ==========================================================================
# The register-only group: SWAP, EXT, EXTB and EXG -- PRM 4
# ==========================================================================
label('swap')
u('the two halves exchanged',
  asrc='DREG', alu='SWAP', dst='DREG_R', size='LONG', ccr='LOGIC',
  pf='ADV', seq='DECODE')

for _name, _alu, _size in (('ext_w', 'EXTW', 'WORD'),
                           ('ext_l', 'EXTL', 'LONG'),
                           ('extb_l', 'EXTB', 'LONG')):
    label(_name)
    u('sign extended in place',
      asrc='DREG', alu=_alu, dst='DREG_R', size=_size, ccr='LOGIC',
      pf='ADV', seq='DECODE')

# EXG. PRM 4 gives it three forms and no condition codes. The register in bits
# 11:9 is the first named, the one in bits 2:0 the second.
for _name, _src1, _dst1, _src2, _dst2 in (
        ('exg_dd', 'DREGW', 'DREG',  'DREG',  'DREG_R'),
        ('exg_aa', 'AREGW', 'AREG',  'AREG',  'AREG_EA'),
        ('exg_da', 'DREGW', 'DREG',  'AREG',  'AREG_EA')):
    label(_name)
    u('hold the first register',
      asrc=_src1, alu='A', dst='T0', size='LONG')
    u('the second goes into the first',
      asrc=_src2, alu='A', dst=_dst1, size='LONG')
    u('... and the first into the second',
      asrc='T0', alu='A', dst=_dst2, size='LONG', pf='ADV', seq='DECODE')

# ==========================================================================
# LEA, PEA, LINK and UNLK -- PRM 4
# ==========================================================================
label('lea')
u('the effective address',
  call=1, seq='EAMODE', size='LONG')
u('... straight into the address register, with no codes touched',
  asrc='EA', alu='A', dst='AREG', size='LONG', pf='ADV', seq='DECODE')

label('pea')
u('the effective address',
  call=1, seq='EAMODE', size='LONG')
u('the stack pointer, four lower',
  asrc='SP', bsrc='FOUR', alu='SUB', dst='T1', size='LONG')
u('... is the new stack pointer',
  asrc='T1', alu='A', dst='SP', size='LONG')
u('and the address goes there',
  bus='WRITE', fc='DATA', asel='T1', asrc='EA', alu='A', bytes=4,
  pf='ADV', seq='DECODE')

# LINK An,#d: SP-4 -> SP, An -> (SP), SP -> An, SP+d -> SP. PRM 4 is explicit
# about the order, and it matters for LINK A7: what gets pushed is the stack
# pointer AFTER the decrement.
def link(name, long_disp):
    label(name)
    u('the stack pointer, four lower',
      asrc='SP', bsrc='FOUR', alu='SUB', dst='T1', size='LONG')
    u('... is the new stack pointer',
      asrc='T1', alu='A', dst='SP', size='LONG')
    u('push the address register',
      bus='WRITE', fc='DATA', asel='T1', asrc='AREG', alu='A', bytes=4)
    u('the frame pointer is the new stack pointer',
      asrc='T1', alu='A', dst='AREG_EA', size='LONG')
    if long_disp:
        u('the high half of the displacement',
          asrc='STG_C_HI', alu='A', dst='T0', pf='CONSUME')
        u('... and the low',
          asrc='T0', bsrc='STG_C_U', alu='OR', dst='T0', pf='CONSUME')
        u('and the displacement, which is signed and usually negative, makes '
          'room on the stack',
          asrc='T1', bsrc='T0', alu='ADD', dst='SP', size='LONG')
    else:
        u('the displacement, sign extended, makes room on the stack',
          asrc='T1', bsrc='STG_C_S', alu='ADD', dst='SP', size='LONG',
          pf='CONSUME')
    u('done',
      pf='ADV', seq='DECODE')


link('link_w', False)
link('link_l', True)

label('unlk')
u('the stack pointer becomes the frame pointer',
  asrc='AREG', alu='A', dst='T1', size='LONG')
u('read the frame pointer that was saved there',
  bus='READ', fc='DATA', asel='T1', bytes=4)
u('... back into the address register',
  asrc='RDATA', alu='A', dst='AREG_EA', size='LONG')
u('and the stack pointer is the four bytes past it',
  asrc='T1', bsrc='FOUR', alu='ADD', dst='SP', size='LONG',
  pf='ADV', seq='DECODE')

# The patterns, ordered so that the specific encodings inside 0100 1000 ... win
# before the general ones. PRM 8 packs LINK.L, NBCD, SWAP, PEA, EXT and MOVEM
# into the same line, distinguished only by bits 8:6 and the mode field.
opcode('0100100000001---', 'link_l',  'LINK.L An,#d32')
opcode('0100100001000---', 'swap',    'SWAP Dn')
opcode('0100100001------', 'pea',     'PEA <ea>')
opcode('0100100010000---', 'ext_w',   'EXT.W Dn')
opcode('0100100011000---', 'ext_l',   'EXT.L Dn')
opcode('0100100111000---', 'extb_l',  'EXTB.L Dn')
opcode('0100111001010---', 'link_w',  'LINK.W An,#d16')
opcode('0100111001011---', 'unlk',    'UNLK An')
opcode('0100---111------', 'lea',     'LEA <ea>,An')
opcode('1100---101000---', 'exg_dd',  'EXG Dx,Dy')
opcode('1100---101001---', 'exg_aa',  'EXG Ax,Ay')
opcode('1100---110001---', 'exg_da',  'EXG Dx,Ay')




# ==========================================================================
# THE TWO-OPERAND ARITHMETIC AND LOGIC GROUP -- PRM 4
#
# ADD, SUB, AND, OR, EOR and CMP share one shape and one line of the opcode map
# each. PRM 8 packs other instructions into the register-direct slots of the
# <ea>-destination direction -- ADDX, SUBX, ABCD, SBCD, EXG and CMPM all live
# there -- so the patterns below are written most-specific first and the
# assembler proves the ordered table and the disjoint one agree.
# ==========================================================================

def ea_to_dn(stem, alu, ccr, szsel='IR86', an_ok=True, rev=False, write=True):
    """op <ea>,Dn."""
    src_prologues(stem, szsel, an_ok=an_ok)
    if rev:
        # PRM 4 defines SUB and CMP as destination minus source, and the adder
        # is not commutative.
        u('destination minus source',
          asrc='DREGW', bsrc='T0', alu=alu, dst=('DREG' if write else 'NONE'),
          ccr=ccr, szsel=szsel, pf='ADV', seq='DECODE')
    else:
        u('the operation',
          asrc='T0', bsrc='DREGW', alu=alu, dst=('DREG' if write else 'NONE'),
          ccr=ccr, szsel=szsel, pf='ADV', seq='DECODE')


def ea_to_an(stem, alu, rev, write):
    """op <ea>,An -- ADDA, SUBA and CMPA.

    PRM 4: the source is sign extended to thirty-two bits and the operation is
    on all of them whatever the size in the opcode. ADDA and SUBA touch no
    condition code at all; CMPA sets them from a long-word comparison.
    """
    src_prologues(stem, 'IR8')
    u('sign extend the source to the whole register',
      asrc='T0', alu='SX', dst='T0', szsel='IR8')
    if rev:
        u('the operation, on all thirty-two bits',
          asrc='AREGW', bsrc='T0', alu=alu, dst=('AREG' if write else 'NONE'),
          size='LONG', ccr=('NONE' if write else 'CMP'), pf='ADV', seq='DECODE')
    else:
        u('the operation, on all thirty-two bits',
          asrc='T0', bsrc='AREGW', alu=alu, dst='AREG', size='LONG',
          pf='ADV', seq='DECODE')


def dn_to_ea(stem, alu, ccr, szsel='IR86', dn_ok=False):
    """op Dn,<ea> -- read, operate, write back."""
    if dn_ok:
        # EOR is the only one of the six whose <ea> direction accepts a data
        # register: PRM 8 gives the same slot in every other line to ABCD, EXG
        # or their relatives.
        label(stem + '_dn')
        u('register to register',
          asrc='DREG', bsrc='DREGW', alu=alu, dst='DREG_R', ccr=ccr,
          szsel=szsel, pf='ADV', seq='DECODE')
    label(stem + '_mem')
    u('the address of the destination',
      call=1, seq='EAMODE', szsel=szsel)
    u('read what is there',
      bus='READ', fc='DATA', asel='EA', szsel=szsel)
    u('... and operate on it',
      asrc='RDATA', bsrc='DREGW', alu=alu, dst='T1', ccr=ccr, szsel=szsel)
    u('... then put it back',
      bus='WRITE', fc='DATA', asel='EA', asrc='T1', alu='A', szsel=szsel,
      pf='ADV', seq='DECODE')


def extend_pair(stem, alu, ccr):
    """ADDX and SUBX, both forms.

    The memory form reads the SOURCE first and the destination second, which is
    the order the accesses come out on the bus and therefore part of what an
    oracle compares.
    """
    # SUBX Dy,Dx is Dx minus Dy minus X, so the register in bits 11:9 is the A
    # side. ADDX does not care and SUBX does, which is why it is written out.
    label(stem + '_dd')
    u('register to register, with the extend bit carried in',
      asrc='DREGW', bsrc='DREG', alu=alu, dst='DREG', ccr=ccr, szsel='IR76',
      pf='ADV', seq='DECODE')

    label(stem + '_mm')
    u('the source register, stepped back',
      asrc='AREG', bsrc='OPSIZE', alu='SUB', dst='T0', szsel='IR76')
    u('... which is its new value',
      asrc='T0', alu='A', dst='AREG_EA', size='LONG')
    u('read the source',
      bus='READ', fc='DATA', asel='T0', szsel='IR76')
    u('and hold it',
      asrc='RDATA', alu='A', dst='T2', szsel='IR76')
    u('the destination register, stepped back',
      asrc='AREGW', bsrc='OPSIZE', alu='SUB', dst='T1', szsel='IR76')
    u('... which is its new value',
      asrc='T1', alu='A', dst='AREG', size='LONG')
    u('read the destination',
      bus='READ', fc='DATA', asel='T1', szsel='IR76')
    u('the operation, with the extend bit carried in',
      asrc='RDATA', bsrc='T2', alu=alu, dst='T3', ccr=ccr, szsel='IR76')
    u('and the result goes back where the destination was',
      bus='WRITE', fc='DATA', asel='T1', asrc='T3', alu='A', szsel='IR76',
      pf='ADV', seq='DECODE')


def alu_patterns(line, stem, mnem, an_ok=True):
    """The five entry points of the <ea>,Dn direction of one opcode line."""
    opcode(line + '---0--000---', stem + '_dn',   mnem + ' Dn,Dn')
    if an_ok:
        opcode(line + '---0--001---', stem + '_an', mnem + ' An,Dn')
    opcode(line + '---000111100', stem + '_immw', mnem + '.B #imm,Dn')
    opcode(line + '---001111100', stem + '_immw', mnem + '.W #imm,Dn')
    opcode(line + '---010111100', stem + '_imml', mnem + '.L #imm,Dn')
    opcode(line + '---0--------', stem + '_mem',  mnem + ' <ea>,Dn')


# ---- the microcode ----
ea_to_dn('add', 'ADD', 'ADD')
ea_to_dn('sub', 'SUB', 'SUB', rev=True)
ea_to_dn('and', 'AND', 'LOGIC', an_ok=False)
ea_to_dn('or',  'OR',  'LOGIC', an_ok=False)
ea_to_dn('cmp', 'SUB', 'CMP', rev=True, write=False)

ea_to_an('adda', 'ADD', rev=False, write=True)
ea_to_an('suba', 'SUB', rev=True,  write=True)
ea_to_an('cmpa', 'SUB', rev=True,  write=False)

dn_to_ea('add_to', 'ADD', 'ADD')
dn_to_ea('sub_to', 'SUB', 'SUB')
dn_to_ea('and_to', 'AND', 'LOGIC')
dn_to_ea('or_to',  'OR',  'LOGIC')
dn_to_ea('eor_to', 'EOR', 'LOGIC', dn_ok=True)

extend_pair('addx', 'ADDX', 'ADDX')
extend_pair('subx', 'SUBX', 'SUBX')

# CMPM (Ay)+,(Ax)+ -- the only mode it has, and the only instruction that
# compares two memory operands.
label('cmpm')
u('the source address, and the register stepped on',
  asrc='AREG', alu='A', dst='T0', szsel='IR76')
u('... by the operand size',
  asrc='AREG', bsrc='OPSIZE', alu='ADD', dst='AREG_EA', szsel='IR76')
u('read the source',
  bus='READ', fc='DATA', asel='T0', szsel='IR76')
u('and hold it',
  asrc='RDATA', alu='A', dst='T2', szsel='IR76')
u('the destination address, and its register stepped on',
  asrc='AREGW', alu='A', dst='T1', szsel='IR76')
u('... likewise',
  asrc='AREGW', bsrc='OPSIZE', alu='ADD', dst='AREG', szsel='IR76')
u('read the destination',
  bus='READ', fc='DATA', asel='T1', szsel='IR76')
u('destination minus source, for the codes alone',
  asrc='RDATA', bsrc='T2', alu='SUB', ccr='CMP', szsel='IR76',
  pf='ADV', seq='DECODE')

# ---- the patterns, most specific first ----
# The A forms take the whole line's opmode 011 and 111, so they come before
# anything that wildcards it.
for _line, _stem in (('1101', 'adda'), ('1001', 'suba'), ('1011', 'cmpa')):
    _M = _stem.upper()
    for _opm, _n, _imm in (('011', 'W', '_immw'), ('111', 'L', '_imml')):
        opcode(_line + '---' + _opm + '000---', _stem + '_dn',
               '%s.%s Dn,An' % (_M, _n))
        opcode(_line + '---' + _opm + '001---', _stem + '_an',
               '%s.%s An,An' % (_M, _n))
        opcode(_line + '---' + _opm + '111100', _stem + _imm,
               '%s.%s #imm,An' % (_M, _n))
        opcode(_line + '---' + _opm + '------', _stem + '_mem',
               '%s.%s <ea>,An' % (_M, _n))




# The rest of each line, in the order PRM 8 packs it: the X forms and CMPM sit
# in the register-direct slots of the <ea> direction, so they are written first.
# MULU, MULS, DIVU and DIVS occupy the 011 and 111 opmode slots of lines 1100
# and 1000 -- the slots ADDA and SUBA occupy on the other lines -- so they are
# claimed before AND and OR wildcard the opmode. PRM 8.
for _line, _stem in (('1100', 'mulw'), ('1000', 'divw')):
    for _opm in ('011', '111'):
        opcode(_line + '---' + _opm + '000---', _stem + '_dn',   _stem + ' Dn')
        opcode(_line + '---' + _opm + '111100', _stem + '_immw', _stem + ' #imm')
        opcode(_line + '---' + _opm + '------', _stem + '_mem',  _stem + ' <ea>')

for _line, _stem, _an in (('1101', 'add', True), ('1001', 'sub', True),
                          ('1100', 'and', False), ('1000', 'or', False)):
    alu_patterns(_line, _stem, _stem.upper(), an_ok=_an)

for _line, _stem in (('1101', 'addx'), ('1001', 'subx')):
    opcode(_line + '---1--000---', _stem + '_dd', _stem.upper() + ' Dy,Dx')
    opcode(_line + '---1--001---', _stem + '_mm', _stem.upper() + ' -(Ay),-(Ax)')

alu_patterns('1011', 'cmp', 'CMP', an_ok=True)
opcode('1011---1--001---', 'cmpm',       'CMPM (Ay)+,(Ax)+')
opcode('1011---1--000---', 'eor_to_dn',  'EOR Dn,Dn')
opcode('1011---1--------', 'eor_to_mem', 'EOR Dn,<ea>')

# ABCD, SBCD, PACK and UNPK sit in the register-direct slots of the <ea>
# direction of lines 1100 and 1000, so they are claimed before those lines are
# -- PRM 8. EXG has already taken its three slots in the same space.
#
# PACK and UNPK are the two the MC68020 added there, and they are the reason
# this ordering is load-bearing rather than tidy: `OR Dn,<ea>` wildcards the
# mode field, and until they were claimed it decoded all 256 of their encodings
# as an OR into a register, which is not an encoding OR has.
opcode('1000---101000---', 'pack_dd', 'PACK Dy,Dx,#adj')
opcode('1000---101001---', 'pack_mm', 'PACK -(Ay),-(Ax),#adj')
opcode('1000---110000---', 'unpk_dd', 'UNPK Dy,Dx,#adj')
opcode('1000---110001---', 'unpk_mm', 'UNPK -(Ay),-(Ax),#adj')
opcode('1100---100000---', 'abcd_dd', 'ABCD Dy,Dx')
opcode('1100---100001---', 'abcd_mm', 'ABCD -(Ay),-(Ax)')
opcode('1000---100000---', 'sbcd_dd', 'SBCD Dy,Dx')
opcode('1000---100001---', 'sbcd_mm', 'SBCD -(Ay),-(Ax)')

for _line, _stem in (('1101', 'add_to'), ('1001', 'sub_to'),
                     ('1100', 'and_to'), ('1000', 'or_to')):
    opcode(_line + '---1--------', _stem + '_mem',
           _stem.split('_')[0].upper() + ' Dn,<ea>')




# ==========================================================================
# THE IMMEDIATE GROUP -- PRM 4
#
# ORI, ANDI, SUBI, ADDI, EORI and CMPI: line 0000, the operation in bits 11:8,
# the size in bits 7:6, and the immediate in the words that follow. The
# immediate is already in the pipe, so how many words it occupies follows the
# size, and the opcode decoder picks the entry point rather than a branch.
#
# ADDQ and SUBQ take their operand out of bits 11:9 instead, with zero meaning
# eight, and the address-register forms of both touch no condition code and
# work on all thirty-two bits whatever the size -- PRM 4.
# ==========================================================================

def imm_to_ea(stem, alu, ccr, rev=False, write=True):
    for _w, _long in (('immw', False), ('imml', True)):
        for _dest in ('dn', 'mem'):
            label('%s_%s_%s' % (stem, _w, _dest))
            if _long:
                u('the high half of the immediate',
                  asrc='STG_C_HI', alu='A', dst='T0', pf='CONSUME')
                u('... and the low',
                  asrc='T0', bsrc='STG_C_U', alu='OR', dst='T0', pf='CONSUME')
            else:
                u('one word of immediate, which a byte operation reads the '
                  'bottom of',
                  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
            goto('%s_%s' % (stem, _dest))

    label(stem + '_dn')
    u('the operation, on the register the mode names',
      asrc=('DREG' if rev else 'T0'), bsrc=('T0' if rev else 'DREG'),
      alu=alu, dst=('DREG_R' if write else 'NONE'), ccr=ccr, szsel='IR76',
      pf='ADV', seq='DECODE')

    label(stem + '_mem')
    u('the address',
      call=1, seq='EAMODE', szsel='IR76')
    u('what is there',
      bus='READ', fc='DATA', asel='EA', szsel='IR76')
    u('... and the operation',
      asrc=('RDATA' if rev else 'T0'), bsrc=('T0' if rev else 'RDATA'),
      alu=alu, dst='T1', ccr=ccr, szsel='IR76')
    if write:
        u('... put back',
          bus='WRITE', fc='DATA', asel='EA', asrc='T1', alu='A', szsel='IR76',
          pf='ADV', seq='DECODE')
    else:
        u('CMPI writes nothing back', pf='ADV', seq='DECODE')


for _bits, _stem, _alu, _ccr, _rev, _wr in (
        ('0000', 'ori',  'OR',  'LOGIC', False, True),
        ('0010', 'andi', 'AND', 'LOGIC', False, True),
        ('0100', 'subi', 'SUB', 'SUB',   True,  True),
        ('0110', 'addi', 'ADD', 'ADD',   False, True),
        ('1010', 'eori', 'EOR', 'LOGIC', False, True),
        ('1100', 'cmpi', 'SUB', 'CMP',   True,  False)):
    imm_to_ea(_stem, _alu, _ccr, rev=_rev, write=_wr)
    _M = _stem.upper()
    # ANDI, ORI and EORI to CCR are byte operations in the immediate slot of
    # their own line, so they have to be claimed before the line is -- PRM 8.
    if _stem in ('andi', 'ori', 'eori'):
        opcode('0000' + _bits + '00111100', _stem + '_ccr',
               _M + ' #imm,CCR')
        # And the privileged form, which is the same instruction on the whole
        # status register at word size. Without this pattern the opcode falls
        # into the general immediate one with an immediate DESTINATION, which
        # no addressing mode allows -- so it became an illegal instruction, and
        # the sweep said so.
        opcode('0000' + _bits + '01111100', _stem + '_sr',
               _M + ' #imm,SR')
    for _sz, _n, _w in (('00', 'B', 'immw'), ('01', 'W', 'immw'),
                        ('10', 'L', 'imml')):
        opcode('0000' + _bits + _sz + '000---', '%s_%s_dn' % (_stem, _w),
               '%s.%s #imm,Dn' % (_M, _n))
        opcode('0000' + _bits + _sz + '------', '%s_%s_mem' % (_stem, _w),
               '%s.%s #imm,<ea>' % (_M, _n))


def quick(stem, alu, ccr):
    # The address-register form. PRM 4: "the condition codes are not affected,
    # and the entire destination address register is used regardless of the
    # operation size", so a word ADDQ to an address register is a long add.
    label(stem + '_an')
    u('all thirty-two bits, and no condition code',
      asrc='AREG', bsrc='IMMQ', alu=alu, dst='AREG_EA', size='LONG',
      pf='ADV', seq='DECODE')

    label(stem + '_dn')
    u('the operation on the register',
      asrc='DREG', bsrc='IMMQ', alu=alu, dst='DREG_R', ccr=ccr, szsel='IR76',
      pf='ADV', seq='DECODE')

    label(stem + '_mem')
    u('the address',
      call=1, seq='EAMODE', szsel='IR76')
    u('what is there',
      bus='READ', fc='DATA', asel='EA', szsel='IR76')
    u('... and the operation',
      asrc='RDATA', bsrc='IMMQ', alu=alu, dst='T1', ccr=ccr, szsel='IR76')
    u('... put back',
      bus='WRITE', fc='DATA', asel='EA', asrc='T1', alu='A', szsel='IR76',
      pf='ADV', seq='DECODE')


quick('addq', 'ADD', 'ADD')
quick('subq', 'SUB', 'SUB')

# Size 11 of this line is Scc and DBcc, so the three sizes are written out
# rather than wildcarded.
for _d, _stem in (('0', 'addq'), ('1', 'subq')):
    for _sz, _n in (('00', 'B'), ('01', 'W'), ('10', 'L')):
        opcode('0101---' + _d + _sz + '001---', _stem + '_an',
               '%s.%s #q,An' % (_stem.upper(), _n))
        opcode('0101---' + _d + _sz + '000---', _stem + '_dn',
               '%s.%s #q,Dn' % (_stem.upper(), _n))
        opcode('0101---' + _d + _sz + '------', _stem + '_mem',
               '%s.%s #q,<ea>' % (_stem.upper(), _n))


# ==========================================================================
# THE CONDITIONAL INSTRUCTIONS -- PRM 4 and table 3-19
#
# Scc, DBcc and Bcc all read the same four bits and the same four flags; the
# sequencer evaluates them, so none of this microcode mentions a flag.
# ==========================================================================
label('scc_dn')
u('the condition',
  seq='COND', cond='CC', next='scc_dn_true')
u('false is a byte of zeros',
  asrc='ZERO', alu='A', dst='DREG_R', size='BYTE', pf='ADV', seq='DECODE')
label('scc_dn_true')
u('and true a byte of ones -- PRM 4, not one',
  asrc='ZERO', alu='NOT', dst='DREG_R', size='BYTE', pf='ADV', seq='DECODE')

label('scc_mem')
u('the address',
  call=1, seq='EAMODE', size='BYTE')
u('the condition',
  seq='COND', cond='CC', next='scc_mem_true')
u('false is a byte of zeros',
  bus='WRITE', fc='DATA', asel='EA', asrc='ZERO', alu='A', bytes=1,
  pf='ADV', seq='DECODE')
label('scc_mem_true')
u('and true a byte of ones',
  bus='WRITE', fc='DATA', asel='EA', asrc='ZERO', alu='NOT', bytes=1,
  pf='ADV', seq='DECODE')

# DBcc Dn,#d. PRM 4: "if the condition is true, no operation is performed";
# otherwise the counter is decremented and the branch is taken unless the
# counter has reached -1. The displacement is relative to the extension word.
label('dbcc')
u('the condition, which if true ends the instruction',
  seq='COND', cond='CC', next='dbcc_done')
u('the low word of the counter, one less, and -1 also ends it',
  asrc='DREG', bsrc='ONE', alu='SUB', dst='DREG_R', size='WORD',
  seq='COND', cond='RESM1', next='dbcc_done')
u('the branch, from the address of the extension word',
  asrc='PC_C', bsrc='STG_C_S', alu='ADD', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')
label('dbcc_done')
u('the displacement word is eaten either way',
  pf='CONSUME')
u('... and the instruction is over',
  pf='ADV', seq='DECODE')

# Bcc, BRA and BSR. The displacement base is the address of the instruction word
# plus two for every size, which is `pc_d + 2`; the byte form carries it in the
# opcode, and the values 0 and $FF select the word and long forms instead.
def branch(stem, disp, sub):
    """Bcc, BRA and BSR at one of the three displacement sizes.

    The displacement is CONSUMED before BSR pushes anything, so that PC_C names
    the next instruction rather than the displacement. It would be eaten by the
    flush either way and the consume looks redundant; it is not, because the
    return address is read between the two.
    """
    label(stem)
    if disp == 'B':
        u('the base, which is the instruction address plus two',
          asrc='PC_D', bsrc='TWO', alu='ADD', dst='T0')
        u('... plus the byte in the opcode, signed',
          asrc='T0', bsrc='DISP8', alu='ADD', dst='T2')
    elif disp == 'W':
        u('the word that follows, sign extended',
          asrc='PC_D', bsrc='TWO', alu='ADD', dst='T0')
        u('... added to the base',
          asrc='T0', bsrc='STG_C_S', alu='ADD', dst='T2', pf='CONSUME')
    else:
        u('the high half of a long displacement',
          asrc='STG_C_HI', alu='A', dst='T2', pf='CONSUME')
        u('... and the low',
          asrc='T2', bsrc='STG_C_U', alu='OR', dst='T2', pf='CONSUME')
        u('the base',
          asrc='PC_D', bsrc='TWO', alu='ADD', dst='T0')
        u('... plus the displacement',
          asrc='T0', bsrc='T2', alu='ADD', dst='T2')
    if sub:
        u('the stack pointer, four lower',
          asrc='SP', bsrc='FOUR', alu='SUB', dst='T1', size='LONG')
        u('... is the new stack pointer',
          asrc='T1', alu='A', dst='SP', size='LONG')
        u('push the address of the next instruction',
          bus='WRITE', fc='DATA', asel='T1', asrc='PC_C', alu='A', bytes=4)
    u('and the target is the new program counter',
      asrc='T2', alu='A', pf='FLUSH')
    u('... then wait for the pipe and decode',
      seq='DECODE')


for _d in ('B', 'W', 'L'):
    branch('bra_' + _d.lower(), _d, False)
    branch('bsr_' + _d.lower(), _d, True)
    # Bcc is BRA behind a test. The not-taken arm has to eat whatever words the
    # displacement occupies, which is why there are three of them.
    label('bcc_' + _d.lower())
    u('the condition',
      seq='COND', cond='CC', next='bra_' + _d.lower())
    if _d == 'B':
        u('not taken, and there is nothing to eat',
          pf='ADV', seq='DECODE')
    elif _d == 'W':
        u('not taken: the displacement word is eaten',
          pf='CONSUME')
        u('... and the instruction is over',
          pf='ADV', seq='DECODE')
    else:
        u('not taken: the first displacement word is eaten',
          pf='CONSUME')
        u('... and the second',
          pf='CONSUME')
        u('... and the instruction is over',
          pf='ADV', seq='DECODE')

# ==========================================================================
# JMP, JSR and the returns -- PRM 4
# ==========================================================================
label('jmp')
u('the effective address',
  call=1, seq='EAMODE', size='LONG')
u('... is the new program counter',
  asrc='EA', alu='A', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')

label('jsr')
u('the effective address',
  call=1, seq='EAMODE', size='LONG')
u('the stack pointer, four lower',
  asrc='SP', bsrc='FOUR', alu='SUB', dst='T1', size='LONG')
u('... is the new stack pointer',
  asrc='T1', alu='A', dst='SP', size='LONG')
# The effective address has consumed its extension words, so PC_C now names the
# word after the instruction -- which is the return address.
u('push the address of the next instruction',
  bus='WRITE', fc='DATA', asel='T1', asrc='PC_C', alu='A', bytes=4)
u('and the effective address is the new program counter',
  asrc='EA', alu='A', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')

def ret(stem, restore_ccr, extra_disp):
    label(stem)
    u('the stack pointer',
      asrc='SP', alu='A', dst='T1', size='LONG')
    if restore_ccr:
        # RTR pops a WORD of condition codes first, and only the low five bits
        # of it are used -- PRM 4, "the supervisor portion is unaffected".
        u('the condition codes, a word of them',
          bus='READ', fc='DATA', asel='T1', bytes=2)
        u('... of which only the low five are restored',
          asrc='RDATA', alu='A', dst='CCR')
        u('the program counter is the long word after it',
          asrc='T1', bsrc='TWO', alu='ADD', dst='T1', size='LONG')
    u('read the return address',
      bus='READ', fc='DATA', asel='T1', bytes=4)
    u('and hold it while the stack pointer is put back',
      asrc='RDATA', alu='A', dst='T2', size='LONG')
    u('the stack pointer, four past the return address',
      asrc='T1', bsrc='FOUR', alu='ADD', dst=('T3' if extra_disp else 'SP'),
      size='LONG')
    if extra_disp:
        # RTD adds a displacement on top, which is how a caller's arguments are
        # dropped in one instruction.
        u('... and the displacement on top of that',
          asrc='T3', bsrc='STG_C_S', alu='ADD', dst='SP', size='LONG',
          pf='CONSUME')
    u('the return address is the new program counter',
      asrc='T2', alu='A', pf='FLUSH')
    u('... then wait for the pipe and decode',
      seq='DECODE')


ret('rts', False, False)
ret('rtr', True,  False)
ret('rtd', False, True)

# ---- the patterns ----
opcode('0101----11111100', 'trapcc_n', 'TRAPcc')
opcode('0101----11111010', 'trapcc_w', 'TRAPcc.W #d')
opcode('0101----11111011', 'trapcc_l', 'TRAPcc.L #d')
opcode('0101----11001---', 'dbcc',    'DBcc Dn,#d16')
opcode('0101----11000---', 'scc_dn',  'Scc Dn')
opcode('0101----11------', 'scc_mem', 'Scc <ea>')

opcode('0100111001110101', 'rts',     'RTS')
opcode('0100111001110111', 'rtr',     'RTR')
opcode('0100111001110100', 'rtd',     'RTD #d16')
opcode('0100111011------', 'jmp',     'JMP <ea>')
opcode('0100111010------', 'jsr',     'JSR <ea>')

opcode('0110000000000000', 'bra_w',   'BRA.W')
opcode('0110000011111111', 'bra_l',   'BRA.L')
opcode('01100000--------', 'bra_b',   'BRA.B')
opcode('0110000100000000', 'bsr_w',   'BSR.W')
opcode('0110000111111111', 'bsr_l',   'BSR.L')
opcode('01100001--------', 'bsr_b',   'BSR.B')
opcode('0110----00000000', 'bcc_w',   'Bcc.W')
opcode('0110----11111111', 'bcc_l',   'Bcc.L')
opcode('0110------------', 'bcc_b',   'Bcc.B')



# ==========================================================================
# THE SHIFTS AND ROTATES -- PRM 4
#
# Eight instructions, two layouts of the same word, and one module that knows
# the condition codes for all of them. The microcode's whole job is to say
# which layout and where the operand comes from.
# ==========================================================================
label('shift_dn')
u('the register, shifted',
  asrc='DREG', alu='SHIFT', shop='REG', dst='DREG_R', ccr='SHIFT',
  szsel='IR76', pf='ADV', seq='DECODE')

label('shift_mem')
u('the address',
  call=1, seq='EAMODE', size='WORD')
u('the word that is there',
  bus='READ', fc='DATA', asel='EA', bytes=2)
u('... shifted one bit',
  asrc='RDATA', alu='SHIFT', shop='MEM', dst='T1', ccr='SHIFT', size='WORD')
u('... and put back',
  bus='WRITE', fc='DATA', asel='EA', asrc='T1', alu='A', bytes=2,
  pf='ADV', seq='DECODE')

# Size 11 of line 1110 is the memory form -- one bit of a word, with the kind in
# bits 10:9. The other three sizes are the register forms, whose kind is in bits
# 4:3 and whose count is in bits 11:9 or in the register they name.
opcode('11100---11------', 'shift_mem', 'shift <ea>')
for _sz in ('00', '01', '10'):
    opcode('1110----' + _sz + '------', 'shift_dn', 'shift Dn')


# ==========================================================================
# THE BIT INSTRUCTIONS -- PRM 4
#
# BTST, BCHG, BCLR and BSET. The bit number is modulo 32 for a data register and
# modulo 8 for a byte in memory. Those are two different masks, so they are two
# different pieces of microcode rather than one with a size-dependent mask: the
# operand size already says which, and writing it once would make the reader
# check a mask instead of reading the manual's sentence.
#
# Only Z moves. PRM 4: "Z is set if the bit tested is zero and cleared
# otherwise; N, V, C and X are unaffected."
# ==========================================================================
def bitop(stem, act, static):
    """`act` is None for BTST, or the ALU operation that changes the bit.

    The static forms latch their bit number into xw BEFORE anything else. They
    have to: the number is the word after the opcode and the effective address's
    extension words come after it, so an address routine that read stage C while
    the number was still sitting there would take the number for its
    displacement. Which is exactly what it did -- BTST #0,(8,A6) read at A6.
    """
    bi = 1 if static else 0

    def number():
        if static:
            u('the bit number, which is the word after the opcode',
              asrc='STG_C', alu='A', dst='XW', size='WORD', pf='CONSUME')

    label(stem + '_dn')
    number()
    u('the bit the number names, modulo thirty-two',
      asrc='DREG', bsrc='BITMASK', alu='AND', ccr='ZBIT', size='LONG',
      bitimm=bi)
    if act is None:
        u('BTST changes nothing', pf='ADV', seq='DECODE')
    else:
        u('... and the register with that bit changed',
          asrc='DREG', bsrc='BITMASK', alu=act, dst='DREG_R', size='LONG',
          bitimm=bi, pf='ADV', seq='DECODE')

    label(stem + '_mem')
    number()
    u('the address',
      call=1, seq='EAMODE', size='BYTE')
    u('the byte that is there',
      bus='READ', fc='EASP', asel='EA', bytes=1)
    u('hold it',
      asrc='RDATA', alu='A', dst='T1', size='BYTE')
    u('the bit the number names, modulo eight',
      asrc='T1', bsrc='BITMASK', alu='AND', ccr='ZBIT', size='BYTE',
      bitimm=bi)
    if act is None:
        u('BTST writes nothing back', pf='ADV', seq='DECODE')
    else:
        u('... and the byte with that bit changed',
          asrc='T1', bsrc='BITMASK', alu=act, dst='T2', size='BYTE',
          bitimm=bi)
        u('... goes back',
          bus='WRITE', fc='DATA', asel='EA', asrc='T2', alu='A', bytes=1,
          pf='ADV', seq='DECODE')


for _stem, _act, _static in (('btst_d', None,    False), ('bchg_d', 'EOR',    False),
                             ('bclr_d', 'ANDNOT', False), ('bset_d', 'OR',     False),
                             ('btst_s', None,    True),  ('bchg_s', 'EOR',    True),
                             ('bclr_s', 'ANDNOT', True), ('bset_s', 'OR',     True)):
    bitop(_stem, _act, _static)

# MOVEP occupies the address-register slots of the DYNAMIC bit instructions --
# an address register is not a legal operand for BTST and its relatives, so PRM
# 8 put MOVEP there. Claimed first, for that reason.
opcode('0000---100001---', 'movep_wr', 'MOVEP.W (d16,Ay),Dx')
opcode('0000---101001---', 'movep_lr', 'MOVEP.L (d16,Ay),Dx')
opcode('0000---110001---', 'movep_wm', 'MOVEP.W Dx,(d16,Ay)')
opcode('0000---111001---', 'movep_lm', 'MOVEP.L Dx,(d16,Ay)')

for _n, _op, _stem in (('BTST', '00', 'btst'), ('BCHG', '01', 'bchg'),
                       ('BCLR', '10', 'bclr'), ('BSET', '11', 'bset')):
    opcode('0000---1' + _op + '000---', _stem + '_d_dn',  _n + ' Dn,Dn')
    opcode('0000---1' + _op + '------', _stem + '_d_mem', _n + ' Dn,<ea>')
    opcode('00001000' + _op + '000---', _stem + '_s_dn',  _n + ' #n,Dn')
    opcode('00001000' + _op + '------', _stem + '_s_mem', _n + ' #n,<ea>')



# ==========================================================================
# THE CONDITION CODES AS AN OPERAND -- PRM 4
#
# MOVE from CCR is an MC68010 addition. On the MC68000 only MOVE from SR
# existed; reading the whole status register became privileged, and this is what
# user code got instead.
#
# Every one of these is a WORD operation whose top eleven bits read as zero and
# whose write reaches only the low five -- PRM 4, "the upper byte is unaffected".
# ==========================================================================
label('move_from_ccr_dn')
u('the codes, zero extended to a word',
  asrc='CCRW', alu='A', dst='DREG_R', size='WORD', pf='ADV', seq='DECODE')

label('move_from_ccr_mem')
u('the address',
  call=1, seq='EAMODE', size='WORD')
u('the codes, as a word',
  bus='WRITE', fc='DATA', asel='EA', asrc='CCRW', alu='A', bytes=2,
  pf='ADV', seq='DECODE')

src_prologues('mtccr', 'FIXED', an_ok=False, size='WORD')
u('only the low five bits of the source reach the codes',
  asrc='T0', alu='A', dst='CCR', size='WORD', pf='ADV', seq='DECODE')

for _stem, _alu, _bits in (('andi_ccr', 'AND', '0010'),
                           ('ori_ccr',  'OR',  '0000'),
                           ('eori_ccr', 'EOR', '1010')):
    label(_stem)
    u('the byte of immediate that follows',
      asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
    u('... against the codes',
      asrc='CCRW', bsrc='T0', alu=_alu, dst='CCR', size='BYTE',
      pf='ADV', seq='DECODE')

opcode('0100001011000---', 'move_from_ccr_dn',  'MOVE CCR,Dn')
opcode('0100001011------', 'move_from_ccr_mem', 'MOVE CCR,<ea>')
opcode('0100010011000---', 'mtccr_dn',          'MOVE Dn,CCR')
opcode('0100010011111100', 'mtccr_immw',        'MOVE #imm,CCR')
opcode('0100010011------', 'mtccr_mem',         'MOVE <ea>,CCR')


# ==========================================================================
# MOVEM -- PRM 4
#
# The only instruction in the integer set with a loop in it. Sixteen registers,
# a mask in the word after the opcode, and one bit of that mask per register.
#
# doc/checkpoint.md's rule on bus-steering conditions was written with this in
# mind: a condition may steer the bus only if it is a single bit of a register
# whose only source is read data or the extension-word latch. MASK0 is exactly
# that, which is why MOVEM is expressible at all.
#
# The predecrement form is the odd one. PRM 4: the mask is reversed, "bit 0
# selects A7", the address register is decremented BEFORE each transfer and is
# left pointing at the last word written. REGNR is the reversal.
#
# And a word transfer into a register is sign extended into all thirty-two bits,
# for a DATA register as well as an address one -- the one place in the whole
# instruction set where that is true of a data register.
# ==========================================================================
def movem(stem, to_mem, step_before, reverse, ctl):
    """One of MOVEM's four shapes."""
    src = 'REGNR' if reverse else 'REGN'
    label(stem)
    u('the register mask, which is the word after the opcode',
      asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
    if ctl:
        u('the address the mode names',
          call=1, seq='EAMODE', szsel='IR6')
        u('... which the loop walks from',
          asrc='EA', alu='A', dst='T1', size='LONG')
    else:
        u('the address register the loop walks from',
          asrc='AREG', alu='A', dst='T1', size='LONG')
    u('start at the first register',
      cnt='ZERO')

    label(stem + '_loop')
    u('all sixteen looked at?',
      seq='COND', cond='CNT16', next=stem + '_done')
    u('is this one in the list?',
      seq='COND', cond='MASK0', next=stem + '_xfer')

    label(stem + '_next')
    u('shift the mask along and step the register number',
      asrc='T0', alu='LSR1', dst='T0', size='WORD', cnt='INC',
      next=stem + '_loop')

    label(stem + '_xfer')
    if step_before:
        u('the address steps back BEFORE the transfer',
          asrc='T1', bsrc='OPSIZE', alu='SUB', dst='T1', szsel='IR6')
    if to_mem:
        u('and the register goes there',
          bus='WRITE', fc='DATA', asel='T1', asrc=src, alu='A', szsel='IR6',
          next=stem + ('_next' if step_before else '_after'))
    else:
        u('read what is there',
          bus='READ', fc='EASP', asel='T1', szsel='IR6')
        u('... sign extended into the whole register',
          asrc='RDATA', alu='SX', dst=src, szsel='IR6',
          next=stem + ('_next' if step_before else '_after'))
    if not step_before:
        label(stem + '_after')
        u('the address steps on AFTER the transfer',
          asrc='T1', bsrc='OPSIZE', alu='ADD', dst='T1', szsel='IR6',
          next=stem + '_next')

    label(stem + '_done')
    if ctl:
        u('a control mode leaves no register to put back',
          pf='ADV', seq='DECODE')
    else:
        u('the address register is left where the loop stopped',
          asrc='T1', alu='A', dst='AREG_EA', size='LONG')
        u('done',
          pf='ADV', seq='DECODE')


#        stem                 to_mem  step_before  reverse  ctl
movem('movem_to_pd',          True,   True,        True,    False)
movem('movem_to_ctl',         True,   False,       False,   True)
movem('movem_from_pi',        False,  False,       False,   False)
movem('movem_from_ctl',       False,  False,       False,   True)

# PRM 8: bit 10 is the direction, bit 6 the size, and the mode field picks the
# predecrement and postincrement forms out of the rest.
opcode('010010001-100---', 'movem_to_pd',    'MOVEM regs,-(An)')
opcode('010010001-------', 'movem_to_ctl',   'MOVEM regs,<ea>')
opcode('010011001-011---', 'movem_from_pi',  'MOVEM (An)+,regs')
opcode('010011001-------', 'movem_from_ctl', 'MOVEM <ea>,regs')


# ==========================================================================
# MULU, MULS, DIVU and DIVS -- PRM 4
#
# Four instructions, eight shapes. The word forms carry their signedness in bit
# 8 of the opcode; the long forms carry it, and their register numbers, in an
# extension word of their own that comes BEFORE the effective address's:
#
#     0 Dq/Dl(3) signed size 0000000 Dr/Dh(3)
#
# so it is latched first and the effective address follows. `mdext` tells the
# datapath which of the two to read the signedness from.
#
# One 32-by-32 multiplier and one 64-by-32 divider serve all of them, because
# the microcode widens the operands first with alu = XSZ -- signed or unsigned
# as the instruction says -- and puts them where the units look: T0 and T1 for
# the multiply, T3:T2 over T1 for the divide.
#
# On divide overflow PRM 4 is explicit: "it sets the overflow condition code,
# and the operands are unaffected". So the overflow arm writes no register.
# ==========================================================================
src_prologues('mulw', 'FIXED', an_ok=False, size='WORD')
u('the source, widened as the signedness says',
  asrc='T0', alu='XSZ', dst='T1', size='WORD')
u('and the destination register, likewise',
  asrc='DREGW', alu='XSZ', dst='T0', size='WORD')
u('the product of two words is a long word, and never overflows',
  asrc='MULLO', alu='A', dst='DREG', size='LONG', ccr='MUL32', mdop='MUL',
  pf='ADV', seq='DECODE')

src_prologues('divw', 'FIXED', an_ok=False, size='WORD')
u('the divisor, widened as the signedness says',
  asrc='T0', alu='XSZ', dst='T1', size='WORD')
u('the dividend is the whole destination register',
  asrc='DREGW', alu='A', dst='T2', size='LONG')
u('... whose top half is its sign, or nothing',
  asrc='T2', alu='XSZHI', dst='T3', size='LONG')
u('divide, and stall until it is done. A zero divisor never starts it, so the '
  'stall resolves at once and the trap is taken -- PRM 4',
  mdop='DIV', size='WORD', seq='COND', cond='DIVZERO', next='exc_divzero')
u('... and the quotient has to fit where it is going',
  mdop='DIV', size='WORD', seq='COND', cond='MDOVF', next='divw_ovf')
u('the remainder goes in the high word',
  asrc='DIVR', alu='SHL16', dst='T0', size='LONG')
u('... and the quotient in the low one',
  asrc='T0', bsrc='DIVQ', alu='ORLOW16', dst='T1', size='LONG')
u('the quotient is what sets the codes, at sixteen bits',
  asrc='DIVQ', alu='A', ccr='DIV', size='WORD')
u('and both halves are written together',
  asrc='T1', alu='A', dst='DREG', size='LONG', pf='ADV', seq='DECODE')
label('divw_ovf')
u('on overflow the operands are unaffected and V is set -- PRM 4',
  ccr='DIVV', pf='ADV', seq='DECODE')


def _mdlong_prelude():
    u('the extension word, which names the registers and the signedness',
      asrc='STG_C', alu='A', dst='XW', size='WORD', pf='CONSUME')


src_prologues('mull', 'FIXED', an_ok=False, size='LONG',
              prelude=_mdlong_prelude)
u('the source',
  asrc='T0', alu='A', dst='T1', size='LONG')
u('and the register the extension word names as the low half',
  asrc='DREG_XQ', alu='A', dst='T0', size='LONG')
u('a 64-bit product goes in two registers',
  mdop='MUL', mdext=1, size='LONG', seq='COND', cond='XW10', next='mull_64')
u('a 32-bit one takes only the low half, and V says whether it fitted',
  asrc='MULLO', alu='A', dst='DREG_XQ', size='LONG', ccr='MUL32',
  mdop='MUL', mdext=1, pf='ADV', seq='DECODE')
label('mull_64')
u('the high half',
  asrc='MULHI', alu='A', dst='DREG_XR', size='LONG', mdop='MUL', mdext=1)
u('... and the low, with the codes taken from all sixty-four bits',
  asrc='MULLO', alu='A', dst='DREG_XQ', size='LONG', ccr='MUL64',
  mdop='MUL', mdext=1, pf='ADV', seq='DECODE')

src_prologues('divl', 'FIXED', an_ok=False, size='LONG',
              prelude=_mdlong_prelude)
u('the divisor',
  asrc='T0', alu='A', dst='T1', size='LONG')
u('the low half of the dividend',
  asrc='DREG_XQ', alu='A', dst='T2', size='LONG')
u('the high half is a second register, or the sign of the first',
  seq='COND', cond='XW10', next='divl_64')
u('... the sign of the first',
  asrc='T2', alu='XSZHI', dst='T3', size='LONG', mdext=1, next='divl_start')
label('divl_64')
u('... or the register the extension word names',
  asrc='DREG_XR', alu='A', dst='T3', size='LONG')
label('divl_start')
u('divide, and stall until it is done',
  mdop='DIV', mdext=1, size='LONG', seq='COND', cond='DIVZERO',
  next='exc_divzero')
u('... and the quotient has to fit where it is going',
  mdop='DIV', mdext=1, size='LONG', seq='COND', cond='MDOVF', next='divl_ovf')
# PRM 4: the remainder goes to Dr and the quotient to Dq. When they are the same
# register -- which is how DIVx.L <ea>,Dq is written -- the quotient must be
# what survives, so it is written second.
u('the remainder',
  asrc='DIVR', alu='A', dst='DREG_XR', size='LONG')
u('... and then the quotient, which wins when they are the same register',
  asrc='DIVQ', alu='A', dst='DREG_XQ', size='LONG', ccr='DIV',
  pf='ADV', seq='DECODE')
label('divl_ovf')
u('on overflow the operands are unaffected and V is set -- PRM 4',
  ccr='DIVV', pf='ADV', seq='DECODE')

# ---- the patterns ----
for _op, _stem in (('0100110000', 'mull'), ('0100110001', 'divl')):
    opcode(_op + '000---', _stem + '_dn',   _stem + ' Dn')
    opcode(_op + '111100', _stem + '_imml', _stem + ' #imm')
    opcode(_op + '------', _stem + '_mem',  _stem + ' <ea>')


# ==========================================================================
# ABCD, SBCD, NBCD and TAS -- PRM 4
#
# The decimal adjust is in the datapath; the microcode's job is to get the two
# bytes to it. The memory forms of ABCD and SBCD are -(Ay),-(Ax), which read the
# SOURCE first, exactly as ADDX and SUBX do.
#
# NBCD is SBCD with a zero minuend: "0 - destination - X".
# ==========================================================================
def bcd_pair(stem, alu):
    label(stem + '_dd')
    u('two registers, with the extend bit carried in',
      asrc='DREGW', bsrc='DREG', alu=alu, dst='DREG', ccr='BCD', size='BYTE',
      pf='ADV', seq='DECODE')

    label(stem + '_mm')
    u('the source register, stepped back a byte',
      asrc='AREG', bsrc='ONE', alu='SUB', dst='T0', size='LONG')
    u('... which is its new value',
      asrc='T0', alu='A', dst='AREG_EA', size='LONG')
    u('read the source',
      bus='READ', fc='DATA', asel='T0', bytes=1)
    u('and hold it',
      asrc='RDATA', alu='A', dst='T2', size='BYTE')
    u('the destination register, stepped back a byte',
      asrc='AREGW', bsrc='ONE', alu='SUB', dst='T1', size='LONG')
    u('... which is its new value',
      asrc='T1', alu='A', dst='AREG', size='LONG')
    u('read the destination',
      bus='READ', fc='DATA', asel='T1', bytes=1)
    u('the decimal operation',
      asrc='RDATA', bsrc='T2', alu=alu, dst='T3', ccr='BCD', size='BYTE')
    u('and the result goes back',
      bus='WRITE', fc='DATA', asel='T1', asrc='T3', alu='A', bytes=1,
      pf='ADV', seq='DECODE')


bcd_pair('abcd', 'ABCD')
bcd_pair('sbcd', 'SBCD')

unary('nbcd', lambda src: u('zero minus the operand and the extend bit, in decimal',
                            asrc='ZERO', bsrc=src, alu='SBCD', dst='T1',
                            ccr='BCD', size='BYTE'),
      'BCD')

# TAS. PRM 4: the operand's codes are taken BEFORE bit 7 is set, and the whole
# thing is one indivisible read-modify-write -- UM 5.5.2, which is what rmc is
# for. It is the only instruction in the MC68010 set that holds RMC.
label('tas_dn')
u('the register, tested and then bit 7 set',
  asrc='DREG', alu='A', ccr='LOGIC', size='BYTE')
u('... in place',
  asrc='DREG', alu='SETB7', dst='DREG_R', size='BYTE', pf='ADV', seq='DECODE')

label('tas_mem')
u('the address',
  call=1, seq='EAMODE', size='BYTE')
u('read the byte, holding the bus',
  bus='READ', fc='DATA', asel='EA', bytes=1, rmc=1)
u('its codes come from what was there, before anything is set',
  asrc='RDATA', alu='A', dst='T1', ccr='LOGIC', size='BYTE', rmc=1)
u('and bit 7 goes back, still holding the bus',
  bus='WRITE', fc='DATA', asel='EA', asrc='T1', alu='SETB7', bytes=1, rmc=1,
  pf='ADV', seq='DECODE')

opcode('0100100000000---', 'nbcd_dn',  'NBCD Dn')
opcode('0100100000------', 'nbcd_mem', 'NBCD <ea>')
opcode('0100101011111100', 'exc_illegal', 'ILLEGAL')
opcode('0100101011000---', 'tas_dn',   'TAS Dn')
opcode('0100101011------', 'tas_mem',  'TAS <ea>')




# ==========================================================================
# MOVEP -- PRM 4
#
# A word or a long word through every OTHER byte of memory, most significant
# first, so that a register can be moved to or from a sixteen-bit peripheral
# sitting on half of a wider bus. The only instruction whose accesses are all
# bytes whatever its own size, and the only one that skips addresses.
#
# The register is walked a byte at a time rather than selected a byte at a time:
# a byte-position source would need one encoding per position, and shifting
# needs one.
# ==========================================================================
def movep(stem, to_mem, nbytes):
    label(stem)
    u('the address: the register plus the word that follows',
      asrc='AREG', bsrc='STG_C_S', alu='ADD', dst='T1', size='LONG',
      pf='CONSUME')
    if to_mem:
        # The most significant byte goes first, so the register is rotated down
        # by one byte less than its width to bring that byte to the bottom.
        u('the register to be taken apart',
          asrc='DREGW', alu='A', dst='T0', size='LONG')
        for _ in range(4 - nbytes):
            u('discard the bytes above the operand',
              asrc='T0', alu='SHL8OR', bsrc='ZERO', dst='T0', size='LONG')
        for i in range(nbytes):
            # After the shifts above, the operand's most significant byte is in
            # bits 31:24; bring it down to 7:0 one byte at a time.
            u('the byte that goes next is the top one',
              asrc='T0', alu='ROL8', dst='T0', size='LONG')
            u('write it, then skip an address',
              bus='WRITE', fc='DATA', asel='T1', asrc='T0', alu='A', bytes=1)
            if i != nbytes - 1:
                u('every OTHER byte -- PRM 4',
                  asrc='T1', bsrc='TWO', alu='ADD', dst='T1', size='LONG')
        u('done', pf='ADV', seq='DECODE')
    else:
        u('start with nothing',
          asrc='ZERO', alu='A', dst='T0', size='LONG')
        for i in range(nbytes):
            u('read a byte',
              bus='READ', fc='DATA', asel='T1', bytes=1)
            u('... and shift it in at the bottom',
              asrc='T0', bsrc='RDATA', alu='SHL8OR', dst='T0', size='LONG')
            if i != nbytes - 1:
                u('every OTHER byte -- PRM 4',
                  asrc='T1', bsrc='TWO', alu='ADD', dst='T1', size='LONG')
        # A word form leaves the top half of the register alone; a long form
        # writes all of it.
        u('into the register, at the size the opcode says',
          asrc='T0', alu='A', dst='DREG',
          size=('LONG' if nbytes == 4 else 'WORD'),
          pf='ADV', seq='DECODE')


movep('movep_wr', False, 2)   # MOVEP.W (d,Ay),Dx
movep('movep_lr', False, 4)   # MOVEP.L (d,Ay),Dx
movep('movep_wm', True,  2)   # MOVEP.W Dx,(d,Ay)
movep('movep_lm', True,  4)   # MOVEP.L Dx,(d,Ay)



# ==========================================================================
# CHK -- PRM 4
#
# "If the register is less than zero or greater than the upper bound, a CHK
# exception occurs." The MC68020 adds the long form; the MC68010 had only the
# word one, and PRM 8 encodes the two in opmodes 110 and 100 -- bit 7 alone.
#
# PRM 4 on the condition codes: "N: set if the compared value is less than
# zero; cleared if greater than the upper bound; undefined otherwise. Z, V, C:
# undefined." The two defined cases are exactly the two that trap, so N is a
# statement about what the handler finds in the frame and not about what the
# instruction leaves behind.
#
# The first comparison writes the codes, and the sign of what it computes IS the
# N the manual asks for when the register is negative. The second does not: its
# rule is "cleared if greater than the upper bound", which is about why the trap
# happened, so the trapping path clears N outright rather than trusting the sign
# of a subtraction that a negative bound can overflow. Z, V and C are zero on
# both trapping paths; the manual leaves them undefined and doc/divergences.md
# records the choice. The non-trapping path falls under "undefined otherwise".
# ==========================================================================
src_prologues('chk', 'CHK', an_ok=False)
u('the upper bound',
  asrc='T0', alu='A', dst='T1', szsel='CHK')
u('less than zero? -- and N is the sign of the register, PRM 4',
  asrc='DREGW', alu='A', szsel='CHK', ccr='LOGIC', seq='COND', cond='RESNEG',
  next='chk_trap')
u('greater than the bound?',
  asrc='DREGW', bsrc='T1', alu='SUB', szsel='CHK',
  seq='COND', cond='GTZ', next='chk_trap_high')
u('neither, so the instruction does nothing at all',
  pf='ADV', seq='DECODE')
label('chk_trap_high')
u('... and then N is CLEARED, because that is what the rule says and not what '
  'the sign of the difference says: a negative upper bound makes the '
  'subtraction overflow and the two part company',
  ccr='CLRNZVC')
label('chk_trap')
u('a CHK exception -- UM table 6-1, vector 6, and a six-word frame',
  next='exc_chk')

for _opm, _n in (('110', 'W'), ('100', 'L')):
    opcode('0100---' + _opm + '000---', 'chk_dn',   'CHK.%s Dn,Dn' % _n)
    opcode('0100---' + _opm + '111100', 'chk_immw' if _n == 'W' else 'chk_imml',
           'CHK.%s #imm,Dn' % _n)
    opcode('0100---' + _opm + '------', 'chk_mem',  'CHK.%s <ea>,Dn' % _n)



# ==========================================================================
# PACK and UNPK -- PRM 4, new on the MC68020
#
# "Adjusts and packs the lower four bits of each of two bytes into a single
# byte", and the reverse. Both take a sixteen-bit adjustment in the word after
# the opcode, and neither touches the condition codes.
#
# The adjustment goes in at different points in the two instructions, and the
# manual is explicit about it: PACK adds it to the source BEFORE the nibbles are
# taken out, and UNPK adds it AFTER they have been spread apart. Doing either
# the other way round changes the answer whenever the addition carries between
# the nibbles, which is the whole reason the adjustment exists.
#
# The register in bits 11-9 is the DESTINATION and the one in bits 2-0 is the
# source, which is the layout ABCD and SBCD use and the opposite of the way the
# assembler syntax reads.
# ==========================================================================
label('pack_dd')
u('the adjustment word that follows the opcode',
  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
u('the source plus it -- PRM 4, the addition comes first',
  asrc='DREG', bsrc='T0', alu='ADD', dst='T1', size='WORD')
u('and the two low nibbles of that, packed into the destination byte',
  asrc='T1', alu='PACK', dst='DREG', size='BYTE', pf='ADV', seq='DECODE')

# The memory forms move BYTES, one access each, and not the word the two of them
# make up: PRM 4 says "two bytes from the source are fetched and concatenated",
# and a part that fetched a word could not do that from an odd address. The
# access list is what settles it -- the oracle makes three transfers where a
# word access would make two.
label('pack_mm')
u('the adjustment word',
  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
u('the source register, back one byte',
  asrc='AREG', bsrc='ONE', alu='SUB', dst='T1', size='LONG')
u('read the byte at the higher address, which is the low one of the pair',
  bus='READ', fc='DATA', asel='T1', bytes=1)
u('... held',
  asrc='RDATA', alu='A', dst='T2', size='BYTE')
u('back one more',
  asrc='T1', bsrc='ONE', alu='SUB', dst='T1', size='LONG')
u('... which is the register\'s new value',
  asrc='T1', alu='A', dst='AREG_EA', size='LONG')
u('read the other one',
  bus='READ', fc='DATA', asel='T1', bytes=1)
u('the two of them concatenated',
  asrc='RDATA', bsrc='T2', alu='BYTEPAIR', dst='T2', size='WORD')
u('... plus the adjustment',
  asrc='T2', bsrc='T0', alu='ADD', dst='T2', size='WORD')
u('the destination register, back the one byte it writes',
  asrc='AREGW', bsrc='ONE', alu='SUB', dst='T3', size='LONG')
u('... which is its new value',
  asrc='T3', alu='A', dst='AREG', size='LONG')
u('and the packed byte goes there',
  bus='WRITE', fc='DATA', asel='T3', asrc='T2', alu='PACK', bytes=1,
  pf='ADV', seq='DECODE')

label('unpk_dd')
u('the adjustment word that follows the opcode',
  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
u('the source byte, spread into two',
  asrc='DREG', alu='UNPK', dst='T1', size='WORD')
u('... and the adjustment goes on AFTER that -- PRM 4',
  asrc='T1', bsrc='T0', alu='ADD', dst='DREG', size='WORD',
  pf='ADV', seq='DECODE')

label('unpk_mm')
u('the adjustment word',
  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
u('the source register, back the one byte it reads',
  asrc='AREG', bsrc='ONE', alu='SUB', dst='T1', size='LONG')
u('... which is its new value',
  asrc='T1', alu='A', dst='AREG_EA', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T1', bytes=1)
u('spread into two bytes',
  asrc='RDATA', alu='UNPK', dst='T2', size='WORD')
u('... plus the adjustment',
  asrc='T2', bsrc='T0', alu='ADD', dst='T2', size='WORD')
u('the destination register, back one byte',
  asrc='AREGW', bsrc='ONE', alu='SUB', dst='T3', size='LONG')
u('the low byte of the pair goes at the higher address',
  bus='WRITE', fc='DATA', asel='T3', asrc='T2', alu='A', bytes=1)
u('back one more',
  asrc='T3', bsrc='ONE', alu='SUB', dst='T3', size='LONG')
u('... which is the register\'s new value',
  asrc='T3', alu='A', dst='AREG', size='LONG')
u('and the other byte goes there',
  bus='WRITE', fc='DATA', asel='T3', asrc='T2', alu='SHR8', bytes=1,
  pf='ADV', seq='DECODE')

# ==========================================================================
# MOVEC -- PRM 6
#
# "This is always a 32-bit transfer, even though the control register may be
# implemented with fewer bits." The direction is bit 0 of the opcode and
# everything else is in the extension word.
#
# MOVEC is privileged. The privilege violation is M8, along with the format
# error an unimplemented control-register code has to raise; until then this
# runs in whatever mode it is given, which the vector sweep always makes
# supervisor.
# ==========================================================================
label('movec_to_gen')
u('MOVEC is privileged -- PRM 6, "if supervisor state then ... else TRAP"',
  seq='COND', cond='USER', next='exc_priv')
u('the extension word names both registers',
  asrc='STG_C', alu='A', dst='XW', size='WORD', pf='CONSUME')
u('the control register into the general one',
  asrc='CREG', alu='A', dst='XREG', size='LONG', pf='ADV', seq='DECODE')

label('movec_to_ctl')
u('MOVEC is privileged -- PRM 6, "if supervisor state then ... else TRAP"',
  seq='COND', cond='USER', next='exc_priv')
u('the extension word names both registers',
  asrc='STG_C', alu='A', dst='XW', size='WORD', pf='CONSUME')
u('the general register into the control one',
  asrc='XREG', alu='A', dst='CREG', size='LONG', pf='ADV', seq='DECODE')

opcode('0100111001111010', 'movec_to_gen', 'MOVEC Rc,Rn')
opcode('0100111001111011', 'movec_to_ctl', 'MOVEC Rn,Rc')


# ==========================================================================
# EXCEPTION PROCESSING -- UM 6.1
#
# "Exception processing occurs in four functional steps."
#
#   1. copy the status register, set S, clear T1 and T0
#   2. determine the vector number
#   3. save the context: a frame on the ACTIVE SUPERVISOR stack
#   4. vector offset = number x 4, address = VBR + offset, load the PC
#
# Step one is one microword, not two: between setting S and clearing the trace
# bits the processor would be at the supervisor level with tracing still on.
#
# The routines below are entered with
#
#   T0 = the vector OFFSET, which is the number times four
#   T1 = the program counter to stack
#   T2 = the instruction address, for a format $2 frame
#
# and they leave the frame built, the vector read and the pipe refilled. The
# caller says which frame to build by which routine it jumps to.
#
# The frame is written from the top down, which is what a stack is: one pointer,
# no address arithmetic, and it ends where the frame begins. UM 6.4 explicitly
# allows it -- "the processor does not necessarily read or write the stack frame
# data in sequential order" -- and says only that the offsets must come out
# right.
# ==========================================================================
def frame_body(frame, six):
    """The words of a four- or six-word frame, written top down from EA.

    One pointer, walking down: the frame is built from its highest address to
    its lowest, so every write is `EA -= n` then `store`, and EA ends up where
    the frame begins -- which is the new stack pointer.
    """
    if six:
        u('+$08: the address of the instruction that caused it',
          asrc='EA', bsrc='FOUR', alu='SUB', dst='EA', size='LONG')
        u('... written there',
          bus='WRITE', fc='DATA', asel='EA', asrc='T2', alu='A', bytes=4)
    u('+$06: the format and the vector offset',
      asrc='EA', bsrc='TWO', alu='SUB', dst='EA', size='LONG')
    u('... written there',
      bus='WRITE', fc='DATA', asel='EA', asrc='FMTVEC', alu='A', bytes=2,
      frame=frame)
    u('+$02: the program counter',
      asrc='EA', bsrc='FOUR', alu='SUB', dst='EA', size='LONG')
    u('... written there',
      bus='WRITE', fc='DATA', asel='EA', asrc='T1', alu='A', bytes=4)
    u('+$00: the status register as it was',
      asrc='EA', bsrc='TWO', alu='SUB', dst='EA', size='LONG')
    u('... written there',
      bus='WRITE', fc='DATA', asel='EA', asrc='T3', alu='A', bytes=2)


def exception(stem, frame, six):
    label(stem)
    # Step one. The status register is copied BEFORE it is changed, and the
    # copy is what goes in the frame.
    u('a copy of the status register as it was',
      asrc='SR', alu='A', dst='T3', size='WORD')
    u('supervisor, and no tracing of the handler -- UM 6.1 step one',
      asrc='SR', alu='EXCSR', dst='SR', size='WORD')
    # Setting S may have changed which register A7 is. Everything from here
    # runs on the supervisor stack, which is what UM 6.1 step three asks for.
    label(stem + '_stack')
    u('the stack pointer, now the supervisor one',
      asrc='SP', alu='A', dst='EA', size='LONG')
    frame_body(frame, six)
    u('and the stack pointer is where the frame begins',
      asrc='EA', alu='A', dst='SP', size='LONG')
    label(stem + '_vector')
    u('the vector address: the base plus the offset -- UM 6.1 step four',
      asrc='VBR', bsrc='T0', alu='ADD', dst='T1', size='LONG')
    u('read the vector. UM 2.1.2 puts every vector but the reset one in '
      'supervisor DATA space',
      bus='READ', fc='DATA', asel='T1', bytes=4)
    u('... and that is where the handler is',
      asrc='RDATA', alu='A', pf='FLUSH')
    u('... then wait for the pipe and decode',
      seq='DECODE')


exception('exc_f0', 'F0', False)
exception('exc_f2', 'F2', True)

# --------------------------------------------------------------------------
# The sources that need no operand
#
# UM table 6-5 says which frame each takes and what the stacked program counter
# points at. The two that matter:
#
#   format $0, and the FAULTING instruction    illegal, A-line, F-line,
#                                              privilege violation
#   format $2, the NEXT instruction, and the   CHK, TRAPcc, TRAPV, zero divide,
#   faulting one at +$08                       trace
#
# "This instruction" is pc_d. "The next instruction" is PC_C once the extension
# words have been consumed -- the same thing BSR and JSR push, and true for the
# same reason.
# --------------------------------------------------------------------------
def exc_here(stem, vec, executed=False):
    """Format $0, stacking the address of the instruction that caused it.

    `executed` is false for the four that are raised INSTEAD of running an
    instruction -- illegal, the two unimplemented lines, and the privilege
    violation. UM 6.1.7: such an instruction "does not cause a trace exception
    since it is not executed", which is what notrace says.
    """
    label(stem)
    u('the vector offset',
      asrc='VECOFF', alu='A', dst='T0', size='LONG', vec=vec,
      notrace=(0 if executed else 1))
    u('the frame carries the address of THIS instruction -- UM table 6-5',
      asrc='PC_D', alu='A', dst='T1', size='LONG', next='exc_f0')


def exc_next(stem, vec, vecsrc='VECOFF'):
    """Format $2: the next instruction, and this one at +$08."""
    label(stem)
    u('the vector offset',
      asrc=vecsrc, alu='A', dst='T0', size='LONG', vec=vec)
    u('the address of the instruction that caused it',
      asrc='PC_D', alu='A', dst='T2', size='LONG')
    u('and the frame carries the address of the NEXT one',
      asrc='PC_C', alu='A', dst='T1', size='LONG', next='exc_f2')


exc_here('exc_illegal',   4)
exc_here('exc_line_a',   10)
exc_here('exc_line_f',   11)
exc_here('exc_priv',      8)
exc_next('exc_chk',       6)
exc_next('exc_trapcc',    7)
exc_next('exc_divzero',   5)

# TRAP #n. PRM 4: vector 32 + n, and the frame carries the address of the next
# instruction, which for a one-word instruction is simply the word after it.
label('trap_n')
u('the vector offset: 32 plus the four bits in the opcode, times four',
  asrc='TRAPVEC', alu='A', dst='T0', size='LONG')
u('and the frame carries the address of the next instruction',
  asrc='PC_C', alu='A', dst='T1', size='LONG', next='exc_f0')

opcode('010011100100----', 'trap_n', 'TRAP #n')
opcode('1010------------', 'exc_line_a', 'an A-line instruction')
opcode('1111------------', 'exc_line_f', 'an F-line instruction')


# ==========================================================================
# RTE -- UM 6.1.12
#
# "When the processor executes an RTE instruction, it examines the stack frame
# on top of the active supervisor stack to determine if it is a valid frame and
# what type of context restoration it requires."
#
#   format $0   restore the SR and the PC, add eight to the stack pointer
#   format $1   restore the SR alone, add eight -- and then START AGAIN, on
#               whatever stack the restored SR now selects
#   format $2   restore the SR and the PC, add twelve
#   anything else   a format error, vector 14
#
# The stack pointer is stepped BEFORE the status register is written, because
# writing the status register is what decides which of the three stack pointers
# A7 means. Doing it the other way round adds eight to the wrong register.
# ==========================================================================
label('rte')
u('RTE is privileged -- PRM 6',
  seq='COND', cond='USER', next='exc_priv')
u('the frame is at the top of the active supervisor stack',
  asrc='SP', alu='A', dst='T1', size='LONG')
u('its format word is at +$06',
  asrc='T1', bsrc='SIX', alu='ADD', dst='T2', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T2', bytes=2)
u('... and hold it, because the branches below read it',
  asrc='RDATA', alu='A', dst='XW', size='WORD')
# The first test gets a microword of its own because the one above WRITES xw,
# and a condition reads the register as it stands, not as it is about to be.
u('a throwaway frame?',
  seq='COND', cond='FMT1', next='rte_throwaway')
u('a six-word frame?',
  seq='COND', cond='FMT2', next='rte_six')
u('a four-word one?',
  seq='COND', cond='FMT0', next='rte_four')
u('a short bus fault frame?',
  seq='COND', cond='FMTA', next='rte_fault_short')
u('a long one?',
  seq='COND', cond='FMTB', next='rte_fault_long')
u('and anything else is a format error -- UM 6.1.8',
  next='exc_format')

label('rte_four')
u('+$00: the status register',
  bus='READ', fc='DATA', asel='T1', bytes=2)
u('... held',
  asrc='RDATA', alu='A', dst='T3', size='WORD')
u('+$02: the program counter',
  asrc='T1', bsrc='TWO', alu='ADD', dst='T2', size='LONG')
u('... read',
  bus='READ', fc='DATA', asel='T2', bytes=4)
u('... and held',
  asrc='RDATA', alu='A', dst='T0', size='LONG')
u('the stack pointer, eight past the frame, while it is still this stack',
  asrc='T1', bsrc='EIGHT', alu='ADD', dst='SP', size='LONG')
u('and now the status register, which may change which stack that was',
  asrc='T3', alu='A', dst='SR', size='WORD')
u('the program counter comes back',
  asrc='T0', alu='A', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')

label('rte_six')
u('+$00: the status register',
  bus='READ', fc='DATA', asel='T1', bytes=2)
u('... held',
  asrc='RDATA', alu='A', dst='T3', size='WORD')
u('+$02: the program counter',
  asrc='T1', bsrc='TWO', alu='ADD', dst='T2', size='LONG')
u('... read',
  bus='READ', fc='DATA', asel='T2', bytes=4)
u('... and held',
  asrc='RDATA', alu='A', dst='T0', size='LONG')
u('a six-word frame is twelve bytes long',
  asrc='T1', bsrc='TWELVE', alu='ADD', dst='SP', size='LONG')
u('and now the status register',
  asrc='T3', alu='A', dst='SR', size='WORD')
u('the program counter comes back',
  asrc='T0', alu='A', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')

# The throwaway frame. UM 6.1.12: read the status register, step the stack,
# write the status register, "and then begins RTE processing again ... on top of
# the active stack, which may or may not be the same stack used for the previous
# operation". The second frame may be any format, including another throwaway.
label('rte_throwaway')
u('+$00: the status register, which is all this frame carries',
  bus='READ', fc='DATA', asel='T1', bytes=2)
u('... held',
  asrc='RDATA', alu='A', dst='T3', size='WORD')
u('step this stack past the frame',
  asrc='T1', bsrc='EIGHT', alu='ADD', dst='SP', size='LONG')
u('write the status register, which chooses the stack the next frame is on',
  asrc='T3', alu='A', dst='SR', size='WORD')
u('and do it all again',
  next='rte')



# ==========================================================================
# RTE out of a bus fault frame -- UM 6.2.3 and doc/ssw.md
#
# "Another method of completing a faulted bus cycle is to allow the processor to
# rerun the bus cycles during execution of the RTE instruction that terminates
# the exception handler. The RTE instruction is always executed. Unless the
# handler routine has corrected the error and cleared the fault (and cleared the
# RB/RC and DF bits of the SSW), the RTE instruction cannot complete the bus
# cycle(s)."
#
# So this routine does three things in order: put the whole machine back, rerun
# what the special status word still asks for, and jump to the micro-address the
# frame carries. The third is a jump and nothing else, because doc/checkpoint.md
# rule 2 made the faulted microword re-executable: it committed nothing, so
# running it again reissues exactly the same request.
#
# The frame is read with `ea_save`, which is the one register in the set that
# RTE does not have to put back -- the slot it lands in at +$3C is the
# exception's own pointer and means nothing afterwards. Everything else is read
# straight into the register it came from, in an order in which each one is dead
# by the time it is written.
#
# The status register comes LAST and the stack pointer is stepped before it, for
# the reason UM 6.1.12 gives the four-word frame: writing the status register is
# what decides which of the three stack pointers A7 means.
# ==========================================================================
def rte_fault(stem, long_frame):
    label(stem)
    u('the frame base, which is where the walk starts',
      asrc='SP', alu='A', dst='EA_SAVE', size='LONG')

    # The order is the frame's own, walking up, with one constraint that is not:
    # the queue DEPTH has to be back before the fill point is written, because
    # the fill point is two beyond stage B only while the queue is two deep. The
    # depth comes out of the special status word at +$0A, which the walk reaches
    # long before +$24, so `PIPE_F` goes in the middle rather than at the end.
    fields = [
        (0x02, 4, 'PC_D'),
        (0x08, 2, 'INT08'),
        (0x0A, 2, 'SSW'),
        (0x0A, 0, 'PIPE_F'),          # no read: the depth, from what was just read
        (0x0C, 2, 'STG_C'),
        (0x0E, 2, 'STG_B'),
        (0x10, 4, 'DFA'),
        (0x14, 2, 'RUPC'),
        (0x16, 2, 'STG_D'),
        (0x18, 4, 'DOB'),
    ]
    if long_frame:
        fields += [
            (0x1C, 4, 'T0'),
            (0x20, 4, 'T1'),
            # Writing this is what says the pipe is whole, and every other pipe
            # field is behind it in the walk.
            (0x24, 4, 'FILL'),
            (0x28, 4, 'T2'),
            (0x2C, 4, 'DIB'),
            (0x30, 4, 'T3'),
            (0x34, 2, 'XW'),
            (0x36, 2, 'INT36'),
            (0x38, 4, 'EA'),
            (0x44, 2, 'LINK'),
            (0x46, 4, 'PC_PREV'),
        ]

    at = 0
    for off, nbytes, dst in fields:
        if nbytes == 0:
            u('the queue depth, which is what the rerun bits say -- UM 6.2.1',
              dst=dst)
            continue
        step = off - at
        if step != 0:
            u('... to +$%02X' % off,
              asrc='EA_SAVE',
              bsrc={2: 'TWO', 4: 'FOUR', 6: 'SIX', 8: 'EIGHT',
                    12: 'TWELVE'}[step],
              alu='ADD', dst='EA_SAVE', size='LONG')
        u('read +$%02X' % off,
          bus='READ', fc='DATA', asel='EA_SAVE', bytes=nbytes)
        u('... into %s' % dst.lower(),
          asrc='RDATA', alu='A', dst=dst, size='LONG' if nbytes == 4 else 'WORD')
        at = off

    if not long_frame:
        # UM 6.2: "when the short bus fault stack frame applies, the address of
        # the pipe stage B word is the value in the PC plus four". The long
        # frame carries that address; the short one is only ever built at an
        # instruction boundary, where the pipe is sequential and the arithmetic
        # is exact, so it is derived rather than read -- and writing it is what
        # says the pipe is whole.
        u('stage B is at the program counter plus four -- UM 6.2',
          asrc='PC_D', bsrc='FOUR', alu='ADD', dst='FILL', size='LONG')

    u('+$00: the status register, read while the stack pointer is still the base',
      bus='READ', fc='DATA', asel='SP', bytes=2)
    u('the stack pointer, past the frame, while it is still this stack',
      asrc='SP', bsrc='FRAME_B_BYTES' if long_frame else 'FRAME_A_BYTES',
      alu='ADD', dst='SP', size='LONG')
    u('and now the status register, which may change which stack that was',
      asrc='RDATA', alu='A', dst='SR', size='WORD')
    # UM 6.2.3: "if the DF bit is still set at the time of the RTE execution, the
    # faulted data cycle is rerun by the RTE instruction"; UM 6.2.2: with it
    # cleared, "the data has been correctly written to memory for a write". Both
    # hand the operand back to the bus unit -- doc/checkpoint.md rule 3, the unit
    # of restart is the operand -- and DF decides how much of it is left, which
    # is a wire and not a branch.
    #
    # It is handed back either way rather than skipped, because the microword
    # that faulted is re-executed and everything else it does has to happen
    # exactly once. Satisfying its request out of the frame is what lets it run
    # again without running the access again.
    u('hand the faulted access back -- the residual, or nothing at all',
      rstop=1, seq='RESUME')


rte_fault('rte_fault_short', False)
rte_fault('rte_fault_long', True)

exc_here('exc_format', 14, executed=True)

# ==========================================================================
# THE SUPERVISOR INSTRUCTIONS -- PRM 6
#
# Every one of them begins the same way, and it is the only thing that makes
# the privilege violation of UM 6.1.6 happen at all: "if a user program attempts
# to execute a privileged instruction, a privilege violation exception occurs".
# The frame carries the address of the instruction that tried -- table 6-5,
# "first word of instruction causing privilege violation" -- which is what
# exc_here stacks.
# ==========================================================================
# The check goes in the PROLOGUE, not in front of it. The opcode patterns point
# straight at mtsr_dn, mtsr_immw and mtsr_mem, so a microword before those
# labels is not on any path -- which is what it was, and the sweep found MOVE
# #imm,SR running happily in user mode.
def _privileged():
    u('privileged -- UM 6.1.6',
      seq='COND', cond='USER', next='exc_priv')


src_prologues('mtsr', 'FIXED', an_ok=False, size='WORD', prelude=_privileged)
u('the whole status register, not just the codes',
  asrc='T0', alu='A', dst='SR', size='WORD', pf='ADV', seq='DECODE')

label('move_from_sr_dn')
u('MOVE from SR is privileged on this part -- it was not on the MC68000, '
  'which is why MOVE from CCR exists',
  seq='COND', cond='USER', next='exc_priv')
u('the status register, as a word',
  asrc='SR', alu='A', dst='DREG_R', size='WORD', pf='ADV', seq='DECODE')

label('move_from_sr_mem')
u('likewise privileged',
  seq='COND', cond='USER', next='exc_priv')
u('the address',
  call=1, seq='EAMODE', size='WORD')
u('and the status register goes there',
  bus='WRITE', fc='DATA', asel='EA', asrc='SR', alu='A', bytes=2,
  pf='ADV', seq='DECODE')

for _stem, _alu, _bits in (('andi_sr', 'AND', '0010'),
                           ('ori_sr',  'OR',  '0000'),
                           ('eori_sr', 'EOR', '1010')):
    label(_stem)
    u('privileged, because the whole status register is the operand',
      seq='COND', cond='USER', next='exc_priv')
    u('the word of immediate that follows',
      asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
    u('... against the status register',
      asrc='SR', bsrc='T0', alu=_alu, dst='SR', size='WORD',
      pf='ADV', seq='DECODE')

# MOVE USP. PRM 6: the ONLY way to reach the user stack pointer while running
# at the supervisor level, which is what a kernel needs to build a user frame.
label('move_usp_to')
u('privileged',
  seq='COND', cond='USER', next='exc_priv')
u('the address register into the user stack pointer',
  asrc='AREG', alu='A', dst='USP', size='LONG', pf='ADV', seq='DECODE')

label('move_usp_from')
u('privileged',
  seq='COND', cond='USER', next='exc_priv')
u('the user stack pointer into the address register',
  asrc='USP', alu='A', dst='AREG_EA', size='LONG', pf='ADV', seq='DECODE')

# ==========================================================================
# RESET and STOP -- PRM 6
# ==========================================================================
label('reset_insn')
u('privileged -- UM 6.1.6',
  seq='COND', cond='USER', next='exc_priv')
u('assert RESET for 512 clock periods. PRM 6: "the processor state, other than '
  'the program counter, is unaffected"',
  rsto=1, pf='ADV', seq='DECODE')

# PRM 6 STOP: "moves the immediate operand into the status register (both user
# and supervisor portions), advances the program counter to point to the next
# instruction, and stops the fetching and executing of instructions".
#
# The status register is written by a microword of its own, one BEFORE the one
# that decodes, and that ordering is the whole of the instruction's subtlety:
# "if an interrupt request is asserted with a priority higher than the priority
# level set by the NEW status register value, an interrupt exception occurs;
# otherwise, the interrupt request is ignored". The decode arm compares the
# level against the status register as it then stands, so the write has to have
# retired by the time it looks.
#
# The trace falls out of the same arrangement: the write to SR is a change of
# flow, so T1T0 = 01 traces the STOP, and T1T0 = 10 traces it because it traces
# everything -- PRM 6, "a trace exception occurs if instruction tracing is
# enabled when the STOP instruction begins execution". Both are decided at that
# decode, ahead of the stop bit.
label('stop_insn')
u('privileged -- UM 6.1.6',
  seq='COND', cond='USER', next='exc_priv')
u('the word of immediate that follows',
  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
u('the whole status register, user half and supervisor half',
  asrc='T0', alu='A', dst='SR', size='WORD')
u('... and now stop',
  stop=1, pf='ADV', seq='DECODE')

opcode('0100111001110000', 'reset_insn',     'RESET')
opcode('0100111001110010', 'stop_insn',      'STOP #imm')
opcode('0100111001110011', 'rte',             'RTE')
opcode('0100011011000---', 'mtsr_dn',         'MOVE Dn,SR')
opcode('0100011011111100', 'mtsr_immw',       'MOVE #imm,SR')
opcode('0100011011------', 'mtsr_mem',        'MOVE <ea>,SR')
opcode('0100000011000---', 'move_from_sr_dn', 'MOVE SR,Dn')
opcode('0100000011------', 'move_from_sr_mem','MOVE SR,<ea>')
opcode('0100111001100---', 'move_usp_to',     'MOVE An,USP')
opcode('0100111001101---', 'move_usp_from',   'MOVE USP,An')


# ==========================================================================
# TRAPV and TRAPcc -- PRM 4
#
# TRAPV traps if V is set and does nothing otherwise. TRAPcc is the MC68020's
# generalisation of it: any of the sixteen conditions, and an optional operand
# word or long word that the instruction does not look at -- PRM 4, "the
# immediate data is placed in the instruction stream for use by the trap
# handler", which means this microcode's only business with it is to eat it.
#
# Both take vector 7 and a six-word frame, with the address of the instruction
# that trapped at +$08 -- UM table 6-5.
# ==========================================================================
# TRAPV tests V, and its own condition field -- bits 11:8 of $4E76 -- reads as
# NE. So it cannot borrow the sequencer's cc evaluation and tests the flag.
label('trapv')
u('V set?',
  seq='COND', cond='VSET', next='trapv_taken')
u('no, and TRAPV does nothing at all',
  pf='ADV', seq='DECODE')
label('trapv_taken')
u('yes -- vector 7',
  next='exc_trapcc')

def trapcc(stem, words):
    label(stem)
    for i in range(words):
        u('the operand word the handler may want, which this does not read',
          pf='CONSUME')
    u('the condition',
      seq='COND', cond='CC', next='exc_trapcc')
    u('not taken, and nothing happens',
      pf='ADV', seq='DECODE')


trapcc('trapcc_n', 0)
trapcc('trapcc_w', 1)
trapcc('trapcc_l', 2)

opcode('0100111001110110', 'trapv', 'TRAPV')


# ==========================================================================
# The trace exception -- UM 6.1.7
#
# The sequencer puts this in front of the decode arm when the instruction that
# has just finished was traced, so it is entered at exactly the point the
# manual names: "at the end of normal processing for the traced instruction and
# before the start of the next instruction".
#
# By then the pipe has advanced, so pc_d is already the NEXT instruction --
# which is what the frame carries -- and the traced instruction's own address
# is in pc_prev.
# ==========================================================================
label('exc_trace')
u('vector 9',
  asrc='VECOFF', alu='A', dst='T0', size='LONG', vec=9)
u('the instruction that was traced',
  asrc='PC_PREV', alu='A', dst='T2', size='LONG')
u('and the frame carries the address of the next one',
  asrc='PC_D', alu='A', dst='T1', size='LONG', next='exc_f2')


# ==========================================================================
# The interrupt exception -- UM 6.1.9
#
# The sequencer dispatches here at an instruction boundary when a request is
# pending and no trace is, and it has latched the level. What is left is the
# manual's four steps with one addition: the vector number is not internal.
#
#   "For interrupts, the processor performs an interrupt acknowledge cycle (a
#    read from the CPU address space type 1111) to obtain the vector number."
#
# Three things can come back:
#
#   DSACK   the device supplied a vector number
#   AVEC    it wants the autovector for its level, 24 + level
#   BERR    nobody answered: a spurious interrupt, vector 24
#
# The mask is raised to the level BEFORE anything else, which is UM 6.1's "for
# the reset and interrupt exceptions, the processor also updates the interrupt
# priority mask" and what stops the same request being taken again the moment
# the handler's first instruction ends.
# ==========================================================================
label('exc_irq')
# UM 6.1 step one is "an internal copy is made of the status register", and only
# then "for the reset and interrupt exceptions, the processor also updates the
# interrupt priority mask". The order is visible in the frame: what is stacked is
# the mask the interrupted program was running under, not the one this interrupt
# raised it to. Letting the shared frame builder make the copy would stack the
# raised mask, and a handler that restored it would come back with interrupts it
# never asked to block still blocked.
u('a copy of the status register as it was, before anything moves',
  asrc='SR', alu='A', dst='T3', size='WORD')
u('the mask goes up to this level -- UM 6.1 step one, second half',
  asrc='SR', bsrc='IRQLEVEL', alu='SETMASK', dst='SR', size='WORD')
u('the acknowledge cycle: CPU space, type $F, the level on A3-A1',
  bus='READ', fc='CPU', bytes=1, cpuspace='IACK',
  seq='COND', cond='AVEC', next='exc_irq_auto')
u('... or nobody answered at all',
  seq='COND', cond='BERR', next='exc_irq_spurious')
u('the device supplied a vector number',
  asrc='IRQVEC', alu='A', dst='T0', size='LONG', next='exc_irq_go')

label('exc_irq_auto')
u('the autovector for this level -- UM table 6-1, vectors 25 to 31',
  asrc='AUTOVEC', alu='A', dst='T0', size='LONG', next='exc_irq_go')

label('exc_irq_spurious')
u('a spurious interrupt -- vector 24',
  asrc='VECOFF', alu='A', dst='T0', size='LONG', vec=24)

label('exc_irq_go')
u('the frame carries the address of the next instruction -- UM table 6-5',
  asrc='PC_D', alu='A', dst='T1', size='LONG',
  seq='COND', cond='MASTER', next='exc_irq_master')
u('supervisor, and no tracing of the handler -- UM 6.1 step one again; the '
  'copy the frame carries was taken above',
  asrc='SR', alu='EXCSR', dst='SR', size='WORD', next='exc_f0_stack')

# --------------------------------------------------------------------------
# The throwaway frame -- UM 6.1.9
#
#   "If the M-bit in the SR is set, the processor clears the M-bit and creates
#    a throwaway exception stack frame on top of the interrupt stack as part of
#    interrupt exception processing. This second frame contains the same PC
#    value and vector offset as the frame created on top of the master stack,
#    but has a format number of 1 instead of 0 or 9. The copy of the SR saved
#    on the throwaway frame is exactly the same as that placed on the master
#    stack except that the S-bit is set in the version placed on the interrupt
#    stack."
#
# So: the ordinary frame goes on the MASTER stack, because M is still set and
# that is what `SP` means; then M is cleared, which is what MOVES the meaning of
# `SP` to the interrupt stack; then the same PC and the same vector offset go
# there again under format $1. Nothing else about the two frames differs, which
# is why T1, T0 and T3 are still the right sources the second time round.
#
# The point of all this is that a task switch can throw the master frame away:
# the handler runs on the interrupt stack and its RTE reads format $1, steps
# past it and starts again on whatever the master stack holds -- which is what
# `rte_throwaway` does at the other end.
# --------------------------------------------------------------------------
label('exc_irq_master')
u('supervisor, and no tracing of the handler -- UM 6.1 step one',
  asrc='SR', alu='EXCSR', dst='SR', size='WORD')
u('the master stack: M is still set, so this is MSP',
  asrc='SP', alu='A', dst='EA', size='LONG')
frame_body('F0', False)
u('and the master stack pointer is where that frame begins',
  asrc='EA', alu='A', dst='SP', size='LONG')
u('now clear M, which moves the stack from MSP to ISP',
  asrc='SR', alu='CLRM', dst='SR', size='WORD')
u('the saved status register again, with S set this time',
  asrc='T3', alu='SETS', dst='T3', size='WORD')
u('the interrupt stack',
  asrc='SP', alu='A', dst='EA', size='LONG')
frame_body('F1', False)
u('and the interrupt stack pointer is where the throwaway begins',
  asrc='EA', alu='A', dst='SP', size='LONG', next='exc_f0_vector')


# ==========================================================================
# BUS FAULT -- UM 6.1.2, 6.2 and doc/ssw.md
#
# The sequencer comes here on the clock the bus unit reports a faulted operand,
# and it comes here INSTEAD of retiring the microword that asked for it:
# doc/checkpoint.md rule 2, a faulted microword ends but commits nothing. So the
# machine state this routine writes out is the state at the start of the faulted
# access, and resuming at the micro-address in the frame re-executes that same
# microword and reissues that same request.
#
# The frame is the long one, format $B, because a data fault is by definition
# taken during the execution of an instruction -- UM 6.1.2, "when the exception
# is taken during the execution of an instruction, the processor must save its
# entire state for recovery and uses the long bus fault stack frame".
#
# Three things about the ORDER, none of them free choices:
#
#   - it is built from the BOTTOM UP, not top down like the other frames. The
#     status register at +$00 has to be written before the S bit is set, and its
#     address is not known until the frame base has been computed, so the base
#     comes first and the walk goes up from it. UM 6.4 allows either: "the
#     processor does not necessarily read or write the stack frame data in
#     sequential order".
#   - the pointer is `ea_save` and not `ea`, because `ea` is the address buffer
#     of the instruction that faulted and is frame field +$38.
#   - the vector offset comes out of the microword (FMTVECI) and not out of T0,
#     because T0 is the instruction's and is not written out until +$1C.
#
# What is NOT here: any microword that could itself fault without being a double
# bus fault. UM 6.1.2 -- "if a bus error occurs during the exception processing
# for a bus error, address error, or reset ... the processor enters the halted
# state" -- and `g0_q`, set by the same edge that came here, is that window.
# ==========================================================================
def fault_frame(stem, long_frame):
    """A format $A or $B frame, built upward from its base.

    One routine for both group-0 vectors. UM 6.1.3 makes the address error
    "similar to a bus error exception but internally initiated", differing only
    in the vector number, so the two share everything and the vector comes out of
    a latch -- FLTVEC and FLTFMT -- rather than out of the microword.
    """
    label(stem)
    u('the frame base: the active supervisor stack, less the frame',
      asrc='EA_SAVE',
      bsrc='FRAME_B_BYTES' if long_frame else 'FRAME_A_BYTES',
      alu='SUB', dst='EA_SAVE', size='LONG')
    u('+$00: the status register, written BEFORE anything sets S',
      bus='WRITE', fc='DATA', asel='EA_SAVE', asrc='SR', alu='A', bytes=2)
    u('supervisor, and no tracing of the handler -- UM 6.1 step one',
      asrc='SR', alu='EXCSR', dst='SR', size='WORD')
    u('and the stack pointer is the frame base, which is now a supervisor one',
      asrc='EA_SAVE', alu='A', dst='SP', size='LONG')

    # (offset, bytes, source) in ascending order. The offsets are UM table 6-5
    # for the named fields and doc/checkpoint.md for the rest; `check_frames`
    # proves the set against frames.py.
    fields = [
        (0x02, 4, 'PC_D'),        # the instruction that was executing
        (0x06, 2, 'FLTFMT'),
        (0x08, 2, 'INT08'),
        (0x0A, 2, 'SSW'),
        (0x0C, 2, 'STG_C_RAW'),
        (0x0E, 2, 'STG_B'),
        (0x10, 4, 'DFA'),
        (0x14, 2, 'UPC'),
        (0x16, 2, 'STG_D'),
        (0x18, 4, 'DOB'),
    ]
    if long_frame:
        fields += [
            (0x1C, 4, 'T0'),
            (0x20, 4, 'T1'),
            (0x24, 4, 'STG_B_ADDR'),
            (0x28, 4, 'T2'),
            (0x2C, 4, 'DIB'),
            (0x30, 4, 'T3'),
            (0x34, 2, 'XW'),
            (0x36, 2, 'INT36'),
            (0x38, 4, 'EA'),
            (0x3C, 4, 'EA_SAVE'),
            (0x40, 4, 'PC_FETCH'),
            (0x44, 2, 'LINK'),
            (0x46, 4, 'PC_PREV'),
        ]
        # UM table 6-5 makes the frame forty-six words whatever is in them. The
        # words this design has no use for are written as zero rather than left
        # as whatever the handler's stack held: a frame is copied and restored
        # by a task switch, and one that carries the previous owner's stack is
        # a leak with no upside.
        fields += [(off, 4, 'ZERO') for off in range(0x4A, 0x5A, 4)]
        fields += [(0x5A, 2, 'ZERO')]
    else:
        # UM table 6-5 makes the short frame sixteen words. Its last two are
        # internal and this design has nothing to put in them: a format $A frame
        # is taken at an instruction boundary, where every register the long
        # frame's +$36 carries is either about to be set by the decode that
        # resumes or is already clear.
        fields += [(0x1C, 4, 'ZERO')]

    at = 0
    for off, nbytes, src in fields:
        step = off - at
        assert step in (1, 2, 4, 6), 'frame step of %d at +$%02X' % (step, off)
        u('... to +$%02X' % off,
          asrc='EA_SAVE', bsrc={2: 'TWO', 4: 'FOUR', 6: 'SIX'}[step],
          alu='ADD', dst='EA_SAVE', size='LONG')
        u('+$%02X: %s' % (off, src.lower()),
          bus='WRITE', fc='DATA', asel='EA_SAVE', asrc=src, alu='A',
          bytes=nbytes,
          **({'frame': 'FB' if long_frame else 'FA'}
             if src == 'FLTFMT' else {}))
        at = off

    u('the vector offset, now that T0 has been written out',
      asrc='FLTVEC', alu='A', dst='T0', size='LONG',
      next='exc_f0_vector')


# UM table 6-5: the short frame when the exception was taken at an instruction
# boundary, the long one when it was taken during an instruction. Which of them
# a fault reaches is decided by the sequencer, and `check_boundary` in the
# assembler is what keeps that decision the same question as the manual's.
fault_frame('exc_fault_long', True)
fault_frame('exc_fault_short', False)
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