#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68021

"""Is there any pad-delay assignment that meets Section 10?

    python3 tools/timing/analyse.py build/timing-events.log
    python3 tools/timing/analyse.py --freq 16_67 --verbose build/timing-events.log
    python3 tools/timing/analyse.py --pad-skew 5 build/timing-events.log

Builds the difference-constraint system that anchors.py describes out of the
times that the testbench recorded, and solves it once per speed grade. The answer
is exact: either an assignment exists, in which case one is printed, or a set of
limits contradict each other, in which case those limits are printed.

INFEASIBLE is a proof. FEASIBLE is conditional on the pad model: --pad-skew is how
far apart the delays of one pin's transitions may be, and it defaults to 0, which
is one delay per pin. The looser reading is printed alongside so that the
difference is visible rather than assumed away.
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import anchors                                                  # noqa: E402
import events as events_mod                                     # noqa: E402
import feasible                                                 # noqa: E402
import specs as specs_mod                                       # noqa: E402


def pin_of(event):
    return event.split('.')[0]


def build(log, spec_table, freq, pad_skew):
    """The whole system, plus the list of things that could not be measured."""
    sys_ = feasible.System()
    unmeasured = []
    done = set()

    # Pad-delay budgets.
    for key, evs, edge, tag in anchors.PAD:
        spec = spec_table[key]
        lo, hi = spec.ns(freq)
        if lo is None and hi is None:
            continue
        for ev in evs:
            seen = 0
            for scen in anchors.scenarios_for(tag):
                for occ in events_mod.occurrences(log.get(scen, []), ev):
                    seen += 1
                    if occ.edge != edge:
                        unmeasured.append(
                            ('%s' % spec.name,
                             'measured from CLK %s but %s moves on a %s edge'
                             % ('high' if edge == 'R' else 'low', ev,
                                'rising' if occ.edge == 'R' else 'falling')))
                        break
            if seen == 0:
                unmeasured.append(('%s' % spec.name,
                                   'no %s in the %s log' % (ev, tag)))
                continue
            sys_.bound(ev, lo, hi, '%s %s' % (spec.name, ev))
            done.add(key)

    # Separations.
    for key, a, b, tag in anchors.SEP:
        spec = spec_table[key]
        lo, hi = spec.ns(freq)
        n = 0
        for scen in anchors.scenarios_for(tag):
            for ea, eb in events_mod.pairs(log.get(scen, []), a, b):
                sys_.sep(ea.name, ea.t, eb.name, eb.t, lo, hi,
                         '%s %s->%s (%s, %.0f ns apart)'
                         % (spec.name, a, b, scen, eb.t - ea.t))
                n += 1
        if n == 0:
            unmeasured.append(('%s' % spec.name,
                               'no %s followed by %s in the %s log' % (a, b, tag)))
        else:
            done.add(key)

    # One pin, one delay -- or several, within pad_skew of each other.
    by_pin = {}
    for v in sorted(sys_.vars):
        if v.startswith('#'):
            continue
        by_pin.setdefault(pin_of(v), []).append(v)
    for pin, vs in sorted(by_pin.items()):
        for i in range(len(vs) - 1):
            sys_.le(vs[i], vs[i + 1], pad_skew, None)
            sys_.le(vs[i + 1], vs[i], pad_skew, None)

    return sys_, len(done), unmeasured


def run(path, freqs, pad_skew, verbose):
    log = events_mod.read(path)
    spec_table = specs_mod.load()

    missing, stale = anchors.check_complete(spec_table)
    if missing or stale:
        print('FAIL: the anchor table does not cover Section 10')
        return 1

    bad = 0
    for freq in freqs:
        sys_, measured, unmeasured = build(log, spec_table, freq, pad_skew)
        ok, dist, cycle = sys_.solve()
        mhz = specs_mod.FREQ_MHZ[freq]

        if not ok:
            bad += 1
            print('%6.2f MHz  INFEASIBLE -- these limits contradict each other:'
                  % mhz)
            total = 0.0
            for y, x, c, why in cycle:
                total += c
                print('           d[%s] - d[%s] <= %7.1f   %s'
                      % (x, y, c, why if why else '(one pin, one delay)'))
            print('           round trip: %.1f ns, which cannot be met' % total)
            continue

        margins = sys_.margins()
        seps = [(m, why) for m, why, kind in margins if kind == 'sep']
        bnds = [(m, why) for m, why, kind in margins if kind == 'bound']

        # The binding constraint is the tightest SEPARATION. A bound's margin is
        # the width the manual printed for that pad delay and says nothing about
        # this design, so quoting it as a margin would flatter or damn the design
        # by accident.
        tight = seps[0] if seps else (float('inf'), 'nothing')
        print('%6.2f MHz  feasible, %d specifications measured, '
              '%.1f ns of room on the binding constraint'
              % (mhz, measured, tight[0]))
        print('           %s' % tight[1])
        if bnds:
            print('           tightest pad-delay budget: %.1f ns, %s'
                  % (bnds[0][0], bnds[0][1]))
        if verbose:
            print('           a pad assignment that meets every limit:')
            seen = set()
            for v in sorted(dist):
                if not v.startswith('#'):
                    seen.add(v)
                    print('             %-16s %6.1f ns' % (v, dist[v] - dist['#0']))
            print('           tightest five separations:')
            last = None
            n = 0
            for m, why in seps:
                if why == last:
                    continue
                last = why
                print('             %6.1f ns  %s' % (m, why))
                n += 1
                if n == 5:
                    break

    if unmeasured and verbose:
        print('\nnot measured by this run:')
        for name, why in unmeasured:
            print('  %-10s %s' % (name, why))

    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--freq', default=None, choices=specs_mod.FREQS)
    ap.add_argument('--pad-skew', type=float, default=0.0,
                    help='how far apart one pin\'s transition delays may be '
                         '(default 0: one delay per pin)')
    ap.add_argument('--verbose', action='store_true')
    args = ap.parse_args()

    freqs = [args.freq] if args.freq else specs_mod.FREQS
    return run(args.log, freqs, args.pad_skew, args.verbose)


if __name__ == '__main__':
    sys.exit(main())
