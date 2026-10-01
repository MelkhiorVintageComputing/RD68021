#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68021

"""Hold a cached and an uncached run of the same program to the same bus.

    python3 tools/cache_diff.py <uncached.bus> <cached.bus>

Each file is one line per bus cycle, as sim/tb/core_cosim_tb.sv writes it with
+buslog: requester (F = instruction pipe, D = anything else), function code,
address, size, direction, write data.

UM 4.1: the cache holds "instruction prefetches ... as they are requested by the
CPU" and "data accesses are not cached, regardless of their associated address
space". So between a core with the cache and one without:

  - the D cycles must be IDENTICAL, in the same order, one for one. That includes
    program-space operand reads (PC-relative addressing), which the manual says
    are program references and which are still not cached.
  - the F cycles may only be FEWER. The two runs do not fetch in the same order
    -- how far the pipe gets ahead of a branch depends on timing, and the timing
    is what the cache changes -- so this is a count, not a sequence.

The runs stop at the same instruction boundary but not at the same clock, so the
last few cycles of the longer log can be ones the shorter never reached. A D
cycle there is a difference only if it is a WRITE: a trailing read is the next
instruction's operand being fetched early by one run and not yet by the other.
"""

import sys


def load(path):
    f, d = 0, []
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == 'F':
                f += 1
            else:
                d.append(tuple(parts[1:]))
    return f, d


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    f0, d0 = load(sys.argv[1])
    f1, d1 = load(sys.argv[2])

    n = min(len(d0), len(d1))
    for i in range(n):
        if d0[i] != d1[i]:
            print(f'FAIL: data cycle {i} differs: uncached {d0[i]}, cached {d1[i]}')
            return 1
    tail = d0[n:] + d1[n:]
    if len(tail) > 2 or any(t[3] == 'W' for t in tail):
        print(f'FAIL: the runs differ by {len(tail)} trailing data cycles: {tail[:4]}')
        return 1
    if f1 > f0:
        print(f'FAIL: the cached run made MORE instruction fetches: {f1} against {f0}')
        return 1
    saved = 100.0 * (f0 - f1) / f0 if f0 else 0.0
    print(f'{n} data cycles identical; instruction fetches {f0} -> {f1} '
          f'({saved:.1f}% taken by the cache)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
