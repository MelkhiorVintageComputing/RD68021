// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 - SystemVerilog MC68020
//
// Bus interface unit. Owns every pin and every clock.
//
// ONE BUS STATE PER CLK HALF PERIOD. Even-numbered states begin on a rising edge
// and odd-numbered ones on a falling edge, so a bus cycle with no wait states is
// three clocks, which is the manual's own ruler (UM 5.3). The state machine is two
// registers, one per edge, each computing its next state from the other.
//
// THE UNIT OF THE CONTRACT IS AN OPERAND, NOT A BUS CYCLE. The sequencer presents
// one request and stalls until req_ack; this unit splits it into the one to four
// bus cycles Table 5-6 requires for that size, alignment and port width, drives
// SIZ1/SIZ0 with the number of bytes REMAINING (UM 5.1.1), routes the byte lanes
// per Tables 5-4 and 5-5, and assembles the result. Nothing above this line knows
// how wide the port was.
//
// That is also what makes OCS correct for free: UM 5.1.1 asserts ECS at the start
// of every bus cycle and OCS only at the start of the first cycle *of an operand*,
// and "operand" there is exactly this handshake.
//
// M1: read, write, wait states, dynamic bus sizing, misalignment. Bus exception
// control and arbitration are M2; the cache abort is M11.

module rd68021_biu #(
    parameter bit ADDR_HIZ_BETWEEN_CYCLES = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    // Operand request from the sequencer ------------------------------------
    input  logic        req_valid,
    input  logic  [2:0] req_kind,
    input  logic  [2:0] req_fc,
    input  logic [31:0] req_addr,
    input  logic  [2:0] req_bytes,
    input  logic [39:0] req_wdata,
    input  logic        req_rmc,
    input  logic  [3:0] req_cpuspace,
    input  logic  [7:0] req_cpuaddr,
    input  logic        req_cpfault,
    // A posted write -- UM 8.1.3, doc/checkpoint.md rule 9. It gets no
    // acknowledge: `req_taken` says it has been taken, the clock after, and
    // the requester goes on. `post_busy` says one is still outstanding, and a
    // fault on it is `req_fault` with `req_fault_post`.
    input  logic        req_post,
    output logic        req_taken,
    output logic        post_busy,
    output logic        req_fault_post,
    output logic        req_ack,
    output logic        req_last,
    // The sequencer's request starts its first bus cycle at this rising edge:
    // S0. IPEND reads it for an interrupt acknowledge -- UM 6.1.9.
    output logic        req_start,
    // The data operand finishes cleanly at the rising edge that ends S5 -- no
    // bus error, no retry. A falling-edge register, valid for that half clock.
    output logic        req_early,
    output logic [39:0] req_rdata,
    output logic  [2:0] req_end,
    output logic        req_fault,
    output logic        req_fault_wr,
    output logic  [1:0] req_dsack,

    // The residual of the in-flight operand, for the fault frame -------------
    output logic [31:0] flt_addr,
    output logic  [2:0] flt_bytes,
    output logic  [2:0] flt_fc,
    output logic        flt_rw,
    output logic        flt_rmc,
    output logic [31:0] flt_dob,
    output logic [31:0] flt_dib,

    // ... and back in, when RTE says to finish it ----------------------------
    input  logic        rst_op_valid,
    // The microword RTE resumed has retired without asking for an operand: the
    // fault was an instruction prefetch at a boundary, and there is nothing to
    // hand back. Whatever is pending is dropped.
    input  logic        rst_cancel,
    // The operand handed back is a posted write: run it now, for nobody.
    input  logic        rst_post,
    input  logic [31:0] rst_addr,
    input  logic  [2:0] rst_bytes,
    input  logic  [2:0] rst_fc,
    input  logic        rst_rw,
    input  logic        rst_rmc,
    input  logic [31:0] rst_dob,

    // Instruction fetch ------------------------------------------------------
    input  logic        fetch_valid,
    input  logic [31:0] fetch_addr,
    input  logic  [2:0] fetch_fc,
    output logic        fetch_ack,
    output logic        fetch_last,
    output logic [31:0] fetch_rdata,
    output logic        fetch_fault,
    input  logic        bus_abort,

    // Status -----------------------------------------------------------------
    input  logic        reset_req,
    output logic        reset_busy,
    input  logic        dbf,
    output logic  [2:0] ipl_sync_n,
    // The RESET pin from outside, registered: the processor is held in reset
    // while it is set -- UM 5.8. Not this processor's own RESET instruction.
    output logic        crst,
    output logic        halt_sync_n,
    output logic        cdis_sync_n,
    output logic        bus_idle,
    output logic        bus_granted,

    // Pins -------------------------------------------------------------------
    output logic  [2:0] fc_o,
    output logic        fc_oe,
    output logic [31:0] a_o,
    output logic        a_oe,
    input  logic [31:0] d_i,
    output logic [31:0] d_o,
    output logic        d_oe,
    output logic  [1:0] siz_o,
    output logic        siz_oe,
    output logic        ecs_n_o,
    output logic        ocs_n_o,
    output logic        rw_o,
    output logic        rw_oe,
    output logic        rmc_n_o,
    output logic        rmc_oe,
    output logic        as_n_o,
    output logic        as_oe,
    output logic        ds_n_o,
    output logic        ds_oe,
    output logic        dben_n_o,     // active low -- UM table 3-2
    output logic        dben_oe,
    input  logic  [1:0] dsack_n_i,
    input  logic  [2:0] ipl_n_i,
    input  logic        avec_n_i,
    input  logic        br_n_i,
    output logic        bg_n_o,
    input  logic        bgack_n_i,
    input  logic        berr_n_i,
    input  logic        reset_n_i,
    output logic        reset_n_o,
    output logic        reset_n_oe,
    input  logic        halt_n_i,
    output logic        halt_n_o,
    output logic        halt_n_oe,
    input  logic        cdis_n_i
);

  // iverilog rejects a declaration inside an unnamed begin/end, so every loop
  // variable lives at module scope -- and each always_comb needs its own, or a
  // shared one is reported as MULTIDRIVEN by the lint pass.
  int unsigned i_v;
  int unsigned i_rv;
  int unsigned i_rd;
  int unsigned i_wr;

  // ==========================================================================
  // Input synchronisers -- UM 5.1, figures 5-1 and 5-2
  //
  // The processor latches the level of an input during a sample window around the
  // FALLING edge of the clock, so both ranks are negedge. DSACK, BERR, HALT and
  // AVEC are not here: they go straight to the falling-edge next-state logic,
  // which is the sample UM 5.3 describes and which must not have a rank of
  // latency added to it.
  // ==========================================================================
  rd68021_sync #(.WIDTH (3), .RESET_VAL (3'b111)) u_sync_ipl (
      .clk (clk), .rst_n (rst_n), .d (ipl_n_i), .q (ipl_sync_n));

  logic reset_sync_n;
  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_reset (
      .clk (clk), .rst_n (rst_n), .d (reset_n_i), .q (reset_sync_n));

  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_halt (
      .clk (clk), .rst_n (rst_n), .d (halt_n_i), .q (halt_sync_n));

  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_cdis (
      .clk (clk), .rst_n (rst_n), .d (cdis_n_i), .q (cdis_sync_n));

  logic br_sync_n;
  logic bgack_sync_n;
  logic hiz_q;

  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_br (
      .clk (clk), .rst_n (rst_n), .d (br_n_i), .q (br_sync_n));

  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_bgack (
      .clk (clk), .rst_n (rst_n), .d (bgack_n_i), .q (bgack_sync_n));

  // ==========================================================================
  // The operand in flight
  //
  // op_rem is the number of bytes still to move. It is what drives SIZ1/SIZ0, it
  // is what the fault frame records as the residual, and it reaching zero is what
  // acknowledges the request.
  // ==========================================================================
  logic        op_active;
  logic [31:0] op_addr;
  logic  [2:0] op_rem;
  logic  [2:0] op_fc;
  logic        op_rw;        // 1 = read
  logic        op_rmc;
  logic        op_first;     // no bus cycle of this operand has started yet -- OCS
  logic        op_isfetch;
  logic        op_posted;    // a posted write: no acknowledge -- rule 9
  logic        rst_post_q;   // the operand RTE handed back is a posted write   // the request came from the instruction fetch unit
  // A bus error on this CPU-space operand is a bus error and not an answer: a
  // coprocessor interface register other than the one that starts an
  // instruction -- UM 7.5.2.8.
  logic        op_cpflt;

  // Declared here, above the logic that reads them, rather than beside the
  // logic that drives them: Quartus, Vivado and Questa all refuse a use above
  // the declaration, and tools/src_lint.py holds `make lint` to that.
  logic        rst_pend_q;
  logic       rsto_q;
  logic [39:0] op_data;      // write data, or the read accumulator, right justified

  // The result of the last completed operand of each kind, held until the next
  // one of that kind completes. op_data cannot serve: it is the accumulator of
  // the operand in flight, and the instruction fetch unit refills the pipe by
  // itself, so a prefetch starting in the clock after a data read would destroy
  // the data before the sequencer had read it.
  logic [39:0] rdata_q;
  logic [31:0] frdata_q;

  // The cycle in flight, latched at the rising edge entering S0 so that every pin
  // is stable for the whole cycle whatever the operand state does.
  logic [31:0] cyc_addr;
  logic  [2:0] cyc_fc;
  logic  [1:0] cyc_siz;
  logic  [2:0] cyc_n;        // bytes this cycle asks for: min(op_rem, 4)
  logic        cyc_rw;

  // ==========================================================================
  // Bus state. Two registers, one per edge.
  //
  //   st_p holds S0, S2, S4, WH or IDLE   (changes on the rising edge)
  //   st_n holds S1, S3, WL, S5 or IDLE   (changes on the falling edge)
  //
  // WH/WL are the wait pair inserted between S3 and S4: UM 5.3.1 state 3, "if wait
  // states are added, the processor continues to sample the DSACK signals on the
  // falling edges of the clock until an assertion is recognized", so one wait is
  // one whole clock and the sample repeats at ST_WL.
  // ==========================================================================
  rd68021_pkg::bus_state_e st_p, st_p_nxt;
  rd68021_pkg::bus_state_e st_n, st_n_nxt;

  logic [1:0] dsack_q;       // the port size, sampled on the edge entering S5
  logic [2:0] end_now;       // how the cycle now ending ended, live
  logic [2:0] req_end_q;     // ... and the copy the sequencer is given
  logic       term_q;        // ... and whether it terminated the cycle at all
  logic       term_err;      // ... as a bus error (Table 5-8 cases 3 and 4)
  logic       term_rty;      // ... as a retry (cases 5 and 6)
  logic       term_hlt;      // ... normally, but with HALT asserted (case 2)
  logic       term_avc;      // ... by AVEC, on an interrupt acknowledge cycle

  // RMC is a qualifier held across a run of ordinary cycles, not a cycle kind
  // (UM 5.5.2). It is raised by the first request of the run and stays up until
  // a request without it starts a cycle -- which is exactly UM 5.1.1's "RMC is
  // guaranteed to be negated before the end of state 0 for a bus cycle following
  // a read-modify-write operation" -- or until the bus goes idle without one.
  logic rmc_hold;

  // UM 5.5.3: HALT alone does not terminate a cycle; it stops the next one. While
  // halted the data bus goes high impedance and AS, DS, ECS and OCS are negated,
  // but the address, FC, SIZ and R/W "remain in the same state" -- driven, not
  // released, which is what distinguishes this from an ordinary idle bus.
  logic halt_hold;

  // ---------------------------------------------------------------------------
  // Bus arbitration -- UM 5.7.1.4
  // ---------------------------------------------------------------------------
  rd68021_pkg::arb_state_e arb, arb_nxt;

  // The RESET pin's reset -- below, with the RESET instruction's counter --
  // and the reset of everything in this unit but the arbiter: rst_n, or the
  // pin. UM 5.8: "the external RESET signal resets the processor and the
  // entire system".
  logic        crst_q;
  logic        eng_rst_n;
  assign eng_rst_n = rst_n && !crst_q;

  logic arb_r;   // BR, synchronised and in positive logic
  logic arb_a;   // BGACK, likewise
  assign arb_r = ~br_sync_n;
  assign arb_a = ~bgack_sync_n;

  // "The BG output will not be asserted while RMC is asserted" -- the note under
  // figure 5-44, and 5.7.1.4: "for the duration of this sequence, the MC68020
  // ignores the BR input".
  //
  // That includes the sequence's first read. The MC68030 makes that read the
  // one exception, relinquishing and retrying on BERR, HALT and BR there (its
  // UM 7.5.2 and 7.7.4), and RD68031 does. The MC68020 has no exception: it
  // "does not relinquish the bus during a read-modify-write operation", and a
  // device that needs the bus must "assert BERR and BR only (HALT must not be
  // included)" (UM 5.5.2).
  logic arb_req;
  assign arb_req = arb_r && !rmc_hold;

  function automatic logic arb_g_of(input rd68021_pkg::arb_state_e st);
    arb_g_of = (st == rd68021_pkg::ARB_GRANT) || (st == rd68021_pkg::ARB_WAIT)
            || (st == rd68021_pkg::ARB_REGRANT) || (st == rd68021_pkg::ARB_REWAIT);
  endfunction

  function automatic logic arb_t_of(input rd68021_pkg::arb_state_e st);
    arb_t_of = (st != rd68021_pkg::ARB_IDLE);
  endfunction

  // The operand finishes with the cycle that is ending now. This is the signal the
  // whole handshake turns on: req_last exports it, and the sequencer is expected
  // to have the next request already presented by the rising edge that consumes
  // it -- which is what the microword's successor previews are for.
  logic op_finishing;
  logic op_continuing;

  // A request is available to start a bus cycle. Data beats instruction fetch:
  // the sequencer is stalled on a data operand and the pipe is not.
  //
  // The arbiter's NEXT state decides whether a cycle may start, not its current
  // one. Reading the current state there is a real bug with a real failure mode:
  // on the single edge where the arbiter reaches its granting state, a cycle
  // begins anyway and then runs with its address bus already in high impedance,
  // which on the MC68010 project cost a long-word read one of its two words every
  // few thousand DMA transfers.
  logic want_cycle;
  // RTE has a posted write to rerun, and the edge a posted write faults on.
  logic rst_self, post_flt_end;
  // Nothing new starts on the edge a posted write ends in a bus error: the
  // sequencer is about to take it, and with nothing taken the state machine
  // would go to S0 by its retry arm and run the faulted write again.
  assign want_cycle = op_continuing
                   || (!post_flt_end && (req_valid || fetch_valid || rst_self));

  logic bus_is_idle;
  assign bus_is_idle = (st_p == rd68021_pkg::ST_IDLE)
                       && (st_n == rd68021_pkg::ST_IDLE);

  // HALT stops the NEXT cycle from starting, whether the bus was busy or idle
  // when it came: the processor "halts external bus activity at the next bus
  // cycle boundary" (UM 5.5.3). Synchronised, as every asynchronous input
  // other than the termination samples is.
  logic start_ok;
  assign start_ok = want_cycle && halt_sync_n && !arb_t_of(arb_nxt);

  // Retry clears when BOTH BERR and HALT have been negated -- UM 5.5.2, "does not
  // begin another bus cycle until the BERR and HALT signals have been negated by
  // external logic".
  //
  // Sampled on the FALLING edge, like every other use of these two pins. They
  // are asynchronous inputs, which UM 5.1 latches "during a sample window
  // around the falling edge of the clock" and specifications 47A and 47B bound
  // only there; a device is free to move them at a rising edge. This was the
  // raw pins, read by the rising-edge state register's next-state logic,
  // which is a metastable sample of a multi-bit register exactly where a
  // device changes them. One falling-edge flop, as the termination samples
  // are: no synchroniser rank is added, so the restart is at most half a
  // clock later than it was.
  logic retry_clr_q;
  logic retry_clear;
  assign retry_clear = retry_clr_q;

  // The if/else inside each case item is not a style choice: iverilog rejects a
  // ternary of two enum values assigned to an enum variable with "This assignment
  // requires an explicit cast" (doc/coding-standard.md, measured).
  always_comb begin
    st_p_nxt = st_p;
    if (st_p == rd68021_pkg::ST_RETRY) begin
      // UM 5.5.2: "after a synchronization delay, the processor retries the
      // previous cycle using the same access information". Nothing in cyc_* or
      // op_* was updated by the faulted cycle, so re-entering S0 reissues it.
      if (retry_clear && !arb_t_of(arb_nxt)) st_p_nxt = rd68021_pkg::ST_S0;
      else                                   st_p_nxt = rd68021_pkg::ST_RETRY;
    end else if (st_p == rd68021_pkg::ST_HALT) begin
      if (!halt_sync_n)                st_p_nxt = rd68021_pkg::ST_HALT;
      else if (start_ok)               st_p_nxt = rd68021_pkg::ST_S0;
      else                             st_p_nxt = rd68021_pkg::ST_IDLE;
    end else begin
      unique case (st_n)
      rd68021_pkg::ST_IDLE: begin
        if (start_ok) st_p_nxt = rd68021_pkg::ST_S0;
        else          st_p_nxt = rd68021_pkg::ST_IDLE;
      end
      rd68021_pkg::ST_S1: st_p_nxt = rd68021_pkg::ST_S2;
      rd68021_pkg::ST_S3: begin
        if (term_q) st_p_nxt = rd68021_pkg::ST_S4;
        else        st_p_nxt = rd68021_pkg::ST_WH;
      end
      rd68021_pkg::ST_WL: begin
        if (term_q) st_p_nxt = rd68021_pkg::ST_S4;
        else        st_p_nxt = rd68021_pkg::ST_WH;
      end
      // The rising edge that ends S5. Table 5-8 decides where it goes.
      rd68021_pkg::ST_S5: begin
        if (term_rty)                st_p_nxt = rd68021_pkg::ST_RETRY;
        else if (term_hlt || !halt_sync_n)
                                     st_p_nxt = rd68021_pkg::ST_HALT;
        else if (start_ok)           st_p_nxt = rd68021_pkg::ST_S0;
        else                         st_p_nxt = rd68021_pkg::ST_IDLE;
      end
      default: st_p_nxt = rd68021_pkg::ST_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // The arbiter's next state -- UM 5.7.1.4, in the prose's own words
  // ---------------------------------------------------------------------------
  always_comb begin
    arb_nxt = arb;
    unique case (arb)
      // "Request R and acknowledge A keep the arbiter in state 0 as long as they
      // are both negated. When a request R is received, both grant G and signal T
      // are asserted."
      //
      // ... "except when the MC68020 has made an internal decision to execute a
      // bus cycle. Then, the assertion of BG is deferred until the bus cycle has
      // begun."
      //
      // That deferral is exactly one edge: the edge on which an idle bus with a
      // request pending enters S0. Testing st_p_nxt for it would be the direct
      // transcription and is a combinational loop -- st_p_nxt depends on
      // start_ok, which depends on this state -- so the test is on the registered
      // state instead, which says the same thing one expression earlier.
      //
      // And figure 5-44's arc from state 0 to state 4: acknowledge A alone puts
      // the buses in the high-impedance state with no grant at all -- an
      // alternate master that arbitrates on BGACK by itself. Not inside a
      // read-modify-write, for the same reason BR is not heard there: "the
      // MC68020 does not allow arbitration of the external bus during the
      // read-modify-write sequence", and the release waits for RMC to negate,
      // which only the sequence's own write can bring about. T asserted in the
      // gap would hold that write off, and the two would wait for each other.
      rd68021_pkg::ARB_IDLE: begin
        if (arb_a && !rmc_hold)
          arb_nxt = rd68021_pkg::ARB_HELD;
        // A bus held by HALT has made no such decision, and does not defer.
        // Nor has a processor held in reset by the RESET pin.
        else if (arb_req && !(bus_is_idle && want_cycle && halt_sync_n
                              && !crst_q))
          arb_nxt = rd68021_pkg::ARB_GRANT;
        else
          arb_nxt = rd68021_pkg::ARB_IDLE;
      end
      // "The next clock causes a change to state 2."
      rd68021_pkg::ARB_GRANT: arb_nxt = rd68021_pkg::ARB_WAIT;
      // "The bus arbiter remains in that state until acknowledge A is asserted or
      // request R is negated."
      rd68021_pkg::ARB_WAIT: begin
        if (arb_a || !arb_r) arb_nxt = rd68021_pkg::ARB_DROP;
        else                 arb_nxt = rd68021_pkg::ARB_WAIT;
      end
      // "The next clock takes the arbiter to state 4."
      rd68021_pkg::ARB_DROP: arb_nxt = rd68021_pkg::ARB_HELD;
      // "With acknowledge A asserted, the arbiter remains in state 4 until A is
      // negated or request R is again asserted. When A is negated, the arbiter
      // returns to the original state."
      //
      // R again is figure 5-44's states 5 and 6, the re-grant: "if another BR
      // is still pending after the assertion of BGACK, another BG is asserted
      // within a few clocks", and "the processor does not perform any external
      // bus cycles before it reasserts BG" (UM 5.7.1.3). State 5 asserts G
      // with T still held; state 6 holds G for as long as the old master still
      // asserts A, and only then passes to state 2 to wait for the new one's.
      // Going back to state 1 instead, as this arbiter once did, left on the
      // old master's A two clocks later, and BG pulsed for as long as it kept
      // the bus.
      rd68021_pkg::ARB_HELD: begin
        if (arb_req)     arb_nxt = rd68021_pkg::ARB_REGRANT;
        else if (!arb_a) arb_nxt = rd68021_pkg::ARB_IDLE;
        else             arb_nxt = rd68021_pkg::ARB_HELD;
      end
      rd68021_pkg::ARB_REGRANT: arb_nxt = rd68021_pkg::ARB_REWAIT;
      // ... and in state 6 the request may go away instead: G negates (state
      // 3), and T stays until the old master's A does (state 4).
      rd68021_pkg::ARB_REWAIT: begin
        if (!arb_r)      arb_nxt = rd68021_pkg::ARB_DROP;
        else if (!arb_a) arb_nxt = rd68021_pkg::ARB_WAIT;
        else             arb_nxt = rd68021_pkg::ARB_REWAIT;
      end
      default: arb_nxt = rd68021_pkg::ARB_IDLE;
    endcase
  end

  always_comb begin
    st_n_nxt = st_n;
    unique case (st_p)
      rd68021_pkg::ST_S0:   st_n_nxt = rd68021_pkg::ST_S1;
      rd68021_pkg::ST_S2:   st_n_nxt = rd68021_pkg::ST_S3;
      rd68021_pkg::ST_S4:   st_n_nxt = rd68021_pkg::ST_S5;
      rd68021_pkg::ST_WH:   st_n_nxt = rd68021_pkg::ST_WL;
      default:              st_n_nxt = rd68021_pkg::ST_IDLE;
    endcase
  end

  // ==========================================================================
  // Dynamic bus sizing -- UM 5.2.1, Tables 5-1, 5-4, 5-5, 5-6 and 5-7
  //
  // "Dynamic bus sizing requires that the portion of the data bus used for a
  // transfer to or from a particular port size be fixed. A 32-bit port must reside
  // on D31-D0, a 16-bit port must reside on D31-D16, and an 8-bit port must reside
  // on D31-D24."
  //
  // So the number of bytes a cycle actually moves is however many of the ones it
  // asked for fit in the port from the offset the address lands on. That single
  // expression reproduces every row of Table 5-6.
  // ==========================================================================
  logic [2:0] port_bytes;    // 1, 2 or 4
  logic [1:0] port_off;      // the address's offset within the port
  logic [2:0] xfer_n;        // bytes this cycle will actually move

  // The port size is taken one clock after the edge that recognised DSACK, at
  // the falling edge that latches the data -- see the falling-edge block. In
  // the half clock before that edge (S4, after the rising edge that entered
  // it) it is the pins themselves, for early_q, the only register clocked on
  // that edge that reads it; no rising-edge register ever sees this arm,
  // because st_n is S5 again before the next rising edge.
  logic [1:0] dsack_port;
  assign dsack_port = ((st_p == rd68021_pkg::ST_S4) && (st_n != rd68021_pkg::ST_S5))
                    ? dsack_n_i : dsack_q;

  always_comb begin
    unique case (dsack_port)
      rd68021_pkg::DSACK_8:  port_bytes = 3'd1;
      rd68021_pkg::DSACK_16: port_bytes = 3'd2;
      rd68021_pkg::DSACK_32: port_bytes = 3'd4;
      default:               port_bytes = 3'd4;
    endcase
  end

  always_comb begin
    unique case (dsack_port)
      rd68021_pkg::DSACK_8:  port_off = 2'd0;
      rd68021_pkg::DSACK_16: port_off = {1'b0, cyc_addr[0]};
      rd68021_pkg::DSACK_32: port_off = cyc_addr[1:0];
      default:               port_off = cyc_addr[1:0];
    endcase
  end

  always_comb begin
    xfer_n = port_bytes - {1'b0, port_off};
    if (xfer_n > cyc_n) xfer_n = cyc_n;
  end

  // What the cycle actually moved. A bus error moves nothing -- the frame has to
  // record the residual as it was BEFORE the faulted access, because RTE reruns
  // that access -- and a retried cycle moves nothing either, because UM 5.5.2
  // reruns it "using the same access information".
  logic [2:0] xfer_done;
  always_comb begin
    if (term_err || term_rty) xfer_done = 3'd0;
    else                      xfer_done = xfer_n;
  end

  // ==========================================================================
  // Read: which lane each byte arrives on -- UM Table 5-4
  //
  // The most significant byte still owed lands on the lane the address selects
  // (D31-D24 is lane 0), and the rest follow on successively lower lanes. A 16-bit
  // port offsets within its own two lanes; an 8-bit port always uses lane 0.
  // ==========================================================================
  // UM 5.3.1 state 4: "at the end of state 4, the processor latches the incoming
  // data" -- the falling edge entering S5. The lanes below are that latched copy,
  // so the merge that follows on the next rising edge is not looking at the pins.
  logic [31:0] d_latched;

  logic [7:0] lane [0:3];
  assign lane[0] = d_latched[31:24];
  assign lane[1] = d_latched[23:16];
  assign lane[2] = d_latched[15:8];
  assign lane[3] = d_latched[7:0];

  // The operand as a byte array, least significant first, so that every index
  // below is a plain 3-bit number rather than a part-select whose width the tools
  // disagree about. Eight entries for a five-byte operand: the top three are never
  // read, and having them removes every out-of-range index warning.
  logic [7:0] opv [0:7];

  always_comb begin
    for (i_v = 0; i_v < 8; i_v = i_v + 1) begin
      opv[i_v] = (i_v < 5) ? op_data[i_v * 8 +: 8] : 8'h00;
    end
  end

  logic [7:0] rdv [0:7];
  logic [2:0] rd_sel;
  logic [1:0] rd_lane;
  logic [39:0] rd_merged;

  always_comb begin
    for (i_rv = 0; i_rv < 8; i_rv = i_rv + 1) begin
      rdv[i_rv] = opv[i_rv];
    end
    rd_sel  = '0;
    rd_lane = '0;
    for (i_rd = 0; i_rd < 4; i_rd = i_rd + 1) begin
      if (i_rd < xfer_done) begin
        // Byte i_rd of this cycle is the (op_rem-1-i_rd)-th byte of the operand,
        // counting up from the least significant.
        rd_sel  = op_rem - 3'd1 - i_rd[2:0];
        // ... and it arrives on the lane the address offset selects. The sum
        // never exceeds three: xfer_n is capped at port_bytes - port_off.
        rd_lane = port_off + i_rd[1:0];
        rdv[rd_sel] = lane[rd_lane];
      end
    end
    rd_merged = {rdv[4], rdv[3], rdv[2], rdv[1], rdv[0]};
  end

  // ==========================================================================
  // Write: the internal-to-external multiplexer -- UM Table 5-5
  //
  // Transcribed rather than reduced to a formula, because two of its entries are
  // footnoted "due to the current implementation, this byte is output but never
  // used" and a formula would quietly disagree with the manual about them.
  //
  // opb[j] is the j-th byte of the group this cycle is presenting, j = 0 being the
  // most significant. The manual names them OP0..OP3 by position in the whole
  // operand, so for a size of n bytes its OPk is our opb[k - (4 - n)].
  //
  // All four lanes are always driven: "the MC68020/EC020 always drives all
  // sections of the data bus because, at the beginning of a write cycle, the bus
  // controller does not know the port size" (UM 5.2.4).
  // ==========================================================================
  logic [7:0] opb [0:3];
  logic [2:0] wr_sel;

  always_comb begin
    wr_sel = '0;
    for (i_wr = 0; i_wr < 4; i_wr = i_wr + 1) begin
      if (op_rem > i_wr[2:0]) begin
        wr_sel     = op_rem - 3'd1 - i_wr[2:0];
        opb[i_wr]  = opv[wr_sel];
      end else begin
        opb[i_wr]  = 8'h00;
      end
    end
  end

  // The byte just above the ones still to send -- the operand byte the previous
  // cycle of this operand sent last. op_data keeps the whole operand and only
  // op_rem counts down, so it is still there. Table 5-5 puts it on D7-D0 of a
  // three-byte transfer at A1A0 = 00, which only arises as the rest of a long
  // word begun at A1A0 = 11: the manual's OP0.
  logic [7:0] op_above;
  assign op_above = opv[op_rem];

  logic [31:0] wr_lanes;

  always_comb begin
    unique case ({cyc_siz, cyc_addr[1:0]})
      // Byte: OP3 on every lane, whatever A1 and A0 are.
      {rd68021_pkg::SIZ_BYTE,  2'b00},
      {rd68021_pkg::SIZ_BYTE,  2'b01},
      {rd68021_pkg::SIZ_BYTE,  2'b10},
      {rd68021_pkg::SIZ_BYTE,  2'b11}: wr_lanes = {opb[0], opb[0], opb[0], opb[0]};

      // Word: A1 is a don't care.
      {rd68021_pkg::SIZ_WORD,  2'b00},
      {rd68021_pkg::SIZ_WORD,  2'b10}: wr_lanes = {opb[0], opb[1], opb[0], opb[1]};
      {rd68021_pkg::SIZ_WORD,  2'b01},
      {rd68021_pkg::SIZ_WORD,  2'b11}: wr_lanes = {opb[0], opb[0], opb[1], opb[0]};

      // 3 bytes. The D7-D0 entry of the first row is OP0, the byte sent
      // before these three -- footnoted "output but never used", and Table 5-7
      // leaves the lane disabled, but it is what the part drives and so what
      // this drives. The Suska WF68K30L drives the same (make suska).
      {rd68021_pkg::SIZ_3BYTE, 2'b00}: wr_lanes = {opb[0], opb[1], opb[2], op_above};
      {rd68021_pkg::SIZ_3BYTE, 2'b01}: wr_lanes = {opb[0], opb[0], opb[1], opb[2]};
      {rd68021_pkg::SIZ_3BYTE, 2'b10}: wr_lanes = {opb[0], opb[1], opb[0], opb[1]};
      {rd68021_pkg::SIZ_3BYTE, 2'b11}: wr_lanes = {opb[0], opb[0], opb[1], opb[0]};

      // Long word.
      {rd68021_pkg::SIZ_LONG,  2'b00}: wr_lanes = {opb[0], opb[1], opb[2], opb[3]};
      {rd68021_pkg::SIZ_LONG,  2'b01}: wr_lanes = {opb[0], opb[0], opb[1], opb[2]};
      {rd68021_pkg::SIZ_LONG,  2'b10}: wr_lanes = {opb[0], opb[1], opb[0], opb[1]};
      {rd68021_pkg::SIZ_LONG,  2'b11}: wr_lanes = {opb[0], opb[0], opb[1], opb[0]};

      default:                         wr_lanes = {opb[0], opb[1], opb[2], opb[3]};
    endcase
  end

  // ==========================================================================
  // The strobes, declared here because the rising-edge block below uses as_win
  // and Questa and Vivado both reject a variable read above its own declaration
  // -- (vlog-2730) and [Synth 8-6901], which scripts/synth.tcl promotes from an
  // info to an error for exactly this reason. The two lint front-ends invent an
  // implicit net instead and say nothing.
  //
  // EVERY STROBE IS A FLIP-FLOP, NOT A DECODE OF THE STATE. A strobe decoded
  // from a multi-bit state register glitches whenever two of its bits change on
  // the same edge and the decode is true of a code in between -- ECS, OCS, DBEN
  // and the data enable at S2 -> S4. So each pin is the registered value of the
  // same decode applied to the NEXT state, which is the same waveform from a
  // flop. A pin that moves on one edge is a flop on that edge; DBEN, which moves
  // on both, is rd68021_dedge_ff.
  // ==========================================================================

  // The states AS is asserted in: from the falling edge entering S1 to the
  // falling edge entering S5.
  function automatic logic as_set(input rd68021_pkg::bus_state_e st);
    as_set = (st == rd68021_pkg::ST_S1) || (st == rd68021_pkg::ST_S3)
          || (st == rd68021_pkg::ST_WL);
  endfunction

  // DBEN, active high here, as a function of the two states -- UM 5.1.6:
  // during a read it is asserted one clock after the beginning of the bus
  // cycle, in S2, and negated as DS is, in S5; during a write it is asserted
  // with AS and held for the duration of the cycle, through S5.
  function automatic logic dben_of(input rd68021_pkg::bus_state_e p,
                                   input rd68021_pkg::bus_state_e n,
                                   input logic rw);
    if (rw)
      dben_of = ((p == rd68021_pkg::ST_S2) || (p == rd68021_pkg::ST_S4)
                 || (p == rd68021_pkg::ST_WH))
                && (n != rd68021_pkg::ST_S5);
    else
      dben_of = as_set(n)
                || ((n == rd68021_pkg::ST_S5) && (p == rd68021_pkg::ST_S4));
  endfunction

  logic as_win;     // AS asserted: a falling-edge register
  logic ds_q;       // DS asserted: likewise
  logic ecs_q;      // the rising edge entering S0 has passed
  logic ocs_q;      // ... and it began an operand
  logic doe_q;      // write data driven: a rising-edge register

  // ==========================================================================
  // Starting a cycle, and starting an operand
  // ==========================================================================
  logic        take_rst;
  logic        take_req;
  logic        take_fetch;
  logic [31:0] next_addr;
  logic  [2:0] next_rem;
  logic  [2:0] next_fc;
  logic        next_rw;
  logic        next_rmc;

  // A new operand may be taken when none is active, or at the very edge the
  // active one completes.
  // UM 6.2.3: RTE "reruns the faulted data access". It is the SAME operand, not
  // a new one -- doc/checkpoint.md rule 3, the unit of restart is the operand --
  // so it comes in with the residual the frame carried and the bytes already
  // gathered, and outranks anything the sequencer or the pipe is asking for.
  // A restored operand outlives the microword that handed it over. The
  // sequencer gives it to the bus unit and jumps to the microword that faulted
  // in the same clock, and the bus is not necessarily idle on that clock -- so
  // this is a latched request and not a level. Without the latch the handover
  // was simply missed, the resumed microword issued its own full-length request
  // instead, and RTE rewrote the bytes that had already gone.
  //
  // ... and it is handed to the resumed microword's OWN request, not to
  // whichever request comes first. RTE resumes at the microword that faulted;
  // when that one has a bus request, its request is the first presented, and it
  // takes the operand. When it has none -- an instruction prefetch fault taken
  // while the pipe was empty, at a boundary -- the operand is for nobody, and
  // the sequencer cancels it when that microword retires. Taking it without a
  // request gave its acknowledge, and its data, to the next instruction's first
  // bus microword: an RTS at the resumed address jumped to the frame's data
  // input buffer without reading its stack (doc/bugs-found.md).
  //
  // A prefetch is not held up behind it either: the resumed microword may be
  // waiting for exactly that word.
  //
  // A posted write handed back is run at once, for nobody: the microword RTE
  // resumed is not the one that wrote it -- doc/checkpoint.md rule 9.
  //
  // And nothing new is taken on the edge a posted write ends in a bus error.
  // The sequencer is about to take the fault at whatever microword it is on,
  // and a request that microword had presented must not run.
  assign rst_self     = rst_pend_q && rst_post_q && (rst_bytes != 3'd0);
  assign post_flt_end = op_finishing && op_posted && term_err;
  assign take_rst   = !op_continuing && !post_flt_end && rst_pend_q
                   && (req_valid || rst_post_q) && (rst_bytes != 3'd0);
  assign take_req   = !op_continuing && !post_flt_end && !rst_pend_q
                   && req_valid;
  assign req_start  = take_req && (st_p_nxt == rd68021_pkg::ST_S0);
  assign take_fetch = !op_continuing && !post_flt_end && !req_valid && fetch_valid
                   && !rst_self;

  // UM 6.2.2: with DF cleared "it assumes that the data input buffer value on
  // the stack is valid for a read or that the data has been correctly written
  // to memory for a write". The sequencer says so by handing back an operand
  // with nothing left of it, and the answer is the buffer out of the frame.
  //
  // It still has to be handed back rather than skipped: the microword that
  // faulted is re-executed -- doc/checkpoint.md rule 2 -- and everything else
  // it does has to happen exactly once. Satisfying its request from the frame
  // is what lets it run again without running the access again.
  logic rst_done;
  assign rst_done = rst_pend_q && !rst_post_q && !op_continuing && req_valid
                 && (rst_bytes == 3'd0);

  // A posted write is outstanding, or RTE has one to rerun.
  assign post_busy = (op_active && op_posted) || rst_self;

  // OCS for a cycle starting at this edge: the first of a new operand, or the
  // next of one none of whose cycles has finished yet -- op_first as this edge
  // leaves it.
  logic first_now;
  assign first_now = take_rst || take_req || take_fetch
                  || (op_first && (st_n != rd68021_pkg::ST_S5))
                  || ((st_n == rd68021_pkg::ST_S5) && op_finishing);

  // CPU space synthesises its address from the type field -- UM figure 5-31.
  logic [31:0] cpu_space_addr;
  always_comb begin
    unique case (req_cpuspace)
      rd68021_pkg::CPUS_IACK:
        // All ones above the level, which sits on A3-A1 with A0 set.
        cpu_space_addr = {28'hFFF_FFFF, req_cpuaddr[2:0], 1'b1};
      rd68021_pkg::CPUS_BKPT:
        // The breakpoint number on A4-A2.
        cpu_space_addr = {12'h000, rd68021_pkg::CPUS_BKPT, 11'h000,
                          req_cpuaddr[2:0], 2'b00};
      rd68021_pkg::CPUS_ACCESS:
        // UM figure 9-13: the access-level control registers are at byte
        // offsets $00 to $5C, which is A7-A0 -- not the A15-A8 the other types
        // put their field on.
        cpu_space_addr = {12'h000, rd68021_pkg::CPUS_ACCESS, 8'h00,
                          req_cpuaddr};
      rd68021_pkg::CPUS_COPROC:
        // UM figure 7-3: the CpID on A15-A13 and the interface register on
        // A4-A0, "address lines not specified above are 0".
        cpu_space_addr = {12'h000, rd68021_pkg::CPUS_COPROC, req_cpuaddr[7:5],
                          8'h00, req_cpuaddr[4:0]};
      default:
        cpu_space_addr = {12'h000, req_cpuspace, req_cpuaddr, 8'h00};
    endcase
  end

  always_comb begin
    if (take_rst) begin
      next_addr = rst_addr;
      next_rem  = rst_bytes;
      next_fc   = rst_fc;
      next_rw   = rst_rw;
      next_rmc  = rst_rmc;
    end else if (take_req) begin
      next_addr = (req_fc == rd68021_pkg::FC_CPU) ? cpu_space_addr : req_addr;
      next_rem  = req_bytes;
      next_fc   = req_fc;
      next_rw   = (req_kind != rd68021_pkg::CT_WRITE);
      next_rmc  = req_rmc;
    end else if (take_fetch) begin
      next_addr = {fetch_addr[31:2], 2'b00};  // always long-word aligned
      next_rem  = 3'd4;
      next_fc   = fetch_fc;
      next_rw   = 1'b1;
      next_rmc  = 1'b0;
    end else if (st_n == rd68021_pkg::ST_S5) begin
      // Continuing a multi-cycle operand on the edge that ends S5. op_addr and
      // op_rem are updated by this same edge, so what the next cycle must carry
      // is the residual *after* this transfer, not before it.
      next_addr = op_addr + {29'd0, xfer_done};
      next_rem  = op_rem - xfer_done;
      next_fc   = op_fc;
      next_rw   = op_rw;
      next_rmc  = op_rmc;
    end else begin
      // Re-entering S0 from anywhere else -- which means a retry (UM 5.5.2,
      // "retries the previous cycle using the same access information"). The
      // residual is already whatever the faulted cycle left it as, and it must
      // NOT be advanced again: xfer_done is only meaningful while the cycle that
      // produced it is still current, and by now term_rty has been cleared, so
      // adding it here would retry at the wrong address with a residual of zero.
      next_addr = op_addr;
      next_rem  = op_rem;
      next_fc   = op_fc;
      next_rw   = op_rw;
      next_rmc  = op_rmc;
    end
  end

  logic [2:0] this_n;
  always_comb begin
    this_n = (next_rem > 3'd4) ? 3'd4 : next_rem;
  end

  logic [1:0] this_siz;
  always_comb begin
    unique case (this_n)
      3'd1:    this_siz = rd68021_pkg::SIZ_BYTE;
      3'd2:    this_siz = rd68021_pkg::SIZ_WORD;
      3'd3:    this_siz = rd68021_pkg::SIZ_3BYTE;
      default: this_siz = rd68021_pkg::SIZ_LONG;
    endcase
  end

  // A faulted operand finishes too: the sequencer has to be unstalled either way,
  // and req_fault is what tells it which happened.
  assign op_finishing  = op_active && (st_n == rd68021_pkg::ST_S5)
                         && !term_rty
                         && ((op_rem == xfer_done) || term_err);
  assign op_continuing = op_active && !op_finishing;

  // Combinational, and true throughout S5: the operand completes at the rising
  // edge that ends S5, which gives the sequencer half a clock to present the next
  // request. That half clock is the design's tightest path, by construction.
  assign req_last   = op_finishing && !op_isfetch && !op_posted;
  assign fetch_last = op_finishing &&  op_isfetch;

  // ==========================================================================
  // Rising-edge domain
  // ==========================================================================
  // ==========================================================================
  // The arbiter, on rst_n alone. UM 5.7: bus arbitration requests are
  // recognised "during normal processing, RESET assertion, HALT assertion, and
  // even when the processor has halted due to a double bus fault" -- so the
  // RESET pin, which resets everything else in this unit, does not reset it.
  // rst_n, which is not an MC68020 pin, does: arbitration stays off under it.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      arb   <= rd68021_pkg::ARB_IDLE;
      hiz_q <= 1'b0;
    end else begin
      arb <= arb_nxt;
      // "If T is true, the address, data, and control buses are placed in the
      // high-impedance state after the next rising edge following the negation
      // of AS and RMC" -- UM 5.7.1.4. Registered on the way up, so the release
      // waits for that edge; combinational on the way down, because "the bus
      // control signals (controlled by T) are driven by the processor
      // immediately following a state change when bus mastership is returned".
      hiz_q <= arb_t_of(arb_nxt) && !as_win && !rmc_hold;
    end
  end

  // The bus engine, which the RESET pin resets: "resetting the processor
  // causes any bus cycle in progress to terminate as if DSACK1/DSACK0 or BERR
  // had been asserted" (UM 5.8).
  always_ff @(posedge clk or negedge eng_rst_n) begin
    if (!eng_rst_n) begin
      st_p       <= rd68021_pkg::ST_IDLE;
      op_active  <= 1'b0;
      op_addr    <= '0;
      op_rem     <= '0;
      op_fc      <= '0;
      op_rw      <= 1'b1;
      op_rmc     <= 1'b0;
      op_first   <= 1'b1;
      op_isfetch <= 1'b0;
      op_cpflt   <= 1'b0;
      op_data    <= '0;
      cyc_addr   <= '0;
      cyc_fc     <= '0;
      cyc_siz    <= rd68021_pkg::SIZ_LONG;
      cyc_n      <= '0;
      cyc_rw     <= 1'b1;
      req_ack    <= 1'b0;
      req_end_q  <= rd68021_pkg::CE_NONE;
      rst_pend_q <= 1'b0;
      rst_post_q <= 1'b0;
      op_posted  <= 1'b0;
      req_taken  <= 1'b0;
      req_fault_post <= 1'b0;
      fetch_ack  <= 1'b0;
      rdata_q    <= '0;
      frdata_q   <= '0;
      req_fault    <= 1'b0;
      req_fault_wr <= 1'b0;
      fetch_fault  <= 1'b0;
      rmc_hold   <= 1'b0;
      halt_hold  <= 1'b0;
      ecs_q      <= 1'b0;
      ocs_q      <= 1'b0;
      doe_q      <= 1'b0;
    end else begin
      st_p      <= st_p_nxt;
      req_ack   <= 1'b0;
      req_taken <= 1'b0;

      if (rst_op_valid) begin
        rst_pend_q <= 1'b1;
        rst_post_q <= rst_post;
      end else if (take_rst && (st_p_nxt == rd68021_pkg::ST_S0))
        rst_pend_q <= 1'b0;
      else if (rst_done) begin
        rst_pend_q <= 1'b0;
        // A posted microword is satisfied by being taken, not acknowledged; an
        // acknowledge would be read by the microword after it.
        req_ack    <= !req_post;
        req_taken  <= req_post;
        req_end_q  <= rd68021_pkg::CE_DSACK;
        rdata_q    <= {8'd0, rst_dob};
      end else if (rst_pend_q && rst_post_q && (rst_bytes == 3'd0))
        // The handler wrote it -- UM 6.2.2 -- and there is nothing to run.
        rst_pend_q <= 1'b0;
      else if (rst_cancel && !rst_post_q)
        rst_pend_q <= 1'b0;

      fetch_ack <= 1'b0;
      req_fault    <= 1'b0;
      req_fault_wr <= 1'b0;
      req_fault_post <= 1'b0;
      fetch_fault  <= 1'b0;

      halt_hold <= (st_p_nxt == rd68021_pkg::ST_HALT);

      // ECS and OCS from the rising edge entering S0 (specification 6A); write
      // data from the rising edge entering S2 to the one that ends S5 (UM 5.3.2
      // state 2, specification 23). cyc_rw is already this cycle's at S2.
      ecs_q <= (st_p_nxt == rd68021_pkg::ST_S0);
      ocs_q <= (st_p_nxt == rd68021_pkg::ST_S0) && first_now;
      doe_q <= !cyc_rw && ((st_p_nxt == rd68021_pkg::ST_S2)
                           || (st_p_nxt == rd68021_pkg::ST_S4)
                           || (st_p_nxt == rd68021_pkg::ST_WH));

      // The rising edge that ends S5. The cycle is over: take the bytes it moved
      // and advance the residual. Every register the operand owns is written
      // here and in the S0 arm below, both in this one block -- a register
      // written from both edge domains is two conflicting drivers, which is a
      // defect `make lint` now fails on.
      if (st_n == rd68021_pkg::ST_S5) begin
        op_first <= 1'b0;
        if (op_rw) op_data <= rd_merged;
        op_addr <= op_addr + {29'd0, xfer_done};
        op_rem  <= op_rem - xfer_done;
        if (op_finishing) begin
          op_active <= 1'b0;
          op_first  <= 1'b1;
          if (op_isfetch) begin
            fetch_ack   <= 1'b1;
            fetch_fault <= term_err;
            if (op_rw) frdata_q <= rd_merged[31:0];
          end else begin
            // A posted write is acknowledged to nobody.
            req_ack      <= !op_posted;
            req_end_q    <= end_now;
            // A bus error on a CPU-SPACE cycle is not a bus error. UM 6.1.9
            // makes one on an interrupt acknowledge the spurious interrupt, and
            // UM 5.4.2 makes one on a breakpoint acknowledge an illegal
            // instruction; the microcode reads it off the end code and decides.
            // Raising a fault here as well would take the bus error exception
            // instead, and the spurious interrupt would be unreachable.
            req_fault    <= term_err && ((op_fc != rd68021_pkg::FC_CPU)
                                         || op_cpflt);
            req_fault_wr <= term_err && ((op_fc != rd68021_pkg::FC_CPU)
                                         || op_cpflt)
                                     && !op_rw;
            req_fault_post <= term_err && op_posted;
            if (op_rw) rdata_q <= rd_merged;
          end
        end
      end

      // Entering S0: latch everything the pins will carry for this whole cycle,
      // and start a new operand if this is the first cycle of one. This arm runs
      // after the one above in the same edge when a cycle follows immediately,
      // which is why next_addr and next_rem are written to see the post-transfer
      // residual.
      if (st_p_nxt == rd68021_pkg::ST_S0) begin
        rmc_hold <= next_rmc;
        cyc_addr <= next_addr;
        cyc_fc   <= next_fc;
        cyc_siz  <= this_siz;
        cyc_n    <= this_n;
        cyc_rw   <= next_rw;

        if (take_rst || take_req || take_fetch) begin
          op_active  <= 1'b1;
          op_addr    <= next_addr;
          op_rem     <= next_rem;
          op_fc      <= next_fc;
          op_rw      <= next_rw;
          op_rmc     <= next_rmc;
          op_first   <= 1'b1;
          op_isfetch <= take_fetch;
          // Posted: the operand RTE reruns by itself, or a posted request --
          // which may be taking a hand-back of its own.
          op_posted  <= take_rst ? (rst_post_q || req_post)
                                 : (take_req && req_post);
          req_taken  <= req_post && (take_req || (take_rst && !rst_post_q));
          // An operand RTE hands back in CPU space can only be a coprocessor
          // access that faulted, so it faults again if it has to.
          op_cpflt   <= take_rst ? 1'b1 : (take_req && req_cpfault);
          // A restarted operand keeps what it had already transferred: the
          // residual says how much is left, and the buffer holds the rest.
          // A read starts from nothing. Its bytes are gathered right justified
          // into this register, and a read of fewer than four bytes leaves the
          // rest as they started -- which, taken from the request's write data,
          // was whatever the requesting microword's ALU was producing. That was
          // always zero until a read began to compute its own result.
          if (take_rst)        op_data <= {8'd0, rst_dob};
          else if (take_fetch) op_data <= '0;
          else if (next_rw)    op_data <= '0;
          else                 op_data <= req_wdata;
        end
      end else if ((st_p_nxt == rd68021_pkg::ST_IDLE) && !req_rmc) begin
        // Nothing locked is pending and the bus is going idle, so let go of RMC
        // rather than blocking arbitration until the next cycle happens along.
        rmc_hold <= 1'b0;
      end
    end
  end

  // ==========================================================================
  // Falling-edge domain
  //
  // Two things happen here and nowhere else: the termination inputs are sampled
  // at the end of S2 (UM 5.3.1 state 2, "concurrently, the selected device asserts
  // DSACK1/DSACK0"; state 3, "as long as at least one is recognized by the end of
  // S2"), and the read data is latched at the end of S4.
  //
  // DSACK1 and DSACK0 are captured by the same flop pair on the same edge and
  // decoded afterwards. Specification 31A allows 15 ns of skew between them at
  // 16.67 MHz; sampling them independently would let a 32-bit port present
  // transiently as an 8-bit one, and the operand engine would assemble the wrong
  // bytes with no error anywhere.
  // ==========================================================================
  // The six acceptable terminations -- UM Table 5-8, with the case numbers the
  // manual gives them. The table indexes on two samples a clock apart, "asserted
  // on rising edge of state n" and "n+2"; here those are the falling edge
  // entering S3 (the end of S2) and the falling edge entering S5 (the end of S4).
  //
  //   1  DSACK, no BERR, no HALT          normal
  //   2  HALT at or before DSACK          normal, then halt
  //   3  BERR in lieu of / at / before    bus error
  //   4  BERR one state pair after DSACK  bus error, deferred -- the late window
  //   5  BERR and HALT in lieu of / at / before   retry
  //   6  BERR and HALT after DSACK        retry, deferred
  //
  // Cases 4 and 6 are the ones worth being careful about. On the MC68010 project
  // the equivalent late assertion was detected and then never delivered, because
  // the late path set an end code without raising the fault; the exception was
  // simply not taken. Here the late sample writes term_err and term_rty, which is
  // the same place the early sample writes them.
  logic berr_s, halt_s, avec_s;
  // The cycle under way is an interrupt acknowledge: CPU space, type $F on
  // A19-A16 -- UM figure 5-31. Both were latched at S0 and hold for the cycle.
  logic cyc_iack;
  assign cyc_iack = (cyc_fc == rd68021_pkg::FC_CPU)
                 && (cyc_addr[19:16] == rd68021_pkg::CPUS_IACK);
  logic early_q;
  assign berr_s = ~berr_n_i;
  // AVEC is active low and is sampled on the same edge as DSACK. Only an
  // interrupt acknowledge cycle means anything by it -- UM 6.1.9.
  assign avec_s = avec_n_i;
  assign halt_s = ~halt_n_i;

  // "The BG signal transitions on the falling edge of the clock after a state
  // is reached during which G changes" -- UM 5.7.1.4. With the arbiter, on
  // rst_n alone: arbitration goes on under the RESET pin (UM 5.7).
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) bg_n_o <= 1'b1;
    else        bg_n_o <= ~arb_g_of(arb);
  end

  always_ff @(negedge clk or negedge eng_rst_n) begin
    if (!eng_rst_n) begin
      st_n      <= rd68021_pkg::ST_IDLE;
      dsack_q   <= rd68021_pkg::DSACK_WAIT;
      term_q    <= 1'b0;
      term_err  <= 1'b0;
      term_rty  <= 1'b0;
      term_avc  <= 1'b0;
      term_hlt  <= 1'b0;
      d_latched <= '0;
      early_q   <= 1'b0;
      as_win    <= 1'b0;
      ds_q      <= 1'b0;
      retry_clr_q <= 1'b1;
    end else begin
      st_n <= st_n_nxt;

      // BERR and HALT both negated, for the end of a retry -- see retry_clear.
      retry_clr_q <= berr_n_i && halt_n_i;

      // AS from the falling edge entering S1 to the one entering S5. DS on a
      // read follows it (UM 5.3.1 state 1, "the processor also asserts DS
      // during S1"); on a write it waits until S3, "indicating that the data on
      // the data bus is stable" (UM 5.3.2 state 3).
      as_win <= as_set(st_n_nxt);
      ds_q   <= cyc_rw ? as_set(st_n_nxt)
                       : ((st_n_nxt == rd68021_pkg::ST_S3)
                          || (st_n_nxt == rd68021_pkg::ST_WL));

      // Decided on the edge entering S5, which is where Table 5-8's second
      // sample is taken: after it nothing can turn this cycle into a bus error
      // or a retry, and the residual after it is known. Everything the sequencer
      // does with it is a half clock -- the early retire, doc/timing-divergences.md.
      early_q <= (st_n_nxt == rd68021_pkg::ST_S5) && op_active && !op_isfetch
              && !op_posted
              && !term_err && !term_rty && !berr_s && (op_rem == xfer_n);


      // The sample: entering S3, and again at every ST_WL while waiting.
      //
      // The cycle terminates on the edge either DSACK is first recognised on
      // (UM 5.3.1 state 3), but the port size is not taken here: specification
      // 31A lets the second DSACK trail the first, by up to 15 ns at 16.67 MHz,
      // and footnote 3 asks only that one of them meet the setup time. The
      // device holds both until it sees AS negate, so they are taken on the
      // edge that latches the data, below.
      if (st_n_nxt == rd68021_pkg::ST_S3 || st_n_nxt == rd68021_pkg::ST_WL) begin
        if (berr_s && halt_s) begin
          term_q   <= 1'b1;  term_rty <= 1'b1;               // case 5
        end else if (berr_s) begin
          term_q   <= 1'b1;  term_err <= 1'b1;               // case 3
        end else if (!avec_s && cyc_iack) begin
          // UM 6.1.9 and table 5-8: AVEC terminates an interrupt acknowledge
          // cycle in place of DSACK and says "use the autovector for this
          // level". It is sampled on the same edge as DSACK. On any other
          // cycle it is not a termination at all -- UM 5.4.1, "AVEC is ignored
          // during all other bus cycles" -- and the cycle waits for DSACK: a
          // board that ties AVEC low to autovector everything must still get
          // its wait states. Ending the cycle on it lost the writes of a
          // Sun-3/60 replica's PROM (doc/bugs-found.md).
          term_q   <= 1'b1;  term_avc <= 1'b1;
        end else if (dsack_n_i != rd68021_pkg::DSACK_WAIT) begin
          term_q   <= 1'b1;  term_hlt <= halt_s;             // cases 1 and 2
        end else begin
          term_q   <= 1'b0;
        end
      end

      // Entering S5: latch the read data, and take the second of Table 5-8's two
      // samples. It applies only to a cycle that terminated normally -- a cycle
      // already in error does not get a second verdict.
      if (st_n_nxt == rd68021_pkg::ST_S5) begin
        d_latched <= d_i;
        dsack_q   <= dsack_n_i;
        if (!term_err && !term_rty) begin
          if (berr_s && halt_s)   term_rty <= 1'b1;          // case 6
          else if (berr_s)        term_err <= 1'b1;          // case 4
        end
      end

      // The rising edge that ends S5 has consumed the verdict; clear it for the
      // next cycle. A retried cycle keeps nothing either: UM 5.5.2 reruns it from
      // the same access information, and the rerun takes its own samples.
      if (st_n == rd68021_pkg::ST_S5) begin
        term_q   <= 1'b0;
        term_err <= 1'b0;
        term_rty <= 1'b0;
        term_avc <= 1'b0;
        term_hlt <= 1'b0;
      end
    end
  end

  // ==========================================================================
  // Pins
  //
  // Each is written as the manual states it, in terms of the two state
  // registers, and each comes from a flip-flop -- see "The strobes" above.
  // ==========================================================================

  // ECS: one half clock at the start of every bus cycle. Asserted on the rising
  // edge entering S0 (specification 6A) and negated on the falling edge entering
  // S1 (specification 12A), which is the whole of specification 10's width.
  // ecs_q is set only for that half clock, and the one edge in it at which st_n
  // moves is the one that takes it into S1, so the AND moves once.
  assign ecs_n_o = ~(ecs_q && (st_n != rd68021_pkg::ST_S1));

  // OCS: identical, but only for the first bus cycle of an operand (UM 5.1.1).
  assign ocs_n_o = ~(ocs_q && (st_n != rd68021_pkg::ST_S1));

  assign as_n_o = ~as_win;

  assign ds_n_o = ~ds_q;

  // DBEN, active low (UM table 3-2), from rd68021_dedge_ff: its value after
  // each edge is dben_of() of the states after that edge. At the rising edge
  // into S0 it is negated whatever the direction, which is what lets the new
  // cycle's R/W, latched on that same edge, not matter there.
  logic dben_q, dben_rise, dben_fall, dben_tp, dben_tn;
  always_comb begin
    if (st_p_nxt == rd68021_pkg::ST_S0) dben_rise = 1'b0;
    else                                dben_rise = dben_of(st_p_nxt, st_n, cyc_rw);
    dben_fall = dben_of(st_p, st_n_nxt, cyc_rw);
  end
  assign dben_tp = dben_rise ^ dben_q;
  assign dben_tn = dben_fall ^ dben_q;

  rd68021_dedge_ff #(.RESET_VAL (1'b0)) u_dben (
      .clk (clk), .rst_n (eng_rst_n), .toggle_p (dben_tp), .toggle_n (dben_tn),
      .q (dben_q));

  assign dben_n_o = ~dben_q;

  assign fc_o    = cyc_fc;
  assign a_o     = cyc_addr;
  assign siz_o   = cyc_siz;
  assign rw_o    = cyc_rw;
  // UM 5.5.2 makes RMC a qualifier over a RUN of cycles, not a property of one:
  // it is asserted for the first cycle of a read-modify-write and stays
  // asserted until the last one has finished, INCLUDING the clocks between
  // them, because that is the whole point -- nothing else may get at the
  // location in the gap. `rmc_hold` is exactly that run, and is already what
  // inhibits arbitration.
  assign rmc_n_o = ~rmc_hold;
  assign d_o     = wr_lanes;

  // Bus relinquish. Combinational on the way down so that the processor drives
  // again "immediately following a state change when bus mastership is returned".
  assign bus_granted = hiz_q && arb_t_of(arb);

  // Output enables.
  //
  // UM 5.8: "during the reset period, the entire bus three-states (except for
  // non-three-statable signals, which are driven to their inactive state)".
  // Both resets count: rst_n, the power-on initialisation that is not an
  // MC68020 pin (doc/pinout.md), and the RESET pin from outside -- every
  // enable below drops with eng_rst_n, which is either.
  //
  // The address group is driven from S0 and released at the rising edge that ends
  // S5 (specification 7) -- except while halted, where UM 5.5.3 says A31-A0,
  // FC2-FC0, SIZ1/SIZ0 and R/W "remain in the same state", driven rather than
  // released. That is the one thing that distinguishes a halted bus from an idle
  // one on these pins.
  logic cyc_drive;
  assign cyc_drive = (st_p != rd68021_pkg::ST_IDLE);

  logic addr_drive;
  assign addr_drive = ADDR_HIZ_BETWEEN_CYCLES ? (cyc_drive || halt_hold) : 1'b1;

  assign a_oe   = addr_drive && !bus_granted && eng_rst_n;
  assign fc_oe  = a_oe;
  assign siz_oe = a_oe;
  // ... and it is DRIVEN for the whole of that run as well. The address may go
  // to high impedance between cycles -- ADDR_HIZ_BETWEEN_CYCLES -- and if RMC
  // followed it there, an external wrapper would three-state the one signal
  // whose job is to stay asserted in the gap.
  assign rmc_oe = (addr_drive || rmc_hold) && !bus_granted && eng_rst_n;

  // Write data is driven from the rising edge entering S2 and held through S5.
  // "When the processor completes a bus cycle with the HALT signal asserted, the
  // data bus is placed in the high-impedance state" -- so no halt term here.
  assign d_oe = doe_q && !bus_granted && eng_rst_n;

  // The control group is driven except on relinquish and reset. UM 5.5.3 is explicit that
  // halting negates these rather than releasing them, and 5.7.1.4's T is what
  // releases them.
  assign as_oe   = !bus_granted && eng_rst_n;
  assign ds_oe   = !bus_granted && eng_rst_n;
  assign rw_oe   = !bus_granted && eng_rst_n;
  assign dben_oe = !bus_granted && eng_rst_n;

  // RESET and HALT are open drain: the output value is a constant zero and the
  // enable is what asserts them. UM 5.5.4: on a double bus fault "the processor
  // halts and asserts HALT", and only an external reset restarts it.
  assign reset_n_o  = 1'b0;
  assign reset_n_oe = rsto_q;
  assign halt_n_o   = 1'b0;
  assign halt_n_oe  = dbf;

  // ==========================================================================
  // Back to the sequencer
  // ==========================================================================
  assign req_rdata   = rdata_q;
  assign req_early   = early_q;
  assign fetch_rdata = frdata_q;

  // How the cycle ended, as the samples of Table 5-8 leave it. This is the live
  // verdict, and it lives only until the rising edge that ends S5 consumes it.
  always_comb begin
    if (term_err)                            end_now = rd68021_pkg::CE_BERR;
    else if (term_rty)                       end_now = rd68021_pkg::CE_RETRY;
    else if (term_avc)                       end_now = rd68021_pkg::CE_AVEC;
    else if (term_hlt)                       end_now = rd68021_pkg::CE_HALT;
    else if (term_q)                         end_now = rd68021_pkg::CE_DSACK;
    else                                     end_now = rd68021_pkg::CE_NONE;
  end

  // What the SEQUENCER is told, which has to outlive it.
  //
  // The verdict is cleared on the falling edge that ends S5 and `req_ack` is
  // raised on the rising edge inside it, so the sequencer -- which retires on
  // the rising edge AFTER it sees the acknowledge -- looked at a verdict that
  // had already been cleared half a clock earlier. Every microword that tests
  // how a cycle ended read CE_NONE: the interrupt acknowledge never saw its
  // AVEC and never saw its bus error, so the autovector and the spurious
  // interrupt were both unreachable, and a vectored interrupt was the only
  // one that worked. Latched with `req_ack`, it holds until the next operand
  // finishes, which is what lets `exc_irq` test AVEC on one microword and BERR
  // on the next.
  assign req_end = req_end_q;
  assign req_dsack    = dsack_q;

  // ==========================================================================
  // The fault snapshot -- doc/ssw.md
  //
  // Everything the fault frame says about the faulted access, latched on the
  // clock the fault is recognised. It has to be a latch and not a view of the
  // live operand registers, because the frame is BUILT BY BUS CYCLES: by the
  // time the special status word reaches +$0A of the frame, four writes have
  // gone through the same operand engine and op_addr, op_rem and op_data are
  // about the last of them.
  //
  // The address is the operand's residual address -- the next byte still to
  // transfer -- and not the address the microword asked for. UM 6.2.2 has the
  // handler "transfer the properly sized data from the data output buffer on
  // the stack frame to the location indicated by the data fault address", and
  // what is left to transfer is what it has to move.
  // ==========================================================================
  always_ff @(posedge clk or negedge eng_rst_n) begin
    if (!eng_rst_n) begin
      flt_addr  <= '0;
      flt_bytes <= 3'd0;
      flt_fc    <= 3'd0;
      flt_rw    <= 1'b1;
      flt_rmc   <= 1'b0;
      flt_dob   <= '0;
      flt_dib   <= '0;
    end else if (st_n == rd68021_pkg::ST_S5 && op_finishing && !op_isfetch
                 && term_err && ((op_fc != rd68021_pkg::FC_CPU) || op_cpflt)) begin
      flt_addr  <= op_addr;
      flt_bytes <= op_rem;
      flt_fc    <= op_fc;
      flt_rw    <= op_rw;
      flt_rmc   <= op_rmc;
      // The two buffers are the same register, because an operand is either
      // being read or being written and op_data is whichever applies. They are
      // separate frame fields, and separate here, so that a handler reads the
      // one the direction makes meaningful and RTE writes back only that one.
      flt_dob   <= op_rw ? flt_dob : op_data[31:0];
      flt_dib   <= op_rw ? op_data[31:0] : flt_dib;
    end
  end

  // PRM 6 RESET: "asserts the RSTO signal for 512 clock periods, resetting all
  // external devices". 512 is this part's number -- the MC68000 and the MC68010
  // used 124 -- and the counter is nine bits plus the state bit that qualifies
  // it, so the pin is driven on the 512 clocks in which rsto_q is set.
  //
  // `reset_busy` answers on the same clock the request arrives, before the
  // counter has started. Without that the sequencer's microword would see an
  // idle bus unit and retire immediately; with it, the one clock in which the
  // request is presented and the counter is not yet running is still a busy
  // one. The arming bit is the other half of the same problem at the other end:
  // the request is still asserted on the clock the count expires, and must not
  // be allowed to start it again.
  logic [8:0] rsto_cnt;
  logic       rsto_arm_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsto_cnt   <= 9'd0;
      rsto_q     <= 1'b0;
      rsto_arm_q <= 1'b1;
    end else if (rsto_q) begin
      rsto_arm_q <= 1'b0;
      if (rsto_cnt == 9'd0) rsto_q   <= 1'b0;
      else                  rsto_cnt <= rsto_cnt - 9'd1;
    end else if (reset_req && rsto_arm_q) begin
      rsto_q     <= 1'b1;
      rsto_cnt   <= 9'd511;
      rsto_arm_q <= 1'b0;
    end else if (!reset_req) begin
      rsto_arm_q <= 1'b1;
    end
  end

  assign reset_busy  = rsto_q || (reset_req && rsto_arm_q);

  // ==========================================================================
  // The RESET pin as an input -- UM 5.8 and 6.1.1
  //
  // "The external RESET signal resets the processor and the entire system";
  // when the processor drives it for the RESET instruction, "the processor
  // resets the external devices of the system, and the internal registers of
  // the processor are unaffected". RESET alone does it, and "asserting RESET
  // for 10 clock periods is sufficient for resetting the processor logic".
  //
  // The pin is open drain and this processor drives it for the RESET
  // instruction, so its own pulse comes back on the input. UM 5.8: "an
  // external RESET signal that is asserted to the processor during execution
  // of a RESET instruction must extend beyond the reset period of the
  // instruction by at least eight clock cycles to reset the processor". So the
  // input is not acted on while the instruction drives the pin, nor for
  // RSTO_TAIL clocks after -- the two falling-edge ranks of the synchroniser
  // and one rising edge, with a clock to spare -- and a RESET held on from
  // outside past that resets the processor, inside the eight clocks the
  // manual allows.
  //
  // crst_q is a rising-edge register, and is the reset the rest of the
  // processor sees (`crst`): held for as long as the pin is, and released on a
  // rising edge, after which reset exception processing begins exactly as it
  // does after rst_n (UM 6.1.1). What it resets, and what it leaves alone, is
  // in rd68021_seq and doc/pinout.md.
  //
  // This block and the RESET instruction's counter above are on rst_n alone,
  // and they are why rst_n cannot be the pin: the register that drives RESET
  // out cannot be reset by RESET coming back in, or the instruction would
  // reset its own counter the clock it started.
  // ==========================================================================
  localparam logic [2:0] RSTO_TAIL = 3'd4;
  logic [2:0] rsto_tail_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rsto_tail_q <= 3'd0;
      crst_q      <= 1'b0;
    end else begin
      if (rsto_q)                   rsto_tail_q <= RSTO_TAIL;
      else if (rsto_tail_q != 3'd0) rsto_tail_q <= rsto_tail_q - 3'd1;
      crst_q <= !reset_sync_n && !rsto_q && (rsto_tail_q == 3'd0);
    end
  end

  assign crst = crst_q;
  assign bus_idle    = bus_is_idle;

  // ==========================================================================
  // Inputs this unit does not consume yet. The list shrinks visibly as the design
  // fills in, which is why it is written out rather than waived wholesale.
  // ==========================================================================
  logic unused_biu;
  assign unused_biu = &{1'b1,
                        rst_op_valid, rst_addr, rst_bytes, rst_fc, rst_rw,
                        rst_rmc, rst_dob,
                        fetch_addr[1:0], bus_abort,
                        reset_req, dbf,
                        avec_n_i,
                        op_data[39:32]};

endmodule
