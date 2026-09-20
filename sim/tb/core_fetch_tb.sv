// RD68021 -- the walking skeleton.
//
// Reset, the instruction pipe, and the four instructions M5 builds: NOP, MOVEQ,
// MOVE.L Dn,Dn and both shapes of BRA. The same program is run three times, with
// its code in a 32-, a 16- and an 8-bit port, and must give the same answer each
// time -- which is the point of the operand engine in rd68021_biu, and the first
// thing that would break if the pipe and the bus contract disagreed.
//
// The exception vectors are always in the 32-bit port at $0, because that is
// where UM 6.1.1 puts them: "the reset exception ... fetches the initial
// interrupt stack pointer from the first long word of the vector table and the
// initial program counter from the second". So every run also crosses two port
// widths, which is worth having by accident.

`timescale 1ns / 1ps

module core_fetch_tb;

`include "rd68021_core_harness.svh"

  logic [31:0] base;
  int unsigned r;
  bit          reached;
  string       what;
  int unsigned i0;

  task automatic load(input logic [31:0] b);
    // The vectors. VBR is zero at reset, so these are absolute.
    poke_l(32'h0000_0000, 32'h0000_1000);      // initial interrupt stack pointer
    poke_l(32'h0000_0004, b + 32'h0400);       // initial program counter

    poke_w(b + 32'h0400, 16'h7042);            // MOVEQ #$42,D0
    poke_w(b + 32'h0402, 16'h4E71);            // NOP
    poke_w(b + 32'h0404, 16'h2200);            // MOVE.L D0,D1
    poke_w(b + 32'h0406, 16'h6002);            // BRA.B  *+4   -> $40A
    // The branched-over instructions must be OBSERVABLE, or a branch that lands
    // one instruction short still gives the right answer: a NOP here made a
    // deliberately wrong branch base pass this test unchanged.
    poke_w(b + 32'h0408, 16'h7A55);            // MOVEQ #$55,D5 -- must NOT run
    poke_w(b + 32'h040A, 16'h7E7F);            // MOVEQ #$7F,D7
    poke_w(b + 32'h040C, 16'h6000);            // BRA.W  *+6   -> $412
    poke_w(b + 32'h040E, 16'h0004);            //   ... displacement
    poke_w(b + 32'h0410, 16'h7C33);            // MOVEQ #$33,D6 -- must NOT run
    poke_w(b + 32'h0412, 16'h7400);            // MOVEQ #0,D2
    poke_w(b + 32'h0414, 16'h60FE);            // BRA.B  *+0   -- spin here
  endtask

  initial begin
    $display("core_fetch_tb: reset, the pipe, and four instructions");

    for (r = 0; r < 3; r = r + 1) begin
      case (r)
        0: begin base = 32'h0000_0000; what = "32-bit port"; end
        1: begin base = 32'h1000_0000; what = "16-bit port"; end
        default: begin base = 32'h2000_0000; what = " 8-bit port"; end
      endcase

      // Load before releasing reset: the core starts fetching the instant it
      // is let go, and an empty memory is not a test.
      load(base);
      reset_dut();
      i0 = instructions;

      // -----------------------------------------------------------------
      // Reset: UM 6.1.1. The stack pointer comes from $0 and the program
      // counter from $4, and execution starts there.
      // -----------------------------------------------------------------
      run_until(base + 32'h0414, 400, reached);
      check(reached, {what, ": the program reaches its spin"});

      check(dut.u_seq.isp_q === 32'h0000_1000,
            {what, ": the initial interrupt stack pointer came from $0"});

      // -----------------------------------------------------------------
      // What the instructions did
      // -----------------------------------------------------------------
      check(dut.u_seq.dreg[0] === 32'h0000_0042,
            {what, ": MOVEQ #$42,D0"});
      check(dut.u_seq.dreg[1] === 32'h0000_0042,
            {what, ": MOVE.L D0,D1"});
      check(dut.u_seq.dreg[7] === 32'h0000_007F,
            {what, ": MOVEQ #$7F,D7 ran"});
      check(dut.u_seq.dreg[5] === 32'h0000_0000,
            {what, ": BRA.B branched OVER the MOVEQ into D5"});
      check(dut.u_seq.dreg[2] === 32'h0000_0000,
            {what, ": MOVEQ #0,D2 ran"});
      check(dut.u_seq.dreg[6] === 32'h0000_0000,
            {what, ": BRA.W branched OVER the MOVEQ into D6"});

      // The NOPs at $408 and $410 are branched over. Six instructions run:
      // MOVEQ, NOP, MOVE.L, BRA.B, MOVEQ, BRA.W, MOVEQ -- seven, and then the
      // spinning BRA.B repeats.
      check((instructions - i0) >= 7,
            {what, ": at least seven instructions retired"});

      // -----------------------------------------------------------------
      // Condition codes. MOVEQ #0 sets Z and clears N; PRM 4.
      // -----------------------------------------------------------------
      check(dut.u_seq.sr_q[rd68021_pkg::SR_Z] === 1'b1,
            {what, ": MOVEQ #0 set Z"});
      check(dut.u_seq.sr_q[rd68021_pkg::SR_N] === 1'b0,
            {what, ": MOVEQ #0 cleared N"});
      check(dut.u_seq.sr_q[rd68021_pkg::SR_V] === 1'b0,
            {what, ": MOVEQ cleared V"});
      check(dut.u_seq.sr_q[rd68021_pkg::SR_C] === 1'b0,
            {what, ": MOVEQ cleared C"});

      // The supervisor bit and the interrupt mask are what reset left them.
      check(dut.u_seq.sr_q[rd68021_pkg::SR_S] === 1'b1,
            {what, ": still in supervisor mode"});
      check(dut.u_seq.sr_q[12:8] === 5'b00111,
            {what, ": the interrupt mask is still 7"});
    end

    // ---------------------------------------------------------------------
    // The pipe invariant ran, and held.
    // ---------------------------------------------------------------------
    // Not every boundary can be checked: with the queue empty -- which happens
    // whenever the fetch has not kept up, and after every flush -- stage B's
    // address is the word at PC plus two rather than plus four. The number is
    // printed so that a regression to zero is visible, which is the failure that
    // would make this test vacuous.
    $sformat(what, "the pipe invariant was checked at %0d of %0d boundaries",
             pipe_checks, instructions);
    check(pipe_checks >= 10, what);
    check(pipe_fails == 0, "the pipe was sequential at every boundary");

    $display("core_fetch_tb: %0d checks, %0d failures; %0d instructions, %0d pipe checks",
             checks, fails, instructions, pipe_checks);
    if (fails == 0) $display("PASS: core_fetch_tb");
    else            $display("FAIL: core_fetch_tb");
    $finish;
  end

  initial begin
    #500_000;
    $display("FAIL: core_fetch_tb timed out");
    $finish;
  end

endmodule
