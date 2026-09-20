// RD68021 - SystemVerilog MC68020
//
// Instruction fetch unit: the cache holding register, the three-stage instruction
// pipe, and the instruction cache.
//
// UM 1.6 and figure 1-5: "instruction words (instruction operation words and all
// extension words) enter the pipe at stage B and proceed to stages C and D. An
// instruction word is completely decoded when it reaches stage D of the pipe. Each
// stage has a status bit that reflects whether the word in the stage was loaded with
// data from a bus cycle that was terminated abnormally." Words reach the pipe from a
// 32-bit cache holding register, which the sequencer fills a long word at a time
// from a long-word-aligned address, so the second word of a pair costs no bus cycle
// and no cache access.
//
// This is a module rather than part of the sequencer because the architecture names
// its state: SSW bits FC, FB, RC and RB and frame fields +$0C, +$0E and +$24 make
// stages B and C visible through the fault frame, and every such register has to be
// nameable and restorable. The checkpoint port below is how the sequencer marshals
// them into a format $A or $B frame and back.
//
// M0: the skeleton. The pipe, the cache holding register and the cache arrive in M5
// and M11.

module rd68021_ifu #(
    parameter int ICACHE_ENTRIES = 0
) (
    input  logic        clk,
    input  logic        rst_n,

    // Prefetch control from the sequencer ------------------------------------
    input  logic  [1:0] pf_op,       // NONE / ADV / FILL / FLUSH
    input  logic [31:0] pf_addr,     // the new fetch address on FLUSH
    input  logic        pf_super,    // supervisor or user program space
    output logic        pf_busy,

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
    output logic [31:0] ckpt_chr,
    output logic [31:0] ckpt_chr_addr,
    output logic  [1:0] ckpt_chr_st,
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
  // The pipe -- M5
  //
  // The invariant the architecture states for us (UM 6.2): stg_d is the word at
  // pc_d, stg_c is at pc_d+2, stg_b is at pc_d+4, and stg_b_addr is the truth when
  // a flush has made that arithmetic false. It is why the long frame carries
  // stg_b_addr and the short frame does not: at an instruction boundary the pipe is
  // always sequential.
  // ==========================================================================
  logic [15:0] d_q;
  logic [15:0] c_q;
  logic [15:0] b_q;
  logic        d_flt_q;
  logic        c_flt_q;
  logic        b_flt_q;
  logic [31:0] pc_d_q;
  logic [31:0] b_addr_q;

  // The cache holding register: 32 bits plus the long-word address they came from,
  // a valid bit and a fault bit. A hit on it is a 30-bit equality, which is what
  // makes the abort of UM 5.2.5 fit in the half clock between the address going out
  // and AS -- and it exists whether or not the cache does.
  logic [31:0] chr_q;
  logic [31:0] chr_addr_q;
  logic        chr_valid_q;
  logic        chr_fault_q;

  logic [31:0] pc_fetch_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d_q         <= '0;
      c_q         <= '0;
      b_q         <= '0;
      d_flt_q     <= 1'b0;
      c_flt_q     <= 1'b0;
      b_flt_q     <= 1'b0;
      pc_d_q      <= '0;
      b_addr_q    <= '0;
      chr_q       <= '0;
      chr_addr_q  <= '0;
      chr_valid_q <= 1'b0;
      chr_fault_q <= 1'b0;
      pc_fetch_q  <= '0;
    end else begin
      d_q         <= d_q;
      c_q         <= c_q;
      b_q         <= b_q;
      d_flt_q     <= d_flt_q;
      c_flt_q     <= c_flt_q;
      b_flt_q     <= b_flt_q;
      pc_d_q      <= pc_d_q;
      b_addr_q    <= b_addr_q;
      chr_q       <= chr_q;
      chr_addr_q  <= chr_addr_q;
      chr_valid_q <= chr_valid_q;
      chr_fault_q <= chr_fault_q;
      pc_fetch_q  <= pc_fetch_q;
    end
  end

  assign stg_d         = d_q;
  assign stg_c         = c_q;
  assign stg_b         = b_q;
  assign stg_d_fault   = d_flt_q;
  assign stg_c_fault   = c_flt_q;
  assign stg_b_fault   = b_flt_q;
  assign pc_d          = pc_d_q;
  assign stg_b_addr    = b_addr_q;

  assign ckpt_chr      = chr_q;
  assign ckpt_chr_addr = chr_addr_q;
  assign ckpt_chr_st   = {chr_fault_q, chr_valid_q};
  assign ckpt_pc_fetch = pc_fetch_q;

  assign pf_busy       = 1'b0;
  assign fetch_valid   = 1'b0;
  assign fetch_addr    = '0;
  assign fetch_fc      = rd68021_pkg::FC_SUPER_PROG;
  assign bus_abort     = 1'b0;

  // ==========================================================================
  // Inputs this unit does not consume yet.
  // ==========================================================================
  logic unused_ifu;
  assign unused_ifu = &{1'b1,
                        pf_op, pf_addr, pf_super,
                        ckpt_save, ckpt_load,
                        cacr, caar, cach_op, cdis_sync_n,
                        fetch_ack, fetch_last, fetch_rdata, fetch_fault,
                        ICACHE_ENTRIES == 0};

endmodule
