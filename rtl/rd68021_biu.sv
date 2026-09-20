// RD68021 - SystemVerilog MC68020
//
// Bus interface unit. Owns every pin and every clock: the S0-S5 cycle at one bus
// state per CLK half period, wait states, dynamic bus sizing from DSACK, the split
// of an operand into one to four bus cycles and the assembly of the result, RMC,
// CPU-space cycles, BERR/retry/halt, arbitration, and the input synchronisers.
//
// The sequencer never counts clocks. It presents one request per OPERAND and stalls
// until req_ack, so wait states, a narrow port, a misaligned transfer and a retried
// cycle all look the same from above.
//
// M0: the skeleton. Every output is driven to its negated value and every register
// is reset; the state machine arrives in M1.

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
    output logic        req_ack,
    output logic        req_last,
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
    output logic [31:0] fetch_rdata,
    output logic        fetch_fault,
    input  logic        bus_abort,

    // Status -----------------------------------------------------------------
    input  logic        reset_req,
    output logic        reset_busy,
    input  logic        dbf,
    output logic  [2:0] ipl_sync_n,
    output logic        reset_sync_n,
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
    output logic        dben_o,
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

  // ==========================================================================
  // Input synchronisers -- UM 5.1, figures 5-1 and 5-2
  //
  // The processor latches the level of an input during a sample window around the
  // FALLING edge of the clock, so both ranks are negedge. DSACK, BERR, HALT and
  // AVEC are not here: they go straight to the falling-edge next-state logic, which
  // is the sample the manual describes.
  // ==========================================================================
  rd68021_sync #(.WIDTH (3), .RESET_VAL (3'b111)) u_sync_ipl (
      .clk (clk), .rst_n (rst_n), .d (ipl_n_i), .q (ipl_sync_n));

  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_reset (
      .clk (clk), .rst_n (rst_n), .d (reset_n_i), .q (reset_sync_n));

  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_halt (
      .clk (clk), .rst_n (rst_n), .d (halt_n_i), .q (halt_sync_n));

  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_cdis (
      .clk (clk), .rst_n (rst_n), .d (cdis_n_i), .q (cdis_sync_n));

  logic br_sync_n;
  logic bgack_sync_n;

  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_br (
      .clk (clk), .rst_n (rst_n), .d (br_n_i), .q (br_sync_n));

  rd68021_sync #(.WIDTH (1), .RESET_VAL (1'b1)) u_sync_bgack (
      .clk (clk), .rst_n (rst_n), .d (bgack_n_i), .q (bgack_sync_n));

  // ==========================================================================
  // Bus state -- M1
  // ==========================================================================
  rd68021_pkg::bus_state_e st_p;   // rising-edge domain
  rd68021_pkg::bus_state_e st_n;   // falling-edge domain

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_p <= rd68021_pkg::ST_IDLE;
    end else begin
      st_p <= rd68021_pkg::ST_IDLE;
    end
  end

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_n <= rd68021_pkg::ST_IDLE;
    end else begin
      st_n <= rd68021_pkg::ST_IDLE;
    end
  end

  // ==========================================================================
  // Pins, all negated. The _n signals are active low AT THE PIN, so negated is 1;
  // the _oe signals are active high meaning the core drives, so released is 0.
  // ==========================================================================
  assign fc_o       = rd68021_pkg::FC_RESERVED_0;
  assign fc_oe      = 1'b0;
  assign a_o        = '0;
  assign a_oe       = 1'b0;
  assign d_o        = '0;
  assign d_oe       = 1'b0;
  assign siz_o      = rd68021_pkg::SIZ_LONG;
  assign siz_oe     = 1'b0;
  assign ecs_n_o    = 1'b1;
  assign ocs_n_o    = 1'b1;
  assign rw_o       = 1'b1;          // read
  assign rw_oe      = 1'b0;
  assign rmc_n_o    = 1'b1;
  assign rmc_oe     = 1'b0;
  assign as_n_o     = 1'b1;
  assign as_oe      = 1'b0;
  assign ds_n_o     = 1'b1;
  assign ds_oe      = 1'b0;
  assign dben_o     = 1'b0;
  assign dben_oe    = 1'b0;
  assign bg_n_o     = 1'b1;

  // RESET and HALT are open drain: the output value is a constant zero and the
  // enable is what asserts them (doc/pinout.md).
  assign reset_n_o  = 1'b0;
  assign reset_n_oe = 1'b0;
  assign halt_n_o   = 1'b0;
  assign halt_n_oe  = 1'b0;

  // ==========================================================================
  // Handshake, idle
  // ==========================================================================
  assign req_ack      = 1'b0;
  assign req_last     = 1'b0;
  assign req_rdata    = '0;
  assign req_end      = rd68021_pkg::CE_NONE;
  assign req_fault    = 1'b0;
  assign req_fault_wr = 1'b0;
  assign req_dsack    = rd68021_pkg::DSACK_WAIT;

  assign flt_addr     = '0;
  assign flt_bytes    = '0;
  assign flt_fc       = rd68021_pkg::FC_RESERVED_0;
  assign flt_rw       = 1'b1;
  assign flt_rmc      = 1'b0;
  assign flt_dob      = '0;
  assign flt_dib      = '0;

  assign fetch_ack    = 1'b0;
  assign fetch_rdata  = '0;
  assign fetch_fault  = 1'b0;

  assign reset_busy   = 1'b0;
  assign bus_idle     = 1'b1;
  assign bus_granted  = 1'b0;

  // ==========================================================================
  // Inputs this unit does not consume yet. The list shrinks visibly as the design
  // fills in, which is why it is written out rather than waived wholesale.
  // ==========================================================================
  logic unused_biu;
  assign unused_biu = &{1'b1,
                        req_valid, req_kind, req_fc, req_addr, req_bytes, req_wdata,
                        req_rmc, req_cpuspace, req_cpuaddr,
                        rst_op_valid, rst_addr, rst_bytes, rst_fc, rst_rw, rst_rmc,
                        rst_dob,
                        fetch_valid, fetch_addr, fetch_fc, bus_abort,
                        reset_req, dbf,
                        d_i, dsack_n_i, avec_n_i, berr_n_i,
                        br_sync_n, bgack_sync_n,
                        st_p == rd68021_pkg::ST_IDLE, st_n == rd68021_pkg::ST_IDLE,
                        ADDR_HIZ_BETWEEN_CYCLES};

endmodule
