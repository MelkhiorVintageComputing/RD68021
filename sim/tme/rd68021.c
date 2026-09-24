/* RD68021 -- the RTL core as the CPU of a TME machine.
 *
 * TME (The Machine Emulator, Inputs/ref/Run-Sun3-SunOS-4.1.1/tme-0.8_up) builds
 * a machine out of elements joined by bus connections, and its CPUs are
 * elements like any other: `cpu0 at mainbus0: tme/ic/m68020` in a machine
 * description. This is a CPU element whose CPU is the Verilator model of
 * rtl/rd68021_top.sv. It offers the board exactly the connection TME's own
 * m68020 offers, so the board -- the Sun-3's MMU, its control space, its
 * interrupt logic, its memories and devices -- cannot tell them apart.
 *
 * The core is clocked a half period at a time, and every bus cycle it runs is
 * answered here on the rising edge after it asserts AS, as the testbenches'
 * memory models answer it (sim/models/rd68021_slave.sv):
 *
 *   - an ordinary cycle is looked up through the board's TLB filler by function
 *     code and address -- the Sun-3 MMU lives behind that call -- and then
 *     either read or written straight from emulator memory or run as a TME bus
 *     cycle through the device's cycle function, with TME's own MC68020 byte
 *     lane router (UM table 5-5). How many bytes the responder took is turned
 *     back into the DSACK encoding that says so, and a fault into BERR;
 *   - an interrupt acknowledge (CPU space type $F) asks the board for the
 *     vector: a vector comes back on an eight-bit port, "use the autovector" as
 *     AVEC, and no interrupt at all as BERR, which the core takes as spurious;
 *   - every other CPU-space cycle -- breakpoint, access level, coprocessor -- is
 *     answered with BERR: there is nothing there on a Sun-3 without an FPU.
 *
 * TME's threads are cooperative and leave by longjmp (libtme/threads-sjlj.c),
 * and a thread's function is called afresh on every dispatch. So the thread
 * below is a restartable burst -- run so many clocks, yield -- with all of its
 * state here in the element, and the Verilator model is only ever called
 * through functions that return (sim/tme/rd68021_model.cpp).
 *
 * Written from TME's interface headers and from the connection plumbing of its
 * m68k element; the RD68021 rule on reference implementations is about the
 * RTL, and nothing here is.
 */

#include <tme/common.h>
#include <tme/element.h>
#include <tme/threads.h>
#include <tme/generic/bus.h>
#include <tme/ic/m68k.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>
#include "rd68021_model.h"

/* clocks run per dispatch before yielding to TME's other threads: */
#define RD_BURST (2000)

struct rd68021 {
  struct tme_element *element;

  /* the board's side of our connection: */
  struct tme_m68k_bus_connection *bus;

  /* our TLB entries: 64 for program space and 64 for everything else, by
     address. They must be long-lived, as TME's own m68k's are, and not one
     entry refilled for every cycle: the Sun-3 board's memory parity test
     follows the one data entry involved in it and aborts if any other entry is
     filled meanwhile -- an instruction fetch included. */
#define RD_TLBS (64)
  struct tme_m68k_tlb tlbs[2 * RD_TLBS];
  tme_bus_context_t bus_context;

  /* the external signals, set by the board's calls into us: */
  tme_mutex_t mutex;
  tme_cond_t cond;
  unsigned int ipl;
  int reset_asserted;      /* RESET held by the board */
  int reset_release;       /* RESET let go: run the core out of reset */
  int running;             /* the core has been let out of reset */
  int driving_reset;       /* the core's own RESET instruction is running */

  /* the core: */
  struct rdm *m;
  int answered;            /* this AS assertion has been answered */
  int halted;              /* HALT out: a double bus fault */

  /* statistics: */
  unsigned long long cycles, faults, next_report;
  unsigned long long log_full;
  unsigned long fc3_logged, ipl_logged;
  /* per interrupt level: how often the board raised it, and how the core's
     acknowledges were answered. */
  unsigned long ipl_raised[8], iack_vec[8], iack_avec[8], iack_spur[8];
  /* RD68021_LOG_FROM / RD68021_LOG_TO: every cycle in that clock window. */
  unsigned long long win_from, win_to, stop_at;
  /* RD68021_LOG_ADDR=lo:hi -- every cycle to that range, the first 20000. */
  tme_uint32_t addr_lo, addr_hi;
  unsigned long addr_logged;
  /* RD68021_LOG_DEV_FROM: every device (non-memory) cycle from this clock. */
  unsigned long long dev_from;
  int syscalls;
  /* RD68021_FAULTS: every bus error, and what became of it -- the first cycle
     to the same address afterwards, which is the handler's RTE rerunning it. */
  int faults_log;
  int fault_pending;
  unsigned long long fault_clock;
  tme_uint32_t fault_addr, fault_pc, fault_data;
  unsigned char fault_fc, fault_rw, fault_siz;
  unsigned long syscall_n;
  long ut_from, ut_to;          /* RD68021_UTRACE=from:to */
  tme_uint32_t ut_pc;
  unsigned long dev_logged;

  /* the last RD_RING bus cycles, dumped to the log when the core halts: what
     led to a double bus fault is otherwise gone by the time anyone looks, and
     TME's clock runs on host time, so no two runs halt at the same clock. */
#define RD_RING (4096)
  struct {
    unsigned long long clock;
    tme_uint32_t pc, addr, data;
    unsigned char fc, siz, rw;
    const char *what;
    unsigned int port;
  } ring[RD_RING];
  unsigned int ring_at;
  /* RD68021_DUMP_AT: dump the ring at this clock and carry on. */
  unsigned long long dump_at;

  /* the program counter over the whole address space, by 16-byte line, in an
     open-addressed table: where a kernel or a user program spends its time. */
#define RD_PCH (1 << 16)
  tme_uint32_t pch_line[RD_PCH];
  unsigned long pch_count[RD_PCH];
  /* RD68021_STOP_PC: stop once the program counter has been here this many
     times -- the monitor's character input at its prompt, for `make sun3`. */
  unsigned long stop_pc, stop_pc_hits;
  FILE *log;

  /* where the time goes: the program counter sampled every 64 clocks, by
     16-byte line within the PROM, so that the delay loops worth patching out
     can be found. The instruction cache hides fetches, so the bus cannot. */
  unsigned long prom_hist[65536 / 16];
};

/* ------------------------------------------------------------------------ */
/* The board's calls into us                                                */
/* ------------------------------------------------------------------------ */

static int
_rd_bus_signal(struct tme_bus_connection *conn_bus, unsigned int signal)
{
  struct rd68021 *rd;
  unsigned int level;

  rd = conn_bus->tme_bus_connection.tme_connection_element->tme_element_private;
  level = signal & TME_BUS_SIGNAL_LEVEL_MASK;
  signal = TME_BUS_SIGNAL_WHICH(signal);

  tme_mutex_lock(&rd->mutex);
  if (signal == TME_BUS_SIGNAL_RESET && !rd->driving_reset) {
    if (level == TME_BUS_SIGNAL_LEVEL_ASSERTED) {
      rd->reset_asserted = TRUE;
    } else if (level == TME_BUS_SIGNAL_LEVEL_NEGATED) {
      rd->reset_asserted = FALSE;
      rd->reset_release = TRUE;
    }
  }
  /* HALT from the board, and anything else, is ignored: the Sun-3 does not
     use HALT as an input, and nothing else is signalled to a CPU. */
  tme_mutex_unlock(&rd->mutex);
  tme_cond_notify(&rd->cond, TRUE);
  return (TME_OK);
}

static int
_rd_bus_interrupt(struct tme_m68k_bus_connection *conn_m68k, unsigned int ipl)
{
  struct rd68021 *rd;

  rd = conn_m68k->tme_m68k_bus_connection.tme_bus_connection.tme_connection_element->tme_element_private;
  tme_mutex_lock(&rd->mutex);
  if (rd->log && ipl != rd->ipl && rd->ipl_logged++ < 200) {
    fprintf(rd->log, "%10llu ipl %u -> %u\n", rdm_clocks(rd->m), rd->ipl, ipl);
  }
  if (ipl > rd->ipl) rd->ipl_raised[ipl & 7]++;
  rd->ipl = ipl;
  tme_mutex_unlock(&rd->mutex);
  tme_cond_notify(&rd->cond, TRUE);
  return (TME_OK);
}

/* there is no FPU on this core until the coprocessor interface is built: */
static int
_rd_m6888x_enable(struct tme_m68k_bus_connection *conn_m68k, int enabled)
{
  return (ENXIO);
}

/* ------------------------------------------------------------------------ */
/* Bus cycles                                                               */
/* ------------------------------------------------------------------------ */

/* SIZ1/SIZ0 to a byte count, UM table 5-2: */
static unsigned int
_rd_siz_bytes(unsigned int siz)
{
  return (siz == 0 ? 4 : siz);
}

/* the DSACK1/DSACK0 encoding, active low, for a port of `port` bytes: */
static unsigned int
_rd_dsack(unsigned int port)
{
  return (port == 4 ? 0 : (port == 2 ? 1 : 2));
}

/* the port size whose table 5-6 behaviour moves exactly `moved` of `resid`
   bytes at `addr` -- the widest one, where more than one would: */
static unsigned int
_rd_port_for(tme_uint32_t addr, unsigned int resid, unsigned int moved)
{
  unsigned int port, room;

  for (port = 4; port >= 1; port >>= 1) {
    room = port - (addr % port);
    if (TME_MIN(resid, room) == moved) {
      return (port);
    }
  }
  return (0);
}

/* the TLB entry for this function code and address: */
static struct tme_m68k_tlb *
_rd_tlb_for(struct rd68021 *rd, unsigned int fc, tme_uint32_t addr)
{
  unsigned int prog;

  prog = (fc == 2 || fc == 6);
  return (&rd->tlbs[prog * RD_TLBS + ((addr >> 12) % RD_TLBS)]);
}

/* does this entry cover this access? The test TME's own m68k makes: valid,
   for this bus context and function code, over this address, and either a
   fast memory pointer for this direction or this cycle type allowed. */
static int
_rd_tlb_covers(const struct rd68021 *rd, struct tme_m68k_tlb *tlb,
               unsigned int fc, tme_uint32_t addr, unsigned int cycle)
{
  return (!tme_m68k_tlb_is_invalid(tlb)
          && tlb->tme_m68k_tlb_bus_context == rd->bus_context
          && (tlb->tme_m68k_tlb_function_codes_mask & TME_BIT(fc)) != 0
          && addr >= (tme_bus_addr32_t) tlb->tme_m68k_tlb_linear_first
          && addr <= (tme_bus_addr32_t) tlb->tme_m68k_tlb_linear_last
          && (((cycle == TME_BUS_CYCLE_READ
                ? tlb->tme_m68k_tlb_emulator_off_read
                : tlb->tme_m68k_tlb_emulator_off_write) != TME_EMULATOR_OFF_UNDEF)
              || (tlb->tme_m68k_tlb_cycles_ok & cycle) != 0));
}

/* make that entry cover this access, filling it if it does not, and return
   nonzero if it then does. An entry the board fills that still does not
   cover the access is a bus error: nothing is mapped there that allows it. */
static int
_rd_tlb_fill(struct rd68021 *rd, struct tme_m68k_tlb *tlb, unsigned int fc,
             tme_uint32_t addr, unsigned int cycle)
{
  if (_rd_tlb_covers(rd, tlb, fc, addr, cycle)) {
    return (TRUE);
  }
  tme_m68k_tlb_unbusy(tlb);
  tme_token_invalid_clear(&tlb->tme_m68k_tlb_token);
  (*rd->bus->tme_m68k_bus_tlb_fill)(rd->bus, tlb, fc, addr, cycle);
  tlb->tme_m68k_tlb_bus_context = rd->bus_context;
  tme_m68k_tlb_busy(tlb);
  return (_rd_tlb_covers(rd, tlb, fc, addr, cycle));
}

static void _rd_log_cycle(struct rd68021 *, const char *, unsigned int, tme_uint32_t);

/* answer the bus cycle the core is running now: */
static void
_rd_answer(struct rd68021 *rd)
{
  struct rdm *m;
  struct tme_m68k_tlb *tlb;
  struct tme_bus_cycle cycle;
  tme_uint8_t buf[4];
  unsigned int fc, siz, resid, size, moved, port, k, lane, type, level;
  tme_uint32_t addr, dout, din = 0, physical;
  tme_shared tme_uint8_t *mem;
  int rw, err, vector, rc, shift;

  m = rd->m;
  fc = rdm_fc(m);
  addr = rdm_addr(m);
  siz = rdm_siz(m);
  rw = rdm_rw(m);
  rd->cycles++;

  /* RD68021_SYSCALLS: a line for every TRAP #0 -- the read of its vector,
     VBR + $80 -- with the call number SunOS puts in D0. */
  if (fc == 5 && rw && addr == rdm_vbr(m) + 0x80) {
    rd->syscall_n++;
  }
  if (rd->syscalls && fc == 5 && rw && addr == rdm_vbr(m) + 0x80 && rd->log) {
    tme_uint32_t sp = rdm_usp(m), w[3] = {0, 0, 0};
    unsigned int k, j;
    /* the top of the user stack, through the board's TLB: an indirect call
       has its number there. */
    for (k = 0; k < 3; k++) {
      struct tme_m68k_tlb *t = _rd_tlb_for(rd, 1, sp + 4 * k);
      tme_mutex_unlock(&rd->mutex);
      if (_rd_tlb_fill(rd, t, 1, sp + 4 * k, TME_BUS_CYCLE_READ)
          && t->tme_m68k_tlb_emulator_off_read != TME_EMULATOR_OFF_UNDEF) {
        const tme_shared tme_uint8_t *p = t->tme_m68k_tlb_emulator_off_read + sp + 4 * k;
        for (j = 0; j < 4; j++) w[k] = (w[k] << 8) | p[j];
      }
      tme_mutex_lock(&rd->mutex);
    }
    fprintf(rd->log, "SYSCALL %10llu d0 %lu pc %08lx usp %08lx: %08lx %08lx %08lx\n",
            rdm_clocks(m), (unsigned long) rdm_d0(m), (unsigned long) rdm_pc(m),
            (unsigned long) sp, (unsigned long) w[0], (unsigned long) w[1], (unsigned long) w[2]);
  }

  /* CPU space: UM figure 5-31. */
  if (fc == 7) {
    type = (addr >> 16) & 0xf;
    if (type == 0xf) {
      level = (addr >> 1) & 7;
      tme_mutex_unlock(&rd->mutex);
      rc = (*rd->bus->tme_m68k_bus_connection.tme_bus_intack)
        (&rd->bus->tme_m68k_bus_connection, level, &vector);
      tme_mutex_lock(&rd->mutex);
      if (rc == ENOENT) {
        rdm_set_berr_n(m, 0);                  /* spurious */
        rd->iack_spur[level]++;
        _rd_log_cycle(rd, "IACK-SPURIOUS", level, 0);
      } else if (vector == TME_BUS_INTERRUPT_VECTOR_UNDEF) {
        rdm_set_avec_n(m, 0);                  /* autovector */
        rd->iack_avec[level]++;
        _rd_log_cycle(rd, "IACK-AVEC", level, 0);
      } else {
        rdm_set_d(m, ((tme_uint32_t) (vector & 0xff)) << 24);
        rdm_set_dsack_n(m, _rd_dsack(1));      /* an eight-bit port */
        rd->iack_vec[level]++;
        _rd_log_cycle(rd, "IACK-VECTOR", level, vector);
      }
    } else {
      rdm_set_berr_n(m, 0);
      _rd_log_cycle(rd, "CPU-SPACE-BERR", type, 0);
    }
    return;
  }

  /* the bytes this cycle can move on a 32-bit port: */
  resid = _rd_siz_bytes(siz);
  size = TME_MIN(resid, 4 - (addr & 3));
  type = rw ? TME_BUS_CYCLE_READ : TME_BUS_CYCLE_WRITE;

  /* on a write, the operand's bytes in address order, from the lanes UM
     table 5-5 puts them on for a 32-bit port: the byte for address a+k is on
     lane (a+k) mod 4, counting D31-D24 as lane 0. */
  if (!rw) {
    dout = rdm_dout(m);
    for (k = 0; k < size; k++) {
      lane = (addr + k) & 3;
      buf[k] = (dout >> (24 - 8 * lane)) & 0xff;
    }
  }

  tlb = _rd_tlb_for(rd, fc, addr);
  tme_mutex_unlock(&rd->mutex);
  if (!_rd_tlb_fill(rd, tlb, fc, addr, type)) {
    tme_mutex_lock(&rd->mutex);
    rd->faults++;
    rdm_set_berr_n(m, 0);
    _rd_log_cycle(rd, "BERR-TLB", 0, 0);
    return;
  }

  mem = (tme_shared tme_uint8_t *)
    (rw ? tlb->tme_m68k_tlb_emulator_off_read : tlb->tme_m68k_tlb_emulator_off_write);
  if (mem != TME_EMULATOR_OFF_UNDEF) {

    /* plain memory: the whole of the cycle, as a 32-bit port would take it,
       limited to what the TLB entry covers: */
    if (size - 1 > (tme_bus_addr32_t) tlb->tme_m68k_tlb_linear_last - addr) {
      size = (tme_bus_addr32_t) tlb->tme_m68k_tlb_linear_last - addr + 1;
    }
    for (k = 0; k < size; k++) {
      if (rw) {
        buf[k] = mem[addr + k];
      } else {
        mem[addr + k] = buf[k];
      }
    }
    moved = size;
  }
  else if ((tlb->tme_m68k_tlb_cycles_ok & type) == 0) {
    tme_mutex_lock(&rd->mutex);
    rd->faults++;
    rdm_set_berr_n(m, 0);
    _rd_log_cycle(rd, "BERR-NOCYCLE", 0, 0);
    return;
  }
  else {

    /* a device: a TME bus cycle, routed as TME's own MC68020 routes it. */
    memset(&cycle, 0, sizeof(cycle));
    cycle.tme_bus_cycle_type = type;
    cycle.tme_bus_cycle_buffer = &buf[0];
    cycle.tme_bus_cycle_buffer_increment = 1;
    cycle.tme_bus_cycle_size = size;
    cycle.tme_bus_cycle_port = TME_BUS_CYCLE_PORT(0, TME_BUS32_LOG2);
    cycle.tme_bus_cycle_lane_routing
      = &tme_m68k_router_32[TME_M68K_BUS_ROUTER_INDEX(TME_BUS32_LOG2, size, addr)];
    physical = tlb->tme_m68k_tlb_addr_offset + addr;
    shift = tlb->tme_m68k_tlb_addr_shift;
    if (shift < 0) {
      physical <<= (0 - shift);
    } else if (shift > 0) {
      physical >>= shift;
    }
    cycle.tme_bus_cycle_address = physical;

    tme_m68k_tlb_unbusy(tlb);
    err = (*tlb->tme_m68k_tlb_bus_tlb.tme_bus_tlb_cycle)
      (tlb->tme_m68k_tlb_bus_tlb.tme_bus_tlb_cycle_private, &cycle);
    tme_m68k_tlb_busy(tlb);

    if (err != TME_OK && err != TME_BUS_CYCLE_SYNCHRONOUS_EVENT
        && !(err == EBADF && tme_m68k_tlb_is_invalid(tlb))) {
      err = tme_bus_tlb_fault(&tlb->tme_m68k_tlb_bus_tlb, &cycle, err);
      if (err != TME_OK) {
        tme_mutex_lock(&rd->mutex);
        rd->faults++;
        rdm_set_berr_n(m, 0);
        _rd_log_cycle(rd, "BERR-FAULT", err, 0);
        return;
      }
    }
    moved = cycle.tme_bus_cycle_size;
  }
  tme_mutex_lock(&rd->mutex);

  /* nothing moved: the TLB entry was invalidated under us. Leave the cycle
     unanswered and try again on the next clock. */
  if (moved == 0) {
    rd->answered = FALSE;
    return;
  }

  /* the port whose dynamic sizing moves exactly that much: */
  port = _rd_port_for(addr, resid, moved);
  if (port == 0) {
    fprintf(stderr, "rd68021: %u of %u bytes at %08lx fits no port\n",
            moved, resid, (unsigned long) addr);
    abort();
  }

  /* a read's bytes go on the lanes that port uses: the port's own offset,
     from D31-D24 (UM table 5-4). */
  if (rw) {
    din = 0;
    for (k = 0; k < moved; k++) {
      lane = (addr % port) + k;
      din |= ((tme_uint32_t) buf[k]) << (24 - 8 * lane);
    }
    rdm_set_d(m, din);
  }
  rdm_set_dsack_n(m, _rd_dsack(port));
  _rd_log_cycle(rd, mem != TME_EMULATOR_OFF_UNDEF ? "MEM" : "DEV", port,
                rw ? din : rdm_dout(m));
}

/* the bus log: every cycle for the first `log_full`, then one line a
   million clocks. */
static void
_rd_log_cycle(struct rd68021 *rd, const char *what, unsigned int port,
              tme_uint32_t data)
{
  {
    unsigned int k = rd->ring_at++ % RD_RING;
    rd->ring[k].clock = rdm_clocks(rd->m);
    rd->ring[k].pc = rdm_pc(rd->m);
    rd->ring[k].fc = rdm_fc(rd->m);
    rd->ring[k].addr = rdm_addr(rd->m);
    rd->ring[k].siz = rdm_siz(rd->m);
    rd->ring[k].rw = rdm_rw(rd->m);
    rd->ring[k].data = data;
    rd->ring[k].what = what;
    rd->ring[k].port = port;
  }
  if (rd->faults_log && rd->log) {
    int berr = (strncmp(what, "BERR", 4) == 0);
    tme_uint32_t a = rdm_addr(rd->m);
    if (rd->fault_pending && a == rd->fault_addr && rdm_fc(rd->m) == rd->fault_fc) {
      fprintf(rd->log, "  -> %s %llu clocks later: pc %08lx fc%u %08lx siz%u %c %08lx %s\n",
              berr ? "FAULTED AGAIN" : "retried", rdm_clocks(rd->m) - rd->fault_clock,
              (unsigned long) rdm_pc(rd->m), rdm_fc(rd->m), (unsigned long) a,
              rdm_siz(rd->m), rdm_rw(rd->m) ? 'R' : 'W', (unsigned long) data, what);
      rd->fault_pending = 0;
    }
    if (berr) {
      if (rd->fault_pending) {
        fprintf(rd->log, "  -> never retried\n");
      }
      fprintf(rd->log, "FAULT %llu pc %08lx fc%u %08lx siz%u %c %08lx sr %04x %s\n",
              rdm_clocks(rd->m), (unsigned long) rdm_pc(rd->m), rdm_fc(rd->m),
              (unsigned long) a, rdm_siz(rd->m), rdm_rw(rd->m) ? 'R' : 'W',
              (unsigned long) (rdm_rw(rd->m) ? 0 : rdm_dout(rd->m)), rdm_sr(rd->m), what);
      rd->fault_pending = 1;
      rd->fault_clock = rdm_clocks(rd->m);
      rd->fault_addr = a;
      rd->fault_fc = rdm_fc(rd->m);
    }
  }
  if (rd->log == NULL) {
    return;
  }
  if (rd->cycles <= rd->log_full
      || (strncmp(what, "MEM", 3) && strncmp(what, "DEV", 3) && rd->fc3_logged++ < 400)
      || (rdm_clocks(rd->m) >= rd->win_from && rdm_clocks(rd->m) < rd->win_to)
      || (rd->dev_from && rdm_clocks(rd->m) >= rd->dev_from && strncmp(what, "MEM", 3)
          && (rdm_pc(rd->m) & 0xffff0000) != 0x0fef0000
          && rd->dev_logged++ < 50000)
      || (rd->addr_hi && rdm_addr(rd->m) >= rd->addr_lo && rdm_addr(rd->m) <= rd->addr_hi
          && rd->addr_logged++ < 20000)) {
    fprintf(rd->log, "%10llu pc %08lx fc%u %08lx siz%u %c %08lx %s%u\n",
            rdm_clocks(rd->m), (unsigned long) rdm_pc(rd->m),
            rdm_fc(rd->m), (unsigned long) rdm_addr(rd->m),
            rdm_siz(rd->m), rdm_rw(rd->m) ? 'R' : 'W', (unsigned long) data,
            what, port);
  }
}

static void
_rd_dump_ring(struct rd68021 *rd, const char *why)
{
  unsigned int k, n;

  if (rd->log == NULL) {
    return;
  }
  fprintf(rd->log, "rd68021: %s -- the last %u bus cycles:\n", why, RD_RING);
  for (n = 0; n < RD_RING; n++) {
    k = (rd->ring_at + n) % RD_RING;
    if (rd->ring[k].what == NULL) continue;
    fprintf(rd->log, "R %10llu pc %08lx fc%u %08lx siz%u %c %08lx %s%u\n",
            rd->ring[k].clock, (unsigned long) rd->ring[k].pc,
            rd->ring[k].fc, (unsigned long) rd->ring[k].addr,
            rd->ring[k].siz, rd->ring[k].rw ? 'R' : 'W',
            (unsigned long) rd->ring[k].data, rd->ring[k].what,
            rd->ring[k].port);
  }
  fflush(rd->log);
}

/* let go of everything the last answer drove: */
static void
_rd_release(struct rd68021 *rd)
{
  rdm_set_dsack_n(rd->m, 3);
  rdm_set_berr_n(rd->m, 1);
  rdm_set_avec_n(rd->m, 1);
  rdm_set_d(rd->m, 0);
}

/* one clock of the core, with the bus answered: */
static void
_rd_clock(struct rd68021 *rd)
{
  struct rdm *m;
  tme_uint32_t pc;

  m = rd->m;
  if ((rdm_clocks(m) & 63) == 0) {
    pc = rdm_pc(m);
    if (rd->stop_pc && (pc & ~0xfUL) == (rd->stop_pc & ~0xfUL)
        && ++rd->stop_pc_hits == 1000 && rd->stop_at == 0) {
      rd->stop_at = rdm_clocks(m);
    }
    if ((pc & 0xffff0000) == 0x0fef0000) {
      rd->prom_hist[(pc & 0xffff) >> 4]++;
    }
    {
      tme_uint32_t line = (pc >> 4) | 1;       /* never zero: zero is empty */
      unsigned int h = (line * 2654435761u) >> 16, probe;
      for (probe = 0; probe < 64; probe++, h = (h + 1) & (RD_PCH - 1)) {
        if (rd->pch_line[h] == line) { rd->pch_count[h]++; break; }
        if (rd->pch_line[h] == 0) { rd->pch_line[h] = line; rd->pch_count[h] = 1; break; }
      }
    }
    if (rd->dump_at && rdm_clocks(m) >= rd->dump_at) {
      rd->dump_at = 0;
      _rd_dump_ring(rd, "RD68021_DUMP_AT");
    }
  }

  /* the interrupt level, sampled by the core's own synchronisers: */
  rdm_set_ipl_n(m, (~rd->ipl) & 7);

  rdm_rising(m);
  if (!rdm_as_n(m)) {
    if (!rd->answered) {
      rd->answered = TRUE;
      _rd_answer(rd);
    }
  } else if (rd->answered) {
    rd->answered = FALSE;
    _rd_release(rd);
  }

  rdm_falling(m);
  /* RD68021_UTRACE: every user-mode instruction between two system calls, as
     TME's own m68k prints them -- the program counter as stage D moves on. */
  if (rd->ut_from >= 0 && (long) rd->syscall_n >= rd->ut_from
      && (long) rd->syscall_n < rd->ut_to && !(rdm_sr(m) & 0x2000)
      && rdm_pc(m) != rd->ut_pc && rd->log) {
    rd->ut_pc = rdm_pc(m);
    fprintf(rd->log, "U %08lx d0 %08lx d1 %08lx sr %04x\n", (unsigned long) rd->ut_pc,
            (unsigned long) rdm_d0(m), (unsigned long) rdm_d1(m), rdm_sr(m));
  }
  if (rdm_as_n(m) && rd->answered) {
    rd->answered = FALSE;
    _rd_release(rd);
  }
}

/* ------------------------------------------------------------------------ */
/* The thread                                                               */
/* ------------------------------------------------------------------------ */

static void
_rd_thread(struct rd68021 *rd)
{
  struct tme_bus_connection *conn_bus;
  unsigned int i;
  int out;

  tme_mutex_lock(&rd->mutex);

  /* held in reset by the board, or never let out: wait. */
  if (rd->reset_asserted || (!rd->running && !rd->reset_release)) {
    tme_cond_wait_yield(&rd->cond, &rd->mutex);
    /* NOTREACHED */
  }

  /* RESET let go: run the core's own reset. rst_n is held low for some
     clocks, because the microcode store's read register takes its reset
     word from the clock, not from the reset (doc/implementation.md). */
  if (rd->reset_release) {
    rd->reset_release = FALSE;
    rd->answered = FALSE;
    rdm_set_rst_n(rd->m, 0);
    _rd_release(rd);
    for (i = 0; i < 8; i++) {
      rdm_rising(rd->m);
      rdm_falling(rd->m);
    }
    rdm_set_rst_n(rd->m, 1);
    rd->running = TRUE;
    rd->halted = FALSE;
    if (rd->log) {
      fprintf(rd->log, "rd68021: out of reset\n");
      fflush(rd->log);
    }
  }

  if (rd->halted) {
    tme_cond_wait_yield(&rd->cond, &rd->mutex);
    /* NOTREACHED */
  }

  for (i = 0; i < RD_BURST; i++) {
    _rd_clock(rd);

    /* the core's RESET instruction: RESET out to every other device (PRM
       6), asserted for as long as the core holds it. */
    out = rdm_reset_out(rd->m);
    if (out != rd->driving_reset) {
      conn_bus = &rd->bus->tme_m68k_bus_connection;
      rd->driving_reset = TRUE;
      tme_mutex_unlock(&rd->mutex);
      (*conn_bus->tme_bus_signal)
        (conn_bus, TME_BUS_SIGNAL_RESET
         | (out ? TME_BUS_SIGNAL_LEVEL_ASSERTED : TME_BUS_SIGNAL_LEVEL_NEGATED));
      tme_mutex_lock(&rd->mutex);
      rd->driving_reset = out;
    }

    /* HALT out is a double bus fault: the core has stopped for good. */
    if (rdm_halt_out(rd->m)) {
      rd->halted = TRUE;
      fprintf(stderr, "rd68021: double bus fault, the processor is halted "
              "(%llu clocks, %llu bus cycles)\n", rdm_clocks(rd->m), rd->cycles);
      _rd_dump_ring(rd, "halted");
      break;
    }
  }

  if (rd->stop_at && rdm_clocks(rd->m) >= rd->stop_at) {
    rd->next_report = 0;
  }
  if (rd->log && rdm_clocks(rd->m) >= rd->next_report) {
    rd->next_report = rdm_clocks(rd->m) + 200000000;
    fprintf(rd->log, "rd68021: %llu clocks, %llu bus cycles, %llu faults, "
            "last fc%u %08lx\n", rdm_clocks(rd->m), rd->cycles, rd->faults,
            rdm_fc(rd->m), (unsigned long) rdm_addr(rd->m));
    {
      unsigned int b, j, best;
      unsigned long seen[16] = {0};
      for (j = 0; j < 16; j++) {
        best = 0;
        for (b = 0; b < 65536 / 16; b++) {
          int taken = 0, q;
          for (q = 0; q < (int) j; q++) if (seen[q] == b) taken = 1;
          if (!taken && rd->prom_hist[b] > rd->prom_hist[best]) best = b;
        }
        seen[j] = best;
        fprintf(rd->log, "  hot %08lx %lu\n", 0x0fef0000UL + best * 16, rd->prom_hist[best]);
      }
    }
    {
      unsigned int l;
      for (l = 1; l < 8; l++)
        if (rd->ipl_raised[l] || rd->iack_vec[l] || rd->iack_avec[l] || rd->iack_spur[l])
          fprintf(rd->log, "  ipl %u: raised %lu, vectored %lu, autovectored %lu, spurious %lu\n",
                  l, rd->ipl_raised[l], rd->iack_vec[l], rd->iack_avec[l], rd->iack_spur[l]);
    }
    {
      unsigned int b, j, best, q, taken;
      unsigned int seen[16];
      for (j = 0; j < 16; j++) {
        best = RD_PCH;
        for (b = 0; b < RD_PCH; b++) {
          if (rd->pch_line[b] == 0) continue;
          for (taken = 0, q = 0; q < j; q++) if (seen[q] == b) taken = 1;
          if (!taken && (best == RD_PCH || rd->pch_count[b] > rd->pch_count[best])) best = b;
        }
        if (best == RD_PCH) break;
        seen[j] = best;
        fprintf(rd->log, "  pc %08lx %lu\n",
                (unsigned long) ((rd->pch_line[best] & ~1u) << 4), rd->pch_count[best]);
      }
    }
    fflush(rd->log);
    /* RD68021_STOP_AT: stop the machine at this many clocks, for a profile of
       a known span -- the PROM up to its prompt, say. */
    if (rd->stop_at && rdm_clocks(rd->m) >= rd->stop_at) {
      exit(0);
    }
  }
  tme_mutex_unlock(&rd->mutex);
  tme_thread_yield();
}

/* ------------------------------------------------------------------------ */
/* Connections                                                              */
/* ------------------------------------------------------------------------ */

static int
_rd_connection_score(struct tme_connection *conn, unsigned int *_score)
{
  struct tme_m68k_bus_connection *conn_m68k;
  struct tme_bus_connection *conn_bus;

  conn_m68k = (struct tme_m68k_bus_connection *) conn->tme_connection_other;
  conn_bus = (struct tme_bus_connection *) conn->tme_connection_other;

  /* only an m68k bus -- a board with a TLB filler -- and not another CPU: */
  *_score = (conn->tme_connection_type == TME_CONNECTION_BUS_M68K
             && conn_bus->tme_bus_tlb_set_add != NULL
             && conn_m68k->tme_m68k_bus_tlb_fill != NULL
             && conn_m68k->tme_m68k_bus_m6888x_enable == NULL) ? 10 : 0;
  return (TME_OK);
}

static int
_rd_connection_make(struct tme_connection *conn, unsigned int state)
{
  struct rd68021 *rd;
  struct tme_bus_tlb_set_info info;
  unsigned int i;
  int rc;

  if (state != TME_CONNECTION_FULL) {
    return (TME_OK);
  }
  rd = conn->tme_connection_element->tme_element_private;
  rd->bus = (struct tme_m68k_bus_connection *) conn->tme_connection_other;

  /* the TLB entries, so that the board can invalidate one when a mapping it
     describes changes: */
  for (i = 0; i < 2 * RD_TLBS; i++) {
    tme_token_init(&rd->tlbs[i].tme_m68k_tlb_token);
    rd->tlbs[i].tme_m68k_tlb_bus_tlb.tme_bus_tlb_token = &rd->tlbs[i].tme_m68k_tlb_token;
  }
  memset(&info, 0, sizeof(info));
  info.tme_bus_tlb_set_info_token0 = &rd->tlbs[0].tme_m68k_tlb_token;
  info.tme_bus_tlb_set_info_token_stride = sizeof(struct tme_m68k_tlb);
  info.tme_bus_tlb_set_info_token_count = 2 * RD_TLBS;
  info.tme_bus_tlb_set_info_bus_context = &rd->bus_context;
  rc = (*rd->bus->tme_m68k_bus_connection.tme_bus_tlb_set_add)
    (&rd->bus->tme_m68k_bus_connection, &info);
  return (rc);
}

static int
_rd_connection_break(struct tme_connection *conn, unsigned int state)
{
  abort();
  return (0);
}

static int
_rd_connections_new(struct tme_element *element, const char * const *args,
                    struct tme_connection **_conns, char **_output)
{
  struct rd68021 *rd;
  struct tme_m68k_bus_connection *conn_m68k;
  struct tme_bus_connection *conn_bus;
  struct tme_connection *conn;

  rd = element->tme_element_private;
  if (rd->bus != NULL) {
    return (TME_OK);
  }

  conn_m68k = tme_new0(struct tme_m68k_bus_connection, 1);
  conn_bus = &conn_m68k->tme_m68k_bus_connection;
  conn = &conn_bus->tme_bus_connection;
  conn->tme_connection_next = *_conns;
  conn->tme_connection_type = TME_CONNECTION_BUS_M68K;
  conn->tme_connection_score = _rd_connection_score;
  conn->tme_connection_make = _rd_connection_make;
  conn->tme_connection_break = _rd_connection_break;
  conn_bus->tme_bus_signal = _rd_bus_signal;
  conn_bus->tme_bus_tlb_set_add = NULL;
  conn_m68k->tme_m68k_bus_interrupt = _rd_bus_interrupt;
  conn_m68k->tme_m68k_bus_tlb_fill = NULL;
  conn_m68k->tme_m68k_bus_m6888x_enable = _rd_m6888x_enable;
  *_conns = conn;
  return (TME_OK);
}

/* Simulated time: the host time the machine was made at, rounded down to a
   second so that every run sees the same sub-second phase, plus 60 ns for
   every clock the core has run -- a 16.67 MHz MC68020, the slowest grade in the
   manual. TME's scheduler and the Sun-3 clock chip read it through
   tme_rd_time_hook (sim/tme/build.sh), so a clock tick comes after as many
   instructions as it would on the real machine, and a run is reproducible. */
#define RD_NS_PER_CLOCK (60)
static struct rd68021 *_rd_time_cpu;
static time_t _rd_time_base;

static void
_rd_time(struct timeval *now)
{
  unsigned long long usec;

  usec = (rdm_clocks(_rd_time_cpu->m) * RD_NS_PER_CLOCK) / 1000;
  now->tv_sec = _rd_time_base + (time_t) (usec / 1000000);
  now->tv_usec = (long) (usec % 1000000);
}

/* `cpu0 at mainbus0: tme/ic/rd68021 [log FILE]` */
TME_ELEMENT_X_NEW_DECL(tme_ic_,m68k,rd68021) {
  struct rd68021 *rd;
  int arg_i;

  rd = tme_new0(struct rd68021, 1);
  rd->element = element;
  rd->log_full = 5000;
  rd->win_from = getenv("RD68021_LOG_FROM") ? strtoull(getenv("RD68021_LOG_FROM"), NULL, 0) : 0;
  rd->win_to   = getenv("RD68021_LOG_TO")   ? strtoull(getenv("RD68021_LOG_TO"), NULL, 0) : 0;
  rd->stop_at  = getenv("RD68021_STOP_AT")  ? strtoull(getenv("RD68021_STOP_AT"), NULL, 0) : 0;
  if (getenv("RD68021_LOG_ADDR")) {
    char *colon;
    rd->addr_lo = strtoul(getenv("RD68021_LOG_ADDR"), &colon, 0);
    rd->addr_hi = (*colon == ':') ? strtoul(colon + 1, NULL, 0) : rd->addr_lo;
  }
  rd->dev_from = getenv("RD68021_LOG_DEV_FROM") ? strtoull(getenv("RD68021_LOG_DEV_FROM"), NULL, 0) : 0;
  rd->syscalls = getenv("RD68021_SYSCALLS") != NULL;
  rd->faults_log = getenv("RD68021_FAULTS") != NULL;
  rd->ut_from = -1;
  if (getenv("RD68021_UTRACE")) {
    char *c;
    rd->ut_from = strtol(getenv("RD68021_UTRACE"), &c, 0);
    rd->ut_to = strtol(c + 1, NULL, 0);
  }
  rd->dump_at  = getenv("RD68021_DUMP_AT")  ? strtoull(getenv("RD68021_DUMP_AT"), NULL, 0) : 0;
  rd->stop_pc  = getenv("RD68021_STOP_PC")  ? strtoul(getenv("RD68021_STOP_PC"), NULL, 0) : 0;
  for (arg_i = 1; args[arg_i] != NULL; arg_i += 2) {
    if (TME_ARG_IS(args[arg_i], "log") && args[arg_i + 1] != NULL) {
      rd->log = fopen(args[arg_i + 1], "w");
      if (rd->log) setvbuf(rd->log, NULL, _IOLBF, 0);
    } else {
      tme_output_append_error(_output, "%s %s [ log FILE ]", _("usage:"), args[0]);
      tme_free(rd);
      return (EINVAL);
    }
  }
  tme_mutex_init(&rd->mutex);
  tme_cond_init(&rd->cond);
  rd->m = rdm_new();
  _rd_time_cpu = rd;
  _rd_time_base = time(NULL);
  tme_rd_time_hook = _rd_time;
  element->tme_element_private = rd;
  element->tme_element_connections_new = _rd_connections_new;
  tme_thread_create((tme_thread_t) _rd_thread, rd);
  return (TME_OK);
}
