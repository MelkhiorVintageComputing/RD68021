// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 Romain Dolbeau
// Source location: https://github.com/MelkhiorVintageComputing/RD68021

// RD68021 - SystemVerilog MC68020
//
// Instruction fetch unit: the cache holding register, the three-stage instruction
// pipe, and the instruction cache.
//
// UM 1.6 and figure 1-5: "instruction words (instruction operation words and all
// extension words) enter the pipe at stage B and proceed to stages C and D. An
// instruction word is completely decoded when it reaches stage D of the pipe."
// So stage D is the instruction register -- it holds the opcode for the whole
// instruction -- and extension words are read from stage C.
//
// The pipe is therefore stage D, plus a two-deep queue holding C and B:
//
//   CONSUME   pop: C <- B, B <- the next word. D is untouched; an extension word
//             has been eaten.
//   ADV       D <- C, then pop. The instruction is over.
//   FLUSH     everything is emptied and refilled from the address on `pf_addr`.
//
// pc_d is the address of stage D and stg_b_addr the address of stage B, both
// carried as real registers because CONSUME moves one and not the other. UM 6.2
// makes that observable: at an instruction boundary the pipe is sequential and
// the short fault frame derives the stage addresses from the PC, but
// mid-instruction it is not, which is exactly why the long frame carries stage
// B's address at SP+$24.
//
// The queue refills by itself. UM 5.5.1 is what makes that safe: "if a bus error
// occurs on an instruction fetch, the processor does not take the exception until
// it attempts to use that instruction word" -- so a faulted prefetch is recorded
// in the stage's fault bit and becomes an exception only when the sequencer
// reaches it, which is what SSW's FB and FC bits are for.
//
// This is a module rather than part of the sequencer because the architecture
// names its state: SSW FC/FB/RC/RB and frame fields +$0C, +$0E and +$24 make
// stages B and C visible through the fault frame, and every such register has to
// be nameable and restorable. See doc/checkpoint.md.

module rd68021_ifu #(
    parameter int ICACHE_ENTRIES = 0
) (
    input  logic        clk,
    input  logic        rst_n,

    // Prefetch control from the sequencer ------------------------------------
    input  logic  [1:0] pf_op,       // rd68021_ucode_pkg::U_PF_*
    input  logic [31:0] pf_addr,     // the new fetch address on FLUSH
    input  logic        pf_super,    // supervisor or user program space
    output logic        pf_ready,    // stage C holds a word, so ADV or CONSUME may run
    output logic        pf_dvalid,   // stage D holds an instruction word

    // The pipe, as the sequencer and the fault frame see it -------------------
    output logic [15:0] stg_d,
    output logic [15:0] stg_c,
    output logic [15:0] stg_b,
    output logic        stg_c_fault,
    output logic        stg_b_fault,
    output logic        stg_c_rerun,
    output logic        stg_b_rerun,
    // The pipe cannot produce a stage D word and never will: either the word
    // at the front of the queue came from a prefetch that faulted, or the
    // address it would fetch from is odd. UM 6.1.2 and 6.1.3.
    output logic        pf_stuck,
    output logic        pf_odd,
    output logic [31:0] pc_d,
    output logic [31:0] stg_b_addr,

    // Checkpoint port ---------------------------------------------------------
    input  logic        ckpt_save,
    // RTE putting the pipe back out of a fault frame, one field per microword,
    // and then `ckpt_load` to say it is whole again -- doc/checkpoint.md.
    input  logic        ckpt_wr,
    input  logic  [2:0] ckpt_sel,      // rd68021_pkg::CK_*
    input  logic [31:0] ckpt_data,
    input  logic        ckpt_load,
    // ... and until RTE has written the status register it read, no prefetch:
    // UM 6.2.1, a rerun prefetch is in "the program space for the privilege
    // level indicated in the copy of the status register on the stack".
    input  logic        ckpt_hold,
    output logic [31:0] ckpt_pc_fetch,

    // Cache control -----------------------------------------------------------
    input  logic [31:0] cacr,
    input  logic [31:0] caar,
    input  logic  [1:0] cach_op,
    input  logic        cdis_sync_n,

    // To the bus unit ---------------------------------------------------------
    output logic        fetch_valid,
    output logic [31:0] fetch_addr,
    output logic  [2:0] fetch_fc,
    input  logic        fetch_ack,
    input  logic        fetch_last,
    input  logic [31:0] fetch_rdata,
    input  logic        fetch_fault,
    output logic        bus_abort
);

  // ==========================================================================
  // State
  // ==========================================================================
  logic [15:0] d_q, c_q, b_q;
  logic        c_f_q, b_f_q;
  logic        d_v_q;
  logic  [1:0] cnt_q;          // words held in the C/B queue: 0, 1 or 2
  logic [31:0] pc_d_q;
  logic [31:0] fill_q;         // the address of the next word to enter the queue

  // The cache holding register: the last long word fetched, and where it came
  // from. It is NOT checkpointed -- doc/checkpoint.md -- because it is a pure
  // cache: RTE restores it invalid and the next prefetch re-reads it. One bus
  // cycle, never a wrong answer, and sixty-six bits of frame budget back.
  logic [31:0] chr_q;
  logic [29:0] chr_addr_q;
  logic        chr_v_q;
  logic        chr_f_q;
  logic        fetch_pend_q;   // a fetch has been asked for and not yet answered
  logic        discard_q;      // the word in flight is for a stream that is gone

  // ... and the space: the cache tag carries FC2 (UM 4.1), and the fill has to be
  // tagged with the space the long word was READ from, which a flush that changed
  // the privilege level while the fetch was in flight has already moved on from.
  logic        fetch_fc2_q;

  // The address that fetch was issued at. It has to be a register: fill_q moves
  // on as the queue drains, and a combinational fetch_addr would label the long
  // word that comes back with wherever the queue had got to by then. The cache
  // holding register would then answer a hit for an address it does not hold,
  // and the pipe would be served words from somewhere else entirely.
  logic [31:0] fetch_addr_q;

  // Until the first FLUSH the pipe has no address. Reset leaves fill_q at zero,
  // which is the exception vector table, and a pipe that started fetching there
  // would both race the reset vector reads for the bus and fill itself with the
  // vectors. UM 6.1.1 gives it an address; nothing before that does.
  logic        primed_q;

  // ==========================================================================
  // Where the next word comes from
  //
  // A long word holds the word at its own address in bits 31:16 and the word two
  // bytes on in bits 15:0 -- the family is big endian.
  // ==========================================================================
  logic        chr_hit;
  logic [15:0] chr_word;

  assign chr_hit  = chr_v_q && (chr_addr_q == fill_q[31:2]);
  assign chr_word = fill_q[1] ? chr_q[15:0] : chr_q[31:16];

  // UM 6.1.3: "an address error exception occurs when the processor attempts to
  // prefetch an instruction from an odd address ... a bus cycle is not
  // executed". So no cycle is issued, the queue never fills, and the sequencer
  // is left waiting for a word that will never come -- which is where the
  // exception is taken.
  assign pf_odd = primed_q && fill_q[0];

  // Nothing is fetched while RTE is putting the pipe back. The restore is one
  // microword per field and takes a bus cycle each, which is tens of clocks --
  // easily long enough for the queue to fetch a word or two of the HANDLER's
  // instruction stream, push them into stages this is in the middle of
  // restoring, and change the depth the fill point is computed from. Which is
  // what it did: the resumed instruction ran and the one after it was garbage.
  logic ckpt_busy_q;

  // ... nor on the clock the coprocessor writes the scanPC, which empties the
  // queue and moves the fill point: a word pushed or a fetch issued on that
  // same edge would belong to the stream it is abandoning.
  logic scan_now;
  assign scan_now = ckpt_wr && (ckpt_sel == rd68021_pkg::CK_SCAN);

  logic room;
  assign room = primed_q && (cnt_q != 2'd2) && !pf_odd && !ckpt_busy_q
             && !ckpt_hold && !scan_now;

  // A word may also go into a full queue that is giving one up on the same
  // edge -- the 2'b11 arm below. Only the push itself looks at that: the pop
  // depends on the microword retiring, which depends on the bus, and the cache
  // lookup and the fetch request stay on `room` so that none of that reaches
  // them. doc/timing-divergences.md, Phase 3.
  logic do_flush, do_adv, do_consume, do_pop, auto_load;
  logic room_p;
  assign room_p = primed_q && ((cnt_q != 2'd2) || do_pop) && !pf_odd
               && !ckpt_busy_q && !ckpt_hold && !scan_now;

  logic push;
  assign push = room_p && chr_hit;

  // The low word of the holding register is going in, so the long word after
  // it is the one wanted next. The cache is looked up there instead, and a hit
  // reloads the holding register on the same edge -- one word per clock out of
  // the cache rather than two every three.
  logic look_ahead;
  assign look_ahead = room && chr_hit && fill_q[1];

  logic [29:0] cache_la;
  assign cache_la = look_ahead ? fill_q[31:2] + 30'd1 : fill_q[31:2];

  // After a flush stage D is empty and the queue is too, and the first word
  // goes straight into stage D rather than through stage C a clock later. A
  // word from a faulted prefetch does not: its fault is taken at stage C.
  logic bypass;
  assign bypass = push && !d_v_q && (cnt_q == 2'd0) && !chr_f_q && !do_pop;

  // Ask the bus unit for the long word the queue wants next.
  //
  // BOTH terms are needed to drop it, and this is the same rule the sequencer
  // follows on the data port. The bus unit accepts a new request on the very
  // edge the previous operand finishes, so fetch_last covers that edge; and the
  // acknowledge is registered, so the request is still asserted for one clock
  // after it, which fetch_ack covers. Miss either and the same long word is
  // fetched twice -- and the second copy arrives labelled with wherever the
  // queue had got to by then, which serves the pipe words from the wrong
  // address entirely.
  assign fetch_valid = fetch_pend_q && !fetch_last && !fetch_ack;
  assign fetch_addr  = fetch_addr_q;
  assign fetch_fc    = pf_super ? rd68021_pkg::FC_SUPER_PROG
                                : rd68021_pkg::FC_USER_PROG;

  // A hit in the instruction cache never starts an external cycle, so there is
  // nothing to abort. UM 5.2.5 says the part MAY start the cycle in parallel with
  // the lookup and abort it before AS, which shows as an ECS with no AS after it;
  // here the lookup is combinational and decides before the bus unit is asked, so
  // it never does. doc/divergences.md.
  assign bus_abort = 1'b0;

  // ==========================================================================
  // The instruction cache -- UM section 4
  //
  // Consulted at exactly one point: where the queue wants a long word that the
  // cache holding register does not have, which is where the bus would otherwise
  // be asked for it. A hit loads the holding register from the cache, and the
  // queue then drains it exactly as it drains a long word from the bus -- the
  // pipe cannot tell the two apart, which is what makes the cache architecturally
  // invisible (UM 4.1: data accesses are never cached, so nothing but the
  // instruction stream could see it anyway).
  //
  // Enabled by CACR's E bit, and disabled regardless of it while CDIS is asserted
  // (UM 4.3). Disabled means neither looked up nor filled; it does NOT mean
  // emptied -- "if the cache is reenabled, the previously valid entries remain
  // valid and may be used" (UM 4.3.1).
  // ==========================================================================
  logic        cache_on;
  logic        cache_hit;
  logic [31:0] cache_rdata;
  logic        cache_fill;
  logic        inv_all, inv_one;

  assign cache_on = cacr[rd68021_pkg::CACR_E] && cdis_sync_n;

  // UM 4.1: the entry is written "unless the F-bit in the CACR is set". And a
  // long word whose cycle ended in a bus error is not an instruction at all: the
  // pipe carries it with its fault bit, and it must not outlive that in the cache.
  // A word for a stream a flush abandoned is still the right word for its own
  // address, but it is not taken into the holding register either, and filling
  // the cache with it would be the only trace it left -- so it is dropped whole.
  assign cache_fill = fetch_ack && !discard_q && !fetch_fault
                   && cache_on && !cacr[rd68021_pkg::CACR_F];

  // CACR's C and CE, pulsed by the MOVEC that sets them. CE clears "regardless of
  // the states of the E and F bits" (UM 4.3.1), and so does C.
  assign inv_all = (cach_op == 2'b01);
  assign inv_one = (cach_op == 2'b10);

  generate
    if (ICACHE_ENTRIES > 0) begin : g_cache
      logic cache_lhit;
      rd68021_icache #(.ENTRIES (ICACHE_ENTRIES)) u_icache (
          .clk     (clk),
          .rst_n   (rst_n),
          .la      (cache_la),
          .lfc2    (pf_super),
          .hit     (cache_lhit),
          .rdata   (cache_rdata),
          .fill    (cache_fill),
          .fa      (fetch_addr_q[31:2]),
          .ffc2    (fetch_fc2_q),
          .fdata   (fetch_rdata),
          .inv_all (inv_all),
          .inv_one (inv_one),
          .inv_la  (caar[31:2]));
      assign cache_hit = cache_on && cache_lhit;
    end else begin : g_nocache
      // No cache. CACR and CAAR still exist and read back what was written, and
      // CDIS is still sampled; with nothing behind them they change nothing,
      // which is what a disabled cache does anyway.
      assign cache_hit   = 1'b0;
      assign cache_rdata = 32'd0;
      logic unused_nocache;
      assign unused_nocache = &{1'b1, cache_fill, inv_all, inv_one, caar,
                                fetch_fc2_q};
    end
  endgenerate

  // ==========================================================================
  // The pipe
  // ==========================================================================
  assign do_flush   = (pf_op == rd68021_ucode_pkg::U_PF_FLUSH);
  assign do_consume = (pf_op == rd68021_ucode_pkg::U_PF_CONSUME);

  // Stage D fills itself. After a flush -- and after reset -- the pipe is empty,
  // and nothing in the microcode loads the first instruction word: the microword
  // that would is the one waiting for it. So an empty stage D takes the front of
  // the queue by itself, which is the same motion as ADV and is written as one.
  // ... and it does not take a word that came from a prefetch that faulted.
  // UM 6.2.1's FC bit is "the processor attempted to use stage C and found it
  // to be marked invalid", so the check belongs at stage C and stage D never
  // holds a faulted word at all -- which is why the manual has no bit for one.
  // Nor while RTE is putting the pipe back: stage D may come back empty, and
  // stage C is not the frame's until the walk reaches it.
  assign auto_load  = !d_v_q && (cnt_q != 2'd0) && !do_flush && !c_f_q
                   && !ckpt_busy_q;

  assign pf_stuck   = pf_odd || (!d_v_q && (cnt_q != 2'd0) && c_f_q);
  assign do_adv     = (pf_op == rd68021_ucode_pkg::U_PF_ADV) || auto_load;
  assign do_pop     = do_adv || do_consume;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d_q          <= '0;
      c_q          <= '0;
      b_q          <= '0;
      c_f_q        <= 1'b0;
      b_f_q        <= 1'b0;
      d_v_q        <= 1'b0;
      cnt_q        <= 2'd0;
      pc_d_q       <= '0;
      fill_q       <= '0;
      chr_q        <= '0;
      chr_addr_q   <= '0;
      chr_v_q      <= 1'b0;
      chr_f_q      <= 1'b0;
      fetch_pend_q <= 1'b0;
      fetch_addr_q <= '0;
      fetch_fc2_q  <= 1'b0;
      discard_q    <= 1'b0;
      primed_q     <= 1'b0;
      ckpt_busy_q  <= 1'b0;
    end else begin
      // ------------------------------------------------------------------
      // The fetch in flight
      // ------------------------------------------------------------------
      if (fetch_ack) begin
        fetch_pend_q <= 1'b0;
        discard_q    <= 1'b0;
        // A word answering a request the flush threw away belongs to the
        // instruction stream that no longer exists. Taking it would put a word
        // from the OLD stream into the pipe with the NEW stream's address on
        // it, which is what it did. See doc/bugs-found.md.
        if (!discard_q) begin
          chr_q      <= fetch_rdata;
          chr_addr_q <= fetch_addr_q[31:2];
          chr_v_q    <= 1'b1;
          chr_f_q    <= fetch_fault;
        end
      end else if (room && !chr_hit && cache_hit
                   && (!fetch_pend_q || discard_q)) begin
        // A hit. It may be taken while a fetch the pipe has abandoned is still
        // in flight -- a branch to code the cache holds does not wait for the
        // answer to a prefetch down the path not taken -- because that answer
        // is discarded when it lands and so cannot overwrite this.
        chr_q      <= cache_rdata;
        chr_addr_q <= fill_q[31:2];
        chr_v_q    <= 1'b1;
        chr_f_q    <= 1'b0;
      end else if (look_ahead && cache_hit && (!fetch_pend_q || discard_q)) begin
        // The next long word, out of the cache, while this one's last word is
        // pushed. A bus answer landing on the same edge takes precedence above,
        // and the lookahead simply waits for the ordinary path.
        chr_q      <= cache_rdata;
        chr_addr_q <= cache_la;
        chr_v_q    <= 1'b1;
        chr_f_q    <= 1'b0;
      end else if (!fetch_pend_q && room && !chr_hit) begin
        fetch_pend_q <= 1'b1;
        fetch_addr_q <= {fill_q[31:2], 2'b00};
        fetch_fc2_q  <= pf_super;
      end

      // ------------------------------------------------------------------
      // RTE putting the pipe back -- UM 6.2.1 and 6.2.3
      //
      // The queue DEPTH is not in the frame; the rerun bits are, and they say
      // which stages RTE still owes a word. Restoring the depth from them is
      // what makes "the processor may execute a bus cycle to prefetch the
      // instruction word for stage C of the pipe (if it is required)" happen by
      // itself: a queue with room asks the bus unit for the next long word, so
      // a stage the frame says is missing is fetched by the ordinary refill and
      // there is no separate rerun path to get wrong.
      // ------------------------------------------------------------------
      if (ckpt_wr) begin
        unique case (ckpt_sel)
          rd68021_pkg::CK_STG_D: d_q    <= ckpt_data[15:0];
          rd68021_pkg::CK_STG_C: c_q    <= ckpt_data[15:0];
          rd68021_pkg::CK_STG_B: b_q    <= ckpt_data[15:0];
          rd68021_pkg::CK_PC_D:  pc_d_q <= ckpt_data;
          // Frame +$24 is the address of the STAGE B word; the fill point is
          // two beyond it once the queue is two deep, which is the same
          // relation stg_b_addr reads the other way. The depth has already been
          // restored, because CK_FLAGS comes first.
          rd68021_pkg::CK_FILL:
            fill_q <= ckpt_data - 32'd2 + {29'd0, cnt_q, 1'b0};
          rd68021_pkg::CK_SCAN: begin
            // UM 7.4.17: "the MC68020 discards any instruction words that have
            // been prefetched beyond the current scanPC location ... then
            // refills the instruction pipe from the scanPC address". A flush
            // that leaves stage D alone, and a prefetch in flight is thrown
            // away when it lands, as a flush does it.
            cnt_q   <= 2'd0;
            fill_q  <= ckpt_data;
            d_v_q   <= 1'b1;
            c_f_q   <= 1'b0;
            b_f_q   <= 1'b0;
            chr_v_q <= 1'b0;
            if (fetch_pend_q && !fetch_ack) discard_q <= 1'b1;
          end
          default: begin                       // CK_FLAGS
            // Only the rerun bits. UM 6.2.1 makes FC and FB a RECORD of what
            // went wrong, for the handler to read, and RC and RB the statement
            // of what is still to be done -- "if the RC bit is clear, the words
            // on the stack for stage C of the pipe are accepted as valid",
            // whatever FC says, and the handler is told not to touch FC. So the
            // pipe comes back with no faulted word in it either way: a stage
            // the frame still wants rerun is simply absent, and one it does not
            // is valid.
            cnt_q <= ckpt_data[0] ? 2'd0 : (ckpt_data[1] ? 2'd1 : 2'd2);
            // Whether stage D held a word. A fault taken with the pipe empty
            // -- the first word after a flush -- had none, and the frame's
            // stage D is then the last instruction's, which must not run
            // again: the queue loads stage D itself once the walk is done.
            d_v_q <= ckpt_data[2];
            c_f_q <= 1'b0;
            b_f_q <= 1'b0;
          end
        endcase
      end

      // The restore always writes the program counter FIRST -- rte_fault in
      // tools/ucode/program.py, and check_restore_order in assemble.py holds it
      // there -- so that is what starts the window. A write of stage D alone is
      // not a restore: BKPT puts the word its acknowledge cycle returned there
      // and carries on, and freezing the pipe for that would freeze it for good,
      // because nothing would ever load it again.
      if (ckpt_load)
        ckpt_busy_q <= 1'b0;
      else if (ckpt_wr && (ckpt_sel == rd68021_pkg::CK_PC_D))
        ckpt_busy_q <= 1'b1;

      if (ckpt_load) begin
        // The pipe is whole again. The cache holding register is not restored
        // -- doc/checkpoint.md -- so it is invalidated and re-read, and a
        // prefetch still in flight belongs to the stream the fault interrupted
        // and is thrown away when it lands, exactly as a flush does it.
        primed_q  <= 1'b1;
        chr_v_q   <= 1'b0;
        if (fetch_pend_q) discard_q <= 1'b1;
      end

      // ------------------------------------------------------------------
      // Push a word into the queue, pop one out, or both in the same clock.
      // ------------------------------------------------------------------
      if (do_flush) begin
        primed_q     <= 1'b1;
        d_v_q        <= 1'b0;
        cnt_q        <= 2'd0;
        pc_d_q       <= pf_addr;
        fill_q       <= pf_addr;
        chr_v_q      <= 1'b0;
        c_f_q        <= 1'b0;
        b_f_q        <= 1'b0;
        // A prefetch already in flight is NOT withdrawn. The bus unit took the
        // operand when it could and there is no way to call it back; what there
        // is, is the answer, which arrives some clocks later and belongs to the
        // stream this flush just abandoned. So the request is left standing and
        // the WORD is thrown away when it comes.
        //
        // Withdrawing it instead -- which is what this did -- leaves the bus
        // unit finishing a cycle nobody is waiting for, and the next prefetch
        // takes that answer as its own: a word from the old stream, carrying
        // the new stream's address. It costs one bus cycle per taken branch,
        // measured in doc/timing-divergences.md.
        discard_q    <= fetch_pend_q && !fetch_ack;
      end else begin
        if (do_adv) begin
          d_q    <= c_q;
          d_v_q  <= 1'b1;
          // The new stage D is the word stage C held, which sits two bytes
          // before stage B -- UM 6.2, "the address of the stage C word is the
          // address of the stage B word minus two".
          pc_d_q <= stg_b_addr - 32'd2;
        end

        unique case ({push, do_pop})
          2'b10: begin                                   // push only
            if (bypass) begin
              d_q    <= chr_word;
              d_v_q  <= 1'b1;
              pc_d_q <= fill_q;
            end else begin
              if (cnt_q == 2'd0) c_q <= chr_word;
              else               b_q <= chr_word;
              if (cnt_q == 2'd0) c_f_q <= chr_f_q;
              else               b_f_q <= chr_f_q;
              cnt_q <= cnt_q + 2'd1;
            end
            fill_q <= fill_q + 32'd2;
          end
          2'b01: begin                                   // pop only
            c_q   <= b_q;
            c_f_q <= b_f_q;
            cnt_q <= cnt_q - 2'd1;
          end
          2'b11: begin                                   // both
            if (cnt_q == 2'd2) begin
              c_q   <= b_q;
              c_f_q <= b_f_q;
              b_q   <= chr_word;
              b_f_q <= chr_f_q;
            end else begin
              c_q   <= chr_word;
              c_f_q <= chr_f_q;
            end
            fill_q <= fill_q + 32'd2;
          end
          default: ;                                     // neither
        endcase
      end
    end
  end

  assign stg_d       = d_q;
  assign stg_c       = c_q;
  assign stg_b       = b_q;
  assign stg_c_fault = c_f_q;
  assign stg_b_fault = b_f_q;
  assign pc_d        = pc_d_q;

  // SSW RC and RB -- doc/ssw.md. "The RC bit indicates that the word in stage C
  // of the instruction pipe is invalid", which is either a word that came from a
  // faulted prefetch or no word at all, and the two cases are what the manual
  // means by "rerun faulted bus cycle OR run pending prefetch".
  //
  // They are DERIVED and not kept. Two registers that are a function of the
  // queue depth and the fault bits would be two more things to keep in step
  // with it, and RTE puts the depth back from them rather than the other way
  // round: a frame with RC clear and RB set describes a queue one word deep.
  //
  // This queue fills stage C before stage B, so RC set implies RB set and the
  // pairing UM 6.2.1 mentions -- "either RB and RC are set, or only RC is set"
  // -- comes out the other way round here. doc/divergences.md records it. A
  // handler does what the same paragraph tells it to and recognises any
  // combination.
  assign stg_c_rerun = (cnt_q == 2'd0) || c_f_q;
  assign stg_b_rerun = (cnt_q != 2'd2) || b_f_q;

  // The address of the word in stage B, or of the word destined for it when the
  // queue is not yet two deep. This is frame field +$24, and it is what RTE
  // needs to rerun a faulted prefetch.
  //
  // The fill point is where the NEXT word goes, and how far that is from stage
  // B's depends on how many stages are still to be filled: one behind when the
  // queue is full, level when only stage B is missing, and one AHEAD when both
  // are -- the next word then belongs to stage C and stage B's is the one after
  // it. Reading it as `fill_q` in that last case is two bytes short, and the
  // case only arises in a frame built with both rerun bits set, which is every
  // address error.
  assign stg_b_addr    = fill_q + 32'd2 - {29'd0, cnt_q, 1'b0};
  assign ckpt_pc_fetch = {fill_q[31:2], 2'b00};

  assign pf_ready  = (cnt_q != 2'd0);
  assign pf_dvalid = d_v_q;

  // ==========================================================================
  // Not consumed yet.
  // ==========================================================================
  logic unused_ifu;
  assign unused_ifu = &{1'b1,
                        ckpt_save, cacr, caar[1:0]};

endmodule
