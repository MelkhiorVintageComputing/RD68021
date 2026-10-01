| SPDX-License-Identifier: CERN-OHL-S-2.0
| Copyright 2026 Romain Dolbeau
| Source location: https://github.com/MelkhiorVintageComputing/RD68021

| RD68021 -- the instructions a compiler does not emit.
|
| arith.c covers the common path, because GCC picks the instructions and the
| mix is one nobody here designed. What GCC never emits is the other half of the
| set: DBcc, the decimal arithmetic, TAS, MOVEP, EXG, the rotates through X, Scc
| and the bit instructions with a register bit number.
|
| Musashi runs the same image and the testbench compares every register at every
| instruction boundary, so nothing here has to check itself -- writing an answer
| down would only test that the answer was written down correctly.
|
| Nothing may take an exception: exception processing is M8.

        .text
        .globl  main
main:
        link    %a6, #-32               | a frame, which -fomit-frame-pointer hides
        move.l  #0x12345678, %d0
        move.l  #0x9ABCDEF0, %d1
        moveq   #0, %d2

| ---- the rotates, including through X, at all three sizes ----------------
        move.w  #63, %d7                | a count the shifts take modulo 64 and
                                        | the X rotates modulo the size plus one
1:      roxl.b  #1, %d0
        roxr.w  #3, %d1
        rol.l   %d7, %d0
        ror.w   %d7, %d1
        asl.l   #8, %d2
        lsr.b   #5, %d2
        addq.w  #1, %d2
        dbra    %d7, 1b                 | DBcc, which is why this file exists

| ---- the decimal arithmetic ---------------------------------------------
        move.l  #0x00000099, %d3
        move.l  #0x00000018, %d4
        andi    #0x00, %ccr             | a defined X to start from
        abcd    %d4, %d3
        abcd    %d4, %d3
        sbcd    %d4, %d3
        nbcd    %d3

| ---- the same through memory, which is the -(An) form -------------------
        lea     buf+16, %a0
        lea     buf+32, %a1
        move.b  #0x27, -1(%a0)
        move.b  #0x45, -1(%a1)
        andi    #0x00, %ccr
        abcd    -(%a0), -(%a1)
        move.b  #0x88, -1(%a0)
        move.b  #0x13, -1(%a1)
        sbcd    -(%a0), -(%a1)

| ---- the bit instructions, static and dynamic, register and memory ------
        lea     buf, %a2
        moveq   #5, %d5
        bset    %d5, (%a2)
        bchg    %d5, 3(%a2)
        bclr    %d5, %d0
        btst    %d5, %d1
        bset    #31, %d0
        bchg    #17, %d1
        bclr    #7, 5(%a2)
        btst    #3, 6(%a2)

| ---- Scc over every condition, into a byte array ------------------------
        lea     buf+64, %a3
        st      (%a3)+
        sf      (%a3)+
        shi     (%a3)+
        sls     (%a3)+
        scc     (%a3)+
        scs     (%a3)+
        sne     (%a3)+
        seq     (%a3)+
        svc     (%a3)+
        svs     (%a3)+
        spl     (%a3)+
        smi     (%a3)+
        sge     (%a3)+
        slt     (%a3)+
        sgt     (%a3)+
        sle     (%a3)+

| ---- TAS, which is the one read-modify-write in the set -----------------
        lea     buf+96, %a4
        move.b  #0x00, (%a4)
        tas     (%a4)
        tas     (%a4)
        tas     %d6

| ---- MOVEP, a register through every other byte ------------------------
        lea     buf+128, %a5
        move.l  #0xCAFEBABE, %d6
        movep.l %d6, 0(%a5)
        movep.w %d6, 9(%a5)
        movep.l 0(%a5), %d7
        movep.w 9(%a5), %d5

| ---- EXG and SWAP ------------------------------------------------------
        exg     %d0, %d1
        exg     %a0, %a1
        exg     %d2, %a2
        swap    %d3
        ext.w   %d4
        ext.l   %d4
        extb.l  %d5

| ---- MOVEM both ways, both sizes, and the two modes that step a register
        lea     buf+160, %a0
        movem.l %d0-%d7/%a1-%a4, (%a0)
        movem.w %d0-%d3, 64(%a0)
        movem.l (%a0), %d0-%d7/%a1-%a4
        movem.w 64(%a0), %d0-%d3
        lea     buf+320, %a0
        movem.l %d0-%d3, -(%a0)
        movem.l (%a0)+, %d4-%d7

| ---- the extended arithmetic, where Z is only ever cleared --------------
        moveq   #0, %d0
        moveq   #0, %d1
        andi    #0x04, %ccr             | Z set, X clear
        addx.l  %d1, %d0                | Z must stay set
        subx.w  %d1, %d0
        moveq   #1, %d1
        addx.b  %d1, %d0                | and now it must be cleared

| ---- the word multiply and divide, and the long forms -------------------
        move.l  #0x00001234, %d0
        move.l  #0x00000037, %d1
        mulu.w  %d1, %d0
        move.l  #0xFFFFF000, %d2
        muls.w  %d1, %d2
        move.l  #0x0000FFFF, %d3
        divu.w  %d1, %d3
        move.l  #0xFFFF0001, %d4
        divs.w  %d1, %d4
        move.l  #0x00123456, %d5
        move.l  #0x00000789, %d6
        mulu.l  %d6, %d5
        divu.l  %d6, %d5
        move.l  #0x7FFFFFFF, %d7
        muls.l  %d6, %d7

        unlk    %a6
        rts

        .bss
        .align  4
buf:    .space  512
