#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68021

"""Which two events each specification separates.

    python3 tools/timing/anchors.py            # the table
    python3 tools/timing/anchors.py --unanchored

Section 10 is written against figures 10-3, 10-4 and 10-5, which draw each limit
as an arrow between two things happening on two pins. This module is that reading,
written down: for every specification, either the pin transition whose pad delay it
bounds, or the pair of transitions it separates.

An RTL model has no pad delays, so a limit measured from a clock edge to a pin
cannot be *measured* from it. It can still be answered. Every limit splits into

    a budget on one pad delay           0 <= d[as.assert] <= 30
    a required separation between pins  (t_b + d_b) - (t_a + d_a) >= 15

and both are difference constraints on the unknown delays, whose times come from
the simulation. "Is there any assignment of pad delays inside the budget meeting
every separation" then has an exact answer -- see feasible.py.

Some specifications are not that question at all, and saying which and why is part
of the answer rather than a gap in it. They are listed at the bottom with a reason
each.

EVENTS. An event is a pin transition, named `<pin>.<what>`, recorded with the
clock edge it happened on. The vocabulary is fixed here and in
sim/tb/rd68021_timing_tb.sv, and nothing else may invent one.
"""

import argparse
import sys

R = 'R'   # the transition happens on a rising clock edge
F = 'F'   # ... or a falling one

# Each scenario is one log, run and recorded separately, because the pairing rule
# below -- an occurrence of a with the next occurrence of b after it -- must never
# reach across from one kind of cycle into another. A read's AS and a write's DS
# are not a pair, and in one mixed log they would look like one.
SCENARIOS = ['read', 'write', 'mixed', 'arb']
ANY = ['read', 'write', 'mixed']


def scenarios_for(tag):
    return ANY if tag == 'any' else [tag]

# --------------------------------------------------------------------------
# Pad-delay budgets: "Clock High/Low to <pin> <transition>".
#
# edge is what the specification itself measures from, so a design that moves the
# pin on the other edge is not merely slow, it is being judged against the wrong
# half of the clock -- and the analyser says so rather than silently using the
# nearest edge.
# --------------------------------------------------------------------------
PAD = [
    # key,            events,                              edge, scenario
    (('6', ''),       ['addr.valid'],                       R, 'any'),
    (('6A', ''),      ['ecs.assert', 'ocs.assert'],         R, 'any'),
    (('7', ''),       ['addr.hiz', 'dout.hiz'],             R, 'any'),
    (('8', ''),       ['addr.invalid'],                     R, 'any'),
    (('9', ''),       ['as.assert', 'ds.assert'],           F, 'any'),
    (('12', ''),      ['as.negate', 'ds.negate'],           F, 'any'),
    (('12A', ''),     ['ecs.negate', 'ocs.negate'],         F, 'any'),
    (('16', ''),      ['ctl.hiz'],                          R, 'arb'),
    (('18', ''),      ['rw.high'],                          R, 'any'),
    (('20', ''),      ['rw.low'],                           R, 'any'),
    (('23', ''),      ['dout.valid'],                       R, 'write'),
    (('33', ''),      ['bg.assert'],                        F, 'arb'),
    (('34', ''),      ['bg.negate'],                        F, 'arb'),
    (('40', ''),      ['dben.assert'],                      R, 'read'),
    (('41', ''),      ['dben.negate'],                      F, 'read'),
    (('42', ''),      ['dben.assert'],                      F, 'write'),
    (('43', ''),      ['dben.negate'],                      R, 'write'),
    (('53', ''),      ['dout.invalid'],                     R, 'write'),
]

# --------------------------------------------------------------------------
# Separations: "<a> to <b>", and widths, which are the same thing with a and b
# on one pin. Each pairs an occurrence of a with the next occurrence of b after
# it, so "AS width asserted" is as.assert to as.negate and "AS width negated" is
# as.negate to the next as.assert, with no special case for either.
# --------------------------------------------------------------------------
SEP = [
    # key,            a,              b,              scenario
    (('9A', ''),      'as.assert',    'ds.assert',    'read'),
    (('9B', ''),      'as.assert',    'ds.assert',    'write'),
    (('10', ''),      'ecs.assert',   'ecs.negate',   'any'),
    (('10A', ''),     'ocs.assert',   'ocs.negate',   'any'),
    (('10B', ''),     'ecs.negate',   'ecs.assert',   'any'),
    (('11', ''),      'addr.valid',   'as.assert',    'any'),
    (('13', ''),      'as.negate',    'addr.invalid', 'any'),
    (('14', ''),      'as.assert',    'as.negate',    'any'),
    (('14A', ''),     'ds.assert',    'ds.negate',    'write'),
    (('15', ''),      'as.negate',    'as.assert',    'any'),
    (('15A', ''),     'ds.negate',    'as.assert',    'any'),
    (('17', ''),      'as.negate',    'rw.change',    'mixed'),
    (('21', ''),      'rw.high',      'as.assert',    'mixed'),
    (('22', ''),      'rw.low',       'ds.assert',    'write'),
    (('25', ''),      'as.negate',    'dout.invalid', 'write'),
    (('25A', ''),     'ds.negate',    'dben.negate',  'write'),
    (('26', ''),      'dout.valid',   'ds.assert',    'write'),
    (('39', ''),      'bg.negate',    'bg.assert',    'arb'),
    (('39A', ''),     'bg.assert',    'bg.negate',    'arb'),
    (('44', ''),      'rw.low',       'dben.assert',  'write'),
    (('45', 'Read'),  'dben.assert',  'dben.negate',  'read'),
    (('45', 'Write'), 'dben.assert',  'dben.negate',  'write'),
    (('46', ''),      'rw.change',    'rw.change',    'mixed'),
    (('55', ''),      'rw.change',    'dout.valid',   'write'),
]

# --------------------------------------------------------------------------
# What this analysis is not about, and why. Every one of these is a real
# specification; none of them is a question about the processor's pad delays.
# --------------------------------------------------------------------------
UNANCHORED = {
    ('1', ''):   'the clock the testbench drives; checked directly, not solved for',
    ('2,3', ''): 'clock pulse width; a property of the stimulus',
    ('4,5', ''): 'clock rise and fall times; an RTL model has no ramps',
    ('27', ''):  'an input requirement: where the design samples read data. '
                 'Not a pad-delay question -- see "The other half" in '
                 'doc/ac-timing.md',
    ('27A', ''): 'an input requirement: the late BERR/HALT window',
    ('28', ''):  'a requirement on the external device, not on the processor',
    ('29', ''):  'an input requirement: read-data hold',
    ('29A', ''): 'a requirement on the external device',
    ('30', ''):  'an input requirement: read-data hold from the clock',
    ('31', ''):  'a requirement on the external device (DSACK to data valid)',
    ('31A', ''): 'a requirement on the external device (DSACK0 to DSACK1 skew)',
    ('32', ''):  'RESET input transition time; a property of the stimulus',
    ('35', ''):  'BR to BG, in clock periods; counted directly by bus_arb_tb',
    ('37', ''):  'BGACK to BG negated, in clock periods; counted directly',
    ('37A', ''): 'BGACK to BR negated; a requirement on the external master',
    ('47A', ''): 'the asynchronous input setup time; a requirement this design '
                 'places on the system, not one it must meet',
    ('47B', ''): 'the asynchronous input hold time; likewise',
    ('48', ''):  'a requirement on the external device (DSACK to BERR)',
    ('56', ''):  'the RESET instruction pulse, in clock periods; M5',
    ('57', ''):  'a requirement on the external device (BERR to HALT, rerun)',
    ('58', ''):  'BGACK negated to bus driven, in clock periods; counted directly',
    ('59', ''):  'BG negated to bus driven, in clock periods; counted directly',
}

EVENTS = sorted(set(
    [e for _, evs, _, _ in PAD for e in evs] +
    [a for _, a, _, _ in SEP] + [b for _, _, b, _ in SEP]
))


def check_complete(specs):
    """Every specification is either anchored or explained. Nothing falls down
    the gap between the two."""
    anchored = set(k for k, _, _, _ in PAD) | set(k for k, _, _, _ in SEP)
    missing = []
    for key in specs:
        if key not in anchored and key not in UNANCHORED:
            missing.append(key)
    stale = [k for k in UNANCHORED if k not in specs]
    stale += [k for k in anchored if k not in specs]
    return missing, stale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--unanchored', action='store_true')
    args = ap.parse_args()

    sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
    import specs as specs_mod
    specs = specs_mod.load()

    if args.unanchored:
        for key, why in sorted(UNANCHORED.items()):
            s = specs.get(key)
            print('%-8s %-56s %s' % (key[0], s.characteristic[:56] if s else '?', why))
    else:
        print('# pad-delay budgets')
        for key, evs, edge, scen in PAD:
            s = specs.get(key)
            print('  %-6s %-4s %-7s %-34s %s'
                  % (key[0], 'CLK' + edge, scen, ','.join(evs),
                     s.characteristic[:44] if s else '?'))
        print('# separations')
        for key, a, b, scen in SEP:
            s = specs.get(key)
            print('  %-6s %-7s %-14s -> %-14s %s'
                  % (key[0] + (':' + key[1] if key[1] else ''), scen, a, b,
                     s.characteristic[:40] if s else '?'))

    missing, stale = check_complete(specs)
    if missing:
        print('\nFAIL: %d specifications are neither anchored nor explained: %s'
              % (len(missing), ', '.join(k[0] for k in sorted(missing))))
        return 1
    if stale:
        print('\nFAIL: %d anchors or exclusions name a specification that does not '
              'exist: %s' % (len(stale), ', '.join(str(k) for k in sorted(stale))))
        return 1
    print('\n%d specifications: %d anchored, %d explained'
          % (len(specs), len(specs) - len(UNANCHORED), len(UNANCHORED)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
