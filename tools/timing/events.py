#!/usr/bin/env python3
"""Read an event log and pair its events the way the anchors ask.

    python3 tools/timing/events.py build/timing-events.log

The log is what sim/tb/rd68021_timing_tb.sv emits: a scenario marker, then one
line per pin transition giving the time, the clock edge it happened on, and the
event's name. Nothing in it knows what a specification is.

THE PAIRING RULE, stated once because every separation depends on it: an
occurrence of `a` is paired with the **first occurrence of `b` strictly later in
the log**. That one rule covers all three shapes a separation comes in -- a width
(as.assert to as.negate), a gap (as.negate to the next as.assert) and a
cross-signal separation (addr.valid to as.assert) -- with no special case for any
of them, and it is why each scenario is a separate log: a read's AS and a write's
DS must never be able to pair.
"""

import sys


class Event(object):
    __slots__ = ('t', 'edge', 'name', 'idx')

    def __init__(self, t, edge, name, idx):
        self.t = t
        self.edge = edge
        self.name = name
        self.idx = idx

    def __repr__(self):
        return '%s@%.1f%s' % (self.name, self.t, self.edge)


def read(path):
    """The log, as {scenario: [Event, ...]} in time order."""
    out = {}
    cur = None
    with open(path) as fh:
        for line in fh:
            f = line.split()
            if not f:
                continue
            if f[0] == 'S':
                cur = f[1]
                out.setdefault(cur, [])
            elif f[0] == 'T':
                if cur is None:
                    raise SystemExit('events: a transition before any scenario')
                lst = out[cur]
                lst.append(Event(float(f[1]), f[2], f[3], len(lst)))
    return out


def occurrences(events, name):
    return [e for e in events if e.name == name]


def pairs(events, a, b):
    """Every (a, b) the pairing rule gives, in order."""
    out = []
    bs = occurrences(events, b)
    j = 0
    for ea in occurrences(events, a):
        # the first b strictly after this a in the log
        k = j
        while k < len(bs) and bs[k].idx <= ea.idx:
            k += 1
        if k < len(bs):
            out.append((ea, bs[k]))
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    log = read(sys.argv[1])
    for scen in sorted(log):
        evs = log[scen]
        print('%s: %d events, %.1f ns to %.1f ns'
              % (scen, len(evs), evs[0].t if evs else 0, evs[-1].t if evs else 0))
        names = {}
        for e in evs:
            names[e.name] = names.get(e.name, 0) + 1
        for n in sorted(names):
            print('    %-16s %d' % (n, names[n]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
