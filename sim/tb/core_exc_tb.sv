// RD68021 -- exception processing: M8.
//
// Every frame shape this milestone builds, built and then unwound: the
// four-word format $0, the six-word format $2, the throwaway format $1 that an
// interrupt leaves on the interrupt stack when the master stack was active, and
// the format error that an RTE raises when it does not recognise what it finds.
//
// The frames are checked as MEMORY, word by word against UM table 6-5, and not
// through the core's own registers. A frame that the core builds and reads back
// consistently but writes in the wrong order would pass any check made the
// other way, and a demand-paging handler is the thing that would find out.
//
// Everything runs in the 32-bit port, because the frames are the subject here
// and the operand engine has its own testbenches.

`timescale 1ns / 1ps

module core_exc_tb;

`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] MSP0 = 32'h0000_2000;
  localparam logic [31:0] USP0 = 32'h0000_3000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] HAND = 32'h0000_0500;

  bit          reached;
  logic [31:0] sp;

  // ------------------------------------------------------------------------
  // The thing on the other end of an interrupt acknowledge -- UM 5.4.1 and
  // 6.1.9. Three answers are possible and all three are tested: a vector
  // number on the bus, AVEC for the autovector, and nothing at all, which the
  // bus error turns into the spurious interrupt.
  //
  // The address is synthesised, not decoded from anything a memory owns
  // (figure 5-31: FC = 111, A19-A16 = $F, the level on A3-A1, A0 = 1), so this
  // device selects on the function code and the space type and not on an
  // address range.
  // ------------------------------------------------------------------------
  localparam int IACK_VECTOR = 0;   // answer with a vector number
  localparam int IACK_AUTO   = 1;   // answer with AVEC
  localparam int IACK_NONE   = 2;   // answer with BERR: spurious

  int unsigned iack_mode;
  logic  [7:0] iack_vec;
  int unsigned iacks;
  logic  [2:0] iack_level;
  initial begin
    iack_mode  = IACK_NONE;
    iack_vec   = 8'd0;
    iacks      = 0;
    iack_level = 3'd0;
  end

  wire iack_now = !as_n_o && (fc_o === 3'b111) && (a_o[19:16] === 4'hF);

  always @(*) begin
    dsack_ext  = 2'b11;
    avec_n_i   = 1'b1;
    berr_force = 1'b0;
    oe_ext     = 1'b0;
    d_ext     = 32'd0;
    if (iack_now) begin
      case (iack_mode)
        // An eight-bit port, so the vector number arrives on D31-D24 --
        // UM table 5-7, the only lane an eight-bit port ever drives.
        IACK_VECTOR: begin
          dsack_ext = 2'b10;
          oe_ext    = 1'b1;
          d_ext     = {iack_vec, 24'd0};
        end
        IACK_AUTO:   avec_n_i   = 1'b0;
        default:     berr_force = 1'b1;
      endcase
    end
  end

  // The level the core asked about, latched when it asks. UM figure 5-31 puts
  // it on A3-A1.
  // Triggered on the acknowledge ITSELF and not on the falling edge of AS that
  // makes it true: `iack_now` is a continuous assignment, so reading it inside
  // an `always @(negedge as_n_o)` is a delta-cycle race, and it read as false
  // every time.
  always @(posedge iack_now) begin
    iacks      = iacks + 1;
    iack_level = a_o[3:1];
    if (!ipl_hold)
      ipl_n_i  = 3'b111;   // a device drops its request when acknowledged
  end

  // ... or holds it until its handler clears it, as a clock chip does: a write
  // to IPL_CLR drops the request.
  localparam logic [31:0] IPL_CLR = 32'h0000_7000;
  bit ipl_hold;
  initial ipl_hold = 1'b0;
  always @(negedge as_n_o)
    if (rst_n && ipl_hold && !rw_o && a_o == IPL_CLR) ipl_n_i = 3'b111;

  // How long the RESET instruction held the pin -- PRM 6 says 512 clocks.
  int unsigned rsto_clocks;
  initial rsto_clocks = 0;
  always @(posedge clk) if (rst_n && reset_n_oe) rsto_clocks = rsto_clocks + 1;

  // Bus cycles, for the one test whose subject is that there are none.
  int unsigned starts;
  int unsigned k;
  string       what;
  initial starts = 0;
  always @(negedge as_n_o) if (rst_n) starts = starts + 1;

  task automatic run_cycles(input int n);
    repeat (n) @(negedge clk);
  endtask

  // Raise a request, and drop it once the core has acknowledged it -- which is
  // what a real device does, and what stops the same interrupt being taken
  // again the moment the handler's first instruction ends.
  task automatic request(input int unsigned level, input int unsigned mode,
                         input logic [7:0] vec);
    iack_mode = mode;
    iack_vec  = vec;
    ipl_n_i   = ~level[2:0];
  endtask

  // The vector table at zero, and a stack. Every test starts from here.
  task automatic base_setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1)
      poke_l(v * 4, 32'h0000_9000);   // an unexpected vector spins at $9000
    poke_w(32'h0000_9000, 16'h60FE);  // BRA *
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
  endtask

  // The three words every four-word frame has, UM table 6-5.
  task automatic check_f0(input logic [31:0] at, input logic [15:0] sr,
                          input logic [31:0] pc, input logic [3:0] fmt,
                          input logic [11:0] off, input string what);
    check(peek_w(at)      === sr,          {what, ": +$00 the status register"});
    check(peek_l(at + 2)  === pc,          {what, ": +$02 the program counter"});
    check(peek_w(at + 6)  === {fmt, off},  {what, ": +$06 the format and vector offset"});
  endtask

  initial begin
    $display("core_exc_tb: the frames of M8, built and unwound");

    // ======================================================================
    // Format $0 -- an illegal instruction, UM 6.1.5, vector 4.
    //
    // Table 6-5 stacks the address of the instruction that caused it, so the
    // handler must step the stacked program counter itself or RTE returns to
    // the same word for ever. That is the whole difference between format $0
    // and format $2, and stepping it here is what proves the frame is where
    // the manual says it is.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0010, HAND);           // vector 4
    poke_w(CODE + 0, 16'h4AFC);            // ILLEGAL
    poke_w(CODE + 2, 16'h7001);            // MOVEQ #1,D0
    poke_w(CODE + 4, 16'h60FE);            // BRA *
    poke_w(HAND + 0, 16'h222F);            // MOVE.L (2,A7),D1 -- the stacked PC
    poke_w(HAND + 2, 16'h0002);
    poke_w(HAND + 4, 16'h54AF);            // ADDQ.L #2,(2,A7) -- step it
    poke_w(HAND + 6, 16'h0002);
    poke_w(HAND + 8, 16'h4E73);            // RTE
    reset_dut();
    run_until(CODE + 4, 2000, reached);
    check(reached, "illegal: the program gets past the handler");
    // The handler stepped +$02 itself, so what is there now is one instruction
    // on; D1 is what it found, and that is the value table 6-5 specifies.
    check_f0(ISP0 - 8, 16'h2700, CODE + 2, 4'h0, 12'h010, "illegal");
    check(dut.u_seq.dreg[1] === CODE,
          "illegal: +$02 was the address of the instruction that faulted");
    check(dut.u_seq.dreg[0] === 32'h0000_0001,
          "illegal: RTE came back to the instruction after it");
    check(dut.u_seq.isp_q === ISP0, "illegal: RTE put the stack back");

    // ======================================================================
    // Format $2 -- TRAPV, UM 6.1.8, vector 7. Six words: the next instruction
    // at +$02 and the one that trapped at +$08.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_001C, HAND);           // vector 7
    poke_w(CODE + 0, 16'h003C);            // ORI #$02,CCR -- set V
    poke_w(CODE + 2, 16'h0002);
    poke_w(CODE + 4, 16'h4E76);            // TRAPV
    poke_w(CODE + 6, 16'h7002);            // MOVEQ #2,D0
    poke_w(CODE + 8, 16'h60FE);            // BRA *
    poke_w(HAND + 0, 16'h4E73);            // RTE -- no fixing up needed
    reset_dut();
    run_until(CODE + 8, 2000, reached);
    check(reached, "TRAPV: the program gets past the handler");
    check_f0(ISP0 - 12, 16'h2702, CODE + 6, 4'h2, 12'h01C, "TRAPV");
    check(peek_l(ISP0 - 4) === CODE + 4,
          "TRAPV: +$08 the address of the instruction that trapped");
    check(dut.u_seq.dreg[0] === 32'h0000_0002,
          "TRAPV: RTE came back to the NEXT instruction, unaided");
    check(dut.u_seq.isp_q === ISP0, "TRAPV: RTE put the six-word frame back");

    // ======================================================================
    // TRAP #n -- vector 32 + n, format $0, and the NEXT instruction stacked.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'h4E43);            // TRAP #3   -> vector 35
    poke_w(CODE + 2, 16'h7003);            // MOVEQ #3,D0
    poke_w(CODE + 4, 16'h60FE);            // BRA *
    poke_l(32'h0000_008C, HAND);           // vector 35
    poke_w(HAND + 0, 16'h4E73);            // RTE
    reset_dut();
    run_until(CODE + 4, 2000, reached);
    check(reached, "TRAP #3: the program gets past the handler");
    check_f0(ISP0 - 8, 16'h2700, CODE + 2, 4'h0, 12'h08C, "TRAP #3");
    check(dut.u_seq.dreg[0] === 32'h0000_0003, "TRAP #3: and returned");

    // ======================================================================
    // Privilege violation -- UM 6.1.6, vector 8, format $0 and the faulting
    // instruction. Getting to user mode at all is the other half of the test:
    // it is the only way the user stack pointer is ever the active one.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0020, HAND);           // vector 8
    poke_w(CODE + 0, 16'h46FC);            // MOVE #$0000,SR -- drop to user
    poke_w(CODE + 2, 16'h0000);
    poke_w(CODE + 4, 16'h46FC);            // MOVE #$2700,SR -- privileged now
    poke_w(CODE + 6, 16'h2700);
    poke_w(CODE + 8, 16'h60FE);            // BRA *
    poke_w(HAND + 0, 16'h7004);            // MOVEQ #4,D0
    poke_w(HAND + 2, 16'h60FE);            // BRA * -- stay in the handler
    reset_dut();
    // The user stack pointer has to exist before the drop into user mode.
    dut.u_seq.usp_q = USP0;
    run_until(HAND + 2, 2000, reached);
    check(reached, "privilege: the handler runs");
    check(dut.u_seq.dreg[0] === 32'h0000_0004, "privilege: and only the handler");
    // The frame is on the INTERRUPT stack, not the user one -- UM 6.1 step
    // three builds it on the active SUPERVISOR stack, whichever stack the
    // instruction that faulted was using.
    check_f0(ISP0 - 8, 16'h0000, CODE + 4, 4'h0, 12'h020, "privilege");
    check(dut.u_seq.usp_q === USP0, "privilege: the user stack is untouched");

    // ======================================================================
    // Format error -- UM 6.1.12, vector 14. RTE reads a format word it does
    // not recognise, and must leave the frame where it found it.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0038, HAND);           // vector 14
    poke_w(CODE + 0, 16'h4E73);            // RTE, on a frame we build by hand
    poke_w(HAND + 0, 16'h7005);            // MOVEQ #5,D0
    poke_w(HAND + 2, 16'h60FE);            // BRA *
    // The stack pointer comes from $0 at reset, so a deposit made here would be
    // overwritten by the reset exception a few clocks later. Point the vector
    // at the hand-built frame instead.
    poke_l(32'h0000_0000, ISP0 - 8);
    reset_dut();
    // A frame with format $7, which this part does not define.
    poke_w(ISP0 - 8, 16'h2700);
    poke_l(ISP0 - 6, CODE);
    poke_w(ISP0 - 2, 16'h7000);            // format $7, vector offset 0
    run_until(HAND + 2, 2000, reached);
    check(reached, "format error: the handler runs");
    check(dut.u_seq.dreg[0] === 32'h0000_0005, "format error: vector 14");
    // UM 6.1.12: "the processor creates a format error exception stack frame on
    // top of the stack frame it could not use", so the bad one survives below.
    check(peek_w(ISP0 - 2) === 16'h7000,
          "format error: the frame it could not use is still there");
    check_f0(ISP0 - 16, 16'h2700, CODE, 4'h0, 12'h038, "format error");

    // ======================================================================
    // Trace -- UM 6.1.7, vector 9, format $2. T1 traces every instruction, and
    // the frame carries the next instruction at +$02 and the traced one at
    // +$08.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0024, HAND);           // vector 9
    poke_w(CODE + 0, 16'h46FC);            // MOVE #$8700,SR -- T1 on
    poke_w(CODE + 2, 16'h8700);
    poke_w(CODE + 4, 16'h7006);            // MOVEQ #6,D0 -- this one is traced
    poke_w(CODE + 6, 16'h60FE);            // BRA *
    poke_w(HAND + 0, 16'h7277);            // MOVEQ #$77,D1
    poke_w(HAND + 2, 16'h60FE);            // BRA *
    reset_dut();
    run_until(HAND + 2, 2000, reached);
    check(reached, "trace: the handler runs");
    // UM table 6-2 reads the trace bits at the START of an instruction, so the
    // MOVE that turns tracing on is NOT itself traced -- the MOVEQ after it is
    // the first traced instruction, and D0 proves it ran before the trap.
    check_f0(ISP0 - 12, 16'h8700, CODE + 6, 4'h2, 12'h024, "trace");
    check(peek_l(ISP0 - 4) === CODE + 4,
          "trace: +$08 the address of the instruction that was traced");
    check(dut.u_seq.dreg[0] === 32'h0000_0006,
          "trace: the traced instruction ran, and the trap came after it");
    check(dut.u_seq.dreg[1] === 32'h0000_0077, "trace: the handler ran");


    // ======================================================================
    // An interrupt with a vector number -- UM 6.1.9 and 5.4.1. The acknowledge
    // cycle runs in CPU space type $F with the level on A3-A1, and what comes
    // back on the bus is the vector number.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0100, HAND);           // vector 64
    // The mask has to come down first: reset leaves it at 7, and UM 6.1.9
    // takes an interrupt only when the level is ABOVE the mask.
    poke_w(CODE + 0, 16'h46FC);            // MOVE #$2000,SR -- mask 0
    poke_w(CODE + 2, 16'h2000);
    poke_w(CODE + 4, 16'h60FE);            // BRA * -- interrupted here
    poke_w(HAND + 0, 16'h7221);            // MOVEQ #$21,D1
    poke_w(HAND + 2, 16'h60FE);            // BRA *
    reset_dut();
    run_cycles(40);
    request(5, IACK_VECTOR, 8'd64);
    run_until(HAND + 2, 2000, reached);
    check(reached, "interrupt: the handler runs");
    check(iack_level === 3'd5, "interrupt: the acknowledge asked about level 5");
    check_f0(ISP0 - 8, 16'h2000, CODE + 4, 4'h0, 12'h100, "interrupt");
    // UM 6.1: "for the reset and interrupt exceptions, the processor also
    // updates the interrupt priority mask".
    check(dut.u_seq.sr_q[10:8] === 3'd5, "interrupt: the mask went up to 5");
    check(dut.u_seq.dreg[1] === 32'h0000_0021, "interrupt: and only the handler");

    // ======================================================================
    // The same, answered with AVEC: the autovector for the level, 24 + level
    // -- UM table 6-1.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0074, HAND);           // vector 29 = 24 + 5
    // The mask has to come down first: reset leaves it at 7, and UM 6.1.9
    // takes an interrupt only when the level is ABOVE the mask.
    poke_w(CODE + 0, 16'h46FC);            // MOVE #$2000,SR -- mask 0
    poke_w(CODE + 2, 16'h2000);
    poke_w(CODE + 4, 16'h60FE);
    poke_w(HAND + 0, 16'h7222);            // MOVEQ #$22,D1
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    run_cycles(40);
    request(5, IACK_AUTO, 8'd0);
    run_until(HAND + 2, 2000, reached);
    check(reached, "autovector: the handler runs");
    check_f0(ISP0 - 8, 16'h2000, CODE + 4, 4'h0, 12'h074, "autovector");
    check(dut.u_seq.dreg[1] === 32'h0000_0022, "autovector: vector 24 + 5");

    // ======================================================================
    // ... and with nothing at all. UM 6.1.9: "if an external device does not
    // respond ... the bus error signal should be asserted to terminate the
    // cycle ... the spurious interrupt vector number (24)".
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0060, HAND);           // vector 24
    // The mask has to come down first: reset leaves it at 7, and UM 6.1.9
    // takes an interrupt only when the level is ABOVE the mask.
    poke_w(CODE + 0, 16'h46FC);            // MOVE #$2000,SR -- mask 0
    poke_w(CODE + 2, 16'h2000);
    poke_w(CODE + 4, 16'h60FE);
    poke_w(HAND + 0, 16'h7223);            // MOVEQ #$23,D1
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    run_cycles(40);
    request(5, IACK_NONE, 8'd0);
    run_until(HAND + 2, 2000, reached);
    check(reached, "spurious: the handler runs");
    check_f0(ISP0 - 8, 16'h2000, CODE + 4, 4'h0, 12'h060, "spurious");
    check(dut.u_seq.dreg[1] === 32'h0000_0023, "spurious: vector 24");

    // ======================================================================
    // The M bit and the throwaway frame -- UM 6.1.9.
    //
    //   "If the M-bit in the SR is set, the processor clears the M-bit and
    //    creates a throwaway exception stack frame on top of the interrupt
    //    stack ... this second frame contains the same PC value and vector
    //    offset as the frame created on top of the master stack, but has a
    //    format number of 1 ... the copy of the SR saved on the throwaway
    //    frame is exactly the same as that placed on the master stack except
    //    that the S-bit is set."
    //
    // The interrupt is taken from USER mode with M set, which is the case the
    // parenthesis in the manual is about: the copy on the master stack has S
    // clear and the copy on the interrupt stack has it set, so the two frames
    // are visibly different and a test can tell them apart.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0108, HAND);           // vector 66
    poke_w(CODE +  0, 16'h46FC);           // MOVE #$3000,SR -- S, M, mask 0
    poke_w(CODE +  2, 16'h3000);
    poke_w(CODE +  4, 16'h2E7C);           // MOVE.L #MSP0,A7 -- which is MSP
    poke_l(CODE +  6, MSP0);
    poke_w(CODE + 10, 16'h46FC);           // MOVE #$1000,SR -- user, M still set
    poke_w(CODE + 12, 16'h1000);
    poke_w(CODE + 14, 16'h60FE);           // BRA * -- interrupted here
    poke_w(HAND +  0, 16'h7224);           // MOVEQ #$24,D1
    poke_w(HAND +  2, 16'h4E73);           // RTE -- through both frames
    reset_dut();
    dut.u_seq.usp_q = USP0;
    run_cycles(60);
    request(3, IACK_VECTOR, 8'd66);
    run_until(HAND + 2, 2000, reached);
    check(reached, "master: the handler runs");
    // The ordinary frame, on the master stack, with the status register as the
    // interrupted program had it: user mode, M set.
    check_f0(MSP0 - 8, 16'h1000, CODE + 14, 4'h0, 12'h108, "master");
    // The throwaway, on the interrupt stack: the same again but format $1 and
    // the S bit set.
    check_f0(ISP0 - 8, 16'h3000, CODE + 14, 4'h1, 12'h108, "throwaway");
    check(dut.u_seq.sr_q[rd68021_pkg::SR_M] === 1'b0,
          "master: M is clear once the throwaway is built");
    check(dut.u_seq.isp_q === ISP0 - 8, "master: the handler runs on ISP");
    check(dut.u_seq.msp_q === MSP0 - 8, "master: the master frame is on MSP");
    check(dut.u_seq.dreg[1] === 32'h0000_0024, "master: the handler ran");

    // And back out again: the RTE reads format $1, steps the interrupt stack,
    // writes the status register it found -- which makes A7 the master stack
    // again -- and starts over on the frame it finds there.
    run_until(CODE + 14, 2000, reached);
    check(reached, "throwaway: RTE goes through both frames and returns");
    check(dut.u_seq.isp_q === ISP0, "throwaway: the interrupt stack is back");
    check(dut.u_seq.msp_q === MSP0, "throwaway: the master stack is back");
    check(dut.u_seq.sr_q[15:0] === 16'h1000,
          "throwaway: and so is the status register the program had");

    // ======================================================================
    // STOP -- PRM 6. The processor stops fetching and executing; a trace, an
    // interrupt or a reset starts it again. The interrupt is judged against
    // the mask STOP itself wrote, which is why the status register is written
    // by the microword BEFORE the one that stops.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0100, HAND);           // vector 64
    poke_w(CODE + 0, 16'h4E72);            // STOP #$2000 -- supervisor, mask 0
    poke_w(CODE + 2, 16'h2000);
    poke_w(CODE + 4, 16'h7001);            // MOVEQ #1,D0
    poke_w(CODE + 6, 16'h60FE);            // BRA *
    poke_w(HAND + 0, 16'h7225);            // MOVEQ #$25,D1
    poke_w(HAND + 2, 16'h4E73);            // RTE
    reset_dut();
    run_cycles(60);
    check(dut.u_seq.stopped_q === 1'b1, "STOP: the processor is stopped");
    check(dut.u_seq.sr_q[15:0] === 16'h2000, "STOP: the immediate went to SR");
    starts = 0;
    run_cycles(60);
    check(starts == 0, "STOP: and runs no bus cycle while it is");
    request(3, IACK_VECTOR, 8'd64);
    run_until(CODE + 6, 2000, reached);
    check(reached, "STOP: an interrupt starts it again");
    check(dut.u_seq.dreg[1] === 32'h0000_0025, "STOP: the handler ran");
    check(dut.u_seq.dreg[0] === 32'h0000_0001,
          "STOP: and RTE came back to the instruction after the STOP");
    check_f0(ISP0 - 8, 16'h2000, CODE + 4, 4'h0, 12'h100, "STOP");

    // ======================================================================
    // RESET -- PRM 6: "asserts the RSTO signal for 512 clock periods ... the
    // processor state, other than the program counter, is unaffected, and
    // execution continues with the next instruction".
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'h7042);            // MOVEQ #$42,D0 -- state to preserve
    poke_w(CODE + 2, 16'h4E70);            // RESET
    poke_w(CODE + 4, 16'h7201);            // MOVEQ #1,D1
    poke_w(CODE + 6, 16'h60FE);            // BRA *
    reset_dut();
    rsto_clocks = 0;
    run_until(CODE + 6, 3000, reached);
    check(reached, "RESET: execution continues with the next instruction");
    check(rsto_clocks == 512, "RESET: the pin was held for 512 clocks");
    check(dut.u_seq.dreg[0] === 32'h0000_0042, "RESET: the state is unaffected");
    check(dut.u_seq.dreg[1] === 32'h0000_0001, "RESET: and the next one ran");

    // A user-mode RESET is a privilege violation and nothing else -- the pin
    // must not move.
    base_setup();
    poke_l(32'h0000_0020, HAND);           // vector 8
    poke_w(CODE + 0, 16'h46FC);            // MOVE #$0000,SR -- user
    poke_w(CODE + 2, 16'h0000);
    poke_w(CODE + 4, 16'h4E70);            // RESET
    poke_w(CODE + 6, 16'h60FE);
    poke_w(HAND + 0, 16'h7226);            // MOVEQ #$26,D1
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    dut.u_seq.usp_q = USP0;
    rsto_clocks = 0;
    run_until(HAND + 2, 2000, reached);
    check(reached, "RESET in user mode: the privilege handler runs");
    check(rsto_clocks == 0, "RESET in user mode: the pin never moved");


    // ======================================================================
    // Trace on change of flow -- UM table 6-2, T1T0 = 01: "trace on change of
    // flow". The instruction that is not a change of flow is NOT traced, which
    // is the half of the mode a T1 test cannot see.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0024, HAND);           // vector 9
    poke_w(CODE +  0, 16'h46FC);           // MOVE #$4700,SR -- T0 alone
    poke_w(CODE +  2, 16'h4700);
    poke_w(CODE +  4, 16'h7006);           // MOVEQ #6,D0 -- NOT a change of flow
    poke_w(CODE +  6, 16'h6002);           // BRA.B over the next -- and this is
    poke_w(CODE +  8, 16'h7007);           // MOVEQ #7,D0 -- must not run
    poke_w(CODE + 10, 16'h60FE);
    poke_w(HAND +  0, 16'h7277);           // MOVEQ #$77,D1
    poke_w(HAND +  2, 16'h60FE);
    reset_dut();
    run_until(HAND + 2, 2000, reached);
    check(reached, "flow trace: the handler runs");
    check(dut.u_seq.dreg[0] === 32'h0000_0006,
          "flow trace: the MOVEQ ran and was not traced");
    check(dut.u_seq.dreg[1] === 32'h0000_0077, "flow trace: the handler ran");
    // +$02 is where execution would have gone next, which for a taken branch
    // is its target and not the word after it.
    check_f0(ISP0 - 12, 16'h4700, CODE + 10, 4'h2, 12'h024, "flow trace");
    check(peek_l(ISP0 - 4) === CODE + 6,
          "flow trace: +$08 is the branch, not the MOVEQ before it");

    // ======================================================================
    // An interrupt taken at the boundary of the instruction that LOWERED the
    // mask -- UM 6.1.9. The request stands from reset and is masked; the MOVE
    // admits it, and the instruction after the MOVE must not run first.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0100, HAND);           // vector 64
    poke_w(CODE + 0, 16'h46FC);            // MOVE #$2000,SR -- mask 7 -> 0
    poke_w(CODE + 2, 16'h2000);
    poke_w(CODE + 4, 16'h7001);            // MOVEQ #1,D0 -- must NOT run first
    poke_w(CODE + 6, 16'h60FE);
    poke_w(HAND + 0, 16'h7231);            // MOVEQ #$31,D1
    poke_w(HAND + 2, 16'h60FE);
    iack_mode = IACK_VECTOR;
    iack_vec  = 8'd64;
    ipl_n_i   = ~3'd3;                     // standing before reset is released
    reset_dut();
    // Reset leaves the mask at 7 -- UM 6.1.1 -- so a level 3 is not pending and
    // the pin must say so.
    run_cycles(10);
    check(ipend_n_o === 1'b1, "mask: IPEND is negated while the mask covers it");
    run_until(HAND + 2, 2000, reached);
    check(reached, "mask: lowering the mask lets the interrupt in");
    check(dut.u_seq.dreg[0] === 32'h0000_0000,
          "mask: and it came in before the next instruction, not after it");
    check(dut.u_seq.dreg[1] === 32'h0000_0031, "mask: the handler ran");
    check_f0(ISP0 - 8, 16'h2000, CODE + 4, 4'h0, 12'h100, "mask");

    // ======================================================================
    // The same boundary through ANDI and EORI to SR, and a trace turned on by
    // ORI to SR. The sequencer computes the status register a decoding
    // microword writes from SR and T0 itself, not from the result bus
    // (doc/critical-path.md), and these are the three shapes besides MOVE.
    // ======================================================================
    for (k = 0; k < 2; k++) begin
      base_setup();
      poke_l(32'h0000_0100, HAND);         // vector 64
      if (k == 0) begin
        poke_w(CODE + 0, 16'h027C);        // ANDI #$F8FF,SR -- mask 7 -> 0
        poke_w(CODE + 2, 16'hF8FF);
      end else begin
        poke_w(CODE + 0, 16'h0A7C);        // EORI #$0700,SR -- mask 7 -> 0
        poke_w(CODE + 2, 16'h0700);
      end
      poke_w(CODE + 4, 16'h7001);          // MOVEQ #1,D0 -- must NOT run first
      poke_w(CODE + 6, 16'h60FE);
      poke_w(HAND + 0, 16'h7231);          // MOVEQ #$31,D1
      poke_w(HAND + 2, 16'h60FE);
      iack_mode = IACK_VECTOR;
      iack_vec  = 8'd64;
      ipl_n_i   = ~3'd3;
      reset_dut();
      run_until(HAND + 2, 2000, reached);
      what = (k == 0) ? "ANDI to SR" : "EORI to SR";
      check(reached, {what, ": lowering the mask lets the interrupt in"});
      check(dut.u_seq.dreg[0] === 32'h0000_0000,
            {what, ": before the next instruction, not after it"});
      check_f0(ISP0 - 8, 16'h2000, CODE + 4, 4'h0, 12'h100, what);
      ipl_n_i = 3'b111;
    end

    base_setup();
    poke_l(32'h0000_0024, HAND);           // vector 9
    poke_w(CODE + 0, 16'h007C);            // ORI #$8000,SR -- T1 on
    poke_w(CODE + 2, 16'h8000);
    poke_w(CODE + 4, 16'h7006);            // MOVEQ #6,D0 -- this one is traced
    poke_w(CODE + 6, 16'h60FE);
    poke_w(HAND + 0, 16'h7277);            // MOVEQ #$77,D1
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    run_until(HAND + 2, 2000, reached);
    check(reached, "ORI to SR trace: the handler runs");
    check_f0(ISP0 - 12, 16'hA700, CODE + 6, 4'h2, 12'h024, "ORI to SR trace");
    check(peek_l(ISP0 - 4) === CODE + 4,
          "ORI to SR trace: the MOVEQ after it was the one traced");
    check(dut.u_seq.dreg[0] === 32'h0000_0006,
          "ORI to SR trace: and it ran before the trap");

    // ======================================================================
    // CHK -- PRM 4, vector 6. The sequencer decides "below zero" and "above
    // the bound" from the register and the bound themselves, not from the
    // result bus (doc/critical-path.md), and the sweep only runs CHK in bounds,
    // so both trapping arms are here, at both sizes, with the N bit PRM 4 says
    // each leaves: set below zero, clear above the bound.
    //
    //          size    D0             bound         traps  N
    // ======================================================================
    for (k = 0; k < 7; k++) begin
      logic [31:0] d0v;
      bit          lng, trap, nset;
      case (k)
        0: begin lng = 0; d0v = 32'hFFFF_FFF0; trap = 1; nset = 1; end  // -16
        1: begin lng = 0; d0v = 32'h0000_0070; trap = 1; nset = 0; end  // 112 > 100
        2: begin lng = 0; d0v = 32'h0001_0050; trap = 0; nset = 0; end  // word 80
        3: begin lng = 0; d0v = 32'h0000_0064; trap = 0; nset = 0; end  // on the bound
        4: begin lng = 1; d0v = 32'h0001_0000; trap = 1; nset = 0; end  // 65536 > 100
        5: begin lng = 1; d0v = 32'h8000_0000; trap = 1; nset = 1; end  // most negative
        default: begin lng = 1; d0v = 32'h0000_0064; trap = 0; nset = 0; end
      endcase
      base_setup();
      poke_l(32'h0000_0018, HAND);         // vector 6
      poke_w(HAND, 16'h60FE);              // BRA *
      poke_w(CODE + 0, 16'h203C);          // MOVE.L #d0v,D0
      poke_l(CODE + 2, d0v);
      if (lng) begin
        poke_w(CODE + 6, 16'h413C);        // CHK.L #100,D0
        poke_l(CODE + 8, 32'd100);
        poke_w(CODE + 12, 16'h7E01);       // MOVEQ #1,D7
        poke_w(CODE + 14, 16'h60FE);
      end else begin
        poke_w(CODE + 6, 16'h41BC);        // CHK.W #100,D0
        poke_w(CODE + 8, 16'd100);
        poke_w(CODE + 10, 16'h7E01);       // MOVEQ #1,D7
        poke_w(CODE + 12, 16'h60FE);
      end
      reset_dut();
      dut.u_seq.dreg[7] = 32'h0;
      run_until(HAND, 600, reached);
      what = $sformatf("CHK.%s with D0=%08h", lng ? "L" : "W", d0v);
      check(reached === trap, {what, trap ? ": traps" : ": does not trap"});
      if (trap)
        check(dut.u_seq.sr_q[3] === nset, {what, nset ? ": sets N" : ": clears N"});
      else
        check(dut.u_seq.dreg[7] === 32'h1, {what, ": carries on"});
    end

    // ======================================================================
    // Level seven -- UM 6.1.9. "A level 7 interrupt is nonmaskable", and what
    // makes a second one happen where a second level 6 would not is the
    // TRANSITION to seven, not the level itself.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_007C, HAND);           // autovector 31 = 24 + 7
    poke_w(CODE + 0, 16'h60FE);            // BRA * -- mask is still 7
    poke_w(HAND + 0, 16'h7232);            // MOVEQ #$32,D1
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    run_cycles(40);
    request(7, IACK_AUTO, 8'd0);
    run_until(HAND + 2, 2000, reached);
    check(reached, "level 7: taken although the mask is already 7");
    check(iack_level === 3'd7, "level 7: the acknowledge asked about level 7");
    check(dut.u_seq.dreg[1] === 32'h0000_0032, "level 7: autovector 31");
    check_f0(ISP0 - 8, 16'h2700, CODE, 4'h0, 12'h07C, "level 7");

    // ======================================================================
    // A level 7 the device holds until its handler clears it -- the Sun-3's
    // clock. It is one transition, so it is one interrupt: the handler's own
    // boundaries see level 7 against a level 7, not a new edge. Taken from a
    // running program, and taken from STOP, which leaves by no decode
    // boundary; that path remembered the level from before the STOP, and the
    // handler's first boundary took the interrupt again, nested.
    // ======================================================================
    for (k = 0; k < 2; k++) begin
      int unsigned i0;
      base_setup();
      poke_l(32'h0000_007C, HAND);         // autovector 31 = 24 + 7
      if (k == 0) begin
        poke_w(CODE + 0, 16'h60FE);        // BRA * -- mask is still 7
      end else begin
        poke_w(CODE + 0, 16'h4E72);        // STOP #$2700
        poke_w(CODE + 2, 16'h2700);
        poke_w(CODE + 4, 16'h60FE);
      end
      poke_w(HAND + 0, 16'h7232);          // MOVEQ #$32,D1 -- a boundary first
      poke_w(HAND + 2, 16'h4E71);          // NOP
      poke_w(HAND + 4, 16'h11C0);          // MOVE.B D0,($7000).W -- clear it
      poke_w(HAND + 6, 16'h7000);
      poke_w(HAND + 8, 16'h4E73);          // RTE
      reset_dut();
      ipl_hold = 1'b1;
      run_cycles(60);
      i0 = iacks;
      request(7, IACK_AUTO, 8'd0);
      run_cycles(1500);
      what = (k == 0) ? "held level 7" : "held level 7 from STOP";
      check(iacks - i0 == 1, $sformatf("%s: acknowledged once, not %0d times",
                                       what, iacks - i0));
      check(dut.u_seq.dreg[1] === 32'h0000_0032, {what, ": the handler ran"});
      check(dut.u_seq.isp_q === ISP0, {what, ": and returned, frame and all"});
      check(dut.u_ifu.pc_d === ((k == 0) ? CODE : CODE + 4),
            {what, ": to where it was"});
      ipl_hold = 1'b0;
    end

    // ======================================================================
    // Done
    // ======================================================================
    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_exc_tb: %0d checks, %0d failed, %0d pipe checks",
             checks, fails, pipe_checks);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_exc_tb");
    else                               $display("FAIL: core_exc_tb");
    $finish;
  end

endmodule
