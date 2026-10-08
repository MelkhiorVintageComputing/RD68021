#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68021

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
CPPATTERNS = []     # [(pattern, target, what)] -- coprocessor response primitives


def label(name):
    if name in LABELS:
        raise SystemExit('program: duplicate label %r' % name)
    LABELS[name] = len(WORDS)


def u(comment='', **fields):
    for k in fields:
        if k not in isa.FIELDS:
            raise SystemExit('program: microword %d has no field %r -- the field '
                             'list is in isa.py' % (len(WORDS), k))
    # The end of a coprocessor primitive -- doc/coprocessor.md. A primitive's
    # last microword asks the one question cp_next used to ask in two: come
    # again (CA set, or a trace pending -- UM 7.5.2.5)? Yes goes straight back
    # to the response CIR; no falls into a release of its own, so the dialogue
    # ends a clock after the primitive's last access rather than three.
    if fields.get('next') == 'cp_next' and fields.get('seq', 'NEXT') == 'NEXT':
        fields = dict(fields, seq='COND', cond='CPAGAIN', next='cp_resp')
        WORDS.append((fields, comment))
        WORDS.append(({'pf': 'ADV', 'seq': 'DECODE'},
                      'released: the scanPC is the next instruction -- UM 7.4.1'))
        return
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


def cpprim(pattern, target, what, ea='-----'):
    """A response primitive pattern, for the seq = CPDEC arm.

    Seventeen characters: the category bit (1 for a conditional instruction),
    then bits 15 down to 0 of the primitive -- UM figure 7-22. And five more
    about the instruction's effective address, `ea`: in the class the
    primitive names (UM table 7-4), suitable for a transfer of multiple
    coprocessor registers (UM 7.4.16), and three for which kind it is -- 000
    Dn, 001 An, 010 #imm, 011 (An)+, 100 -(An), 101 the other memory modes.
    """
    pattern = pattern + ea
    if len(pattern) != 22 or any(c not in '01-' for c in pattern):
        raise SystemExit('program: %r is not seventeen and five of 0, 1 and -'
                         % pattern)
    CPPATTERNS.append((pattern, target, what))


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
# PRM 4: "the processor's pipeline is synchronized prior to the NOP instruction
# being executed", so that a write before it has reached the bus -- UM 8.1.4
# relies on it to clear an interrupt before lowering the mask.
u('nothing but the pipe, once the bus has caught up',
  pf='ADV', seq='DECODE', sync=1)

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
# Each routine leaves the address in EA and returns. Its scratch is T2, T3 and
# XW, and nothing else: an instruction may hold T0 and T1 across the call, and
# must restore XW itself if it needs it after -- the indexed modes decode their
# extension word there. assemble.py's check_ea_live holds every caller to that.
# It used to be T0 and T1, while the callers held their operands in T0, so every
# memory destination that needed an absolute long or an indexed address wrote
# the wrong thing (doc/bugs-found.md). `call` latches the address
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
u('... which for A7 and a byte is two, so the stack stays even. The register '
  'takes an ADDRESS, so it is written whole and not sign extended at the '
  'operand size',
  asrc='AREG', bsrc='OPSIZE', alu='ADD', dst='AREG_EA_ADDR', szsel='LATCHED',
  seq='RET')

label('ea_an_pre')                       # -(An)
u('the address register stepped back first, likewise whole',
  asrc='AREG', bsrc='OPSIZE', alu='SUB', dst='AREG_EA_ADDR', szsel='LATCHED')
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
  asrc='STG_C_HI', alu='A', dst='T2', pf='CONSUME')
u('... and the low half',
  asrc='T2', bsrc='STG_C_U', alu='OR', dst='EA', pf='CONSUME', seq='RET')

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
  asrc='AREG', bsrc='INDEX', alu='ADD', dst='T2', pf='CONSUME')
u('... plus the displacement byte',
  asrc='T2', bsrc='XWDISP8', alu='ADD', dst='EA', seq='RET')

label('eab_pc')
u('the extension word address plus the scaled index',
  asrc='PC_C', bsrc='INDEX', alu='ADD', dst='T2', pf='CONSUME')
u('... plus the displacement byte',
  asrc='T2', bsrc='XWDISP8', alu='ADD', dst='EA', seq='RET')

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
    """Leave a base or outer displacement of the given size in T3."""
    if kind == 'null':
        u('no displacement', asrc='ZERO', alu='A', dst='T3')
    elif kind == 'word':
        u('a word displacement, sign extended',
          bsrc='STG_C_S', alu='B', dst='T3', pf='CONSUME')
    else:
        u('the high half of a long displacement',
          asrc='STG_C_HI', alu='A', dst='T3', pf='CONSUME')
        u('... and the low half',
          asrc='T3', bsrc='STG_C_U', alu='OR', dst='T3', pf='CONSUME')


def _ea_full(bd, action, od):
    """One full-extension-word routine."""
    name = 'eaf_%s_%s_%s' % (bd[0], action, od[0] if od else 'x')
    label(name)
    # The base, and the index if it goes on before the indirection. The
    # extension word is consumed here, after EABASE has been read from it --
    # PC_C names the extension word only until it is gone.
    if action == 'post':
        u('the base register, or the extension word address',
          asrc='EABASE', alu='A', dst='T2', pf='CONSUME')
    else:
        u('the base plus the scaled index',
          asrc='EABASE', bsrc='INDEX', alu='ADD', dst='T2', pf='CONSUME')
    _disp_into_t1(bd[1])
    u('... plus the base displacement', asrc='T2', bsrc='T3', alu='ADD', dst='T2')
    if action != 'none':
        u('the long word that address names',
          bus='READ', fc='EASP', asel='T2', bytes=4)
        u('... is the address to go on with',
          asrc='RDATA', alu='A', dst='T2')
        if action == 'post':
            u('... plus the scaled index', asrc='T2', bsrc='INDEX', alu='ADD',
              dst='T2')
        _disp_into_t1(od[1])
        u('... plus the outer displacement',
          asrc='T2', bsrc='T3', alu='ADD', dst='T2')
    u('and that is the effective address',
      asrc='T2', alu='A', dst='EA', seq='RET')
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

# ==========================================================================
# The fast effective-address paths
#
# (An), (An)+, -(An) and (d16,An) are most of the memory operands compiled code
# names, and the general path spends an EAMODE dispatch and a routine on each
# before the bus cycle can start. For the common instruction families the opcode
# decoder picks the mode instead -- a pattern per mode -- and the bus microword
# addresses through the register itself: asel = AREG, or AREG_PRE for -(An),
# which is the register less the operand size.
#
# A read steps (An)+ and -(An) on its own microword, as its `dst`: the step is
# committed only if the read completes, so a faulted read leaves the register
# as it was and RTE re-runs the microword whole. A write cannot, because its
# data is the ALU output, so the step is a microword after it.
#
# None of these touches the EA buffer, so an instruction whose tail reads EA
# cannot have them. assemble.py's check_ea_set holds every opcode entry to that.
#
# `eadst` is MOVE's destination: the register in bits 11:9, which the
# microword's own eadst bit selects -- rd68021_seq's rsel.
# ==========================================================================
FAST_MODES = (('ai', '010'), ('pi', '011'), ('pd', '100'), ('di', '101'))


def fast_read(mode, eadst=0, **sz):
    """Read the operand the mode names. It is in RDATA for the next microword,
    which must not use the pipe -- check_rdata_restart."""
    if mode == 'ai':
        u('read through the address register',
          bus='READ', fc='DATA', asel='AREG', eadst=eadst, **sz)
    elif mode == 'pi':
        u('read through the address register, and step it on by the operand '
          'size -- committed only if the read completes. The register takes an '
          'ADDRESS, so it is written whole',
          bus='READ', fc='DATA', asel='AREG', asrc='AREG', bsrc='OPSIZE',
          alu='ADD', dst='AREG_EA_ADDR', eadst=eadst, **sz)
    elif mode == 'pd':
        u('read through the address register less the operand size, which is '
          'what it becomes if the read completes',
          bus='READ', fc='DATA', asel='AREG_PRE', asrc='AREG', bsrc='OPSIZE',
          alu='SUB', dst='AREG_EA_ADDR', eadst=eadst, **sz)
    else:
        u('the address register plus the word that follows',
          asrc='AREG', bsrc='STG_C_S', alu='ADD', dst='EA', pf='CONSUME',
          eadst=eadst, **sz)
        u('read what it names',
          bus='READ', fc='DATA', asel='EA', eadst=eadst, **sz)


def fast_write(mode, src, eadst=0, ccr='NONE', stepped=False, **sz):
    """Write `src` where the mode names, and end the instruction.

    `stepped` says a fast_read has already stepped (An)+ or -(An): the write
    goes back where the read was, and the register is left alone."""
    last = dict(pf='ADV', seq='DECODE')
    if mode == 'di':
        if not stepped:
            u('the address register plus the word that follows',
              asrc='AREG', bsrc='STG_C_S', alu='ADD', dst='EA', pf='CONSUME',
              eadst=eadst, **sz)
        u('the write',
          bus='WRITE', fc='DATA', asel='EA', asrc=src, alu='A', ccr=ccr,
          eadst=eadst, **last, **sz)
        return
    if stepped:
        u('the write, back where the read was',
          bus='WRITE', fc='DATA', asel=('AREG_PRE' if mode == 'pi' else 'AREG'),
          asrc=src, alu='A', ccr=ccr, eadst=eadst, **last, **sz)
        return
    asel = 'AREG_PRE' if mode == 'pd' else 'AREG'
    if mode == 'ai':
        u('the write, through the address register',
          bus='WRITE', fc='DATA', asel=asel, asrc=src, alu='A', ccr=ccr,
          eadst=eadst, **last, **sz)
        return
    u('the write, through the address register' +
      (' less the operand size' if mode == 'pd' else ''),
      bus='WRITE', fc='DATA', asel=asel, asrc=src, alu='A', ccr=ccr,
      eadst=eadst, **sz)
    u('... and the register stepped, now that the write has completed. It '
      'takes an ADDRESS, so it is written whole',
      asrc='AREG', bsrc='OPSIZE', alu=('ADD' if mode == 'pi' else 'SUB'),
      dst='AREG_EA_ADDR', eadst=eadst, **last, **sz)


def fast_rmw(stem, op, szsel, write=True):
    """A read-modify-write <ea> through each fast mode: `op` emits the
    microword that takes RDATA into T1 (and the codes), with no pipe use."""
    for mode, _bits in FAST_MODES:
        label(stem + '_' + mode)
        fast_read(mode, szsel=szsel)
        op()
        if write:
            fast_write(mode, 'T1', stepped=True, szsel=szsel)
        else:
            u('nothing is written back', pf='ADV', seq='DECODE')


def src_prologues(stem, szsel, an_ok=True, imm_ok=True, size='LONG',
                  prelude=None, before_ea=None, after_ea=None, fast=False):
    """Leave the <ea> source operand in T0, then fall into `stem`_go.

    `size` matters only when szsel is FIXED -- the instructions whose operand
    size is not a field of the opcode at all, like MOVE to CCR.

    `prelude` is emitted at the head of every entry point, for the instructions
    with an extension word of their own BEFORE the effective address's: the long
    forms of MULU, MULS, DIVU and DIVS put their register numbers and their
    signedness there, and it has to be latched before stage C moves on.
    `before_ea` and `after_ea` are emitted around the effective-address call on
    the memory path, for an instruction that needs something back the call may
    have used.
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

    if fast:
        assert prelude is None and before_ea is None and after_ea is None
        for mode, _bits in FAST_MODES:
            label(stem + '_' + mode)
            fast_read(mode, szsel=szsel, size=size)
            u('... into the working register',
              asrc='RDATA', alu='A', dst='T0', szsel=szsel, size=size)
            goto(stem + '_go')

    label(stem + '_mem')
    pre()
    if before_ea is not None:
        before_ea()
    u('... or memory, whose address the mode decoder knows how to build',
      call=1, seq='EAMODE', szsel=szsel, size=size)
    if after_ea is not None:
        after_ea()
    u('read the operand it names',
      bus='READ', fc='EASP', asel='EA', szsel=szsel, size=size)
    u('... into the working register',
      asrc='RDATA', alu='A', dst='T0', szsel=szsel, size=size)
    label(stem + '_go')


def fast_patterns(pats, stem, mnem):
    """The fast-path modes' patterns, which must come before the <ea> one."""
    for mode, bits in FAST_MODES:
        opcode(pats.replace('##', bits + '---'), stem + '_' + mode,
               '%s (%s)' % (mnem, mode))


def src_patterns(pats, stem, mnem, an_ok=True, imm=None, mem=True, fast=False):
    """The opcode patterns that reach one set of prologues.

    `pats` is a template with `##` where the six mode and register bits go.
    `imm` is None, 'W' or 'L': how many words an immediate source occupies at
    this instruction's size, which the pattern has already fixed.
    """
    if fast:
        fast_patterns(pats, stem, mnem + ' <ea>')
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
    src_prologues(stem, 'MOVE', fast=True)
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
# ... and the fast destinations, where the write itself sets the codes: a write
# that faults commits nothing, codes included, and RTE runs it again whole.
for _mode, _bits in FAST_MODES:
    move_family('move_' + _mode,
                lambda m=_mode: fast_write(m, 'T0', eadst=1, ccr='LOGIC',
                                           szsel='MOVE'))

# The patterns. `ss` is 01 byte, 11 word, 10 long, and a byte operation may not
# name an address register at either end -- PRM 4.
for _ss, _szname, _immwords, _an in (('01', 'B', 'W', False),
                                     ('11', 'W', 'W', True),
                                     ('10', 'L', 'L', True)):
    # A data register destination.
    src_patterns('00' + _ss + '---000##', 'move_dn',
                 'MOVE.%s <ea>,Dn <-' % _szname, an_ok=_an, imm=_immwords,
                 fast=True)
    # An address register destination is MOVEA, and only at word and long.
    if _an:
        src_patterns('00' + _ss + '---001##', 'move_an',
                     'MOVEA.%s <ea>,An <-' % _szname, an_ok=True, imm=_immwords,
                     fast=True)
    # The fast destinations.
    for _mode, _bits in FAST_MODES:
        src_patterns('00' + _ss + '---' + _bits + '##', 'move_' + _mode,
                     'MOVE.%s <ea>,(%s) <-' % (_szname, _mode), an_ok=_an,
                     imm=_immwords, fast=True)
    # Everything else. This pattern is written last so that the ones above win.
    src_patterns('00' + _ss + '------##', 'move_mem',
                 'MOVE.%s <ea>,<ea> <-' % _szname, an_ok=_an, imm=_immwords,
                 fast=True)


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


# TST and CLR, the two compiled code names memory with most, have the fast
# paths too. CLR reads nothing, so its write sets the codes itself.
fast_rmw('tst', lambda: u('the operand itself, for its condition codes alone',
                          asrc='RDATA', alu='A', ccr='LOGIC', szsel='IR76'),
         'IR76', write=False)
for _mode, _bits in FAST_MODES:
    label('clr_' + _mode)
    fast_write(_mode, 'ZERO', ccr='LOGIC', szsel='IR76')

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

# TST on the MC68020 also takes an address register, at word and long size, and
# an immediate -- PRM 4, "MC68020, MC68030, MC68040 and CPU32" -- neither of
# which the MC68000 or MC68010 allowed and neither of which reaches memory, so
# neither can go through the mode decoder. These patterns come first: the
# generic <ea> ones below cover both encodings and send them to a memory path
# with no routine for them, which is an illegal instruction. Found by the
# Sun-3/160 PROM, which says TST.L A2 (doc/bugs-found.md).
label('tst_an')
u('the address register, for its condition codes alone -- at word size its '
  'low word',
  asrc='AREG', alu='A', ccr='LOGIC', szsel='IR76', pf='ADV', seq='DECODE')
label('tst_immw')
u('one word of the instruction stream, for its condition codes alone',
  asrc='STG_C', alu='A', ccr='LOGIC', szsel='IR76', pf='CONSUME')
u('... and on', pf='ADV', seq='DECODE')
label('tst_imml')
u('two words, the first being the high half',
  asrc='STG_C_HI', alu='A', dst='T0', pf='CONSUME')
u('... and the second the low, for the condition codes alone',
  asrc='T0', bsrc='STG_C_U', alu='OR', ccr='LOGIC', size='LONG', pf='CONSUME')
u('... and on', pf='ADV', seq='DECODE')
opcode('0100101001001---', 'tst_an',   'TST.W An')
opcode('0100101010001---', 'tst_an',   'TST.L An')
opcode('0100101000111100', 'tst_immw', 'TST.B #<data>')
opcode('0100101001111100', 'tst_immw', 'TST.W #<data>')
opcode('0100101010111100', 'tst_imml', 'TST.L #<data>')

for _op, _stem, _mnem in (('0100001000', 'clr',  'CLR'),
                          ('0100010000', 'neg',  'NEG'),
                          ('0100000000', 'negx', 'NEGX'),
                          ('0100011000', 'not',  'NOT'),
                          ('0100101000', 'tst',  'TST')):
    for _sz, _n in (('00', 'B'), ('01', 'W'), ('10', 'L')):
        _pat = _op[:8] + _sz + '##'
        opcode(_pat.replace('##', '000---'), _stem + '_dn',
               '%s.%s Dn' % (_mnem, _n))
        if _stem in ('tst', 'clr'):
            fast_patterns(_pat, _stem, '%s.%s <ea>' % (_mnem, _n))
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
    # PRM 4: "SP - 4 -> SP; An -> (SP); SP -> An; SP + d -> SP". The stack
    # pointer is stepped first and the push goes through it, so LINK A7 pushes
    # the decremented stack pointer, as the operation says.
    u('the stack pointer, four lower',
      asrc='SP', bsrc='FOUR', alu='SUB', dst='SP', size='LONG')
    u('push the address register',
      bus='WRITE', fc='DATA', asel='SP', asrc='AREG', alu='A', bytes=4)
    u('the frame pointer is the new stack pointer',
      asrc='SP', alu='A', dst='AREG_EA', size='LONG')
    if long_disp:
        u('the high half of the displacement',
          asrc='STG_C_HI', alu='A', dst='T0', pf='CONSUME')
        u('... and the low',
          asrc='T0', bsrc='STG_C_U', alu='OR', dst='T0', pf='CONSUME')
        u('and the displacement, which is signed and usually negative, makes '
          'room on the stack',
          asrc='SP', bsrc='T0', alu='ADD', dst='SP', size='LONG')
    else:
        u('the displacement, sign extended, makes room on the stack',
          asrc='SP', bsrc='STG_C_S', alu='ADD', dst='SP', size='LONG',
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

# ==========================================================================
# BKPT -- PRM 4 and UM 5.4.2
#
# "The breakpoint acknowledge cycle allows the external hardware to provide an
# instruction word directly into the instruction pipeline as the program
# executes. ... If the external hardware terminates the cycle with DSACK1/DSACK0,
# the data on the bus (an instruction word) is inserted into the instruction
# pipe, replacing the breakpoint opcode, and is executed after the breakpoint
# acknowledge cycle completes. ... If the external logic terminates the
# breakpoint acknowledge cycle with BERR (i.e., no instruction word available),
# the processor takes an illegal instruction exception."
#
# So the word goes into stage D where the BKPT was, and the decode that follows
# decodes it: the program counter does not move, and the replacement runs at the
# breakpoint's own address. A BERR here is not a bus error -- the bus unit does
# not raise a fault for a CPU-space cycle -- and the end code is what says which
# way it went.
# ==========================================================================
label('bkpt')
u('the breakpoint acknowledge: CPU space type 0, the number on A4-A2, a word',
  bus='READ', fc='CPU', bytes=2, cpuspace='BKPT')
u('nobody had an instruction for it: an illegal instruction -- UM 5.4.2',
  seq='COND', cond='BERR', next='exc_illegal')
u('the word that came back replaces the breakpoint in stage D',
  asrc='RDATA', alu='A', dst='STG_D', size='WORD')
u('... and is decoded where it stands',
  seq='DECODE')

# The patterns, ordered so that the specific encodings inside 0100 1000 ... win
# before the general ones. PRM 8 packs LINK.L, NBCD, SWAP, PEA, EXT and MOVEM
# into the same line, distinguished only by bits 8:6 and the mode field.
#
# BKPT is the one this part added, in the slot PEA would have with an address
# register -- which is not an addressing mode PEA has, and which the PEA pattern
# took anyway until the inventory in M10 found it.
opcode('0100100000001---', 'link_l',  'LINK.L An,#d32')
opcode('0100100001001---', 'bkpt',    'BKPT #n')
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
    src_prologues(stem, szsel, an_ok=an_ok, fast=True)
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
    src_prologues(stem, 'IR8', fast=True)
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
    u('the destination register, stepped back -- by its own A7 rule',
      asrc='AREGW', bsrc='OPSIZEW', alu='SUB', dst='T1', szsel='IR76')
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
    fast_patterns(line + '---0--##', stem, mnem + ' <ea>,Dn')
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
u('... by the operand size. The register takes an ADDRESS, so it is written '
  'whole and not sign extended at that size',
  asrc='AREG', bsrc='OPSIZE', alu='ADD', dst='AREG_EA_ADDR', szsel='IR76')
u('read the source',
  bus='READ', fc='DATA', asel='T0', szsel='IR76')
u('and hold it',
  asrc='RDATA', alu='A', dst='T2', szsel='IR76')
u('the destination address, and its register stepped on',
  asrc='AREGW', alu='A', dst='T1', szsel='IR76')
u('... likewise, by its own A7 rule',
  asrc='AREGW', bsrc='OPSIZEW', alu='ADD', dst='AREG_ADDR', szsel='IR76')
u('read the destination',
  bus='READ', fc='DATA', asel='T1', szsel='IR76')
# Held before it is used: the microword that compares also advances the pipe,
# and a prefetch fault there re-executes it after RTE -- when the bus unit's
# read data is the last word RTE read, not this operand. T3 is in the frame.
# check_rdata_restart in the assembler; doc/bugs-found.md.
u('hold it too',
  asrc='RDATA', alu='A', dst='T3', szsel='IR76')
u('destination minus source, for the codes alone',
  asrc='T3', bsrc='T2', alu='SUB', ccr='CMP', szsel='IR76',
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
        fast_patterns(_line + '---' + _opm + '##', _stem,
                      '%s.%s <ea>,An' % (_M, _n))
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

def imm_to_ea(stem, alu, ccr, rev=False, write=True, fast=False):
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

    if fast:
        for _w, _long in (('immw', False), ('imml', True)):
            for mode, _bits in FAST_MODES:
                label('%s_%s_%s' % (stem, _w, mode))
                if _long:
                    u('the high half of the immediate',
                      asrc='STG_C_HI', alu='A', dst='T0', pf='CONSUME')
                    u('... and the low',
                      asrc='T0', bsrc='STG_C_U', alu='OR', dst='T0',
                      pf='CONSUME')
                else:
                    u('one word of immediate',
                      asrc='STG_C', alu='A', dst='T0', size='WORD',
                      pf='CONSUME')
                goto('%s_%s' % (stem, mode))
        fast_rmw(stem, lambda: u('... and the operation',
                                 asrc=('RDATA' if rev else 'T0'),
                                 bsrc=('T0' if rev else 'RDATA'),
                                 alu=alu, dst='T1', ccr=ccr, szsel='IR76'),
                 'IR76', write=write)

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
    imm_to_ea(_stem, _alu, _ccr, rev=_rev, write=_wr, fast=(_stem == 'cmpi'))
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
        if _stem == 'cmpi':
            for _mode, _mb in FAST_MODES:
                opcode('0000' + _bits + _sz + _mb + '---',
                       '%s_%s_%s' % (_stem, _w, _mode),
                       '%s.%s #imm,(%s)' % (_M, _n, _mode))
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
for _stem, _alu in (('addq', 'ADD'), ('subq', 'SUB')):
    fast_rmw(_stem, lambda a=_alu: u('the operation',
                                     asrc='RDATA', bsrc='IMMQ', alu=a, dst='T1',
                                     ccr=a, szsel='IR76'), 'IR76')

# Size 11 of this line is Scc and DBcc, so the three sizes are written out
# rather than wildcarded.
for _d, _stem in (('0', 'addq'), ('1', 'subq')):
    for _sz, _n in (('00', 'B'), ('01', 'W'), ('10', 'L')):
        opcode('0101---' + _d + _sz + '001---', _stem + '_an',
               '%s.%s #q,An' % (_stem.upper(), _n))
        opcode('0101---' + _d + _sz + '000---', _stem + '_dn',
               '%s.%s #q,Dn' % (_stem.upper(), _n))
        fast_patterns('0101---' + _d + _sz + '##', _stem,
                      '%s.%s #q,<ea>' % (_stem.upper(), _n))
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
          asrc='SP', bsrc='FOUR', alu='SUB', dst='SP', size='LONG')
        u('push the address of the next instruction',
          bus='WRITE', fc='DATA', asel='SP', asrc='PC_C', alu='A', bytes=4)
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
  asrc='SP', bsrc='FOUR', alu='SUB', dst='SP', size='LONG')
# The effective address has consumed its extension words, so PC_C now names the
# word after the instruction -- which is the return address.
u('push the address of the next instruction',
  bus='WRITE', fc='DATA', asel='SP', asrc='PC_C', alu='A', bytes=4)
u('and the effective address is the new program counter',
  asrc='EA', alu='A', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')

def ret(stem, restore_ccr, extra_disp):
    label(stem)
    if not restore_ccr and not extra_disp:
        # RTS: the return address read and flushed to in one microword -- a
        # read taking its own data (MERGED_READS), and a flush is gated on the
        # microword committing, so a faulted read neither jumps nor moves the
        # stack. Then the stack pointer, on the microword that waits to decode.
        u('the return address, read and made the new program counter',
          bus='READ', fc='DATA', asel='SP', bytes=4, asrc='RDATA', alu='A',
          pf='FLUSH')
        u('the stack pointer, four past it -- and wait for the pipe and decode',
          asrc='SP', bsrc='FOUR', alu='ADD', dst='SP', size='LONG',
          seq='DECODE')
        return
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
    if static:
        u('the bit number, which is the word after the opcode -- kept in T0, '
          'because an indexed address decodes its own extension word in XW',
          asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
    u('the address',
      call=1, seq='EAMODE', size='BYTE')
    if static:
        u('... and the bit number back where the mask is made from',
          asrc='T0', alu='A', dst='XW', size='WORD')
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
    """One of MOVEM's four shapes.

    The register each transfer moves is the lowest set bit of what is left of
    the mask in T0 -- REGN and REGNR are a priority encoder on it, not a counter
    -- and the transfer clears that bit (cnt = CLRLOW). So the loop visits only
    the registers in the list: two microwords each, the transfer and the step of
    the address, and none for a register that is not there. It used to walk all
    sixteen positions at three microwords each, which made MOVEM the slowest row
    in doc/timing-divergences.md.

    The predecrement form walks down from one operand below An, so that the
    address is stepped after the transfer as in the other forms, and puts back
    the last address it wrote -- PRM 4, "the address register is decremented by
    the operand size ... the final address is written to the register".
    """
    src = 'REGNR' if reverse else 'REGN'
    label(stem)
    u('the register mask, which is the word after the opcode',
      asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
    if ctl:
        u('the address the mode names',
          call=1, seq='EAMODE', szsel='IR6')
        u('... which the loop walks from -- if there is anything to move',
          asrc='EA', alu='A', dst='T1', size='LONG',
          seq='COND', cond='EMPTY', next=stem + '_done')
    elif step_before:
        u('one operand below the address register is where the first goes -- '
          'if there is anything to move',
          asrc='AREG', bsrc='OPSIZE', alu='SUB', dst='T1', szsel='IR6',
          seq='COND', cond='EMPTY', next=stem + '_done')
    else:
        u('the address register the loop walks from -- if there is anything to '
          'move',
          asrc='AREG', alu='A', dst='T1', size='LONG',
          seq='COND', cond='EMPTY', next=stem + '_done')

    label(stem + '_xfer')
    if to_mem:
        u('the lowest register left in the list goes to the address, and leaves '
          'the list',
          bus='WRITE', fc='DATA', asel='T1', asrc=src, alu='A', szsel='IR6',
          cnt='CLRLOW')
    else:
        u('what is at the address goes into the lowest register left in the '
          'list, sign extended, and it leaves the list',
          bus='READ', fc='EASP', asel='T1', asrc='RDATA', alu='SX', dst=src,
          szsel='IR6', cnt='CLRLOW')
    u('the address steps on, and round again while any register is left',
      asrc='T1', bsrc='OPSIZE', alu='SUB' if step_before else 'ADD', dst='T1',
      szsel='IR6', seq='COND', cond='NOTEMPTY', next=stem + '_xfer')

    label(stem + '_done')
    if ctl:
        u('a control mode leaves no register to put back',
          pf='ADV', seq='DECODE')
    elif step_before:
        u('the address register is left on the last operand written -- an '
          'address, so written whole',
          asrc='T1', bsrc='OPSIZE', alu='ADD', dst='AREG_EA_ADDR', szsel='IR6')
        u('done',
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


# ... which an indexed source overwrites with ITS extension word, so the memory
# path keeps a copy in T1 across the effective address -- check_ea_live -- and
# only the memory path pays for it.
def _mdlong_save():
    u('the extension word kept across the effective address',
      asrc='XW', alu='A', dst='T1', size='WORD')


def _mdlong_restore():
    u('... and put back',
      asrc='T1', alu='A', dst='XW', size='WORD')


src_prologues('mull', 'FIXED', an_ok=False, size='LONG',
              prelude=_mdlong_prelude, before_ea=_mdlong_save,
              after_ea=_mdlong_restore)
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
              prelude=_mdlong_prelude, before_ea=_mdlong_save,
              after_ea=_mdlong_restore)
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
    u('the source register, stepped back a byte -- two for A7, UM 2.2',
      asrc='AREG', bsrc='BSTEP', alu='SUB', dst='T0', size='LONG')
    u('... which is its new value',
      asrc='T0', alu='A', dst='AREG_EA', size='LONG')
    u('read the source',
      bus='READ', fc='DATA', asel='T0', bytes=1)
    u('and hold it',
      asrc='RDATA', alu='A', dst='T2', size='BYTE')
    u('the destination register, stepped back a byte -- two for A7',
      asrc='AREGW', bsrc='BSTEPW', alu='SUB', dst='T1', size='LONG')
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
# CMP2 and CHK2 -- PRM 4, new on the MC68020
#
# "Compares the value in Rn to each bound. The effective address contains the
# bounds pair: the upper bound following the lower bound."
#
# One routine for both, because the extension word and not the opcode says which
# it is -- bit 11 -- and everything up to the verdict is the same.
#
# THE COMPARISON IS THE INTERESTING PART. The manual does not say signed or
# unsigned; it says "for signed comparisons, the arithmetically smaller value
# should be used as the lower bound. For unsigned comparisons, the logically
# smaller value should be the lower bound." One test satisfies both:
#
#     out of bounds  <=>  (Rn - LB)  >unsigned  (UB - LB)
#
# Both differences are modular, so the test asks whether Rn lies in the cyclic
# interval that starts at LB and is as long as the range -- which is what being
# between the bounds means under either reading, and it needs no branch on which
# one was meant. The two equalities the Z bit wants fall out of the same two
# differences: Rn = LB is the first being zero, and Rn = UB is the two being
# equal.
#
# PRM 4 on the register: "if Rn is a data register and the operation size is
# byte or word, only the appropriate low-order part of Rn is checked. If Rn is
# an address register ... the bounds operands are sign-extended to 32 bits, and
# the resultant operands are compared to the full 32 bits of An." So the bounds
# are always widened and only the data-register case narrows what it checks.
# ==========================================================================
label('cmp2')
# The extension word has to be read before the effective address, because it is
# the word right after the opcode -- and it has to be put somewhere the address
# routines will not tread on, because they use `xw` for their own. MOVEM has the
# same problem with its register mask and solves it the same way.
u('the extension word: the register, and which of the two instructions this is',
  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
u('the address of the bounds pair',
  call=1, seq='EAMODE', szsel='IR109')
u('... and now the extension word can come back',
  asrc='T0', alu='A', dst='XW', size='WORD')
# The bounds are read in the effective address's own space: (d16,PC) and
# (d8,PC,Xn) are program references (PRM 2), like any read-only operand. And
# they sit at consecutive operand-sized addresses: the A7 byte rule is for
# stepping the register through (A7)+ and -(A7), not for this.
u('the lower bound',
  bus='READ', fc='EASP', asel='EA', szsel='IR109')
u('... widened to thirty-two bits -- PRM 4',
  asrc='RDATA', alu='SX', dst='T1', szsel='IR109')
u('step past it, by the operand size and nothing else',
  asrc='EA', bsrc='OPBYTES', alu='ADD', dst='EA', size='LONG', szsel='IR109')
u('the upper bound',
  bus='READ', fc='EASP', asel='EA', szsel='IR109')
u('... likewise',
  asrc='RDATA', alu='SX', dst='T2', szsel='IR109')
u('an address register is compared whole',
  seq='COND', cond='XW15', next='cmp2_areg')
u('a data register, only as far as the operand size goes',
  asrc='XREG', alu='SX', dst='T3', szsel='IR109', next='cmp2_go')

label('cmp2_areg')
u('all thirty-two bits of it',
  asrc='XREG', alu='A', dst='T3', size='LONG')

label('cmp2_go')
u('the register less the lower bound, and Z if they were equal',
  asrc='T3', bsrc='T1', alu='SUB', dst='T3', size='LONG', ccr='ZN')
u('the span of the range',
  asrc='T2', bsrc='T1', alu='SUB', dst='T1', size='LONG')
u('out of bounds when the register is further along it than that',
  asrc='T1', bsrc='T3', alu='SUB', size='LONG', ccr='CMP2',
  seq='COND', cond='XW11', next='chk2_test')
u('CMP2 does nothing but set the codes',
  pf='ADV', seq='DECODE')

label('chk2_test')
u('CHK2 traps when it is out of bounds -- PRM 4, vector 6',
  seq='COND', cond='CSET', next='exc_chk')
u('... and does not when it is not',
  pf='ADV', seq='DECODE')

opcode('0000000011------', 'cmp2', 'CMP2/CHK2.B <ea>,Rn')
opcode('0000001011------', 'cmp2', 'CMP2/CHK2.W <ea>,Rn')
opcode('0000010011------', 'cmp2', 'CMP2/CHK2.L <ea>,Rn')


# ==========================================================================
# MOVES -- PRM 6, the MC68010's and this part's only way to name an address
# space rather than have one chosen for it.
#
# "Moves the byte, word, or long-word operand from the specified general
# register to a location within the address space specified by the destination
# function code register, or from a location within the address space specified
# by the source function code register to the specified general register."
#
# Privileged, for the obvious reason: a user program that could name its own
# function code could read supervisor memory.
# ==========================================================================
label('moves')
u('privileged -- PRM 6',
  seq='COND', cond='USER', next='exc_priv')
u('the extension word: the register, and which way the move goes',
  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
u('the address the mode names',
  call=1, seq='EAMODE', szsel='IR76')
u('... and now the extension word can come back',
  asrc='T0', alu='A', dst='XW', size='WORD')
u('which way?',
  seq='COND', cond='XW11', next='moves_out')
u('in, through the SOURCE function code',
  bus='READ', fc='SFC', asel='EA', szsel='IR76')
u('... held, because the microword that writes it also advances the pipe -- '
  'check_rdata_restart',
  asrc='RDATA', alu='A', dst='T1', szsel='IR76')
u('... into the register the extension word names',
  asrc='T1', alu='A', dst='XREG_SZ', szsel='IR76', pf='ADV', seq='DECODE')

label('moves_out')
u('out, through the DESTINATION function code',
  bus='WRITE', fc='DFC', asel='EA', asrc='XREG', alu='A', szsel='IR76',
  pf='ADV', seq='DECODE')

opcode('0000111000------', 'moves', 'MOVES.B')
opcode('0000111001------', 'moves', 'MOVES.W')
opcode('0000111010------', 'moves', 'MOVES.L')


# ==========================================================================
# THE BIT FIELD INSTRUCTIONS -- PRM 4, eight of the MC68020's twenty-seven
#
# A field is one to thirty-two bits starting `offset` bits after a base, and the
# base is either a data register -- where the offset is taken modulo 32 and the
# field WRAPS -- or memory, where it runs downward from bit 7 of the byte at
# base + offset/8 through as many as five bytes.
#
# Offset and width are not operands this microcode fetches: they are functions
# of the extension word and, when it says so, of a data register, and
# rd68021_bitfield is handed them as wires. What the microcode does is find the
# base, read the bytes the field touches, and say what to do with it.
#
# PRM 3.1.6: "All bit field instructions set the CCR N and Z bits as shown for
# BFTST before performing the specified operation" -- from the field as it was
# found. BFINS is the exception its own page names, and
# doc/manual-contradictions.md records the disagreement.
#
# What goes back into the field is always put in T3 first, because the microword
# that writes it computes the MERGE, and the merge cannot depend on that same
# microword's result.
# ==========================================================================
def bitfield(stem, ttt, ins=None, result=None, ccr='BF'):
    """One bit-field instruction, in its register and its memory form.

    `ins` is the microword that loads T3 with what goes back into the field,
    and `result` the source that goes into the register the extension word
    names. An instruction has one or the other or neither.
    """
    for mem in (False, True):
        sz = 'BFMEM' if mem else 'BFREG'
        label(stem + ('_mem' if mem else '_dn'))
        if mem:
            # The extension word is the word after the opcode and has to be
            # read before the address routine's own -- and kept out of `xw`
            # while that routine uses it, which is what T0 is for here.
            u('the extension word: the field, and where its offset comes from',
              asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
            u('the base address',
              call=1, seq='EAMODE', size='LONG')
            u('... and now the extension word can come back',
              asrc='T0', alu='A', dst='XW', size='WORD')
            u('the first byte the field touches -- PRM 4, the offset over eight',
              asrc='EA', bsrc='BF_BYTEOFF', alu='ADD', dst='EA', size='LONG')
            # In the effective address's own space: BFTST, BFEXTU, BFEXTS
            # and BFFFO allow the PC-relative modes, which are program
            # references (PRM 2). For the others it is data space anyway.
            u('read every byte it touches, and no others',
              bus='READ', fc='EASP', asel='EA', szsel=sz)
        else:
            u('the extension word: the field, and where its offset comes from',
              asrc='STG_C', alu='A', dst='XW', size='WORD', pf='CONSUME')

        # In the memory form everything the bit-field unit produces is a
        # function of the read data, which does not survive a fault -- so no
        # microword that uses it may also advance the pipe, where a prefetch
        # fault would re-run it after RTE on whatever RTE last read.
        # check_rdata_restart; the register form has no such constraint.
        last = (ins is None and result is None)
        end = {'pf': 'ADV', 'seq': 'DECODE'} if not mem else {}
        if ccr == 'BF':
            u('the codes come from the field as it was found -- PRM 3.1.6',
              ccr='BF', szsel=sz, **(end if last else {}))
            if last and mem:
                u('... and on', pf='ADV', seq='DECODE')

        if result is not None:
            u('and the result goes to the register the extension word names',
              asrc=result, alu='A', dst='DREG_XQ', size='LONG', szsel=sz,
              **end)
            if mem:
                u('... and on', pf='ADV', seq='DECODE')

        if ins is not None:
            u('what goes back into the field',
              asrc=ins[0], alu=ins[1], dst='T3', size='LONG', szsel=sz)
            if ccr == 'BFINS':
                u('BFINS sets the codes from the value it is inserting',
                  ccr='BFINS', szsel=sz)
            if mem:
                u('the bytes back, with only the field changed',
                  bus='WRITE', fc='DATA', asel='EA', szsel=sz)
                u('... and on', pf='ADV', seq='DECODE')
            else:
                u('the register back, with only the field changed',
                  asrc='BF_MERGED', alu='A', dst='DREG_R', size='LONG',
                  szsel=sz, pf='ADV', seq='DECODE')

    base = '1110' + ttt + '11'
    opcode(base + '000---', stem + '_dn',  stem.upper() + ' Dn{o:w}')
    opcode(base + '------', stem + '_mem', stem.upper() + ' <ea>{o:w}')


bitfield('bftst',  '1000')
bitfield('bfextu', '1001', result='BF_FIELD')
bitfield('bfchg',  '1010', ins=('BF_FIELD', 'NOT'))
bitfield('bfexts', '1011', result='BF_SXFIELD')
bitfield('bfclr',  '1100', ins=('ZERO', 'A'))
bitfield('bfffo',  '1101', result='BF_FFO')
bitfield('bfset',  '1110', ins=('ZERO', 'NOT'))
# PRM 4: "inserts a bit field taken from the low-order bits of the specified
# data register", which is the one in bits 14-12 of the extension word.
bitfield('bfins',  '1111', ins=('DREG_XQ', 'A'), ccr='BFINS')


# ==========================================================================
# CAS and CAS2 -- PRM 4, the MC68020's synchronisation primitives
#
# "Both operations access memory using locked or read-modify-write transfer
# sequences, providing a means of synchronizing several processors." RMC is
# held across every cycle of the sequence and across the microwords between
# them -- UM 5.5.2 makes it a qualifier over a run of ordinary cycles, and the
# bus unit drops it the moment a microword stops asking for it.
#
# CAS2 is the reason the sequencer has four temporaries and the reason the
# extension words are kept in two of them. It has SIX things live at once --
# two addresses, two values read, and two extension words -- and only four
# registers to put them in. The way out is that the addresses are recomputable:
# each is a register the extension word names, so loading `xw` from whichever
# word is current gets the address back for nothing.
# ==========================================================================
label('cas')
u('the extension word: the compare register and the update register',
  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
u('the address',
  call=1, seq='EAMODE', szsel='CAS')
u('... and now the extension word can come back',
  asrc='T0', alu='A', dst='XW', size='WORD')
u('read the destination, and hold the bus from here -- UM 5.5.2',
  bus='READ', fc='DATA', asel='EA', szsel='CAS', rmc=1)
u('... held',
  asrc='RDATA', alu='A', dst='T1', szsel='CAS', rmc=1)
u('the destination less the compare operand',
  asrc='T1', bsrc='DREG_XR', alu='SUB', ccr='CMP', szsel='CAS', rmc=1)
u('... and the branch is a microword later, because a condition reads the '
  'codes as they stand and the one above has not written them yet',
  seq='COND', cond='ZSET', next='cas_swap', rmc=1)
u('they differ, so the destination goes into the compare register instead '
  'and the bus is let go',
  asrc='T1', alu='A', dst='DREG_XR', szsel='CAS', pf='ADV', seq='DECODE')

label('cas_swap')
u('they match, so the update register goes to memory, still holding the bus',
  bus='WRITE', fc='DATA', asel='EA', asrc='DREG_XU', alu='A', szsel='CAS',
  rmc=1, pf='ADV', seq='DECODE')


label('cas2')
u('the first extension word',
  asrc='STG_C', alu='A', dst='T0', size='WORD', pf='CONSUME')
u('the second',
  asrc='STG_C', alu='A', dst='T1', size='WORD', pf='CONSUME')
u('the first one names the first address',
  asrc='T0', alu='A', dst='XW', size='WORD')
u('... which is the register it names',
  asrc='XREG', alu='A', dst='EA', size='LONG')
u('read it, and hold the bus from here to the end',
  bus='READ', fc='DATA', asel='EA', szsel='CAS', rmc=1)
u('... held',
  asrc='RDATA', alu='A', dst='T2', szsel='CAS', rmc=1)
u('the second extension word names the second address',
  asrc='T1', alu='A', dst='XW', size='WORD', rmc=1)
u('... likewise',
  asrc='XREG', alu='A', dst='EA', size='LONG', rmc=1)
u('read that too. BOTH are read before either is compared, because a compare '
  'that fails still has to put both of them in the compare registers',
  bus='READ', fc='DATA', asel='EA', szsel='CAS', rmc=1)
u('... held',
  asrc='RDATA', alu='A', dst='T3', szsel='CAS', rmc=1)
u('back to the first extension word for the first compare',
  asrc='T0', alu='A', dst='XW', size='WORD', rmc=1)
u('the first destination less the first compare operand',
  asrc='T2', bsrc='DREG_XR', alu='SUB', ccr='CMP', szsel='CAS', rmc=1)
u('... and the branch a microword later',
  seq='COND', cond='ZSET', next='cas2_second', rmc=1)
u('the first differs, and that is the end of it',
  next='cas2_fail')

label('cas2_second')
u('the second extension word',
  asrc='T1', alu='A', dst='XW', size='WORD', rmc=1)
u('the second destination less the second compare operand',
  asrc='T3', bsrc='DREG_XR', alu='SUB', ccr='CMP', szsel='CAS', rmc=1)
u('... likewise',
  seq='COND', cond='ZSET', next='cas2_swap', rmc=1)
u('the second differs',
  next='cas2_fail')

label('cas2_swap')
# PRM 4: "Update 1 -> Destination 1; Update 2 -> Destination 2", in that order.
u('both matched: back to the first address',
  asrc='T0', alu='A', dst='XW', size='WORD', rmc=1)
u('... which is the register it names',
  asrc='XREG', alu='A', dst='EA', size='LONG', rmc=1)
u('the first update goes there',
  bus='WRITE', fc='DATA', asel='EA', asrc='DREG_XU', alu='A', szsel='CAS',
  rmc=1)
u('and the second address',
  asrc='T1', alu='A', dst='XW', size='WORD', rmc=1)
u('... likewise',
  asrc='XREG', alu='A', dst='EA', size='LONG', rmc=1)
u('the second update goes there, and the bus is let go',
  bus='WRITE', fc='DATA', asel='EA', asrc='DREG_XU', alu='A', szsel='CAS',
  rmc=1, pf='ADV', seq='DECODE')

label('cas2_fail')
# "If either comparison fails, the instruction writes the memory operands to
# the compare operands." Both of them, whichever comparison it was that failed,
# which is why both were read before either was compared.
#
# The SECOND goes first. PRM 4, CAS2, the Dc1 and Dc2 fields: "If Dc1 and Dc2
# specify the same data register and the comparison fails, memory operand 1 is
# stored in the data register" -- so operand 1 is the write that lands last.
u('one of them differed: the second extension word',
  asrc='T1', alu='A', dst='XW', size='WORD')
u('the second destination goes into the second compare register',
  asrc='T3', alu='A', dst='DREG_XR', szsel='CAS')
u('and the first extension word',
  asrc='T0', alu='A', dst='XW', size='WORD')
u('the first destination into the first compare register, last, so that it is '
  'what a shared register holds',
  asrc='T2', alu='A', dst='DREG_XR', szsel='CAS', pf='ADV', seq='DECODE')

# CAS2 is an immediate-mode encoding of CAS, which CAS cannot use, so it is
# claimed first -- PRM 8.
opcode('0000110011111100', 'cas2', 'CAS2.W')
opcode('0000111011111100', 'cas2', 'CAS2.L')
opcode('0000101011------', 'cas',  'CAS.B')
opcode('0000110011------', 'cas',  'CAS.W')
opcode('0000111011------', 'cas',  'CAS.L')


# ==========================================================================
# CALLM and RTM -- PRM 4 and UM 9.7-9.8, the MC68020's module calls
#
# Motorola dropped them from the MC68030 and nothing emulates them, so these are
# written from UM section 9 and nothing else, and checked by directed tests
# only -- doc/divergences.md says exactly what that does and does not cover.
#
# A module descriptor (UM figure 9-10):
#
#   +$00  opt[31:29]  type[28:24]  access level[23:16]  reserved[15:0]
#   +$04  module entry word pointer
#   +$08  module data area pointer
#
# and the module stack frame CALLM builds and RTM takes apart (figure 9-12),
# six long words from the stack pointer up:
#
#   +$00  opt[15:13]  type[12:8]  saved access level[7:0]
#   +$02  the condition codes of the calling module
#   +$04  the argument count
#   +$06  reserved
#   +$08  module descriptor pointer
#   +$0C  saved program counter -- the instruction after the CALLM
#   +$10  saved module data area pointer -- the old value of the register the
#         entry word names
#   +$14  saved stack pointer
#
# "The first word at the entry address specifies the register to be saved in
# the module stack frame and then loaded with the module descriptor data area
# pointer; the first instruction of the module starts with the next word." That
# word has the register in exactly the layout an extension word does -- D/A in
# bit 15, the number in 14:12 -- so it goes into `xw` and XREG does the rest.
#
# Both instructions check the options and the type BEFORE they change anything:
# UM 9.8.1, on a refusal, "no visible processor registers are changed".
# ==========================================================================
label('callm')
u('the argument count, which is the word after the opcode, in T1 because the '
  'effective address may use T2 and T3',
  asrc='STG_C', alu='A', dst='T1', size='WORD', pf='CONSUME')
u('the address of the module descriptor',
  call=1, seq='EAMODE', size='LONG')
u('its first long word: the options, the type and the access level',
  bus='READ', fc='DATA', asel='EA', bytes=4)
u('... held, with the argument count put in the low half the manual reserves, '
  'which is where the frame wants it',
  asrc='RDATA', bsrc='T1', alu='ORLOW16', dst='T0', size='LONG')
u('anything but options 000 and 100 and types $00 and $01 is a format error, '
  'taken before anything has changed -- UM 9.7.1',
  seq='COND', cond='MODBAD', next='exc_format')
u('type $01 changes the access level -- UM 9.8.1',
  seq='COND', cond='MODTYPE1', next='callm_type1')
label('callm_ptrs')
u('the module entry word pointer is at +$04',
  asrc='EA', bsrc='FOUR', alu='ADD', dst='T1', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T1', bytes=4)
u('... held: it is where the module starts',
  asrc='RDATA', alu='A', dst='T1', size='LONG')
u('the module data area pointer is at +$08',
  asrc='EA', bsrc='EIGHT', alu='ADD', dst='T2', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T2', bytes=4)
u('... held',
  asrc='RDATA', alu='A', dst='T2', size='LONG')
u('the module entry word, which names the register the data area pointer goes '
  'into. It is the first word of the module code, so it is read as program',
  bus='READ', fc='PROG', asel='T1', bytes=2)
u('... into xw, where XREG reads a register name from',
  asrc='RDATA', alu='A', dst='XW', size='WORD')

label('callm_frame')
# The frame is built top down from the stack pointer, with T3 walking. The
# order is the frame's own, highest first, and it ends with T3 on the base.
u('the frame is built down from the stack pointer',
  asrc='SP', alu='A', dst='T3', size='LONG')
# A type $01 call that moves the stack comes in here with T3 already at the top
# of the new one, below the arguments it copied.
label('callm_frame_at')
u('+$14: the saved stack pointer -- the OLD one, since the register has not '
  'been written yet',
  asrc='T3', bsrc='FOUR', alu='SUB', dst='T3', size='LONG')
u('... written',
  bus='WRITE', fc='DATA', asel='T3', asrc='SP', alu='A', bytes=4)
u('+$10: the old value of the register the entry word names',
  asrc='T3', bsrc='FOUR', alu='SUB', dst='T3', size='LONG')
u('... written',
  bus='WRITE', fc='DATA', asel='T3', asrc='XREG', alu='A', bytes=4)
u('+$0C: the instruction after the CALLM, which is where RTM goes back to',
  asrc='T3', bsrc='FOUR', alu='SUB', dst='T3', size='LONG')
u('... written',
  bus='WRITE', fc='DATA', asel='T3', asrc='PC_C', alu='A', bytes=4)
u('+$08: the module descriptor pointer',
  asrc='T3', bsrc='FOUR', alu='SUB', dst='T3', size='LONG')
u('... written',
  bus='WRITE', fc='DATA', asel='T3', asrc='EA', alu='A', bytes=4)
u('+$06: reserved',
  asrc='T3', bsrc='TWO', alu='SUB', dst='T3', size='LONG')
u('... written as zero',
  bus='WRITE', fc='DATA', asel='T3', asrc='ZERO', alu='A', bytes=2)
u('+$04: the argument count',
  asrc='T3', bsrc='TWO', alu='SUB', dst='T3', size='LONG')
u('... written: it is the low half of T0',
  bus='WRITE', fc='DATA', asel='T3', asrc='T0', alu='A', bytes=2)
u('+$02: the condition codes of the calling module',
  asrc='T3', bsrc='TWO', alu='SUB', dst='T3', size='LONG')
u('... written',
  bus='WRITE', fc='DATA', asel='T3', asrc='CCRW', alu='A', bytes=2)
u('+$00: the options, the type and the access level',
  asrc='T3', bsrc='TWO', alu='SUB', dst='T3', size='LONG')
u('... written: they are the high half of T0',
  bus='WRITE', fc='DATA', asel='T3', asrc='T0', alu='SWAP', bytes=2)
# UM 9.7.1: "if the called module does not wish the module data area pointer to
# be loaded into a register, the module entry word can select register A7, and
# the loaded value will be overwritten with the correct stack pointer value
# after the module stack frame is created" -- so the register first and the
# stack pointer second.
u('the register the entry word names gets the module data area pointer',
  asrc='T2', alu='A', dst='XREG', size='LONG')
u('and the stack pointer is the frame, overwriting that if the register was A7',
  asrc='T3', alu='A', dst='SP', size='LONG')
u('the module starts at the word after its entry word',
  asrc='T1', bsrc='TWO', alu='ADD', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')

label('rtm')
u('the register to restore, from the opcode, put where XREG reads a name from',
  asrc='RTM_XW', alu='A', dst='XW', size='WORD')
u('the frame is at the top of the stack',
  asrc='SP', alu='A', dst='T3', size='LONG')
u('+$00: the options, the type and the access level',
  bus='READ', fc='DATA', asel='T3', bytes=2)
u('... moved up to where a descriptor has them, so that the same conditions '
  'judge both',
  asrc='RDATA', alu='SHL16', dst='T0', size='LONG')
u('a frame RTM does not recognise is a format error, before anything changes '
  '-- UM 9.7.2',
  seq='COND', cond='MODBAD', next='exc_format')
u('type $01 changes the access level back -- UM 9.8.2',
  seq='COND', cond='MODTYPE1', next='rtm_type1')

label('rtm_restore')
u('+$04: the argument count',
  asrc='T3', bsrc='FOUR', alu='ADD', dst='T1', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T1', bytes=2)
u('... which, with the frame, is how far the stack goes back',
  asrc='RDATA', bsrc='T3', alu='ADD', dst='T1', size='LONG')
u('... twelve bytes of it',
  asrc='T1', bsrc='TWELVE', alu='ADD', dst='T1', size='LONG')
u('... and twelve more: the frame is six long words',
  asrc='T1', bsrc='TWELVE', alu='ADD', dst='T1', size='LONG')
label('rtm_restore_rest')
u('+$0C: the saved program counter',
  asrc='T3', bsrc='TWELVE', alu='ADD', dst='T2', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T2', bytes=4)
u('... held',
  asrc='RDATA', alu='A', dst='T2', size='LONG')
u('+$02: the condition codes',
  asrc='T3', bsrc='TWO', alu='ADD', dst='T0', size='LONG')
u('read them',
  bus='READ', fc='DATA', asel='T0', bytes=2)
u('... held',
  asrc='RDATA', alu='A', dst='T0', size='WORD')
u('+$10: the saved module data area pointer',
  asrc='T3', bsrc='EIGHT', alu='ADD', dst='T3', size='LONG')
u('... eight more',
  asrc='T3', bsrc='EIGHT', alu='ADD', dst='T3', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T3', bytes=4)
# "Condition Codes: set according to the content of the word on the stack."
u('it goes back into the register the opcode names',
  asrc='RDATA', alu='A', dst='XREG', size='LONG')
u('the condition codes come back',
  asrc='T0', alu='A', dst='CCR', size='WORD')
# PRM 4: "If the register specified is A7 (SP), the updated value of the
# register reflects the stack pointer operations, and the saved module data
# area pointer is lost" -- so the stack pointer is written after it.
u('the stack goes back past the frame and the arguments',
  asrc='T1', alu='A', dst='SP', size='LONG')
u('and the calling module carries on after its CALLM',
  asrc='T2', alu='A', pf='FLUSH')
u('... then wait for the pipe and decode',
  seq='DECODE')

# --------------------------------------------------------------------------
# Type $01: a change of access level -- UM 9.8
#
# The processor does not interpret access levels; it carries them between the
# descriptor, the frame, and external hardware at the registers of UM figure
# 9-13, in CPU space type 1, and does what the access status register tells it.
# "If the processor receives a bus error on any of these CPU space accesses
# during the execution of a CALLM or RTM instruction, the processor will take a
# format error exception" -- so every one of them is followed by that test.
# --------------------------------------------------------------------------
label('callm_type1')
# UM 9.8.1, in the manual's own order: "the processor must first obtain the
# current access level from external hardware. It also verifies that the
# calling module has the right to read from the area pointed to by the current
# value of the stack pointer by reading from that address. It passes the
# descriptor address and increase access level to external hardware for
# validation and then reads the access status."
u('the current access level: CAL, CPU space type 1 at $00',
  bus='READ', fc='CPU', bytes=1, cpuspace='ACCESS', vec=0x00)
u('a bus error on any of these is a format error -- UM 9.8',
  seq='COND', cond='BERR', next='exc_format')
u('... held: it goes in the frame',
  asrc='RDATA', alu='A', dst='T1', size='LONG')
u('the caller has to be able to read its own stack: read it',
  bus='READ', fc='DATA', asel='SP', bytes=2)
u('the descriptor address, to the register for the space it was read from',
  seq='COND', cond='USER', next='callm_t1_user')
u('... supervisor data, function code 5, is $54',
  bus='WRITE', fc='CPU', bytes=4, cpuspace='ACCESS', vec=0x54,
  asrc='EA', alu='A', next='callm_t1_ial')
label('callm_t1_user')
u('... user data, function code 1, is $44',
  bus='WRITE', fc='CPU', bytes=4, cpuspace='ACCESS', vec=0x44,
  asrc='EA', alu='A')
label('callm_t1_ial')
u('... and refused with a bus error, a format error',
  seq='COND', cond='BERR', next='exc_format')
u('the access level the descriptor asks for, to IAL at $08. It is bits 23:16 '
  'of T0, which SWAP brings down to the byte that goes out',
  bus='WRITE', fc='CPU', bytes=1, cpuspace='ACCESS', vec=0x08,
  asrc='T0', alu='SWAP')
u('... refused with a bus error',
  seq='COND', cond='BERR', next='exc_format')
u('the verdict: the access status register at $04',
  bus='READ', fc='CPU', bytes=1, cpuspace='ACCESS', vec=0x04)
u('... refused with a bus error',
  seq='COND', cond='BERR', next='exc_format')
u('... held',
  asrc='RDATA', alu='A', dst='T2', size='LONG')
u('zero is a refusal and above seven is undefined: a format error, and '
  'nothing visible has changed -- UM 9.8.1',
  seq='COND', cond='ASTAT_BAD', next='exc_format')
u('the frame keeps the CALLER\'s access level, in place of the one asked for',
  asrc='T0', bsrc='T1', alu='SETB2', dst='T0', size='LONG')
u('a new stack as well? -- UM table 9-6, four to seven',
  seq='COND', cond='ASTAT_STACK', next='callm_t1_stack')
u('no: from here it is a type $00 call',
  next='callm_ptrs')

label('callm_t1_stack')
# "If the access status register indicates that a change in the stack pointer
# is required, the stack pointer is saved internally, a new value is loaded from
# the module descriptor, and arguments are copied from the calling stack to the
# new stack." Saved internally means: not written yet. The register keeps the
# old value until the frame has been built, which is what puts it at +$14.
u('the new stack pointer, from the descriptor at +$0C',
  asrc='EA', bsrc='TWELVE', alu='ADD', dst='T1', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T1', bytes=4)
u('... held',
  asrc='RDATA', alu='A', dst='T1', size='LONG')
u('option 100 reaches the arguments through the saved stack pointer and '
  'copies nothing -- UM 9.7.1',
  seq='COND', cond='MODOPT4', next='callm_t1_placed')
u('option 000 copies them: this many bytes',
  asrc='T0', alu='ZXB', dst='T3', size='LONG')
u('... from the top end of them on the old stack',
  asrc='SP', bsrc='T3', alu='ADD', dst='T2', size='LONG')
label('callm_t1_copy')
u('all copied?',
  seq='COND', cond='T3ZERO', next='callm_t1_placed')
u('back one on the old stack',
  asrc='T2', bsrc='ONE', alu='SUB', dst='T2', size='LONG')
u('back one on the new',
  asrc='T1', bsrc='ONE', alu='SUB', dst='T1', size='LONG')
u('a byte from the old',
  bus='READ', fc='DATA', asel='T2', bytes=1)
u('... to the new',
  bus='WRITE', fc='DATA', asel='T1', asrc='RDATA', alu='A', bytes=1)
u('one fewer to go',
  asrc='T3', bsrc='ONE', alu='SUB', dst='T3', size='LONG',
  next='callm_t1_copy')

label('callm_t1_placed')
u('the frame goes on the new stack, below whatever arguments came with it',
  asrc='T1', alu='A', dst='T3', size='LONG')
u('the module entry word pointer is at +$04',
  asrc='EA', bsrc='FOUR', alu='ADD', dst='T1', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T1', bytes=4)
u('... held',
  asrc='RDATA', alu='A', dst='T1', size='LONG')
u('the module data area pointer is at +$08',
  asrc='EA', bsrc='EIGHT', alu='ADD', dst='T2', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T2', bytes=4)
u('... held',
  asrc='RDATA', alu='A', dst='T2', size='LONG')
u('the module entry word',
  bus='READ', fc='PROG', asel='T1', bytes=2)
u('... into xw',
  asrc='RDATA', alu='A', dst='XW', size='WORD', next='callm_frame_at')

label('rtm_type1')
# UM 9.8.2: "the processor reads the access level, condition codes, PC, saved
# module data area pointer, and saved stack pointer from the module stack frame.
# The access level is written to the DAL for validation by external hardware;
# the processor then reads the access status to check the validation. If ... the
# access status is zero, ... the processor takes a format error exception. No
# visible processor registers are changed."
u('the saved access level, to DAL at $0C. The frame\'s word was moved up by '
  'sixteen, so it is bits 23:16 of T0 and SWAP brings it down',
  bus='WRITE', fc='CPU', bytes=1, cpuspace='ACCESS', vec=0x0C,
  asrc='T0', alu='SWAP')
u('a bus error is a format error',
  seq='COND', cond='BERR', next='exc_format')
u('the access status at $04',
  bus='READ', fc='CPU', bytes=1, cpuspace='ACCESS', vec=0x04)
u('... refused with a bus error',
  seq='COND', cond='BERR', next='exc_format')
u('... held',
  asrc='RDATA', alu='A', dst='T2', size='LONG')
u('refused: a format error, and nothing has changed',
  seq='COND', cond='ASTAT_BAD', next='exc_format')
# The stack comes back from the frame's +$14 and not from the frame base: a
# type $01 call may have moved it, and "the argument count is added to the new
# stack pointer value".
u('+$04: the argument count',
  asrc='T3', bsrc='FOUR', alu='ADD', dst='T1', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T1', bytes=2)
u('... held',
  asrc='RDATA', alu='A', dst='T1', size='LONG')
u('+$14: the saved stack pointer',
  asrc='T3', bsrc='TWELVE', alu='ADD', dst='T2', size='LONG')
u('... eight more',
  asrc='T2', bsrc='EIGHT', alu='ADD', dst='T2', size='LONG')
u('read it',
  bus='READ', fc='DATA', asel='T2', bytes=4)
u('... plus the arguments is where the stack goes back to',
  asrc='RDATA', bsrc='T1', alu='ADD', dst='T1', size='LONG',
  next='rtm_restore_rest')


# RTM is CALLM's encoding with a data or address register as the effective
# address, which CALLM cannot use, so it is claimed first -- PRM 8.
opcode('000001101100----', 'rtm',   'RTM Rn')
opcode('0000011011------', 'callm', 'CALLM #n,<ea>')

# ==========================================================================
# MOVEC -- PRM 6
#
# "This is always a 32-bit transfer, even though the control register may be
# implemented with fewer bits." The direction is bit 0 of the opcode and
# everything else is in the extension word.
#
# MOVEC is privileged, and a control register code the MC68020 does not have is
# an illegal instruction -- UM 6.1.5, "a MOVEC instruction with an undefined
# register specification field in the first extension word". The check reads
# stage C on the microword that latches it into XW, so it costs no clock.
# ==========================================================================
label('movec_to_gen')
u('MOVEC is privileged -- PRM 6, "if supervisor state then ... else TRAP"',
  seq='COND', cond='USER', next='exc_priv')
u('the extension word names both registers -- and one this part does not '
  'have is an illegal instruction, UM 6.1.5, tested on stage C as it is taken',
  asrc='STG_C', alu='A', dst='XW', size='WORD', pf='CONSUME',
  seq='COND', cond='CREGBADC', next='exc_illegal')
u('the control register into the general one',
  asrc='CREG', alu='A', dst='XREG', size='LONG', pf='ADV', seq='DECODE')

label('movec_to_ctl')
u('MOVEC is privileged -- PRM 6, "if supervisor state then ... else TRAP"',
  seq='COND', cond='USER', next='exc_priv')
u('the extension word names both registers -- and one this part does not '
  'have is an illegal instruction, UM 6.1.5, tested on stage C as it is taken',
  asrc='STG_C', alu='A', dst='XW', size='WORD', pf='CONSUME',
  seq='COND', cond='CREGBADC', next='exc_illegal')
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


def exc_next(stem, vec, vecsrc='VECOFF', ccr='NONE'):
    """Format $2: the next instruction, and this one at +$08.

    `ccr` is what the instruction leaves in the codes before the frame copies
    the status register -- the zero divide's, below."""
    label(stem)
    u('the vector offset',
      asrc=vecsrc, alu='A', dst='T0', size='LONG', vec=vec, ccr=ccr)
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
# PRM 4, DIVU and DIVS: "C -- Always cleared", with no exception for a zero
# divisor; N, Z and V are undefined then, and are cleared too. X is untouched.
exc_next('exc_divzero',   5, ccr='CLRNZVC')

# TRAP #n. PRM 4: vector 32 + n, and the frame carries the address of the next
# instruction, which for a one-word instruction is simply the word after it.
label('trap_n')
u('the vector offset: 32 plus the four bits in the opcode, times four',
  asrc='TRAPVEC', alu='A', dst='T0', size='LONG')
u('and the frame carries the address of the next instruction',
  asrc='PC_C', alu='A', dst='T1', size='LONG', next='exc_f0')

opcode('010011100100----', 'trap_n', 'TRAP #n')
opcode('1010------------', 'exc_line_a', 'an A-line instruction')
# The F-line patterns are with the coprocessor interface, at the end.


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
u('a coprocessor midinstruction frame? UM 7.4.19',
  seq='COND', cond='FMT9', next='rte_nine')
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
# What each fault frame's builder writes and each RTE reads back, by offset:
# assemble.py's check_frame_fields holds them to frames.INTERNAL.
FRAME_WRITES = {}
FRAME_READS = {}


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
            # The primitive a bus error interrupted: what the rest of its
            # transfer reads its length and direction from, and which a
            # handler's own coprocessor instructions have since overwritten.
            (0x4A, 2, 'CPRIM'),
        ]

    FRAME_READS[stem] = [(off, n, dst) for off, n, dst in fields if n]
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
    u('+$00: the status register, written BEFORE anything sets S -- and so '
      'to supervisor data by name, since DATA would still be the user\'s space',
      bus='WRITE', fc='SDATA', asel='EA_SAVE', asrc='SR', alu='A', bytes=2)
    u('supervisor, and no tracing of the handler -- UM 6.1 step one',
      asrc='SR', alu='EXCSR', dst='SR', size='WORD')
    u('and the stack pointer is the frame base, which is now a supervisor one',
      asrc='EA_SAVE', alu='A', dst='SP', size='LONG')

    # (offset, bytes, source) in ascending order. The offsets are UM table 6-5
    # for the named fields and doc/checkpoint.md for the rest;
    # assemble.py's check_frame_fields proves the set against frames.py.
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
            (0x4A, 2, 'CPRIM'),
        ]
        # UM table 6-5 makes the frame forty-six words whatever is in them. The
        # words this design has no use for are written as zero rather than left
        # as whatever the handler's stack held: a frame is copied and restored
        # by a task switch, and one that carries the previous owner's stack is
        # a leak with no upside.
        fields += [(off, 4, 'ZERO') for off in range(0x4C, 0x5C, 4)]
    else:
        # UM table 6-5 makes the short frame sixteen words. Its last two are
        # internal and this design has nothing to put in them: a format $A frame
        # is taken at an instruction boundary, where every register the long
        # frame's +$36 carries is either about to be set by the decode that
        # resumes or is already clear.
        fields += [(0x1C, 4, 'ZERO')]

    FRAME_WRITES[stem] = list(fields)
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


# UM table 6-5 gives the short frame to a fault taken at an instruction
# boundary. This design never builds it: a prefetch fault is taken by the
# instruction's own last microword, which RTE re-executes, and that microword
# may read any working register -- which only the long frame carries. RTE still
# takes a short frame apart. doc/divergences.md.
fault_frame('exc_fault_long', True)
# ==========================================================================
# THE COPROCESSOR INTERFACE -- UM section 7, M13
#
# A coprocessor instruction is a conversation. The processor starts it by
# writing to one of the coprocessor's interface registers (a CIR) in CPU space
# type $2, then reads the response CIR and does what the primitive it finds
# there says -- fetch an operand, evaluate an effective address, take an
# exception -- until a primitive releases it. doc/coprocessor.md has the whole
# protocol as built; this is the microcode of it.
#
# Four things hold the conversation's state, and they are the four the
# midinstruction frame of UM figure 7-43 saves, which is what lets an interrupt
# be taken in the middle of it:
#
#   the program counter    pc_d. Stage D is the F-line operation word for the
#                          whole instruction and nothing advances it.
#   the scanPC             the address of stage C. Every word the instruction
#                          reads from the stream is CONSUMEd, which moves it on,
#                          and UM 7.4.17 writes it by refilling the queue.
#   the effective address  EA, for the write-to-previously-evaluated-EA
#                          primitive.
#   the operation word     stage D.
#
# Nothing else lives across two primitives. Within one, T0-T3 are scratch, and
# the primitive itself is in cprim, which the long fault frame carries: a bus
# error on a CIR access or on an operand is an ordinary bus error (UM 7.5.2.8).
# ==========================================================================

# The interface registers -- UM figure 7-5.
CIR_RESPONSE, CIR_CONTROL, CIR_SAVE, CIR_RESTORE = 0x00, 0x02, 0x04, 0x06
CIR_OPWORD, CIR_COMMAND, CIR_CONDITION = 0x08, 0x0A, 0x0E
CIR_OPERAND, CIR_REGSEL, CIR_IADDR, CIR_OADDR = 0x10, 0x14, 0x18, 0x1C


def cir_read(comment, off, nbytes, init=False, **kw):
    u(comment, bus='READ', fc='CPU', cpuspace='CPINIT' if init else 'COPROC',
      vec=off, bytes=nbytes, **kw)


def cir_write(comment, off, nbytes, init=False, **kw):
    kw.setdefault('alu', 'A')
    u(comment, bus='WRITE', fc='CPU', cpuspace='CPINIT' if init else 'COPROC',
      vec=off, bytes=nbytes, **kw)


# --------------------------------------------------------------------------
# The opcode patterns -- UM figures 7-6 to 7-17 and PRM 8.
#
# Bits 11:9 are the CpID and bits 8:6 the type. A CpID of zero is never a
# coprocessor (UM 7.1.3), types 110 and 111 never are (UM 7.5.2.2), and an
# effective address a form does not allow is an F-line exception with no CIR
# access -- "an operation word ... that does not map to one of the valid
# coprocessor instructions". All of those are the catch-all at the end.
# --------------------------------------------------------------------------
opcode('1111000---------', 'exc_line_f', 'F-line, CpID 0')
opcode('1111---000------', 'cp_gen',     'cpGEN')
opcode('1111---001001---', 'cp_dbcc',    'cpDBcc')
opcode('1111---001111010', 'cp_trapcc',  'cpTRAPcc.W')
opcode('1111---001111011', 'cp_trapcc',  'cpTRAPcc.L')
opcode('1111---001111100', 'cp_trapcc',  'cpTRAPcc')
# cpScc takes a data alterable effective address (PRM 4): not An -- that slot is
# cpDBcc -- and nothing in mode 111 beyond the two absolute forms.
opcode('1111---001111101', 'exc_line_f', 'cpScc, not data alterable')
opcode('1111---00111111-', 'exc_line_f', 'cpScc, not data alterable')
opcode('1111---001------', 'cp_scc',     'cpScc')
opcode('1111---01-------', 'cp_bcc',     'cpBcc')
# UM 7.2.3.3.1: cpSAVE takes the control alterable modes and -(An).
for _m in ('010---', '100---', '101---', '110---', '11100-'):
    opcode('1111---100' + _m, 'cp_save', 'cpSAVE')
# UM 7.2.3.4.1: "all memory addressing modes except the predecrement". PRM 6's
# text says "only postincrement or control", and its table then lists the
# immediate as well -- doc/manual-contradictions.md. Two of the three allow it:
# the state frame is then in the instruction stream.
for _m in ('010---', '011---', '101---', '110---', '11100-', '11101-'):
    opcode('1111---101' + _m, 'cp_restore', 'cpRESTORE')
opcode('1111---101111100', 'cp_restore_imm', 'cpRESTORE #<frame>')
opcode('1111------------', 'exc_line_f', 'an F-line instruction')


# --------------------------------------------------------------------------
# The dialogue -- UM 7.2.1.2, 7.2.2 and 7.4
# --------------------------------------------------------------------------
label('cp_resp')
cir_read('read the response CIR -- UM 7.3.1 -- and hold the primitive while it '
         'is served', CIR_RESPONSE, 2,
         asrc='RDATA', alu='A', dst='CPRIM', size='WORD')
label('cp_dispatch')
u('what the primitive asks for -- the decoder, UM 7.4 and table 7-6. A '
  'primitive with PC set goes to cp_passpc first',
  seq='CPDEC')

# UM 7.4.2: the program counter goes to the instruction address CIR "as the
# first operation in servicing the primitive request" -- before an exception
# it may lead to, too. Then the bit is cleared, so that the decoder, asked
# again, serves the rest; cprim is in the fault frame, so a fault on either
# access resumes the right half.
label('cp_passpc')
cir_write('the address of the F-line operation word', CIR_IADDR, 4,
          asrc='PC_D')
u('... and the program counter has been passed',
  asrc='CPRIM', bsrc='PCBIT', alu='EOR', dst='CPRIM', size='WORD',
  next='cp_dispatch')

# After a primitive that allows come-again. CA set: read the response CIR
# again. CA clear: a general instruction is released -- the decoder refuses CA
# clear for these in a conditional one -- unless a trace is pending, in which
# case UM 7.5.2.5 keeps reading until the coprocessor says it has finished.
label('cp_next')
u('come again?', seq='COND', cond='CPCA', next='cp_resp')
u('a trace pending holds the dialogue open -- UM 7.5.2.5',
  seq='COND', cond='TRACEPEND', next='cp_resp')
label('cp_done')
u('the coprocessor has let go: the scanPC is the next instruction -- UM 7.4.1',
  pf='ADV', seq='DECODE')

# The two aborts. UM 7.3.2: the processor writes the abort mask to the control
# CIR before an F-line or privilege exception a primitive caused, and before a
# format error; the exception acknowledge before taking one a primitive asked
# for. The fourteen other bits "are undefined": they are written as zero.
label('cp_fline_abort')
cir_write('abort -- UM 7.3.2', CIR_CONTROL, 2, bsrc='ONE', alu='B',
          next='exc_line_f')

label('cp_priv_abort')
cir_write('abort -- UM 7.4.5', CIR_CONTROL, 2, bsrc='ONE', alu='B',
          next='exc_priv')

label('cp_format_abort')
cir_write('abort -- UM 7.2.3.2.3', CIR_CONTROL, 2, bsrc='ONE', alu='B',
          next='exc_format')

# A protocol violation the processor detects -- UM 7.5.2.1. Not notified to the
# coprocessor; the midinstruction frame, vector 13, and RTE reads the response
# CIR again.
label('cp_protocol')
u('vector 13', asrc='VECOFF', alu='A', dst='T0', size='LONG', vec=13,
  next='exc_cp9')

# ---- Busy -- UM 7.4.3 ------------------------------------------------------
# "It services pending interrupts using a preinstruction exception stack frame
# ... then restarts the general or conditional coprocessor instruction". Going
# back to the operation word IS that: the decode arm takes a pending interrupt
# at the boundary with this instruction's own address in the frame, and then
# decodes it afresh. It was never executed, so it is not traced.
label('cp_busy')
u('start again from the operation word',
  asrc='PC_D', alu='A', pf='FLUSH', notrace=1)
u('... which is an instruction boundary',
  seq='DECODE')

# ---- Null -- UM 7.4.4 and table 7-3 ------------------------------------------
# The null primitive is decoded completely -- CA, IA, PF and the category are
# all the decoder's inputs -- so only the two questions that are not about the
# primitive are asked here: a trace pending, an interrupt pending.
label('cp_null_nf')
u('not finished: the dialogue only goes on if a trace is pending -- UM 7.5.2.5',
  seq='COND', cond='TRACEPEND', next='cp_null_ca')
u('... and none is', next='cp_done')

label('cp_null_ca')
u('interrupts allowed?', seq='COND', cond='CPB8', next='cp_null_ia')
u('no: read the response again at once', next='cp_resp')

label('cp_null_ia')
u('one pending? UM 7.5.2.6: serviced with the midinstruction frame',
  seq='COND', cond='IRQPEND', next='exc_cp_irq')
u('none', next='cp_resp')

# ---- Supervisor check -- UM 7.4.5 --------------------------------------------
label('cp_svchk')
u('at the user level the instruction is aborted',
  seq='COND', cond='USER', next='cp_priv_abort')
u('at the supervisor level the response is read again', next='cp_resp')

# ---- Transfer operation word -- UM 7.4.6 --------------------------------------
label('cp_opword')
cir_write('the F-line operation word to the operation word CIR', CIR_OPWORD, 2,
          asrc='STG_D', next='cp_next')

# ---- Transfer from instruction stream -- UM 7.4.7 -----------------------------
# The length is even -- the decoder refuses an odd one -- so what is left after
# the long words is nothing or one word.
label('cp_stream')
u('the length', asrc='CPLEN', alu='A', dst='T1')
label('cp_stream_loop')
u('four or more to go?', seq='COND', cond='T1GE4', next='cp_stream_long')
u('none?', seq='COND', cond='T1ZERO', next='cp_next')
cir_write('the last word -- "using a word write to the operand CIR"',
          CIR_OPERAND, 2, asrc='STG_C', pf='CONSUME', next='cp_next')
label('cp_stream_long')
u('two words of the stream', asrc='STG_C_HI', alu='A', dst='T0',
  pf='CONSUME')
u('... as one long word', asrc='T0', bsrc='STG_C_U', alu='OR', dst='T0',
  pf='CONSUME')
cir_write('to the operand CIR', CIR_OPERAND, 4, asrc='T0')
u('four fewer', asrc='T1', bsrc='FOUR', alu='SUB', dst='T1',
  next='cp_stream_loop')


# ---- Moving an operand between memory and the operand CIR ---------------------
# UM 7.3.8 and the primitives that use it: long words "whenever possible", the
# remainder "using a one-, two-, or three-byte transfer as required", and every
# part aligned to the most significant byte of the operand CIR -- which is what
# a transfer of n bytes to offset $10 is, since the bus unit puts an n-byte
# operand on the top n lanes of a long-word aligned address.
#
# T2 is the address and T1 the count. `fc` is the memory side's address space;
# `out` is where the loop goes when the count reaches zero.
def xfer_loop(stem, to_cp, fc, out):
    label(stem)
    u('four or more to go?', seq='COND', cond='T1GE4', next=stem + '_4')
    u('none?', seq='COND', cond='T1ZERO', next=out)
    u('two or three?', seq='COND', cond='T1B1', next=stem + '_23')
    _xfer_part(stem + '_1', 1, to_cp, fc, out)
    label(stem + '_23')
    u('three?', seq='COND', cond='T1B0', next=stem + '_3')
    _xfer_part(stem + '_2', 2, to_cp, fc, out)
    label(stem + '_3')
    _xfer_part(stem + '_3x', 3, to_cp, fc, out)
    label(stem + '_4')
    _xfer_part(stem + '_4x', 4, to_cp, fc, stem)


def _xfer_part(stem, n, to_cp, fc, out):
    step = {1: 'ONE', 2: 'TWO', 3: 'THREE', 4: 'FOUR'}[n]
    if to_cp:
        u('%d byte(s) from memory, and the count goes down' % n,
          bus='READ', fc=fc, asel='T2', bytes=n,
          asrc='T1', bsrc=step, alu='SUB', dst='T1')
        cir_write('... to the operand CIR', CIR_OPERAND, n, asrc='RDATA')
    else:
        cir_read('%d byte(s) from the operand CIR, and the count goes down' % n,
                 CIR_OPERAND, n, asrc='T1', bsrc=step, alu='SUB', dst='T1')
        u('... to memory',
          bus='WRITE', fc=fc, asel='T2', bytes=n, asrc='RDATA', alu='A')
    u('the address moves on', asrc='T2', bsrc=step, alu='ADD', dst='T2',
      next=out)


# ---- Evaluate and transfer effective address -- UM 7.4.8 ----------------------
label('cp_evalea')
u('only a control alterable address is evaluated',
  seq='COND', cond='EACTLALT', next='cp_evalea_go')
u('... anything else is aborted as an F-line exception', next='cp_fline_abort')
label('cp_evalea_go')
u('evaluate it', call=1, seq='EAMODE')
cir_write('to the operand address CIR', CIR_OADDR, 4, asrc='EA',
          next='cp_next')

# ---- Evaluate effective address and transfer data -- UM 7.4.9 -----------------
label('cp_eadata')
u('in the class the primitive names? table 7-4',
  seq='COND', cond='CPEAOK', next='cp_eadata_ok')
u('no: aborted, and an F-line exception', next='cp_fline_abort')
label('cp_eadata_ok')
u('a data register?', seq='COND', cond='EADN', next='cp_ead_dn')
u('an address register?', seq='COND', cond='EAAN', next='cp_ead_an')
u('an immediate?', seq='COND', cond='EAIMM', next='cp_ead_imm')
u('(An)+?', seq='COND', cond='EAPOST', next='cp_ead_post')
u('-(An)?', seq='COND', cond='EAPRE', next='cp_ead_pre')
u('memory, the other modes: to it?', seq='COND', cond='CPDR',
  next='cp_ead_wr')
label('cp_ead_calc')
u('evaluate it', call=1, seq='EAMODE')
label('cp_ead_mem')
u('the operand begins at the effective address', asrc='EA', alu='A',
  dst='T2')
u('... and is as long as the primitive says', asrc='CPLEN', alu='A',
  dst='T1')
u('which way?', seq='COND', cond='CPDR', next='cp_ead_out')
xfer_loop('cp_ead_in', True, 'EASP', 'cp_next')
label('cp_ead_out')
xfer_loop('cp_ead_outl', False, 'EASP', 'cp_next')

label('cp_ead_wr')
u('UM table 7-6: a write to an address that is not alterable is a protocol '
  'violation, even in a class the primitive declared',
  seq='COND', cond='EAUNALT', next='cp_protocol')
u('otherwise as for a read', next='cp_ead_calc')

# (An)+ and -(An) step the register by the operand's length, which may be
# anything up to 255 -- so not by the operand SIZE the shared routines use.
label('cp_ead_post')
u('the address register is the address', asrc='AREG', alu='A', dst='EA')
u('... and steps on by the length, two for a byte through A7',
  asrc='AREG', bsrc='CPSTEP', alu='ADD', dst='AREG_EA_ADDR',
  next='cp_ead_mem')
label('cp_ead_pre')
u('the address register steps back by the length first',
  asrc='AREG', bsrc='CPSTEP', alu='SUB', dst='AREG_EA_ADDR')
u('... and that is the address', asrc='AREG', alu='A', dst='EA',
  next='cp_ead_mem')

# A register is one, two or four bytes -- UM table 7-6 -- and the operand
# size follows the length.
label('cp_ead_dn')
u('one, two or four bytes?', seq='COND', cond='CPLEN124', next='cp_ead_dn_ok')
u('no: a protocol violation', next='cp_protocol')
label('cp_ead_dn_ok')
u('which way?', seq='COND', cond='CPDR', next='cp_ead_dn_in')
cir_write('the data register to the operand CIR', CIR_OPERAND, 0,
          asrc='DREG', szsel='CPLEN', next='cp_next')
label('cp_ead_dn_in')
cir_read('the operand CIR ...', CIR_OPERAND, 0, szsel='CPLEN')
u('... into the low part of the data register -- UM 7.4.9',
  asrc='RDATA', alu='A', dst='DREG_R', szsel='CPLEN', next='cp_next')

label('cp_ead_an')
u('one, two or four bytes?', seq='COND', cond='CPLEN124', next='cp_ead_an_ok')
u('no: a protocol violation', next='cp_protocol')
label('cp_ead_an_ok')
u('which way?', seq='COND', cond='CPDR', next='cp_ead_an_in')
cir_write('the address register to the operand CIR', CIR_OPERAND, 0,
          asrc='AREG', szsel='CPLEN', next='cp_next')
label('cp_ead_an_in')
cir_read('the operand CIR ...', CIR_OPERAND, 0, szsel='CPLEN')
u('... sign extended into the whole address register -- UM 7.4.9',
  asrc='RDATA', alu='A', dst='AREG_R', szsel='CPLEN', next='cp_next')

# UM 7.4.9: "the length of an immediate operand must be one byte or an even
# number of bytes (less than 256), and the direction of transfer must be to the
# coprocessor". A byte immediate occupies a word, the byte in its low half.
label('cp_ead_imm')
u('to the coprocessor only', seq='COND', cond='CPDR', next='cp_protocol')
u('one less than the length', asrc='CPLEN', bsrc='ONE', alu='SUB', dst='T1')
u('a byte?', seq='COND', cond='T1ZERO', next='cp_ead_imm_b')
u('the length', asrc='CPLEN', alu='A', dst='T1')
u('odd, and not one: a protocol violation', seq='COND', cond='T1B0',
  next='cp_protocol')
u('even: the words of the stream, exactly as the stream primitive moves them',
  next='cp_stream_loop')
label('cp_ead_imm_b')
cir_write('the low byte of the immediate word', CIR_OPERAND, 1,
          asrc='STG_C', pf='CONSUME', next='cp_next')

# ---- Write to previously evaluated effective address -- UM 7.4.10 --------------
# "The function code ... indicates either supervisor or user data space", and
# the address is used exactly as it was left: no register is stepped.
label('cp_wprev')
u('the address the last evaluation left', asrc='EA', alu='A', dst='T2')
u('the length', asrc='CPLEN', alu='A', dst='T1')
xfer_loop('cp_wprev_x', False, 'DATA', 'cp_next')

# ---- Take address and transfer data -- UM 7.4.11 ------------------------------
label('cp_takeaddr')
cir_read('the address, from the operand address CIR', CIR_OADDR, 4)
u('... held', asrc='RDATA', alu='A', dst='T2')
u('the length', asrc='CPLEN', alu='A', dst='T1')
u('which way?', seq='COND', cond='CPDR', next='cp_takeaddr_out')
xfer_loop('cp_takeaddr_in', True, 'DATA', 'cp_next')
label('cp_takeaddr_out')
xfer_loop('cp_takeaddr_o', False, 'DATA', 'cp_next')

# ---- Transfer to/from top of stack -- UM 7.4.12 --------------------------------
# One, two or four bytes, through the ACTIVE stack pointer: (A7)+ to the
# coprocessor, -(A7) from it, and a byte steps it by two.
label('cp_tos')
u('one, two or four bytes?', seq='COND', cond='CPLEN124', next='cp_tos_ok')
u('no: a protocol violation', next='cp_protocol')
label('cp_tos_ok')
u('the length', asrc='CPLEN', alu='A', dst='T1')
u('which way?', seq='COND', cond='CPDR', next='cp_tos_out')
u('the operand is at the top of the stack', asrc='SP', alu='A', dst='T2')
u('(A7)+: four?', seq='COND', cond='T1GE4', next='cp_tos_in4')
u('... or two, which a byte also takes',
  asrc='SP', bsrc='TWO', alu='ADD', dst='SP', next='cp_tos_in_go')
label('cp_tos_in4')
u('... four', asrc='SP', bsrc='FOUR', alu='ADD', dst='SP')
label('cp_tos_in_go')
xfer_loop('cp_tos_in', True, 'DATA', 'cp_next')

label('cp_tos_out')
u('-(A7): four?', seq='COND', cond='T1GE4', next='cp_tos_out4')
u('... or two, which a byte also takes',
  asrc='SP', bsrc='TWO', alu='SUB', dst='SP', next='cp_tos_out_go')
label('cp_tos_out4')
u('... four', asrc='SP', bsrc='FOUR', alu='SUB', dst='SP')
label('cp_tos_out_go')
u('the operand goes where the stack pointer now is', asrc='SP', alu='A',
  dst='T2')
xfer_loop('cp_tos_o', False, 'DATA', 'cp_next')

# ---- Transfer single main processor register -- UM 7.4.13 ---------------------
label('cp_sreg')
u('which way?', seq='COND', cond='CPDR', next='cp_sreg_in')
cir_write('the register to the operand CIR', CIR_OPERAND, 4, asrc='CPREG',
          next='cp_next')
label('cp_sreg_in')
cir_read('the operand CIR ...', CIR_OPERAND, 4)
u('... into the register', asrc='RDATA', alu='A', dst='CPREG',
  next='cp_next')

# ---- Transfer main processor control register -- UM 7.4.14 ---------------------
# The select code goes through XW, which is where MOVEC keeps its own, so that
# both reach the control registers through the same multiplexer.
label('cp_creg')
cir_read('the control register select code, from the register select CIR',
         CIR_REGSEL, 2)
u('... held where MOVEC keeps its own', asrc='RDATA', alu='A', dst='XW',
  size='WORD')
u('one of table 7-5?', seq='COND', cond='CREGBAD', next='cp_protocol')
u('which way?', seq='COND', cond='CPDR', next='cp_creg_in')
cir_write('the control register to the operand CIR', CIR_OPERAND, 4,
          asrc='CREG', next='cp_next')
label('cp_creg_in')
cir_read('the operand CIR ...', CIR_OPERAND, 4)
u('... into the control register', asrc='RDATA', alu='A', dst='CREG',
  next='cp_next')

# ---- Transfer multiple main processor registers -- UM 7.4.15 ------------------
# "The selected registers are transferred in the order D7-D0 and then A7-A0",
# with bit 0 of the mask selecting D0. The same walk as MOVEM's control form,
# which takes them D0 first; doc/manual-contradictions.md says why that is the
# reading taken.
label('cp_mreg')
cir_read('the register select mask', CIR_REGSEL, 2)
u('... into T0', asrc='RDATA', alu='A', dst='T0', size='WORD')
u('none selected?', seq='COND', cond='EMPTY', next='cp_next')
label('cp_mreg_x')
u('which way?', seq='COND', cond='CPDR', next='cp_mreg_in')
cir_write('the lowest register left in the mask to the operand CIR, and it '
          'leaves the mask', CIR_OPERAND, 4, asrc='REGN', cnt='CLRLOW',
          next='cp_mreg_nx')
label('cp_mreg_in')
cir_read('the operand CIR into the lowest register left, which leaves the '
         'mask', CIR_OPERAND, 4, asrc='RDATA', alu='A', dst='REGN',
         cnt='CLRLOW')
label('cp_mreg_nx')
u('any left?', seq='COND', cond='NOTEMPTY', next='cp_mreg_x')
u('no', next='cp_next')

# ---- Transfer multiple coprocessor registers -- UM 7.4.16 ---------------------
# One operand for every set bit of the mask, each LENGTH bytes. The address
# steps on through them; -(An) walks the operands down and the bytes of each up,
# figure 7-38.
label('cp_mcreg')
u('an address the direction allows?', seq='COND', cond='CPMEAOK',
  next='cp_mcreg_ok')
u('no: aborted, and an F-line exception', next='cp_fline_abort')
label('cp_mcreg_ok')
u('(An)+?', seq='COND', cond='EAPOST', next='cp_mcreg_an')
u('-(An)?', seq='COND', cond='EAPRE', next='cp_mcreg_an')
u('a control address', call=1, seq='EAMODE')
u('... which the operands are walked from', asrc='EA', alu='A', dst='T2',
  next='cp_mcreg_mask')
label('cp_mcreg_an')
u('the address register', asrc='AREG', alu='A', dst='EA')
u('... is where they start', asrc='AREG', alu='A', dst='T2')
label('cp_mcreg_mask')
cir_read('the register select mask', CIR_REGSEL, 2)
u('... into T0 -- its ones count the operands', asrc='RDATA', alu='A',
  dst='T0', size='WORD')
u('none?', seq='COND', cond='EMPTY', next='cp_next')
label('cp_mcreg_op')
u('one operand\'s worth', asrc='CPLEN', alu='A', dst='T1')
u('-(An)?', seq='COND', cond='EAPRE', next='cp_mcreg_pre')
u('which way?', seq='COND', cond='CPDR', next='cp_mcreg_out')
xfer_loop('cp_mcreg_in', True, 'EASP', 'cp_mcreg_post')
label('cp_mcreg_out')
xfer_loop('cp_mcreg_o', False, 'EASP', 'cp_mcreg_post')
# (An)+: the register follows the address, "incremented by the size of an
# operand after each operand is transferred".
label('cp_mcreg_post')
u('(An)+?', seq='COND', cond='EAPOST', next='cp_mcreg_upd')
u('no', next='cp_mcreg_nx')
label('cp_mcreg_upd')
u('the address register follows', asrc='T2', alu='A', dst='AREG_EA_ADDR')
label('cp_mcreg_nx')
u('one operand fewer to go', cnt='CLRLOW')
u('any left?', seq='COND', cond='NOTEMPTY', next='cp_mcreg_op')
u('no', next='cp_next')
# -(An): "the processor decrements the address register by the size of an
# operand before the operand is transferred", and then writes its bytes upwards.
label('cp_mcreg_pre')
u('the address register steps down by one operand',
  asrc='AREG', bsrc='CPLEN', alu='SUB', dst='AREG_EA_ADDR')
u('... and the operand is written up from there', asrc='AREG', alu='A',
  dst='T2')
xfer_loop('cp_mcreg_pr', False, 'EASP', 'cp_mcreg_nx')


# ---- The common shapes, dispatched by the decoder ------------------------------
# The decoder sees the effective address (cpprim's `ea`) and the length, so the
# shapes an MC68881 asks for most -- a control register, four bytes; a register
# of the extended format, twelve -- go straight to handlers with no questions
# and no loop. Everything else still goes through the general ones above.

# Evaluate effective address and transfer data, four bytes to the coprocessor
# from memory -- FMOVE <ea>,FPcr.
label('cp_ead_rd4')
u('evaluate it', call=1, seq='EAMODE')
label('cp_ead_rd4_go')
u('four bytes from memory', bus='READ', fc='EASP', asel='EA', bytes=4)
cir_write('... to the operand CIR', CIR_OPERAND, 4, asrc='RDATA', next='cp_next')
label('cp_ead_post4')
u('the address register is the address', asrc='AREG', alu='A', dst='EA')
u('... and steps on by four', asrc='AREG', bsrc='CPSTEP', alu='ADD',
  dst='AREG_EA_ADDR', next='cp_ead_rd4_go')
label('cp_ead_pre4')
u('the address register steps back by four first',
  asrc='AREG', bsrc='CPSTEP', alu='SUB', dst='AREG_EA_ADDR')
u('... and that is the address', asrc='AREG', alu='A', dst='EA',
  next='cp_ead_rd4_go')


# Transfer multiple coprocessor registers, twelve bytes each -- FMOVEM.X. One
# loop per direction and addressing shape, each register three long words.
# T0 is the mask, T2 the address; from the coprocessor the write's ALU carries
# its data, so the address steps on the CIR read, into T3 and T2 by turns.
def _m12_mask(stem):
    label(stem + '_mask')
    cir_read('the register select mask, into T0 -- its ones count the operands',
             CIR_REGSEL, 2, asrc='RDATA', alu='A', dst='T0', size='WORD')
    u('none?', seq='COND', cond='EMPTY', next='cp_next')


label('cp_m12in_ctl')
u('a control address', call=1, seq='EAMODE')
u('... which the operands are walked from', asrc='EA', alu='A', dst='T2',
  next='cp_m12in_mask')
label('cp_m12in_post')
u('the address register', asrc='AREG', alu='A', dst='EA')
u('... is where they start', asrc='AREG', alu='A', dst='T2')
_m12_mask('cp_m12in')
label('cp_m12in_op')
for _k in range(3):
    u('four bytes of the register from memory, and the address moves on',
      bus='READ', fc='EASP', asel='T2', bytes=4,
      asrc='T2', bsrc='FOUR', alu='ADD', dst='T2')
    if _k < 2:
        cir_write('... to the operand CIR', CIR_OPERAND, 4, asrc='RDATA')
    else:
        cir_write('... to the operand CIR, and one register fewer to go',
                  CIR_OPERAND, 4, asrc='RDATA', cnt='CLRLOW')
u('(An)+: "incremented by the size of an operand after each operand" -- '
  'harmless for a control address, whose register is not written',
  seq='COND', cond='EAPOST', next='cp_m12in_upd')
u('any left?', seq='COND', cond='NOTEMPTY', next='cp_m12in_op')
u('no', next='cp_next')
label('cp_m12in_upd')
u('the address register follows, and any left?',
  asrc='T2', alu='A', dst='AREG_EA_ADDR',
  seq='COND', cond='NOTEMPTY', next='cp_m12in_op')
u('no', next='cp_next')


def _m12_out(first_from):
    """Three long words from the operand CIR to T2, T2+4, T2+8, the address
    stepping on the reads into T3 and T2 by turns; T3 ends one register on."""
    cir_read('four bytes of the register, and the address after them',
             CIR_OPERAND, 4, asrc='T2', bsrc='FOUR', alu='ADD', dst='T3')
    u('... to memory', bus='WRITE', fc='EASP', asel='T2', bytes=4,
      asrc='RDATA', alu='A')
    cir_read('four more, and the address after them',
             CIR_OPERAND, 4, asrc='T3', bsrc='FOUR', alu='ADD', dst='T2')
    u('... to memory', bus='WRITE', fc='EASP', asel='T3', bytes=4,
      asrc='RDATA', alu='A')
    cir_read('the last four, and the address of the next register',
             CIR_OPERAND, 4, asrc='T2', bsrc='FOUR', alu='ADD', dst='T3')
    u('... to memory, and one register fewer to go',
      bus='WRITE', fc='EASP', asel='T2', bytes=4, asrc='RDATA', alu='A',
      cnt='CLRLOW')


# Evaluate effective address and transfer data, twelve bytes FROM the
# coprocessor to memory -- FMOVEM of the three control registers.
label('cp_ead_wr12')
u('UM table 7-6: not alterable is a protocol violation',
  seq='COND', cond='EAUNALT', next='cp_protocol')
u('evaluate it', call=1, seq='EAMODE')
u('... and the operand goes there', asrc='EA', alu='A', dst='T2')
_m12_out('T2')
u('all twelve bytes', next='cp_next')

label('cp_m12out_ctl')
u('a control alterable address', call=1, seq='EAMODE')
u('... which the operands are walked from', asrc='EA', alu='A', dst='T2',
  next='cp_m12out_mask')
_m12_mask('cp_m12out')
label('cp_m12out_op')
_m12_out('T2')
u('the next register\'s address, and any left?', asrc='T3', alu='A', dst='T2',
  seq='COND', cond='NOTEMPTY', next='cp_m12out_op')
u('no', next='cp_next')

# -(An): "the processor decrements the address register by the size of an
# operand before the operand is transferred", and writes its bytes upwards.
label('cp_m12pre')
u('the address register', asrc='AREG', alu='A', dst='EA')
_m12_mask('cp_m12pre')
label('cp_m12pre_op')
u('the address register steps down by one operand',
  asrc='AREG', bsrc='CPLEN', alu='SUB', dst='AREG_EA_ADDR')
u('... and the operand is written up from there', asrc='AREG', alu='A',
  dst='T2')
_m12_out('T2')
u('any left?', seq='COND', cond='NOTEMPTY', next='cp_m12pre_op')
u('no', next='cp_next')

# ---- Transfer status register and scanPC -- UM 7.4.17 --------------------------
label('cp_srpc')
u('which way?', seq='COND', cond='CPDR', next='cp_srpc_in')
u('the scanPC too?', seq='COND', cond='CPB8', next='cp_srpc_pc')
label('cp_srpc_sr')
cir_write('the status register to the operand CIR', CIR_OPERAND, 2,
          asrc='SR', next='cp_next')
label('cp_srpc_pc')
cir_write('the scanPC to the instruction address CIR, first', CIR_IADDR, 4,
          asrc='PC_C_RAW', next='cp_srpc_sr')
label('cp_srpc_in')
cir_read('the status register from the operand CIR ...', CIR_OPERAND, 2)
u('... into the status register', asrc='RDATA', alu='A', dst='SR',
  size='WORD')
u('the scanPC too?', seq='COND', cond='CPB8', next='cp_srpc_inpc')
u('no', next='cp_next')
label('cp_srpc_inpc')
cir_read('then the scanPC, from the instruction address CIR', CIR_IADDR, 4)
u('... and the queue is refilled from there -- in the space the new status '
  'register says',
  asrc='RDATA', alu='A', dst='SCANPC', next='cp_next')

# ---- Take pre-, mid- and postinstruction exception -- UM 7.4.18 to 7.4.20 ------
label('cp_takepre')
cir_write('acknowledge -- UM 7.3.2', CIR_CONTROL, 2, bsrc='TWO', alu='B')
u('the coprocessor\'s vector', asrc='CPVEC', alu='A', dst='T0')
u('figure 7-41: the four-word frame, with the address of the operation word, '
  'so that RTE starts the instruction again',
  asrc='PC_D', alu='A', dst='T1', size='LONG', next='exc_f0')

label('cp_takemid')
cir_write('acknowledge', CIR_CONTROL, 2, bsrc='TWO', alu='B')
u('the coprocessor\'s vector, and figure 7-43: the midinstruction frame',
  asrc='CPVEC', alu='A', dst='T0', next='exc_cp9')

label('cp_takepost')
cir_write('acknowledge', CIR_CONTROL, 2, bsrc='TWO', alu='B')
u('the coprocessor\'s vector', asrc='CPVEC', alu='A', dst='T0')
u('figure 7-45: the operation word\'s address at +$08 ...',
  asrc='PC_D', alu='A', dst='T2', size='LONG')
u('... and the scanPC as the program counter, "the address of the next '
  'instruction"',
  asrc='PC_C_RAW', alu='A', dst='T1', size='LONG', next='exc_f2')


# --------------------------------------------------------------------------
# The primitive patterns -- UM 7.4, 7.6 and table 7-6.
#
# Seventeen characters: the category (1 = conditional), CA, PC, then bits 13:8
# and the parameter byte. Ordered, first match wins, and everything not matched
# is a protocol violation -- which is what UM 7.6 makes of the encodings it
# leaves undefined ($00, $3F, $0B, $18-$1B, $1F, $28-$2B, $38-$3B in bits 13:8).
# --------------------------------------------------------------------------
def _prim(cat, ca, fn, par='--------'):
    assert len(fn) == 6 and len(par) == 8
    return cat + ca + '-' + fn + par


# PC set: the program counter first, whatever the primitive -- UM 7.4.2.
cpprim('--1--------------', 'cp_passpc', 'PC set: pass the program counter first')

# Refused in a conditional instruction: every primitive but null that allows
# come-again, with CA clear (the footnote to table 7-6) ...
for _fn in ('000111', '100111', '001111', '101111', '-00101', '-01110',
            '-01100', '-01101', '-00110'):
    cpprim(_prim('1', '0', _fn), 'cp_protocol', 'CA clear in a conditional')
# ... the supervisor check with bit 15 clear (UM 7.4.5) ...
cpprim(_prim('1', '0', '000100'), 'cp_protocol',
       'supervisor check, bit 15 clear, conditional')
# ... and the four that are general-category only, whatever CA says.
for _fn in ('001010', '-10---', '100000', '-00001', '-0001-'):
    cpprim(_prim('1', '-', _fn), 'cp_protocol', 'general only')
# Odd lengths where the manual forbids them.
cpprim(_prim('-', '-', '-01111', '-------1'), 'cp_protocol',
       'transfer from instruction stream, odd length')
cpprim(_prim('-', '-', '-00001', '-------1'), 'cp_protocol',
       'transfer multiple coprocessor registers, odd length')

cpprim(_prim('-', '-', '100100'), 'cp_busy',     'busy')
# The null primitive, every case -- UM 7.4.2 and 7.5.2.5.
cpprim(_prim('-', '1', '001000'), 'cp_resp',      'null, come again')
cpprim(_prim('-', '1', '001001'), 'cp_null_ca',   'null, come again, interrupts allowed')
cpprim(_prim('1', '0', '00100-'), 'cp_cond_done', 'null in a conditional: the verdict is in TF')
cpprim(_prim('0', '0', '00100-', '------1-'), 'cp_done', 'null, processing finished')
cpprim(_prim('0', '0', '00100-'), 'cp_null_nf',   'null, not finished')
cpprim(_prim('-', '-', '000100'), 'cp_svchk',    'supervisor check')
cpprim(_prim('-', '-', '-00111'), 'cp_opword',   'transfer operation word')
cpprim(_prim('-', '-', '-01111'), 'cp_stream',   'transfer from instruction stream')
cpprim(_prim('-', '-', '001010'), 'cp_evalea',   'evaluate and transfer effective address')
# Evaluate effective address and transfer data, by the effective address --
# table 7-4 and UM 7.4.9: outside its class an F-line exception; then a handler
# for each kind; four bytes from memory, the control registers, unrolled.
cpprim(_prim('-', '-', '-10---'), 'cp_fline_abort', 'eadata, outside its class', ea='0----')
cpprim(_prim('-', '-', '-10---'), 'cp_ead_dn',   'eadata, a data register',   ea='1-000')
cpprim(_prim('-', '-', '-10---'), 'cp_ead_an',   'eadata, an address register', ea='1-001')
cpprim(_prim('-', '-', '-10---'), 'cp_ead_imm',  'eadata, an immediate',      ea='1-010')
cpprim(_prim('-', '-', '010---', '00000100'), 'cp_ead_post4', 'eadata, (An)+, four bytes in', ea='1-011')
cpprim(_prim('-', '-', '-10---'), 'cp_ead_post', 'eadata, (An)+',             ea='1-011')
cpprim(_prim('-', '-', '010---', '00000100'), 'cp_ead_pre4', 'eadata, -(An), four bytes in', ea='1-100')
cpprim(_prim('-', '-', '-10---'), 'cp_ead_pre',  'eadata, -(An)',             ea='1-100')
cpprim(_prim('-', '-', '110---', '00001100'), 'cp_ead_wr12', 'eadata, memory, twelve bytes out', ea='1-101')
cpprim(_prim('-', '-', '110---'), 'cp_ead_wr',   'eadata, memory, from the coprocessor', ea='1-101')
cpprim(_prim('-', '-', '010---', '00000100'), 'cp_ead_rd4', 'eadata, memory, four bytes in', ea='1-101')
cpprim(_prim('-', '-', '010---'), 'cp_ead_calc', 'eadata, memory, to the coprocessor', ea='1-101')
# Transfer multiple coprocessor registers, twelve bytes each: FMOVEM.X. UM
# 7.4.16: to the coprocessor control or (An)+, from it control alterable or
# -(An); anything else an F-line exception.
cpprim(_prim('-', '-', '-00001'), 'cp_fline_abort', 'multiple registers, no such address', ea='-0---')
cpprim(_prim('-', '-', '000001', '00001100'), 'cp_m12in_post', 'multiple registers in, twelve bytes, (An)+', ea='-1011')
cpprim(_prim('-', '-', '000001', '00001100'), 'cp_m12in_ctl',  'multiple registers in, twelve bytes, control', ea='-1101')
cpprim(_prim('-', '-', '100001', '00001100'), 'cp_m12pre',     'multiple registers out, twelve bytes, -(An)', ea='-1100')
cpprim(_prim('-', '-', '100001', '00001100'), 'cp_m12out_ctl', 'multiple registers out, twelve bytes, control', ea='-1101')
cpprim(_prim('-', '-', '-10---'), 'cp_eadata',   'evaluate effective address and transfer data')
cpprim(_prim('-', '-', '100000'), 'cp_wprev',    'write to previously evaluated effective address')
cpprim(_prim('-', '-', '-00101'), 'cp_takeaddr', 'take address and transfer data')
cpprim(_prim('-', '-', '-01110'), 'cp_tos',      'transfer to/from top of stack')
cpprim(_prim('-', '-', '-01100'), 'cp_sreg',     'transfer single main processor register')
cpprim(_prim('-', '-', '-01101'), 'cp_creg',     'transfer main processor control register')
cpprim(_prim('-', '-', '-00110'), 'cp_mreg',     'transfer multiple main processor registers')
cpprim(_prim('-', '-', '-00001'), 'cp_mcreg',    'transfer multiple coprocessor registers')
cpprim(_prim('-', '-', '-0001-'), 'cp_srpc',     'transfer status register and scanPC')
cpprim(_prim('-', '-', '-11100'), 'cp_takepre',  'take preinstruction exception')
cpprim(_prim('-', '-', '-11101'), 'cp_takemid',  'take midinstruction exception')
cpprim(_prim('-', '-', '-11110'), 'cp_takepost', 'take postinstruction exception')


# --------------------------------------------------------------------------
# The instructions
# --------------------------------------------------------------------------
# cpGEN -- UM 7.2.1. The command word is the word after the operation word.
label('cp_gen')
cir_write('the command word to the command CIR -- UM 7.3.6',
          CIR_COMMAND, 2, init=True, asrc='STG_C', pf='CONSUME')
u('no coprocessor answered: UM 7.5.2.8, an F-line exception',
  seq='COND', cond='BERR', next='exc_line_f')
u('the scanPC is the word after the command word -- UM 7.4.1',
  next='cp_resp')

# cpBcc -- UM 7.2.2.1. "The MC68020 writes the entire operation word to the
# condition CIR", and the scanPC stays on the word after it.
label('cp_bcc')
cir_write('the operation word to the condition CIR -- UM 7.3.7',
          CIR_CONDITION, 2, init=True, asrc='STG_D')
u('no coprocessor', seq='COND', cond='BERR', next='exc_line_f')
u('the dialogue', next='cp_resp')

# cpScc, cpDBcc and cpTRAPcc -- UM 7.2.2.2 to 7.2.2.4. The condition selector is
# the word after the operation word.
for _stem in ('cp_scc', 'cp_dbcc', 'cp_trapcc'):
    label(_stem)
    cir_write('the condition selector word to the condition CIR',
              CIR_CONDITION, 2, init=True, asrc='STG_C', pf='CONSUME')
    u('no coprocessor', seq='COND', cond='BERR', next='exc_line_f')
    u('the dialogue', next='cp_resp')

# The end of a conditional dialogue: a null primitive with CA clear, and the
# verdict in TF -- UM 7.4.4. Which instruction it was is in stage D.
label('cp_cond_done')
u('cpBcc?', seq='COND', cond='CPBCC', next='cp_bcc_tail')
u('cpDBcc?', seq='COND', cond='CPDBCC', next='cp_dbcc_tail')
u('cpTRAPcc?', seq='COND', cond='CPTRAP', next='cp_trapcc_tail')
u('cpScc', next='cp_scc_tail')

# cpBcc: "adds the displacement to the scanPC", which "must be pointing to the
# location of the first word of the displacement".
label('cp_bcc_tail')
u('true?', seq='COND', cond='CPTF', next='cp_bcc_taken')
u('false: the long form?', seq='COND', cond='IR6', next='cp_bcc_nl')
u('... the displacement word is eaten', pf='CONSUME', next='cp_done')
label('cp_bcc_nl')
u('... both words of it', pf='CONSUME')
u('...', pf='CONSUME', next='cp_done')
label('cp_bcc_taken')
u('the base, which is the scanPC', asrc='PC_C', alu='A', dst='T1')
u('the long form?', seq='COND', cond='IR6', next='cp_bcc_tl')
u('the word displacement, sign extended, onto the base',
  asrc='T1', bsrc='STG_C_S', alu='ADD', pf='FLUSH', next='cp_bcc_go')
label('cp_bcc_tl')
u('the high half of a long displacement', asrc='STG_C_HI', alu='A',
  dst='T0', pf='CONSUME')
u('... and the low', asrc='T0', bsrc='STG_C_U', alu='OR', dst='T0')
u('... onto the base', asrc='T1', bsrc='T0', alu='ADD', pf='FLUSH')
label('cp_bcc_go')
u('then wait for the pipe and decode', seq='DECODE')

# cpScc: all ones for true, all zeros for false, in the byte at the effective
# address -- evaluated only now, after the dialogue, from the extension words
# the scanPC has reached.
label('cp_scc_tail')
u('true?', seq='COND', cond='CPTF', next='cp_scc_t')
u('false: zero', asrc='ZERO', alu='A', dst='T0', next='cp_scc_st')
label('cp_scc_t')
u('true: ones', asrc='ZERO', alu='NOT', dst='T0')
label('cp_scc_st')
u('a data register?', seq='COND', cond='EADN', next='cp_scc_dn')
u('the byte at the effective address', call=1, seq='EAMODE', size='BYTE')
u('... is set or cleared',
  bus='WRITE', fc='DATA', asel='EA', asrc='T0', alu='A', bytes=1,
  next='cp_done')
label('cp_scc_dn')
u('the low byte of the data register',
  asrc='T0', alu='A', dst='DREG_R', size='BYTE', next='cp_done')

# cpDBcc: the scanPC is on the displacement.
label('cp_dbcc_tail')
u('true: the instruction is over', seq='COND', cond='CPTF',
  next='cp_dbcc_done')
u('the low word of the counter, one less, and -1 also ends it',
  asrc='DREG', bsrc='ONE', alu='SUB', dst='DREG_R', size='WORD',
  seq='COND', cond='RESM1', next='cp_dbcc_done')
u('the branch, from the address of the displacement',
  asrc='PC_C', bsrc='STG_C_S', alu='ADD', pf='FLUSH', next='cp_bcc_go')
label('cp_dbcc_done')
u('the displacement word is eaten either way', pf='CONSUME', next='cp_done')

# cpTRAPcc: the operand words are eaten first, so that the frame's program
# counter is the next instruction -- UM 7.5.2.4.
label('cp_trapcc_tail')
u('an operand word?', seq='COND', cond='IR1', next='cp_trapcc_w')
u('none', next='cp_trapcc_t')
label('cp_trapcc_w')
u('eaten', pf='CONSUME')
u('a second?', seq='COND', cond='IR0', next='cp_trapcc_l')
u('no', next='cp_trapcc_t')
label('cp_trapcc_l')
u('eaten', pf='CONSUME')
label('cp_trapcc_t')
u('true: the trap -- vector 7 and the six-word frame', seq='COND',
  cond='CPTF', next='exc_trapcc')
u('false: on to the next instruction', next='cp_done')


# cpSAVE -- UM 7.2.3.3. Privileged, and the only coprocessor instruction that
# starts with a READ.
label('cp_save')
u('privileged -- checked before any CIR is touched, UM 7.2.3.3.2',
  seq='COND', cond='USER', next='exc_priv')
cir_read('the save CIR', CIR_SAVE, 2, init=True)
u('no coprocessor', seq='COND', cond='BERR', next='exc_line_f')
u('the format word', asrc='RDATA', alu='A', dst='T0', size='WORD')
u('not ready: "the main processor services any pending interrupts and then '
  'reads the save CIR again"',
  seq='COND', cond='FWNOTRDY', next='cp_busy')
u('invalid, or a reserved code', seq='COND', cond='FWBAD',
  next='cp_format_abort')
u('empty?', seq='COND', cond='FWEMPTY', next='cp_save_empty')
u('a length that is not a multiple of four', seq='COND', cond='FWLEN',
  next='cp_format_abort')
u('the length of the state', asrc='FWLEN', alu='A', dst='T1',
  next='cp_save_ea')
label('cp_save_empty')
u('an empty frame is the format word and nothing else', asrc='ZERO',
  alu='A', dst='T1')
label('cp_save_ea')
u('-(An)?', seq='COND', cond='EAPRE', next='cp_save_pre')
u('a control address', call=1, seq='EAMODE')
u('... and the format word goes there', next='cp_save_fw')
label('cp_save_pre')
u('the whole frame: the state, the format word and its reserved word',
  asrc='T1', bsrc='FOUR', alu='ADD', dst='T2')
u('the address register steps down by it',
  asrc='AREG', bsrc='T2', alu='SUB', dst='AREG_EA_ADDR')
u('... and the frame starts there', asrc='AREG', alu='A', dst='EA')
label('cp_save_fw')
u('the format word first, at the lowest address -- figure 7-14',
  bus='WRITE', fc='DATA', asel='EA', asrc='FWLONG', alu='A', bytes=4)
u('the state goes in from the top down: its last long word is at EA + length',
  asrc='EA', bsrc='T1', alu='ADD', dst='T2')
u('none of it?', seq='COND', cond='T1ZERO', next='cp_done')
label('cp_save_loop')
cir_read('a long word from the operand CIR, and four fewer', CIR_OPERAND, 4,
         asrc='T1', bsrc='FOUR', alu='SUB', dst='T1')
u('... to memory -- and was that the last?', bus='WRITE', fc='DATA',
  asel='T2', asrc='RDATA', alu='A', bytes=4,
  seq='COND', cond='T1ZERO', next='cp_done')
u('... and down', asrc='T2', bsrc='FOUR', alu='SUB', dst='T2',
  next='cp_save_loop')

# cpRESTORE -- UM 7.2.3.4.
label('cp_restore')
u('privileged', seq='COND', cond='USER', next='exc_priv')
u('(An)+?', seq='COND', cond='EAPOST', next='cp_rest_an')
u('a control address', call=1, seq='EAMODE')
u('... where the frame is', next='cp_rest_fw')
label('cp_rest_an')
u('the address register', asrc='AREG', alu='A', dst='EA')
label('cp_rest_fw')
u('the format word from memory, kept for its length -- UM figure 7-18 note 2',
  bus='READ', fc='EASP', asel='EA', bytes=2,
  asrc='RDATA', alu='A', dst='T1', size='WORD')
cir_write('... and written to the restore CIR', CIR_RESTORE, 2, init=True,
          asrc='T1')
u('no coprocessor', seq='COND', cond='BERR', next='exc_line_f')
label('cp_rest_rd')
cir_read('what the coprocessor makes of it, held', CIR_RESTORE, 2,
         asrc='RDATA', alu='A', dst='T0', size='WORD')
u('not ready: read it again, without servicing interrupts -- UM 7.2.3.2.2',
  seq='COND', cond='FWNOTRDY', next='cp_rest_rd')
u('invalid', seq='COND', cond='FWBAD', next='cp_format_abort')
u('empty: nothing follows', seq='COND', cond='FWEMPTY', next='cp_rest_empty')
u('the length is the one read from MEMORY', asrc='T1', alu='A', dst='T0',
  size='WORD')
u('... and must be a multiple of four -- UM 7.5.2.7', seq='COND',
  cond='FWLEN', next='cp_format_abort')
u('the length', asrc='FWLEN', alu='A', dst='T1')
u('the state follows the format word and its reserved word',
  asrc='EA', bsrc='FOUR', alu='ADD', dst='T2')
u('none of it?', seq='COND', cond='T1ZERO', next='cp_rest_end')
label('cp_rest_loop')
u('a long word from memory, going up, and four fewer',
  bus='READ', fc='EASP', asel='T2', bytes=4,
  asrc='T1', bsrc='FOUR', alu='SUB', dst='T1')
cir_write('... to the operand CIR -- and was that the last?', CIR_OPERAND, 4,
          asrc='RDATA', seq='COND', cond='T1ZERO', next='cp_rest_last')
u('... and up', asrc='T2', bsrc='FOUR', alu='ADD', dst='T2',
  next='cp_rest_loop')
label('cp_rest_last')
u('... and past it', asrc='T2', bsrc='FOUR', alu='ADD', dst='T2',
  next='cp_rest_end')
label('cp_rest_empty')
u('the frame is the format word and its reserved word', asrc='EA',
  bsrc='FOUR', alu='ADD', dst='T2')
label('cp_rest_end')
u('(An)+?', seq='COND', cond='EAPOST', next='cp_rest_upd')
u('no', next='cp_done')
label('cp_rest_upd')
u('the address register is past the frame', asrc='T2', alu='A',
  dst='AREG_EA_ADDR', next='cp_done')


# cpRESTORE of an immediate frame: the format word, its reserved word and the
# state are the words after the operation word, so they come out of the pipe
# and the scanPC ends past them.
label('cp_restore_imm')
u('privileged', seq='COND', cond='USER', next='exc_priv')
u('the format word, from the stream', asrc='STG_C', alu='A', dst='T1',
  size='WORD', pf='CONSUME')
u('... and its reserved word, eaten', pf='CONSUME')
cir_write('... written to the restore CIR', CIR_RESTORE, 2, init=True,
          asrc='T1')
u('no coprocessor', seq='COND', cond='BERR', next='exc_line_f')
label('cp_resti_rd')
cir_read('what the coprocessor makes of it', CIR_RESTORE, 2)
u('... held', asrc='RDATA', alu='A', dst='T0', size='WORD')
u('not ready: read it again', seq='COND', cond='FWNOTRDY', next='cp_resti_rd')
u('invalid', seq='COND', cond='FWBAD', next='cp_format_abort')
u('empty: nothing follows', seq='COND', cond='FWEMPTY', next='cp_done')
u('the length from the stream', asrc='T1', alu='A', dst='T0', size='WORD')
u('... a multiple of four', seq='COND', cond='FWLEN', next='cp_format_abort')
u('the length', asrc='FWLEN', alu='A', dst='T1')
label('cp_resti_loop')
u('all of it?', seq='COND', cond='T1ZERO', next='cp_done')
u('two words of the stream', asrc='STG_C_HI', alu='A', dst='T0',
  pf='CONSUME')
u('... as one long word', asrc='T0', bsrc='STG_C_U', alu='OR', dst='T0',
  pf='CONSUME')
cir_write('to the operand CIR', CIR_OPERAND, 4, asrc='T0')
u('four fewer', asrc='T1', bsrc='FOUR', alu='SUB', dst='T1',
  next='cp_resti_loop')


# --------------------------------------------------------------------------
# The midinstruction frame -- UM figure 7-43, format $9
#
# Entered with T0 = the vector offset. It is built with ea_save as the pointer
# because EA is one of the things it saves. Everything a coprocessor
# instruction needs to go on with the dialogue is in it; RTE reads it back and
# goes straight to the response CIR.
# --------------------------------------------------------------------------
def frame9_body(ptr_from_sp=True):
    if ptr_from_sp:
        u('the stack pointer, now the supervisor one', asrc='SP', alu='A',
          dst='EA_SAVE')
    for off, n, src, what in [(0x10, 4, 'EA', 'the effective address'),
                              (0x0E, 2, 'STG_D', 'the operation word'),
                              (0x0C, 2, 'CPINT', 'the internal register'),
                              (0x08, 4, 'PC_D', 'the program counter'),
                              (0x06, 2, 'FMTVEC', 'format $9 and the vector'),
                              (0x02, 4, 'PC_C_RAW', 'the scanPC'),
                              (0x00, 2, 'T3', 'the status register')]:
        u('+$%02X: %s' % (off, what), asrc='EA_SAVE',
          bsrc={2: 'TWO', 4: 'FOUR'}[n], alu='SUB', dst='EA_SAVE')
        u('... written there', bus='WRITE', fc='DATA', asel='EA_SAVE',
          asrc=src, alu='A', bytes=n,
          **({'frame': 'F9'} if src == 'FMTVEC' else {}))


label('exc_cp9')
u('a copy of the status register as it was', asrc='SR', alu='A', dst='T3',
  size='WORD')
u('supervisor, and no tracing of the handler -- UM 6.1 step one',
  asrc='SR', alu='EXCSR', dst='SR', size='WORD')
frame9_body()
u('and the stack pointer is where the frame begins', asrc='EA_SAVE', alu='A',
  dst='SP', size='LONG', next='exc_f0_vector')

# An interrupt in the middle of the dialogue -- UM 7.5.2.6. The same
# acknowledge as exc_irq and the same throwaway frame when M is set, around the
# midinstruction frame instead of the four-word one.
label('exc_cp_irq')
u('a copy of the status register as it was', asrc='SR', alu='A', dst='T3',
  size='WORD')
u('the mask goes up to this level',
  asrc='SR', bsrc='IRQLEVEL', alu='SETMASK', dst='SR', size='WORD')
u('the acknowledge cycle', bus='READ', fc='CPU', bytes=1, cpuspace='IACK',
  seq='COND', cond='AVEC', next='exc_cp_irq_auto')
u('... or nobody answered', seq='COND', cond='BERR', next='exc_cp_irq_spur')
u('the device supplied a vector number', asrc='IRQVEC', alu='A', dst='T0',
  size='LONG', next='exc_cp_irq_go')
label('exc_cp_irq_auto')
u('the autovector', asrc='AUTOVEC', alu='A', dst='T0', size='LONG',
  next='exc_cp_irq_go')
label('exc_cp_irq_spur')
u('a spurious interrupt', asrc='VECOFF', alu='A', dst='T0', size='LONG',
  vec=24)
label('exc_cp_irq_go')
u('the master stack?', seq='COND', cond='MASTER', next='exc_cp_irq_m')
u('supervisor, and no tracing of the handler',
  asrc='SR', alu='EXCSR', dst='SR', size='WORD')
frame9_body()
u('and the stack pointer is where the frame begins', asrc='EA_SAVE', alu='A',
  dst='SP', size='LONG', next='exc_f0_vector')
label('exc_cp_irq_m')
u('supervisor, and no tracing of the handler',
  asrc='SR', alu='EXCSR', dst='SR', size='WORD')
frame9_body()
u('the master stack pointer is where that frame begins', asrc='EA_SAVE',
  alu='A', dst='SP', size='LONG')
# UM 6.1.9: "this second frame contains the same PC value and vector offset as
# the frame created on top of the master stack, but has a format number of 1".
# The midinstruction frame's first long word after the status register is the
# scanPC, so that is what the throwaway carries.
u('now clear M, which moves the stack from MSP to ISP',
  asrc='SR', alu='CLRM', dst='SR', size='WORD')
u('the saved status register again, with S set',
  asrc='T3', alu='SETS', dst='T3', size='WORD')
u('the same program counter', asrc='PC_C_RAW', alu='A', dst='T1',
  size='LONG')
u('the interrupt stack', asrc='SP', alu='A', dst='EA_SAVE', size='LONG')
u('+$06: format $1 and the vector', asrc='EA_SAVE', bsrc='TWO', alu='SUB',
  dst='EA_SAVE')
u('... written there', bus='WRITE', fc='DATA', asel='EA_SAVE',
  asrc='FMTVEC', alu='A', bytes=2, frame='F1')
u('+$02: the program counter', asrc='EA_SAVE', bsrc='FOUR', alu='SUB',
  dst='EA_SAVE')
u('... written there', bus='WRITE', fc='DATA', asel='EA_SAVE', asrc='T1',
  alu='A', bytes=4)
u('+$00: the status register', asrc='EA_SAVE', bsrc='TWO', alu='SUB',
  dst='EA_SAVE')
u('... written there', bus='WRITE', fc='DATA', asel='EA_SAVE', asrc='T3',
  alu='A', bytes=2)
u('and the interrupt stack pointer is where the throwaway begins',
  asrc='EA_SAVE', alu='A', dst='SP', size='LONG', next='exc_f0_vector')

# RTE of a midinstruction frame -- UM 7.4.19: "the MC68020 returns from the
# exception handler and reads the response CIR". Entered from rte with T1 the
# frame base. The status register is written last but one, because it decides
# which stack pointer is stepped and the space the queue refills from; the
# scanPC is written last, which is what refills it.
label('rte_nine')
u('+$02: the scanPC', asrc='T1', bsrc='TWO', alu='ADD', dst='T2')
u('... read', bus='READ', fc='DATA', asel='T2', bytes=4)
u('... and held', asrc='RDATA', alu='A', dst='T0')
u('+$08: the program counter', asrc='T1', bsrc='EIGHT', alu='ADD', dst='T2')
u('... read', bus='READ', fc='DATA', asel='T2', bytes=4)
u('... into the pipe', asrc='RDATA', alu='A', dst='PC_D')
u('+$0C: the internal register', asrc='T2', bsrc='FOUR', alu='ADD', dst='T2')
u('... read', bus='READ', fc='DATA', asel='T2', bytes=2)
u('... unpacked', asrc='RDATA', alu='A', dst='CPINT', size='WORD')
u('+$0E: the operation word', asrc='T2', bsrc='TWO', alu='ADD', dst='T2')
u('... read', bus='READ', fc='DATA', asel='T2', bytes=2)
u('... into stage D', asrc='RDATA', alu='A', dst='STG_D', size='WORD')
u('+$10: the effective address', asrc='T2', bsrc='TWO', alu='ADD', dst='T2')
u('... read', bus='READ', fc='DATA', asel='T2', bytes=4)
u('... back', asrc='RDATA', alu='A', dst='EA')
u('+$00: the status register', bus='READ', fc='DATA', asel='T1', bytes=2)
u('... held', asrc='RDATA', alu='A', dst='T3', size='WORD')
u('the stack pointer, past the frame, while it is still this stack',
  asrc='T1', bsrc='TWENTY', alu='ADD', dst='SP', size='LONG')
u('the status register', asrc='T3', alu='A', dst='SR', size='WORD')
u('the queue refills from the scanPC', asrc='T0', alu='A', dst='SCANPC')
u('and the dialogue goes on where it stopped', next='cp_resp')


# ==========================================================================
# A read takes its own data
#
# Written the plain way, a memory operand is two microwords: the read, and then
# a microword that takes the read data somewhere. The bus microword already
# costs its bus cycle and one clock more for the acknowledge, and the read data
# is valid in that last clock -- so the second microword is a clock thrown away
# on every operand read. This pass folds each such pair into the read, where
# that is safe; check_rdata_restart in the assembler is what says it is, and
# refuses the result otherwise. doc/timing-divergences.md.
#
# Folded only when the read is a plain memory or coprocessor read with no other
# work of its own, the consumer uses no bus, no pipe and nothing but the
# datapath, both agree on the operand size, and nothing jumps to the consumer --
# so that removing it changes no path through the program.
# ==========================================================================
_PLAIN_READ = {'bus', 'fc', 'asel', 'bytes', 'szsel', 'size', 'cpuspace', 'vec',
               'rmc', 'eadst', 'eapc'}
_CONSUMER = {'asrc', 'bsrc', 'alu', 'dst', 'size', 'szsel', 'ccr', 'seq', 'cond',
             'next', 'cnt', 'notrace', 'frame', 'call'}


def _reads_rdata(f):
    return f.get('asrc') == 'RDATA' or f.get('bsrc') == 'RDATA'


def _merge_reads():
    targets = set(LABELS.values())
    for f, _c in WORDS:
        n = f.get('next')
        if isinstance(n, str):
            targets.add(LABELS[n])
        elif isinstance(n, int):
            targets.add(n)
    keep, merged = [], 0
    i = 0
    while i < len(WORDS):
        f, c = WORDS[i]
        if (i + 1 < len(WORDS) and i + 1 not in targets
                and f.get('bus') == 'READ'
                and f.get('cpuspace', 'NONE') in ('NONE', 'COPROC')
                and set(f) <= _PLAIN_READ
                and f.get('seq', 'NEXT') == 'NEXT' and 'next' not in f):
            g, d = WORDS[i + 1]
            same_size = (f.get('szsel', 'FIXED') == g.get('szsel', 'FIXED')
                         and (f.get('size', 'LONG') == g.get('size', 'LONG')
                              or f.get('bytes', 0) != 0))
            if (_reads_rdata(g) and set(g) <= _CONSUMER and same_size
                    and not g.get('call')):
                h = dict(f)
                h.update(g)
                if f.get('bytes', 0) == 0:
                    # the operand size is the read's; the consumer agreed on it
                    h['szsel'] = f.get('szsel', 'FIXED')
                    h['size'] = f.get('size', 'LONG')
                keep.append((i, h, c + ' / ' + d))
                merged += 1
                i += 2
                continue
        keep.append((i, f, c))
        i += 1
    # the old index of every word that survives, and where it now is
    where = {}
    for new, (old, _f, _c) in enumerate(keep):
        where[old] = new
    removed = set(range(len(WORDS))) - set(where)
    for name in list(LABELS):
        assert LABELS[name] not in removed, name
        LABELS[name] = where[LABELS[name]]
    WORDS[:] = [(f, c) for _old, f, c in keep]
    return merged


MERGED_READS = _merge_reads()


# Identical microwords that end a path -- DECODE, RET, or an explicit `next` --
# behave identically wherever they sit, so all but the first are removed and
# their predecessors jump to it instead. A word is kept if the one before it
# reaches it by falling through in a way that cannot be redirected: a COND's
# not-taken arm, or the return from a call. The fast effective-address paths
# spend about a hundred words on copies of the same few tails, and this is what
# keeps the micro-ROM within 2048 words.
def _terminal(f):
    return (f.get('seq') in ('DECODE', 'RET')
            or ('next' in f and f.get('seq', 'NEXT') == 'NEXT'
                and not f.get('call')))


def _merge_tails():
    def key(f):
        return tuple(sorted((k, repr(v)) for k, v in f.items()))

    first = {}
    drop = {}                        # removed index -> the index it becomes
    redirect = set()                 # predecessors that now need a `next`
    for i, (f, _c) in enumerate(WORDS):
        if not _terminal(f):
            continue
        k = key(f)
        if k not in first:
            first[k] = i
            continue
        if i > 0:
            p = WORDS[i - 1][0]
            # a call -- EAMODE's included -- returns to the word after it
            falls = bool(p.get('call')) or (
                not _terminal(p) and p.get('seq', 'NEXT') not in (
                    'EADEC', 'EAMODE', 'CPDEC', 'RESUME'))
            if falls:
                if (p.get('seq', 'NEXT') != 'NEXT' or 'next' in p
                        or p.get('call') or (i - 1) in drop):
                    continue
                redirect.add(i - 1)
        drop[i] = first[k]
    if not drop:
        return 0
    keep = [i for i in range(len(WORDS)) if i not in drop]
    where = {old: new for new, old in enumerate(keep)}
    for old, tgt in drop.items():
        where[old] = where[tgt]

    def fix(n):
        if isinstance(n, int):
            return where[n]
        return n
    out = []
    for i in keep:
        f, c = WORDS[i]
        f = dict(f)
        if i in redirect:
            f['next'] = where[i + 1] if (i + 1) not in drop else where[drop[i + 1]]
        elif 'next' in f:
            f['next'] = fix(f['next'])
        out.append((f, c))
    for name in list(LABELS):
        LABELS[name] = where[LABELS[name]]
    WORDS[:] = out
    return len(drop)


MERGED_TAILS = _merge_tails()


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