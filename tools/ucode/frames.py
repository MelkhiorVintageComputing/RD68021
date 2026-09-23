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
import os
import re

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
    (0x08,  4,  4, 'notrace',    1,  'the trace pending for this instruction was cancelled'),
    (0x08,  6,  6, 'eapc',       1,  'the base of the effective address under way is the PC'),
    (0x08,  8,  7, 'opsize',     2,  'the operand size the dispatching microword resolved'),
    (0x08,  9,  9, 'eadst',      1,  'the effective address under way is a MOVE destination'),
    (0x36,  2,  1, 'trmode',     2,  'the trace mode this instruction began with'),
    (0x36,  3,  3, 'flow',       1,  'this instruction has changed the flow'),
    (0x36,  4,  4, 'pc_kept',    1,  'pc_prev was taken at a flush, not at the decode'),
    (0x46, 31,  0, 'pc_prev',   32,  'the address of the instruction before this one'),
    (0x08, 14, 10, 'regcnt',     5,  "MOVEM's register counter"),
    (0x14, 15,  0, 'upc',       16,  'the micro-address to resume at'),
    (0x16, 15,  0, 'stage_d',   16,  'the instruction word being decoded'),
    (0x1C, 31,  0, 't0',        32,  'working register'),
    (0x20, 31,  0, 't1',        32,  'working register'),
    (0x28, 31,  0, 't2',        32,  'working register'),
    (0x30, 31,  0, 't3',        32,  'working register'),
    (0x34, 15,  0, 'xw',        16,  'the extension-word latch'),
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
    #
    # `register` is the name in the RTL, not a pretty one. check_rtl() below
    # reads every clocked process in rtl/ and insists that each register it
    # finds is either in this table or in EXEMPT, with a reason. Driving the
    # check from the MICROWORD DESTINATIONS instead -- which is what it did --
    # cannot see a register the microcode never names: link_q, eapc_q, size_q,
    # eadst_q and cnt_q were all added and all missed, and the first of them
    # would have surfaced in M9 as a wild jump on a demand-paged access.
    ('ifu', 'd_q',              16, 'stage_d',       ''),
    ('ifu', 'c_q',              16, 'stage_c',       'frame +$0C'),
    ('ifu', 'b_q',              16, 'stage_b',       'frame +$0E'),
    ('ifu', 'c_f_q',             1, 'ssw',           'SSW FC'),
    ('ifu', 'b_f_q',             1, 'ssw',           'SSW FB'),
    ('ifu', 'pc_d_q',           32, 'pc',            "the frame's own program counter"),
    ('ifu', 'fill_q',           32, 'stage_b_addr',  'long frame +$24; short frame derives it. The same register as pc_fetch: stage B is two before the fill point.'),
    ('ifu', 'fill_q',           32, 'pc_fetch',      ''),
    ('ifu', 'chr_q',            32, 'derived',       'not saved: invalidated by RTE, re-fetched'),
    ('ifu', 'chr_addr_q',       30, 'derived',       'likewise'),
    ('ifu', 'chr_v_q',           1, 'derived',       'likewise -- always restored as invalid'),
    ('ifu', 'chr_f_q',           1, 'derived',       'likewise'),
    ('biu', 'flt_addr',         32, 'dfa',           'frame +$10'),
    ('biu', 'flt_dib',          32, 'dib',           'long frame +$2C'),
    ('biu', 'flt_dob',          32, 'dob',           'frame +$18'),
    ('biu', 'flt_bytes',         3, 'bytes',         'SIZ cannot encode a five-byte residual'),
    ('biu', 'flt_rmc',           1, 'ssw',           'SSW RM'),
    ('biu', 'flt_rw',            1, 'ssw',           'SSW RW'),
    ('biu', 'flt_fc',            3, 'ssw',           'SSW FC2-FC0'),
    ('seq', 'df_q',              1, 'ssw',           'SSW DF -- see biu.flt_df'),
    ('seq', 'flt_upc',          16, 'upc',           'the faulted microword\'s own address, latched at the fault: by the time the frame builder writes +$14 its own upc is deep inside itself'),
    ('seq', 'link_q',           16, 'link',          'seq = RET returns here'),
    ('seq', 't_q',              32, 't0',            'one array of four in the RTL'),
    ('seq', 't_q',              32, 't1',            ''),
    ('seq', 't_q',              32, 't2',            ''),
    ('seq', 't_q',              32, 't3',            ''),
    ('seq', 'ea_q',             32, 'ea_latch',      ''),
    ('seq', 'ea_save',          32, 'ea_save',       "the frame builder's own pointer, so that ea_q -- which is the instruction's and is +$38 -- is not disturbed. RTE ignores what lands in this slot"),
    ('seq', 'xw_q',             16, 'xw',            ''),
    ('seq', 'notrace_q',         1, 'notrace',       'the instruction was never executed, so UM 6.1.7 does not trace it'),
    ('seq', 'eapc_q',            1, 'eapc',          'seq = EADEC latches it; EABASE reads it'),
    ('seq', 'size_q',            2, 'opsize',        'seq = EAMODE latches it; the shared EA routines read it'),
    ('seq', 'eadst_q',           1, 'eadst',         'likewise, and rsel reads it'),
    ('seq', 'cnt_q',             5, 'regcnt',        'MOVEM is restarted where it stopped'),
    ('seq', 'trace_mode_q',      2, 'trmode',        'UM 6.1.7 fixes it at the start of the instruction, so a fault may not lose it'),
    ('seq', 'flow_q',            1, 'flow',          'likewise: whether the instruction had changed the flow before it faulted'),
    ('seq', 'pc_prev_q',        32, 'pc_prev',       'a trace frame carries it at +$08'),
    ('seq', 'pc_kept_q',         1, 'pc_kept',      'pc_prev_q was taken at a flush, so the decode must not overwrite it'),
    ('seq', 'sr_q',             16, 'sr',            'frame +$00'),
]

# Rows of CHECKPOINT whose register the RTL does not have YET, and the milestone
# that builds it. They are listed rather than quietly skipped so that the table
# stays a description of the finished design and the check still says which
# parts of it are not there.
PENDING = {
}

# Every register in rtl/ that is NOT checkpointed, and the reason. check_rtl()
# below insists the two lists between them account for every clocked signal in
# the design -- so a register added without a thought about what a fault does to
# it is a build failure, not something M9 discovers.
EXEMPT = [
    # unit, register, why
    ('ifu', 'cnt_q',        'how many words the queue holds. Derived from the '
                            'rerun bits, which say which stages RTE still owes '
                            'a word: none if RC, one if RB alone, two if '
                            'neither.'),
    ('ifu', 'd_v_q',        'stage D is valid. Derived: RTE puts stage D back.'),
    ('ifu', 'primed_q',     'whether the pipe has ever been flushed. Always set '
                            'once the first instruction has been fetched.'),
    ('ifu', 'fetch_pend_q', 'a prefetch is outstanding. Derived: RTE re-issues '
                            'whatever the refill needs.'),
    ('ifu', 'fetch_addr_q', 'the address that prefetch was issued at. Likewise.'),
    ('ifu', 'fetch_fc2_q',  '... and the space, for the cache tag. Likewise.'),
    ('icache', 'valid_q',   'the instruction cache. UM 4.1 caches instruction '
                            'prefetches only, so it is architecturally '
                            'invisible; a fault leaves it alone and RTE has '
                            'nothing to put back.'),
    ('icache', 'mem',       '... its tags and data, which the valid bits gate'),
    ('ifu', 'ckpt_busy_q',  'RTE is in the middle of putting this pipe back, '
                            'so it does not fetch. It cannot be live across a '
                            'fault: a fault while RTE reads its own frame is a '
                            'double bus fault -- UM 6.1.2.'),
    ('ifu', 'discard_q',    'the word in flight belongs to a stream that is '
                            'gone. Likewise -- and RTE flushes anyway.'),

    # The bus unit's cycle-level state. A fault is recognised at the END of a
    # bus cycle and the bus is idle by the time the exception is taken, so none
    # of this is live across one. What IS live is the OPERAND residual, and that
    # is in CHECKPOINT above.
    # The RESET instruction's 512 clocks. No bus cycle runs while the counter
    # does -- the instruction asks for none and the sequencer is stalled, so the
    # pipe stands still too -- and therefore no fault can be taken in the middle
    # of it. PRM 6 also says the processor state other than the PC is
    # unaffected, so there is nothing here an exception handler could want.
    ('biu', 'req_end_q',    'how the last operand ended, as the sequencer is '
                            'told it. A fault is the one end code that outlives '
                            'the cycle, and it is in the SSW, which IS '
                            'checkpointed; the others are consumed by the '
                            'microword after the one that waited.'),

    ('biu', 'rst_pend_q',   'RTE has handed an operand back and the bus unit '
                            'has not picked it up yet. It lives for the clocks '
                            'between the handover and the next S0, inside one '
                            'instruction, and a fault in that window is a fault '
                            'on the rerun -- which UM 6.2.3 makes an ordinary '
                            'bus error with a frame of its own.'),

    ('biu', 'rsto_q',       'the RESET instruction is driving the pin'),
    ('biu', 'rsto_cnt',     '... for this many more clocks'),
    ('biu', 'rsto_arm_q',   '... and the request has been let go since, so the '
                            'count cannot restart itself'),

    # The live operand. What a fault frame carries is the SNAPSHOT above, taken
    # on the clock the fault is reported, because the frame is built by bus
    # cycles that run through these very registers -- doc/ssw.md.
    ('biu', 'op_addr',      'the address the operand now running is up to'),
    ('biu', 'op_data',      'its data, assembled or waiting to go out'),
    ('biu', 'op_rem',       'how many bytes of it are left'),
    ('biu', 'op_fc',        'its function code'),
    ('biu', 'op_rw',        'its direction'),
    ('biu', 'op_rmc',       'whether RMC is held across it'),

    ('biu', 'st_p',         'the bus state machine, rising-edge half'),
    ('biu', 'st_n',         '... and falling-edge half'),
    ('biu', 'cyc_addr',     'the address of the cycle now running'),
    ('biu', 'cyc_fc',       'its function code'),
    ('biu', 'cyc_rw',       'its direction'),
    ('biu', 'cyc_siz',      'its size code'),
    ('biu', 'cyc_n',        'how many bytes it asks for'),
    ('biu', 'd_latched',    'the data pins latched at S5'),
    ('biu', 'dsack_q',      'the port size the slave reported'),
    ('biu', 'term_q',       'how the cycle terminated'),
    ('biu', 'term_err',     '... bus error'),
    ('biu', 'term_rty',     '... retry'),
    ('biu', 'term_hlt',     '... halt'),
    ('biu', 'term_avc',     '... AVEC, on an interrupt acknowledge cycle'),
    ('biu', 'hiz_q',        'whether the address group is released'),
    ('biu', 'rdata_q',      'the result of the last read, held for the sequencer'),
    ('biu', 'frdata_q',     '... and of the last prefetch'),
    ('biu', 'req_ack',      'the handshake back to the sequencer'),
    ('biu', 'fetch_ack',    '... and to the fetch unit'),
    ('biu', 'req_fault',    'a fault is being reported this clock'),
    ('biu', 'req_fault_wr', '... on a write'),
    ('biu', 'fetch_fault',  '... on a prefetch'),
    ('biu', 'op_active',    'an operand is under way'),
    ('biu', 'op_first',     'no cycle of it has started yet -- OCS'),
    ('biu', 'op_isfetch',   'which of the two requesters it belongs to'),
    ('biu', 'arb',          'the arbiter. UM figure 5-44: it is not part of the '
                            'processor state and a fault does not disturb it.'),
    ('biu', 'bg_n_o',       'the grant pin'),
    ('biu', 'rmc_hold',     'arbitration is inhibited across a read-modify-write'),
    ('biu', 'halt_hold',    'the processor is halted'),

    ('seq', 'dreg',         'architectural: D0 to D7'),
    ('seq', 'areg',         'architectural: A0 to A6'),
    ('seq', 'usp_q',        'architectural. A7 is not a register -- it is '
                            'whichever of these three the S and M bits select.'),
    ('seq', 'isp_q',        'architectural'),
    ('seq', 'msp_q',        'architectural'),
    ('seq', 'vbr_q',        'architectural'),
    ('seq', 'sfc_q',        'architectural'),
    ('seq', 'dfc_q',        'architectural'),
    ('seq', 'cacr_q',       'architectural'),
    ('seq', 'caar_q',       'architectural'),
    ('seq', 'irq_prev_q',   'the interrupt level at the last instruction '
                            'boundary. It is about the PINS, not about the '
                            'instruction: a fault does not change what the '
                            'outside world is asking for, and UM 6.1.9 requires '
                            'the device to hold the level until it is '
                            'acknowledged.'),
    ('seq', 'irq_taking_q', 'the level of the interrupt being taken. Live only '
                            'between the dispatch and the acknowledge cycle, '
                            'and nothing in that span makes a DATA access that '
                            'could fault -- the acknowledge itself is in CPU '
                            'space and a fault there is a spurious interrupt, '
                            'not a bus fault. M9 revisits it.'),
    # PRM 6 STOP. The processor runs no bus cycle while stopped, so no fault can
    # be recognised there, and the interrupt that ends the stopped state clears
    # the bit on the same clock it enters exception processing. A stopped
    # processor is not a context worth saving: it has none.
    ('seq', 'stopped_q',    'the processor is stopped'),

    # UM 6.1.2: "if a bus error occurs during the exception processing for a bus
    # error, address error, or reset ... a double bus fault occurs and the
    # processor enters the halted state". So a frame is never built from inside
    # the window this bit marks -- the machine halts instead -- and there is
    # nothing for a frame field to say.
    ('seq', 'g0_q',         'the window in which a second fault is a double bus fault'),
    ('seq', 'flt_odd_q',    'this fault is an address error and not a bus '
                            'error, which is the only thing that differs '
                            'between the two frames they build'),
    ('seq', 'dbf_q',        'a double bus fault has halted the processor. UM '
                            '6.1.2: only an external reset restarts it, so '
                            'there is nothing to restore and nowhere to '
                            'restore it from'),
    ('seq', 'upc',          'the micro-address now running. The one a fault '
                            'frame carries is flt_upc, latched on the clock '
                            'the fault was reported -- by then this one is the '
                            "frame builder's own."),

    # The two halves of the pipe's state arrive in different microwords of the
    # RTE, and these hold them until they can be put together. RTE reading its
    # own frame cannot fault without it being a double bus fault -- UM 6.1.2 --
    # so there is no window in which they must survive one.
    ('seq', 'rs_rc_q',      'the special status word RTE has read back, taken '
                            'apart: RC'),
    ('seq', 'rs_rb_q',      '... RB'),
    ('seq', 'rs_df_q',      '... DF'),
    ('seq', 'rs_rm_q',      '... RM'),
    ('seq', 'rs_rw_q',      '... RW'),
    ('seq', 'rs_space_q',   '... and the address space of the data cycle'),
    ('seq', 'rupc_q',       'the micro-address RTE will resume at'),
    ('seq', 'rst_addr_q',   'the faulted operand RTE is handing back to the '
                            'bus unit: its address'),
    ('seq', 'rst_data_q',   '... whichever of its two data buffers the '
                            'direction makes meaningful'),
    ('seq', 'rst_bytes_q',  '... and how much of it is left'),

    ('seq', 'div_go_q',     'the divider is running. A divide makes no bus cycle, '
                            'so nothing can fault inside one: the microword that '
                            'reads the pipe comes after it.'),
    ('seq', 'div_fin_q',    'likewise'),

    # The divider's own working state, for the same reason.
    ('divider', 'acc',      'the running remainder'),
    ('divider', 'quo',      'the quotient so far'),
    ('divider', 'rem_num',  'what is left of the dividend'),
    ('divider', 'iter',     'the bit counter'),
    ('divider', 'run',      'it is running'),
    ('divider', 'den_q',    'the divisor'),
    ('divider', 'sq',       'the sign the quotient is to carry'),
    ('divider', 'sr',       '... and the remainder'),
    ('divider', 'ovf_q',    'the quotient will not fit'),
    ('divider', 'dz_q',     'the divisor was zero'),
    ('divider', 'mag_num',  'the dividend, unsigned'),
    ('divider', 'mag_den',  '... and the divisor'),

    ('sync',     'q',       'a synchroniser is not state, it is a pipe'),
    ('sync',     'rank0',   'likewise'),
    ('dedge_ff', 'half_p',  'half of a both-edge cell'),
    ('dedge_ff', 'half_n',  '... and the other half'),
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


# --------------------------------------------------------------------------
# The check that reads the RTL
# --------------------------------------------------------------------------
_MODULES = ('ifu', 'icache', 'biu', 'seq', 'divider', 'shifter', 'sync', 'dedge_ff', 'top')


def _unparen(text):
    """`text` with every parenthesised span removed."""
    out, depth = [], 0
    for ch in text:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(ch)
    return ''.join(out)


def rtl_registers(rtl_dir):
    """Every signal a clocked process writes, by module.

    A non-blocking assignment ends with an identifier and optional index
    expressions, and stands at a statement boundary; a comparison stands inside
    an expression. Unbalanced parentheses to the left of the name is what tells
    the two apart, so `if (a <= b)` and `for (i = 0; i <= 7; ...)` are rejected
    while a `q <= d` sharing its line with the `else if (...)` that guards it is
    not. Missing one of those would leave a register silently unchecked.
    """
    found = {}
    for name in _MODULES:
        path = os.path.join(rtl_dir, 'rd68021_%s.sv' % name)
        if not os.path.exists(path):
            continue
        text = re.sub(r'//[^\n]*', '', open(path).read())
        regs = set()
        for line in text.split('\n'):
            if '<=' not in line:
                continue
            for a in re.finditer('<=', line):
                left = line[:a.start()]
                m = re.search(r'([a-z_][a-z_0-9]*)((?:\[[^\]]*\])*)\s*$', left)
                if not m:
                    continue
                before = left[:m.start()]
                # Inside an expression -- `if (a <= b)`, `for (i = 0; i <= 7;)`
                # -- the parentheses are still open.
                if before.count('(') != before.count(')'):
                    continue
                # A blocking assignment on the same line means this `<=` is the
                # comparison in `y = a <= b`, not a register. Parenthesised `=`
                # belongs to a for-loop header, which may still guard one.
                if re.search(r'(?<![<>=!])=(?!=)', _unparen(before)):
                    continue
                regs.add(m.group(1))
        found[name] = regs
    return found


def check_rtl(rtl_dir):
    """Every register in the design is accounted for, one way or the other.

    doc/checkpoint.md rule 3: every register an instruction accumulates has a
    home in the frame or it does not exist. This is that rule, enforced against
    the SOURCE rather than against the microcode -- because a register the
    microcode never names as a destination is exactly the kind the old check
    could not see, and five of them got past it.
    """
    bad = []
    found = rtl_registers(rtl_dir)
    if not found:
        return ['checkpoint: no RTL was read, so this check proved nothing']

    kept   = {(u, r) for u, r, _, _, _ in CHECKPOINT}
    waived = {(u, r) for u, r, _ in EXEMPT}

    for unit, regs in sorted(found.items()):
        for r in sorted(regs):
            if (unit, r) not in kept and (unit, r) not in waived:
                bad.append('%s.%s is a register and is neither checkpointed nor '
                           'exempt -- doc/checkpoint.md rule 3' % (unit, r))

    # And the other way: a row naming a register that is not there is a rename
    # nobody followed through, which would leave the real one unaccounted for.
    for unit, r in sorted(kept | waived):
        if unit in found and r not in found[unit] and (unit, r) not in PENDING:
            bad.append('%s.%s is in the checkpoint tables and is not a register '
                       'in rtl/rd68021_%s.sv' % (unit, r, unit))

    # A pending register that has arrived is one nobody removed from the list,
    # and the list is what stops it being forgotten.
    for (unit, r), why in sorted(PENDING.items()):
        if unit in found and r in found[unit]:
            bad.append('%s.%s exists now; take it out of PENDING (%s)'
                       % (unit, r, why))
    return bad


def pending_summary():
    return sorted('%s.%s (%s)' % (u, r, w) for (u, r), w in PENDING.items())


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
