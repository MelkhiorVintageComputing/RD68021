// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 -- the Verilator model of the core, behind a C interface, for the TME
// element in sim/tme/rd68021.c.
//
// TME is C and runs its elements as cooperative threads that leave by longjmp.
// Nothing may longjmp across a C++ frame, so everything here is a short call
// that returns: a half clock, or a pin read or written. The bus protocol --
// which edge answers what -- is the element's business, not this file's.

#include "Vrd68021_top.h"
#include "verilated.h"
#include "Vrd68021_top___024root.h"
#include "rd68021_model.h"

struct rdm {
  VerilatedContext *ctx;
  Vrd68021_top     *top;
  unsigned long long clocks;
};

extern "C" {

struct rdm *rdm_new(void) {
  struct rdm *m = new rdm;
  m->ctx = new VerilatedContext;
  m->top = new Vrd68021_top{m->ctx};
  m->clocks = 0;
  Vrd68021_top *t = m->top;
  // Everything idle: no bus master wants the bus, no interrupt, no halt, no
  // reset from outside, the cache allowed.
  t->clk = 0;
  t->rst_n = 0;
  t->d_i = 0;
  t->dsack_n_i = 3;
  t->ipl_n_i = 7;
  t->avec_n_i = 1;
  t->br_n_i = 1;
  t->bgack_n_i = 1;
  t->berr_n_i = 1;
  t->reset_n_i = 1;
  t->halt_n_i = 1;
  t->cdis_n_i = 1;
  t->eval();
  return m;
}

void rdm_rising(struct rdm *m)  { m->top->clk = 1; m->top->eval(); m->clocks++; }
void rdm_falling(struct rdm *m) { m->top->clk = 0; m->top->eval(); }
unsigned long long rdm_clocks(const struct rdm *m) { return m->clocks; }

void rdm_set_rst_n(struct rdm *m, int v)       { m->top->rst_n = v; m->top->eval(); }
void rdm_set_d(struct rdm *m, unsigned v)      { m->top->d_i = v; }
void rdm_set_dsack_n(struct rdm *m, unsigned v){ m->top->dsack_n_i = v; }
void rdm_set_berr_n(struct rdm *m, int v)      { m->top->berr_n_i = v; }
void rdm_set_avec_n(struct rdm *m, int v)      { m->top->avec_n_i = v; }
void rdm_set_ipl_n(struct rdm *m, unsigned v)  { m->top->ipl_n_i = v; }
void rdm_set_halt_n(struct rdm *m, int v)      { m->top->halt_n_i = v; }

int      rdm_as_n(const struct rdm *m)   { return m->top->as_n_o; }
int      rdm_ds_n(const struct rdm *m)   { return m->top->ds_n_o; }
int      rdm_rw(const struct rdm *m)     { return m->top->rw_o; }
int      rdm_rmc_n(const struct rdm *m)  { return m->top->rmc_n_o; }
unsigned rdm_fc(const struct rdm *m)     { return m->top->fc_o; }
unsigned rdm_addr(const struct rdm *m)   { return m->top->a_o; }
unsigned rdm_siz(const struct rdm *m)    { return m->top->siz_o; }
unsigned rdm_dout(const struct rdm *m)   { return m->top->d_o; }
int      rdm_reset_out(const struct rdm *m) { return m->top->reset_n_oe; }
int      rdm_halt_out(const struct rdm *m)  { return m->top->halt_n_oe; }
unsigned rdm_d0(const struct rdm *m) {
  return m->top->rootp->rd68021_top__DOT__u_seq__DOT__dreg[0];
}
unsigned rdm_sr(const struct rdm *m) {
  return m->top->rootp->rd68021_top__DOT__u_seq__DOT__sr_q;
}
unsigned rdm_d1(const struct rdm *m) {
  return m->top->rootp->rd68021_top__DOT__u_seq__DOT__dreg[1];
}
unsigned rdm_usp(const struct rdm *m) {
  return m->top->rootp->rd68021_top__DOT__u_seq__DOT__usp_q;
}
unsigned rdm_vbr(const struct rdm *m) {
  return m->top->rootp->rd68021_top__DOT__u_seq__DOT__vbr_q;
}
unsigned rdm_pc(const struct rdm *m) {
  return m->top->rootp->rd68021_top__DOT__u_ifu__DOT__pc_d_q;
}

}
