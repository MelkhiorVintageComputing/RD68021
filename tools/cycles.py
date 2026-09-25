#!/usr/bin/env python3
"""Instruction clock counts against UM section 8.

    python3 tools/cycles.py gen   > build/cycles.vec
    python3 tools/cycles.py check build/cycles.out [--doc doc/timing-divergences.md]

`gen` writes one row per instruction for sim/tb/core_cycles_tb.sv. The testbench
runs each row's program -- a fixed prologue, the row's setup, the instruction,
a landing pad of NOPs -- twice round a loop with the instruction cache on, and
reports the clocks from the instruction boundary before the instruction to the
one after it, on both passes. The first pass is COLD (the cache is empty, so
it is near the manual's worst case); the second is WARM (every word is in the
cache, which is the manual's "cache case": in the cache, no overlap).

`check` compares the warm count with OURS below and fails if any row moved.
Every row is a regression check, not a report: the number this design takes is
written down, and a change to it -- faster or slower -- is a change someone has
to look at and then write down. It also regenerates the table in
doc/timing-divergences.md between its markers when --doc is given.

UM is the arbiter for the manual's numbers. Each row's CC is the cache-case
total: the instruction's own entry plus, where its table's footnote says so,
the fetch-effective-address (8.2.1), fetch-immediate (8.2.2), calculate (8.2.3),
calculate-immediate (8.2.4) or jump (8.2.5) entry for its mode. The sum is
written out in the row so it can be checked against the manual by eye.

The prologue, every pass:

    D0=$11 D1=2 D2=$1F D3=5 D4=0 D5=0  A0=$2000 A1=$2100 A2=$2200 A3=$3000
    A5=X+2 (the word after a one-word instruction)  SP=$1000  D6=1 (so Z is clear)

$3000 holds an RTS. Vector 32 (TRAP #0) points at an RTE; vectors 4 and 10
(illegal, line A) at a handler that steps the stacked PC past the instruction
and returns.
"""

import re
import sys

# (name, setup words, instruction words, manual cache case, how it adds up, ours)
#
# `ours` is None for a row whose count has not been frozen yet; `check` prints
# it and fails, so a new row cannot slip in unexamined.
ROWS = [
    # --- 8.2.8 / 8.2.9: arithmetic, with the fetch-EA time for the source mode
    ('NOP',                    [], [0x4E71],                 2,  '2', 1),
    ('MOVEQ #1,D4',            [], [0x7801],                 2,  '2', 1),
    ('ADD.L D0,D4',            [], [0xD880],                 2,  '2 + Dn 0', 2),
    ('ADD.L (A0),D4',          [], [0xD890],                 6,  '2 + (An) 4', 6),
    ('ADD.L (A0)+,D4',         [], [0xD898],                 6,  '2 + (An)+ 4', 6),
    ('ADD.L -(A1),D4',         [], [0xD8A1],                 7,  '2 + -(An) 5', 6),
    ('ADD.L (8,A0),D4',        [], [0xD8A8, 0x0008],         7,  '2 + (d16,An) 5', 7),
    ('ADD.L ($2000).W,D4',     [], [0xD8B8, 0x2000],         6,  '2 + (xxx).W 4', 8),
    ('ADD.L ($2000).L,D4',     [], [0xD8B9, 0x0000, 0x2000], 6,  '2 + (xxx).L 4', 9),
    ('ADD.L #imm,D4',          [], [0xD8BC, 0x1234, 0x5678], 6,  '2 + #.L 4', 4),
    ('ADD.L (4,A0,D3.L),D4',   [], [0xD8B0, 0x3804],         9,  '2 + (d8,An,Xn) 7', 13),
    ('ADD.L ([A0]),D4',        [], [0xD8B0, 0x0151],         14, '2 + ([B],I) 12', 20),
    ('ADD.L D4,(A0)',          [], [0xD990],                 8,  '4 + (An) 4', 11),
    ('CMP.L D0,D4',            [], [0xB880],                 2,  '2', 2),
    ('CMPA.L A0,A2',           [], [0xB5C8],                 4,  '4', 3),
    ('MULU.W D1,D4',           [], [0xC8C1],                 27, '27', 4),
    ('MULU.L D1,D4',           [], [0x4C01, 0x4004],         45, '43 + #.W,Dn 2', 6),
    ('DIVU.W D1,D4',           [], [0x88C1],                 44, '44', 44),
    ('DIVS.W D1,D4',           [], [0x89C1],                 56, '56', 44),
    ('DIVU.L D1,D4',           [], [0x4C41, 0x4004],         80, '78 + #.W,Dn 2', 44),
    ('DIVS.L D1,D4',           [], [0x4C41, 0x4804],         92, '90 + #.W,Dn 2', 44),
    ('ADDQ.L #1,D4',           [], [0x5284],                 2,  '2', 1),
    ('ADDQ.L #1,(A0)',         [], [0x5290],                 8,  '4 + (An) 4', 9),
    ('ADDI.L #imm,D4',         [], [0x0684, 0x1234, 0x5678], 6,  '2 + #.L,Dn 4', 4),
    ('ADDI.W #1,(A0)',         [], [0x0650, 0x0001],         8,  '4 + #.W,(An) 4', 12),
    # --- 8.2.10
    ('ABCD D0,D4',             [], [0xC900],                 4,  '4', 1),
    ('ABCD -(A1),-(A2)',       [], [0xC509],                 16, '16', 18),
    ('ADDX.L D0,D4',           [], [0xD980],                 2,  '2', 1),
    ('CMPM.L (A0)+,(A1)+',     [], [0xB388],                 9,  '9', 15),
    ('PACK D0,D4,#0',          [], [0x8940, 0x0000],         6,  '6', 3),
    ('UNPK D0,D4,#0',          [], [0x8980, 0x0000],         8,  '8', 3),
    # --- 8.2.11
    ('CLR.L D4',               [], [0x4284],                 2,  '2', 2),
    ('CLR.L (A0)',             [], [0x4290],                 6,  '4 + calc (An) 2', 4),
    ('NEG.L D4',               [], [0x4484],                 2,  '2', 2),
    ('EXT.L D4',               [], [0x48C4],                 4,  '4', 1),
    ('NBCD D4',                [], [0x4804],                 6,  '6', 2),
    ('ST D4',                  [], [0x50C4],                 4,  '4', 2),
    ('TAS D4',                 [], [0x4AC4],                 4,  '4', 2),
    ('TAS (A0)',               [], [0x4AD0],                 14, '12 + calc (An) 2', 13),
    ('TST.L D4',               [], [0x4A84],                 2,  '2 + Dn 0', 2),
    ('TST.L (A0)',             [], [0x4A90],                 6,  '2 + (An) 4', 6),
    # --- 8.2.12
    ('LSL.L #1,D4',            [], [0xE38C],                 4,  '4', 1),
    ('LSL.L D1,D4',            [], [0xE3AC],                 6,  '6', 1),
    ('ASL.L #1,D4',            [], [0xE384],                 8,  '8', 1),
    ('ASR.L #1,D4',            [], [0xE284],                 6,  '6', 1),
    ('ROL.L #1,D4',            [], [0xE39C],                 8,  '8', 1),
    ('ROXL.L #1,D4',           [], [0xE394],                 12, '12', 1),
    ('LSL.W (A0)',             [], [0xE3D0],                 9,  '5 + (An) 4', 11),
    # --- 8.2.13
    ('BTST #3,D4',             [], [0x0804, 0x0003],         4,  '4', 3),
    ('BTST D1,D4',             [], [0x0304],                 4,  '4', 2),
    ('BSET D1,D4',             [], [0x03C4],                 4,  '4', 2),
    ('BTST D1,(A0)',           [], [0x0310],                 8,  '4 + (An) 4', 9),
    ('BSET D1,(A0)',           [], [0x03D0],                 8,  '4 + (An) 4', 13),
    # 13, was 12: the bit number is kept in T0 across the effective address
    # and put back, since an indexed address decodes its own extension word in
    # XW where the number was -- doc/bugs-found.md, M12.
    ('BTST #3,(A0)',           [], [0x0810, 0x0003],         8,  '4 + #.W,(An) 4', 11),
    # --- 8.2.14, with the calculate-immediate time for the mode
    ('BFTST D4{0:8}',          [], [0xE8C4, 0x0008],         6,  '6', 2),
    ('BFEXTU D4{0:8},D5',      [], [0xE9C4, 0x5008],         8,  '8', 3),
    ('BFINS D5,D4{0:8}',       [], [0xEFC4, 0x5008],         10, '10', 4),
    ('BFFFO D4{0:8},D5',       [], [0xEDC4, 0x5008],         18, '18', 3),
    ('BFCHG D4{0:8}',          [], [0xEAC4, 0x0008],         12, '12', 4),
    ('BFEXTU (A0){0:8},D5',    [], [0xE9D0, 0x5008],         15, '13 + #.W,(An) 2', 12),
    ('BFINS D5,(A0){0:8}',     [], [0xEFD0, 0x5008],         16, '14 + #.W,(An) 2', 17),
    ('BFTST (A0){4:32}',       [], [0xE8D0, 0x0100],         17, '15 (5 bytes) + #.W,(An) 2', 14),
    # --- 8.2.15
    ('BRA.S (taken)',          [], [0x6002],                 6,  '6', 6),
    ('BRA.W (taken)',          [], [0x6000, 0x0004],         6,  '6', 6),
    ('BRA.L (taken)',          [], [0x60FF, 0x0000, 0x0006], 6,  '6', 8),
    ('BEQ.S (not taken)',      [], [0x6702],                 4,  '4', 2),
    ('BEQ.W (not taken)',      [], [0x6700, 0x0004],         6,  '6', 3),
    ('BEQ.L (not taken)',      [], [0x67FF, 0x0000, 0x0006], 6,  '6', 5),
    ('DBF (count not expired)', [], [0x51CE, 0x0002],        6,  '6', 6),
    ('DBF (count expired)',    [0x7C00], [0x51CE, 0x0002],   10, '10', 4),
    ('DBT (cc true)',          [], [0x50CE, 0x0002],         6,  '6', 3),
    # --- 8.2.7
    ('EXG D0,D4',              [], [0xC144],                 2,  '2', 3),
    ('SWAP D4',                [], [0x4844],                 4,  '4', 1),
    ('MOVE SR,D4',             [], [0x40C4],                 4,  '4', 2),
    ('MOVE D0,CCR',            [], [0x44C0],                 4,  '4 + Dn 0', 2),
    ('MOVE #$2700,SR',         [], [0x46FC, 0x2700],         10, '8 + #.W 2', 3),
    ('MOVE A0,USP',            [], [0x4E60],                 2,  '2', 2),
    ('MOVEC CACR,D4',          [], [0x4E7A, 0x4002],         6,  '6', 3),
    ('MOVEC D4,SFC',           [], [0x4E7B, 0x4000],         12, '12', 3),
    ('MOVEM.L D0-D3,(A2)',     [], [0x48D2, 0x000F],         18, '4 + 3x4 + #.W,(An) 2', 25),
    ('MOVEM.L (A0),D4-D5',     [], [0x4CD0, 0x0030],         18, '8 + 4x2 + #.W,(An) 2', 17),
    ('MOVEP.L D4,(0,A2)',      [], [0x09CA, 0x0000],         17, '17', 26),
    ('MOVEP.L (0,A0),D4',      [], [0x0948, 0x0000],         18, '18', 26),
    ('MOVES.L (A0),D4',        [], [0x0E90, 0x4000],         9,  '7 + #.W,(An) 2', 12),
    # --- 8.2.6
    ('MOVE.L D0,D4',           [], [0x2800],                 2,  'Rn -> Dn', 2),
    ('MOVEA.L A0,A4',          [], [0x2848],                 2,  'Rn -> An', 3),
    ('MOVE.W #1,D4',           [], [0x383C, 0x0001],         4,  '#.W -> Dn', 2),
    ('MOVE.L #imm,D4',         [], [0x283C, 0x1234, 0x5678], 6,  '#.L -> Dn', 4),
    ('MOVE.L D0,(A2)',         [], [0x2480],                 4,  'Rn -> (An)', 5),
    ('MOVE.L D0,-(A2)',        [], [0x2500],                 5,  'Rn -> -(An)', 6),
    ('MOVE.L (A0),D4',         [], [0x2810],                 6,  '(An) -> Dn', 6),
    ('MOVE.L (8,A0),D4',       [], [0x2828, 0x0008],         7,  '(d16,An) -> Dn', 7),
    ('MOVE.L (4,A0,D3.L),D4',  [], [0x2830, 0x3804],         9,  '(d8,An,Xn) -> Dn', 13),
    ('MOVE.L (A0),(A2)',       [], [0x2490],                 7,  '(An) -> (An)', 9),
    ('MOVE.L (A0)+,(A2)+',     [], [0x24D8],                 7,  '(An)+ -> (An)+', 10),
    # --- 8.2.16, with the jump or calculate time for the mode
    ('ORI #0,CCR',             [], [0x003C, 0x0000],         12, '12', 2),
    ('ANDI #$FFFF,SR',         [], [0x027C, 0xFFFF],         12, '12', 3),
    ('LEA (A0),A4',            [], [0x49D0],                 4,  '2 + calc (An) 2', 3),
    ('LEA (8,A0),A4',          [], [0x49E8, 0x0008],         4,  '2 + calc (d16,An) 2', 3),
    ('PEA (A0)',               [], [0x4850],                 7,  '5 + calc (An) 2', 8),
    ('LINK.W A4,#-8',          [], [0x4E54, 0xFFF8],         5,  '5', 8),
    ('LINK.L A4,#-8',          [], [0x480C, 0xFFFF, 0xFFF8], 6,  '6', 10),
    ('UNLK A4',                [0x4E54, 0x0000], [0x4E5C],   6,  '6', 7),
    ('JMP (A5)',               [], [0x4ED5],                 6,  '4 + jump (An) 2', 6),
    ('JSR (A3)',               [], [0x4E93],                 7,  '5 + jump (An) 2', 11),
    ('BSR.S',                  [], [0x6102, 0x6002, 0x4E75], 7,  '7', 11),
    ('RTS',                    [0x487A, 0x0004], [0x4E75],   10, '10', 8),
    ('RTR',                    [0x487A, 0x0008, 0x3F3C, 0x0000], [0x4E77],
                                                             14, '14', 17),
    ('RTD #4',                 [0x2F00, 0x487A, 0x0006], [0x4E74, 0x0004],
                                                             10, '10', 12),
    ('RTE (format 0)',         [0x3F3C, 0x0000, 0x487A, 0x0008, 0x3F3C, 0x2700],
                               [0x4E73],                     21, '21', 31),
    # A coprocessor midinstruction frame -- UM figure 7-43, built from the top:
    # the effective address, the internal word and operation word ($F200, cpGEN
    # to CpID 1), the program counter, format $9, the scanPC -- the landing pad
    # -- and the status register. RTE ends by reading the response CIR, and
    # sim/models/rd68021_cpmodel.sv answers "processing finished".
    ('RTE (coprocessor)',      [0x4878, 0x0000, 0x2F3C, 0x0000, 0xF200, 0x4855,
                                0x3F3C, 0x9000, 0x4855, 0x3F3C, 0x2700],
                               [0x4E73],                     31, '31', 67),
    ('CHK.L D1,D4 (in range)', [], [0x4901],                 8,  '8 + Dn 0', 5),
    ('CHK2.L (A0),D4',         [], [0x04D0, 0x4800],         22, '18 + #.W,(An) 4', 22),
    ('CMP2.L (A0),D4',         [], [0x04D0, 0x4000],         22, '18 + #.W,(An) 4', 21),
    ('CAS.L (unsuccessful)',   [], [0x0ED0, 0x0040],         14, '12 + #.W,(An) 2', 13),
    ('CAS.L (successful)',     [0x4290], [0x0ED0, 0x0044],   17, '15 + #.W,(An) 2', 17),
    ('CAS2.L (successful)',    [0x4290, 0x4291], [0x0EFC, 0x8044, 0x9085],
                                                             25, '25', 38),
    # --- 8.2.17
    ('TRAPV (no trap)',        [], [0x4E76],                 4,  '4', 2),
    ('TRAPF',                  [], [0x51FC],                 4,  '4', 2),
    ('TRAPF.W',                [], [0x51FA, 0x0000],         6,  '6', 3),
    ('TRAPF.L',                [], [0x51FB, 0x0000, 0x0000], 8,  '8', 4),
    ('TRAP #0',                [], [0x4E40],                 20, '20', 33),
    ('ILLEGAL',                [], [0x4AFC],                 20, '20', 38),
    ('line A',                 [], [0xA000],                 20, '20', 38),
    ('RESET',                  [], [0x4E70],                 518, '518', 515),
]


def gen():
    print(len(ROWS))
    for k, (name, pre, ins, cc, how, ours) in enumerate(ROWS):
        tag = 'r%d' % k
        words = [len(pre)] + pre + [len(ins)] + ins
        print(tag, ' '.join('%x' % w for w in words))


def load(path):
    got = {}
    with open(path) as fh:
        for line in fh:
            m = re.match(r'^CYCLES (\S+) (\d+) (\d+)', line)
            if m:
                got[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return got


def check(path, doc=None):
    got = load(path)
    bad = 0
    rows = []
    for k, (name, pre, ins, cc, how, ours) in enumerate(ROWS):
        # By position and not by name: names differ in punctuation, and a tag
        # made from one collapsed (A0), (A0)+ and ([A0]) into the same row.
        tag = 'r%d' % k
        if tag not in got:
            print(f'  FAIL: {name}: no measurement')
            bad += 1
            continue
        warm, cold = got[tag]
        if ours is None:
            print(f'  NEW:  {name}: {warm} warm, {cold} cold (manual {cc}) -- '
                  f'freeze it in tools/cycles.py')
            bad += 1
        elif warm != ours:
            print(f'  FAIL: {name}: {warm} clocks, was {ours} (manual {cc})')
            bad += 1
        rows.append((name, how, cc, warm, cold))
    if doc:
        splice(doc, rows)
    n = len(rows)
    same = sum(1 for r in rows if r[3] == r[2])
    faster = sum(1 for r in rows if r[3] < r[2])
    slower = n - same - faster
    tot_m = sum(r[2] for r in rows if r[2] < 500)
    tot_o = sum(r[3] for r in rows if r[2] < 500)
    print(f'  cycles: {n} instructions -- {same} exact, {faster} faster, '
          f'{slower} slower; {tot_o} clocks against the manual\'s {tot_m} '
          f'(RESET aside)')
    if bad:
        print('FAIL: cycles')
        return 1
    print('PASS: cycles')
    return 0


BEGIN = '<!-- cycles:begin -- generated by tools/cycles.py; do not edit -->'
END = '<!-- cycles:end -->'


def splice(doc, rows):
    lines = ['| Instruction | UM 8 cache case | | This core, warm | Δ | cold |',
             '|---|---:|---|---:|---:|---:|']
    for name, how, cc, warm, cold in rows:
        d = warm - cc
        mark = '' if d == 0 else ('**%+d**' % d if d > 0 else '%+d' % d)
        lines.append(f'| `{name}` | {cc} | {how} | {warm} | {mark} | {cold} |')
    table = '\n'.join(lines)
    text = open(doc).read()
    if BEGIN not in text:
        raise SystemExit(f'{doc} has no {BEGIN!r} marker')
    a = text.index(BEGIN) + len(BEGIN)
    b = text.index(END)
    text = text[:a] + '\n' + table + '\n' + text[b:]
    open(doc, 'w').write(text)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == 'gen':
        gen()
        return 0
    if len(sys.argv) >= 3 and sys.argv[1] == 'check':
        doc = sys.argv[4] if len(sys.argv) >= 5 and sys.argv[3] == '--doc' else None
        return check(sys.argv[2], doc)
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main())
