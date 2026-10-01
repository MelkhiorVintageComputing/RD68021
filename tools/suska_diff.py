#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68021

"""Compare this core's bus with the Suska WF68K30L's, on the same probe.

    python3 tools/suska_diff.py <suska.bus> <rd68021.bus>

Each file has one `BUS fc address siz R|W data` line per bus cycle. The DATA
cycles -- function codes 1 and 5 -- are compared in order, one bus cycle at a
time: the address, SIZ, direction, whether RMC was asserted, and for a write
the data on all four byte lanes. That is UM tables 5-6 and 5-7 in full: how an operand is split across a
port, what SIZ says at each step, and what is duplicated onto which lanes.

Instruction fetches are only counted. The two cores fetch differently by design
-- this one a long word at a time through a cache, the other a word at a time
-- so their order and number mean nothing to each other.
"""

import sys


def load(path):
    data, fetch = [], 0
    for line in open(path):
        p = line.split()
        if not p or p[0] != 'BUS':
            continue
        fc = int(p[1])
        if fc in (1, 5):
            data.append((p[1], p[2].lower(), p[3], p[4], p[5].lower(),
                         p[6] if len(p) > 6 else '?'))
        elif fc in (2, 6):
            fetch += 1
    return data, fetch


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    ds, fs = load(sys.argv[1])
    dr, fr = load(sys.argv[2])
    n = min(len(ds), len(dr))
    for i in range(n):
        if ds[i] != dr[i]:
            print(f'FAIL: data cycle {i} differs')
            for j in range(max(0, i - 3), min(n, i + 4)):
                mark = '>>' if j == i else '  '
                print(f'  {mark} suska {" ".join(ds[j])}   rd68021 {" ".join(dr[j])}')
            return 1
    if len(ds) != len(dr):
        print(f'FAIL: suska made {len(ds)} data cycles and this core {len(dr)}')
        return 1
    print(f'  suska: {n} data cycles identical -- address, SIZ, direction, RMC '
          f'and write lanes; instruction fetches {fs} there and {fr} here')
    print('PASS: suska')
    return 0


if __name__ == '__main__':
    sys.exit(main())
