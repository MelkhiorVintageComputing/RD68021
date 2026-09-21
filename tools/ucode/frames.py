#!/usr/bin/env python3
"""The six exception stack frames, and the state this design keeps in them.

    python3 tools/ucode/frames.py            # the layouts and the budget
    python3 tools/ucode/frames.py --check    # just the checks

This is the single table. `rtl/gen/rd68021_frame_pkg.sv` is generated from it, the
microcode's frame-build and RTE routines are checked against it, and the tables in
`doc/checkpoint.md` are printed from it. One wrong offset in the long fault frame
is a silent demand-paging failure that no instruction test will catch, so the
offset exists once.

Source: UM Table 6-5 for the layouts, UM 6.1.12 for the version word, UM 6.2 and
figure 6-8 for the special status word.
"""

import argparse
import sys

# --------------------------------------------------------------------------
# Architecturally named fields. A slot is (offset, words, field).
#
# `internal` means the manual names it "internal register" or "internal
# information" -- private to the implementation, and on the long frame protected
# by the version number at SP+$36.
# --------------------------------------------------------------------------
FRAMES = {
    0x0: dict(words=4, name='four-word', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
    ]),
    0x1: dict(words=4, name='throwaway four-word', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
    ]),
    0x2: dict(words=6, name='six-word', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
        (0x08, 2, 'instr_addr'),
    ]),
    0x9: dict(words=10, name='coprocessor midinstruction', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
        (0x08, 2, 'instr_addr'),
        (0x0C, 4, 'internal'),
    ]),
    0xA: dict(words=16, name='short bus fault', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
        (0x08, 1, 'internal'),
        (0x0A, 1, 'ssw'),
        (0x0C, 1, 'stage_c'),
        (0x0E, 1, 'stage_b'),
        (0x10, 2, 'dfa'),
        (0x14, 1, 'internal'),
        (0x16, 1, 'internal'),
        (0x18, 2, 'dob'),
        (0x1C, 1, 'internal'),
        (0x1E, 1, 'internal'),
    ]),
    0xB: dict(words=46, name='long bus fault', slots=[
        (0x00, 1, 'sr'),
        (0x02, 2, 'pc'),
        (0x06, 1, 'fmtvec'),
        (0x08, 1, 'internal'),
        (0x0A, 1, 'ssw'),
        (0x0C, 1, 'stage_c'),
        (0x0E, 1, 'stage_b'),
        (0x10, 2, 'dfa'),
        (0x14, 1, 'internal'),
        (0x16, 1, 'internal'),
        (0x18, 2, 'dob'),
        (0x1C, 4, 'internal'),
        (0x24, 2, 'stage_b_addr'),
        (0x28, 2, 'internal'),
        (0x2C, 2, 'dib'),
        (0x30, 3, 'internal'),
        (0x36, 1, 'version'),
        (0x38, 18, 'internal'),
    ]),
}

# UM 6.1.12: "the version number is located in the most significant nibble
# (bits 15-12) of the word at location SP + $36 in the long stack frame". Table
# 6-5's own layout reads at a glance as if it were at +$38; the arithmetic of the
# frame settles it. See doc/manual-contradictions.md.
VERSION_OFFSET = 0x36
VERSION_HI, VERSION_LO = 15, 12
VERSION = 0x1

# --------------------------------------------------------------------------
# Where this design's private state lives, in the long frame's internal words.
#
# Rules, and they are the reason this file is written before any instruction:
#
#   1. Nothing goes in the SHORT frame's internal words. Format $A has no version
#      field -- UM 6.1.12 validates the stamp only for the long frame -- so a
#      short frame this design wrote could be read by something else with no way
#      to know it should not. Everything format $A needs is either an
#      architectural field or derivable from one.
#   2. The cache holding register is NOT saved. It is a pure cache of the last
#      long word fetched; RTE marks it invalid and the next prefetch re-reads it.
#      One bus cycle, never a wrong answer, and 66 bits of budget back.
#   3. Every register an instruction accumulates has a home here or it does not
#      exist. A microword may not stash a value anywhere else.
# --------------------------------------------------------------------------
INTERNAL = [
    # offset, hi, lo, name, bits, what
    (0x08,  2,  0, 'bytes',      3,  'residual byte count of the faulted operand'),
    (0x08,  3,  3, 'g0',         1,  'inside group-0 exception processing'),
    (0x08,  4,  4, 'notrace',    1,  'the trace pending for this instruction was cancelled'),
    (0x08,  5,  5, 'rr_pending', 1,  'a rerun flag out of the frame is still to be applied'),
    (0x08,  6,  6, 'eapc',       1,  'the base of the effective address under way is the PC'),
    (0x08,  8,  7, 'opsize',     2,  'the operand size the dispatching microword resolved'),
    (0x08,  9,  9, 'eadst',      1,  'the effective address under way is a MOVE destination'),
    (0x08, 14, 10, 'regcnt',     5,  "MOVEM's register counter"),
    (0x14, 15,  0, 'upc',       16,  'the micro-address to resume at'),
    (0x16, 15,  0, 'stage_d',   16,  'the instruction word being decoded'),
    (0x1C, 31,  0, 't0',        32,  'working register'),
    (0x20, 31,  0, 't1',        32,  'working register'),
    (0x28, 31,  0, 't2',        32,  'working register'),
    (0x30, 31,  0, 't3',        32,  'working register'),
    (0x34, 15,  0, 'xw',        16,  'the extension-word latch'),
    (0x36,  0,  0, 'stage_d_f',  1,  'stage D came from a faulted prefetch'),
    (0x38, 31,  0, 'ea_latch',  32,  'the address output buffer'),
    (0x3C, 31,  0, 'ea_save',   32,  'the copy of it taken at the fault'),
    (0x40, 31,  0, 'pc_fetch',  32,  'the next long word the pipe will fetch'),
    (0x44, 15,  0, 'link',      16,  'the return address of the subroutine under way'),
]

# --------------------------------------------------------------------------
# The frozen set: everything that survives a fault, and where it lands.
#
# `slot` is an architectural field of the fault frames, an INTERNAL name, or
# 'derived' with the derivation written out.
# --------------------------------------------------------------------------
CHECKPOINT = [
    # unit,  register,        bits, slot,            note
    ('ifu', 'stg_d',            16, 'stage_d',       ''),
    ('ifu', 'stg_c',            16, 'stage_c',       'frame +$0C'),
    ('ifu', 'stg_b',            16, 'stage_b',       'frame +$0E'),
    ('ifu', 'stg_c_fault',       1, 'ssw',           'SSW FC'),
    ('ifu', 'stg_b_fault',       1, 'ssw',           'SSW FB'),
    ('ifu', 'stg_c_rerun',       1, 'ssw',           'SSW RC'),
    ('ifu', 'stg_b_rerun',       1, 'ssw',           'SSW RB'),
    ('ifu', 'stg_d_fault',       1, 'stage_d_f',     ''),
    ('ifu', 'pc_d',             32, 'pc',            "the frame's own program counter"),
    ('ifu', 'stg_b_addr',       32, 'stage_b_addr',  'long frame +$24; short frame derives it'),
    ('ifu', 'pc_fetch',         32, 'pc_fetch',      ''),
    ('ifu', 'chr',              32, 'derived',       'not saved: invalidated by RTE, re-fetched'),
    ('ifu', 'chr_addr',         30, 'derived',       'likewise'),
    ('ifu', 'chr_valid',         1, 'derived',       'likewise -- always restored as invalid'),
    ('ifu', 'chr_fault',         1, 'derived',       'likewise'),
    ('biu', 'flt_addr',         32, 'dfa',           'frame +$10'),
    ('biu', 'flt_dob',          32, 'dob',           'frame +$18'),
    ('biu', 'flt_dib',          32, 'dib',           'long frame +$2C'),
    ('biu', 'ssw',              16, 'ssw',           'frame +$0A'),
    ('biu', 'flt_bytes',         3, 'bytes',         'SIZ cannot encode a five-byte residual'),
    ('biu', 'flt_rmc',           1, 'ssw',           'SSW RM'),
    ('biu', 'flt_rw',            1, 'ssw',           'SSW RW'),
    ('biu', 'flt_fc',            3, 'ssw',           'SSW FC2-FC0'),
    ('seq', 'upc',              16, 'upc',           ''),
    ('seq', 'link',             16, 'link',          'seq = RET returns here'),
    ('seq', 't0',               32, 't0',            ''),
    ('seq', 't1',               32, 't1',            ''),
    ('seq', 't2',               32, 't2',            ''),
    ('seq', 't3',               32, 't3',            ''),
    ('seq', 'ea_latch',         32, 'ea_latch',      ''),
    ('seq', 'ea_save',          32, 'ea_save',       ''),
    ('seq', 'xw',               16, 'xw',            ''),
    ('seq', 'g0',                1, 'g0',            ''),
    ('seq', 'notrace',           1, 'notrace',       ''),
    ('seq', 'rr_pending',        1, 'rr_pending',    ''),
    ('seq', 'eapc',              1, 'eapc',          'seq = EADEC latches it; EABASE reads it'),
    ('seq', 'size_q',            2, 'opsize',        'seq = EAMODE latches it; the shared EA routines read it'),
    ('seq', 'eadst_q',           1, 'eadst',         'likewise, and rsel reads it'),
    ('seq', 'cnt_q',             5, 'regcnt',        'MOVEM is restarted where it stopped'),
    ('seq', 'sr',               16, 'sr',            'frame +$00'),
]

# Registers that are architectural rather than per-instruction state: a fault does
# not change them and RTE does not put them back.
NOT_CHECKPOINTED = [
    ('D0-D7, A0-A6', 'architectural'),
    ('USP, ISP, MSP', "architectural; A7 is not a register, it is whichever of "
                      "these the S and M bits select"),
    ('VBR, SFC, DFC', 'architectural'),
    ('CACR, CAAR', 'architectural'),
    ('the instruction cache', 'a cache; UM 4.1 caches instructions only, so it is '
                              'architecturally invisible'),
]

ARCH_FIELDS = {
    'sr': 'status register',
    'pc': 'program counter',
    'fmtvec': 'format and vector offset',
    'instr_addr': 'instruction address',
    'ssw': 'special status word',
    'stage_c': 'instruction pipe stage C',
    'stage_b': 'instruction pipe stage B',
    'stage_b_addr': 'stage B address',
    'dfa': 'data cycle fault address',
    'dob': 'data output buffer',
    'dib': 'data input buffer',
    'version': 'version number and internal information',
    'internal': 'internal register',
}


def internal_words(fmt):
    """The offsets of the private words in one frame."""
    out = []
    for off, n, field in FRAMES[fmt]['slots']:
        if field == 'internal':
            out.extend(off + 2 * i for i in range(n))
        elif field == 'version':
            out.append(off)
    return out


# --------------------------------------------------------------------------
# The checks. These are the point of the file.
# --------------------------------------------------------------------------
def check():
    bad = []

    # 1. Every frame is contiguous, gapless and exactly its declared length.
    for fmt, f in sorted(FRAMES.items()):
        want = 0
        for off, n, field in f['slots']:
            if off != want:
                bad.append('format $%X: slot %r starts at +$%02X, expected +$%02X'
                           % (fmt, field, off, want))
            if field not in ARCH_FIELDS:
                bad.append('format $%X: slot %r is not a known field' % (fmt, field))
            want = off + 2 * n
        if want != 2 * f['words']:
            bad.append('format $%X: slots cover %d bytes, the manual says %d words '
                       '(%d bytes)' % (fmt, want, f['words'], 2 * f['words']))

    # 2. The version word is where UM 6.1.12 says, and only the long frame has one.
    for fmt, f in sorted(FRAMES.items()):
        vs = [off for off, n, field in f['slots'] if field == 'version']
        if fmt == 0xB:
            if vs != [VERSION_OFFSET]:
                bad.append('format $B: the version word is at %s, UM 6.1.12 says '
                           '+$%02X' % (vs, VERSION_OFFSET))
        elif vs:
            bad.append('format $%X: has a version word, which only the long frame '
                       'does' % fmt)

    # 3. The private assignment fits in the long frame's internal words, with no
    #    two registers on the same bits.
    avail = set(internal_words(0xB))
    used = {}
    for off, hi, lo, name, bits, _ in INTERNAL:
        if hi - lo + 1 != bits:
            bad.append('internal %r: %d bits declared, bit range %d..%d is %d'
                       % (name, bits, hi, lo, hi - lo + 1))
        nwords = (bits + 15) // 16
        for w in range(nwords):
            o = off + 2 * w
            if o not in avail:
                bad.append('internal %r: +$%02X is not an internal word of the '
                           'long frame' % (name, o))
            # A field of 16 bits or fewer occupies the bits it names in one word;
            # a wider one occupies whole words.
            span = range(lo, hi + 1) if bits <= 16 else range(0, 16)
            for b in span:
                k = (o, b)
                if k in used:
                    bad.append('internal %r: +$%02X bit %d is already %r'
                               % (name, o, b, used[k]))
                used[k] = name
    for b in range(VERSION_LO, VERSION_HI + 1):
        k = (VERSION_OFFSET, b)
        if k in used:
            bad.append('internal %r sits on the version nibble at +$%02X bit %d'
                       % (used[k], VERSION_OFFSET, b))

    # 4. NOTHING private is in the short frame. Format $A has no version field,
    #    so anything this design put there could be read by something else with
    #    no way to know it should not.
    short = set(internal_words(0xA))
    for off, hi, lo, name, bits, _ in INTERNAL:
        nwords = (bits + 15) // 16
        for w in range(nwords):
            if off + 2 * w in short and off + 2 * w not in avail:
                bad.append('internal %r is in the short frame, which has no '
                           'version field' % name)

    # 5. Every checkpointed register has a home, and every home is real.
    names = set(n for _, _, _, n, _, _ in INTERNAL)
    for unit, reg, bits, slot, _ in CHECKPOINT:
        if slot == 'derived':
            continue
        if slot in names:
            continue
        if slot in ARCH_FIELDS:
            continue
        bad.append('%s.%s: slot %r is neither an internal name nor an '
                   'architectural field' % (unit, reg, slot))

    # 6. Every internal word this design allocated is actually used by something.
    #    An allocation nobody claims is a budget nobody will re-examine.
    claimed = set(slot for _, _, _, slot, _ in CHECKPOINT)
    for off, hi, lo, name, bits, _ in INTERNAL:
        if name not in claimed:
            bad.append('internal %r at +$%02X is allocated but no checkpointed '
                       'register uses it' % (name, off))

    return bad


def budget():
    """(bits available, bits used, spare words)."""
    words = internal_words(0xB)
    have = len(words) * 16 - (VERSION_HI - VERSION_LO + 1)
    use = sum(bits for _, _, _, _, bits, _ in INTERNAL)
    touched = set()
    for off, hi, lo, name, bits, _ in INTERNAL:
        for w in range((bits + 15) // 16):
            touched.add(off + 2 * w)
    spare = [w for w in words if w not in touched and w != VERSION_OFFSET]
    return have, use, spare
