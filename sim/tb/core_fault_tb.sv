// RD68021 -- bus faults and the frames that describe them: M9.
//
// The milestone the checkpoint discipline was frozen for. A faulted data access
// builds a format $B frame; the frame is checked as MEMORY, word by word, at
// the offsets UM table 6-5 and doc/checkpoint.md give -- because a frame this
// core writes and reads back consistently, but writes in the wrong place, is
// exactly the bug a demand-paging handler finds and nothing else does.
//
// `berr_base` / `berr_mask` in the harness are the unmapped page: an access
// there terminates with BERR, which is what a page that is not resident looks
// like from the bus.

`timescale 1ns / 1ps

module core_fault_tb;

`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] HAND = 32'h0000_0500;
  // The page that is not there. It is inside the 32-bit port so that everything
  // about the access is ordinary except its answer.
  localparam logic [31:0] GONE = 32'h0000_8000;

  bit          reached;
  logic [31:0] base;

  task automatic base_setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1)
      poke_l(v * 4, 32'h0000_9000);
    poke_w(32'h0000_9000, 16'h60FE);       // an unexpected vector spins
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
    poke_l(32'h0000_0008, HAND);           // vector 2, bus error
    berr_en   = 1'b1;
    berr_base = GONE;
    berr_mask = 32'hFFFF_F000;             // a 4K page
  endtask

  initial begin
    $display("core_fault_tb: bus faults, and the long frame");

    // ======================================================================
    // A write to a page that is not there. UM 6.1.2: "if the aborted bus cycle
    // is a data access, the processor immediately begins exception
    // processing", and the frame is the long one because the exception is
    // taken during the execution of an instruction.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'h207C);            // MOVEA.L #GONE,A0
    poke_l(CODE + 2, GONE);
    poke_w(CODE + 6, 16'h7255);            // MOVEQ #$55,D1
    poke_w(CODE + 8, 16'h2080);            // MOVE.L D0,(A0)  -- faults
    poke_w(CODE + 10, 16'h60FE);
    poke_w(HAND + 0, 16'h7433);            // MOVEQ #$33,D2
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    dut.u_seq.dreg[0] = 32'h1234_5678;
    run_until(HAND + 2, 3000, reached);
    check(reached, "write fault: the bus error handler runs");
    check(dut.u_seq.dreg[2] === 32'h0000_0033, "write fault: and only it");

    base = ISP0 - 32'h5C;
    check(dut.u_seq.isp_q === base,
          "write fault: the stack pointer is the base of a 46-word frame");

    // UM table 6-5 and doc/checkpoint.md, field by field.
    check(peek_w(base + 32'h00) === 16'h2700,
          "write fault: +$00 the status register as it was");
    check(peek_l(base + 32'h02) === CODE + 8,
          "write fault: +$02 the instruction that was executing");
    check(peek_w(base + 32'h06) === 16'hB008,
          "write fault: +$06 format $B, vector offset $008");
    // doc/ssw.md: a data write fault, four bytes, supervisor data space.
    //   DF = 1, RM = 0, RW = 0 (write), SIZE = 00 (four bytes), FC = 101
    //
    // Only the low twelve bits are compared. The high nibble is FC, FB, RC and
    // RB, which describe the instruction PIPE: whether stage B held a word when
    // the data cycle faulted is a matter of how far ahead the prefetch had got,
    // and it is the RTE-continuation tests that pin it down.
    check((peek_w(base + 32'h0A) & 16'h0FFF) === 12'h105,
          "write fault: +$0A the special status word");
    check(peek_l(base + 32'h10) === GONE,
          "write fault: +$10 the data cycle fault address");
    check(peek_l(base + 32'h18) === 32'h1234_5678,
          "write fault: +$18 the data output buffer");
    check(peek_w(base + 32'h36) >> 12 === 4'h1,
          "write fault: +$36 the frame version");
    check(peek_l(base + 32'h46) === CODE + 6,
          "write fault: +$46 the instruction before this one");

    // ======================================================================
    // A read fault. Same frame, but the data input buffer is the field that
    // matters and RW says so.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'h207C);            // MOVEA.L #GONE,A0
    poke_l(CODE + 2, GONE);
    poke_w(CODE + 6, 16'h2410);            // MOVE.L (A0),D2 -- faults
    poke_w(CODE + 8, 16'h60FE);
    poke_w(HAND + 0, 16'h7633);            // MOVEQ #$33,D3
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    run_until(HAND + 2, 3000, reached);
    check(reached, "read fault: the bus error handler runs");
    base = ISP0 - 32'h5C;
    check(peek_l(base + 32'h02) === CODE + 6,
          "read fault: +$02 the instruction that was executing");
    //   DF = 1, RM = 0, RW = 1 (read), SIZE = 00, FC = 101
    check((peek_w(base + 32'h0A) & 16'h0FFF) === 12'h145,
          "read fault: +$0A the special status word says read");
    check(peek_l(base + 32'h10) === GONE,
          "read fault: +$10 the data cycle fault address");


    // ======================================================================
    // The whole point of the milestone: a handler that maps the page and lets
    // RTE finish the access. UM 6.2.3 -- "another method of completing a
    // faulted bus cycle is to allow the processor to rerun the bus cycles
    // during execution of the RTE instruction that terminates the exception
    // handler".
    //
    // The handler here does nothing but RTE. Mapping the page is the
    // testbench's job -- `berr_en` goes low -- which is exactly what a pager
    // does that the instruction cannot see.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'h207C);            // MOVEA.L #GONE,A0
    poke_l(CODE + 2, GONE);
    poke_w(CODE + 6, 16'h2080);            // MOVE.L D0,(A0) -- faults
    poke_w(CODE + 8, 16'h7255);            // MOVEQ #$55,D1  -- must run after
    poke_w(CODE + 10, 16'h60FE);
    poke_w(HAND + 0, 16'h4E73);            // RTE -- with DF still set
    reset_dut();
    dut.u_seq.dreg[0] = 32'hDEAD_BEEF;
    // The handler maps the page in: run until it is entered, then let the
    // access through.
    run_until(HAND + 0, 3000, reached);
    check(reached, "rerun: the handler is entered");
    berr_en = 1'b0;
    run_until(CODE + 10, 3000, reached);
    check(reached, "rerun: and the program gets past the faulted instruction");
    check(peek_l(GONE) === 32'hDEAD_BEEF,
          "rerun: RTE finished the write the instruction started");
    check(dut.u_seq.dreg[1] === 32'h0000_0055,
          "rerun: and the instruction after it ran");
    check(dut.u_seq.isp_q === ISP0,
          "rerun: RTE took the frame off the stack");
    check(dut.u_seq.areg[0] === GONE,
          "rerun: the address register is untouched");
    check(dut.u_seq.sr_q === 16'h2700, "rerun: and so is the status register");

    // ======================================================================
    // The same fault, repaired by the handler instead: it writes the word
    // itself and clears DF, so RTE runs no bus cycle of its own -- UM 6.2.2.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'h207C);
    poke_l(CODE + 2, GONE);
    poke_w(CODE + 6, 16'h2080);            // MOVE.L D0,(A0) -- faults
    poke_w(CODE + 8, 16'h7255);
    poke_w(CODE + 10, 16'h60FE);
    // ANDI.W #$FEFF,($0A,A7) clears DF and nothing else. UM 6.2.2: "the only
    // bits in the SSW that may be modified are DF, RB, and RC".
    poke_w(HAND + 0, 16'h026F);            // ANDI.W #imm,(d16,A7)
    poke_w(HAND + 2, 16'hFEFF);
    poke_w(HAND + 4, 16'h000A);
    poke_w(HAND + 6, 16'h4E73);            // RTE
    reset_dut();
    dut.u_seq.dreg[0] = 32'hCAFE_F00D;
    run_until(HAND + 6, 3000, reached);
    check(reached, "repaired: the handler reaches its RTE");
    // The handler "moves the properly sized data from the data output buffer".
    // Here the testbench is the handler's memory system and does it directly.
    poke_l(GONE, peek_l(ISP0 - 32'h5C + 32'h18));
    berr_en = 1'b0;
    run_until(CODE + 10, 3000, reached);
    check(reached, "repaired: the program gets past the faulted instruction");
    check(peek_l(GONE) === 32'hCAFE_F00D,
          "repaired: the handler's own write is what landed");
    check(dut.u_seq.dreg[1] === 32'h0000_0055,
          "repaired: and the instruction after it ran");
    check(dut.u_seq.isp_q === ISP0, "repaired: the frame came off the stack");

    // ======================================================================
    // A double bus fault. UM 6.1.2: a bus error during the exception
    // processing for a bus error "and the processor enters the halted state.
    // In this case, the processor does not attempt to alter the current state
    // of memory."
    //
    // The stack itself is put in the unmapped page, so building the frame
    // faults.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0000, GONE + 32'h800); // the stack is not there either
    poke_w(CODE + 0, 16'h207C);
    poke_l(CODE + 2, GONE);
    poke_w(CODE + 6, 16'h2410);            // MOVE.L (A0),D2 -- faults
    poke_w(CODE + 8, 16'h60FE);
    reset_dut();
    run_cycles(600);
    check(halt_n_oe === 1'b1, "double fault: HALT is asserted");
    check(dut.u_seq.dbf_q === 1'b1, "double fault: and it is latched");

    if (pipe_fails != 0)
      $display("  FAIL: the pipe invariant broke %0d times", pipe_fails);
    $display("core_fault_tb: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("PASS: core_fault_tb");
    else            $display("FAIL: core_fault_tb");
    $finish;
  end

  task automatic run_cycles(input int n);
    repeat (n) @(negedge clk);
  endtask

endmodule
