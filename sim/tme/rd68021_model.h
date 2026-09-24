/* RD68021 -- the C interface to the Verilator model: sim/tme/rd68021_model.cpp. */
#ifndef RD68021_MODEL_H
#define RD68021_MODEL_H
#ifdef __cplusplus
extern "C" {
#endif
struct rdm;
struct rdm *rdm_new(void);
void rdm_rising(struct rdm *);
void rdm_falling(struct rdm *);
unsigned long long rdm_clocks(const struct rdm *);
void rdm_set_rst_n(struct rdm *, int);
void rdm_set_d(struct rdm *, unsigned);
void rdm_set_dsack_n(struct rdm *, unsigned);
void rdm_set_berr_n(struct rdm *, int);
void rdm_set_avec_n(struct rdm *, int);
void rdm_set_ipl_n(struct rdm *, unsigned);
void rdm_set_halt_n(struct rdm *, int);
int rdm_as_n(const struct rdm *);
int rdm_ds_n(const struct rdm *);
int rdm_rw(const struct rdm *);
int rdm_rmc_n(const struct rdm *);
unsigned rdm_fc(const struct rdm *);
unsigned rdm_addr(const struct rdm *);
unsigned rdm_siz(const struct rdm *);
unsigned rdm_dout(const struct rdm *);
int rdm_reset_out(const struct rdm *);
int rdm_halt_out(const struct rdm *);
unsigned rdm_pc(const struct rdm *);
#ifdef __cplusplus
}
#endif
#endif
