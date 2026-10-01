/* SPDX-License-Identifier: CERN-OHL-S-2.0
 * Copyright 2026 Romain Dolbeau
 * Source location: https://github.com/MelkhiorVintageComputing/RD68021
 */

/* RD68021 -- the effective-address oracle.
 *
 * Generates one test per (addressing mode, extension-word shape), runs it
 * through Musashi as an MC68020, and prints what the address came out as.
 *
 * There are two instruments. LEA <ea>,A0 computes an address and does nothing
 * else with it, which is what makes it the one to measure an address with; but
 * LEA takes only the control modes, so it cannot reach (An)+, -(An) or the
 * modes that fetch. MOVE.L <ea>,D0 reaches those, and makes the operand fetch
 * itself visible in the access list.
 *
 * Musashi is an oracle, not a source. Nothing here was written by reading how it
 * computes an address; the point is that two independent readings of PRM
 * section 2 have to agree, and where they do not, the manual decides.
 *
 * The output is a flat stream of hex numbers, read positionally by
 * sim/tb/core_ea_tb.sv with $fscanf("%h"):
 *
 *     ntests
 *     per test:
 *       index  nwords  w0..w5          the instruction, at PROG_BASE
 *       d0..d7 a0..a6                   the registers it starts with
 *       ea                              what the address came out as
 *       nreads  then nreads pairs of    what it read on the way, and whether
 *               address and space         each was a program reference (1) or a
 *                                         data one (0) -- PRM 2
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "m68k.h"

#define MEMSIZE    0x00100000
#define PROG_BASE  0x00001000
#define DATA_BASE  0x00002000

static unsigned char mem[MEMSIZE];

#define MAXREADS 8
static unsigned int read_addr[MAXREADS];
static int          read_prog[MAXREADS];   /* 1 = program space, 0 = data */
static int          nreads;
static int          recording;

static unsigned int rd8(unsigned int a)  { return mem[a % MEMSIZE]; }
static unsigned int rd16(unsigned int a) { return (rd8(a) << 8) | rd8(a + 1); }
static unsigned int rd32(unsigned int a) { return (rd16(a) << 16) | rd16(a + 2); }

/* Which reads count, and which space each one is in.
 *
 * An instruction prefetch is not an operand access and the two cores do not
 * fetch alike, so immediate and instruction words are not recorded. Everything
 * else is -- and the space matters, because PRM 2 says a program-counter-
 * relative operand access "classifies as a program reference" and comes out on
 * the function code pins as program space rather than data.
 *
 * This is what M68K_SEPARATE_READS in m68kconf.h is turned on for. Telling the
 * two apart by address does not work: a memory-indirect mode with a null base
 * displacement and the PC as its base reads the extension word itself. */
/* Musashi routes only the FINAL operand fetch of a PC-relative mode through
 * m68k_read_pcrelative_xx. The intermediate long word a memory-indirect mode
 * reads goes through m68k_read_memory_xx like any other, so Musashi calls it a
 * data reference -- and PRM 2.2.14 and 2.2.15 say it is not:
 *
 *     "The processor calculates an intermediate indirect memory address by
 *      adding a base displacement to the PC contents. The processor accesses a
 *      long word at that address ... This is a program reference allowed only
 *      for reads."
 *
 * The manual is the arbiter, so the space is taken from the addressing mode the
 * test was built with rather than from which callback Musashi happened to use.
 * doc/divergences.md records it. */
static int cur_pcrel;

static void record(unsigned int a, int prog)
{
    if (cur_pcrel) prog = 1;
    if (!recording || nreads >= MAXREADS) return;
    read_addr[nreads] = a;
    read_prog[nreads] = prog;
    nreads++;
}

unsigned int m68k_read_memory_8(unsigned int a)  { record(a, 0); return rd8(a); }
unsigned int m68k_read_memory_16(unsigned int a) { record(a, 0); return rd16(a); }
unsigned int m68k_read_memory_32(unsigned int a) { record(a, 0); return rd32(a); }

/* The instruction stream: never an operand access. */
unsigned int m68k_read_immediate_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_immediate_32(unsigned int a) { return rd32(a); }

/* A program-counter-relative operand: an access the instruction made, in
 * program space. */
unsigned int m68k_read_pcrelative_8(unsigned int a)  { record(a, 1); return rd8(a); }
unsigned int m68k_read_pcrelative_16(unsigned int a) { record(a, 1); return rd16(a); }
unsigned int m68k_read_pcrelative_32(unsigned int a) { record(a, 1); return rd32(a); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return rd32(a); }

void m68k_write_memory_8(unsigned int a, unsigned int v)  { mem[a % MEMSIZE] = v; }
void m68k_write_memory_16(unsigned int a, unsigned int v)
{ m68k_write_memory_8(a, v >> 8); m68k_write_memory_8(a + 1, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v)
{ m68k_write_memory_16(a, v >> 16); m68k_write_memory_16(a + 2, v); }

/* ------------------------------------------------------------------ */

struct test {
    int          nwords;
    int          pcrel;
    unsigned int w[6];
    unsigned int d[8];
    unsigned int a[7];
};

#define MAXTESTS 2048
static struct test tests[MAXTESTS];
static int         ntests;

static void add6(int nwords, const unsigned int *w)
{
    struct test *t;
    int i;
    if (ntests >= MAXTESTS) {
        fprintf(stderr, "musashi_ea: more than %d tests\n", MAXTESTS);
        exit(1);
    }
    t = &tests[ntests++];
    t->nwords = nwords;
    /* Mode 111 register 010 or 011 -- the two program-counter-relative modes. */
    t->pcrel = (((w[0] >> 3) & 7) == 7) && ((w[0] & 7) == 2 || (w[0] & 7) == 3);
    for (i = 0; i < 6; i++) t->w[i] = w[i];
    /* Register values that are distinctive, aligned, and inside the store. */
    for (i = 0; i < 8; i++) t->d[i] = 0x00000010 + i * 4;
    for (i = 0; i < 7; i++) t->a[i] = DATA_BASE + 0x100 + i * 0x40;
}

static void add(int nwords, unsigned int w0, unsigned int w1,
                unsigned int w2, unsigned int w3)
{
    unsigned int w[6];
    w[0] = w0; w[1] = w1; w[2] = w2; w[3] = w3; w[4] = 0; w[5] = 0;
    add6(nwords, w);
}

#define LEA(mode, reg)    (0x41C0 | ((mode) << 3) | (reg))
#define MOVEL(mode, reg)  (0x2000 | ((mode) << 3) | (reg))

/* One full-extension-word case. `nbd` is how many words of base displacement
 * follow (0, 1 or 2); the outer displacement's size comes from I/IS. */
static void lea_full_op(int opcode, int ext, int nbd, int iis, int is)
{
    unsigned int w[6];
    int n = 2, nod = 0;
    if ((iis & 3) != 0)
        nod = ((iis & 3) == 2) ? 1 : (((iis & 3) == 3) ? 2 : 0);
    (void)is;
    w[0] = opcode;
    w[1] = ext;
    w[2] = w[3] = w[4] = w[5] = 0;
    /* Displacements that keep every address inside the filled block. */
    if (nbd == 1)      { w[n++] = 0x0040; }
    else if (nbd == 2) { w[n++] = 0x0000; w[n++] = 0x2040; }
    if (nod == 1)      { w[n++] = 0x0004; }
    else if (nod == 2) { w[n++] = 0x0000; w[n++] = 0x0008; }
    add6(n, w);
}

static void build(void)
{
    int reg, da, ix, wl, sc;

    /* (An) */
    for (reg = 0; reg < 7; reg++) add(1, LEA(2, reg), 0, 0, 0);
    /* (d16,An), both signs */
    for (reg = 0; reg < 7; reg++) {
        add(2, LEA(5, reg), 0x0020, 0, 0);
        add(2, LEA(5, reg), 0xFFE0, 0, 0);
    }
    /* (xxx).W, both signs; (xxx).L */
    add(2, LEA(7, 0), 0x2000, 0, 0);
    add(2, LEA(7, 0), 0x8000, 0, 0);
    add(3, LEA(7, 1), 0x0000, 0x2040, 0);
    /* (d16,PC) */
    add(2, LEA(7, 2), 0x0010, 0, 0);
    add(2, LEA(7, 2), 0xFFF0, 0, 0);
    /* (d8,An,Xn) brief, every index register, both sizes, every scale */
    for (reg = 0; reg < 3; reg++)
        for (da = 0; da < 2; da++)
            for (ix = 0; ix < 8; ix++)
                for (wl = 0; wl < 2; wl++)
                    for (sc = 0; sc < 4; sc++)
                        add(2, LEA(6, reg),
                            (da << 15) | (ix << 12) | (wl << 11) | (sc << 9) | 0x08,
                            0, 0);
    /* (d8,PC,Xn) brief */
    for (da = 0; da < 2; da++)
        for (ix = 0; ix < 8; ix++)
            for (wl = 0; wl < 2; wl++)
                for (sc = 0; sc < 4; sc++)
                    add(2, LEA(7, 3),
                        (da << 15) | (ix << 12) | (wl << 11) | (sc << 9) | 0xF8,
                        0, 0);

    /* The full extension word -- PRM 2.5, tables 2-1 and 2-2. Every combination
     * of base suppress, index suppress, base displacement size, memory indirect
     * action and outer displacement size, with the base both an address register
     * and the program counter. The displacements are chosen to land inside the
     * block the caller filled with known long words, so that a memory indirect
     * address reads something recognisable rather than zero. */
    {
        int bs, is, bd, iis, base, d, ext;
        for (base = 0; base < 2; base++) {
            for (bs = 0; bs < 2; bs++)
                for (is = 0; is < 2; is++)
                    for (bd = 1; bd < 4; bd++)
                        for (iis = 0; iis < 8; iis++) {
                            /* PRM table 2-2 leaves these undefined; this design
                             * does something with them and the manual does not
                             * say what, so they are not compared. */
                            if (is == 0 && iis == 4) continue;
                            if (is == 1 && iis >= 4) continue;
                            ext = 0x0100                        /* full format */
                                | (1 << 15)                     /* D/A: A0 */
                                | (0 << 12)                     /* Xn = A0 */
                                | (1 << 11)                     /* long index */
                                | (0 << 9)                      /* scale 1 */
                                | (bs << 7) | (is << 6)
                                | (bd << 4) | iis;
                            /* The base displacement, then the outer one. */
                            if (bd == 1)      d = 0;            /* null */
                            else if (bd == 2) d = 1;            /* one word */
                            else              d = 2;            /* two words */
                            /* An indexed effective address is mode 110 with the
                             * base register, or mode 111 register 011 with the
                             * program counter -- not mode 010, which takes no
                             * extension word at all. */
                            if (base == 0)
                                lea_full_op(LEA(6, 2), ext, d, iis, is);
                            else
                                lea_full_op(LEA(7, 3), ext, d, iis, is);
                        }
        }
    }

    /* MOVE.L <ea>,D0 -- the modes LEA cannot take, and the operand fetch.
     *
     * LEA is the better instrument for an address because it does nothing else,
     * but it takes only the control modes: PRM table 2-2's (An)+ and -(An) are
     * unreachable through it, and so is the fetch an effective address exists to
     * make. MOVE.L reaches both. The side effect on An is what the final
     * register state is compared for. */
    for (reg = 0; reg < 7; reg++) add(1, MOVEL(3, reg), 0, 0, 0);   /* (An)+ */
    for (reg = 0; reg < 7; reg++) add(1, MOVEL(4, reg), 0, 0, 0);   /* -(An) */

    /* One of each mode LEA also takes, so that the operand read appears in the
     * access list next to whatever the address calculation itself read. */
    add(1, MOVEL(2, 1), 0, 0, 0);                    /* (An)          */
    add(2, MOVEL(5, 1), 0x0020, 0, 0);               /* (d16,An)      */
    add(2, MOVEL(6, 1), 0x1a08, 0, 0);               /* (d8,An,Xn*4)  */
    add(2, MOVEL(7, 0), 0x2000, 0, 0);               /* (xxx).W       */
    add(3, MOVEL(7, 1), 0x0000, 0x2040, 0);          /* (xxx).L       */
    add(2, MOVEL(7, 2), 0x1000, 0, 0);               /* (d16,PC)      */
    add(2, MOVEL(7, 3), 0x1af8, 0, 0);               /* (d8,PC,Xn*4)  */

    /* And the memory-indirect shapes through MOVE.L, where the access list has
     * both the indirection and the fetch in it and their order matters. */
    {
        int iis, base;
        for (base = 0; base < 2; base++)
            for (iis = 1; iis < 8; iis++) {
                int ext;
                if (iis == 4) continue;             /* reserved -- PRM 2-2 */
                ext = 0x0100 | (1 << 15) | (1 << 11) | (2 << 4) | iis;
                if (base == 0) lea_full_op(MOVEL(6, 2), ext, 1, iis, 0);
                else           lea_full_op(MOVEL(7, 3), ext, 1, iis, 0);
            }
    }
}

int main(void)
{
    int i, j;

    build();

    memset(mem, 0, sizeof mem);
    /* Something recognisable wherever a memory-indirect address might land. */
    for (i = 0; i < 1024; i += 4) m68k_write_memory_32(DATA_BASE + i, 0x00003000 + i);

    m68k_write_memory_32(0, 0x00008000);
    m68k_write_memory_32(4, PROG_BASE);
    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68020);
    m68k_pulse_reset();
    /* m68k_pulse_reset leaves RESET_CYCLES set, and m68k_execute spends its
     * whole budget on those before it looks at an instruction, so the first
     * m68k_execute(1) after a reset runs NOTHING and returns. A budget of zero
     * absorbs them. Without this the first vector of the sweep is compared
     * against a Musashi that never executed it. See doc/bugs-found.md. */
    m68k_execute(0);

    printf("%x\n", ntests);
    for (i = 0; i < ntests; i++) {
        struct test *t = &tests[i];
        for (j = 0; j < 6; j++) m68k_write_memory_16(PROG_BASE + j * 2, t->w[j]);
        m68k_write_memory_16(PROG_BASE + t->nwords * 2, 0x4E71);   /* NOP */

        for (j = 0; j < 8; j++) m68k_set_reg(M68K_REG_D0 + j, t->d[j]);
        for (j = 0; j < 7; j++) m68k_set_reg(M68K_REG_A0 + j, t->a[j]);
        m68k_set_reg(M68K_REG_A7, 0x8000);
        m68k_set_reg(M68K_REG_SR, 0x2700);
        m68k_set_reg(M68K_REG_PC, PROG_BASE);

        nreads = 0;
        cur_pcrel = t->pcrel;
        recording = 1;
        m68k_execute(1);
        recording = 0;

        printf("%x %x", i, t->nwords);
        for (j = 0; j < 6; j++) printf(" %x", t->w[j]);
        printf("\n");
        for (j = 0; j < 8; j++) printf("%x ", t->d[j]);
        for (j = 0; j < 7; j++) printf("%x ", t->a[j]);
        printf("\n%x\n", m68k_get_reg(NULL, M68K_REG_A0));
        printf("%x", nreads);
        for (j = 0; j < nreads; j++) printf(" %x %x", read_addr[j], read_prog[j]);
        printf("\n%x", m68k_get_reg(NULL, M68K_REG_D0));
        for (j = 0; j < 7; j++) printf(" %x", m68k_get_reg(NULL, M68K_REG_A0 + j));
        printf("\n");
    }
    return 0;
}
