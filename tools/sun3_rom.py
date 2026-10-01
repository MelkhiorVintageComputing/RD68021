#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 Romain Dolbeau
# Source location: https://github.com/MelkhiorVintageComputing/RD68021

"""Make the Sun-3 boot PROM `make sun3` runs: a copy, patched to boot faster.

    python3 tools/sun3_rom.py <original.bin> <patched.bin>

Inputs/ is immutable, so the PROM is copied into build/ and patched there. The
patches shorten waits that exist for a person or for slow hardware and change
nothing the PROM checks or reports -- the same idea as
Inputs/ref/VintageBusFPGA_Common/RomPatcher/Sun3_60FastBoot, which does it for
the Sun-3/60's v1.9 PROM, applied to the Sun-3/160's Carrera Rev 3.0.

Each patch names the bytes it expects to find, so a different PROM is refused
rather than corrupted. The checksum is then put right: the low sixteen bits of
the sum of every byte but the last two, stored in the last two -- the rule
RomPatcher/patcher/sun3_checksum.c computes and Sun3_160MaxMemory relies on.
"""

import sys

PATCHES = [
    # 0x0FEFCA98: MOVE.L #65535,D0, then a SUBQ/BGT loop -- the wait after the
    # PROM writes the diagnostic LEDs, so that a person can read them, run
    # before every self-test step. Two, as FastBoot's loweritercount.
    (0xCA9A, bytes.fromhex('0000ffff'), bytes.fromhex('00000002'),
     'the diagnostic-LED display wait'),
]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rom = bytearray(open(sys.argv[1], 'rb').read())
    if (sum(rom[:-2]) & 0xFFFF) != int.from_bytes(rom[-2:], 'big'):
        sys.exit('sun3_rom: %s fails its own checksum' % sys.argv[1])
    for off, old, new, why in PATCHES:
        if rom[off:off + len(old)] != old:
            sys.exit('sun3_rom: %s at 0x%05x is %s, not %s -- not the PROM '
                     'these patches are for' % (why, off,
                                                rom[off:off + len(old)].hex(),
                                                old.hex()))
        rom[off:off + len(new)] = new
    rom[-2:] = (sum(rom[:-2]) & 0xFFFF).to_bytes(2, 'big')
    open(sys.argv[2], 'wb').write(rom)
    print('  sun3: %d patch(es) applied, checksum %04x' %
          (len(PATCHES), int.from_bytes(rom[-2:], 'big')))


if __name__ == '__main__':
    main()
