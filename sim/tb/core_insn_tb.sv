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
  int unsigned k;

  // UM 5.5.2 and PRM 4: a compare-and-swap holds RMC across every cycle of the
  // sequence, so that nothing else can get at the location in between. These
  // count the cycles that ran while it was asserted and the times it was let
  // go and taken again -- which must be never, within one instruction.
  int unsigned rmc_cycles, rmc_breaks;
  bit          rmc_seen;
  always @(negedge clk) if (rst_n) begin
    if (rmc_oe && !rmc_n_o) begin
      rmc_cycles = rmc_cycles + 1;
      rmc_seen   = 1'b1;
    end else if (rmc_seen) begin
      rmc_breaks = rmc_breaks + 1;
      rmc_seen   = 1'b0;
    end
  end

  // One CMP2 or CHK2: the bounds pair at DATA, the register loaded, and the
  // codes read back out of the status register.
  //
  // `xw` is the instruction's extension word -- bit 15 the register file, bits
  // 14-12 the register, bit 11 CHK2 rather than CMP2.
  task automatic cmp2_case(input logic [15:0] opw, input logic [15:0] xw,
                           input logic [31:0] lb, input logic [31:0] ub,
                           input logic [31:0] rn, input int unsigned nbytes,
                           input bit want_c, input bit want_z,
                           input string what);
    setup();
    // The bounds, lower first -- PRM 4, "the upper bound following the lower".
    case (nbytes)
      1: begin
        poke_w(DATA,     {lb[7:0], ub[7:0]});
      end
      2: begin
        poke_w(DATA,     lb[15:0]);
        poke_w(DATA + 2, ub[15:0]);
      end
      default: begin
        poke_l(DATA,     lb);
        poke_l(DATA + 4, ub);
      end
    endcase
    // MOVEA.L #DATA,A6 ; MOVE.L #rn,D1 or MOVEA.L #rn,A1 ; the instruction.
    poke_w(CODE + 0, 16'h2C7C);            // MOVEA.L #DATA,A6
    poke_l(CODE + 2, DATA);
    if (xw[15]) begin
      poke_w(CODE + 6, 16'h227C | ({13'd0, xw[14:12]} << 9)); // MOVEA.L #rn,An
    end else begin
      poke_w(CODE + 6, 16'h203C | ({13'd0, xw[14:12]} << 9)); // MOVE.L #rn,Dn
    end
    poke_l(CODE + 8, rn);
    poke_w(CODE + 12, opw | 16'h0016);     // ... <ea> = (A6)
    poke_w(CODE + 14, xw);
    poke_w(CODE + 16, 16'h60FE);           // BRA *
    reset_dut();
    run_until(CODE + 16, 2000, reached);
    check(reached, {what, ": the program finishes"});
    check(dut.u_seq.sr_q[0] === want_c, {what, ": C says in or out of bounds"});
    check(dut.u_seq.sr_q[2] === want_z, {what, ": Z says equal to a bound"});
  endtask

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


    // ======================================================================
    // CMP2 -- PRM 4. The manual asks for one instruction that serves both a
    // signed and an unsigned range, and doc/divergences.md works through why
    // no fixed-signedness comparison can. These are the cases that tell the
    // three candidate rules apart.
    //
    //                    op     xw     LB    UB    Rn   sz   C  Z
    // ======================================================================
    // A signed range, -16 to +16 at byte size.
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'h00, 1, 0, 0,
              "CMP2.B signed range, inside");
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'hEF, 1, 1, 0,
              "CMP2.B signed range, below");
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'h11, 1, 1, 0,
              "CMP2.B signed range, above");
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'hF0, 1, 0, 1,
              "CMP2.B signed range, on the lower bound");
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'h10, 1, 0, 1,
              "CMP2.B signed range, on the upper bound");

    // An unsigned range, 16 to 240. $80 is inside it and is negative, which is
    // the case a signed comparison gets wrong.
    cmp2_case(16'h00C0, 16'h1000, 32'h10, 32'hF0, 32'h80, 1, 0, 0,
              "CMP2.B unsigned range, inside and negative");
    cmp2_case(16'h00C0, 16'h1000, 32'h10, 32'hF0, 32'h00, 1, 1, 0,
              "CMP2.B unsigned range, below");
    cmp2_case(16'h00C0, 16'h1000, 32'h10, 32'hF0, 32'hFF, 1, 1, 0,
              "CMP2.B unsigned range, above");

    // "If the upper bound equals the lower bound, the valid range is a single
    // value."
    cmp2_case(16'h00C0, 16'h1000, 32'h42, 32'h42, 32'h42, 1, 0, 1,
              "CMP2.B one-value range, on it");
    cmp2_case(16'h00C0, 16'h1000, 32'h42, 32'h42, 32'h43, 1, 1, 0,
              "CMP2.B one-value range, off it");

    // Word and long, so that the size field and the two reads are exercised.
    cmp2_case(16'h02C0, 16'h1000, 32'hFFF0, 32'h0010, 32'h0000, 2, 0, 0,
              "CMP2.W signed range, inside");
    cmp2_case(16'h02C0, 16'h1000, 32'h0010, 32'hFFF0, 32'h8000, 2, 0, 0,
              "CMP2.W unsigned range, inside and negative");
    cmp2_case(16'h04C0, 16'h1000, 32'hFFFFFFF0, 32'h00000010, 32'h00000000,
              4, 0, 0, "CMP2.L signed range, inside");
    cmp2_case(16'h04C0, 16'h1000, 32'h00000010, 32'hFFFFFFF0, 32'h80000000,
              4, 0, 0, "CMP2.L unsigned range, inside and negative");

    // An address register with byte bounds: PRM 4 sign-extends the bounds to
    // thirty-two bits and compares them against the whole of An, so -8 is
    // inside [-16, +16] and $000000F8 is not.
    cmp2_case(16'h00C0, 16'h9000, 32'hF0, 32'h10, 32'hFFFFFFF8, 1, 0, 0,
              "CMP2.B into An, sign extended, inside");
    cmp2_case(16'h00C0, 16'h9000, 32'hF0, 32'h10, 32'h000000F8, 1, 1, 0,
              "CMP2.B into An, the same bits unextended, outside");

    // ... and only the low part of a data register is looked at.
    cmp2_case(16'h00C0, 16'h1000, 32'hF0, 32'h10, 32'hAABBCC00, 1, 0, 0,
              "CMP2.B into Dn looks only at the low byte");

    // ======================================================================
    // CHK2 is the same comparison with a trap on it -- PRM 4, vector 6.
    // ======================================================================
    setup();
    poke_l(32'h0000_0018, 32'h0000_0500);  // vector 6
    poke_w(32'h0000_0500, 16'h7A44);       // MOVEQ #$44,D5
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(DATA, 16'hF010);                // bounds -16 .. +16
    poke_w(CODE + 0, 16'h2C7C);            // MOVEA.L #DATA,A6
    poke_l(CODE + 2, DATA);
    poke_w(CODE + 6, 16'h223C);            // MOVE.L #$EF,D1 -- one below
    poke_l(CODE + 8, 32'h0000_00EF);
    poke_w(CODE + 12, 16'h00D6);           // CHK2.B (A6),D1
    poke_w(CODE + 14, 16'h1800);
    poke_w(CODE + 16, 16'h60FE);
    reset_dut();
    run_until(32'h0000_0502, 2000, reached);
    check(reached, "CHK2: out of bounds traps to vector 6");
    check(dut.u_seq.dreg[5] === 32'h0000_0044, "CHK2: and the handler ran");

    setup();
    poke_l(32'h0000_0018, 32'h0000_0500);
    poke_w(32'h0000_0500, 16'h7A44);
    poke_w(32'h0000_0502, 16'h60FE);
    poke_w(DATA, 16'hF010);
    poke_w(CODE + 0, 16'h2C7C);
    poke_l(CODE + 2, DATA);
    poke_w(CODE + 6, 16'h223C);            // MOVE.L #0,D1 -- inside
    poke_l(CODE + 8, 32'h0000_0000);
    poke_w(CODE + 12, 16'h00D6);
    poke_w(CODE + 14, 16'h1800);
    poke_w(CODE + 16, 16'h60FE);
    reset_dut();
    run_until(CODE + 16, 2000, reached);
    check(reached, "CHK2: in bounds does not trap");
    check(dut.u_seq.dreg[5] === 32'h0000_0000, "CHK2: and the handler did not run");


    // ======================================================================
    // An address register stepped by (An)+ or -(An) holds an ADDRESS, and the
    // whole of it survives whatever the operand size is.
    //
    // PRM 2 sign-extends a word into an address register because the word is a
    // value; the address a postincrement leaves behind is not one. The two go
    // to the same register through the same microword field, and for two
    // milestones they went through the same sign-extending path -- which no
    // test noticed, because every address the sweep uses has the relevant bit
    // clear. These are chosen so that it is set.
    // ======================================================================
    setup();
    poke_w(32'h0000_8000, 16'h1234);
    poke_w(32'h0000_0080, 16'h5678);
    poke_w(CODE +  0, 16'h207C);           // MOVEA.L #$8000,A0
    poke_l(CODE +  2, 32'h0000_8000);
    poke_w(CODE +  6, 16'h227C);           // MOVEA.L #$0080,A1
    poke_l(CODE +  8, 32'h0000_0080);
    poke_w(CODE + 12, 16'h3018);           // MOVE.W (A0)+,D0
    poke_w(CODE + 14, 16'h1219);           // MOVE.B (A1)+,D1
    poke_w(CODE + 16, 16'h3420);           // MOVE.W -(A0),D2
    poke_w(CODE + 18, 16'h60FE);
    reset_dut();
    run_until(CODE + 18, 2000, reached);
    check(reached, "stepping: the program finishes");
    check(dut.u_seq.areg[0] === 32'h0000_8000,
          "stepping: (A0)+ then -(A0) at a word comes back to $00008000");
    check(dut.u_seq.areg[1] === 32'h0000_0081,
          "stepping: (A1)+ at a byte gives $00000081, not a sign extension");
    check(dut.u_seq.dreg[0][15:0] === 16'h1234, "stepping: and the word read");
    check(dut.u_seq.dreg[2][15:0] === 16'h1234, "stepping: ... and read back");


    // ======================================================================
    // CAS -- PRM 4. "Compares the effective address operand to the compare
    // operand (Dc). If the operands are equal, the instruction writes the
    // update operand (Du) to the effective address operand; otherwise, the
    // instruction writes the effective address operand to the compare operand
    // (Dc)."
    //
    // Both outcomes, and RMC held across the whole of each.
    // ======================================================================
    setup();
    poke_l(DATA, 32'h1234_5678);
    poke_w(CODE +  0, 16'h247C);           // MOVEA.L #DATA,A2
    poke_l(CODE +  2, DATA);
    poke_w(CODE +  6, 16'h223C);           // MOVE.L #$12345678,D1  -- matches
    poke_l(CODE +  8, 32'h1234_5678);
    poke_w(CODE + 12, 16'h243C);           // MOVE.L #$AAAABBBB,D2  -- the update
    poke_l(CODE + 14, 32'hAAAA_BBBB);
    poke_w(CODE + 18, 16'h0ED2);           // CAS.L D1,D2,(A2)
    poke_w(CODE + 20, 16'h0081);           //   Du = D2, Dc = D1
    poke_w(CODE + 22, 16'h60FE);
    reset_dut();
    rmc_cycles = 0; rmc_breaks = 0; rmc_seen = 1'b0;
    run_until(CODE + 22, 2000, reached);
    check(reached, "CAS match: the program finishes");
    check(peek_l(DATA) === 32'hAAAA_BBBB,
          "CAS match: the update operand went to memory");
    check(dut.u_seq.dreg[1] === 32'h1234_5678,
          "CAS match: the compare register is untouched");
    check(dut.u_seq.sr_q[2] === 1'b1, "CAS match: Z says so");
    check(rmc_breaks <= 1,
          "CAS match: RMC was held across the read and the write, unbroken");
    check(rmc_cycles > 0, "CAS match: ... and it was asserted at all");

    setup();
    poke_l(DATA, 32'h1234_5678);
    poke_w(CODE +  0, 16'h247C);
    poke_l(CODE +  2, DATA);
    poke_w(CODE +  6, 16'h223C);           // MOVE.L #$0BADC0DE,D1 -- differs
    poke_l(CODE +  8, 32'h0BAD_C0DE);
    poke_w(CODE + 12, 16'h243C);
    poke_l(CODE + 14, 32'hAAAA_BBBB);
    poke_w(CODE + 18, 16'h0ED2);           // CAS.L D1,D2,(A2)
    poke_w(CODE + 20, 16'h0081);
    poke_w(CODE + 22, 16'h60FE);
    reset_dut();
    rmc_cycles = 0; rmc_breaks = 0; rmc_seen = 1'b0;
    run_until(CODE + 22, 2000, reached);
    check(reached, "CAS miss: the program finishes");
    check(peek_l(DATA) === 32'h1234_5678,
          "CAS miss: memory is untouched");
    check(dut.u_seq.dreg[1] === 32'h1234_5678,
          "CAS miss: what memory held went into the compare register");
    check(dut.u_seq.sr_q[2] === 1'b0, "CAS miss: Z says so");
    check(rmc_breaks <= 1, "CAS miss: RMC was held and let go once");

    // ======================================================================
    // CAS2 -- PRM 4. Two locations at once, with the whole of it indivisible.
    // "If either comparison fails, the instruction writes the memory operands
    // (Rn1 and Rn2) to the compare operands (Dc1 and Dc2)" -- BOTH of them,
    // which is why both are read before either is compared.
    // ======================================================================
    setup();
    poke_l(DATA,      32'h1111_1111);
    poke_l(DATA + 8,  32'h2222_2222);
    poke_w(CODE +  0, 16'h247C);           // MOVEA.L #DATA,A2
    poke_l(CODE +  2, DATA);
    poke_w(CODE +  6, 16'h267C);           // MOVEA.L #DATA+8,A3
    poke_l(CODE +  8, DATA + 8);
    poke_w(CODE + 12, 16'h203C);           // MOVE.L #$11111111,D0
    poke_l(CODE + 14, 32'h1111_1111);
    poke_w(CODE + 18, 16'h223C);           // MOVE.L #$22222222,D1
    poke_l(CODE + 20, 32'h2222_2222);
    poke_w(CODE + 24, 16'h243C);           // MOVE.L #$AAAA0001,D2
    poke_l(CODE + 26, 32'hAAAA_0001);
    poke_w(CODE + 30, 16'h263C);           // MOVE.L #$BBBB0002,D3
    poke_l(CODE + 32, 32'hBBBB_0002);
    poke_w(CODE + 36, 16'h0EFC);           // CAS2.L
    poke_w(CODE + 38, 16'hA080);           //   Rn1 = A2, Du1 = D2, Dc1 = D0
    poke_w(CODE + 40, 16'hB0C1);           //   Rn2 = A3, Du2 = D3, Dc2 = D1
    poke_w(CODE + 42, 16'h60FE);
    reset_dut();
    rmc_cycles = 0; rmc_breaks = 0; rmc_seen = 1'b0;
    run_until(CODE + 42, 3000, reached);
    check(reached, "CAS2 match: the program finishes");
    check(peek_l(DATA)     === 32'hAAAA_0001, "CAS2 match: the first update landed");
    check(peek_l(DATA + 8) === 32'hBBBB_0002, "CAS2 match: and the second");
    check(rmc_breaks <= 1,
          "CAS2 match: RMC was held across all four transfers, unbroken");

    // ... and with the SECOND comparison failing, so that both compare
    // registers are loaded although the first one matched.
    setup();
    poke_l(DATA,      32'h1111_1111);
    poke_l(DATA + 8,  32'h9999_9999);      // not what D1 holds
    poke_w(CODE +  0, 16'h247C);
    poke_l(CODE +  2, DATA);
    poke_w(CODE +  6, 16'h267C);
    poke_l(CODE +  8, DATA + 8);
    poke_w(CODE + 12, 16'h203C);
    poke_l(CODE + 14, 32'h1111_1111);
    poke_w(CODE + 18, 16'h223C);
    poke_l(CODE + 20, 32'h2222_2222);
    poke_w(CODE + 24, 16'h243C);
    poke_l(CODE + 26, 32'hAAAA_0001);
    poke_w(CODE + 30, 16'h263C);
    poke_l(CODE + 32, 32'hBBBB_0002);
    poke_w(CODE + 36, 16'h0EFC);
    poke_w(CODE + 38, 16'hA080);
    poke_w(CODE + 40, 16'hB0C1);
    poke_w(CODE + 42, 16'h60FE);
    reset_dut();
    rmc_cycles = 0; rmc_breaks = 0; rmc_seen = 1'b0;
    run_until(CODE + 42, 3000, reached);
    check(reached, "CAS2 miss: the program finishes");
    check(peek_l(DATA)     === 32'h1111_1111, "CAS2 miss: neither location moved");
    check(peek_l(DATA + 8) === 32'h9999_9999, "CAS2 miss: ... nor the second");
    check(dut.u_seq.dreg[0] === 32'h1111_1111,
          "CAS2 miss: the first compare register took what memory held");
    check(dut.u_seq.dreg[1] === 32'h9999_9999,
          "CAS2 miss: and so did the second, though it was the one that failed");
    check(rmc_breaks <= 1, "CAS2 miss: RMC was held across both reads");

    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_insn_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0 && pipe_fails == 0) $display("PASS: core_insn_tb");
    else                               $display("FAIL: core_insn_tb");
    $finish;
  end

endmodule
