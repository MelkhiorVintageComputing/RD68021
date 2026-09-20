// RD68021 - SystemVerilog MC68020
//
// Instruction fetch unit: the cache holding register, the three-stage instruction
// pipe, and (from M11) the instruction cache.
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
    output logic        stg_d_fault,
    output logic        stg_c_fault,
    output logic        stg_b_fault,
    output logic [31:0] pc_d,
    output logic [31:0] stg_b_addr,

    // Checkpoint port ---------------------------------------------------------
    input  logic        ckpt_save,
    input  logic        ckpt_load,
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
  logic        d_f_q, c_f_q, b_f_q;
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

  logic room;
  assign room = primed_q && (cnt_q != 2'd2);

  logic push;
  assign push = room && chr_hit;

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

  // M11: a hit in the instruction cache aborts the external cycle before AS.
  assign bus_abort = 1'b0;

  // ==========================================================================
  // The pipe
  // ==========================================================================
  logic do_flush, do_adv, do_consume, do_pop, auto_load;

  assign do_flush   = (pf_op == rd68021_ucode_pkg::U_PF_FLUSH);
  assign do_consume = (pf_op == rd68021_ucode_pkg::U_PF_CONSUME);

  // Stage D fills itself. After a flush -- and after reset -- the pipe is empty,
  // and nothing in the microcode loads the first instruction word: the microword
  // that would is the one waiting for it. So an empty stage D takes the front of
  // the queue by itself, which is the same motion as ADV and is written as one.
  assign auto_load  = !d_v_q && (cnt_q != 2'd0) && !do_flush;
  assign do_adv     = (pf_op == rd68021_ucode_pkg::U_PF_ADV) || auto_load;
  assign do_pop     = do_adv || do_consume;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d_q          <= '0;
      c_q          <= '0;
      b_q          <= '0;
      d_f_q        <= 1'b0;
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
      primed_q     <= 1'b0;
    end else begin
      // ------------------------------------------------------------------
      // The fetch in flight
      // ------------------------------------------------------------------
      if (fetch_ack) begin
        chr_q        <= fetch_rdata;
        chr_addr_q   <= fetch_addr_q[31:2];
        chr_v_q      <= 1'b1;
        chr_f_q      <= fetch_fault;
        fetch_pend_q <= 1'b0;
      end else if (!fetch_pend_q && room && !chr_hit) begin
        fetch_pend_q <= 1'b1;
        fetch_addr_q <= {fill_q[31:2], 2'b00};
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
        fetch_pend_q <= 1'b0;
        d_f_q        <= 1'b0;
        c_f_q        <= 1'b0;
        b_f_q        <= 1'b0;
      end else begin
        if (do_adv) begin
          d_q    <= c_q;
          d_f_q  <= c_f_q;
          d_v_q  <= 1'b1;
          // The new stage D is the word stage C held, which sits two bytes
          // before stage B -- UM 6.2, "the address of the stage C word is the
          // address of the stage B word minus two".
          pc_d_q <= stg_b_addr - 32'd2;
        end

        unique case ({push, do_pop})
          2'b10: begin                                   // push only
            if (cnt_q == 2'd0) c_q <= chr_word;
            else               b_q <= chr_word;
            if (cnt_q == 2'd0) c_f_q <= chr_f_q;
            else               b_f_q <= chr_f_q;
            cnt_q  <= cnt_q + 2'd1;
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
  assign stg_d_fault = d_f_q;
  assign stg_c_fault = c_f_q;
  assign stg_b_fault = b_f_q;
  assign pc_d        = pc_d_q;

  // The address of the word in stage B, or of the word destined for it when the
  // queue is not yet two deep. This is frame field +$24, and it is what RTE needs
  // to rerun a faulted prefetch.
  assign stg_b_addr    = (cnt_q == 2'd2) ? (fill_q - 32'd2) : fill_q;
  assign ckpt_pc_fetch = {fill_q[31:2], 2'b00};

  assign pf_ready  = (cnt_q != 2'd0);
  assign pf_dvalid = d_v_q;

  // ==========================================================================
  // Not consumed yet.
  // ==========================================================================
  logic unused_ifu;
  assign unused_ifu = &{1'b1,
                        ckpt_save, ckpt_load,
                        cacr, caar, cach_op, cdis_sync_n,
                        ICACHE_ENTRIES == 0};

endmodule
