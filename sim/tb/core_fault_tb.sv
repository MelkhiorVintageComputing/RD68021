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
  int unsigned i;

  // Every cycle to the supervisor stack must be in supervisor space. The
  // memory models ignore the function code, so nothing else would notice a
  // frame written through user data -- which is what the bus-fault frames did
  // for a fault taken in user mode, until SunOS on a Sun-3 found it: that MMU
  // keeps the spaces apart, and the frame write faulted into a double bus
  // fault. UM table 2-1: FC 1 and 2 are the user's.
  int unsigned user_on_sstack;
  initial user_on_sstack = 0;
  always @(negedge as_n_o)
    if (rst_n && as_oe && (fc_o == 3'd1 || fc_o == 3'd2)
        && a_o >= ISP0 - 32'h200 && a_o < ISP0)
      user_on_sstack++;

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
    // Here the testbench is its memory system -- and it writes something the
    // INSTRUCTION would not have written, so that the check can tell a handler
    // that did the access from an RTE that redid it. With the same value in
    // both places it cannot, which is how the equivalent bug on the rerun path
    // went unnoticed for two commits.
    poke_l(GONE, 32'h5A5A_5A5A);
    berr_en = 1'b0;
    run_until(CODE + 10, 3000, reached);
    check(reached, "repaired: the program gets past the faulted instruction");
    check(peek_l(GONE) === 32'h5A5A_5A5A,
          "repaired: the handler's own write stands, and RTE did not redo it");
    check(dut.u_seq.dreg[1] === 32'h0000_0055,
          "repaired: and the instruction after it ran");
    check(dut.u_seq.isp_q === ISP0, "repaired: the frame came off the stack");


    // ======================================================================
    // A prefetch that faults -- UM 6.1.2, "if the aborted bus cycle is an
    // instruction prefetch, the processor may delay taking the exception until
    // it attempts to use the prefetched information".
    //
    // The program runs into a page that is not there. The words already in the
    // pipe execute; the exception is taken when the first word that is not
    // there is wanted. UM table 6-5 would give that the short frame; this
    // design gives every fault the long one, because the microword that takes
    // it is re-executed and may need any working register -- doc/divergences.md.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0008, HAND);           // vector 2
    // Straight-line code running up to the page boundary.
    poke_w(GONE - 6, 16'h7001);            // MOVEQ #1,D0
    poke_w(GONE - 4, 16'h7202);            // MOVEQ #2,D1
    poke_w(GONE - 2, 16'h7403);            // MOVEQ #3,D2
    poke_w(GONE + 0, 16'h7604);            // MOVEQ #4,D3 -- never runs
    poke_w(CODE + 0, 16'h4EF9);            // JMP (xxx).L
    poke_l(CODE + 2, GONE - 6);
    poke_w(HAND + 0, 16'h7833);            // MOVEQ #$33,D4
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    run_until(HAND + 2, 3000, reached);
    check(reached, "prefetch fault: the bus error handler runs");
    // The instruction in stage D when the fault is taken does NOT run: its own
    // microword is the one that advances the pipe, and a faulted microword
    // commits nothing. It is re-executed by RTE, so it runs exactly once, and
    // UM's "the logical address of the instruction that was executing at the
    // time the fault was detected" is its address -- doc/divergences.md.
    check(dut.u_seq.dreg[1] === 32'h0000_0002,
          "prefetch fault: the instructions whose words were there ran");
    check(dut.u_seq.dreg[2] === 32'h0000_0000,
          "prefetch fault: the one being decoded did not");
    check(dut.u_seq.dreg[3] === 32'h0000_0000,
          "prefetch fault: nor the one whose word was missing");
    base = ISP0 - 32'h5C;
    check(dut.u_seq.isp_q === base,
          "prefetch fault: the frame is the long one, forty-six words");
    check(peek_l(base + 32'h02) === GONE - 2,
          "prefetch fault: +$02 the instruction that was being decoded");
    check(peek_w(base + 32'h06) === 16'hB008,
          "prefetch fault: +$06 format $B, vector offset $008");
    check(peek_l(base + 32'h24) === GONE + 2,
          "prefetch fault: +$24 stage B, so stage C is the missing word");
    // doc/ssw.md: a fault on the prefetch for stage C, so FC is set, and RC is
    // always set when FC is. DF is clear -- this was not a data cycle -- and
    // with it the whole low half.
    // Both stages came from prefetches that faulted -- the refill after the pop
    // ran into the same missing page -- so FC, FB, RC and RB are all set, and
    // the whole low half is clear because this was not a data cycle.
    check(peek_w(base + 32'h0A) === 16'hF000,
          "prefetch fault: +$0A the fault and rerun bits, and no data fault");


    // ======================================================================
    // ... and out again. The handler maps the page and RTEs; the frame
    // is restored, the prefetch that faulted is rerun by the refill the queue
    // depth asks for, and the instruction that was being decoded runs.
    // ======================================================================
    base_setup();
    poke_l(32'h0000_0008, HAND);
    poke_w(GONE - 6, 16'h7001);            // MOVEQ #1,D0
    poke_w(GONE - 4, 16'h7202);            // MOVEQ #2,D1
    poke_w(GONE - 2, 16'h7403);            // MOVEQ #3,D2 -- decoded, not run
    poke_w(GONE + 0, 16'h7604);            // MOVEQ #4,D3 -- the missing word
    poke_w(GONE + 2, 16'h60FE);            // BRA *
    poke_w(CODE + 0, 16'h4EF9);            // JMP (xxx).L
    poke_l(CODE + 2, GONE - 6);
    poke_w(HAND + 0, 16'h4E73);            // RTE, with the rerun bits untouched
    reset_dut();
    run_until(HAND + 0, 3000, reached);
    check(reached, "prefetch rerun: the handler is entered");
    berr_en = 1'b0;                        // the pager maps it
    run_until(GONE + 2, 3000, reached);
    check(reached, "prefetch rerun: the program runs on into the page");
    check(dut.u_seq.dreg[2] === 32'h0000_0003,
          "prefetch rerun: the instruction being decoded ran, exactly once");
    check(dut.u_seq.dreg[3] === 32'h0000_0004,
          "prefetch rerun: and so did the one whose word had been missing");
    check(dut.u_seq.isp_q === ISP0,
          "prefetch rerun: the frame came off the stack");

    // ======================================================================
    // The same fault with the pipe EMPTY: the first word after a flush. This
    // is SunOS's forked child, whose first instruction -- reached by the RTE
    // that starts it -- is on a page the fork has not mapped yet.
    //
    // There is no stage D, so there is no instruction being decoded, and stage
    // C is the word AT the program counter. The short frame cannot say that --
    // UM 6.2 puts its stage C at the PC plus two, and a handler pages in by
    // that arithmetic -- so the frame is the long one, whose +$24 does. And the
    // frame's stage D is the JMP's, left over: RTE must not run it again.
    // ======================================================================
    base_setup();
    poke_w(GONE + 0, 16'h7604);            // MOVEQ #4,D3 -- the missing word
    poke_w(GONE + 2, 16'h60FE);            // BRA *
    poke_w(CODE + 0, 16'h4EF9);            // JMP (xxx).L
    poke_l(CODE + 2, GONE);
    poke_w(HAND + 0, 16'h4E73);            // RTE, with the rerun bits untouched
    reset_dut();
    run_until(HAND + 0, 3000, reached);
    check(reached, "empty pipe: the handler is entered");
    base = ISP0 - 32'h5C;
    check(dut.u_seq.isp_q === base,
          "empty pipe: the frame is the LONG one, forty-six words");
    check(peek_w(base + 32'h06) === 16'hB008,
          "empty pipe: +$06 format $B, vector offset $008");
    check(peek_l(base + 32'h02) === GONE,
          "empty pipe: +$02 the instruction whose word is missing");
    check(peek_l(base + 32'h24) === GONE + 2,
          "empty pipe: +$24 stage B, so stage C is at the missing word");
    check(peek_w(base + 32'h0A) === 16'hF000,
          "empty pipe: +$0A both stages faulted and are to be rerun");
    berr_en = 1'b0;
    run_until(GONE + 2, 3000, reached);
    check(reached, "empty pipe: RTE resumes at the missing word");
    check(dut.u_seq.dreg[3] === 32'h0000_0004,
          "empty pipe: and it runs");
    check(dut.u_seq.isp_q === ISP0,
          "empty pipe: the long frame came off the stack");

    // ======================================================================
    // ... and with a two-word instruction in stage D. Stage C is its NEXT
    // instruction, four bytes on, not two: the long frame again, and the
    // instruction re-executed by RTE runs exactly once.
    // ======================================================================
    base_setup();
    poke_w(GONE - 8, 16'h7001);            // MOVEQ #1,D0
    poke_w(GONE - 6, 16'h7200);            // MOVEQ #0,D1
    poke_w(GONE - 4, 16'h0641);            // ADDI.W #5,D1 -- decoded, not run
    poke_w(GONE - 2, 16'h0005);
    poke_w(GONE + 0, 16'h7604);            // MOVEQ #4,D3 -- the missing word
    poke_w(GONE + 2, 16'h60FE);            // BRA *
    poke_w(CODE + 0, 16'h4EF9);            // JMP (xxx).L
    poke_l(CODE + 2, GONE - 8);
    poke_w(HAND + 0, 16'h4E73);            // RTE
    reset_dut();
    run_until(HAND + 0, 3000, reached);
    check(reached, "two-word: the handler is entered");
    base = ISP0 - 32'h5C;
    check(peek_w(base + 32'h06) === 16'hB008,
          "two-word: +$06 format $B, vector offset $008");
    check(peek_l(base + 32'h02) === GONE - 4,
          "two-word: +$02 the instruction being decoded");
    check(peek_l(base + 32'h24) === GONE + 2,
          "two-word: +$24 stage B, so stage C is at the missing word");
    berr_en = 1'b0;
    run_until(GONE + 2, 3000, reached);
    check(reached, "two-word: RTE resumes");
    check(dut.u_seq.dreg[1] === 32'h0000_0005,
          "two-word: the instruction being decoded ran, exactly once");
    check(dut.u_seq.dreg[3] === 32'h0000_0004,
          "two-word: and the one whose word had been missing");
    check(dut.u_seq.isp_q === ISP0,
          "two-word: the long frame came off the stack");

    // ======================================================================
    // CMPM as the last word before the missing page -- libc's strcmp loop,
    // which is how SunOS's ps -U died. The microword that compares also
    // advances the pipe, so it is the one the prefetch fault re-executes after
    // RTE, and the bus unit's read data is by then the last word RTE read.
    // The compare has to be of the two operands, not of that.
    // ======================================================================
    base_setup();
    poke_w(GONE - 6, 16'h7A00);            // MOVEQ #0,D5
    poke_w(GONE - 4, 16'h4E71);            // NOP
    poke_w(GONE - 2, 16'hB308);            // CMPM.B (A0)+,(A1)+
    poke_w(GONE + 0, 16'h57C5);            // SEQ D5 -- the missing word
    poke_w(GONE + 2, 16'h60FE);            // BRA *
    poke_w(CODE + 0, 16'h4EF9);            // JMP (xxx).L
    poke_l(CODE + 2, GONE - 6);
    poke_w(HAND + 0, 16'h4E73);            // RTE
    poke_w(32'h0000_3000, 16'h4142);       // the two operands: equal bytes
    poke_w(32'h0000_3100, 16'h4143);
    reset_dut();
    dut.u_seq.areg[0] = 32'h0000_3000;
    dut.u_seq.areg[1] = 32'h0000_3100;
    run_until(HAND + 0, 3000, reached);
    check(reached, "CMPM at a page end: the prefetch fault is taken");
    berr_en = 1'b0;
    run_until(GONE + 2, 3000, reached);
    check(reached, "CMPM at a page end: RTE, and the program goes on");
    check(dut.u_seq.dreg[5] === 32'h0000_00FF,
          "CMPM at a page end: the compare re-run after RTE still sees them equal");
    check(dut.u_seq.areg[0] === 32'h0000_3001 && dut.u_seq.areg[1] === 32'h0000_3101,
          "CMPM at a page end: each register stepped once");

    // ======================================================================
    // A memory bit field as the last instruction before the missing page.
    // Everything the bit-field unit produces comes from the read data, which
    // does not survive a fault, so the microword that writes the result may
    // not be the one that advances the pipe -- check_rdata_restart found that
    // it was. The result has to be the field, not something made from RTE's
    // last read.
    // ======================================================================
    base_setup();
    poke_w(GONE - 6, 16'h7A00);            // MOVEQ #0,D5
    poke_w(GONE - 4, 16'hE9D0);            // BFEXTU (A0){0:8},D5
    poke_w(GONE - 2, 16'h5008);
    poke_w(GONE + 0, 16'h7601);            // MOVEQ #1,D3 -- the missing word
    poke_w(GONE + 2, 16'h60FE);
    poke_w(CODE + 0, 16'h4EF9);            // JMP (xxx).L
    poke_l(CODE + 2, GONE - 6);
    poke_w(HAND + 0, 16'h4E73);            // RTE
    poke_l(32'h0000_3000, 32'hA5C3_0000);
    reset_dut();
    dut.u_seq.areg[0] = 32'h0000_3000;
    run_until(HAND + 0, 3000, reached);
    check(reached, "BFEXTU at a page end: the prefetch fault is taken");
    berr_en = 1'b0;
    run_until(GONE + 2, 3000, reached);
    check(reached, "BFEXTU at a page end: RTE, and the program goes on");
    check(dut.u_seq.dreg[5] === 32'h0000_00A5,
          "BFEXTU at a page end: the field, as it was read");
    check(dut.u_seq.dreg[3] === 32'h0000_0001,
          "BFEXTU at a page end: and the instruction on the new page ran");

    // ======================================================================
    // RTS whose return address is on a page that is not there. The read and
    // the jump are one microword now: a faulted read must neither jump nor
    // move the stack, and RTE's rerun must do both.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0,  16'h207C);           // MOVEA.L #GONE+$10,A0
    poke_l(CODE + 2,  GONE + 32'h10);
    poke_w(CODE + 6,  16'h4E60);           // MOVE A0,USP
    poke_w(CODE + 8,  16'h027C);           // ANDI #$DFFF,SR: to user mode
    poke_w(CODE + 10, 16'hDFFF);
    poke_w(CODE + 12, 16'h4E75);           // RTS, with SP on the missing page
    poke_w(CODE + 14, 16'h60FE);
    poke_w(HAND + 0,  16'h4E73);           // RTE
    poke_w(32'h0000_0480, 16'h7C07);       // MOVEQ #7,D6 -- where it returns
    poke_w(32'h0000_0482, 16'h60FE);
    poke_l(GONE + 32'h10, 32'h0000_0480);  // the return address
    reset_dut();
    run_until(HAND + 0, 3000, reached);
    check(reached, "RTS from a missing page: the bus error is taken");
    check(dut.u_seq.usp_q === GONE + 32'h10, "RTS from a missing page: the stack did not move");
    berr_en = 1'b0;
    run_until(32'h0000_0482, 3000, reached);
    check(reached, "RTS from a missing page: RTE reruns the read and returns");
    check(dut.u_seq.dreg[6] === 32'h0000_0007, "RTS from a missing page: to the right place");
    check(dut.u_seq.usp_q === GONE + 32'h14, "RTS from a missing page: the stack stepped once");

    // ======================================================================
    // An address error -- UM 6.1.3, "an address error exception occurs when
    // the processor attempts to prefetch an instruction from an odd address
    // ... a bus cycle is not executed". Vector 3, and UM 6.2.1: the fault bits
    // are NOT set, "and the rerun bits alone show the cause of the exception".
    // ======================================================================
    base_setup();
    poke_l(32'h0000_000C, HAND);           // vector 3, address error
    poke_w(CODE + 0, 16'h7001);            // MOVEQ #1,D0
    poke_w(CODE + 2, 16'h4EF9);            // JMP ($0000_0801).L -- odd
    poke_l(CODE + 4, 32'h0000_0801);
    poke_w(HAND + 0, 16'h7A44);            // MOVEQ #$44,D5
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    berr_en = 1'b0;                        // nothing is missing; the target is odd
    run_until(HAND + 2, 3000, reached);
    check(reached, "address error: the handler runs");
    check(dut.u_seq.dreg[5] === 32'h0000_0044, "address error: and only it");
    // After a flush the pipe is empty, so the frame is the long one -- the
    // same rule as the empty-pipe bus error above.
    base = ISP0 - 32'h5C;
    check(peek_w(base + 32'h06) === 16'hB00C,
          "address error: +$06 format $B, vector offset $00C");
    check(peek_l(base + 32'h02) === 32'h0000_0801,
          "address error: +$02 the odd address it could not fetch from");
    // UM 6.2.1: the fault bits are clear and the rerun bits alone show it.
    check(peek_w(base + 32'h0A) === 16'h3000,
          "address error: +$0A the rerun bits alone");



    // ======================================================================
    // The read half of UM 6.2.2: "data read faults only generate the long bus
    // fault frame, and the handler must transfer properly sized data from the
    // location indicated by the fault address ... to the image of the data
    // input buffer at location SP + $2C".
    //
    // The page is left missing on purpose. If RTE ran a bus cycle of its own
    // it would fault again; the instruction gets its operand from the frame or
    // it does not get one at all.
    // ======================================================================
    base_setup();
    poke_w(CODE + 0, 16'h207C);            // MOVEA.L #GONE,A0
    poke_l(CODE + 2, GONE);
    poke_w(CODE + 6, 16'h2410);            // MOVE.L (A0),D2 -- faults
    poke_w(CODE + 8, 16'h7255);            // MOVEQ #$55,D1
    poke_w(CODE + 10, 16'h60FE);
    poke_w(HAND +  0, 16'h2F7C);           // MOVE.L #$12345678,($2C,A7)
    poke_l(HAND +  2, 32'h1234_5678);      //   ... into the data input buffer
    poke_w(HAND +  6, 16'h002C);
    poke_w(HAND +  8, 16'h026F);           // ANDI.W #$FEFF,($0A,A7)
    poke_w(HAND + 10, 16'hFEFF);           //   ... clear DF, and only DF
    poke_w(HAND + 12, 16'h000A);
    poke_w(HAND + 14, 16'h4E73);           // RTE
    reset_dut();
    run_until(HAND + 14, 4000, reached);
    check(reached, "emulated read: the handler reaches its RTE");
    run_until(CODE + 10, 4000, reached);
    check(reached, "emulated read: it gets past the faulted instruction with the page still missing");
    check(dut.u_seq.dreg[2] === 32'h1234_5678,
          "emulated read: the operand came out of the frame");
    check(dut.u_seq.dreg[1] === 32'h0000_0055,
          "emulated read: and the instruction after it ran");
    check(dut.u_seq.isp_q === ISP0, "emulated read: the frame came off");

    // ======================================================================
    // MOVEM faulting part way down its list. The register counter and the mask
    // are checkpoint registers -- doc/checkpoint.md -- and this is what they
    // are for: the instruction resumes where it stopped, with no register
    // moved twice and none missed.
    //
    // Eight long words are read through (A0)+, and the fifth is in the page
    // that is not there.
    // ======================================================================
    base_setup();
    for (i = 0; i < 8; i = i + 1)
      poke_l(GONE - 16 + i * 4, 32'h1100_0000 + i);
    poke_w(CODE + 0, 16'h207C);            // MOVEA.L #GONE-16,A0
    poke_l(CODE + 2, GONE - 16);
    poke_w(CODE + 6, 16'h4CD8);            // MOVEM.L (A0)+,D0-D7
    poke_w(CODE + 8, 16'h00FF);
    poke_w(CODE + 10, 16'h60FE);           // BRA *
    poke_w(HAND + 0, 16'h4E73);            // RTE, with DF still set
    reset_dut();
    run_until(HAND + 0, 4000, reached);
    check(reached, "movem: the fifth transfer faults and the handler is entered");
    berr_en = 1'b0;
    run_until(CODE + 10, 4000, reached);
    check(reached, "movem: and the instruction finishes");
    for (i = 0; i < 8; i = i + 1)
      check(dut.u_seq.dreg[i] === 32'h1100_0000 + i,
            $sformatf("movem: D%0d came from the right long word", i));
    check(dut.u_seq.areg[0] === GONE + 16,
          "movem: the address register stepped exactly eight times");
    check(dut.u_seq.isp_q === ISP0, "movem: the frame came off the stack");

    // ======================================================================
    // A misaligned long word split across a page boundary by an 8-bit port.
    // UM table 5-6 makes that four bus cycles; two of them succeed and the
    // third does not, so what the frame has to carry is the RESIDUAL -- the
    // address of the next byte still to go and how many are left. This is the
    // case doc/ssw.md says the bus unit has architectural state for.
    // ======================================================================
    base_setup();
    berr_base = 32'h2000_8000;             // a page of the 8-bit port
    poke_w(CODE + 0, 16'h207C);            // MOVEA.L #$20007FFE,A0
    poke_l(CODE + 2, 32'h2000_7FFE);
    poke_w(CODE + 6, 16'h2080);            // MOVE.L D0,(A0) -- four cycles
    poke_w(CODE + 8, 16'h60FE);
    poke_w(HAND + 0, 16'h7833);            // MOVEQ #$33,D4
    poke_w(HAND + 2, 16'h60FE);
    reset_dut();
    dut.u_seq.dreg[0] = 32'hAABB_CCDD;
    run_until(HAND + 2, 4000, reached);
    check(reached, "residual: the third cycle faults");
    base = ISP0 - 32'h5C;
    check(peek_l(base + 32'h10) === 32'h2000_8000,
          "residual: +$10 is the next BYTE still to transfer, not the operand");
    // DF = 1, RM = 0, RW = 0 (write), SIZE = 10 (two bytes left), FC = 101.
    check((peek_w(base + 32'h0A) & 16'h0FFF) === 12'h125,
          "residual: +$0A says two bytes of a write are left");
    // The two bytes that did go are in memory; the operand is still whole in
    // the data output buffer, right justified -- UM 6.2.2.
    check(peek_l(base + 32'h18) === 32'hAABB_CCDD,
          "residual: +$18 the data output buffer holds the whole operand");
    check(peek_w(32'h2000_7FFE) === 16'hAABB,
          "residual: the two bytes that did go are where they belong");

    // ... and RTE finishes only what is left.
    berr_en = 1'b0;
    poke_w(HAND + 0, 16'h4E73);            // the handler is now just an RTE
    reset_dut();
    berr_en   = 1'b1;
    berr_base = 32'h2000_8000;
    dut.u_seq.dreg[0] = 32'hAABB_CCDD;
    poke_w(32'h2000_7FFE, 16'h0000);
    poke_w(32'h2000_8000, 16'h0000);
    run_until(HAND + 0, 4000, reached);
    check(reached, "residual rerun: the handler is entered");
    // A sentinel over the two bytes that already went. Comparing the finished
    // operand cannot tell a rerun of the RESIDUAL from a rerun of the whole
    // thing -- both end with the right four bytes in memory -- so the question
    // is asked the only way it can be: put something else there and see
    // whether RTE writes over it. The residual says two bytes, not four.
    poke_w(32'h2000_7FFE, 16'h5555);
    berr_en = 1'b0;
    run_until(CODE + 8, 4000, reached);
    check(reached, "residual rerun: the program gets past the instruction");
    check(peek_w(32'h2000_7FFE) === 16'h5555,
          "residual rerun: the bytes that had gone were not written again");
    check(peek_w(32'h2000_8000) === 16'hCCDD,
          "residual rerun: and the two that were left went, once");

    // ======================================================================
    // A prefetch fault repaired IN THE FRAME. UM 6.2.2: "for each faulted
    // stage, the software handler should copy the instruction word ... to the
    // image of the appropriate stage in the stack frame. In addition, the
    // handler must clear the RB or RC bit associated with the stage that it
    // has corrected."
    //
    // The handler writes an instruction that is NOT the one in memory, so that
    // what runs says which of the two RTE believed. UM 6.2.1: "if the RC bit
    // is clear, the words on the stack for stage C of the pipe are accepted as
    // valid".
    // ======================================================================
    base_setup();
    poke_w(GONE - 2, 16'h7403);            // MOVEQ #3,D2 -- decoded, not run
    poke_w(GONE + 0, 16'h7604);            // MOVEQ #4,D3 -- what MEMORY says
    poke_w(GONE + 2, 16'h60FE);            // BRA *
    poke_w(CODE + 0, 16'h4EF9);            // JMP (xxx).L
    poke_l(CODE + 2, GONE - 2);
    poke_w(HAND +  0, 16'h3F7C);           // MOVE.W #$767F,($0C,A7)
    poke_w(HAND +  2, 16'h767F);           //   ... MOVEQ #$7F,D3 into stage C
    poke_w(HAND +  4, 16'h000C);
    poke_w(HAND +  6, 16'h026F);           // ANDI.W #$DFFF,($0A,A7)
    poke_w(HAND +  8, 16'hDFFF);           //   ... clear RC, and only RC
    poke_w(HAND + 10, 16'h000A);
    poke_w(HAND + 12, 16'h4E73);           // RTE
    reset_dut();
    run_until(HAND + 12, 4000, reached);
    check(reached, "repaired pipe: the handler reaches its RTE");
    berr_en = 1'b0;                        // stage B is still refetched
    run_until(GONE + 2, 4000, reached);
    check(reached, "repaired pipe: the program runs on");
    check(dut.u_seq.dreg[2] === 32'h0000_0003,
          "repaired pipe: the instruction being decoded ran");
    check(dut.u_seq.dreg[3] === 32'h0000_007F,
          "repaired pipe: and the REPAIRED word ran, not the one in memory");
    check(dut.u_seq.isp_q === ISP0, "repaired pipe: the frame came off");

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

    // ======================================================================
    // The same faults, taken in USER mode -- SunOS's first user process
    // touching its data page. The frame goes on the supervisor stack, in
    // supervisor space, and holds the user's status register.
    // ======================================================================
    base_setup();
    user_on_sstack = 0;
    poke_w(CODE + 0,  16'h227C);           // MOVEA.L #$1800,A1
    poke_l(CODE + 2,  32'h0000_1800);
    poke_w(CODE + 6,  16'h4E61);           // MOVE A1,USP
    poke_w(CODE + 8,  16'h207C);           // MOVEA.L #GONE,A0
    poke_l(CODE + 10, GONE);
    poke_w(CODE + 14, 16'h46FC);           // MOVE #$0000,SR -- to user mode
    poke_w(CODE + 16, 16'h0000);
    poke_w(CODE + 18, 16'h2080);           // MOVE.L D0,(A0) -- faults
    poke_w(CODE + 20, 16'h60FE);
    poke_w(HAND + 0,  16'h7433);           // MOVEQ #$33,D2
    poke_w(HAND + 2,  16'h60FE);
    reset_dut();
    run_until(HAND + 2, 3000, reached);
    base = ISP0 - 32'h5C;
    check(reached, "user-mode write fault: the bus error handler runs");
    check(dut.u_seq.isp_q === base, "user-mode write fault: a long frame on the ISP");
    // The SYSTEM byte: S and T clear, mask 0. The condition codes are the
    // instruction's own business mid-way -- MOVE has already set Z for the zero
    // it is moving -- and the long frame's continuation finishes them.
    check(peek_w(base + 32'h00) >> 8 === 8'h00,
          "user-mode write fault: +$00 is the USER's status register");
    check(peek_l(base + 32'h02) === CODE + 18,
          "user-mode write fault: +$02 is the faulted instruction");
    check(user_on_sstack == 0,
          "user-mode write fault: no user-space cycle touched the supervisor stack");

    base_setup();
    user_on_sstack = 0;
    poke_w(CODE + 0,  16'h227C);           // MOVEA.L #$1800,A1
    poke_l(CODE + 2,  32'h0000_1800);
    poke_w(CODE + 6,  16'h4E61);           // MOVE A1,USP
    poke_w(CODE + 8,  16'h207C);           // MOVEA.L #GONE,A0
    poke_l(CODE + 10, GONE);
    poke_w(CODE + 14, 16'h46FC);           // MOVE #$0000,SR -- to user mode
    poke_w(CODE + 16, 16'h0000);
    poke_w(CODE + 18, 16'h4ED0);           // JMP (A0) -- the prefetch faults
    poke_w(HAND + 0,  16'h7433);
    poke_w(HAND + 2,  16'h60FE);
    reset_dut();
    run_until(HAND + 2, 3000, reached);
    check(reached, "user-mode prefetch fault: the bus error handler runs");
    check(peek_w(dut.u_seq.isp_q) >> 8 === 8'h00,
          "user-mode prefetch fault: +$00 is the USER's status register");
    check(user_on_sstack == 0,
          "user-mode prefetch fault: no user-space cycle touched the supervisor stack");

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
