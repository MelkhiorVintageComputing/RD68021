// RD68021 -- instructions the generated sweep cannot judge.
//
// Every case here is one where Musashi is not authoritative and the expectation
// is written from the manual instead -- doc/divergences.md says which and why
// for each. They are directed tests because there is nothing to compare
// against, not because they are hard.

`timescale 1ns / 1ps

module core_insn_tb;

`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] DATA = 32'h0000_2000;

  bit          reached;
  logic [15:0] got;

  task automatic setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1) poke_l(v * 4, 32'h0000_9000);
    poke_w(32'h0000_9000, 16'h60FE);
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
  endtask

  initial begin
    $display("core_insn_tb: instructions with no oracle");

    // ======================================================================
    // PACK -(A3),-(A2),#adj -- PRM 4.
    //
    // The case that needs no reasoning about diagrams: the two bytes of the
    // string "42" are $34 and $32, at increasing addresses, and packing them
    // has to give $42. Adjusting by -$3030 is what turns ASCII into BCD, and
    // it is the only thing the adjustment word is ever used for.
    // ======================================================================
    setup();
    poke_w(DATA, 16'h3432);                // "42", '4' at the lower address
    poke_w(DATA + 8, 16'h0000);            // and somewhere else to land
    poke_w(CODE + 0, 16'h247C);            // MOVEA.L #DATA+9,A2
    poke_l(CODE + 2, DATA + 9);
    poke_w(CODE + 6, 16'h267C);            // MOVEA.L #DATA+2,A3
    poke_l(CODE + 8, DATA + 2);
    poke_w(CODE + 12, 16'h854B);           // PACK -(A3),-(A2),#-$3030
    poke_w(CODE + 14, 16'hCFD0);
    poke_w(CODE + 16, 16'h60FE);
    reset_dut();
    run_until(CODE + 16, 2000, reached);
    check(reached, "PACK: the program finishes");
    got = peek_w(DATA + 8);
    check(got[15:8] === 8'h42,
          "PACK: the digits of \"42\" pack into $42, in that order");
    check(dut.u_seq.areg[3] === DATA,
          "PACK: the source register stepped back two bytes");
    check(dut.u_seq.areg[2] === DATA + 8,
          "PACK: and the destination one byte");

    // ======================================================================
    // UNPK -(A3),-(A2),#adj -- the reverse, and the same question about which
    // byte is which. $42 unpacked and adjusted by +$3030 is the string "42",
    // with '4' at the lower address again.
    // ======================================================================
    setup();
    poke_w(DATA + 2, 16'h4200);            // the packed byte at DATA+2
    poke_w(DATA, 16'h0000);
    poke_w(CODE + 0, 16'h247C);            // MOVEA.L #DATA+2,A2
    poke_l(CODE + 2, DATA + 2);
    poke_w(CODE + 6, 16'h267C);            // MOVEA.L #DATA+3,A3
    poke_l(CODE + 8, DATA + 3);
    poke_w(CODE + 12, 16'h858B);           // UNPK -(A3),-(A2),#$3030
    poke_w(CODE + 14, 16'h3030);
    poke_w(CODE + 16, 16'h60FE);
    reset_dut();
    run_until(CODE + 16, 2000, reached);
    check(reached, "UNPK: the program finishes");
    check(peek_w(DATA) === 16'h3432,
          "UNPK: $42 unpacks into \"42\", the significant digit first");
    check(dut.u_seq.areg[3] === DATA + 2,
          "UNPK: the source register stepped back one byte");
    check(dut.u_seq.areg[2] === DATA,
          "UNPK: and the destination two");

    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_insn_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_insn_tb");
    else                               $display("FAIL: core_insn_tb");
    $finish;
  end

endmodule
