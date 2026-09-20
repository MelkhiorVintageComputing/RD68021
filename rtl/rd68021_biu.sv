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
    output logic        fetch_last,
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
  logic        op_isfetch;   // the request came from the instruction fetch unit
  logic [39:0] op_data;      // write data, or the read accumulator, right justified

  // The cycle in flight, latched at the rising edge entering S0 so that every pin
  // is stable for the whole cycle whatever the operand state does.
  logic [31:0] cyc_addr;
  logic  [2:0] cyc_fc;
  logic  [1:0] cyc_siz;
  logic  [2:0] cyc_n;        // bytes this cycle asks for: min(op_rem, 4)
  logic        cyc_rw;
  logic        cyc_rmc;

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

  logic [1:0] dsack_q;       // the port size sampled at the end of S2
  logic       term_q;        // ... and whether it terminated the cycle at all

  // The operand finishes with the cycle that is ending now. This is the signal the
  // whole handshake turns on: req_last exports it, and the sequencer is expected
  // to have the next request already presented by the rising edge that consumes
  // it -- which is what the microword's successor previews are for.
  logic op_finishing;
  logic op_continuing;

  // A request is available to start a bus cycle. Data beats instruction fetch:
  // the sequencer is stalled on a data operand and the pipe is not.
  logic start_ok;
  assign start_ok = op_continuing || req_valid || fetch_valid;

  // The if/else inside each case item is not a style choice: iverilog rejects a
  // ternary of two enum values assigned to an enum variable with "This assignment
  // requires an explicit cast" (doc/coding-standard.md, measured).
  always_comb begin
    st_p_nxt = st_p;
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
      // The rising edge that ends S5 either starts the next cycle or goes idle.
      rd68021_pkg::ST_S5: begin
        if (start_ok) st_p_nxt = rd68021_pkg::ST_S0;
        else          st_p_nxt = rd68021_pkg::ST_IDLE;
      end
      default: st_p_nxt = rd68021_pkg::ST_IDLE;
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

  always_comb begin
    unique case (dsack_q)
      rd68021_pkg::DSACK_8:  port_bytes = 3'd1;
      rd68021_pkg::DSACK_16: port_bytes = 3'd2;
      rd68021_pkg::DSACK_32: port_bytes = 3'd4;
      default:               port_bytes = 3'd4;
    endcase
  end

  always_comb begin
    unique case (dsack_q)
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
      if (i_rd < xfer_n) begin
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

      // 3 bytes. The D7-D0 entry of the first row is the manual's OP0, which is
      // not one of the three bytes left to send; it is one of the two starred
      // "output but never used" cells, and Table 5-7 leaves that lane disabled.
      {rd68021_pkg::SIZ_3BYTE, 2'b00}: wr_lanes = {opb[0], opb[1], opb[2], opb[0]};
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
  // Starting a cycle, and starting an operand
  // ==========================================================================
  logic        take_req;
  logic        take_fetch;
  logic [31:0] next_addr;
  logic  [2:0] next_rem;
  logic  [2:0] next_fc;
  logic        next_rw;
  logic        next_rmc;

  // A new operand may be taken when none is active, or at the very edge the
  // active one completes.
  assign take_req   = !op_continuing && req_valid;
  assign take_fetch = !op_continuing && !req_valid && fetch_valid;

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
      default:
        cpu_space_addr = {12'h000, req_cpuspace, req_cpuaddr, 8'h00};
    endcase
  end

  always_comb begin
    if (take_req) begin
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
    end else begin
      // Continuing a multi-cycle operand. The residual is updated by the same
      // rising edge that latches these, so what the next cycle must carry is the
      // residual *after* this transfer, not before it.
      next_addr = op_addr + {29'd0, xfer_n};
      next_rem  = op_rem - xfer_n;
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

  assign op_finishing  = op_active && (st_n == rd68021_pkg::ST_S5)
                         && (op_rem == xfer_n);
  assign op_continuing = op_active && !op_finishing;

  // Combinational, and true throughout S5: the operand completes at the rising
  // edge that ends S5, which gives the sequencer half a clock to present the next
  // request. That half clock is the design's tightest path, by construction.
  assign req_last   = op_finishing && !op_isfetch;
  assign fetch_last = op_finishing &&  op_isfetch;

  // ==========================================================================
  // Rising-edge domain
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_p       <= rd68021_pkg::ST_IDLE;
      op_active  <= 1'b0;
      op_addr    <= '0;
      op_rem     <= '0;
      op_fc      <= '0;
      op_rw      <= 1'b1;
      op_rmc     <= 1'b0;
      op_first   <= 1'b1;
      op_isfetch <= 1'b0;
      op_data    <= '0;
      cyc_addr   <= '0;
      cyc_fc     <= '0;
      cyc_siz    <= rd68021_pkg::SIZ_LONG;
      cyc_n      <= '0;
      cyc_rw     <= 1'b1;
      cyc_rmc    <= 1'b0;
      req_ack    <= 1'b0;
      fetch_ack  <= 1'b0;
    end else begin
      st_p      <= st_p_nxt;
      req_ack   <= 1'b0;
      fetch_ack <= 1'b0;

      // The rising edge that ends S5. The cycle is over: take the bytes it moved
      // and advance the residual. Every register the operand owns is written
      // here and in the S0 arm below, both in this one block -- a register
      // written from both edge domains is two conflicting drivers, which is a
      // defect `make lint` now fails on.
      if (st_n == rd68021_pkg::ST_S5) begin
        op_first <= 1'b0;
        if (op_rw) op_data <= rd_merged;
        op_addr <= op_addr + {29'd0, xfer_n};
        op_rem  <= op_rem - xfer_n;
        if (op_finishing) begin
          op_active <= 1'b0;
          op_first  <= 1'b1;
          if (op_isfetch) fetch_ack <= 1'b1;
          else            req_ack   <= 1'b1;
        end
      end

      // Entering S0: latch everything the pins will carry for this whole cycle,
      // and start a new operand if this is the first cycle of one. This arm runs
      // after the one above in the same edge when a cycle follows immediately,
      // which is why next_addr and next_rem are written to see the post-transfer
      // residual.
      if (st_p_nxt == rd68021_pkg::ST_S0) begin
        cyc_addr <= next_addr;
        cyc_fc   <= next_fc;
        cyc_siz  <= this_siz;
        cyc_n    <= this_n;
        cyc_rw   <= next_rw;
        cyc_rmc  <= next_rmc;

        if (take_req || take_fetch) begin
          op_active  <= 1'b1;
          op_addr    <= next_addr;
          op_rem     <= next_rem;
          op_fc      <= next_fc;
          op_rw      <= next_rw;
          op_rmc     <= next_rmc;
          op_first   <= 1'b1;
          op_isfetch <= take_fetch;
          if (take_fetch) op_data <= '0;
          else            op_data <= req_wdata;
        end
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
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_n      <= rd68021_pkg::ST_IDLE;
      dsack_q   <= rd68021_pkg::DSACK_WAIT;
      term_q    <= 1'b0;
      d_latched <= '0;
    end else begin
      st_n <= st_n_nxt;

      // The sample: entering S3, and again at every ST_WL while waiting.
      if (st_n_nxt == rd68021_pkg::ST_S3 || st_n_nxt == rd68021_pkg::ST_WL) begin
        dsack_q <= dsack_n_i;
        term_q  <= (dsack_n_i != rd68021_pkg::DSACK_WAIT);
      end

      // Entering S5: latch the read data. dsack_q is held past here so that the
      // rising edge that ends S5 can still see which port answered.
      if (st_n_nxt == rd68021_pkg::ST_S5) begin
        d_latched <= d_i;
        term_q    <= 1'b0;
      end
    end
  end

  // ==========================================================================
  // Pins
  //
  // Each is written as the manual states it, in terms of the two state registers.
  // Only one of them changes at any instant, so every expression below settles on
  // exactly one edge.
  // ==========================================================================

  // ECS: one half clock at the start of every bus cycle. Asserted on the rising
  // edge entering S0 (specification 6A) and negated on the falling edge entering
  // S1 (specification 12A), which is the whole of specification 10's width.
  logic ecs_win;
  assign ecs_win = (st_p == rd68021_pkg::ST_S0) && (st_n != rd68021_pkg::ST_S1);
  assign ecs_n_o = ~ecs_win;

  // OCS: identical, but only for the first bus cycle of an operand (UM 5.1.1).
  assign ocs_n_o = ~(ecs_win && op_first);

  // AS: asserted on the falling edge entering S1, negated on the falling edge
  // entering S5. Purely a function of the negative-edge state.
  logic as_win;
  assign as_win = (st_n == rd68021_pkg::ST_S1) || (st_n == rd68021_pkg::ST_S3)
               || (st_n == rd68021_pkg::ST_WL);
  assign as_n_o = ~as_win;

  // DS: on a read it follows AS (UM 5.3.1 state 1, "the processor also asserts DS
  // during S1"). On a write it waits until S3, "indicating that the data on the
  // data bus is stable" (UM 5.3.2 state 3).
  logic ds_win;
  assign ds_win = cyc_rw ? as_win
                         : ((st_n == rd68021_pkg::ST_S3)
                            || (st_n == rd68021_pkg::ST_WL));
  assign ds_n_o = ~ds_win;

  // DBEN: on a read, asserted in S2 and negated in S5. On a write, asserted in S1
  // and held valid throughout S5. Active high -- it is not an _n signal.
  logic dben_win;
  always_comb begin
    if (cyc_rw) begin
      dben_win = ((st_p == rd68021_pkg::ST_S2) || (st_p == rd68021_pkg::ST_S4)
                  || (st_p == rd68021_pkg::ST_WH))
                 && (st_n != rd68021_pkg::ST_S5);
    end else begin
      dben_win = as_win
                 || ((st_n == rd68021_pkg::ST_S5) && (st_p == rd68021_pkg::ST_S4));
    end
  end
  assign dben_o = dben_win;

  assign fc_o    = cyc_fc;
  assign a_o     = cyc_addr;
  assign siz_o   = cyc_siz;
  assign rw_o    = cyc_rw;
  assign rmc_n_o = ~cyc_rmc;
  assign d_o     = wr_lanes;

  // Output enables. The address group is driven from S0 and released at the rising
  // edge that ends S5 (specification 7); the control group is driven always, and
  // is released only on bus relinquish and during RESET, which are M2.
  logic cyc_drive;
  assign cyc_drive = (st_p != rd68021_pkg::ST_IDLE);

  assign a_oe   = ADDR_HIZ_BETWEEN_CYCLES ? cyc_drive : 1'b1;
  assign fc_oe  = a_oe;
  assign siz_oe = a_oe;
  assign rmc_oe = a_oe;

  // Write data is driven from the rising edge entering S2 and held through S5.
  assign d_oe = !cyc_rw && ((st_p == rd68021_pkg::ST_S2)
                            || (st_p == rd68021_pkg::ST_S4)
                            || (st_p == rd68021_pkg::ST_WH));

  assign as_oe   = 1'b1;
  assign ds_oe   = 1'b1;
  assign rw_oe   = 1'b1;
  assign dben_oe = 1'b1;

  assign bg_n_o     = 1'b1;
  assign reset_n_o  = 1'b0;   // open drain: the enable is what asserts it
  assign reset_n_oe = 1'b0;
  assign halt_n_o   = 1'b0;
  assign halt_n_oe  = 1'b0;

  // ==========================================================================
  // Back to the sequencer
  // ==========================================================================
  assign req_rdata   = op_data;
  assign fetch_rdata = op_data[31:0];
  assign req_end      = rd68021_pkg::CE_DSACK;
  assign req_fault    = 1'b0;   // M2
  assign req_fault_wr = 1'b0;   // M2
  assign req_dsack    = dsack_q;
  assign fetch_fault  = 1'b0;   // M2

  assign flt_addr  = op_addr;
  assign flt_bytes = op_rem;
  assign flt_fc    = op_fc;
  assign flt_rw    = op_rw;
  assign flt_rmc   = op_rmc;
  assign flt_dob   = op_data[31:0];
  assign flt_dib   = op_data[31:0];

  assign reset_busy  = 1'b0;    // M2
  assign bus_idle    = (st_p == rd68021_pkg::ST_IDLE)
                       && (st_n == rd68021_pkg::ST_IDLE);
  assign bus_granted = 1'b0;    // M2

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
                        avec_n_i, berr_n_i,
                        br_sync_n, bgack_sync_n,
                        op_data[39:32]};

endmodule
