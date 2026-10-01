| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68021

| RD68021 -- the bus probe, run on this core and on the Suska WF68K30L.
|
| Every data transfer the dynamic bus sizing tables describe: byte, word and
| long, at each of the four byte offsets, read and written, to a 32-, a 16- and
| an 8-bit port (UM tables 5-6 and 5-7). Then the multi-operand shapes: MOVEM,
| and the read-modify-write sequences, CAS and TAS, which hold RMC.
|
| Supervisor mode, no exceptions, no program-counter-relative operands -- those
| are program references (PRM 2) and would be indistinguishable from prefetches
| in the comparison, which is of DATA cycles only.
|
| The memory map is the one both testbenches build:
|   $0000_0000  32-bit port    (this image, the vectors, the stack)
|   $1000_0000  16-bit port
|   $2000_0000   8-bit port

        .section .vectors, "a"
        .long   0x0000F000
        .long   _start

        .text
        .globl  _start
_start:
        move.l  #0x11223344, %d0
        move.l  #0x00008000, %a0
        move.l  #0x10008000, %a1
        move.l  #0x20008000, %a2

        .irp    base, %a0, %a1, %a2
        .irp    off, 0, 1, 2, 3
        move.b  %d0, \off(\base)
        move.w  %d0, \off(\base)
        move.l  %d0, \off(\base)
        move.b  \off(\base), %d1
        move.w  \off(\base), %d1
        move.l  \off(\base), %d1
        .endr
        .endr

        | Several operands in one instruction.
        movem.l %d0-%d3, 0x10(%a1)
        movem.l 0x10(%a1), %d4-%d7
        movem.l %d0-%d1, 0x21(%a2)

        | The read-modify-write sequences: RMC held across each.
        cas.l   %d0, %d1, 0x40(%a0)
        cas.w   %d0, %d1, 0x41(%a1)
        tas     0x43(%a2)

        | A long across a 16-bit port's word boundary, and a stack frame's
        | worth of pushes.
        move.l  %d0, 0x33(%a1)
        pea     0x1234
        move.l  %d0, -(%sp)
        addq.l  #8, %sp

done:   bra     done
