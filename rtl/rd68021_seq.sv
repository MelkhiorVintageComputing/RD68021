// RD68021 - SystemVerilog MC68020
//
// Sequencer: the microcode engine, the 32-bit datapath, the register file, the three
// stack pointers, the address unit, the condition codes, and the marshalling of the
// checkpoint state into and out of a fault frame.
//
// The sequencer never counts clocks. It presents one request per OPERAND to the bus
// unit and stalls until req_ack, so dynamic bus sizing, misalignment, wait states
// and a retried cycle are all invisible here -- which is also what keeps the bus
// request out of reach of every condition but the two the assembler permits.
//
// M0: the skeleton. The microcode store, the decoders and the datapath arrive in M4
// and M5.

module rd68021_seq #(
    parameter bit COPROCESSOR = 1'b0
) (
    input  logic        clk,
    input  logic        rst_n,

    // Operand request to the bus unit ----------------------------------------
    output logic        req_valid,
    output logic  [2:0] req_kind,
    output logic  [2:0] req_fc,
    output logic [31:0] req_addr,
    output logic  [2:0] req_bytes,
    output logic [39:0] req_wdata,
    output logic        req_rmc,
    output logic  [3:0] req_cpuspace,
    output logic  [7:0] req_cpuaddr,
    input  logic        req_ack,
    input  logic        req_last,
    input  logic [39:0] req_rdata,
    input  logic  [2:0] req_end,
    input  logic        req_fault,
    input  logic        req_fault_wr,
    input  logic  [1:0] req_dsack,

    // The faulted operand's residual, and the way back in --------------------
    input  logic [31:0] flt_addr,
    input  logic  [2:0] flt_bytes,
    input  logic  [2:0] flt_fc,
    input  logic        flt_rw,
    input  logic        flt_rmc,
    input  logic [31:0] flt_dob,
    input  logic [31:0] flt_dib,
    output logic        rst_op_valid,
    output logic [31:0] rst_addr,
    output logic  [2:0] rst_bytes,
    output logic  [2:0] rst_fc,
    output logic        rst_rw,
    output logic        rst_rmc,
    output logic [31:0] rst_dob,

    // Instruction fetch unit --------------------------------------------------
    output logic  [1:0] pf_op,
    output logic [31:0] pf_addr,
    output logic        pf_super,
    input  logic        pf_busy,
    input  logic [15:0] stg_d,
    input  logic [15:0] stg_c,
    input  logic [15:0] stg_b,
    input  logic        stg_d_fault,
    input  logic        stg_c_fault,
    input  logic        stg_b_fault,
    input  logic [31:0] pc_d,
    input  logic [31:0] stg_b_addr,
    output logic        ckpt_save,
    output logic        ckpt_load,
    input  logic [31:0] ckpt_chr,
    input  logic [31:0] ckpt_chr_addr,
    input  logic  [1:0] ckpt_chr_st,
    input  logic [31:0] ckpt_pc_fetch,

    // Cache control -----------------------------------------------------------
    output logic [31:0] cacr,
    output logic [31:0] caar,
    output logic  [1:0] cach_op,

    // Status -------------------------------------------------------------------
    input  logic  [2:0] ipl_sync_n,
    input  logic        reset_sync_n,
    input  logic        halt_sync_n,
    input  logic        bus_idle,
    input  logic        bus_granted,
    input  logic        reset_busy,   // the RESET instruction's 512-clock pulse is running
    output logic        reset_req,
    output logic        dbf,
    output logic        ipend_n_o
);

  // ==========================================================================
  // Architectural state -- M5
  //
  // A7 is not a register. It is whichever of USP, ISP and MSP the S and M bits of
  // the status register select (UM 2.1.1), so an exception switches stacks without
  // moving anything.
  // ==========================================================================
  logic [15:0] sr_q;
  logic [31:0] vbr_q;
  logic  [2:0] sfc_q;
  logic  [2:0] dfc_q;
  logic [31:0] cacr_q;
  logic [31:0] caar_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // UM 2.1.1: after reset the processor is at the supervisor level in interrupt
      // mode, with the mask at 7. UM 4.2: reset clears the E and F bits of CACR.
      sr_q   <= rd68021_pkg::SR_RESET;
      vbr_q  <= '0;
      sfc_q  <= '0;
      dfc_q  <= '0;
      cacr_q <= '0;
      caar_q <= '0;
    end else begin
      sr_q   <= sr_q;
      vbr_q  <= vbr_q;
      sfc_q  <= sfc_q;
      dfc_q  <= dfc_q;
      cacr_q <= cacr_q;
      caar_q <= caar_q;
    end
  end

  assign cacr              = cacr_q;
  assign caar              = caar_q;
  assign cach_op           = 2'b00;

  assign req_valid         = 1'b0;
  assign req_kind          = rd68021_pkg::CT_READ;
  assign req_fc            = rd68021_pkg::FC_SUPER_PROG;
  assign req_addr          = '0;
  assign req_bytes         = 3'd4;
  assign req_wdata         = '0;
  assign req_rmc           = 1'b0;
  assign req_cpuspace      = rd68021_pkg::CPUS_IACK;
  assign req_cpuaddr       = '0;

  assign rst_op_valid      = 1'b0;
  assign rst_addr          = '0;
  assign rst_bytes         = '0;
  assign rst_fc            = rd68021_pkg::FC_SUPER_DATA;
  assign rst_rw            = 1'b1;
  assign rst_rmc           = 1'b0;
  assign rst_dob           = '0;

  assign pf_op             = 2'b00;
  assign pf_addr           = '0;
  assign pf_super          = 1'b1;
  assign ckpt_save         = 1'b0;
  assign ckpt_load         = 1'b0;

  assign reset_req         = 1'b0;
  assign dbf               = 1'b0;
  assign ipend_n_o         = 1'b1;

  // ==========================================================================
  // Inputs this unit does not consume yet.
  // ==========================================================================
  logic unused_seq;
  assign unused_seq = &{1'b1,
                        req_ack, req_last, req_rdata, req_end, req_fault,
                        req_fault_wr, req_dsack,
                        flt_addr, flt_bytes, flt_fc, flt_rw, flt_rmc, flt_dob,
                        flt_dib,
                        pf_busy, stg_d, stg_c, stg_b,
                        stg_d_fault, stg_c_fault, stg_b_fault, pc_d, stg_b_addr,
                        ckpt_chr, ckpt_chr_addr, ckpt_chr_st, ckpt_pc_fetch,
                        ipl_sync_n, reset_sync_n, halt_sync_n, bus_idle, bus_granted,
                        reset_busy,
                        sr_q, vbr_q, sfc_q, dfc_q,
                        COPROCESSOR};

endmodule
