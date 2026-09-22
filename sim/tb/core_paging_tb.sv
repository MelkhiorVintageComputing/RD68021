// RD68021 -- demand paging: every shape of operand faulted across a page
// page_at, handled, and continued.
//
// This is the Sun-3 requirement made checkable, and the reason the checkpoint
// set was frozen before any instruction microcode was written. A misaligned
// operand on a narrow port is split by the bus unit into up to four cycles --
// UM table 5-6 -- and a page page_at in the middle of it means the FIRST of
// those cycles succeeds and a later one does not. What the frame then has to
// carry is the RESIDUAL: the address of the next byte still to transfer and
// how many are left. RTE hands that back to the bus unit and the operand
// finishes; the instruction never knows.
//
// Every combination of
//
//     operand size   1, 2 and 4 bytes
//     alignment      A1A0 = 00, 01, 10, 11
//     port size      8, 16 and 32 bits
//     direction      read and write
//
// is run with the operand straddling a page that is not there. The handler is
// real MC68020 code: it reads the data fault address out of the frame at +$10,
// hands it to the pager, and returns with DF still set so that the processor
// reruns the access itself -- UM 6.2.3.

`timescale 1ns / 1ps

module core_paging_tb;

`include "rd68021_core_harness.svh"

  localparam logic [31:0] ISP0 = 32'h0000_1000;
  localparam logic [31:0] CODE = 32'h0000_0400;
  localparam logic [31:0] HAND = 32'h0000_0500;
  localparam logic [31:0] PAGER = 32'h0000_7000;  // the pager's control word

  // The page under test, and the page_at the operands straddle.
  localparam logic [31:0] PAGE_MASK = 32'hFFFF_F000;

  int unsigned nsize, nalign, nport, ndir;
  int unsigned isize, ialign, iport, idir;
  int unsigned opsize;
  logic [31:0] port_base;
  logic [31:0] page_at;
  logic [31:0] addr;
  logic [31:0] want;
  logic [31:0] mask;
  logic [15:0] got_w;
  bit          reached;
  string       what;
  int unsigned faults;
  int unsigned cases_run;

  // The pager. A write to its control word maps whatever page the value names,
  // which here means letting the access through.
  always @(negedge as_n_o) begin
    if (rst_n && !rw_o && (a_o[31:0] & ~32'd3) == PAGER) begin
      berr_en = 1'b0;
      faults  = faults + 1;
    end
  end

  task automatic setup();
    int unsigned v;
    for (v = 0; v < 256; v = v + 1) poke_l(v * 4, 32'h0000_9000);
    poke_w(32'h0000_9000, 16'h60FE);
    poke_l(32'h0000_0000, ISP0);
    poke_l(32'h0000_0004, CODE);
    poke_l(32'h0000_0008, HAND);          // vector 2, bus error

    // The handler: hand the data fault address at +$10 of the frame to the
    // pager, then return with DF untouched so that RTE reruns the access.
    poke_w(HAND + 0, 16'h21EF);           // MOVE.L ($10,A7),($7000).W
    poke_w(HAND + 2, 16'h0010);
    poke_w(HAND + 4, PAGER[15:0]);
    poke_w(HAND + 6, 16'h4E73);           // RTE
  endtask

  initial begin
    $display("core_paging_tb: every operand shape faulted across a page boundary");
    faults    = 0;
    cases_run = 0;

    for (idir = 0; idir < 2; idir = idir + 1)
    for (iport = 0; iport < 3; iport = iport + 1)
    for (isize = 0; isize < 3; isize = isize + 1)
    for (ialign = 0; ialign < 4; ialign = ialign + 1) begin
      opsize = (isize == 0) ? 1 : (isize == 1) ? 2 : 4;
      case (iport)
        0: begin port_base = 32'h0000_0000; what = "32-bit port"; end
        1: begin port_base = 32'h1000_0000; what = "16-bit port"; end
        default: begin port_base = 32'h2000_0000; what = " 8-bit port"; end
      endcase

      // The page under test is page 8 of the port. An operand at alignment
      // `ialign` STRADDLES the boundary exactly when it runs off the end of its
      // own long word -- ialign + size > 4 -- and then it is placed in the long
      // word below, so its first cycles are in the page that is there and a
      // later one is not. When it cannot straddle, it goes inside the missing
      // page instead and faults on its first cycle. Both are worth running:
      // the first is the one that leaves a partial residual for the frame to
      // carry, and the second is the one every byte access is.
      page_at = port_base + 32'h8000;
      if (ialign + opsize > 4) addr = page_at - 4 + ialign;
      else                     addr = page_at + ialign;

      setup();
      want = 32'h1234_5678 >> (8 * (4 - opsize));

      // The program. The operand goes to or from D0 through (A0).
      poke_w(CODE + 0, 16'h207C);                    // MOVEA.L #addr,A0
      poke_l(CODE + 2, addr);
      poke_w(CODE + 6, 16'h203C);                    // MOVE.L #want,D0
      poke_l(CODE + 8, want);
      if (idir == 0)
        // A write: MOVE.<size> D0,(A0)
        poke_w(CODE + 12, (opsize == 1) ? 16'h1080 :
                          (opsize == 2) ? 16'h3080 : 16'h2080);
      else
        // A read into D1: MOVE.<size> (A0),D1
        poke_w(CODE + 12, (opsize == 1) ? 16'h1210 :
                          (opsize == 2) ? 16'h3210 : 16'h2210);
      poke_w(CODE + 14, 16'h7455);                   // MOVEQ #$55,D2
      poke_w(CODE + 16, 16'h60FE);                   // BRA *

      // For a read, put the answer where the instruction will look for it --
      // in memory that is about to be unmapped, which is the point.
      if (idir == 1) begin
        case (opsize)
          1: poke_w(addr & ~32'd1, (addr[0] ? {8'h00, want[7:0]}
                                            : {want[7:0], 8'h00}));
          2: poke_w(addr, want[15:0]);
          default: begin poke_w(addr, want[31:16]); poke_w(addr + 2, want[15:0]); end
        endcase
      end

      reset_dut();
      berr_en   = 1'b1;
      berr_base = page_at;
      berr_mask = PAGE_MASK;

      run_until(CODE + 16, 6000, reached);
      cases_run = cases_run + 1;
      check(reached, $sformatf("%s size %0d at %08h (%s): the program finishes",
                               what, opsize, addr, idir ? "read" : "write"));
      check(dut.u_seq.dreg[2] === 32'h0000_0055,
            $sformatf("%s size %0d at %08h: the next instruction ran",
                      what, opsize, addr));
      check(dut.u_seq.isp_q === ISP0,
            $sformatf("%s size %0d at %08h: the stack is unwound",
                      what, opsize, addr));
      if (idir == 0) begin
        case (opsize)
          1: begin
            got_w = peek_w(addr & ~32'd1);
            check((addr[0] ? got_w[7:0] : got_w[15:8]) === want[7:0],
                  $sformatf("%s byte at %08h: the byte landed", what, addr));
          end
          2: check(peek_w(addr) === want[15:0],
                   $sformatf("%s word at %08h: the word landed", what, addr));
          default: check({peek_w(addr), peek_w(addr + 2)} === want,
                   $sformatf("%s long at %08h: the long word landed", what, addr));
        endcase
      end else begin
        mask = (opsize == 1) ? 32'h0000_00FF
             : (opsize == 2) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
        check((dut.u_seq.dreg[1] & mask) === (want & mask),
              $sformatf("%s size %0d at %08h: the operand was read",
                        what, opsize, addr));
      end
    end

    $display("core_paging_tb: %0d cases, %0d faults handled, %0d checks, %0d failed",
             cases_run, faults, checks, fails);
    // Every case must have faulted, or the sweep is testing the plain bus.
    if (fails == 0 && faults == cases_run) $display("PASS: core_paging_tb");
    else                                   $display("FAIL: core_paging_tb");
    $finish;
  end

endmodule
