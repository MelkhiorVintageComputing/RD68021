// RD68021 - SystemVerilog MC68020
//
// Sequencer: the microcode engine, the 32-bit datapath, the register file, the
// three stack pointers, and (from M9) the marshalling of the checkpoint state
// into and out of a fault frame.
//
// ONE MICROWORD PER CLOCK, and the sequencer never counts clocks. A microword
// with a bus request stalls until req_ack, so wait states, a narrow port, a
// misaligned transfer and a retried cycle are all invisible here -- which is also
// what keeps dynamic bus sizing out of reach of the micro-address path.
//
// The store is read at the NEXT micro-address rather than the current one and is
// registered, so the microword arrives at the same time as the micro-address it
// belongs to: no clock lost, and a memory instead of logic.
//
// M5: reset, NOP, MOVEQ, MOVE.L Dn,Dn and both shapes of BRA. The addressing
// modes are M6 and the rest of the instruction set M7.

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
    input  logic        pf_ready,
    input  logic        pf_dvalid,
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
    input  logic        reset_busy,
    output logic        reset_req,
    output logic        dbf,
    output logic        ipend_n_o
);

  int unsigned i_r;

  // ==========================================================================
  // The microword
  // ==========================================================================
  `define UF(f) uw[rd68021_ucode_pkg::U_``f``_LSB +: rd68021_ucode_pkg::U_``f``_W]

  logic [rd68021_ucode_pkg::UW-1:0]    uw;
  logic [rd68021_ucode_pkg::UADDR-1:0] upc, upc_nxt;

  logic [rd68021_ucode_pkg::UADDR-1:0] dec_entry;
  logic                                dec_illegal;

  rd68021_ucode_rom u_urom (
      .clk (clk), .rst_n (rst_n), .addr (upc_nxt), .uw (uw));

  // The word to decode. An instruction ends with one microword that both
  // advances the pipe and decodes, so the opcode the decoder must look at is the
  // one ADV is about to move into stage D -- which is stage C. Decoding stage D
  // there decodes the instruction that has just finished, again.
  logic [15:0] dec_ir;
  assign dec_ir = (`UF(PF) == rd68021_ucode_pkg::U_PF_ADV) ? stg_c : stg_d;

  rd68021_decode_rom u_decode (
      .ir (dec_ir), .entry (dec_entry), .illegal (dec_illegal));

  // ==========================================================================
  // Architectural state
  //
  // A7 is not a register. It is whichever of USP, ISP and MSP the S and M bits
  // of the status register select (UM 2.1.1), so an exception switches stacks
  // without moving anything.
  // ==========================================================================
  logic [31:0] dreg [0:7];
  logic [31:0] areg [0:6];
  logic [31:0] usp_q, isp_q, msp_q;
  logic [15:0] sr_q;
  logic [31:0] vbr_q;
  logic  [2:0] sfc_q, dfc_q;
  logic [31:0] cacr_q, caar_q;

  // The checkpoint set -- doc/checkpoint.md.
  logic [31:0] t_q [0:3];
  logic [15:0] xw_q;
  logic [31:0] ea_q;

  logic super_mode;
  logic master_mode;
  assign super_mode  = sr_q[rd68021_pkg::SR_S];
  assign master_mode = sr_q[rd68021_pkg::SR_M];

  logic [31:0] sp_read;
  always_comb begin
    if (!super_mode)     sp_read = usp_q;
    else if (master_mode) sp_read = msp_q;
    else                 sp_read = isp_q;
  end

  // ==========================================================================
  // Register selects. A convention rather than a microword field: an A source
  // reads the register bits 2:0 of the instruction word name, and a destination
  // writes the one bits 11:9 name. That is the direction MOVE and MOVEQ both go.
  // ==========================================================================
  logic [2:0] rsel, wsel;
  assign rsel = stg_d[2:0];
  assign wsel = stg_d[11:9];

  // ==========================================================================
  // The datapath
  // ==========================================================================
  logic [31:0] a_bus, b_bus, y;

  always_comb begin
    unique case (`UF(ASRC))
      rd68021_ucode_pkg::U_ASRC_ZERO:  a_bus = 32'd0;
      rd68021_ucode_pkg::U_ASRC_T0:    a_bus = t_q[0];
      rd68021_ucode_pkg::U_ASRC_T1:    a_bus = t_q[1];
      rd68021_ucode_pkg::U_ASRC_T2:    a_bus = t_q[2];
      rd68021_ucode_pkg::U_ASRC_T3:    a_bus = t_q[3];
      rd68021_ucode_pkg::U_ASRC_RDATA: a_bus = req_rdata[31:0];
      rd68021_ucode_pkg::U_ASRC_STG_D: a_bus = {16'd0, stg_d};
      rd68021_ucode_pkg::U_ASRC_STG_C: a_bus = {16'd0, stg_c};
      rd68021_ucode_pkg::U_ASRC_XW:    a_bus = {{16{xw_q[15]}}, xw_q};
      rd68021_ucode_pkg::U_ASRC_PC_D:  a_bus = pc_d;
      rd68021_ucode_pkg::U_ASRC_SR:    a_bus = {16'd0, sr_q};
      rd68021_ucode_pkg::U_ASRC_DREG:  a_bus = dreg[rsel];
      rd68021_ucode_pkg::U_ASRC_AREG:  a_bus = (rsel == 3'd7) ? sp_read
                                                              : areg[rsel];
      rd68021_ucode_pkg::U_ASRC_IMM8:  a_bus = {{24{stg_d[7]}}, stg_d[7:0]};
      rd68021_ucode_pkg::U_ASRC_DISP8: a_bus = {{24{stg_d[7]}}, stg_d[7:0]};
      rd68021_ucode_pkg::U_ASRC_SP:    a_bus = sp_read;
      default:                         a_bus = 32'd0;
    endcase
  end

  always_comb begin
    unique case (`UF(BSRC))
      rd68021_ucode_pkg::U_BSRC_ZERO:  b_bus = 32'd0;
      rd68021_ucode_pkg::U_BSRC_TWO:   b_bus = 32'd2;
      rd68021_ucode_pkg::U_BSRC_T0:    b_bus = t_q[0];
      rd68021_ucode_pkg::U_BSRC_T1:    b_bus = t_q[1];
      rd68021_ucode_pkg::U_BSRC_XW:    b_bus = {{16{xw_q[15]}}, xw_q};
      rd68021_ucode_pkg::U_BSRC_DISP8: b_bus = {{24{stg_d[7]}}, stg_d[7:0]};
      rd68021_ucode_pkg::U_BSRC_DREG:  b_bus = dreg[rsel];
      rd68021_ucode_pkg::U_BSRC_AREG:  b_bus = (rsel == 3'd7) ? sp_read
                                                              : areg[rsel];
      rd68021_ucode_pkg::U_BSRC_RDATA: b_bus = req_rdata[31:0];
      default:                         b_bus = 32'd0;
    endcase
  end

  always_comb begin
    unique case (`UF(ALU))
      rd68021_ucode_pkg::U_ALU_A:   y = a_bus;
      rd68021_ucode_pkg::U_ALU_B:   y = b_bus;
      rd68021_ucode_pkg::U_ALU_ADD: y = a_bus + b_bus;
      rd68021_ucode_pkg::U_ALU_SUB: y = a_bus - b_bus;
      rd68021_ucode_pkg::U_ALU_AND: y = a_bus & b_bus;
      rd68021_ucode_pkg::U_ALU_OR:  y = a_bus | b_bus;
      rd68021_ucode_pkg::U_ALU_EOR: y = a_bus ^ b_bus;
      default:                      y = a_bus;
    endcase
  end

  // The result as the destination size sees it. PRM 3: a byte or word result
  // sets N and Z from that width, and a write to a data register leaves the rest
  // of the register alone.
  logic        res_n, res_z;
  always_comb begin
    unique case (`UF(SIZE))
      rd68021_ucode_pkg::U_SIZE_BYTE: begin
        res_n = y[7];
        res_z = (y[7:0] == 8'd0);
      end
      rd68021_ucode_pkg::U_SIZE_WORD: begin
        res_n = y[15];
        res_z = (y[15:0] == 16'd0);
      end
      default: begin
        res_n = y[31];
        res_z = (y == 32'd0);
      end
    endcase
  end

  // ==========================================================================
  // Stalling
  //
  // A microword retires when nothing it asked for is outstanding. Everything
  // else -- the datapath write, the pipe operation, the micro-address -- is
  // conditioned on that one signal, so a stalled microword has no effect at all
  // and can be re-evaluated every clock without doing anything twice.
  // ==========================================================================
  logic bus_req;
  logic needs_c;
  logic stall;

  assign bus_req = (`UF(BUS) != rd68021_ucode_pkg::U_BUS_NONE);
  assign needs_c = (`UF(PF) == rd68021_ucode_pkg::U_PF_ADV)
                || (`UF(PF) == rd68021_ucode_pkg::U_PF_CONSUME)
                || (`UF(ASRC) == rd68021_ucode_pkg::U_ASRC_STG_C);

  assign stall = (bus_req && !req_ack)
              || (needs_c && !pf_ready)
              || ((`UF(SEQ) == rd68021_ucode_pkg::U_SEQ_DECODE)
                  && (`UF(PF) != rd68021_ucode_pkg::U_PF_ADV)
                  && !pf_dvalid);

  logic retire;
  assign retire = !stall;

  // ==========================================================================
  // The bus request
  // ==========================================================================
  logic [31:0] req_addr_sel;
  always_comb begin
    unique case (`UF(ASEL))
      rd68021_ucode_pkg::U_ASEL_ZERO: req_addr_sel = 32'd0;
      rd68021_ucode_pkg::U_ASEL_FOUR: req_addr_sel = 32'd4;
      rd68021_ucode_pkg::U_ASEL_T0:   req_addr_sel = t_q[0];
      rd68021_ucode_pkg::U_ASEL_T1:   req_addr_sel = t_q[1];
      rd68021_ucode_pkg::U_ASEL_EA:   req_addr_sel = ea_q;
      rd68021_ucode_pkg::U_ASEL_PC_D: req_addr_sel = pc_d;
      default:                        req_addr_sel = 32'd0;
    endcase
  end

  always_comb begin
    unique case (`UF(FC))
      rd68021_ucode_pkg::U_FC_PROG: req_fc = super_mode
                                             ? rd68021_pkg::FC_SUPER_PROG
                                             : rd68021_pkg::FC_USER_PROG;
      rd68021_ucode_pkg::U_FC_CPU:  req_fc = rd68021_pkg::FC_CPU;
      default:                      req_fc = super_mode
                                             ? rd68021_pkg::FC_SUPER_DATA
                                             : rd68021_pkg::FC_USER_DATA;
    endcase
  end

  // Drop the request as soon as it has been taken, and it takes BOTH terms.
  //
  // The bus unit accepts a new request on the very edge the previous operand
  // finishes -- that is what makes back-to-back cycles possible at all -- so a
  // request still asserted at that edge is taken a second time. req_last covers
  // that edge. But this sequencer waits for req_ack rather than presenting its
  // next request in that half clock, so the microword is still current for one
  // more clock after the operand completes, with req_last back low: without the
  // second term the same read runs twice, which is how the reset vectors came
  // back as the stack pointer twice over.
  assign req_valid    = bus_req && !req_last && !req_ack;
  assign req_kind     = (`UF(BUS) == rd68021_ucode_pkg::U_BUS_WRITE)
                        ? rd68021_pkg::CT_WRITE : rd68021_pkg::CT_READ;
  assign req_addr     = req_addr_sel;
  assign req_bytes    = `UF(BYTES);
  assign req_wdata    = {8'd0, y};
  assign req_rmc      = 1'b0;
  assign req_cpuspace = rd68021_pkg::CPUS_IACK;
  assign req_cpuaddr  = 8'd0;

  // ==========================================================================
  // The instruction pipe
  // ==========================================================================
  assign pf_op    = retire ? `UF(PF) : rd68021_ucode_pkg::U_PF_NONE;
  assign pf_addr  = y;
  assign pf_super = super_mode;

  // ==========================================================================
  // The next micro-address
  // ==========================================================================
  always_comb begin
    if (!retire) begin
      upc_nxt = upc;
    end else begin
      unique case (`UF(SEQ))
        rd68021_ucode_pkg::U_SEQ_DECODE: upc_nxt = dec_entry;
        rd68021_ucode_pkg::U_SEQ_COND:   upc_nxt = `UF(NEXT);
        default:                         upc_nxt = `UF(NEXT);
      endcase
    end
  end

  // ==========================================================================
  // The one clocked process
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      upc    <= rd68021_ucode_pkg::ENTRY_RESET;
      // UM 2.1.1: after reset the processor is at the supervisor level in
      // interrupt mode with the mask at 7. UM 4.2: reset clears CACR's E and F.
      sr_q   <= rd68021_pkg::SR_RESET;
      vbr_q  <= '0;
      sfc_q  <= '0;
      dfc_q  <= '0;
      cacr_q <= '0;
      caar_q <= '0;
      usp_q  <= '0;
      isp_q  <= '0;
      msp_q  <= '0;
      xw_q   <= '0;
      ea_q   <= '0;
      for (i_r = 0; i_r < 8; i_r = i_r + 1) dreg[i_r] <= '0;
      for (i_r = 0; i_r < 7; i_r = i_r + 1) areg[i_r] <= '0;
      for (i_r = 0; i_r < 4; i_r = i_r + 1) t_q[i_r]  <= '0;
    end else begin
      upc <= upc_nxt;

      if (retire) begin
        unique case (`UF(DST))
          rd68021_ucode_pkg::U_DST_T0: t_q[0] <= y;
          rd68021_ucode_pkg::U_DST_T1: t_q[1] <= y;
          rd68021_ucode_pkg::U_DST_T2: t_q[2] <= y;
          rd68021_ucode_pkg::U_DST_T3: t_q[3] <= y;
          rd68021_ucode_pkg::U_DST_XW: xw_q   <= y[15:0];
          rd68021_ucode_pkg::U_DST_EA: ea_q   <= y;
          rd68021_ucode_pkg::U_DST_SR: sr_q   <= y[15:0]
                                                 & rd68021_pkg::SR_IMPLEMENTED;
          rd68021_ucode_pkg::U_DST_DREG: begin
            // A byte or word write leaves the rest of the data register alone.
            unique case (`UF(SIZE))
              rd68021_ucode_pkg::U_SIZE_BYTE: dreg[wsel][7:0]  <= y[7:0];
              rd68021_ucode_pkg::U_SIZE_WORD: dreg[wsel][15:0] <= y[15:0];
              default:                        dreg[wsel]       <= y;
            endcase
          end
          rd68021_ucode_pkg::U_DST_AREG: begin
            // An address register is always written full width, sign extended
            // from a word -- PRM 2.
            if (wsel == 3'd7) begin
              if (!super_mode)      usp_q <= y;
              else if (master_mode) msp_q <= y;
              else                  isp_q <= y;
            end else begin
              areg[wsel] <= y;
            end
          end
          rd68021_ucode_pkg::U_DST_SP: begin
            if (!super_mode)      usp_q <= y;
            else if (master_mode) msp_q <= y;
            else                  isp_q <= y;
          end
          default: ;
        endcase

        if (`UF(CCR) == rd68021_ucode_pkg::U_CCR_LOGIC) begin
          sr_q[rd68021_pkg::SR_N] <= res_n;
          sr_q[rd68021_pkg::SR_Z] <= res_z;
          sr_q[rd68021_pkg::SR_V] <= 1'b0;
          sr_q[rd68021_pkg::SR_C] <= 1'b0;
        end
      end
    end
  end

  assign cacr      = cacr_q;
  assign caar      = caar_q;
  assign cach_op   = 2'b00;
  assign ckpt_save = 1'b0;
  assign ckpt_load = 1'b0;

  assign rst_op_valid = 1'b0;
  assign rst_addr     = '0;
  assign rst_bytes    = '0;
  assign rst_fc       = rd68021_pkg::FC_SUPER_DATA;
  assign rst_rw       = 1'b1;
  assign rst_rmc      = 1'b0;
  assign rst_dob      = '0;

  assign reset_req    = 1'b0;
  assign dbf          = 1'b0;
  assign ipend_n_o    = 1'b1;

  // ==========================================================================
  // Not consumed yet.
  // ==========================================================================
  logic unused_seq;
  assign unused_seq = &{1'b1,
                        req_last, req_end, req_fault, req_fault_wr, req_dsack,
                        req_rdata[39:32],
                        flt_addr, flt_bytes, flt_fc, flt_rw, flt_rmc, flt_dob,
                        flt_dib,
                        stg_b, stg_d_fault, stg_c_fault, stg_b_fault,
                        stg_b_addr, ckpt_pc_fetch,
                        ipl_sync_n, reset_sync_n, halt_sync_n, bus_idle,
                        bus_granted, reset_busy,
                        dec_illegal, vbr_q, sfc_q, dfc_q,
                        `UF(COND),
                        COPROCESSOR};

  `undef UF

endmodule
