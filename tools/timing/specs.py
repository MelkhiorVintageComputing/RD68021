#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68021

"""Section 10's AC electrical specifications, as data.

    python3 tools/timing/specs.py --dump           # every row, every grade
    python3 tools/timing/specs.py --dump --freq 20

The source is `Inputs/doc/.../MC68020UM_split/ac-electrical-specifications.csv`,
which was parsed out of the manual's text layer rather than transcribed. This
module adds the judgements the CSV cannot carry: which rows are one specification
and which are two, what an em dash means in each column, and which of the four
frequency columns apply to a given part.

The limits live here and not in SystemVerilog. The testbenches emit times and
nothing else -- no testbench knows what a specification is. That is what lets a
wrong anchor be fixed with a one-line edit and a re-analysis in milliseconds
instead of a re-simulation, and it is what would let a second core, in another
language, be judged by exactly the same code.
"""

import argparse
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CSV = os.path.join(ROOT, 'Inputs', 'doc', 'MC68030_Doc_More_Readable',
                   'MC68020UM_split', 'ac-electrical-specifications.csv')

# The manual prints four speed grades. A design is conformant only if it is
# conformant at the grade it is built for; `make timing` reports all four.
FREQS = ['16_67', '20', '25', '33_33']
FREQ_MHZ = {'16_67': 16.67, '20': 20.0, '25': 25.0, '33_33': 33.33}

# The nominal clock period each grade's minimum cycle time gives (specification 1).
FREQ_PERIOD_NS = {'16_67': 60.0, '20': 50.0, '25': 40.0, '33_33': 30.0}

EM_DASH = '—'   # the manual's "not specified"
EN_DASH = '–'   # the manual's minus sign, in specification 9A's minimum


def _num(text):
    """One printed cell. Returns a float, or None for the manual's em dash."""
    t = (text or '').strip()
    if not t or t == EM_DASH or t == '-' or t == '--':
        return None
    t = t.replace(EN_DASH, '-')
    return float(t)


class Spec(object):
    """One row of Section 10, at all four grades."""

    def __init__(self, row):
        self.num = row['num'].strip()
        self.condition = row['condition'].strip()
        self.characteristic = row['characteristic'].strip()
        self.unit = row['unit'].strip()
        self.footnotes = [f for f in row['footnotes'].strip().split(',') if f]
        self.table = row['table'].strip()
        self.limits = {}
        for f in FREQS:
            self.limits[f] = (_num(row['f%s_min' % f]), _num(row['f%s_max' % f]))

    @property
    def key(self):
        """Specification 45 is printed twice, once for a read and once for a
        write, and they are different numbers. Nothing else repeats, so the key
        is the number plus whichever condition distinguishes it."""
        return (self.num, self.condition)

    @property
    def name(self):
        if self.condition:
            return '%s (%s)' % (self.num, self.condition)
        return self.num

    def ns(self, freq):
        """The limits in nanoseconds at one grade.

        Seven rows are printed in clock periods rather than nanoseconds -- the
        arbitration handshakes, the RESET instruction's pulse and the reset input
        transition time. They are converted here using that grade's minimum cycle
        time, which is specification 1, so that everything downstream works in one
        unit. A limit in clocks is exact at every frequency; a limit in
        nanoseconds is not, which is the whole reason the manual mixes them.
        """
        lo, hi = self.limits[freq]
        if self.unit == 'Clks':
            p = FREQ_PERIOD_NS[freq]
            lo = None if lo is None else lo * p
            hi = None if hi is None else hi * p
        elif self.unit != 'ns':
            return (None, None)       # MHz: the frequency row itself
        return (lo, hi)


def load(path=CSV):
    """Every specification, keyed by (number, condition)."""
    out = {}
    with open(path) as fh:
        for row in csv.DictReader(fh):
            s = Spec(row)
            if not s.num:
                continue              # the unnumbered "Frequency of Operation" row
            if s.key in out:
                raise SystemExit('specs: duplicate key %r -- the CSV has changed '
                                 'and this module has not' % (s.key,))
            out[s.key] = s
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--freq', default=None, choices=FREQS)
    args = ap.parse_args()

    specs = load()
    if not args.dump:
        print('%d specifications, %d limits'
              % (len(specs), sum(1 for s in specs.values() for f in FREQS
                                 for v in s.limits[f] if v is not None)))
        return 0

    freqs = [args.freq] if args.freq else FREQS
    for key in sorted(specs, key=lambda k: (k[0].rstrip('AB'), k[0], k[1])):
        s = specs[key]
        cells = []
        for f in freqs:
            lo, hi = s.ns(f)
            cells.append('%8s %8s' % ('-' if lo is None else '%.1f' % lo,
                                      '-' if hi is None else '%.1f' % hi))
        print('%-10s %-58s %s  %s' % (s.name, s.characteristic[:58],
                                      ' '.join(cells),
                                      ','.join(s.footnotes)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
