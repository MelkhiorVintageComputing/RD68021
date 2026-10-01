/* SPDX-License-Identifier: CERN-OHL-S-2.0
 * Copyright 2026 Romain Dolbeau
 * Source location: https://github.com/MelkhiorVintageComputing/RD68021
 */

/* RD68021 -- an MC68881 behind the coprocessor interface, for TME.
 *
 * TME's own MC68881 lives inside its CPU emulation: its instructions read their
 * operands straight out of the emulated processor's registers and memory, and it
 * never speaks the M68000 coprocessor protocol. The RTL core does speak it --
 * UM section 7 -- and needs a coprocessor on its bus. This is one: the MC68881's
 * side of the protocol, written from MC68881 UM section 7 ("the instruction
 * dialogs", table 7-7's primitives), in front of TME's floating-point arithmetic.
 *
 * The arithmetic is TME's, deliberately. `make sunos-fpu` compares a machine
 * with TME's m68020 and its built-in MC68881 against one with the core and this;
 * both do their arithmetic in the same code, so a difference can only come from
 * the protocol -- which operand was transferred, where, in which order -- and
 * that is what is under test. TME is a reference implementation used here as a
 * device, exactly as its MMU and serial chips are; nothing in rtl/ comes from it.
 *
 * This file is appended to build/tme's copy of ic/m68k/m6888x.c by
 * sim/tme/build.sh, so that it can use that file's static helpers (the predicate
 * evaluator and the fpgen tables). TME's routines are handed a private
 * struct tme_m68k that only ever holds FPU state: an operand arrives through the
 * operand CIR and is put where the routine expects a data register or an
 * immediate, never in memory, and a result is taken out of the routine's
 * internal registers before it would store it (the one patch build.sh makes to
 * tme_m68k_fmove_rm). An exception inside TME's code leaves it by longjmp to
 * the private structure's dispatcher, which is set here.
 *
 * What the MC68881 does, per instruction class (MC68881 UM 7.5):
 *
 *   opclass 000  register to register: computed at once, released ($0802)
 *   opclass 010  external to register: evaluate <ea> and transfer data in
 *                ($95nn data, $96nn memory), then released
 *   opclass 011  register to external: the result, evaluate <ea> and transfer
 *                data out ($B1nn data alterable, $B2nn memory alterable)
 *   opclass 100  control registers in:  $9504 / $9608 / $960C, $9704 for FPIAR
 *   opclass 101  control registers out: $B104 / $B208 / $B20C, $B304 for FPIAR
 *   opclass 110  FMOVEM in, 111 out: transfer multiple coprocessor registers
 *                ($810C / $A10C), after transfer single main processor register
 *                ($8C0n) for a dynamic list
 *   conditional  the predicate evaluated, answered with a null primitive: TF
 *   FSAVE        null ($0000) until the first instruction, then idle ($1F18)
 *                with six long words
 *   FRESTORE     null resets the FPU; idle is taken; anything else is invalid
 *
 * Not done, and none of it is used by the programs `make sunos-fpu` runs:
 * packed decimal out (TME punts on it too), arithmetic exceptions enabled in
 * the FPCR (reported as a preinstruction exception rather than on the next
 * instruction), the PC bit (so FPIAR is not updated -- the MC68881 allows the
 * main processor to ignore it, and this front end never asks), and the busy
 * state frame: every instruction here finishes before its dialogue does.
 */

#define RD_FPU_IDLE_FORMAT  0x1f18      /* MC68881 idle frame, $18 bytes */

struct rd68021_fpu {
  struct tme_m68k *ic;          /* FPU state only */
  tme_uint16_t resp;            /* what the response CIR reads as */
  tme_uint16_t rest;            /* ... and the restore CIR */
  tme_uint16_t regsel;          /* ... and the register select CIR */
  int used;                     /* an instruction since reset or a null restore */

  /* the operand being moved through the operand CIR */
  enum { RD_FPU_NONE, RD_FPU_IN, RD_FPU_OUT, RD_FPU_DREG } phase;
  tme_uint8_t buf[256];
  unsigned int len, pos;
  tme_uint16_t command;

  /* what completes when an incoming operand is whole */
  enum { RD_FPU_DO_GEN, RD_FPU_DO_CTL, RD_FPU_DO_MOVEM, RD_FPU_DO_RESTORE,
         RD_FPU_DO_NOTHING } done;
  unsigned int movem_regs[8], movem_n;
};

/* the one patch to tme_m68k_fmove_rm: return once the result is in memx, memy
   and memz, before it is stored. */
int rd68021_fpu_capture;

static void
_rd_fpu_put32(tme_uint8_t *b, tme_uint32_t v)
{
  b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v;
}

static tme_uint32_t
_rd_fpu_get32(const tme_uint8_t *b)
{
  return ((tme_uint32_t) b[0] << 24) | ((tme_uint32_t) b[1] << 16)
    | ((tme_uint32_t) b[2] << 8) | b[3];
}

/* the size of an operand of each source or destination format: */
static const unsigned int _rd_fpu_format_len[8] = {
  4,   /* long */
  4,   /* single */
  12,  /* extended */
  12,  /* packed, static k */
  2,   /* word */
  8,   /* double */
  1,   /* byte */
  12,  /* packed, dynamic k */
};

struct rd68021_fpu *
rd68021_fpu_new(void)
{
  struct rd68021_fpu *f;
  struct tme_m68k *ic;
  static const char * const args[] = {
    "fpu", "fpu-type", "m68881", "fpu-compliance", "unknown",
    "fpu-incomplete", "line-f", NULL
  };
  int arg_i = 1, usage = FALSE;
  char *output = NULL;

  f = tme_new0(struct rd68021_fpu, 1);
  ic = tme_new0(struct tme_m68k, 1);
  f->ic = ic;
  ic->tme_m68k_fpu_type = TME_M68K_FPU_NONE;
  if (!tme_m68k_fpu_new(ic, args, &arg_i, &usage, &output) || usage) {
    abort();
  }
  ic->tme_m68k_fpu_enabled = TRUE;
  /* not restarting: TME_M68K_SEQUENCE_RESTARTING compares these two */
  ic->_tme_m68k_sequence._tme_m68k_sequence_transfer_next = 1;
  ic->_tme_m68k_sequence._tme_m68k_sequence_transfer_faulted = 0;
  tme_m68k_fpu_reset(ic);
  f->resp = 0x0802;
  f->phase = RD_FPU_NONE;
  return (f);
}

/* run one of TME's FPU routines; a nonzero return is the exception it raised */
static tme_uint32_t
_rd_fpu_run(struct rd68021_fpu *f,
            void (*insn) _TME_P((struct tme_m68k *, void *, void *)),
            tme_uint16_t opcode, tme_uint16_t specop, void *op1)
{
  struct tme_m68k *ic = f->ic;
  tme_uint32_t exceptions;

  ic->_tme_m68k_insn_opcode = opcode;
  ic->_tme_m68k_insn_specop = specop;
  ic->_tme_m68k_exceptions = 0;
  ic->_tme_m68k_sequence._tme_m68k_sequence_transfer_next = 1;
  ic->_tme_m68k_sequence._tme_m68k_sequence_transfer_faulted = 0;
  if (setjmp(ic->_tme_m68k_dispatcher)) {
    exceptions = ic->_tme_m68k_exceptions;
    ic->_tme_m68k_exceptions = 0;
    return (exceptions ? exceptions : TME_M68K_EXCEPTION_ILL);
  }
  (*insn)(ic, NULL, op1);
  return (0);
}

/* what an exception inside TME's code becomes on the protocol: an illegal
   command is the F-line emulator exception the MC68881 asks for with a
   preinstruction primitive (MC68881 UM 7.5.4.5); an arithmetic exception, its
   own vector the same way. */
static tme_uint16_t
_rd_fpu_exception_primitive(tme_uint32_t exceptions)
{
  if (TME_M68K_EXCEPTION_IS_INST(exceptions)) {
    return (0x1c00 | (TME_M68K_EXCEPTION_IS_INST(exceptions) & 0xff));
  }
  return (0x1c0b);
}

/* an FPgen, opclass 000 or 010, once its source operand (if any) is here */
static void
_rd_fpu_gen(struct rd68021_fpu *f)
{
  struct tme_m68k *ic = f->ic;
  unsigned int fmt = (f->command >> 10) & 7;
  tme_uint32_t exc;
  void *op1;
  tme_uint16_t opcode;

  if ((f->command & 0xe000) == 0x4000 && (f->command & 0xfc00) != 0x5c00) {
    /* external to register: the operand as a data register or an immediate */
    switch (fmt) {
    case TME_M6888X_TYPE_BYTE:
      ic->tme_m68k_ireg_uint32(TME_M68K_IREG_D0) = f->buf[0];
      op1 = &ic->tme_m68k_ireg_uint32(TME_M68K_IREG_D0); opcode = 0xf200;
      break;
    case TME_M6888X_TYPE_WORD:
      ic->tme_m68k_ireg_uint32(TME_M68K_IREG_D0) = (f->buf[0] << 8) | f->buf[1];
      op1 = &ic->tme_m68k_ireg_uint32(TME_M68K_IREG_D0); opcode = 0xf200;
      break;
    case TME_M6888X_TYPE_LONG:
    case TME_M6888X_TYPE_SINGLE:
      ic->tme_m68k_ireg_uint32(TME_M68K_IREG_D0) = _rd_fpu_get32(f->buf);
      op1 = &ic->tme_m68k_ireg_uint32(TME_M68K_IREG_D0); opcode = 0xf200;
      break;
    default:
      ic->tme_m68k_ireg_uint32(TME_M68K_IREG_IMM32 + 0) = _rd_fpu_get32(f->buf + 0);
      ic->tme_m68k_ireg_uint32(TME_M68K_IREG_IMM32 + 1) = _rd_fpu_get32(f->buf + 4);
      ic->tme_m68k_ireg_uint32(TME_M68K_IREG_IMM32 + 2) = _rd_fpu_get32(f->buf + 8);
      op1 = &ic->tme_m68k_ireg_uint32(TME_M68K_IREG_IMM32); opcode = 0xf23c;
      break;
    }
  } else {
    /* register to register, and FMOVECR, which is recognised by an <ea> of 0 */
    op1 = &ic->tme_m68k_ireg_uint32(TME_M68K_IREG_D0);
    opcode = 0xf200;
  }
  exc = _rd_fpu_run(f, tme_m68k_fpgen, opcode, f->command, op1);
  f->resp = exc ? _rd_fpu_exception_primitive(exc) : 0x0802;
}

/* FMOVE FPn,<ea>, opclass 011: the result converted, as bytes to go out */
static int
_rd_fpu_move_out(struct rd68021_fpu *f)
{
  struct tme_m68k *ic = f->ic;
  unsigned int fmt = (f->command >> 10) & 7;
  unsigned int n = _rd_fpu_format_len[fmt];
  tme_uint32_t exc;

  rd68021_fpu_capture = TRUE;
  /* an <ea> of (A0): TME refuses D and X to a data register, and the capture
     returns before anything is stored anywhere */
  exc = _rd_fpu_run(f, tme_m68k_fmove_rm, 0xf210, f->command, NULL);
  rd68021_fpu_capture = FALSE;
  if (exc) {
    f->resp = _rd_fpu_exception_primitive(exc);
    return (FALSE);
  }
  switch (n) {
  case 1: f->buf[0] = ic->tme_m68k_ireg_memx32; break;
  case 2: f->buf[0] = ic->tme_m68k_ireg_memx32 >> 8;
          f->buf[1] = ic->tme_m68k_ireg_memx32; break;
  default:
    _rd_fpu_put32(f->buf + 0, ic->tme_m68k_ireg_memx32);
    _rd_fpu_put32(f->buf + 4, ic->tme_m68k_ireg_memy32);
    _rd_fpu_put32(f->buf + 8, ic->tme_m68k_ireg_memz32);
    break;
  }
  f->len = n; f->pos = 0; f->phase = RD_FPU_OUT;
  f->resp = (n <= 4 ? 0xb100 : 0xb200) | n;
  return (TRUE);
}

/* the control registers a command names, FPCR first -- MC68881 UM 4, FMOVEM */
static unsigned int
_rd_fpu_ctl_list(tme_uint16_t command, tme_uint32_t **regs, struct tme_m68k *ic)
{
  unsigned int n = 0;
  if (command & TME_BIT(12)) regs[n++] = &ic->tme_m68k_fpu_fpcr;
  if (command & TME_BIT(11)) regs[n++] = &ic->tme_m68k_fpu_fpsr;
  if (command & TME_BIT(10)) regs[n++] = &ic->tme_m68k_fpu_fpiar;
  if (n == 0) regs[n++] = &ic->tme_m68k_fpu_fpiar;
  return (n);
}

/* FMOVEM's registers in the order they are transferred: with a predecrement
   list, mask bit 7 is FP7 and FP7 goes first, to the highest address; with the
   other, mask bit 7 is FP0 and FP0 goes first -- the same walk as TME's own
   tme_m68k_fmovem, so the memory images agree. */
static void
_rd_fpu_movem_list(struct rd68021_fpu *f, unsigned int mask)
{
  unsigned int first = (f->command & TME_BIT(12)) ? 0 : 7;
  unsigned int bit;
  f->movem_n = 0;
  for (bit = 0; bit < 8; bit++) {
    if (mask & (0x80 >> bit)) {
      f->movem_regs[f->movem_n++] = bit ^ first;
    }
  }
  f->regsel = (tme_uint16_t) ((mask & 0xff) << 8);   /* MC68881 UM 7.2.9 */
}

static void
_rd_fpu_movem_start(struct rd68021_fpu *f)
{
  struct tme_m68k *ic = f->ic;
  const struct tme_float_ieee754_extended80 *x;
  struct tme_float_ieee754_extended80 xb;
  unsigned int k;

  f->pos = 0;
  f->len = 12 * f->movem_n;
  if (f->command & TME_BIT(13)) {
    /* registers out: $A10C */
    for (k = 0; k < f->movem_n; k++) {
      x = tme_ieee754_extended80_value_get(&ic->tme_m68k_fpu_fpreg[f->movem_regs[k]], &xb);
      _rd_fpu_put32(f->buf + 12 * k + 0, (tme_uint32_t) x->tme_float_ieee754_extended80_sexp << 16);
      _rd_fpu_put32(f->buf + 12 * k + 4, x->tme_float_ieee754_extended80_significand.tme_value64_uint32_hi);
      _rd_fpu_put32(f->buf + 12 * k + 8, x->tme_float_ieee754_extended80_significand.tme_value64_uint32_lo);
    }
    f->phase = f->len ? RD_FPU_OUT : RD_FPU_NONE;
    f->resp = 0xa10c;
  } else {
    f->phase = f->len ? RD_FPU_IN : RD_FPU_NONE;
    f->done = RD_FPU_DO_MOVEM;
    f->resp = 0x810c;
  }
}

/* an incoming operand is whole */
static void
_rd_fpu_in_done(struct rd68021_fpu *f)
{
  struct tme_m68k *ic = f->ic;
  tme_uint32_t *regs[3];
  unsigned int n, k;
  struct tme_float *r;

  f->phase = RD_FPU_NONE;
  switch (f->done) {
  case RD_FPU_DO_GEN:
    _rd_fpu_gen(f);
    break;
  case RD_FPU_DO_CTL:
    n = _rd_fpu_ctl_list(f->command, regs, ic);
    for (k = 0; k < n; k++) *regs[k] = _rd_fpu_get32(f->buf + 4 * k);
    f->resp = 0x0802;
    break;
  case RD_FPU_DO_MOVEM:
    for (k = 0; k < f->movem_n; k++) {
      r = &ic->tme_m68k_fpu_fpreg[f->movem_regs[k]];
      r->tme_float_format = TME_FLOAT_FORMAT_IEEE754_EXTENDED80;
      r->tme_float_value_ieee754_extended80.tme_float_ieee754_extended80_sexp
        = _rd_fpu_get32(f->buf + 12 * k) >> 16;
      r->tme_float_value_ieee754_extended80.tme_float_ieee754_extended80_significand.tme_value64_uint32_hi
        = _rd_fpu_get32(f->buf + 12 * k + 4);
      r->tme_float_value_ieee754_extended80.tme_float_ieee754_extended80_significand.tme_value64_uint32_lo
        = _rd_fpu_get32(f->buf + 12 * k + 8);
    }
    f->resp = 0x0802;
    break;
  default:
    f->resp = 0x0802;
    break;
  }
}

/* a command written to the command CIR -- MC68881 UM 7.5.1 */
static void
_rd_fpu_command(struct rd68021_fpu *f, tme_uint16_t command)
{
  struct tme_m68k *ic = f->ic;
  tme_uint32_t *regs[3];
  unsigned int n, k, fmt;

  f->command = command;
  f->used = TRUE;
  f->phase = RD_FPU_NONE;
  switch (command >> 13) {
  case 0:                                         /* register to register */
    _rd_fpu_gen(f);
    break;
  case 2:                                         /* external to register */
    if ((command & 0xfc00) == 0x5c00) {           /* FMOVECR */
      _rd_fpu_gen(f);
      break;
    }
    fmt = (command >> 10) & 7;
    if (fmt == TME_M6888X_TYPE_PACKEDDEC_DK) {
      f->resp = 0x1c0b;
      break;
    }
    f->len = _rd_fpu_format_len[fmt]; f->pos = 0;
    f->phase = RD_FPU_IN; f->done = RD_FPU_DO_GEN;
    f->resp = (f->len <= 4 ? 0x9500 : 0x9600) | f->len;
    break;
  case 3:                                         /* register to external */
    fmt = (command >> 10) & 7;
    if (fmt == TME_M6888X_TYPE_PACKEDDEC || fmt == TME_M6888X_TYPE_PACKEDDEC_DK) {
      f->resp = 0x1c0b;                           /* TME punts on these too */
      break;
    }
    _rd_fpu_move_out(f);
    break;
  case 4:                                         /* control registers in */
    n = _rd_fpu_ctl_list(command, regs, ic);
    f->len = 4 * n; f->pos = 0; f->phase = RD_FPU_IN; f->done = RD_FPU_DO_CTL;
    f->resp = (n == 1 && regs[0] == &ic->tme_m68k_fpu_fpiar) ? 0x9704
            : n == 1 ? 0x9504 : n == 2 ? 0x9608 : 0x960c;
    break;
  case 5:                                         /* control registers out */
    n = _rd_fpu_ctl_list(command, regs, ic);
    for (k = 0; k < n; k++) _rd_fpu_put32(f->buf + 4 * k, *regs[k]);
    f->len = 4 * n; f->pos = 0; f->phase = RD_FPU_OUT;
    f->resp = (n == 1 && regs[0] == &ic->tme_m68k_fpu_fpiar) ? 0xb304
            : n == 1 ? 0xb104 : n == 2 ? 0xb208 : 0xb20c;
    break;
  case 6:                                         /* FMOVEM in */
  case 7:                                         /* FMOVEM out */
    if (command & TME_BIT(11)) {
      /* a dynamic list: the data register first -- $8C0n */
      f->len = 4; f->pos = 0; f->phase = RD_FPU_DREG;
      f->resp = 0x8c00 | ((command >> 4) & 7);
    } else {
      _rd_fpu_movem_list(f, command & 0xff);
      _rd_fpu_movem_start(f);
    }
    break;
  default:                                        /* opclass 001: undefined */
    f->resp = 0x1c0b;
    break;
  }
}

/* one access to an interface register. `data` is right justified: the value
   written, or where the value read goes. Returns FALSE for an access to a
   register this coprocessor does not answer, which the caller terminates with a
   bus error. */
int
rd68021_fpu_cir(struct rd68021_fpu *f, int read, unsigned int off,
                unsigned int nbytes, tme_uint32_t *data)
{
  struct tme_m68k *ic = f->ic;
  tme_uint32_t v = 0;
  tme_uint32_t exc;
  unsigned int k;
  int t;

  switch (off) {
  case 0x00:                                      /* response */
    if (!read) return (FALSE);
    v = f->resp;
    /* MC68881 UM 7.5.1.2: reading the primitive that asks for an operand turns
       the response into the null come-again one until the operand is moved --
       and a come-again primitive with nothing left to move (an FMOVEM of an
       empty list) is followed by the release, or it would be read forever. */
    if (f->phase != RD_FPU_NONE) f->resp = 0x8900;
    else if ((v & 0x8000) && v != 0x8900) f->resp = 0x0802;
    break;
  case 0x02:                                      /* control: abort, acknowledge */
    if (read) return (FALSE);
    f->phase = RD_FPU_NONE;
    f->resp = 0x0802;
    break;
  case 0x04:                                      /* save */
    if (!read) return (FALSE);
    if (!f->used) {
      v = 0x0000;                                 /* null */
    } else {
      v = RD_FPU_IDLE_FORMAT;
      memset(f->buf, 0, 24);
      f->len = 24; f->pos = 0; f->phase = RD_FPU_OUT;
    }
    f->resp = 0x0802;
    break;
  case 0x06:                                      /* restore */
    if (read) {
      v = f->rest;
      break;
    }
    v = *data & 0xffff;
    if ((v >> 8) == 0x00) {                       /* null: reset */
      tme_m68k_fpu_reset(ic);
      f->used = FALSE;
      f->rest = v;
      f->phase = RD_FPU_NONE;
    } else if (v == RD_FPU_IDLE_FORMAT) {
      f->rest = v;
      f->used = TRUE;
      f->len = 24; f->pos = 0; f->phase = RD_FPU_IN; f->done = RD_FPU_DO_NOTHING;
    } else {
      f->rest = 0x0200;                           /* invalid */
      f->phase = RD_FPU_NONE;
    }
    f->resp = 0x0802;
    break;
  case 0x0a:                                      /* command */
    if (read) return (FALSE);
    _rd_fpu_command(f, *data & 0xffff);
    break;
  case 0x0e:                                      /* condition */
    if (read) return (FALSE);
    f->used = TRUE;
    f->phase = RD_FPU_NONE;
    ic->_tme_m68k_exceptions = 0;
    if (setjmp(ic->_tme_m68k_dispatcher)) {
      exc = ic->_tme_m68k_exceptions;
      f->resp = _rd_fpu_exception_primitive(exc ? exc : TME_M68K_EXCEPTION_ILL);
      break;
    }
    t = _tme_m6888x_predicate_true(ic, *data & 0x3f);
    f->resp = 0x0800 | (t ? 1 : 0);
    break;
  case 0x14:                                      /* register select */
    if (!read) return (FALSE);
    v = f->regsel;
    break;
  case 0x18:                                      /* instruction address */
    if (read) v = 0xffffffff;
    else ic->tme_m68k_fpu_fpiar = *data;
    break;
  case 0x08:                                      /* operation word */
  case 0x1c:                                      /* operand address */
    if (read) v = 0xffffffff;
    break;
  default:
    if (off < 0x10 || off > 0x13) return (FALSE);
    /* the operand CIR: bytes aligned to its most significant end -- UM 7.3.8 */
    if (read) {
      for (k = 0; k < nbytes; k++) {
        v = (v << 8) | (f->phase == RD_FPU_OUT && f->pos < f->len ? f->buf[f->pos++] : 0);
      }
      if (f->phase == RD_FPU_OUT && f->pos >= f->len) {
        f->phase = RD_FPU_NONE;
        f->resp = 0x0802;
      }
    } else if (f->phase == RD_FPU_DREG) {
      /* the dynamic FMOVEM list, from the data register's low byte */
      _rd_fpu_movem_list(f, *data & 0xff);
      _rd_fpu_movem_start(f);
    } else if (f->phase == RD_FPU_IN) {
      for (k = 0; k < nbytes && f->pos < f->len; k++) {
        f->buf[f->pos++] = *data >> (8 * (nbytes - 1 - k));
      }
      if (f->pos >= f->len) _rd_fpu_in_done(f);
    }
    break;
  }
  if (read) *data = v;
  return (TRUE);
}
