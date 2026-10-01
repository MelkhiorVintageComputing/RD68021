/* SPDX-License-Identifier: CERN-OHL-S-2.0
 * Copyright 2026 Romain Dolbeau
 * Source location: https://github.com/MelkhiorVintageComputing/RD68021
 */

/* RD68021 -- a program that exercises the integer set through a compiler.
 *
 * The point is not that it computes anything useful. The point is that GCC
 * chooses the instructions, the addressing modes and the register allocation,
 * so the mix is one nobody here designed -- which is exactly what a sweep
 * written by the same person who wrote the microcode cannot provide.
 *
 * The Debian cross-compiler's default -mcpu IS 68020 and its libgcc is built
 * for it, so the 32-bit multiply and the long divide come out as MULS.L and
 * DIVS.L rather than as calls, and the 64-bit arithmetic comes out as calls
 * into libgcc that this core then has to run.
 *
 * Nothing here may trap: exception processing is M8. So no division by zero, no
 * CHK, and no dereference of anything that is not in the first 64 KB.
 */

typedef unsigned char      u8;
typedef unsigned short     u16;
typedef unsigned long      u32;
typedef unsigned long long u64;
typedef signed char        s8;
typedef short              s16;
typedef long               s32;
typedef long long          s64;

static u32 state = 0x13572468UL;

static u32 rnd(void)
{
    state = state * 1103515245UL + 12345UL;
    return (state >> 8) ^ (state << 13);
}

/* Arrays, so that the indexed and displacement modes get used and so that
   something has to be written to memory and read back. */
static u32 tab[64];
static s16 wtab[64];
static u8  btab[64];

struct thing {
    u32 a;
    s16 b;
    u8  c;
    s32 d;
};

static struct thing things[8];

/* Not inlined, so that there are real calls: BSR and JSR, LINK and UNLK, and a
   stack frame to walk. */
__attribute__((noinline))
static s32 mix(s32 x, s32 y, s32 z)
{
    s32 t = x * y;
    t += z << 3;
    t -= x >> 2;
    t ^= y;
    if (y != 0) t /= (y | 1);
    return t;
}

__attribute__((noinline))
static u64 wide(u32 x, u32 y)
{
    u64 p = (u64)x * (u64)y;
    p += ((u64)y << 17);
    p ^= 0x0123456789ABCDEFULL;
    return p;
}

__attribute__((noinline))
static int count_bits(u32 v)
{
    int n = 0;
    while (v) { n += (int)(v & 1u); v >>= 1; }
    return n;
}

int main(void)
{
    int i, j;
    u32 acc = 0;
    s32 sacc = 0;
    u64 wacc = 0;

    for (i = 0; i < 64; i++) {
        tab[i]  = rnd();
        wtab[i] = (s16)(rnd() >> 3);
        btab[i] = (u8)(rnd() >> 11);
    }

    for (i = 0; i < 8; i++) {
        things[i].a = tab[i * 3];
        things[i].b = wtab[i * 5];
        things[i].c = btab[i * 7];
        things[i].d = (s32)tab[i] - (s32)tab[63 - i];
    }

    /* Every shift and rotate the compiler will give us, and the conditionals
       that follow from them. */
    for (i = 0; i < 64; i++) {
        u32 v = tab[i];
        acc += v << (i & 31);
        acc ^= v >> (i & 31);
        acc += (u32)((s32)v >> (i & 15));
        acc -= count_bits(v);
        if ((s32)v < 0)      acc += 3;
        else if (v > acc)    acc -= 5;
        else                 acc ^= 0x5A5A5A5AUL;
    }

    /* Byte and word memory, which is where the misaligned splits come from. */
    for (i = 0; i < 64; i++) {
        btab[i] = (u8)(btab[i] + (u8)i);
        wtab[i] = (s16)(wtab[i] * 3 - (s16)i);
        acc += btab[i];
        sacc += wtab[i];
    }

    for (i = 0; i < 8; i++) {
        sacc += mix(things[i].d, (s32)things[i].b, (s32)things[i].c);
        wacc += wide(things[i].a, (u32)(i + 1));
    }

    /* A switch, for the jump table and the comparisons that guard it. */
    for (i = 0; i < 32; i++) {
        switch (i & 7) {
        case 0: acc += 1; break;
        case 1: acc -= 2; break;
        case 2: acc *= 3; break;
        case 3: acc ^= 4; break;
        case 4: acc |= 5; break;
        case 5: acc &= ~6UL; break;
        case 6: acc = (acc << 7) | (acc >> 25); break;
        default: acc = ~acc; break;
        }
    }

    /* A block copy and a compare, which is where MOVEM and the postincrement
       modes turn up. */
    for (j = 0; j < 4; j++) {
        for (i = 0; i < 32; i++) tab[i + 32] = tab[i] + (u32)j;
        for (i = 0; i < 32; i++) if (tab[i + 32] != tab[i] + (u32)j) acc ^= 0xDEADU;
    }

    return (int)(acc ^ (u32)sacc ^ (u32)wacc ^ (u32)(wacc >> 32));
}
