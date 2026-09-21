/* RD68021 -- the instruction-by-instruction oracle.
 *
 * Loads a flat image, runs it under Musashi as an MC68020, and prints the
 * architectural state at EVERY instruction boundary. sim/tb/core_cosim_tb.sv
 * runs the same image on the core and compares at the same boundaries, so a
 * divergence is reported at the instruction that caused it rather than at the
 * end of a program that came out wrong.
 *
 *     build/musashi/musashi_trace <image.bin> [limit]
 *
 * Musashi is an ORACLE, not a source. Where the two disagree the manual decides.
 *
 * The output, read positionally by $fscanf("%h"):
 *
 *     ninstr
 *     per instruction:  pc  d0..d7  a0..a6  usp  isp  sr
 *
 * The program stops itself with a branch to itself -- see sim/programs/crt0.S --
 * and that is what ends the trace: the first instruction whose program counter
 * is the one before it has nothing after it worth comparing.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "m68k.h"

#define MEMSIZE 0x00010000

static unsigned char mem[MEMSIZE];

static unsigned int rd8(unsigned int a)  { return mem[a & (MEMSIZE - 1)]; }
static unsigned int rd16(unsigned int a) { return (rd8(a) << 8) | rd8(a + 1); }
static unsigned int rd32(unsigned int a) { return (rd16(a) << 16) | rd16(a + 2); }
static void wr8(unsigned int a, unsigned int v) { mem[a & (MEMSIZE - 1)] = v; }

unsigned int m68k_read_memory_8(unsigned int a)  { return rd8(a); }
unsigned int m68k_read_memory_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_memory_32(unsigned int a) { return rd32(a); }
unsigned int m68k_read_immediate_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_immediate_32(unsigned int a) { return rd32(a); }
unsigned int m68k_read_pcrelative_8(unsigned int a)  { return rd8(a); }
unsigned int m68k_read_pcrelative_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_pcrelative_32(unsigned int a) { return rd32(a); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return rd16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return rd32(a); }

void m68k_write_memory_8(unsigned int a, unsigned int v)  { wr8(a, v); }
void m68k_write_memory_16(unsigned int a, unsigned int v)
{ wr8(a, v >> 8); wr8(a + 1, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v)
{ m68k_write_memory_16(a, v >> 16); m68k_write_memory_16(a + 2, v); }

#define MAXSTEPS 4000000

static unsigned int pc[MAXSTEPS];
static unsigned int st[MAXSTEPS][18];   /* d0..d7 a0..a6 usp isp sr */

int main(int argc, char **argv)
{
    FILE *f;
    long  n;
    int   i, j, steps = 0, limit = MAXSTEPS;
    unsigned int prev_pc = 0xFFFFFFFFu;

    if (argc < 2) { fprintf(stderr, "usage: musashi_trace <image.bin>\n"); return 1; }
    if (argc > 2) limit = atoi(argv[2]);
    if (limit > MAXSTEPS) limit = MAXSTEPS;

    f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    n = (long)fread(mem, 1, MEMSIZE, f);
    fclose(f);
    if (n <= 8) { fprintf(stderr, "musashi_trace: %s is %ld bytes\n", argv[1], n); return 1; }

    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68020);
    m68k_pulse_reset();
    /* m68k_pulse_reset leaves RESET_CYCLES set and m68k_execute spends its whole
     * budget on those before it looks at an instruction, so the first step after
     * a reset would run nothing. See doc/bugs-found.md. */
    m68k_execute(0);

    /* The reset exception has already loaded the stack pointer and the program
     * counter from the first two long words -- UM 6.1.1 -- which is exactly what
     * the core does with them too. */

    while (steps < limit) {
        unsigned int now = m68k_get_reg(NULL, M68K_REG_PC);
        /* The branch to itself that ends every program here. Recorded once, so
         * that the testbench has a boundary to stop on, and then no more. */
        if (now == prev_pc) break;
        prev_pc = now;

        pc[steps] = now;
        for (j = 0; j < 8; j++) st[steps][j]      = m68k_get_reg(NULL, M68K_REG_D0 + j);
        for (j = 0; j < 7; j++) st[steps][8 + j]  = m68k_get_reg(NULL, M68K_REG_A0 + j);
        st[steps][15] = m68k_get_reg(NULL, M68K_REG_USP);
        st[steps][16] = m68k_get_reg(NULL, M68K_REG_ISP);
        st[steps][17] = m68k_get_reg(NULL, M68K_REG_SR);
        steps++;

        m68k_execute(1);
    }

    fprintf(stderr, "trace: %d instructions\n", steps);
    printf("%x\n", steps);
    for (i = 0; i < steps; i++) {
        printf("%x", pc[i]);
        for (j = 0; j < 18; j++) printf(" %x", st[i][j]);
        printf("\n");
    }
    return 0;
}
