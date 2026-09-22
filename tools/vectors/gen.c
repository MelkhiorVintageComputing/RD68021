/* RD68021 -- the per-opcode vector generator.
 *
 * There is no SingleStepTests set for the MC68020, so the mass oracle has to be
 * built rather than downloaded. This is it: for each instruction it knows, it
 * emits a set of opcodes, gives each one several pseudo-random starting states,
 * runs it through Musashi as an MC68020, and prints what came out.
 *
 *     build/vectors/gen <group>...      # or `all`
 *
 * Musashi is an ORACLE, not a source. Nothing here was written by reading how it
 * implements anything; the manual is the arbiter when the two disagree.
 *
 * WHAT IS AND IS NOT SWEPT HERE
 *
 * The addressing modes are NOT swept exhaustively against every opcode. `make
 * ea` already does that -- all eighteen modes and every shape of extension word,
 * against the same oracle, comparing the address and the access list. Repeating
 * it per opcode would multiply the vector count by two hundred to re-check
 * something already checked. What this sweeps is the OPERATION: every opcode,
 * every size, every condition, against varied operands, through a handful of
 * modes chosen to reach each data path into and out of the effective address --
 * a register, an aligned memory operand, a MISALIGNED one, and the two that
 * have a side effect on an address register.
 *
 * THE OUTPUT, read positionally by sim/tb/core_vec_tb.sv with $fscanf("%h"):
 *
 *     ntests
 *     per test:
 *       index  nwords  w0..w5             the instruction, at PROG_BASE
 *       d0..d7  a0..a6  usp  isp  sr      the state it starts from
 *       msp  sfc  dfc  vbr  caar           and the control registers, because
 *                                          UM 6.1.1's nine steps name only VBR
 *                                          and CACR -- the rest are undefined
 *                                          after a reset and MOVEC can read them
 *       npoke  then npoke pairs of        long words put into memory before the
 *         address and value               run, for the few instructions that
 *                                         need something specific there
 *       srmask  bcdfill                   which bits of the status register are
 *                                         worth comparing -- see below -- and
 *                                         whether the data block holds valid
 *                                         binary-coded decimal
 *       d0..d7  a0..a6  usp  isp  sr  pc  the state it finished in
 *       msp  vbr  sfc  dfc  caar           and the control registers MOVEC
 *                                          reaches, except CACR, which waits
 *                                          for the cache in M11
 *       nacc                              how many operand accesses it made
 *         per access: addr  rw  bytes  prog  value
 *
 * `rw` is 1 for a read. `prog` is 1 for a program-space reference -- PRM 2. See
 * doc/divergences.md for the two places Musashi has to be corrected: the space
 * of a program-counter-relative indirection, and the shape of a long write to a
 * predecrement address.
 * `value` is what was written, and is 0 on a read: the reads are covered by the
 * final state, and the writes are how memory is compared without dumping it.
 *
 * `srmask` exists because the manual leaves some condition codes UNDEFINED and
 * an oracle still produces a number for them. PRM 4 says N and V are undefined
 * after ABCD, SBCD and NBCD; N and Z are undefined after a divide that
 * overflowed; and CHK leaves Z, V and C undefined. Comparing those bits would
 * be comparing this core against Musashi's choice rather than against the
 * manual, which CLAUDE.md forbids -- so they are masked out here and the choice
 * this design made is written down in doc/divergences.md instead.
 *
 * MEMORY. Both sides fill DATA_SIZE bytes at DATA_BASE from the test index with
 * the same two truncating multiplications, so neither has to send the other a
 * copy per test and neither can be reading storage the other never wrote.
 * Everything else is zero. The block is only as big as the addresses a test can
 * reach, because the testbench refills it once per test and that is what the
 * sweep spends its time on.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "m68k.h"

#define MEMSIZE    0x00100000
#define PROG_BASE  0x00001000
#define DATA_BASE  0x00002000
#define DATA_SIZE  0x00000800
#define STACK      0x00002700

static unsigned char mem[MEMSIZE];

/* ------------------------------------------------------------------ */
/* Accesses                                                            */
/* ------------------------------------------------------------------ */

#define MAXACC 24
static struct {
    unsigned int addr, rw, bytes, prog, value;
} acc[MAXACC];
static int nacc;
static int recording;
static int cur_pcrel;   /* the instruction's mode is PC-relative: PRM 2 */
static int overflowed;

static unsigned int rd8(unsigned int a)  { return mem[a % MEMSIZE]; }
static unsigned int rd16(unsigned int a) { return (rd8(a) << 8) | rd8(a + 1); }
static unsigned int rd32(unsigned int a) { return (rd16(a) << 16) | rd16(a + 2); }

static void wr8(unsigned int a, unsigned int v)  { mem[a % MEMSIZE] = v; }
static void wr16(unsigned int a, unsigned int v) { wr8(a, v >> 8); wr8(a + 1, v); }
static void wr32(unsigned int a, unsigned int v) { wr16(a, v >> 16); wr16(a + 2, v); }

/* Musashi splits a long write to a PREDECREMENT address into two word writes,
 * low half first -- MOVE.L <ea>,-(An) in m68k_in.c and unconditionally, not even
 * behind M68K_SIMULATE_PD_WRITES, and MOVEM.L regs,-(An) the same way.
 * That is the MC68000's behaviour, a consequence of a sixteen-bit bus. On the
 * MC68020 a long-word operand is ONE operand and UM table 5-6 splits it by its
 * ADDRESS, most significant bytes first; there is no instruction-specific case.
 * So the two are put back together here, gated on the opcode so that nothing
 * else can be merged by accident -- MOVEM to -(An) also writes descending words
 * and must not be. doc/divergences.md records it. */
static int split_pd;

static void record(unsigned int a, int rw, int bytes, unsigned int v)
{
    if (!recording) return;
    /* The second half of a split predecrement long write goes back onto the
     * first. It is the PREVIOUS access that is merged with, not the first one:
     * MOVE.L (A0),-(A1) reads before it writes. */
    if (split_pd && !rw && bytes == 2 && nacc >= 1
        && acc[nacc - 1].rw == 0 && acc[nacc - 1].bytes == 2
        && acc[nacc - 1].addr == a + 2) {
        acc[nacc - 1].addr  = a;
        acc[nacc - 1].bytes = 4;
        acc[nacc - 1].value = (v << 16) | acc[nacc - 1].value;
        return;
    }
    if (nacc >= MAXACC) { overflowed = 1; return; }
    acc[nacc].addr  = a;
    acc[nacc].rw    = rw;
    acc[nacc].bytes = bytes;
    /* PRM 2 makes a program-counter-relative mode's READS program references.
     * Anything such an instruction WRITES goes somewhere else by construction --
     * the mode is "a program reference allowed only for reads" -- so PEA's push
     * and a MOVE destination are ordinary data. The pcrelative callbacks set
     * this again for the accesses Musashi itself classifies. */
    acc[nacc].prog  = (cur_pcrel && rw);
    acc[nacc].value = v;
    nacc++;
}

unsigned int m68k_read_memory_8(unsigned int a)  { record(a, 1, 1, 0); return rd8(a); }
unsigned int m68k_read_memory_16(unsigned int a) { record(a, 1, 2, 0); return rd16(a); }
unsigned int m68k_read_memory_32(unsigned int a) { record(a, 1, 4, 0); return rd32(a); }

/* The instruction stream is never an operand access. */
unsigned int m68k_read_immediate_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_immediate_32(unsigned int a) { return rd32(a); }

/* A program-counter-relative operand IS one, and is a program reference. */
unsigned int m68k_read_pcrelative_8(unsigned int a)
{ record(a, 1, 1, 0); acc[nacc-1].prog = 1; return rd8(a); }
unsigned int m68k_read_pcrelative_16(unsigned int a)
{ record(a, 1, 2, 0); acc[nacc-1].prog = 1; return rd16(a); }
unsigned int m68k_read_pcrelative_32(unsigned int a)
{ record(a, 1, 4, 0); acc[nacc-1].prog = 1; return rd32(a); }

unsigned int m68k_read_disassembler_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return rd32(a); }

void m68k_write_memory_8(unsigned int a, unsigned int v)
{ record(a, 0, 1, v & 0xFF); wr8(a, v); }
void m68k_write_memory_16(unsigned int a, unsigned int v)
{ record(a, 0, 2, v & 0xFFFF); wr16(a, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v)
{ record(a, 0, 4, v); wr32(a, v); }

/* ------------------------------------------------------------------ */
/* Tests                                                               */
/* ------------------------------------------------------------------ */

struct test {
    int          nwords;
    unsigned int w[6];
    int          pcrel;
    int          flow;      /* the instruction may legitimately change the PC */
    unsigned int d[8], a[7], usp, isp, sr;
    unsigned int imsp, isfc, idfc, ivbr, icaar;
    int          npoke;
    unsigned int poke_a[4], poke_v[4];
    unsigned int srmask;      /* which status-register bits to compare */
    int          bcdfill;     /* the data block is to be valid BCD */
};

#define MAXTESTS 200000
static struct test *tests;
static int          ntests;

/* A deterministic generator, so a failing vector index means the same thing on
 * every run and on every machine. */
static unsigned int rng_state;
static unsigned int rnd(void)
{
    rng_state = rng_state * 1103515245u + 12345u;
    return (rng_state >> 8) ^ (rng_state << 13);
}

/* The data block, filled identically by sim/tb/core_vec_tb.sv. Two truncating
 * 32-bit multiplications and an exclusive or -- nothing that could mean one
 * thing in C and another in SystemVerilog. */
static unsigned int fill_word(int idx, unsigned int off)
{
    return ((unsigned int)idx * 0x9E3779B9u) ^ (off * 0x01000193u);
}

/* Every byte of a long word brought into the range a decimal digit pair can
 * hold. PRM 4 defines ABCD, SBCD and NBCD on binary-coded decimal operands and
 * says nothing about what a digit above nine does, so the sweep does not ask --
 * see doc/divergences.md. */
static unsigned int bcd_word(unsigned int v)
{
    unsigned int out = 0, i, b;
    for (i = 0; i < 4; i++) {
        b = (v >> (i * 8)) & 0xFFu;
        /* Each NIBBLE modulo ten, not the byte: `b % 10` would take $7C to
         * $74 rather than to $72, and the testbench -- which computes the same
         * fill independently -- would disagree about what is in memory. */
        out |= ((((b >> 4) % 10u) << 4) | ((b & 0x0Fu) % 10u)) << (i * 8);
    }
    return out;
}

/* One test. `nw` counts the instruction's words; the caller has put them in w. */
static void emit(int nw, const unsigned int *w, int pcrel, int flow)
{
    struct test *t;
    int i;
    if (ntests >= MAXTESTS) {
        fprintf(stderr, "vectors: more than %d tests\n", MAXTESTS);
        exit(1);
    }
    t = &tests[ntests++];
    t->nwords = nw;
    for (i = 0; i < 6; i++) t->w[i] = w[i];
    t->pcrel = pcrel;
    t->flow  = flow;

    for (i = 0; i < 8; i++) t->d[i] = rnd();
    /* Address registers point into the data block. Half of them land on an odd
     * address on purpose: the MC68020 takes no address error on a data access
     * (UM 6.1.3), so a misaligned operand is ordinary behaviour that the bus
     * unit splits, and an instruction sweep that only ever used even addresses
     * would never reach that path through an instruction. */
    for (i = 0; i < 7; i++)
        t->a[i] = DATA_BASE + 0x100 + (rnd() & 0x3FF);
    t->usp = STACK;
    t->isp = STACK;
    /* Supervisor, interrupts masked, trace off -- tracing is M8 -- and the
     * condition codes varied, because ADDX, SUBX, the rotates through X and
     * every Bcc read them. */
    t->sr  = 0x2700 | (rnd() & 0x1F);
    t->srmask  = 0xFFFF;
    /* Distinctive, and legal: the function codes are three bits and the vector
     * base has to be even. */
    t->imsp  = STACK - 0x80;
    t->isfc  = 3;
    t->idfc  = 5;
    /* Zero, and deliberately. UM 6.1.1 step 4 initialises VBR to zero, so it is
     * the one control register that does NOT need establishing -- and moving it
     * would move the vector table out from under the check below, which is how
     * a test that trapped is recognised. That is exactly what it did: setting
     * VBR to $A000 made every trapping test look like an ordinary one, and CHK
     * stopped being dropped. */
    t->ivbr  = 0x00000000u;
    t->icaar = 0x12345670u;
    t->bcdfill = 0;
}

/* Several starting states for one instruction. */
static void emitn(int n, int nw, const unsigned int *w, int pcrel, int flow)
{
    while (n-- > 0) emit(nw, w, pcrel, flow);
}

/* ------------------------------------------------------------------ */
/* Addressing modes                                                    */
/*                                                                     */
/* A handful, not eighteen. `make ea` sweeps all eighteen against every */
/* shape of extension word already; what these have to do is reach each */
/* PATH into and out of an operand -- a register, an aligned memory     */
/* operand, a misaligned one, the two with a side effect on an address  */
/* register, an absolute address and a program-space one.               */
/*                                                                     */
/* The indexed modes are deliberately absent: their index register is   */
/* one of the randomised data registers, so the address would leave the */
/* block. They are `make ea`'s business.                                */
/* ------------------------------------------------------------------ */

struct eamode {
    int          mode, reg;
    int          next;          /* how many extension words follow */
    unsigned int ext[2];
    int          pcrel;
};

/* (d16,PC): the PC in the calculation is the address of the extension word,
 * PROG_BASE+2 for a one-word opcode. Displacements are chosen so that every
 * address lands inside the filled block. */
#define D16AN  0x0008
#define ABSW   0x2100

static const struct eamode EA_ALL[] = {      /* data source: anything readable */
    { 0, 0, 0, { 0, 0 }, 0 },                /* Dn      */
    { 0, 5, 0, { 0, 0 }, 0 },
    { 2, 1, 0, { 0, 0 }, 0 },                /* (An)    */
    { 2, 4, 0, { 0, 0 }, 0 },
    { 3, 2, 0, { 0, 0 }, 0 },                /* (An)+   */
    { 4, 3, 0, { 0, 0 }, 0 },                /* -(An)   */
    { 5, 6, 1, { D16AN, 0 }, 0 },            /* (d16,An)*/
    { 7, 0, 1, { ABSW, 0 }, 0 },             /* (xxx).W */
};
#define N_EA_ALL ((int)(sizeof EA_ALL / sizeof EA_ALL[0]))

static const struct eamode EA_ALT[] = {      /* data alterable: no PC, no imm */
    { 0, 0, 0, { 0, 0 }, 0 },
    { 2, 1, 0, { 0, 0 }, 0 },
    { 3, 2, 0, { 0, 0 }, 0 },
    { 4, 3, 0, { 0, 0 }, 0 },
    { 5, 6, 1, { D16AN, 0 }, 0 },
    { 7, 0, 1, { ABSW, 0 }, 0 },
};
#define N_EA_ALT ((int)(sizeof EA_ALT / sizeof EA_ALT[0]))

static const struct eamode EA_MEM[] = {      /* memory alterable: no Dn */
    { 2, 1, 0, { 0, 0 }, 0 },
    { 3, 2, 0, { 0, 0 }, 0 },
    { 4, 3, 0, { 0, 0 }, 0 },
    { 5, 6, 1, { D16AN, 0 }, 0 },
    { 7, 0, 1, { ABSW, 0 }, 0 },
};
#define N_EA_MEM ((int)(sizeof EA_MEM / sizeof EA_MEM[0]))

static const struct eamode EA_CTL[] = {      /* control: an address, not a value */
    { 2, 1, 0, { 0, 0 }, 0 },
    { 5, 6, 1, { D16AN, 0 }, 0 },
    { 7, 0, 1, { ABSW, 0 }, 0 },
};
#define N_EA_CTL ((int)(sizeof EA_CTL / sizeof EA_CTL[0]))

/* One opcode through one set of modes, with `nper` starting states each.
 * `pre` is any word that comes between the opcode and the mode's extension
 * words -- an immediate operand, or MOVEM's register mask. */
static void sweep(unsigned int base, const struct eamode *set, int nset,
                  int npre, const unsigned int *pre, int nper, int flow)
{
    unsigned int w[6];
    int i, j, n;
    for (i = 0; i < nset; i++) {
        memset(w, 0, sizeof w);
        n = 0;
        w[n++] = base | (unsigned)(set[i].mode << 3) | (unsigned)set[i].reg;
        for (j = 0; j < npre; j++) w[n++] = pre[j];
        for (j = 0; j < set[i].next; j++) w[n++] = set[i].ext[j];
        emitn(nper, n, w, set[i].pcrel, flow);
    }
}

/* A (d16,PC) source, whose displacement depends on how many words precede it. */
static void sweep_pc(unsigned int base, int npre, const unsigned int *pre,
                     int nper, int flow)
{
    unsigned int w[6];
    int j, n = 0;
    memset(w, 0, sizeof w);
    w[n++] = base | (7 << 3) | 2;
    for (j = 0; j < npre; j++) w[n++] = pre[j];
    /* The value of the PC is the address of the extension word. */
    w[n] = (DATA_BASE + 0x100 - (PROG_BASE + (unsigned)n * 2)) & 0xFFFF;
    n++;
    emitn(nper, n, w, 1, flow);
}

/* No effective address at all. */
static void plain(unsigned int w0, int nper, int flow)
{
    unsigned int w[6];
    memset(w, 0, sizeof w);
    w[0] = w0;
    emitn(nper, 1, w, 0, flow);
}

static void plain2(unsigned int w0, unsigned int w1, int nper, int flow)
{
    unsigned int w[6];
    memset(w, 0, sizeof w);
    w[0] = w0; w[1] = w1;
    emitn(nper, 2, w, 0, flow);
}

/* Put a long word somewhere before the run. RTS and its relatives need a return
 * address on the stack that is a real address, not fill. */
static void poke(unsigned int a, unsigned int v)
{
    struct test *t = &tests[ntests - 1];
    if (t->npoke >= 4) { fprintf(stderr, "vectors: too many pokes\n"); exit(1); }
    t->poke_a[t->npoke] = a;
    t->poke_v[t->npoke] = v;
    t->npoke++;
}

/* The same long word into the last `n` tests, which is what emitn just made. */
static void poke_n(int n, unsigned int a, unsigned int v)
{
    int i;
    for (i = 0; i < n; i++) {
        struct test *t = &tests[ntests - 1 - i];
        if (t->npoke >= 4) { fprintf(stderr, "vectors: too many pokes\n"); exit(1); }
        t->poke_a[t->npoke] = a;
        t->poke_v[t->npoke] = v;
        t->npoke++;
    }
}

/* ------------------------------------------------------------------ */
/* The instruction groups                                              */
/*                                                                     */
/* Encodings are from PRM section 8, the instruction format summary.    */
/* ------------------------------------------------------------------ */

#define NPER 6      /* starting states per opcode */

/* MOVE: 00 ss  rrr mmm  eeeeee -- note the destination is register THEN mode.
 * Sizes are 01 byte, 11 word, 10 long, which is not the order anything else
 * uses (PRM 8). */
static const unsigned int MOVE_SZ[3] = { 0x1000, 0x3000, 0x2000 };

static void g_move(void)
{
    int s, i;
    for (s = 0; s < 3; s++) {
        /* <ea> -> D1, every source mode. Byte size takes no address register. */
        for (i = 0; i < N_EA_ALL; i++) {
            if (s == 0 && EA_ALL[i].mode == 1) continue;
            sweep(MOVE_SZ[s] | (1 << 9) | (0 << 6),
                  &EA_ALL[i], 1, 0, NULL, NPER, 0);
        }
        sweep_pc(MOVE_SZ[s] | (1 << 9) | (0 << 6), 0, NULL, NPER, 0);
        /* D3 -> <ea>, every destination mode. */
        for (i = 0; i < N_EA_ALT; i++) {
            unsigned int dst = (unsigned)(EA_ALT[i].reg << 9)
                             | (unsigned)(EA_ALT[i].mode << 6);
            unsigned int w[6];
            int n = 0, j;
            memset(w, 0, sizeof w);
            w[n++] = MOVE_SZ[s] | dst | 3;          /* source D3 */
            for (j = 0; j < EA_ALT[i].next; j++) w[n++] = EA_ALT[i].ext[j];
            emitn(NPER, n, w, 0, 0);
        }
        /* memory to memory, the shape that has a read and a write in one
         * instruction and no register in between */
        {
            unsigned int w[2];
            w[0] = MOVE_SZ[s] | (2 << 9) | (2 << 6) | (2 << 3) | 1;  /* (A1)->(A2) */
            w[1] = 0;
            emitn(NPER, 1, w, 0, 0);
        }
    }
    /* MOVEA, word and long only, sign extending the word form to 32 bits. */
    for (s = 1; s < 3; s++)
        for (i = 0; i < N_EA_ALL; i++)
            sweep(MOVE_SZ[s] | (4 << 9) | (1 << 6), &EA_ALL[i], 1, 0, NULL, NPER, 0);
}

static void g_moveq(void)
{
    /* Bit 8 must be zero or it is not MOVEQ, so the immediate is masked rather
     * than computed: 0x01 + 3 * 0x55 is 0x100, which is a different instruction
     * and an illegal one. The drop counter caught it. */
    static const unsigned int imm[4] = { 0x00, 0x7F, 0x80, 0xFF };
    int r, k;
    for (r = 0; r < 8; r++)
        for (k = 0; k < 4; k++)
            plain(0x7000 | (unsigned)(r << 9) | imm[k], 2, 0);
}

/* The one-operand group: CLR NEG NEGX NOT TST. */
static void g_unary(void)
{
    static const unsigned int op[5] = { 0x4200, 0x4400, 0x4000, 0x4600, 0x4A00 };
    int o, s;
    for (o = 0; o < 5; o++)
        for (s = 0; s < 3; s++)
            sweep(op[o] | (unsigned)(s << 6), EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);
}

static void g_misc(void)
{
    int r;
    for (r = 0; r < 8; r++) {
        plain(0x4840 | (unsigned)r, NPER, 0);            /* SWAP    */
        plain(0x4880 | (unsigned)r, NPER, 0);            /* EXT.W   */
        plain(0x48C0 | (unsigned)r, NPER, 0);            /* EXT.L   */
        plain(0x49C0 | (unsigned)r, NPER, 0);            /* EXTB.L  */
    }
    /* EXG, all three register-pair forms. */
    for (r = 0; r < 4; r++) {
        plain(0xC140 | (unsigned)(r << 9) | (unsigned)(7 - r), NPER, 0); /* Dx,Dy */
        plain(0xC148 | (unsigned)(r << 9) | (unsigned)(6 - r), NPER, 0); /* Ax,Ay */
        plain(0xC188 | (unsigned)(r << 9) | (unsigned)(5 - r), NPER, 0); /* Dx,Ay */
    }
    plain(0x4E71, 4, 0);                                 /* NOP     */
}

static void g_addr(void)
{
    int i;
    /* LEA <ea>,A4 and PEA <ea> -- control modes only. */
    for (i = 0; i < N_EA_CTL; i++) {
        sweep(0x41C0 | (4 << 9), &EA_CTL[i], 1, 0, NULL, NPER, 0);
        sweep(0x4840, &EA_CTL[i], 1, 0, NULL, NPER, 0);
    }
    sweep_pc(0x41C0 | (4 << 9), 0, NULL, NPER, 0);
    sweep_pc(0x4840, 0, NULL, NPER, 0);
    /* LINK.W, LINK.L and UNLK. The displacement is negative, as a frame's is. */
    plain2(0x4E50 | 5, 0xFFF0, NPER, 0);                 /* LINK.W A5,#-16 */
    {
        unsigned int w[6];
        memset(w, 0, sizeof w);
        w[0] = 0x4808 | 5; w[1] = 0xFFFF; w[2] = 0xFF00; /* LINK.L A5,#-256 */
        emitn(NPER, 3, w, 0, 0);
    }
    plain(0x4E58 | 5, NPER, 0);                          /* UNLK A5 */
}

/* The two-operand arithmetic and logic group. Each has the same shape:
 * an opmode field selecting size and direction, and an <ea>. */
static void g_alu(void)
{
    static const unsigned int op[5]   = { 0xD000, 0x9000, 0xC000, 0x8000, 0xB000 };
    static const int          mem_ok[5] = { 1, 1, 1, 1, 1 };  /* <ea> as destination */
    /*                        ADD     SUB     AND     OR      EOR/CMP          */
    int o, s, i;

    for (o = 0; o < 4; o++) {           /* ADD SUB AND OR: both directions */
        for (s = 0; s < 3; s++) {
            /* Dn = Dn op <ea>. AND and OR take no address register source. */
            for (i = 0; i < N_EA_ALL; i++) {
                if (EA_ALL[i].mode == 1) continue;   /* no An source for any of
                                                        these at byte size, and
                                                        none at all for AND/OR */
                sweep(op[o] | (2 << 9) | (unsigned)(s << 6),
                      &EA_ALL[i], 1, 0, NULL, NPER, 0);
            }
            sweep_pc(op[o] | (2 << 9) | (unsigned)(s << 6), 0, NULL, NPER, 0);
            /* <ea> = <ea> op Dn, memory destinations only. */
            if (mem_ok[o])
                sweep(op[o] | (6 << 9) | (unsigned)((s + 4) << 6),
                      EA_MEM, N_EA_MEM, 0, NULL, NPER, 0);
        }
        /* ADDA and SUBA: word and long, and no condition codes at all. */
        if (o < 2)
            for (s = 1; s < 3; s++)
                sweep(op[o] | (5 << 9) | (unsigned)((s == 1 ? 3 : 7) << 6),
                      EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);
    }

    /* CMP, CMPA and EOR share the 1011 line. */
    for (s = 0; s < 3; s++) {
        for (i = 0; i < N_EA_ALL; i++) {
            if (s == 0 && EA_ALL[i].mode == 1) continue;
            sweep(0xB000 | (2 << 9) | (unsigned)(s << 6),
                  &EA_ALL[i], 1, 0, NULL, NPER, 0);        /* CMP  <ea>,Dn */
        }
        sweep(0xB000 | (6 << 9) | (unsigned)((s + 4) << 6),
              EA_MEM, N_EA_MEM, 0, NULL, NPER, 0);         /* EOR  Dn,<ea> */
        sweep(0xB000 | (6 << 9) | (unsigned)((s + 4) << 6),
              EA_ALT, 1, 0, NULL, NPER, 0);                /* EOR  Dn,Dn   */
    }
    for (s = 1; s < 3; s++)
        sweep(0xB000 | (5 << 9) | (unsigned)((s == 1 ? 3 : 7) << 6),
              EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);         /* CMPA */

    /* CMPM (Ay)+,(Ax)+ -- the only mode it has. */
    for (s = 0; s < 3; s++)
        plain(0xB108 | (unsigned)(s << 6) | (2 << 9) | 3, NPER, 0);
}

/* The immediate group: ADDI SUBI ANDI ORI EORI CMPI. */
static void g_imm(void)
{
    static const unsigned int op[6] = { 0x0600, 0x0400, 0x0200, 0x0000,
                                        0x0A00, 0x0C00 };
    static const unsigned int imm_b[4] = { 0x0001, 0x007F, 0x0080, 0x00FF };
    static const unsigned int imm_w[4] = { 0x0001, 0x7FFF, 0x8000, 0xFFFF };
    int o, k, i;
    for (o = 0; o < 6; o++) {
        for (k = 0; k < 4; k++) {
            unsigned int pre[2];
            /* byte and word take one extension word, long takes two */
            pre[0] = imm_b[k];
            sweep(op[o] | (0 << 6), EA_ALT, N_EA_ALT, 1, pre, 2, 0);
            pre[0] = imm_w[k];
            sweep(op[o] | (1 << 6), EA_ALT, N_EA_ALT, 1, pre, 2, 0);
            pre[0] = imm_w[k]; pre[1] = imm_w[3 - k];
            sweep(op[o] | (2 << 6), EA_ALT, N_EA_ALT, 2, pre, 2, 0);
        }
    }
    /* ADDQ and SUBQ, every data value including the 8 that zero encodes, and
     * the address-register forms, which touch no condition code. */
    for (i = 1; i <= 8; i++) {
        unsigned int q = (unsigned)(i & 7) << 9;
        int s;
        for (s = 0; s < 3; s++) {
            sweep(0x5000 | q | (unsigned)(s << 6), EA_ALT, N_EA_ALT, 0, NULL, 2, 0);
            sweep(0x5100 | q | (unsigned)(s << 6), EA_ALT, N_EA_ALT, 0, NULL, 2, 0);
        }
        plain(0x5048 | q | 3, 2, 0);          /* ADDQ.W #i,A3 */
        plain(0x5088 | q | 3, 2, 0);          /* ADDQ.L #i,A3 */
        plain(0x5148 | q | 3, 2, 0);          /* SUBQ.W #i,A3 */
        plain(0x5188 | q | 3, 2, 0);          /* SUBQ.L #i,A3 */
    }
}

/* ADDX and SUBX, both forms: register to register and -(Ay) to -(Ax). */
static void g_extend(void)
{
    static const unsigned int op[2] = { 0xD100, 0x9100 };
    int o, s;
    for (o = 0; o < 2; o++)
        for (s = 0; s < 3; s++) {
            plain(op[o] | (unsigned)(s << 6) | (2 << 9) | 5, NPER, 0);
            plain(op[o] | (unsigned)(s << 6) | (2 << 9) | 8 | 3, NPER, 0);
        }
}

/* The shifts and rotates: ASL ASR LSL LSR ROL ROR ROXL ROXR, register forms in
 * all three sizes with both a count in the instruction and a count in a
 * register, and the memory forms, which are one bit of a word. */
static void g_shift(void)
{
    int type, dir, s, c;
    for (type = 0; type < 4; type++)
        for (dir = 0; dir < 2; dir++) {
            for (s = 0; s < 3; s++) {
                /* An immediate count of 1..8, 0 meaning 8. */
                for (c = 0; c < 8; c++)
                    plain(0xE000 | (unsigned)(c << 9) | (unsigned)(dir << 8)
                          | (unsigned)(s << 6) | (unsigned)(type << 3) | 4,
                          2, 0);
                /* A count in D2, which is random: the 68020 takes it modulo 64
                 * for the shifts and modulo the size plus one for the rotates
                 * through X, so the whole range has to be reachable. */
                plain(0xE020 | (2 << 9) | (unsigned)(dir << 8)
                      | (unsigned)(s << 6) | (unsigned)(type << 3) | 4,
                      NPER * 3, 0);
            }
            /* The memory forms shift one bit of a word. */
            sweep(0xE0C0 | (unsigned)(type << 9) | (unsigned)(dir << 8),
                  EA_MEM, N_EA_MEM, 0, NULL, NPER, 0);
        }
}

/* BTST BCHG BCLR BSET, static and dynamic. A byte in memory, a long word in a
 * register -- PRM 4: the bit number is modulo 8 for memory and modulo 32 for a
 * register, and getting that the wrong way round is a real bug this catches. */
static void g_bit(void)
{
    static const unsigned int op[4] = { 0x0000, 0x0040, 0x0080, 0x00C0 };
    int o, b;
    for (o = 0; o < 4; o++) {
        /* Dynamic: the bit number in D1. */
        sweep(0x0100 | (1 << 9) | op[o], EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);
        if (o == 0) sweep_pc(0x0100 | (1 << 9), 0, NULL, NPER, 0);  /* BTST only */
        /* Static: the bit number in the word after the opcode. */
        for (b = 0; b < 40; b += 7) {
            unsigned int pre = (unsigned)b;
            sweep(0x0800 | op[o], EA_ALT, N_EA_ALT, 1, &pre, 2, 0);
        }
    }
}

/* Scc, DBcc, Bcc, BRA and BSR over all sixteen conditions. */
static void g_cond(void)
{
    int cc;
    for (cc = 0; cc < 16; cc++) {
        /* Scc: T and F are conditions 0 and 1, and Scc has all sixteen. */
        sweep(0x50C0 | (unsigned)(cc << 8), EA_ALT, N_EA_ALT, 0, NULL, 3, 0);
        /* DBcc Dn,#d -- the count register is random, so both the taken and the
         * exhausted arms are reached. */
        plain2(0x50C8 | (unsigned)(cc << 8) | 6, 0x0004, NPER, 1);
        if (cc >= 2) {
            /* Bcc: the byte, word and long displacements. All three land inside
             * the program area, where a NOP is waiting. */
            plain(0x6000 | (unsigned)(cc << 8) | 0x04, NPER, 1);
            plain2(0x6000 | (unsigned)(cc << 8), 0x0006, NPER, 1);
            {
                unsigned int w[6];
                memset(w, 0, sizeof w);
                w[0] = 0x6000 | (unsigned)(cc << 8) | 0xFF;
                w[1] = 0x0000; w[2] = 0x0008;
                emitn(NPER, 3, w, 0, 1);
            }
        }
    }
    /* BRA and BSR, all three displacement sizes. */
    plain(0x6004, NPER, 1);
    plain2(0x6000, 0x0006, NPER, 1);
    plain(0x6104, NPER, 1);                   /* BSR.B */
    plain2(0x6100, 0x0006, NPER, 1);          /* BSR.W */
    {
        unsigned int w[6];
        memset(w, 0, sizeof w);
        w[0] = 0x61FF; w[1] = 0x0000; w[2] = 0x0008;
        emitn(NPER, 3, w, 0, 1);              /* BSR.L */
    }
}

/* JMP, JSR and the returns. The returns need a real address on the stack, which
 * is what poke_n is for -- fill would send the program counter anywhere. */
static void g_jump(void)
{
    int i;
    for (i = 0; i < N_EA_CTL; i++) {
        sweep(0x4EC0, &EA_CTL[i], 1, 0, NULL, NPER, 1);   /* JMP */
        sweep(0x4E80, &EA_CTL[i], 1, 0, NULL, NPER, 1);   /* JSR */
    }
    sweep_pc(0x4EC0, 0, NULL, NPER, 1);
    sweep_pc(0x4E80, 0, NULL, NPER, 1);

    plain(0x4E75, NPER, 1);                               /* RTS */
    poke_n(NPER, STACK, PROG_BASE + 8);
    /* RTR pops a WORD of condition codes and then a LONG program counter, so
     * the long word at the stack pointer is the codes and the top half of the
     * address, and the next one holds the bottom half. */
    plain(0x4E77, NPER, 1);                               /* RTR */
    poke_n(NPER, STACK,     0x001F0000);
    poke_n(NPER, STACK + 4, ((PROG_BASE + 8) & 0xFFFF) << 16);
    plain2(0x4E74, 0x0010, NPER, 1);                      /* RTD #16 */
    poke_n(NPER, STACK, PROG_BASE + 8);
}

/* MULU MULS DIVU DIVS, the word forms the MC68010 has and the long forms the
 * MC68020 adds. A zero divisor traps, and exception processing is M8, so the
 * divisors are poked to something non-zero and main() drops any test whose
 * oracle run left the program counter somewhere unexpected anyway. */
static void g_muldiv(void)
{
    int i;
    for (i = 0; i < N_EA_ALL; i++) {
        if (EA_ALL[i].mode == 1) continue;
        sweep(0xC0C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* MULU.W */
        sweep(0xC1C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* MULS.W */
        sweep(0x80C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* DIVU.W */
        sweep(0x81C0 | (3 << 9), &EA_ALL[i], 1, 0, NULL, NPER, 0);   /* DIVS.W */
    }
    /* The 32-bit forms, PRM 4: MULU.L <ea>,Dl and the 64-bit MULU.L <ea>,Dh:Dl,
     * and DIVU.L with a 32- and a 64-bit dividend. */
    {
        unsigned int pre;
        pre = (2 << 12);                 /* Dl = D2, unsigned, 32 bits    */
        sweep(0x4C00, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);           /* MULU.L */
        pre = (2 << 12) | 0x0800;        /* signed                        */
        sweep(0x4C00, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);           /* MULS.L */
        pre = (2 << 12) | 0x0400 | 5;    /* 64-bit product into D5:D2     */
        sweep(0x4C00, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
        pre = (2 << 12);                 /* DIVU.L <ea>,Dq                */
        sweep(0x4C40, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
        pre = (2 << 12) | 0x0800;        /* DIVS.L                        */
        sweep(0x4C40, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
        pre = (2 << 12) | 0x0400 | 5;    /* 64-bit dividend D5:D2         */
        sweep(0x4C40, EA_ALT, N_EA_ALT, 1, &pre, NPER, 0);
    }
}

/* ABCD SBCD NBCD, both register and memory forms. */
static void bcd_operands(int n)
{
    int i, j;
    for (i = 0; i < n; i++) {
        struct test *t = &tests[ntests - 1 - i];
        t->bcdfill = 1;
        for (j = 0; j < 8; j++) t->d[j] = bcd_word(t->d[j]);
    }
}

static void g_bcd(void)
{
    plain(0xC100 | (2 << 9) | 5, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* ABCD D5,D2      */
    plain(0xC108 | (2 << 9) | 3, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* ABCD -(A3),-(A2)*/
    plain(0x8100 | (2 << 9) | 5, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* SBCD D5,D2      */
    plain(0x8108 | (2 << 9) | 3, NPER * 2, 0);
    bcd_operands(NPER * 2);        /* SBCD -(A3),-(A2)*/
    sweep(0x4800, EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);/* NBCD <ea>       */
    bcd_operands(NPER * N_EA_ALT);
}

/* TAS: a read-modify-write, and the only instruction in the MC68010 set that
 * holds RMC across two accesses. */
static void g_tas(void)
{
    sweep(0x4AC0, EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);
}

/* MOVEM, both directions, both sizes, and the masks that matter: none, one at
 * each end, alternating, and all of them. The predecrement form's mask is
 * reversed, which is the part worth sweeping. */
static void g_movem(void)
{
    static const unsigned int mask[6] = { 0x0000, 0x0001, 0x8000, 0xFFFF,
                                          0xAAAA, 0x0F0F };
    int m, s;
    for (m = 0; m < 6; m++)
        for (s = 0; s < 2; s++) {
            unsigned int sz = (unsigned)(s << 6);       /* 0 word, 1 long */
            unsigned int pre = mask[m];
            /* registers to memory, and the predecrement form */
            sweep(0x4880 | sz, EA_CTL, N_EA_CTL, 1, &pre, 2, 0);
            plain2(0x4880 | sz | (4 << 3) | 3, mask[m], 2, 0);
            /* memory to registers, and the postincrement form */
            sweep(0x4C80 | sz, EA_CTL, N_EA_CTL, 1, &pre, 2, 0);
            plain2(0x4C80 | sz | (3 << 3) | 2, mask[m], 2, 0);
        }
}

/* MOVEP: a word or a long word through every other byte of memory. */
static void g_movep(void)
{
    int op;
    for (op = 4; op < 8; op++)
        plain2(0x0008 | (1 << 9) | (unsigned)(op << 6) | 3, 0x0010, NPER, 0);
}

/* The condition codes as an operand: MOVE to and from CCR, and the three
 * immediate forms. MOVE from CCR is an MC68010 addition. */
static void g_ccr(void)
{
    sweep(0x42C0, EA_ALT, N_EA_ALT, 0, NULL, NPER, 0);        /* MOVE  CCR,<ea> */
    sweep(0x44C0, EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);        /* MOVE  <ea>,CCR */
    {
        int k;
        static const unsigned int v[4] = { 0x0000, 0x001F, 0x000A, 0x0015 };
        for (k = 0; k < 4; k++) {
            plain2(0x023C, v[k], 2, 0);                       /* ANDI  #x,CCR   */
            plain2(0x003C, v[k], 2, 0);                       /* ORI   #x,CCR   */
            plain2(0x0A3C, v[k], 2, 0);                       /* EORI  #x,CCR   */
        }
    }
}

/* The exceptions that no other group reaches: the traps, the illegal and
 * unimplemented instruction lines, the privilege violation and the return.
 *
 * These are compared like any other instruction. What makes them a test of
 * exception processing is that the frame they build is in the access list --
 * four or six words, each with its address and its value -- and that the
 * program counter afterwards says which vector was taken, because every vector
 * in the table points somewhere different. */
/* One privileged instruction, run in USER mode, where it must trap.
 *
 * The user stack has to be somewhere real: the frame goes on the SUPERVISOR
 * stack -- UM 6.1 step three builds it on the active supervisor stack, and the
 * first step has already set S -- but the instruction runs with A7 meaning the
 * user one, and an instruction that touches it before trapping would go
 * somewhere undefined otherwise. */
static void user_mode(unsigned int w0, unsigned int w1, int words)
{
    int i;
    if (words) plain2(w0, w1, 2, 1);
    else       plain(w0, 2, 1);
    for (i = 0; i < 2; i++) {
        struct test *t = &tests[ntests - 1 - i];
        t->sr  = (t->sr & ~0x2000u);      /* S clear: the user level */
        t->usp = STACK - 0x100;
    }
}


/* One RTE, with a frame poked under the stack pointer. */
static void rte_frame(unsigned int sr, unsigned int pc, unsigned int fmtvec)
{
    plain(0x4E73, 2, 1);
    poke_n(2, STACK,     (sr << 16) | (pc >> 16));
    poke_n(2, STACK + 4, ((pc & 0xFFFFu) << 16) | fmtvec);
}


static void g_traps(void)
{
    int i;

    /* TRAP #0 to #15. */
    for (i = 0; i < 16; i++)
        plain(0x4E40 | (unsigned)i, 2, 1);

    /* TRAPV, both ways: the condition codes are random, so about half of these
     * trap and about half do nothing. */
    plain(0x4E76, NPER * 2, 1);

    /* TRAPcc over every condition, and all three operand forms. */
    for (i = 0; i < 16; i++) {
        plain(0x50FC | (unsigned)(i << 8), 3, 1);              /* no operand */
        plain2(0x50FA | (unsigned)(i << 8), 0x1234, 3, 1);     /* a word     */
        {
            unsigned int w[6];
            memset(w, 0, sizeof w);
            w[0] = 0x50FB | (unsigned)(i << 8);
            w[1] = 0x1234; w[2] = 0x5678;
            emitn(3, 3, w, 0, 1);                              /* a long word */
        }
    }

    /* ILLEGAL, and the two lines the MC68020 leaves unimplemented so that a
     * coprocessor or an emulator can have them -- UM 6.1.5. */
    plain(0x4AFC, 2, 1);                                       /* ILLEGAL */
    plain(0xA000, 2, 1);                                       /* A-line  */
    plain(0xA5A5, 2, 1);
    plain(0xF000, 2, 1);                                       /* F-line  */
    plain(0xF5A5, 2, 1);

    /* The privileged instructions, run at the supervisor level, where they are
     * legal: this half is the test that each one does what it says. The other
     * half -- that each one TRAPS in user mode -- is user_mode() below, which
     * clears S in the starting state and expects vector 8 every time. */
    /* RTE, over the frames UM 6.1.12 says it understands and one it does not.
     *
     * A frame is a WORD of status register at +$00, a LONG program counter at
     * +$02 and a WORD of format and vector at +$06, so a long-word poke at the
     * base carries the status register and the TOP HALF of the program
     * counter. Writing the obvious thing there instead put $1010 in the format
     * word, which is a throwaway frame, and the test then measured something
     * nobody meant to ask about. */
    rte_frame(0x0000, 0x00001010u, 0x0000);   /* $0, returning to user mode */
    rte_frame(0x2700, 0x00001010u, 0x0000);   /* $0, staying supervisor     */
    rte_frame(0x2000, 0x00001010u, 0x2000);   /* $2, a six-word frame       */
    rte_frame(0x2700, 0x00001010u, 0x7000);   /* and a format error          */
    plain2(0x46FC, 0x2700, 2, 0);                              /* MOVE #imm,SR */
    plain(0x40C0 | 3, 2, 0);                                   /* MOVE SR,D3   */
    plain2(0x027C, 0xF8FF, 2, 0);                              /* ANDI #x,SR   */
    plain2(0x007C, 0x0700, 2, 0);                              /* ORI  #x,SR   */
    plain2(0x0A7C, 0x1000, 2, 0);                              /* EORI #x,SR   */
    plain(0x4E60 | 3, 2, 0);                                   /* MOVE A3,USP  */
    plain(0x4E68 | 3, 2, 0);                                   /* MOVE USP,A3  */

    /* And a divide by zero, which no other group produces on purpose. */
    plain2(0x82BC, 0x0000, 2, 1);                              /* DIVU.L #0,D1 */
    poke_n(2, DATA_BASE, 0);

    /* UM 6.1.6: "if a user program attempts to execute a privileged
     * instruction, a privilege violation exception occurs". Every one of these
     * is the same instruction as above with the S bit clear, and every one of
     * them must end at vector 8 with a four-word frame carrying the address of
     * the instruction that tried. */
    user_mode(0x4E73, 0, 0);                                   /* RTE          */
    user_mode(0x46FC, 0x2700, 1);                              /* MOVE #imm,SR */
    user_mode(0x40C0 | 3, 0, 0);                               /* MOVE SR,D3   */
    user_mode(0x027C, 0xF8FF, 1);                              /* ANDI #x,SR   */
    user_mode(0x007C, 0x0700, 1);                              /* ORI  #x,SR   */
    user_mode(0x0A7C, 0x1000, 1);                              /* EORI #x,SR   */
    user_mode(0x4E60 | 3, 0, 0);                               /* MOVE A3,USP  */
    user_mode(0x4E68 | 3, 0, 0);                               /* MOVE USP,A3  */
    user_mode(0x4E7A, 0x0000, 1);                              /* MOVEC SFC,D0 */
    user_mode(0x4E7B, 0x0000, 1);                              /* MOVEC D0,SFC */
}

/* Tracing -- UM 6.1.7 and table 6-2.
 *
 * The same instructions run three times: with tracing off, with T1 set (every
 * instruction is traced) and with T0 set (only those that change the flow). The
 * mix is chosen so that the second and third disagree -- a MOVEQ is traced by
 * one and not the other, a BRA by both -- because a test where they agree
 * cannot tell the two modes apart.
 *
 * T1 T0 = 11 is "undefined, reserved" in table 6-2 and is not swept.
 */
static void trace_at(unsigned int w0, unsigned int w1, int words, int flow)
{
    int i, k;
    static const unsigned int mode[3] = { 0x0000u, 0x8000u, 0x4000u };
    for (k = 0; k < 3; k++) {
        if (words) plain2(w0, w1, 2, flow);
        else       plain(w0, 2, flow);
        for (i = 0; i < 2; i++) {
            struct test *t = &tests[ntests - 1 - i];
            t->sr = (t->sr & 0x3FFFu) | mode[k];
        }
    }
}

static void g_trace(void)
{
    /* Instructions that do NOT change the flow. */
    trace_at(0x7042, 0, 0, 0);                  /* MOVEQ #$42,D0   */
    trace_at(0x2200, 0, 0, 0);                  /* MOVE.L D0,D1    */
    trace_at(0xD282, 0, 0, 0);                  /* ADD.L  D2,D1    */
    trace_at(0x4E71, 0, 0, 0);                  /* NOP             */

    /* ... and instructions that do. */
    trace_at(0x6004, 0, 0, 1);                  /* BRA.B  *+6      */
    trace_at(0x6000, 0x0006, 1, 1);             /* BRA.W           */
    trace_at(0x4EF8, 0x1010, 1, 1);             /* JMP $1010.W     */
    trace_at(0x4E40, 0, 0, 1);                  /* TRAP #0         */
    trace_at(0x4E76, 0, 0, 1);                  /* TRAPV           */

    /* A status register write counts as a change of flow -- UM 6.1.7, because
     * a real part re-prefetches after one. */
    trace_at(0x46FC, 0x2700, 1, 1);             /* MOVE #imm,SR    */
    trace_at(0x007C, 0x0000, 1, 1);             /* ORI  #0,SR      */

    /* And an instruction that is never executed, which UM 6.1.7 says is NOT
     * traced however the bits are set. */
    trace_at(0x4AFC, 0, 0, 1);                  /* ILLEGAL         */
    trace_at(0xA000, 0, 0, 1);                  /* A-line          */
}

/* MOVEC, both directions, over the control registers PRM 6 gives the MC68020.
 *
 * CACR is deliberately absent: which of its bits are implemented is a property
 * of the cache, and the cache is M11. The instruction reaches it either way;
 * what is not yet swept is what it reads back. */
static void g_movec(void)
{
    static const unsigned int rc[7] = { 0x000, 0x001, 0x800, 0x801,
                                        0x802, 0x803, 0x804 };
    int i, ad, n;
    for (i = 0; i < 7; i++)
        for (ad = 0; ad < 2; ad++)
            for (n = 1; n < 4; n++) {
                unsigned int ext = (unsigned)(ad << 15)
                                 | (unsigned)(n << 12) | rc[i];
                plain2(0x4E7A, ext, 2, 0);      /* MOVEC Rc,Rn */
                plain2(0x4E7B, ext, 2, 0);      /* MOVEC Rn,Rc */
            }
}

/* CHK, word and long. Only the cases that do NOT trap: the trap is M8. main()
 * drops the ones that do. */
static void g_chk(void)
{
    sweep(0x4180 | (2 << 9), EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);   /* CHK.W */
    sweep(0x4100 | (2 << 9), EA_ALL, N_EA_ALL, 0, NULL, NPER, 0);   /* CHK.L */
}

/* ------------------------------------------------------------------ */
/* The catalogue                                                       */
/* ------------------------------------------------------------------ */

struct group { const char *name; void (*build)(void); };

static const struct group GROUPS[] = {
    { "move",    g_move    },
    { "moveq",   g_moveq   },
    { "unary",   g_unary   },
    { "misc",    g_misc    },
    { "addr",    g_addr    },
    { "alu",     g_alu     },
    { "imm",     g_imm     },
    { "extend",  g_extend  },
    { "shift",   g_shift   },
    { "bit",     g_bit     },
    { "cond",    g_cond    },
    { "jump",    g_jump    },
    { "muldiv",  g_muldiv  },
    { "bcd",     g_bcd     },
    { "tas",     g_tas     },
    { "movem",   g_movem   },
    { "movep",   g_movep   },
    { "ccr",     g_ccr     },
    { "chk",     g_chk     },
    { "movec",   g_movec   },
    { "traps",   g_traps   },
    { "trace",   g_trace   },
};
#define NGROUPS ((int)(sizeof GROUPS / sizeof GROUPS[0]))

/* The program area is filled with NOPs before the instruction is written, on
 * both sides, so that a branch has somewhere defined to land and a
 * memory-indirect mode that reads the instruction stream reads the same thing
 * here as it does in the core's memory. */
#define PROG_FILL  0x40

struct result {
    int          keep;
    unsigned int d[8], a[7], usp, isp, sr, pc;
    unsigned int msp, vbr, sfc, dfc, caar;
    int          nacc;
    struct { unsigned int addr, rw, bytes, prog, value; } acc[MAXACC];
};

int main(int argc, char **argv)
{
    int i, j;
    long kept = 0, dropped = 0;
    int  div_ovf_c = 0;
    struct test *t;
    struct result *res, *r;

    tests = calloc(MAXTESTS, sizeof *tests);
    if (!tests) { fprintf(stderr, "vectors: out of memory\n"); return 1; }

    rng_state = 0x13572468u;
    if (argc < 2 || !strcmp(argv[1], "all")) {
        for (i = 0; i < NGROUPS; i++) GROUPS[i].build();
    } else {
        for (j = 1; j < argc; j++) {
            for (i = 0; i < NGROUPS; i++)
                if (!strcmp(argv[j], GROUPS[i].name)) { GROUPS[i].build(); break; }
            if (i == NGROUPS) {
                fprintf(stderr, "vectors: no group %s. There is:", argv[j]);
                for (i = 0; i < NGROUPS; i++) fprintf(stderr, " %s", GROUPS[i].name);
                fprintf(stderr, "\n");
                return 1;
            }
        }
    }

    res = calloc((size_t)ntests, sizeof *res);
    if (!res) { fprintf(stderr, "vectors: out of memory\n"); return 1; }

    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68020);

    for (i = 0; i < ntests; i++) {
        t = &tests[i];
        r = &res[i];

        memset(mem, 0, sizeof mem);
        /* Each exception vector points somewhere DIFFERENT, so that an
         * instruction which trapped through the wrong one shows as a wrong
         * program counter rather than as nothing at all. */
        for (j = 0; j < 256; j++)
            wr32((unsigned)j * 4, 0x00009000u + (unsigned)j * 4);
        wr32(0, STACK);
        wr32(4, PROG_BASE);
        for (j = 0; j < DATA_SIZE; j += 4) {
            unsigned int fw = fill_word(i, (unsigned)j);
            wr32(DATA_BASE + (unsigned)j, t->bcdfill ? bcd_word(fw) : fw);
        }
        for (j = 0; j < PROG_FILL; j += 2)
            wr16(PROG_BASE + (unsigned)j, 0x4E71);
        for (j = 0; j < t->nwords; j++)
            wr16(PROG_BASE + (unsigned)j * 2, t->w[j]);
        for (j = 0; j < t->npoke; j++)
            wr32(t->poke_a[j], t->poke_v[j]);

        m68k_pulse_reset();
        /* m68k_pulse_reset leaves RESET_CYCLES set, and m68k_execute spends
         * its whole budget on those before it looks at an instruction:
         *
         *     if (RESET_CYCLES) { num_cycles -= rc; if (num_cycles <= 0) return rc; }
         *
         * so the first m68k_execute(1) after a reset runs NOTHING and returns.
         * A budget of zero absorbs them and executes nothing, which is what is
         * wanted here. See doc/bugs-found.md.
         */
        m68k_execute(0);
        for (j = 0; j < 8; j++) m68k_set_reg(M68K_REG_D0 + j, t->d[j]);
        for (j = 0; j < 7; j++) m68k_set_reg(M68K_REG_A0 + j, t->a[j]);
        /* The STATUS REGISTER first, and not as a matter of taste. Musashi
         * keeps the active stack pointer in A7 and the other two beside it, so
         * m68k_set_reg for USP, ISP or MSP writes A7 or the saved copy
         * depending on the S and M flags AS THEY ARE AT THAT MOMENT:
         *
         *     case M68K_REG_ISP: if(FLAG_S && !FLAG_M) REG_SP = value;
         *                        else                  REG_ISP = value;
         *
         * Setting them before the status register leaves them wherever the
         * PREVIOUS test's flags put them. RTE returning to user mode is what
         * showed it: the oracle came back with a user stack pointer eight
         * higher than it started, which is not something RTE does. */
        m68k_set_reg(M68K_REG_SR,  t->sr);
        m68k_set_reg(M68K_REG_USP, t->usp);
        m68k_set_reg(M68K_REG_ISP, t->isp);
        m68k_set_reg(M68K_REG_MSP,  t->imsp);
        m68k_set_reg(M68K_REG_SFC,  t->isfc);
        m68k_set_reg(M68K_REG_DFC,  t->idfc);
        m68k_set_reg(M68K_REG_VBR,  t->ivbr);
        m68k_set_reg(M68K_REG_CAAR, t->icaar);
        m68k_set_reg(M68K_REG_PC,  PROG_BASE);

        nacc       = 0;
        overflowed = 0;
        cur_pcrel  = t->pcrel;
        /* MOVE.L <ea>,-(An), and MOVEM.L regs,-(An). MOVEM.W to the same mode
         * writes single words at descending addresses and must NOT be merged,
         * which is why the size bit is part of the test. */
        split_pd = (((t->w[0] & 0xF000u) == 0x2000u)
                    && ((t->w[0] & 0x01C0u) == 0x0100u))
                || ((t->w[0] & 0xFFF8u) == 0x48E0u);
        recording  = 1;
        m68k_execute(1);
        recording  = 0;

        /* Anything that touched the vector table took an exception, and
         * exception processing is M8. Anything that made more accesses than
         * there is room to record cannot be compared. Both are dropped, and
         * the count of them is printed so that a group that silently stopped
         * testing anything is visible. */
        // PRM 4's undefined rows. The mask is set AFTER the run because one of
        // them depends on what happened: a divide only leaves N and Z undefined
        // when it overflowed.
        {
            unsigned int op = t->w[0];
            unsigned int sr_after = m68k_get_reg(NULL, M68K_REG_SR);
            int is_abcd = ((op & 0xF1F0u) == 0xC100u)     /* ABCD */
                       || ((op & 0xF1F0u) == 0x8100u)     /* SBCD */
                       || ((op & 0xFFC0u) == 0x4800u);    /* NBCD */
            int is_divw = ((op & 0xF0C0u) == 0x80C0u)     /* DIVU.W, DIVS.W */
                       && ((op & 0x01C0u) == 0x00C0u || (op & 0x01C0u) == 0x01C0u);
            int is_divl = ((op & 0xFFC0u) == 0x4C40u);    /* DIVU.L, DIVS.L */
            int is_chk  = ((op & 0xF040u) == 0x4000u)
                       && (((op >> 6) & 7) == 6 || ((op >> 6) & 7) == 4)
                       && ((op & 0xF000u) == 0x4000u) && ((op & 0x0100u) != 0);
            if (is_abcd)                     t->srmask &= ~0x000Au;  /* N and V */
            if ((is_divw || is_divl) && (sr_after & 2)) t->srmask &= ~0x000Cu; /* N and Z */
            if (is_chk)                      t->srmask &= ~0x000Fu;  /* N Z V C */
            div_ovf_c = (is_divw || is_divl) && (sr_after & 2);
        }

        /* UM 6.1.8: "the stacked PC value is the logical address of the
         * instruction that DETECTED the format error" -- the RTE itself, not
         * the instruction after it. Musashi stacks the one after. The manual
         * is the arbiter, so the recorded frame is corrected; the alternative
         * was to stop comparing the one word this test exists to check.
         * doc/divergences.md. */
        if (t->w[0] == 0x4E73u
            && m68k_get_reg(NULL, M68K_REG_PC) == 0x9000u + 14u * 4u) {
            for (j = 0; j < nacc; j++)
                if (!acc[j].rw && acc[j].bytes == 4
                    && acc[j].value == PROG_BASE + 2)
                    acc[j].value = PROG_BASE;
        }

        /* Only a test that made more accesses than there is room to record is
         * dropped now. Up to M7 a test that touched the vector table was
         * dropped too, because exception processing did not exist; it does
         * now, and the frame such a test builds is in the access list with the
         * value of every word in it.
         *
         * ... and one whose oracle ended with an ODD program counter. UM 6.1.3:
         * "an address error exception occurs when the processor attempts to
         * prefetch an instruction from an odd address". Musashi does not model
         * that for this part and carries on executing from the odd address, so
         * the two machines are doing different things from there on and there
         * is nothing to compare. JMP and JSR through an address register are
         * what reach it. doc/divergences.md. */
        r->keep = !overflowed
               && ((m68k_get_reg(NULL, M68K_REG_PC) & 1u) == 0u);
        if (!r->keep) { dropped++; continue; }
        kept++;

        for (j = 0; j < 8; j++) r->d[j] = m68k_get_reg(NULL, M68K_REG_D0 + j);
        for (j = 0; j < 7; j++) r->a[j] = m68k_get_reg(NULL, M68K_REG_A0 + j);
        r->usp = m68k_get_reg(NULL, M68K_REG_USP);
        r->isp = m68k_get_reg(NULL, M68K_REG_ISP);
        r->sr  = m68k_get_reg(NULL, M68K_REG_SR);
        /* PRM 4's row for DIVU and DIVS is "C -- Always cleared", with no
         * qualifier -- unlike N, Z and V, which each carry an "undefined if
         * overflow" of their own. Musashi's overflow path is
         *
         *     FLAG_V = VFLAG_SET;
         *     return;
         *
         * so it leaves C at whatever the instruction before it left. The manual
         * is the arbiter; the oracle is corrected. doc/divergences.md. */
        if (div_ovf_c) r->sr &= ~1u;
        r->pc  = m68k_get_reg(NULL, M68K_REG_PC);
        r->msp  = m68k_get_reg(NULL, M68K_REG_MSP);
        r->vbr  = m68k_get_reg(NULL, M68K_REG_VBR);
        r->sfc  = m68k_get_reg(NULL, M68K_REG_SFC);
        r->dfc  = m68k_get_reg(NULL, M68K_REG_DFC);
        r->caar = m68k_get_reg(NULL, M68K_REG_CAAR);
        r->nacc = nacc;
        for (j = 0; j < nacc; j++) {
            r->acc[j].addr  = acc[j].addr;
            r->acc[j].rw    = acc[j].rw;
            r->acc[j].bytes = acc[j].bytes;
            r->acc[j].prog  = acc[j].prog;
            r->acc[j].value = acc[j].value;
        }
    }

    fprintf(stderr, "vectors: %ld tests, %ld dropped because the oracle took an "
                    "exception or ran out of room\n", kept, dropped);
    if (kept == 0) { fprintf(stderr, "vectors: nothing to test\n"); return 1; }

    printf("%lx\n", kept);
    for (i = 0; i < ntests; i++) {
        t = &tests[i];
        r = &res[i];
        if (!r->keep) continue;
        printf("%x %x", i, t->nwords);
        for (j = 0; j < 6; j++) printf(" %x", t->w[j]);
        printf("\n");
        for (j = 0; j < 8; j++) printf("%x ", t->d[j]);
        for (j = 0; j < 7; j++) printf("%x ", t->a[j]);
        printf("%x %x %x %x %x %x %x %x\n", t->usp, t->isp, t->sr,
               t->imsp, t->isfc, t->idfc, t->ivbr, t->icaar);
        printf("%x", t->npoke);
        for (j = 0; j < t->npoke; j++) printf(" %x %x", t->poke_a[j], t->poke_v[j]);
        printf(" %x %x\n", t->srmask, (unsigned)t->bcdfill);
        for (j = 0; j < 8; j++) printf("%x ", r->d[j]);
        for (j = 0; j < 7; j++) printf("%x ", r->a[j]);
        printf("%x %x %x %x %x %x %x %x %x\n", r->usp, r->isp, r->sr, r->pc,
               r->msp, r->vbr, r->sfc, r->dfc, r->caar);
        printf("%x", r->nacc);
        for (j = 0; j < r->nacc; j++)
            printf(" %x %x %x %x %x", r->acc[j].addr, r->acc[j].rw,
                   r->acc[j].bytes, r->acc[j].prog, r->acc[j].value);
        printf("\n");
    }
    return 0;
}
