// RD68021 - SystemVerilog MC68020
//
// Top level. Pin list per doc/pinout.md: every three-state or bidirectional pin of
// the original is split into _i / _o / _oe, with _oe active high meaning the core
// drives.
//
// The processor is three units: rd68021_seq runs the microcode and holds the
// datapath, rd68021_ifu holds the instruction pipe and the cache, and rd68021_biu
// drives the pins. This wires them together and does nothing else.
//
// Note the fully-scoped rd68021_pkg:: references and the plain-vector ports: yosys
// 0.52 supports neither `import pkg::*` nor user types on ports. See
// doc/coding-standard.md.

module rd68021_top #(
    // Number of instruction cache entries: 64 is the MC68020 (UM 4.1), and any
    // other power of two from 2 up is a smaller cache with a wider tag. Zero
    // removes the cache entirely, which is still fully software compatible -- UM
    // 4.1 caches instructions only, so the cache is architecturally invisible --
    // and `make cache` holds the two to that. CACR, CAAR and CDIS exist and
    // behave either way.
    parameter int ICACHE_ENTRIES = 64,
    // Whether the coprocessor interface is built. Zero takes an F-line exception on
    // every coprocessor opcode, which is also the right behaviour for a machine with
    // no coprocessor attached.
    parameter bit COPROCESSOR = 1'b0,
    // Whether the address group is released between bus cycles. The MC68020 does
    // (specification 7); a board that needs it held can clear this.
    parameter bit ADDR_HIZ_BETWEEN_CYCLES = 1'b1
) (
    // Clock and hardware reset -----------------------------------------------
    input  logic        clk,      // free-running, both edges used
    input  logic        rst_n,    // not an MC68020 pin: async init, see doc/pinout.md

    // Function codes (UM 3.2) ------------------------------------------------
    output logic  [2:0] fc_o,
    output logic        fc_oe,

    // Address bus (UM 3.3) ---------------------------------------------------
    output logic [31:0] a_o,      // A1 and A0 are real pins
    output logic        a_oe,

    // Data bus (UM 3.4) ------------------------------------------------------
    input  logic [31:0] d_i,
    output logic [31:0] d_o,      // all 32 bits driven on every write (UM 5.2.4)
    output logic        d_oe,

    // Transfer size (UM 3.5) -------------------------------------------------
    output logic  [1:0] siz_o,    // bytes REMAINING, not operand size (UM 5.1.1)
    output logic        siz_oe,

    // Asynchronous bus control (UM 3.6) --------------------------------------
    output logic        ecs_n_o,  // one half clock, every bus cycle; never three-stated
    output logic        ocs_n_o,  // ... but only the first cycle of an operand
    output logic        rw_o,     // high = read, low = write
    output logic        rw_oe,
    output logic        rmc_n_o,
    output logic        rmc_oe,
    output logic        as_n_o,
    output logic        as_oe,
    output logic        ds_n_o,
    output logic        ds_oe,
    output logic        dben_o,
    output logic        dben_oe,
    input  logic  [1:0] dsack_n_i,  // [1] is DSACK1; sample both on the same edge

    // Interrupt control (UM 3.7) ---------------------------------------------
    input  logic  [2:0] ipl_n_i,
    output logic        ipend_n_o,  // never three-stated
    input  logic        avec_n_i,

    // Bus arbitration (UM 3.8) -----------------------------------------------
    input  logic        br_n_i,
    output logic        bg_n_o,     // never three-stated
    input  logic        bgack_n_i,

    // Bus exception control (UM 3.9) -----------------------------------------
    input  logic        berr_n_i,
    input  logic        reset_n_i,
    output logic        reset_n_o,  // open drain: constant 0
    output logic        reset_n_oe, // the RESET instruction holds it 512 clocks
    input  logic        halt_n_i,
    output logic        halt_n_o,   // open drain: constant 0
    output logic        halt_n_oe,

    // Emulator support (UM 3.10) ---------------------------------------------
    input  logic        cdis_n_i
);

  // ==========================================================================
  // Sequencer to bus unit: one request per OPERAND, not per bus cycle.
  //
  // The bus unit owns the split into one to four cycles, the SIZ encoding, the
  // byte lanes of Table 5-7 and the assembly of the result, so the microcode
  // issues exactly one request whatever the alignment and whatever port answers.
  // That is also what lets OCS be driven from this handshake (UM 5.1.1).
  // ==========================================================================
  logic        req_valid;
  logic  [2:0] req_kind;
  logic  [2:0] req_fc;
  logic [31:0] req_addr;
  logic  [2:0] req_bytes;      // 1..5; five is a bit-field span, which SIZ cannot encode
  logic [39:0] req_wdata;      // right-justified
  logic        req_rmc;
  logic  [3:0] req_cpuspace;
  logic  [7:0] req_cpuaddr;

  logic        req_ack;
  logic        req_last;
  logic [39:0] req_rdata;
  logic  [2:0] req_end;
  logic        req_fault;
  logic        req_fault_wr;
  logic  [1:0] req_dsack;

  // The residual of the in-flight operand, sampled at a fault: what the frame
  // records, and what RTE reloads through the restore port below.
  logic [31:0] flt_addr;
  logic  [2:0] flt_bytes;
  logic  [2:0] flt_fc;
  logic        flt_rw;
  logic        flt_rmc;
  logic [31:0] flt_dob;
  logic [31:0] flt_dib;

  logic        rst_op_valid;
  logic [31:0] rst_addr;
  logic  [2:0] rst_bytes;
  logic  [2:0] rst_fc;
  logic        rst_rw;
  logic        rst_rmc;
  logic [31:0] rst_dob;

  // ==========================================================================
  // Sequencer to instruction fetch unit
  // ==========================================================================
  logic  [1:0] pf_op;          // NONE / ADV / FILL / FLUSH
  logic [31:0] pf_addr;        // the new fetch address on FLUSH
  logic        pf_super;       // which program space to fetch in
  logic        pf_ready;
  logic        pf_dvalid;
  logic [15:0] stg_d;
  logic [15:0] stg_c;
  logic [15:0] stg_b;
  logic        stg_c_fault;
  logic        stg_b_fault;
  logic        stg_c_rerun;
  logic        stg_b_rerun;
  logic        pf_stuck;
  logic        pf_odd;
  logic [31:0] pc_d;
  logic [31:0] stg_b_addr;

  // The IFU's checkpoint port, marshalled into and out of a format $A or $B
  // frame by the sequencer. The cache holding register is deliberately absent:
  // doc/checkpoint.md records why it is not saved.
  logic        ckpt_save;
  logic        ckpt_wr;
  logic  [2:0] ckpt_sel;
  logic [31:0] ckpt_data;
  logic        ckpt_load;
  logic [31:0] ckpt_pc_fetch;

  // ==========================================================================
  // Instruction fetch unit to bus unit
  // ==========================================================================
  logic        fetch_valid;
  logic [31:0] fetch_addr;     // always long-word aligned (UM Table 5-6 note)
  logic  [2:0] fetch_fc;
  logic        fetch_ack;
  logic        fetch_last;
  logic [31:0] fetch_rdata;
  logic        fetch_fault;
  logic        bus_abort;      // combinational, valid during S0 (UM 5.2.5)

  // ==========================================================================
  // Cache control, which exists whether or not the cache does
  // ==========================================================================
  logic [31:0] cacr;
  logic [31:0] caar;
  logic  [1:0] cach_op;        // none / clear all / clear the entry CAAR names
  logic        cdis_sync_n;

  // ==========================================================================
  // Status
  // ==========================================================================
  logic  [2:0] ipl_sync_n;
  logic        reset_sync_n;
  logic        halt_sync_n;
  logic        bus_idle;
  logic        bus_granted;
  logic        reset_req;
  logic        reset_busy;
  logic        dbf;            // double bus fault

  rd68021_seq #(.COPROCESSOR (COPROCESSOR)) u_seq (
      .clk            (clk),
      .rst_n          (rst_n),

      .req_valid      (req_valid),
      .req_kind       (req_kind),
      .req_fc         (req_fc),
      .req_addr       (req_addr),
      .req_bytes      (req_bytes),
      .req_wdata      (req_wdata),
      .req_rmc        (req_rmc),
      .req_cpuspace   (req_cpuspace),
      .req_cpuaddr    (req_cpuaddr),
      .req_ack        (req_ack),
      .req_last       (req_last),
      .req_rdata      (req_rdata),
      .req_end        (req_end),
      .req_fault      (req_fault),
      .req_fault_wr   (req_fault_wr),
      .req_dsack      (req_dsack),

      .flt_addr       (flt_addr),
      .flt_bytes      (flt_bytes),
      .flt_fc         (flt_fc),
      .flt_rw         (flt_rw),
      .flt_rmc        (flt_rmc),
      .flt_dob        (flt_dob),
      .flt_dib        (flt_dib),
      .rst_op_valid   (rst_op_valid),
      .rst_addr       (rst_addr),
      .rst_bytes      (rst_bytes),
      .rst_fc         (rst_fc),
      .rst_rw         (rst_rw),
      .rst_rmc        (rst_rmc),
      .rst_dob        (rst_dob),

      .pf_op          (pf_op),
      .pf_addr        (pf_addr),
      .pf_super       (pf_super),
      .pf_ready       (pf_ready),
      .pf_dvalid      (pf_dvalid),
      .stg_d          (stg_d),
      .stg_c          (stg_c),
      .stg_b          (stg_b),
      .stg_c_fault    (stg_c_fault),
      .stg_b_fault    (stg_b_fault),
      .stg_c_rerun    (stg_c_rerun),
      .stg_b_rerun    (stg_b_rerun),
      .pf_stuck       (pf_stuck),
      .pf_odd         (pf_odd),
      .pc_d           (pc_d),
      .stg_b_addr     (stg_b_addr),
      .ckpt_save      (ckpt_save),
      .ckpt_wr        (ckpt_wr),
      .ckpt_sel       (ckpt_sel),
      .ckpt_data      (ckpt_data),
      .ckpt_load      (ckpt_load),
      .ckpt_pc_fetch  (ckpt_pc_fetch),

      .cacr           (cacr),
      .caar           (caar),
      .cach_op        (cach_op),

      .ipl_sync_n     (ipl_sync_n),
      .reset_sync_n   (reset_sync_n),
      .halt_sync_n    (halt_sync_n),
      .bus_idle       (bus_idle),
      .bus_granted    (bus_granted),
      .reset_req      (reset_req),
      .reset_busy     (reset_busy),
      .dbf            (dbf),
      .ipend_n_o      (ipend_n_o)
  );

  rd68021_ifu #(.ICACHE_ENTRIES (ICACHE_ENTRIES)) u_ifu (
      .clk            (clk),
      .rst_n          (rst_n),

      .pf_op          (pf_op),
      .pf_addr        (pf_addr),
      .pf_super       (pf_super),
      .pf_ready       (pf_ready),
      .pf_dvalid      (pf_dvalid),
      .stg_d          (stg_d),
      .stg_c          (stg_c),
      .stg_b          (stg_b),
      .stg_c_fault    (stg_c_fault),
      .stg_b_fault    (stg_b_fault),
      .stg_c_rerun    (stg_c_rerun),
      .stg_b_rerun    (stg_b_rerun),
      .pf_stuck       (pf_stuck),
      .pf_odd         (pf_odd),
      .pc_d           (pc_d),
      .stg_b_addr     (stg_b_addr),
      .ckpt_save      (ckpt_save),
      .ckpt_wr        (ckpt_wr),
      .ckpt_sel       (ckpt_sel),
      .ckpt_data      (ckpt_data),
      .ckpt_load      (ckpt_load),
      .ckpt_pc_fetch  (ckpt_pc_fetch),

      .cacr           (cacr),
      .caar           (caar),
      .cach_op        (cach_op),
      .cdis_sync_n    (cdis_sync_n),

      .fetch_valid    (fetch_valid),
      .fetch_addr     (fetch_addr),
      .fetch_fc       (fetch_fc),
      .fetch_ack      (fetch_ack),
      .fetch_last     (fetch_last),
      .fetch_rdata    (fetch_rdata),
      .fetch_fault    (fetch_fault),
      .bus_abort      (bus_abort)
  );

  rd68021_biu #(.ADDR_HIZ_BETWEEN_CYCLES (ADDR_HIZ_BETWEEN_CYCLES)) u_biu (
      .clk            (clk),
      .rst_n          (rst_n),

      .req_valid      (req_valid),
      .req_kind       (req_kind),
      .req_fc         (req_fc),
      .req_addr       (req_addr),
      .req_bytes      (req_bytes),
      .req_wdata      (req_wdata),
      .req_rmc        (req_rmc),
      .req_cpuspace   (req_cpuspace),
      .req_cpuaddr    (req_cpuaddr),
      .req_ack        (req_ack),
      .req_last       (req_last),
      .req_rdata      (req_rdata),
      .req_end        (req_end),
      .req_fault      (req_fault),
      .req_fault_wr   (req_fault_wr),
      .req_dsack      (req_dsack),

      .flt_addr       (flt_addr),
      .flt_bytes      (flt_bytes),
      .flt_fc         (flt_fc),
      .flt_rw         (flt_rw),
      .flt_rmc        (flt_rmc),
      .flt_dob        (flt_dob),
      .flt_dib        (flt_dib),
      .rst_op_valid   (rst_op_valid),
      .rst_addr       (rst_addr),
      .rst_bytes      (rst_bytes),
      .rst_fc         (rst_fc),
      .rst_rw         (rst_rw),
      .rst_rmc        (rst_rmc),
      .rst_dob        (rst_dob),

      .fetch_valid    (fetch_valid),
      .fetch_addr     (fetch_addr),
      .fetch_fc       (fetch_fc),
      .fetch_ack      (fetch_ack),
      .fetch_last     (fetch_last),
      .fetch_rdata    (fetch_rdata),
      .fetch_fault    (fetch_fault),
      .bus_abort      (bus_abort),

      .reset_req      (reset_req),
      .reset_busy     (reset_busy),
      .dbf            (dbf),
      .ipl_sync_n     (ipl_sync_n),
      .reset_sync_n   (reset_sync_n),
      .halt_sync_n    (halt_sync_n),
      .cdis_sync_n    (cdis_sync_n),
      .bus_idle       (bus_idle),
      .bus_granted    (bus_granted),

      .fc_o           (fc_o),        .fc_oe      (fc_oe),
      .a_o            (a_o),         .a_oe       (a_oe),
      .d_i            (d_i),         .d_o        (d_o),       .d_oe    (d_oe),
      .siz_o          (siz_o),       .siz_oe     (siz_oe),
      .ecs_n_o        (ecs_n_o),     .ocs_n_o    (ocs_n_o),
      .rw_o           (rw_o),        .rw_oe      (rw_oe),
      .rmc_n_o        (rmc_n_o),     .rmc_oe     (rmc_oe),
      .as_n_o         (as_n_o),      .as_oe      (as_oe),
      .ds_n_o         (ds_n_o),      .ds_oe      (ds_oe),
      .dben_o         (dben_o),      .dben_oe    (dben_oe),
      .dsack_n_i      (dsack_n_i),
      .ipl_n_i        (ipl_n_i),     .avec_n_i   (avec_n_i),
      .br_n_i         (br_n_i),      .bg_n_o     (bg_n_o),    .bgack_n_i (bgack_n_i),
      .berr_n_i       (berr_n_i),
      .reset_n_i      (reset_n_i),   .reset_n_o  (reset_n_o), .reset_n_oe (reset_n_oe),
      .halt_n_i       (halt_n_i),    .halt_n_o   (halt_n_o),  .halt_n_oe  (halt_n_oe),
      .cdis_n_i       (cdis_n_i)
  );

endmodule
